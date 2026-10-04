import Foundation
import Testing
import PaceCore
@testable import PaceStore

@Suite("Intentional screenshot review") struct CaptureReviewTests {
    @Test func groundedKnownMerchantCanAutoSaveUnderAssistedM1() throws {
        let database = try PaceDatabase()
        let captured = Instant(iso: "2026-09-28T04:00:00Z")!
        let request = CaptureRequest(source: "screenshot", path: "screenshot_intentional_fm",
            amountMinor: 1280, merchant: "ZUS COFFEE", capturedAt: captured,
            timeZone: "Asia/Kuala_Lumpur", idempotencyKey: "screenshot:known-test",
            rawFields: ["imageHash": "known-test"], amountTrust: .trusted, merchantTrust: .usable)
        let result = try CaptureProcessor(database: database).process(request)
        #expect(result.outcome == .saved)
        #expect(result.categoryID != nil)
    }

    @Test func trustedOCRAliasWinsButConflictingFMSelectionRequiresReview() throws {
        let database = try PaceDatabase()
        let captured = Instant(iso: "2026-09-28T04:00:00Z")!
        let request = CaptureRequest(source: "screenshot", path: "screenshot_intentional_fm",
            amountMinor: 1280, merchant: "OTHER SHOP", capturedAt: captured,
            timeZone: "Asia/Kuala_Lumpur", idempotencyKey: "screenshot:alias-test",
            rawFields: ["imageHash": "alias-test", "ocrMerchantCandidate": "ZUS COFFEE"],
            amountTrust: .trusted, merchantTrust: .unresolved)
        let result = try CaptureProcessor(database: database).process(request)
        #expect(result.outcome == .draft)
        #expect(result.merchant == "ZUS Coffee")
    }

    @Test func draftConfirmationTeachesMerchantOnlyAfterExplicitAction() throws {
        let database = try PaceDatabase()
        let captured = Instant(iso: "2026-09-28T04:00:00Z")!
        let request = CaptureRequest(source: "screenshot", path: "screenshot_intentional_fm",
            amountMinor: 1280, merchant: "DUMAKIVO LAB", capturedAt: captured,
            timeZone: "Asia/Kuala_Lumpur", idempotencyKey: "screenshot:review-test",
            rawFields: ["imageHash": "review-test"], amountTrust: .trusted, merchantTrust: .usable)
        var policy = CaptureTrustPolicy(); policy.pinnedStage = .observe
        let result = try CaptureProcessor(database: database).process(request, policy: policy)
        #expect(result.outcome == .draft)
        let id = try #require(result.recordID)
        #expect(try database.writer.read { try Queries.resolveMerchant($0, name: "DUMAKIVO LAB") } == nil)
        #expect(try CaptureReview.drafts(database).contains(where: { $0.id == id }))
        let actionID = try CaptureReview.confirm(database, id: id, amountMinor: 1280,
            merchant: "DUMAKIVO LAB", categoryID: "other")
        #expect(!actionID.isEmpty)
        #expect(try database.writer.read { try Queries.confirmedTransaction($0, id: id) } != nil)
        #expect(try database.writer.read { try Queries.resolveMerchant($0, name: "DUMAKIVO LAB") } != nil)
        #expect(try CaptureReview.drafts(database).isEmpty)
        let state = try #require(CaptureProcessor(database: database).pathStates().first { $0.path == "screenshot_intentional_fm" })
        #expect(state.stage == .assisted && state.amountErrors == 0 && state.merchantErrors == 0)
        _ = try LedgerExecutor(database: database).undo(actionID)
        #expect(try database.writer.read { try Queries.resolveMerchant($0, name: "DUMAKIVO LAB") } == nil)
        #expect(try CaptureReview.drafts(database).contains(where: { $0.id == id }))
    }
}
