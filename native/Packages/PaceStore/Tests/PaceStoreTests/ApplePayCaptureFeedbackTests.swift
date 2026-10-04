import Foundation
import GRDB
import PaceCore
import Testing
@testable import PaceStore

@Suite("Apple Pay capture feedback") struct ApplePayCaptureFeedbackTests {
    let captured = Instant(iso: "2026-09-30T12:15:00+08:00")!
    let zone = "Asia/Kuala_Lumpur"

    func pay(_ database: PaceDatabase, amount: String? = "RM 15.20", merchant: String? = "SAMPLE MERCHANT",
             offset: Int64 = 0, draft: Bool = false, stage: CaptureStage? = nil) throws -> CaptureResult {
        let input = WalletCaptureAdapter.request(amount: amount, merchant: merchant,
            cardOrPass: "sample card label", name: "sample name", shortcutInput: nil,
            capturedAt: Instant(seconds: captured.seconds + offset), timeZone: zone)
        var policy = CaptureTrustPolicy()
        policy.pinnedStage = draft ? .observe : stage
        return try CaptureProcessor(database: database).process(input, policy: policy,
            executionContext: "app_intent_background")
    }

    func backTap(_ database: PaceDatabase) throws -> CaptureResult {
        let lines = ["Completed", "-RM 9.50", "To SAMPLE VENUE", "30/07/2026 07:45:57"]
            .enumerated().map { index, value in
                ScreenshotTextLine(value, confidence: 0.98, x: index == 1 ? 0.3 : 0.1,
                    y: 0.08 + Double(index) * 0.08, width: index == 1 ? 0.4 : 0.7,
                    height: index == 1 ? 0.07 : 0.035)
            }
        let resolution = ScreenshotFieldResolver().resolve(lines, capturedAt: captured, timeZone: zone)
        var input = ScreenshotIntentionalCapture.request(lines: lines, resolution: resolution,
            imageHash: UUID().uuidString, capturedAt: captured, timeZone: zone)
        input.categoryID = "transport"
        input.categoryTrust = .usable
        let category = ScreenshotCategoryResolution(categoryID: "transport", source: "apple_fm",
            memoryCategoryID: nil, fmAttempted: true, fmCategory: "Transport",
            validation: "valid Pace category", fmError: nil)
        return try CaptureProcessor(database: database).process(input, feedbackEvidence:
            try IntentionalCaptureEvidence(lines: lines, capturedAt: captured, timeZone: zone,
                resolver: resolution, category: category))
    }

    func export(_ database: PaceDatabase) throws -> IntentionalCaptureFeedbackExport {
        try CaptureProcessor(database: database).intentionalCaptureFeedback()
    }

    func applePayRecord(_ database: PaceDatabase) throws -> IntentionalCaptureFeedbackRecord {
        try #require(export(database).records.first { $0.captureSource == .applePay })
    }

    func teachCategory(_ database: PaceDatabase, _ merchant: String, _ category: String) throws {
        let taught = try LedgerExecutor(database: database).create(TransactionDraft(type: .expense,
            amountMinor: 100, occurredAt: Instant(seconds: captured.seconds - 86_400), tzIdentifier: zone,
            localDate: LocalDate(year: 2026, month: 9, day: 29)!, merchantText: merchant, categoryID: "other", source: .keypad))
        _ = try LedgerExecutor(database: database).update(taught.transaction.id,
            TransactionChanges(categoryID: category))
    }

