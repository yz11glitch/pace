import Foundation
import GRDB
import PaceCore
import Testing
@testable import PaceStore

@Suite("Capture attention") struct CaptureAttentionTests {
    // Reuse the existing real capture regression fixtures rather than a second pipeline.
    let apple = ApplePayCaptureFeedbackTests()
    let backTap = IntentionalCaptureFeedbackTests()

    func counts(_ database: PaceDatabase) throws -> CaptureAttentionCounts {
        try database.writer.read { try Queries.captureAttention($0) }
    }

    @Test func zeroOneManyAndFeedbackDoesNotCount() throws {
        let database = try PaceDatabase()
        #expect(try counts(database) == .empty)
        let one = try apple.pay(database, draft: true)
        let id = try #require(one.recordID)
        #expect(try counts(database).draftCount == 1)
        #expect(try counts(database).total == 1)
        #expect(try counts(database).singleDraftID == id)
        #expect(try counts(database).summary == "1 capture needs you")
        _ = try apple.pay(database, amount: nil, merchant: nil, offset: 3_600)
        #expect(try counts(database).draftCount == 2)
        #expect(try counts(database).singleDraftID == nil)
        #expect(try counts(database).summary == "2 captures need you")
        try CaptureFeedbackIssueStore.set(database, transactionID: id,
            issue: .init(explicitlyReportedIssue: true, userFeedbackNote: "Check the merchant"))
        // Replay adds an outcome, never a second attention item.
        _ = try apple.pay(database, draft: true)
        #expect(try counts(database).total == 2)
        #expect(try apple.export(database).records.count == 2)
    }

