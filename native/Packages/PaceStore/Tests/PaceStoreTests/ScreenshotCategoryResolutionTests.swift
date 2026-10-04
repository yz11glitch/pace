import Foundation
import GRDB
import PaceCore
import Testing
@testable import PaceStore

@Suite("Intentional screenshot categories") struct ScreenshotCategoryResolutionTests {
    let captured = Instant(iso: "2026-09-28T04:00:00Z")!

    func request(_ merchant: String, hash: String) -> CaptureRequest {
        CaptureRequest(source: "screenshot", path: "screenshot_intentional_fm",
            amountMinor: 5300, merchant: merchant, capturedAt: captured,
            timeZone: "Asia/Kuala_Lumpur", idempotencyKey: "screenshot:\(hash)",
            rawFields: ["imageHash": hash, "ocrMerchantCandidate": merchant],
            amountTrust: .trusted, merchantTrust: .usable)
    }

    @Test func knownMemorySkipsFM() async throws {
        let processor = CaptureProcessor(database: try PaceDatabase())
        let input = request("ZUS COFFEE", hash: "known-category")
        let result = try await processor.screenshotCategory(for: input, ocrText: ["Food & Drink"]) { _, _ in
            Issue.record("Known merchant must skip FM")
            return .init(name: "Shopping")
        }
        #expect(result.source == "merchant_memory")
        #expect(result.categoryID == "food-drink")
        #expect(!result.fmAttempted)
    }

    @Test func validFMCategorySavesWithoutLearningAndUserCorrectionWinsLater() async throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        var input = request("NORTH QUAY BOOKS", hash: "new-category")
        let suggestion = try await processor.screenshotCategory(for: input,
            ocrText: ["To NORTH QUAY BOOKS", "Category", "Shopping"]) { merchant, context in
            #expect(merchant == "NORTH QUAY BOOKS")
            #expect(context.contains("Shopping"))
            return .init(name: "Shopping")
        }
        #expect(suggestion.source == "apple_fm" && suggestion.fmAttempted)
        input.categoryID = suggestion.categoryID; input.categoryTrust = .usable
        let saved = try processor.process(input)
        #expect(saved.outcome == .saved && saved.categoryID == "shopping")
        let id = try #require(saved.recordID)
        #expect(try await db.writer.read { try Queries.resolveMerchant($0, name: "NORTH QUAY BOOKS") } == nil)

        _ = try LedgerExecutor(database: db).update(id, TransactionChanges(categoryID: "food-drink"))
        let learned = try await db.writer.read { try Queries.resolveMerchant($0, name: "NORTH QUAY BOOKS") }
        #expect(learned?.categoryID == "food-drink")
        let next = try await processor.screenshotCategory(for: request("NORTH QUAY BOOKS", hash: "later-category"),
            ocrText: ["Shopping"]) { _, _ in
            Issue.record("Corrected merchant must skip FM")
            return .init(name: "Shopping")
        }
        #expect(next.source == "merchant_memory" && next.categoryID == "food-drink")
        #expect(!next.fmAttempted)
        var laterInput = request("NORTH QUAY BOOKS", hash: "later-category")
        laterInput.capturedAt = Instant(seconds: captured.seconds + 3_600)
        laterInput.categoryID = next.categoryID; laterInput.categoryTrust = .usable
        let later = try processor.process(laterInput)
        #expect(later.outcome == .saved && later.categoryID == "food-drink")
    }

    @Test func refusalAndInvalidOutputFallBackWithoutBlockingCapture() async throws {
        for (hash, suggestion) in [("refused", ScreenshotCategorySuggestion(name: nil, error: "refusal")),
                                   ("invalid", ScreenshotCategorySuggestion(name: "Dining", error: nil))] {
            let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
            var input = request("NORTH QUAY BOOKS", hash: hash)
            let category = try await processor.screenshotCategory(for: input, ocrText: ["Payment complete"]) { _, _ in
                suggestion
            }
            #expect(category.source == "fallback_other")
            #expect(category.categoryID == "other")
            #expect(category.fmAttempted)
            input.categoryID = category.categoryID; input.categoryTrust = .usable
            let saved = try processor.process(input)
            #expect(saved.outcome == .saved && saved.categoryID == "other")
            #expect(try await db.writer.read { try Queries.resolveMerchant($0, name: "NORTH QUAY BOOKS") } == nil)
        }
    }
}
