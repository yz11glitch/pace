import Foundation
import GRDB
import PaceCore
import Testing
@testable import PaceStore

@Suite("Local intentional capture feedback") struct IntentionalCaptureFeedbackTests {
    let captured = Instant(iso: "2026-09-29T21:08:00+08:00")!
    let zone = "Asia/Kuala_Lumpur"

    func capture(_ database: PaceDatabase, hash: String = UUID().uuidString,
                 categoryID: String = "transport", draft: Bool = false) throws -> CaptureResult {
        let lines = ["Completed", "-RM 9.50", "To CINEMA HALL", "30/07/2026 07:45:57"]
            .enumerated().map { index, value in
                ScreenshotTextLine(value, confidence: 0.98, x: index == 1 ? 0.3 : 0.1,
                    y: 0.08 + Double(index) * 0.08, width: index == 1 ? 0.4 : 0.7,
                    height: index == 1 ? 0.07 : 0.035)
            }
        let resolution = ScreenshotFieldResolver().resolve(lines, capturedAt: captured, timeZone: zone)
        var input = ScreenshotIntentionalCapture.request(lines: lines, resolution: resolution,
            imageHash: hash, capturedAt: captured, timeZone: zone)
        input.categoryID = categoryID
        input.categoryTrust = .usable
        let category = ScreenshotCategoryResolution(categoryID: categoryID, source: "apple_fm",
            memoryCategoryID: nil, fmAttempted: true, fmCategory: "Transport",
            validation: "valid Pace category", fmError: nil)
        let evidence = try IntentionalCaptureEvidence(lines: lines, capturedAt: captured,
            timeZone: zone, resolver: resolution, category: category)
        var policy = CaptureTrustPolicy()
        if draft { policy.pinnedStage = .observe }
        return try CaptureProcessor(database: database).process(input, policy: policy,
            feedbackEvidence: evidence)
    }

    func only(_ database: PaceDatabase) throws -> IntentionalCaptureFeedbackRecord {
        try #require(CaptureProcessor(database: database).intentionalCaptureFeedback().records.first)
    }