    @Test(arguments: [false, true]) func discardUndoPreserveBothFeedbackSources(screenshot: Bool) throws {
        let database = try PaceDatabase()
        let result = try screenshot ? backTap.capture(database, draft: true) : apple.pay(database, draft: true)
        let id = try #require(result.recordID)
        let issue = CaptureFeedbackIssue(explicitlyReportedIssue: true, userFeedbackNote: "Wrong shop, keep evidence")
        try CaptureFeedbackIssueStore.set(database, transactionID: id, issue: issue)
        let original = try #require(CaptureReview.drafts(database).first)
        let evidence = try apple.export(database).records.first
        let before = try database.writer.read { try $0.snapshot("transactions", id: id) }!
        let paths = try database.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM capture_path_state") }
        let memory = try database.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM merchants") }
        let action = try #require(try CaptureReview.discard(database, id: id))
        #expect(try CaptureReview.drafts(database).isEmpty)
        #expect(try counts(database) == .empty)
        #expect(try database.writer.read { try Queries.history($0, .init()).isEmpty })
        #expect(try CaptureFeedbackIssueStore.state(database, transactionID: id) == issue)
        let discarded = try #require(apple.export(database).records.first)
        #expect(discarded.outcome == "abandonedDeleted")
        #expect(discarded.captureUUID == evidence?.captureUUID)
        #expect(discarded.predicted == evidence?.predicted)
        #expect(discarded.corrected == evidence?.corrected)
        #expect(discarded.explicitlyReportedIssue && discarded.userFeedbackNote == issue.userFeedbackNote)
        #expect(discarded.vision == evidence?.vision && discarded.applePay == evidence?.applePay)
        #expect(try CaptureReview.discard(database, id: id) == nil) // No second deletion audit.
        #expect(try database.writer.read { try Int.fetchOne($0,
            sql: "SELECT count(*) FROM capture_outcomes WHERE transaction_id = ? AND outcome = 'discarded'", arguments: [id]) } == 1)
        let executor = LedgerExecutor(database: database)
        try executor.undoDraftDiscard(action)
        try executor.undoDraftDiscard(action) // Safe replay of Undo.
        #expect(try CaptureReview.drafts(database).first == original)
        #expect(try counts(database).singleDraftID == id)
        #expect(try CaptureFeedbackIssueStore.state(database, transactionID: id) == issue)
        let restored = try #require(apple.export(database).records.first)
        #expect(restored.outcome == "pendingReview")
        #expect(restored.captureUUID == evidence?.captureUUID && restored.predicted == evidence?.predicted)
        #expect(restored.explicitlyReportedIssue && restored.userFeedbackNote == issue.userFeedbackNote)
        let after = try database.writer.read { try $0.snapshot("transactions", id: id) }!
        #expect(before.filter { $0.key != "updated_at" } == after.filter { $0.key != "updated_at" })
        #expect(try database.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM capture_path_state") } == paths)
        #expect(try database.writer.read { try Row.fetchAll($0, sql: "SELECT * FROM merchants") } == memory)
    }

    @Test func amountMissingDraftDiscardPersistsAcrossRestartAndUndoKeepsNull() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pace.sqlite")
        let database = try PaceDatabase(url: url)
        let result = try apple.pay(database, amount: nil, merchant: nil)
        let id = try #require(result.recordID)
        let original = try #require(CaptureReview.drafts(database).first)
        #expect(original.amountMinor == nil && original.merchant == nil)
        let action = try #require(try CaptureReview.discard(database, id: id))
        let reopened = try PaceDatabase(url: url)
        #expect(try CaptureReview.drafts(reopened).isEmpty)
        try LedgerExecutor(database: reopened).undoDraftDiscard(action)
        #expect(try CaptureReview.drafts(reopened).first == original)
        #expect(try reopened.writer.read { try Queries.history($0, .init()).isEmpty })
    }

    @Test func confirmRemovesAttentionAndDiscardRejectsSavedRow() throws {
        let database = try PaceDatabase()
        let id = try #require(apple.pay(database, draft: true).recordID)
        let action = try CaptureReview.confirm(database, id: id, amountMinor: 1_520,
            merchant: "SAMPLE MERCHANT", categoryID: "transport")
        #expect(try counts(database) == .empty)
        #expect(throws: LedgerError.self) { try CaptureReview.discard(database, id: id) }
        _ = try LedgerExecutor(database: database).undo(action)
        #expect(try counts(database).singleDraftID == id)
    }

    @Test func mixedCategoryPendingResolutionAndUndo() throws {
        let database = try PaceDatabase()
        let pending = try apple.pay(database, stage: .automatic)
        let id = try #require(pending.recordID)
        #expect(pending.outcome == .saved && pending.categoryPending)
        let draftID = try #require(apple.pay(database, amount: nil, merchant: nil, offset: 3_600).recordID)
        #expect(try counts(database).draftCount == 1 && counts(database).categoryPendingCount == 1)
        #expect(try counts(database).total == 2 && counts(database).singleDraftID == nil)
        #expect(try counts(database).summary == "1 capture needs you · 1 needs a category")
        let stored = try database.writer.read { try Queries.categoryPendingCaptures($0) }
        #expect(stored.map(\.id) == [id] && stored.first?.categoryPending == true)
        // An unrelated edit doesn't resolve it; choosing Other explicitly does.
        let executor = LedgerExecutor(database: database)
        _ = try executor.update(id, .init(note: "Later"))
        #expect(try counts(database).categoryPendingCount == 1)
        let refund = try executor.update(id, .init(type: .refund))
        #expect(try counts(database).categoryPendingCount == 1)
        _ = try executor.undo(refund.actionID)
        let action = try executor.update(id, .init(categoryID: "other"))
        #expect(try counts(database).categoryPendingCount == 0)
        #expect(try counts(database).singleDraftID == draftID)
        #expect(try database.writer.read { try Queries.resolveMerchant($0, name: "SAMPLE MERCHANT") } == nil)
        _ = try executor.undo(action.actionID)
        #expect(try counts(database).categoryPendingCount == 1)
        let resolution = try executor.update(id, .init(categoryID: "transport"))
        #expect(try counts(database).categoryPendingCount == 0)
        #expect(resolution.transaction.categoryPending == false)
        _ = try executor.undo(resolution.actionID)
        let deletion = try executor.softDelete(id)
        #expect(try counts(database).categoryPendingCount == 0)
        _ = try executor.undo(deletion.actionID)
        #expect(try counts(database).categoryPendingCount == 1)
    }

    @Test func resetPreservesFeedbackAndClearIsIndependent() throws {
        let database = try PaceDatabase()
        let id = try #require(apple.pay(database, draft: true).recordID)
        _ = try apple.pay(database, merchant: "Another", offset: 3_600, stage: .automatic)
        try CaptureFeedbackIssueStore.set(database, transactionID: id,
            issue: .init(explicitlyReportedIssue: true, userFeedbackNote: "Keep me"))
        let action = try #require(try CaptureReview.discard(database, id: id))
        let original = try apple.export(database).records
        try PaceDataMaintenance.resetPaceData(database)
        #expect(try counts(database) == .empty && CaptureReview.drafts(database).isEmpty)
        let records = try apple.export(database).records
        #expect(records.map(\.captureUUID) == original.map(\.captureUUID))
        #expect(records.first { $0.transactionID == id }?.userFeedbackNote == "Keep me")
        #expect(throws: LedgerError.self) { try LedgerExecutor(database: database).undoDraftDiscard(action) }
        try PaceDataMaintenance.clearCaptureFeedback(database)
        #expect(try apple.export(database).records.isEmpty && counts(database) == .empty)
        let nextID = try #require(apple.pay(database, amount: nil, offset: 7_200).recordID)
        let nextAction = try #require(try CaptureReview.discard(database, id: nextID))
        try PaceDataMaintenance.clearCaptureFeedback(database)
        try LedgerExecutor(database: database).undoDraftDiscard(nextAction)
        #expect(try counts(database).singleDraftID == nextID)
        #expect(try apple.export(database).records.isEmpty) // Undo cannot resurrect cleared evidence.
    }

    @Test func resetAlsoClearsLiveDraftsAndKeepsTheirReports() throws {
        let database = try PaceDatabase()
        let id = try #require(apple.pay(database, draft: true).recordID)
        try CaptureFeedbackIssueStore.set(database, transactionID: id,
            issue: .init(explicitlyReportedIssue: true, userFeedbackNote: "Pending report"))
        try PaceDataMaintenance.resetPaceData(database)
        #expect(try counts(database) == .empty)
        #expect(try CaptureReview.drafts(database).isEmpty)
        #expect(try apple.export(database).records.first?.userFeedbackNote == "Pending report")
    }

    @Test func longMissingMerchantAndGroundedCandidateProjection() throws {
        let database = try PaceDatabase()
        let merchant = "Restoran Nasi Kandar Pelita Jalan Ampang (Cawangan Suria KLCC) Sdn Bhd"
        _ = try apple.pay(database, merchant: merchant, draft: true)
        _ = try apple.pay(database, amount: nil, merchant: nil, offset: 3_600)
        let drafts = try CaptureReview.drafts(database)
        #expect(drafts.first { $0.merchant == merchant }?.title == merchant)
        let missing = try #require(drafts.first { $0.merchant == nil })
        #expect(missing.title == "Apple Pay payment" && missing.amountMinor == nil)
        #expect(missing.source == .applePay && missing.capturePath == "apple_pay")
        #expect(missing.unresolved.contains(.merchant) && missing.unresolved.contains(.amount))
        #expect(missing.fieldTrust[.amount] == .unresolved)
        #expect(missing.capturedAt != nil && !missing.createdAt.isEmpty && !missing.occurredAt.isEmpty)
        let request = CaptureRequest(source: "screenshot", path: "screenshot_generic",
            amountMinor: nil, merchant: "Bookshop", capturedAt: apple.captured, timeZone: apple.zone,
            amountTrust: .unresolved, merchantTrust: .usable, extractionAmbiguous: true,
            amountCandidates: ["RM 12.00", "RM 21.00"])
        let candidateID = try #require(CaptureProcessor(database: database).process(request).recordID)
        let candidate = try #require(CaptureReview.drafts(database).first { $0.id == candidateID })
        #expect(candidate.amountCandidates == request.amountCandidates)
        #expect(candidate.anomalySignals == [.ambiguousAmount] && candidate.attentionReason == .amount)
    }

    @Test func duplicateSummaryDisappearsWhenMatchIsDeleted() throws {
        let database = try PaceDatabase()
        let savedID = try #require(apple.pay(database, stage: .automatic).recordID)
        let duplicateID = try #require(apple.pay(database, offset: 60).recordID)
        var draft = try #require(CaptureReview.drafts(database).first { $0.id == duplicateID })
        #expect(draft.duplicateMatchID == savedID && draft.duplicateMatch?.id == savedID)
        #expect(draft.duplicateBasis == .notRecorded && draft.attentionReason == .duplicate)
        _ = try LedgerExecutor(database: database).softDelete(savedID)
        draft = try #require(CaptureReview.drafts(database).first { $0.id == duplicateID })
        #expect(draft.duplicateMatchID == savedID && draft.duplicateMatch == nil)
        #expect(draft.attentionReason != .duplicate)
    }

    @Test func duplicateCanMatchAnotherPendingDraftWithoutClaimingItIsSaved() throws {
        let database = try PaceDatabase()
        let first = try #require(apple.pay(database, merchant: nil).recordID)
        let second = try #require(apple.pay(database, merchant: nil, offset: 60).recordID)
        let duplicate = try #require(CaptureReview.drafts(database).first { $0.id == second })
        #expect(duplicate.duplicateMatchID == first)
        #expect(duplicate.duplicateMatch?.status == "draft" && duplicate.attentionReason == .duplicate)
        #expect(try counts(database).draftCount == 2 && counts(database).categoryPendingCount == 0)
    }

    @Test func deterministicReasonCopyAndNoDebugLanguage() throws {
        let expected: [CaptureAttentionReason: String] = [.category: "Needs a category", .amount: "Check the amount",
            .merchant: "Merchant needed", .duplicate: "Possible duplicate", .date: "Check the date",
            .status: "Check this payment", .payment: "Check this payment"]
        for reason in CaptureAttentionReason.allCases {
            #expect(ReasonCopy.short(reason) == expected[reason])
            for forbidden in ["percentile", "threshold", "resolver", "M1", "G1", "G2", "G3", "unresolved", "screenshot_", "apple_pay"] {
                #expect(!ReasonCopy.short(reason).contains(forbidden))
            }
        }
        for signal in ["amount extraction ambiguous", "cold-start testing ceiling", "above personal 99th percentile",
            "new merchant above personal 90th percentile", "above merchant robust bound", "above observe path threshold",
            "above assisted path threshold", "above automatic path threshold"] {
            #expect(CaptureAnomaly(storedSignal: signal).needsAmountCheck)
        }
        #expect(CaptureAnomaly(storedSignal: "G3 resolver secret") == .other)
    }

    @Test func pendingNotificationsUseTheSameSafeVocabulary() {
        for reason in ["cold-start testing ceiling", "above personal 99th percentile",
            "above merchant robust bound, above assisted path threshold", "amount extraction ambiguous",
            "G3 resolver M1 secret"] {
            let result = CaptureResult(outcome: .draft, recordID: "draft", actionID: nil, reason: reason,
                unresolved: [], amountMinor: 1_520, merchant: "Shop", categoryID: nil, categoryName: nil,
                categoryPending: false, duplicateMatchID: nil)
            #expect(ReasonCopy.short(result) == (reason == "G3 resolver M1 secret" ? "Check this payment" : "Check the amount"))
        }
        for (fields, expected) in [(Set<CaptureField>([.category]), "Needs a category"),
            ([.merchant], "Merchant needed"), ([.date], "Check the date"), ([.status], "Check this payment"),
            ([.amount, .merchant], "Check the amount")] {
            let result = CaptureResult(outcome: .draft, recordID: "draft", actionID: nil, reason: "unresolved internal",
                unresolved: fields, amountMinor: 1_520, merchant: "Shop", categoryID: nil, categoryName: nil,
                categoryPending: false, duplicateMatchID: nil)
            #expect(ReasonCopy.short(result) == expected)
        }
    }

    @Test func sourceProjectionDoesNotGuessForOtherPaths() {
        #expect(CaptureSource(source: "wallet", path: "apple_pay").label == "Apple Pay")
        #expect(CaptureSource(source: "screenshot", path: "screenshot_intentional_fm").label == "Back Tap")
        #expect(CaptureSource(source: "screenshot", path: "screenshot_generic") == .other)
        #expect(CaptureSource(source: "future", path: nil).fallbackTitle == "Captured payment")
    }

    @Test func structuredReasonPriorityAndEveryStateHasDiscard() throws {
        let states: [(Set<CaptureField>, CaptureAttentionReason)] = [
            ([], .payment), ([.category], .category), ([.merchant, .category], .merchant),
            ([.amount, .merchant, .category, .date, .status], .amount), ([.date], .date),
            ([.status], .status), ([.date, .status], .date)
        ]
        for (unresolved, expected) in states {
            let database = try PaceDatabase()
            let id = try #require(apple.pay(database, draft: true).recordID)
            // Projection contract: reason is diagnostics; structured fields control copy.
            try database.writer.write { db in
                let raw = try String.fetchOne(db, sql: "SELECT fields_json FROM capture_outcomes WHERE transaction_id = ?", arguments: [id])!
                var fields = try JSON.decode([String: String].self, raw)
                fields["unresolved"] = unresolved.map(\.rawValue).sorted().joined(separator: ",")
                try db.execute(sql: "UPDATE capture_outcomes SET fields_json = ?, reason = 'G3 resolver M1 percentile threshold' WHERE transaction_id = ?",
                    arguments: [try JSON.encode(fields), id])
            }
            let original = try #require(CaptureReview.drafts(database).first)
            #expect(original.unresolved == unresolved && original.attentionReason == expected)
            #expect(ReasonCopy.short(original.attentionReason) == ReasonCopy.short(expected))
            let action = try #require(try CaptureReview.discard(database, id: id))
            #expect(try counts(database) == .empty)
            try LedgerExecutor(database: database).undoDraftDiscard(action)
            #expect(try CaptureReview.drafts(database).first == original)
        }
    }

    @Test func discardUndoRefusesToOverwriteLaterDeletion() throws {
        let database = try PaceDatabase()
        let id = try #require(apple.pay(database, draft: true).recordID)
        let first = try #require(try CaptureReview.discard(database, id: id))
        let executor = LedgerExecutor(database: database)
        try executor.undoDraftDiscard(first)
        let second = try #require(try CaptureReview.discard(database, id: id))
        // Replaying the already-undone first action can't restore the second deletion.
        try executor.undoDraftDiscard(first)
        #expect(try counts(database) == .empty)
        try executor.undoDraftDiscard(second)
        #expect(try counts(database).singleDraftID == id)
        #expect(throws: LedgerError.self) { try CaptureReview.discard(database, id: "does-not-exist") }
    }
}