    @Test func savedApplePayCaptureCreatesTaggedRecordWithRealInputEvidence() throws {
        let db = try PaceDatabase()
        try teachCategory(db, "SAMPLE MERCHANT", "transport")
        let saved = try pay(db)
        #expect(saved.outcome == .saved)
        let id = try #require(saved.recordID)
        #expect(try CaptureFeedbackIssueStore.state(db, transactionID: id)?.explicitlyReportedIssue == false)
        let record = try applePayRecord(db)
        #expect(record.captureSource == .applePay && record.capturePath == "apple_pay")
        #expect(record.transactionID == id)
        #expect(record.outcome == "acceptedUnchanged" && record.changedFields.isEmpty)
        #expect(record.predicted.amountMinor == 1_520 && record.predicted.merchant == "SAMPLE MERCHANT")
        #expect(record.predicted.categoryID == "transport")
        #expect(record.m1.outcome == "saved")
        #expect(record.m1.reviewReason == "trusted fields and merchant memory")
        let evidence = try #require(record.applePay)
        #expect(evidence.received.amountText == "RM 15.20")
        #expect(evidence.received.merchantText == "SAMPLE MERCHANT")
        #expect(!evidence.received.referenceSupplied)
        #expect(evidence.received.suppliedParameters == ["amount", "cardOrPass", "merchant", "name"])
        #expect(evidence.parsedAmountMinor == 1_520 && evidence.amountTrust == "trusted")
        #expect(evidence.merchantTrust == "usable" && evidence.merchantResolution != "raw payee")
        #expect(evidence.category == .init(source: "merchantMemory", memoryCategoryID: "transport",
            memoryCategoryTrusted: true, categoryPending: false, finalCategoryID: "transport"))
        #expect(evidence.capturedAt == captured.isoUTC && evidence.timeZone == zone)
        #expect(evidence.executionContext == "app_intent_background")
        #expect(record.captureTimestamp == captured.isoUTC)
    }

    @Test func automaticSaveOfUnknownMerchantRecordsOtherAsProducedCategory() throws {
        let db = try PaceDatabase()
        let saved = try pay(db, stage: .automatic)
        #expect(saved.outcome == .saved && saved.categoryPending)
        let record = try applePayRecord(db)
        #expect(record.predicted.categoryID == "other" && record.corrected.categoryID == "other")
        #expect(record.changedFields.isEmpty && record.outcome == "acceptedUnchanged")
        #expect(record.applePay?.merchantResolution == "raw payee")
        #expect(record.applePay?.category == .init(source: "defaultOther", memoryCategoryID: nil,
            memoryCategoryTrusted: false, categoryPending: true, finalCategoryID: "other"))
        let id = try #require(saved.recordID)
        _ = try LedgerExecutor(database: db).update(id, TransactionChanges(categoryID: "entertainment"))
        #expect(try applePayRecord(db).changedFields == ["category"])
    }

    @Test func applePayEvidenceHasNoScreenshotEvidenceOrWalletValues() throws {
        let db = try PaceDatabase()
        _ = try pay(db)
        let data = try export(db).jsonData()
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let record = try #require((json["records"] as? [[String: Any]])?.first)
        #expect(record["captureSource"] as? String == "applePay")
        for key in ["vision", "visionTruncated", "resolver", "category"] { #expect(record[key] == nil) }
        let text = try #require(String(data: data, encoding: .utf8))
        for absent in ["ocr", "lines", "amountCandidates\"", "fmAttempted", "sample card label", "sample name"] {
            #expect(!text.contains(absent))
        }
        let raw = try #require(try db.writer.read { try String.fetchOne($0,
            sql: "SELECT raw_fields_json FROM capture_outcomes WHERE capture_path = 'apple_pay'") })
        #expect(!raw.contains("sample card label") && !raw.contains("sample name"))
    }

    @Test func originalIsPreservedAndEachFieldCorrectionIsAttributed() throws {
        for (changes, expected) in [
            (TransactionChanges(categoryID: "entertainment"), ["category"]),
            (TransactionChanges(amountMinor: 1_620), ["amount"]),
            (TransactionChanges(merchantText: "RENAMED MERCHANT"), ["merchant"]),
            (TransactionChanges(amountMinor: 1_620, merchantText: "RENAMED MERCHANT", categoryID: "transport"),
             ["amount", "merchant", "category"])
        ] {
            let db = try PaceDatabase()
            try teachCategory(db, "SAMPLE MERCHANT", "shopping")
            let id = try #require(try pay(db).recordID)
            _ = try LedgerExecutor(database: db).update(id, changes)
            let record = try applePayRecord(db)
            #expect(record.predicted.amountMinor == 1_520)
            #expect(record.predicted.merchant == "SAMPLE MERCHANT")
            #expect(record.predicted.categoryID == "shopping")
            #expect(record.corrected.amountMinor == changes.amountMinor ?? 1_520)
            #expect(record.corrected.merchant == changes.merchantText ?? "SAMPLE MERCHANT")
            #expect(record.corrected.categoryID == changes.categoryID ?? "shopping")
            #expect(record.changedFields == expected)
            #expect(!record.explicitlyReportedIssue && record.userFeedbackNote == nil)
            #expect(record.outcome == "editedNotReported")
        }
    }

    @Test func reportedCategoryCorrectionKeepsNoteAndKnownMerchantPrediction() throws {
        let db = try PaceDatabase()
        try teachCategory(db, "SAMPLE MERCHANT", "transport")
        let saved = try pay(db)
        let id = try #require(saved.recordID)
        #expect(saved.categoryID == "transport")
        _ = try LedgerExecutor(database: db).update(id, TransactionChanges(categoryID: "entertainment"),
            captureFeedbackIssue: .init(explicitlyReportedIssue: true, userFeedbackNote: "  Wrong category.  "))
        let record = try applePayRecord(db)
        #expect(record.predicted == IntentionalCaptureValues(amountMinor: 1_520, merchant: "SAMPLE MERCHANT",
            categoryID: "transport", ledgerTimestamp: captured.isoUTC, reference: nil, note: nil))
        #expect(record.corrected.categoryID == "entertainment")
        #expect(record.corrected.amountMinor == 1_520 && record.corrected.merchant == "SAMPLE MERCHANT")
        #expect(record.changedFields == ["category"])
        #expect(record.explicitlyReportedIssue && record.userFeedbackNote == "Wrong category.")
        #expect(record.outcome == "reportedAndCorrected")
        #expect(record.applePay?.category.source == "merchantMemory")
        #expect(record.applePay?.category.memoryCategoryID == "transport")
        #expect(record.applePay?.merchantResolution != "raw payee")
    }

    @Test func reportedWithoutFieldChangesIsValidAndDeselectClearsNote() throws {
        let db = try PaceDatabase()
        try teachCategory(db, "SAMPLE MERCHANT", "transport")
        let id = try #require(try pay(db).recordID)
        try CaptureFeedbackIssueStore.set(db, transactionID: id,
            issue: .init(explicitlyReportedIssue: true, userFeedbackNote: "Notification arrived late."))
        let reported = try applePayRecord(db)
        #expect(reported.changedFields.isEmpty && reported.explicitlyReportedIssue)
        #expect(reported.userFeedbackNote == "Notification arrived late.")
        #expect(reported.outcome == "reportedCaptureIssue")
        try CaptureFeedbackIssueStore.set(db, transactionID: id, issue: .init(explicitlyReportedIssue: false))
        #expect(try !applePayRecord(db).explicitlyReportedIssue)
        #expect(try applePayRecord(db).userFeedbackNote == nil)
    }

    @Test func applePayDraftReviewIsLinkedAndReportable() throws {
        let db = try PaceDatabase()
        let draft = try pay(db, draft: true)
        #expect(draft.outcome == .draft)
        let id = try #require(draft.recordID)
        #expect(try applePayRecord(db).outcome == "pendingReview")
        #expect(try applePayRecord(db).applePay?.category.source == "none")
        let review = try #require(CaptureReview.drafts(db).first { $0.id == id })
        #expect(review.feedbackIssue?.explicitlyReportedIssue == false)
        try CaptureFeedbackIssueStore.set(db, transactionID: id, issue: .init(explicitlyReportedIssue: true, userFeedbackNote: "Category needed"))
        _ = try CaptureReview.confirm(db, id: id, amountMinor: 1_520, merchant: "SAMPLE MERCHANT", categoryID: "entertainment")
        let record = try applePayRecord(db)
        #expect(record.predicted.categoryID == nil && record.corrected.categoryID == "entertainment")
        #expect(record.changedFields == ["category"])
        #expect(record.explicitlyReportedIssue && record.userFeedbackNote == "Category needed")
    }

    @Test func oneExportCarriesBothSourcesWithSourceSummaries() throws {
        let db = try PaceDatabase()
        try teachCategory(db, "SAMPLE MERCHANT", "transport")
        try teachCategory(db, "SECOND MERCHANT", "shopping")
        let tap = try #require(try backTap(db).recordID)
        let applePaid = try #require(try pay(db).recordID)
        _ = try pay(db, merchant: "SECOND MERCHANT", offset: 7_200)
        _ = try LedgerExecutor(database: db).update(tap, TransactionChanges(categoryID: "entertainment"))
        _ = try LedgerExecutor(database: db).update(applePaid, TransactionChanges(amountMinor: 1_620),
            captureFeedbackIssue: .init(explicitlyReportedIssue: true))
        let exported = try export(db)
        #expect(exported.schemaVersion == 3)
        #expect(exported.records.count == 3)
        #expect(Set(exported.records.map(\.captureSource)) == [.intentionalBackTap, .applePay])
        #expect(exported.summary.totalCaptures == 3 && exported.summary.corrected == 2)
        #expect(exported.summary.acceptedUnchanged == 1 && exported.summary.reportedIssues == 1)
        #expect(exported.summary.correctionCountsByField == ["category": 1, "amount": 1])
        #expect(exported.summary.byCaptureSource["intentionalBackTap"] == .init(total: 1,
            acceptedUnchanged: 0, corrected: 1, reportedIssues: 0, correctionCountsByField: ["category": 1]))
        #expect(exported.summary.byCaptureSource["applePay"] == .init(total: 2,
            acceptedUnchanged: 1, corrected: 1, reportedIssues: 1, correctionCountsByField: ["amount": 1]))
        let decoded = try JSONDecoder().decode(IntentionalCaptureFeedbackExport.self, from: exported.jsonData())
        #expect(decoded.records.map(\.captureSource) == exported.records.map(\.captureSource))
        #expect(decoded.summary.byCaptureSource == exported.summary.byCaptureSource)
        #expect(decoded.records.first { $0.captureSource == .applePay }?.applePay != nil)
        #expect(decoded.records.first { $0.captureSource == .intentionalBackTap }?.vision != nil)
    }

    @Test func versionTwoBackTapExportDecodesAsBackTap() throws {
        let db = try PaceDatabase()
        _ = try backTap(db)
        var json = try #require(JSONSerialization.jsonObject(with: export(db).jsonData()) as? [String: Any])
        json["schemaVersion"] = 2
        var summary = try #require(json["summary"] as? [String: Any])
        summary.removeValue(forKey: "byCaptureSource")
        json["summary"] = summary
        var records = try #require(json["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "captureSource")
        json["records"] = records
        let decoded = try JSONDecoder().decode(IntentionalCaptureFeedbackExport.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.records[0].captureSource == .intentionalBackTap)
        #expect(decoded.records[0].vision != nil && decoded.records[0].applePay == nil)
        #expect(decoded.summary.byCaptureSource.isEmpty)
    }

    @Test func archivedVersionTwoRecordStillExportsAfterUpgrade() throws {
        let db = try PaceDatabase()
        _ = try backTap(db)
        try PaceDataMaintenance.resetPaceData(db)
        try db.writer.write { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT id, raw_fields_json FROM capture_outcomes"))
            var fields = try JSON.decode([String: String].self, row["raw_fields_json"] as String)
            var archived = try #require(JSONSerialization.jsonObject(with:
                Data(fields["captureFeedbackArchivedRecordJSON"]!.utf8)) as? [String: Any])
            archived.removeValue(forKey: "captureSource")
            fields["captureFeedbackArchivedRecordJSON"] = String(data:
                try JSONSerialization.data(withJSONObject: archived), encoding: .utf8)
            try db.execute(sql: "UPDATE capture_outcomes SET raw_fields_json = ? WHERE id = ?",
                arguments: [try JSON.encode(fields), row["id"] as String])
        }
        let record = try #require(try export(db).records.first)
        #expect(record.captureSource == .intentionalBackTap)
        #expect(try export(db).summary.byCaptureSource["intentionalBackTap"]?.total == 1)
    }

    @Test func resetPreservesAndClearRemovesBothSources() throws {
        let db = try PaceDatabase()
        try teachCategory(db, "SAMPLE MERCHANT", "transport")
        let tap = try #require(try backTap(db).recordID)
        let applePaid = try #require(try pay(db).recordID)
        _ = try LedgerExecutor(database: db).update(applePaid, TransactionChanges(categoryID: "entertainment"),
            captureFeedbackIssue: .init(explicitlyReportedIssue: true, userFeedbackNote: "Wrong category."))
        _ = try LedgerExecutor(database: db).update(tap, TransactionChanges(categoryID: "shopping"))
        let before = try export(db)

        try PaceDataMaintenance.resetPaceData(db)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM transactions") } == 0)
        let after = try export(db)
        #expect(after.records.map(\.captureUUID) == before.records.map(\.captureUUID))
        #expect(after.summary.byCaptureSource == before.summary.byCaptureSource)
        let archived = try #require(after.records.first { $0.captureSource == .applePay })
        #expect(archived.predicted.categoryID == "transport" && archived.corrected.categoryID == "entertainment")
        #expect(archived.explicitlyReportedIssue && archived.userFeedbackNote == "Wrong category.")

        let fresh = try #require(try pay(db, offset: 3_600).recordID)
        try PaceDataMaintenance.clearCaptureFeedback(db)
        let cleared = try export(db)
        #expect(cleared.records.isEmpty)
        #expect(cleared.summary.byCaptureSource["applePay"]?.total == 0)
        #expect(cleared.summary.byCaptureSource["intentionalBackTap"]?.total == 0)
        #expect(try CaptureFeedbackIssueStore.state(db, transactionID: fresh) == nil)
        #expect(try db.writer.read { try Int.fetchOne($0,
            sql: "SELECT count(*) FROM transactions WHERE id = ?", arguments: [fresh]) } == 1)
    }

    @Test func feedbackDoesNotAlterCaptureDecisions() throws {
        // The same capture sequence with feedback retained versus cleared after every
        // capture must produce identical decisions and ledger rows.
        func run(clearing: Bool) throws -> [String] {
            let db = try PaceDatabase()
            try teachCategory(db, "KNOWN MERCHANT", "transport")
            var trace: [String] = []
            for (amount, merchant, offset, draft) in [("RM 15.20", "SAMPLE MERCHANT", Int64(0), false),
                                                      ("RM 15.20", "SAMPLE MERCHANT", 60, false),
                                                      ("RM 8.00", "KNOWN MERCHANT", 7_200, false),
                                                      ("12.00", "SAMPLE MERCHANT", 14_400, false),
                                                      ("RM 3.00", nil, 21_600, true)] {
                let result = try pay(db, amount: amount, merchant: merchant, offset: offset, draft: draft)
                trace.append([result.outcome.rawValue, result.reason, result.categoryID ?? "-",
                              String(result.categoryPending), result.merchant ?? "-",
                              result.duplicateMatchID == nil ? "-" : "dup"].joined(separator: "|"))
                if clearing { try PaceDataMaintenance.clearCaptureFeedback(db) }
            }
            let rows = try db.writer.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT amount_minor, merchant_text, category_id, status, category_pending, capture_path
                    FROM transactions ORDER BY occurred_at
                    """).map { "\($0)" }
            }
            return trace + rows
        }
        #expect(try run(clearing: false) == run(clearing: true))
    }

    @Test func reportingAloneNeverTeachesMerchantMemory() throws {
        let db = try PaceDatabase()
        let id = try #require(try pay(db, stage: .automatic).recordID)
        try CaptureFeedbackIssueStore.set(db, transactionID: id,
            issue: .init(explicitlyReportedIssue: true, userFeedbackNote: "Should be something else"))
        #expect(try db.writer.read { try Queries.resolveMerchant($0, name: "SAMPLE MERCHANT") } == nil)
        let next = try pay(db, offset: 7_200)
        #expect(next.outcome == .draft && next.categoryID == nil)
        // An explicit category correction keeps teaching memory under the existing contract.
        _ = try LedgerExecutor(database: db).update(id, TransactionChanges(categoryID: "entertainment"))
        #expect(try db.writer.read { try Queries.resolveMerchant($0, name: "SAMPLE MERCHANT") }?.categoryID
            == "entertainment")
    }

    @Test func applePayFeedbackIsBoundedWithoutTouchingBackTap() throws {
        let db = try PaceDatabase()
        _ = try backTap(db)
        for index in 0..<203 {
            _ = try pay(db, amount: "RM \(index + 1).00", offset: Int64(index) * 7_200)
        }
        let exported = try export(db)
        #expect(exported.summary.byCaptureSource["applePay"]?.total == 200)
        #expect(exported.summary.byCaptureSource["intentionalBackTap"]?.total == 1)
    }
}
