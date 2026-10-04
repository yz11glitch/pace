import Foundation
import GRDB
import PaceCore
import Testing
@testable import PaceStore

@Suite("Frozen daily-driver store contracts") struct DailyDriverTests {
    let apple = ApplePayCaptureFeedbackTests()
    let backTap = IntentionalCaptureFeedbackTests()
    func transaction(_ database: PaceDatabase, name: String? = "Ledger Shop", category: String = "other") throws -> StoredTransaction {
        try LedgerExecutor(database: database).create(TransactionDraft(type: .expense, amountMinor: 50,
            occurredAt: apple.captured, tzIdentifier: apple.zone,
            localDate: LocalDate(iso: "2026-09-30")!, merchantText: name,
            categoryID: category, source: .keypad)).transaction
    }

    @Test(arguments: [true, false]) func categoryAndRenameUseSharedTeaching(remember: Bool) throws {
        let db = try PaceDatabase(), executor = LedgerExecutor(database: db)
        let current = try transaction(db)
        let category = TransactionChanges(categoryID: "groceries")
        let plan = try #require(MerchantTeaching.edit(current: current, changes: category))
        #expect(plan.learnCategory && !plan.learnAlias)
        #expect(plan.consequence(categoryName: "Groceries") == "File future Ledger Shop payments under Groceries")
        let saved = try executor.update(current.id, category, remember: remember)
        #expect(saved.transaction.categoryID == "groceries")
        #expect(try db.writer.read { try Queries.resolveMerchant($0, name: "Ledger Shop")?.categoryID } == (remember ? "groceries" : nil))
        _ = try executor.undo(saved.actionID)
        #expect(try db.writer.read { try Queries.resolveMerchant($0, name: "Ledger Shop") } == nil)
        let rename = TransactionChanges(merchantText: "A Better Name")
        #expect(MerchantTeaching.edit(current: current, changes: rename)?.learnAlias == true)
        let renamed = try executor.update(current.id, rename, remember: remember)
        #expect(renamed.transaction.merchantText == "A Better Name")
        #expect(try db.writer.read { try Queries.resolveMerchant($0, name: "Ledger Shop")?.displayName } == (remember ? "A Better Name" : nil))
    }

    @Test func ordinaryEditsNeverOfferTeaching() throws {
        let db = try PaceDatabase(), current = try transaction(db)
        for changes in [TransactionChanges(amountMinor: 999), TransactionChanges(note: "Lunch"),
            TransactionChanges(localDate: LocalDate(iso: "2026-09-29")!), TransactionChanges(type: .refund),
            TransactionChanges(type: .refund, categoryID: "groceries"), TransactionChanges(merchantText: .some(nil)),
            TransactionChanges(merchantText: "LEDGER SHOP"), TransactionChanges(categoryID: "other")] {
            #expect(MerchantTeaching.edit(current: current, changes: changes) == nil)
        }
        let noName = try transaction(db, name: nil)
        #expect(MerchantTeaching.edit(current: noName, changes: .init(merchantText: "New Name")) == nil)
        #expect(MerchantTeaching.edit(current: noName, changes: .init(categoryID: "groceries")) == nil)
        #expect(MerchantTeaching.edit(current: noName, changes: .init(merchantText: "New Name", categoryID: "groceries")) != nil)
    }

    @Test(arguments: [true, false]) func reviewTeachingAndOptOut(remember: Bool) throws {
        let db = try PaceDatabase()
        let id = try #require(apple.pay(db, draft: true).recordID)
        #expect(try MerchantTeaching.review(db, id: id, merchant: "Fresh Shop", categoryID: "groceries") != nil)
        let action = try CaptureReview.confirm(db, id: id, amountMinor: 1520, merchant: "Fresh Shop", categoryID: "groceries", remember: remember)
        #expect(try db.writer.read { try Queries.resolveMerchant($0, name: "Fresh Shop")?.categoryID } == (remember ? "groceries" : nil))
        #expect(try apple.export(db).records.first?.changedFields.contains("merchant") == true)
        _ = try LedgerExecutor(database: db).undo(action)
        #expect(try CaptureReview.drafts(db).contains { $0.id == id })
    }