    @Test func categoryOnlyCorrectionPreservesOriginalAndJSONRoundTrips() throws {
        let db = try PaceDatabase()
        let saved = try capture(db)
        let id = try #require(saved.recordID)
        #expect(saved.outcome == .saved)
        #expect(try only(db).outcome == "acceptedUnchanged")
        #expect(try only(db).changedFields.isEmpty)
        #expect(try !only(db).explicitlyReportedIssue)
        #expect(try db.writer.read { try Int.fetchOne($0,
            sql: "SELECT count(*) FROM merchants WHERE canonical_key = 'cinema hall'") } == 0)
        _ = try LedgerExecutor(database: db).update(id, TransactionChanges(categoryID: "entertainment"))
        let exported = try CaptureProcessor(database: db).intentionalCaptureFeedback(
            appVersion: "0.1.0", buildVersion: "1", generatedAt: captured.date)
        let record = try #require(exported.records.first)
        #expect(record.captureUUID != id)
        #expect(record.predicted.amountMinor == 950 && record.corrected.amountMinor == 950)
        #expect(record.predicted.categoryID == "transport")
        #expect(record.corrected.categoryID == "entertainment")
        #expect(record.changedFields == ["category"])
        #expect(record.outcome == "editedNotReported")
        #expect(!record.explicitlyReportedIssue && record.userFeedbackNote == nil)
        #expect(record.captureSource == .intentionalBackTap && record.applePay == nil)
        #expect(record.vision?.lines.count == 4)
        #expect(record.vision?.lines[1].confidence == 0.98)
        #expect(record.resolver?.amount.kind == .decisive)
        #expect(record.category?.fmAttempted == true && record.category?.fmCategory == "Transport")
        #expect(exported.schemaVersion == 3 && exported.appVersion == "0.1.0")
        #expect(exported.summary.totalCaptures == 1 && exported.summary.corrected == 1)
        #expect(exported.summary.reportedIssues == 0)
        #expect(exported.summary.correctionCountsByField == ["category": 1])
        let decoded = try JSONDecoder().decode(IntentionalCaptureFeedbackExport.self,
            from: exported.jsonData())
        #expect(decoded.records.first?.predicted.categoryID == "transport")
        #expect(decoded.records.first?.corrected.categoryID == "entertainment")
        #expect(decoded.records.first?.changedFields == ["category"])
        #expect(decoded.records.first?.explicitlyReportedIssue == false)
        #expect(try db.writer.read { try Queries.resolveMerchant($0, name: "CINEMA HALL") }?.categoryID == "entertainment")
    }

    @Test func amountMerchantAndMultipleFieldCorrections() throws {
        for (amount, merchant, category, expected) in [
            (1_050, "CINEMA HALL", "transport", ["amount"]),
            (950, "NEW CINEMA", "transport", ["merchant"]),
            (1_050, "NEW CINEMA", "entertainment", ["amount", "merchant", "category"])
        ] {
            let db = try PaceDatabase()
            let saved = try capture(db)
            let id = try #require(saved.recordID)
            _ = try LedgerExecutor(database: db).update(id, TransactionChanges(
                amountMinor: amount, merchantText: merchant, categoryID: category))
            let record = try only(db)
            #expect(record.predicted.amountMinor == 950)
            #expect(record.predicted.merchant == "CINEMA HALL")
            #expect(record.predicted.categoryID == "transport")
            #expect(record.corrected.amountMinor == amount)
            #expect(record.corrected.merchant == merchant)
            #expect(record.corrected.categoryID == category)
            #expect(record.changedFields == expected)
            #expect(!record.explicitlyReportedIssue)
        }
    }

    @Test func unchangedDraftConfirmationAndDeletionHaveDistinctOutcomes() throws {
        let db = try PaceDatabase()
        let draft = try capture(db, draft: true)
        let id = try #require(draft.recordID)
        #expect(try only(db).outcome == "pendingReview")
        _ = try CaptureReview.confirm(db, id: id, amountMinor: 950,
            merchant: "CINEMA HALL", categoryID: "transport")
        #expect(try only(db).outcome == "acceptedUnchanged")
        #expect(try only(db).changedFields.isEmpty)
        #expect(try !only(db).explicitlyReportedIssue)
        _ = try LedgerExecutor(database: db).softDelete(id)
        let result = try CaptureProcessor(database: db).intentionalCaptureFeedback()
        #expect(result.records.first?.outcome == "abandonedDeleted")
        #expect(result.summary.abandonedDeleted == 1)
    }

    @Test func reviewCaptureCorrectionIsLinkedToOriginalCapture() throws {
        let db = try PaceDatabase()
        let draft = try capture(db, draft: true)
        let id = try #require(draft.recordID)
        _ = try CaptureReview.confirm(db, id: id, amountMinor: 1_050,
            merchant: "RENAMED CINEMA", categoryID: "entertainment")
        let record = try only(db)
        #expect(record.transactionID == id)
        #expect(record.predicted.amountMinor == 950)
        #expect(record.predicted.merchant == "CINEMA HALL")
        #expect(record.predicted.categoryID == "transport")
        #expect(record.corrected.amountMinor == 1_050)
        #expect(record.corrected.merchant == "RENAMED CINEMA")
        #expect(record.corrected.categoryID == "entertainment")
        #expect(record.changedFields == ["amount", "merchant", "category"])
        #expect(!record.explicitlyReportedIssue)
    }

    @Test func reportedCategoryCorrectionKeepsNoteAndOriginalPrediction() throws {
        let db = try PaceDatabase()
        let saved = try capture(db)
        let id = try #require(saved.recordID)
        let issue = CaptureFeedbackIssue(explicitlyReportedIssue: true,
            userFeedbackNote: "This venue belongs in Entertainment.")
        _ = try LedgerExecutor(database: db).update(id,
            TransactionChanges(categoryID: "entertainment"), captureFeedbackIssue: issue)
        let exported = try CaptureProcessor(database: db).intentionalCaptureFeedback()
        let record = try #require(exported.records.first)
        #expect(record.predicted.categoryID == "transport")
        #expect(record.corrected.categoryID == "entertainment")
        #expect(record.changedFields == ["category"])
        #expect(record.explicitlyReportedIssue)
        #expect(record.userFeedbackNote == "This venue belongs in Entertainment.")
        #expect(record.outcome == "reportedAndCorrected")
        #expect(try db.writer.read { try String.fetchOne($0,
            sql: "SELECT note FROM transactions WHERE id = ?", arguments: [id]) } == nil)
        #expect(exported.summary.reportedIssues == 1)
        #expect(exported.summary.reportedIssuesByChangedField == ["category": 1])
        let decoded = try JSONDecoder().decode(IntentionalCaptureFeedbackExport.self,
            from: exported.jsonData())
        #expect(decoded.records.first?.explicitlyReportedIssue == true)
        #expect(decoded.records.first?.userFeedbackNote == issue.userFeedbackNote)
    }

    @Test func reportedWithoutFieldChangeAndWithoutNoteAreValid() throws {
        let db = try PaceDatabase()
        let saved = try capture(db)
        let id = try #require(saved.recordID)
        try CaptureFeedbackIssueStore.set(db, transactionID: id,
            issue: .init(explicitlyReportedIssue: true, userFeedbackNote: "The notification was confusing."))
        let noted = try only(db)
        #expect(noted.changedFields.isEmpty)
        #expect(noted.explicitlyReportedIssue)
        #expect(noted.userFeedbackNote == "The notification was confusing.")
        #expect(noted.outcome == "reportedCaptureIssue")
        try CaptureFeedbackIssueStore.set(db, transactionID: id,
            issue: .init(explicitlyReportedIssue: true))
        let noNote = try only(db)
        #expect(noNote.explicitlyReportedIssue && noNote.userFeedbackNote == nil)
        #expect(noNote.changedFields.isEmpty)
        try CaptureFeedbackIssueStore.set(db, transactionID: id,
            issue: .init(explicitlyReportedIssue: false, userFeedbackNote: "Not saved"))
        #expect(try !only(db).explicitlyReportedIssue)
        #expect(try only(db).userFeedbackNote == nil)
    }

    @Test func draftReportThenDeselectBeforeSaveStaysUnreported() throws {
        let db = try PaceDatabase()
        let draft = try capture(db, draft: true)
        let id = try #require(draft.recordID)
        let review = try #require(CaptureReview.drafts(db).first { $0.id == id })
        #expect(review.feedbackIssue?.explicitlyReportedIssue == false)
        var selected = true
        selected = false
        try CaptureFeedbackIssueStore.set(db, transactionID: id, issue: .init(explicitlyReportedIssue: selected,
            userFeedbackNote: "Discard this unsaved note"))
        _ = try CaptureReview.confirm(db, id: id, amountMinor: 950, merchant: "CINEMA HALL", categoryID: "transport")
        let record = try only(db)
        #expect(!record.explicitlyReportedIssue)
        #expect(record.userFeedbackNote == nil)
        #expect(record.outcome == "acceptedUnchanged")
    }

    @Test func reviewReportWithNoNoteIsLinkedToDraft() throws {
        let db = try PaceDatabase()
        let draft = try capture(db, draft: true)
        let id = try #require(draft.recordID)
        try CaptureFeedbackIssueStore.set(db, transactionID: id, issue: .init(explicitlyReportedIssue: true))
        _ = try CaptureReview.confirm(db, id: id, amountMinor: 950, merchant: "CINEMA HALL", categoryID: "transport")
        let record = try only(db)
        #expect(record.explicitlyReportedIssue && record.userFeedbackNote == nil)
        #expect(record.changedFields.isEmpty)
    }

    @Test func legacyFeedbackPayloadAndVersionOneExportRemainDecodable() throws {
        let db = try PaceDatabase()
        _ = try capture(db)
        let processor = CaptureProcessor(database: db)
        let current = try processor.intentionalCaptureFeedback()
        #expect(try CaptureFeedbackIssueStore.state(db,
            transactionID: current.records[0].transactionID)?.explicitlyReportedIssue == false)
        var json = try #require(JSONSerialization.jsonObject(with: current.jsonData()) as? [String: Any])
        json["schemaVersion"] = 1
        var summary = try #require(json["summary"] as? [String: Any])
        summary.removeValue(forKey: "reportedIssues")
        summary.removeValue(forKey: "reportedIssuesByChangedField")
        json["summary"] = summary
        var records = try #require(json["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "explicitlyReportedIssue")
        records[0].removeValue(forKey: "userFeedbackNote")
        json["records"] = records
        let old = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(IntentionalCaptureFeedbackExport.self, from: old)
        #expect(decoded.records[0].explicitlyReportedIssue == false)
        #expect(decoded.records[0].userFeedbackNote == nil)
        #expect(decoded.summary.reportedIssues == 0)
    }

    @Test func recordingIsPassiveAndOtherPathsAreExcluded() throws {
        let db = try PaceDatabase()
        let before = try capture(db)
        #expect(before.outcome == .saved)
        let record = try only(db)
        let after = ScreenshotFieldResolver().resolve(try #require(record.vision).lines,
            capturedAt: captured, timeZone: zone)
        #expect(after.amount.value?.minorUnits == record.resolver?.amount.value?.minorUnits)
        #expect(after.merchant.value == record.resolver?.merchant.value)
        #expect(try db.writer.read { try Queries.resolveMerchant($0, name: "CINEMA HALL") } == nil)
        let manual = CaptureRequest(source: "keypad", path: "manual", amountMinor: 500,
            merchant: "MANUAL SHOP", capturedAt: captured, timeZone: zone,
            amountTrust: .trusted, merchantTrust: .usable)
        _ = try CaptureProcessor(database: db).process(manual)
        #expect(try CaptureProcessor(database: db).intentionalCaptureFeedback().records.count == 1)
        let manualID: String = try db.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM transactions WHERE source = 'keypad' LIMIT 1")!
        }
        #expect(try CaptureFeedbackIssueStore.state(db, transactionID: manualID) == nil)
        #expect(throws: LedgerError.self) {
            try CaptureFeedbackIssueStore.set(db, transactionID: manualID,
                issue: .init(explicitlyReportedIssue: true))
        }
    }

    @Test func resetPaceDataClearsLiveStateButPreservesFeedback() throws {
        let db = try PaceDatabase()
        let saved = try capture(db)
        let savedID = try #require(saved.recordID)
        _ = try LedgerExecutor(database: db).update(savedID,
            TransactionChanges(categoryID: "entertainment"),
            captureFeedbackIssue: .init(explicitlyReportedIssue: true,
                userFeedbackNote: "Wrong category"))
        _ = try capture(db, hash: "another-screenshot", draft: true)
        try LedgerExecutor(database: db).setProfile(ProfileInput(
            paydayAnchor: 25, salaryMinor: 350_000, salaryDay: 25,
            effectiveCycleStart: LocalDate(year: 2026, month: 9, day: 25)!))
        let before = try CaptureProcessor(database: db).intentionalCaptureFeedback()
        #expect(before.records.count == 2)
        #expect(try db.writer.read { try Int.fetchOne($0,
            sql: "SELECT count(*) FROM merchants WHERE canonical_key = 'cinema hall'") } == 1)

        try PaceDataMaintenance.resetPaceData(db)

        let counts = try db.writer.read { database in
            try ["transactions", "profile_versions", "recurring_rules", "merchants",
                 "merchant_aliases", "merchant_context_rules", "categories", "preferences",
                 "action_log", "request_idempotency", "capture_feedback",
                 "capture_path_state", "capture_outcomes"].map { table in
                try Int.fetchOne(database, sql: "SELECT count(*) FROM \(table)") ?? -1
            }
        }
        let seeded = try PaceDatabase()
        let freshCounts = try seeded.writer.read { database in
            try ["transactions", "profile_versions", "recurring_rules", "merchants",
                 "merchant_aliases", "merchant_context_rules", "categories", "preferences",
                 "action_log", "request_idempotency", "capture_feedback",
                 "capture_path_state"].map { table in
                try Int.fetchOne(database, sql: "SELECT count(*) FROM \(table)") ?? -1
            }
        }
        #expect(Array(counts.dropLast()) == freshCounts)
        #expect(counts.last == 2)
        #expect(try CaptureReview.drafts(db).isEmpty)
        #expect(try db.writer.read { try Queries.resolveMerchant($0, name: "CINEMA HALL") } == nil)
        let after = try CaptureProcessor(database: db).intentionalCaptureFeedback()
        #expect(after.records.count == 2)
        #expect(after.records.map(\.captureUUID) == before.records.map(\.captureUUID))
        let reported = try #require(after.records.first { $0.transactionID == savedID })
        #expect(reported.predicted.categoryID == "transport")
        #expect(reported.corrected.categoryID == "entertainment")
        #expect(reported.changedFields == ["category"])
        #expect(reported.explicitlyReportedIssue)
        #expect(reported.userFeedbackNote == "Wrong category")
        let fresh = try capture(db, hash: "after-reset")
        #expect(fresh.outcome == .saved)
    }

    @Test func clearFeedbackPreservesLedgerMemoryAndProfile() throws {
        let db = try PaceDatabase()
        let saved = try capture(db)
        let id = try #require(saved.recordID)
        _ = try LedgerExecutor(database: db).update(id,
            TransactionChanges(categoryID: "entertainment"),
            captureFeedbackIssue: .init(explicitlyReportedIssue: true,
                userFeedbackNote: "Wrong category"))
        try LedgerExecutor(database: db).setProfile(ProfileInput(
            paydayAnchor: 25, salaryMinor: 350_000, salaryDay: 25,
            effectiveCycleStart: LocalDate(year: 2026, month: 9, day: 25)!))
        try PaceDataMaintenance.clearCaptureFeedback(db)
        let exported = try CaptureProcessor(database: db).intentionalCaptureFeedback()
        #expect(exported.records.isEmpty)
        #expect(exported.summary.totalCaptures == 0)
        #expect(exported.summary.reportedIssues == 0)
        #expect(try JSONDecoder().decode(IntentionalCaptureFeedbackExport.self,
            from: exported.jsonData()).records.isEmpty)
        #expect(try CaptureFeedbackIssueStore.state(db, transactionID: id) == nil)
        let counts = try db.writer.read { database in
            try ["transactions", "profile_versions", "capture_outcomes"].map { table in
                try Int.fetchOne(database, sql: "SELECT count(*) FROM \(table)") ?? -1
            }
        }
        #expect(counts == [1, 1, 1])
        #expect(try db.writer.read { try Queries.resolveMerchant($0, name: "CINEMA HALL") }?.categoryID == "entertainment")
        _ = try LedgerExecutor(database: db).update(id, TransactionChanges(amountMinor: 1_050))
        #expect(try db.writer.read { try Int.fetchOne($0,
            sql: "SELECT amount_minor FROM transactions WHERE id = ?", arguments: [id]) } == 1_050)
    }

    @Test func managedSnapshotsFollowTheirRespectiveResetBoundary() throws {
        let directory = temporaryDirectory()
        let db = try PaceDatabase(url: directory.appendingPathComponent("live/pace.sqlite"))
        _ = try capture(db)
        let snapshots = directory.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let managed = snapshots.appendingPathComponent("auto-test.sqlite")
        let exported = snapshots.appendingPathComponent("user-export.sqlite")
        try Backup.snapshot(db, to: managed)
        try Backup.snapshot(db, to: exported)

        try Backup.clearFeedbackFromManagedSnapshots(in: snapshots)
        try Backup.validate(managed)
        let managedDB = try PaceDatabase(url: managed)
        #expect(try CaptureProcessor(database: managedDB).intentionalCaptureFeedback().records.isEmpty)
        #expect(try managedDB.writer.read { try Int.fetchOne($0,
            sql: "SELECT count(*) FROM transactions") } == 1)
        let exportedDB = try PaceDatabase(url: exported)
        #expect(try CaptureProcessor(database: exportedDB).intentionalCaptureFeedback().records.count == 1)

        try Backup.removeManagedSnapshots(in: snapshots)
        #expect(!FileManager.default.fileExists(atPath: managed.path))
        #expect(FileManager.default.fileExists(atPath: exported.path))
    }

    @Test func resetThenClearIsCleanAcrossRestart() throws {
        let url = temporaryDirectory().appendingPathComponent("pace.sqlite")
        let db = try PaceDatabase(url: url)
        _ = try capture(db)
        try PaceDataMaintenance.resetPaceData(db)
        let reopened = try PaceDatabase(url: url)
        #expect(try CaptureProcessor(database: reopened).intentionalCaptureFeedback().records.count == 1)
        try PaceDataMaintenance.clearCaptureFeedback(reopened)
        let clean = try PaceDatabase(url: url)
        #expect(try CaptureProcessor(database: clean).intentionalCaptureFeedback().records.isEmpty)
        #expect(try clean.writer.read { try Int.fetchOne($0,
            sql: "SELECT count(*) FROM transactions") } == 0)
        #expect(try capture(clean, hash: "new-after-both").outcome == .saved)
    }

}