    @Test func unchangedRememberedReviewCategoryHasNoConsequence() throws {
        let db = try PaceDatabase()
        try apple.teachCategory(db, "SAMPLE MERCHANT", "transport")
        let id = try #require(apple.pay(db, draft: true).recordID)
        #expect(try MerchantTeaching.review(db, id: id, merchant: "SAMPLE MERCHANT", categoryID: "transport") == nil)
        #expect(try MerchantTeaching.review(db, id: id, merchant: "SAMPLE MERCHANT", categoryID: "groceries") != nil)
    }

    @Test func reviewRenameToRememberedCategoryStatesNameConsequence() throws {
        let db = try PaceDatabase()
        try apple.teachCategory(db, "Known Display", "groceries")
        let id = try #require(apple.pay(db, draft: true).recordID)
        let plan = try #require(try MerchantTeaching.review(db, id: id, merchant: "Known Display", categoryID: "groceries"))
        #expect(plan.learnAlias && !plan.learnCategory)
        #expect(plan.consequence(categoryName: "Groceries") == "Show future “SAMPLE MERCHANT” payments as Known Display")
        _ = try CaptureReview.confirm(db, id: id, amountMinor: 1520, merchant: "Known Display", categoryID: "groceries")
        #expect(try db.writer.read { try Queries.resolveMerchant($0, name: "SAMPLE MERCHANT")?.displayName } == "Known Display")
    }

    @Test func rememberedSeedConfirmationStillUsesExistingReinforcement() throws {
        let db = try PaceDatabase()
        let input = try apple.pay(db, merchant: "ZUS COFFEE", draft: true)
        let id = try #require(input.recordID), category = try #require(input.categoryID)
        #expect(try MerchantTeaching.review(db, id: id, merchant: input.merchant!, categoryID: category) == nil)
        _ = try CaptureReview.confirm(db, id: id, amountMinor: 1520, merchant: input.merchant!, categoryID: category)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT is_user_taught FROM merchants WHERE id = ?", arguments: [try Queries.resolveMerchant($0, name: input.merchant!)?.merchantID]) } == 1)
    }

    @Test(arguments: [true, false]) func noMerchantSaveAndIndependentReport(screenshot: Bool) throws {
        let db = try PaceDatabase()
        let capture = try screenshot ? backTap.capture(db, draft: true) : apple.pay(db, draft: true)
        let id = try #require(capture.recordID)
        let issue = CaptureFeedbackIssue(explicitlyReportedIssue: true, userFeedbackNote: "Merchant unreadable")
        try CaptureFeedbackIssueStore.set(db, transactionID: id, issue: issue)
        let original = try #require(try apple.export(db).records.first)
        #expect(try CaptureReview.drafts(db).first?.feedbackIssue == issue) // keep and reopen
        #expect(try MerchantTeaching.review(db, id: id, merchant: "", categoryID: "groceries") == nil)
        let action = try CaptureReview.confirm(db, id: id, amountMinor: capture.amountMinor!, merchant: "", categoryID: capture.categoryID ?? "other")
        let saved = try #require(db.writer.read { try Queries.confirmedTransaction($0, id: id) })
        #expect(saved.merchantText == nil && saved.merchantID == nil)
        #expect(saved.title == (screenshot ? "Back Tap payment" : "Apple Pay payment"))
        let result = try #require(try apple.export(db).records.first)
        #expect(result.predicted == original.predicted && result.explicitlyReportedIssue)
        #expect(result.changedFields.contains("merchant") && result.userFeedbackNote == issue.userFeedbackNote)
        _ = try LedgerExecutor(database: db).undo(action)
        #expect(try CaptureFeedbackIssueStore.state(db, transactionID: id) == issue)
        let discard = try #require(try CaptureReview.discard(db, id: id))
        #expect(try apple.export(db).records.first?.outcome == "abandonedDeleted")
        try LedgerExecutor(database: db).undoDraftDiscard(discard)
        #expect(try CaptureReview.drafts(db).first?.feedbackIssue == issue)
    }

    @Test(arguments: [true, false]) func reportingWithoutCorrectionAndEditWithoutSave(screenshot: Bool) throws {
        let db = try PaceDatabase()
        if !screenshot { try apple.teachCategory(db, "SAMPLE MERCHANT", "transport") }
        let capture = try screenshot ? backTap.capture(db, draft: true) : apple.pay(db, draft: true)
        let id = try #require(capture.recordID)
        let issue = CaptureFeedbackIssue(explicitlyReportedIssue: true, userFeedbackNote: "Check once")
        try CaptureFeedbackIssueStore.set(db, transactionID: id, issue: issue)
        _ = try CaptureReview.confirm(db, id: id, amountMinor: capture.amountMinor!, merchant: capture.merchant!, categoryID: capture.categoryID ?? "other")
        let record = try #require(try apple.export(db).records.first)
        #expect(record.outcome == "reportedCaptureIssue" && record.changedFields.isEmpty)
        let prior = try db.writer.read { try Queries.transaction($0, id: id) }
        try CaptureFeedbackIssueStore.set(db, transactionID: id, issue: .init(explicitlyReportedIssue: true, userFeedbackNote: "Noticed after saving"))
        #expect(try db.writer.read { try Queries.transaction($0, id: id) } == prior)
        #expect(try apple.export(db).records.count == 1)
        try CaptureFeedbackIssueStore.set(db, transactionID: id, issue: .init(explicitlyReportedIssue: false))
        #expect(try apple.export(db).records.first?.explicitlyReportedIssue == false)
        #expect(throws: LedgerError.self) {
            try CaptureFeedbackIssueStore.set(db, transactionID: id, issue: .init(explicitlyReportedIssue: true, userFeedbackNote: String(repeating: "x", count: 1001)))
        }
    }

    @Test func allTimeSearchNoImplicitCapAndFallbacks() throws {
        let db = try PaceDatabase(), executor = LedgerExecutor(database: db)
        for index in 0..<550 {
            var draft = TransactionDraft(type: .expense, amountMinor: 50, occurredAt: apple.captured,
                tzIdentifier: apple.zone, localDate: LocalDate(iso: index == 0 ? "2025-09-01" : "2026-09-30")!,
                merchantText: index == 0 ? "Old Search Merchant" : "Ledger Shop", categoryID: "other", source: .keypad)
            draft.note = "Search collection"
            _ = try executor.create(draft)
        }
        #expect(try db.writer.read { try Queries.history($0, .init()) }.count == 550)
        #expect(try db.writer.read { try Queries.history($0, .init(start: LocalDate(iso: "2026-09-01"), end: LocalDate(iso: "2026-09-30"))) }.count == 549)
        #expect(try db.writer.read { try Queries.history($0, .init(text: "Old Search Merchant")) }.count == 1)
        #expect(try db.writer.read { try Queries.history($0, .init(text: "RM0.50")) }.count == 550)
        #expect(try db.writer.read { try Queries.history($0, .init(text: "collection")) }.count == 550)
        var empty = try transaction(db, name: nil)
        #expect(empty.title == "Expense" && empty.ledgerMetadata == "Other")
        empty.note = "Team lunch"; #expect(empty.title == "Team lunch")
        empty.note = nil; empty.source = "wallet"
        #expect(empty.title == "Apple Pay payment" && empty.ledgerMetadata == "Other · Apple Pay")
        empty.source = "screenshot"; empty.capturePath = "screenshot_intentional_fm"
        #expect(empty.title == "Back Tap payment")
        empty.source = "keypad"; empty.type = .contribution; empty.categoryName = nil
        #expect(empty.title == "Set aside" && empty.ledgerMetadata.isEmpty)
    }

    @Test func manualDuplicateUsesLedgerTitleAndNoCaptureSource() throws {
        let db = try PaceDatabase(), executor = LedgerExecutor(database: db)
        var input = TransactionDraft(type: .expense, amountMinor: 1520, occurredAt: apple.captured,
            tzIdentifier: apple.zone, localDate: LocalDate(iso: "2026-09-30")!, categoryID: "other", source: .keypad)
        input.note = "Receipt already entered"
        let transaction = try executor.create(input).transaction
        let match = try #require(try db.writer.read { try CaptureDuplicateMatch.fetch($0, id: transaction.id) })
        #expect(match.title == transaction.title && match.title == "Receipt already entered")
        #expect(match.captureSource == nil && !match.isCaptured)
    }

    @Test func reviewDateAndNoteAreAuditedWithoutChangingCaptureTime() throws {
        let db = try PaceDatabase()
        let capture = try apple.pay(db, draft: true)
        let id = try #require(capture.recordID)
        let original = try #require(try apple.export(db).records.first)
        let chosen = Instant(iso: "2026-09-29T12:00:00+08:00")!
        #expect(try CaptureReview.drafts(db).first?.tzIdentifier == apple.zone)
        let action = try CaptureReview.confirm(db, id: id, amountMinor: 1520, merchant: "SAMPLE MERCHANT",
            categoryID: "transport", occurredAt: chosen, note: .some("Receipt corrected"))
        let record = try #require(try apple.export(db).records.first)
        #expect(record.captureTimestamp == original.captureTimestamp && record.predicted == original.predicted)
        #expect(record.corrected.ledgerTimestamp == chosen.isoUTC && record.corrected.note == "Receipt corrected")
        #expect(record.changedFields.contains("timestamp") && record.changedFields.contains("note"))
        #expect(try db.writer.read { try Queries.transaction($0, id: id)?.localDate } == LocalDate(iso: "2026-09-29"))
        _ = try LedgerExecutor(database: db).undo(action)
        #expect(try apple.export(db).records.first?.corrected.ledgerTimestamp == original.corrected.ledgerTimestamp)
    }

    @Test func storedCategorySuggestionIsReadOnlyAndUnselected() throws {
        let db = try PaceDatabase()
        let input = CaptureRequest(source: "screenshot", path: "screenshot_intentional_fm", amountMinor: 1520,
            merchant: "Suggestion Shop", categoryID: "shopping", capturedAt: backTap.captured,
            timeZone: backTap.zone, amountTrust: .trusted, merchantTrust: .usable, categoryTrust: .usable)
        var policy = CaptureTrustPolicy(); policy.pinnedStage = .observe
        let capture = try CaptureProcessor(database: db).process(input, policy: policy)
        #expect(capture.outcome == .draft)
        let draft = try #require(try CaptureReview.drafts(db).first)
        #expect(draft.suggestedCategory == "Shopping")
        #expect(draft.reviewState() == .checkOnce) // Existing intentional-capture policy.
        #expect(try db.writer.read { try Queries.resolveMerchant($0, name: "Suggestion Shop") } == nil)
        var generic = input
        generic.path = "screenshot_generic"; generic.categoryTrust = .trusted
        generic.merchant = "Another Suggestion Shop"; generic.amountMinor = 1700
        generic.capturedAt = Instant(seconds: input.capturedAt.seconds + 120)
        _ = try CaptureProcessor(database: db).process(generic, policy: policy)
        let question = try #require(try CaptureReview.drafts(db).first { $0.merchant == generic.merchant })
        #expect(question.suggestedCategory == "Shopping" && question.reviewState() == .category)
    }

    @Test func amountAndDuplicateEarlyReturnsStillPresentUnresolvedCategory() throws {
        let db = try PaceDatabase()
        let input = CaptureRequest(source: "screenshot", path: "screenshot_generic", amountMinor: nil,
            merchant: "Uncategorized Shop", capturedAt: backTap.captured, timeZone: backTap.zone,
            merchantTrust: .usable, extractionAmbiguous: true, amountCandidates: ["RM 12.00", "RM 21.00"])
        _ = try CaptureProcessor(database: db).process(input)
        let draft = try #require(try CaptureReview.drafts(db).first)
        #expect(!draft.unresolved.contains(.category)) // Existing engine's early amount return.
        #expect(draft.fieldTrust[.category] == .unresolved)
        var answers = CaptureReviewAnswers()
        #expect(draft.reviewState(answers: answers) == .ambiguousAmount)
        answers.fields.insert(.amount); answers.amountChecked = true
        #expect(draft.reviewState(answers: answers) == .category)
        answers.fields.insert(.category)
        #expect(draft.reviewState(answers: answers) == .checkOnce)
    }

    @Test func allReviewStatesAndPriorityHaveSafeCopy() throws {
        let db = try PaceDatabase()
        let id = try #require(apple.pay(db, draft: true).recordID)
        let base = try #require(try CaptureReview.drafts(db).first)
        func fixture(_ unresolved: Set<CaptureField> = [], amount: Int? = 1520, candidates: [String] = [], anomalies: [CaptureAnomaly] = [], duplicate: Bool = false) -> CaptureReviewDraft {
            CaptureReviewDraft(id: id, amountMinor: amount, merchant: "Sample", categoryID: "transport",
                capturedAt: base.capturedAt, createdAt: base.createdAt, occurredAt: base.occurredAt, source: .applePay,
                capturePath: base.capturePath, categoryName: "Transport", categoryPending: false,
                unresolved: unresolved, fieldTrust: [:], amountCandidates: candidates, anomalySignals: anomalies,
                duplicateMatchID: duplicate ? "existing" : nil,
                duplicateMatch: duplicate ? CaptureDuplicateMatch(id: "existing", amountMinor: 1520, merchant: "Sample",
                    categoryName: "Transport", occurredAt: base.occurredAt, source: .applePay, status: "confirmed") : nil,
                duplicateBasis: .notRecorded, feedbackIssue: base.feedbackIssue)
        }
        let cases: [(CaptureReviewDraft, CaptureReviewState)] = [
            (fixture(), .checkOnce), (fixture([.category]), .category),
            (fixture([.amount], candidates: ["RM 15.20", "RM 50"], anomalies: [.ambiguousAmount]), .ambiguousAmount),
            (fixture([.amount], amount: nil), .amountMissing), (fixture([.merchant]), .merchantMissing),
            (fixture(duplicate: true), .duplicate), (fixture(anomalies: [.personalLarge]), .unusuallyLarge),
            (fixture([.status]), .mayHaveFailed), (fixture([.date]), .dateUnclear)]
        #expect(Set(cases.map { String(describing: $0.1) }).count == CaptureReviewState.allCases.count)
        for (draft, state) in cases {
            #expect(draft.reviewState() == state)
            let copy = ReasonCopy.question(state, amount: "RM 15.20") + (ReasonCopy.evidence(state, draft: draft, reported: false) ?? "")
            for term in ["percentile", "threshold", "unresolved", "path", "stage", "FM", "OCR", "confidence"] { #expect(!copy.contains(term)) }
        }
        let duplicate = fixture([.merchant, .category, .status], duplicate: true)
        var answers = CaptureReviewAnswers()
        #expect(duplicate.reviewState(answers: answers) == .duplicate)
        answers.keepDuplicate = true
        #expect(duplicate.reviewState(answers: answers) == .merchantMissing)
        answers.fields.insert(.merchant)
        #expect(duplicate.reviewState(answers: answers) == .category)
        answers.fields.insert(.category)
        #expect(duplicate.reviewState(answers: answers) == .mayHaveFailed)
        answers.fields.insert(.status)
        #expect(duplicate.reviewState(answers: answers) == .checkOnce)
        #expect(ReasonCopy.evidence(.checkOnce, draft: base, reported: true) == nil)
    }
}
