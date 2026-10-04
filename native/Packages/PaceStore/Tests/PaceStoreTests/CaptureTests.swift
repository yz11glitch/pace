import Foundation
import GRDB
import PaceCore
import Testing
@testable import PaceStore

@Suite("Capture M1")
struct CaptureTests {
    let instant = Instant(iso: "2026-09-27T04:00:00+00:00")!
    let zone = "Asia/Kuala_Lumpur"

    func request(amount: Int? = 1_250, merchant: String? = "ZUS COFFEE", offset: Int64 = 0,
                 key: String? = "wallet:test", trust: CaptureFieldTrust = .trusted) -> CaptureRequest {
        CaptureRequest(source: "wallet", path: "apple_pay", amountMinor: amount, merchant: merchant,
                       capturedAt: Instant(seconds: instant.seconds + offset), timeZone: zone, idempotencyKey: key,
                       amountTrust: amount == nil ? .unresolved : trust,
                       merchantTrust: merchant == nil ? .unresolved : .usable)
    }

    func screenshot(_ text: [String], hash: String, at: Instant? = nil, hero: Int? = nil) -> (ScreenshotFieldResolution, CaptureRequest) {
        let when = at ?? instant
        let lines = text.enumerated().map { index, value in
            ScreenshotTextLine(value, confidence: 0.98, x: index == hero ? 0.3 : 0.1,
                y: 0.08 + Double(index) * 0.08, width: index == hero ? 0.4 : 0.7,
                height: index == hero ? 0.07 : 0.035)
        }
        let resolution = ScreenshotFieldResolver().resolve(lines, capturedAt: when, timeZone: zone)
        return (resolution, ScreenshotIntentionalCapture.request(lines: lines, resolution: resolution,
            imageHash: hash, capturedAt: when, timeZone: zone))
    }

    @Test func screenshotResolverRoundTripAndReplay() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        let (resolved, input) = screenshot(["Completed", "-RM 20.00", "To NORTH QUAY BOOKS"],
            hash: "step1-simple", hero: 1)
        #expect(resolved.amount.kind == .decisive && resolved.merchant.kind == .decisive)
        #expect(input.path == "screenshot_intentional_fm" && input.idempotencyKey == "screenshot:step1-simple")
        let saved = try processor.process(input)
        #expect(saved.outcome == .saved)
        #expect(try processor.process(input).outcome == .duplicate)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM transactions") } == 1)
    }

    @Test func screenshotResolverDraftsAndNoEvidence() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        let (ambiguous, amountInput) = screenshot(["Completed", "Subtotal RM 18.00", "Total RM 20.00",
            "To NORTH QUAY BOOKS"], hash: "step1-ambiguous")
        #expect(ambiguous.amount.kind == .ambiguous)
        #expect(amountInput.amountCandidates.count == 2)
        #expect(try processor.process(amountInput).outcome == .draft)
        let (_, missingMerchant) = screenshot(["Completed", "-RM 20.00"], hash: "step1-missing-merchant", hero: 1)
        #expect(try processor.process(missingMerchant).outcome == .draft)
        let (missingAmountResolution, missingAmount) = screenshot(
            ["Completed", "To NORTH QUAY BOOKS"], hash: "step1-missing-amount")
        #expect(missingAmountResolution.amount.kind == .missing)
        #expect(try processor.process(missingAmount).outcome == .draft)
        let (_, weakAmount) = screenshot(["Refund successful", "+RM 20.00", "To NORTH QUAY BOOKS"],
            hash: "step1-incoming", hero: 1)
        #expect(weakAmount.amountTrust == .unresolved)
        #expect(try processor.process(weakAmount).outcome == .draft)
        let none = screenshot(["Share", "Help"], hash: "step1-empty")
        #expect(none.0.noTransactionEvidence)
        try processor.recordCaptureRejection(reason: "no payment found on screen",
            fields: ["ocrStatus": "success"])
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM transactions") } == 4)
    }

    @Test func screenshotStaleDisplayedDateUsesCaptureTimeAndSaves() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        let captured = Instant(iso: "2026-09-29T12:00:00+08:00")!
        let (resolution, input) = screenshot(["Completed", "-RM 20.00", "To NORTH QUAY BOOKS",
            "8 Sep 2026, 3:35 PM"], hash: "step1-old", at: captured, hero: 1)
        let displayed = Instant(iso: "2026-09-08T15:35:00+08:00")!
        #expect(resolution.date.trust == .unresolved)
        #expect(resolution.date.occurredAt == displayed)
        #expect(input.occurredAt == captured)
        let result = try processor.process(input)
        #expect(result.outcome == .saved && !result.unresolved.contains(.date))
        let stored: String? = try db.writer.read { db in
            try String.fetchOne(db, sql: "SELECT occurred_at FROM transactions WHERE id = ?", arguments: [result.recordID])
        }
        #expect(stored == captured.isoUTC)
    }

    @Test func allScreenshotDateEvidenceUsesBackTapTime() throws {
        let captured = Instant(iso: "2026-09-29T21:08:00+08:00")!
        for (label, dateLine) in [
            ("old", "30/07/2026 07:45:57"),
            ("current", "29/09/2026 21:07:00"),
            ("malformed", "31/02/2026 25:99"),
            ("absent", "")
        ] {
            let db = try PaceDatabase()
            let text = ["Completed", "-RM 9.50", "To NORTH QUAY BOOKS"] +
                (dateLine.isEmpty ? [] : [dateLine])
            let (resolution, input) = screenshot(text, hash: "date-\(label)", at: captured, hero: 1)
            #expect(input.occurredAt == captured && input.dateTrust == .trusted)
            #expect(resolution.amount.kind == .decisive && resolution.merchant.kind == .decisive)
            let result = try CaptureProcessor(database: db).process(input)
            #expect(result.outcome == .saved && !result.unresolved.contains(.date))
            let stored: String? = try db.writer.read { db in
                try String.fetchOne(db, sql: "SELECT occurred_at FROM transactions WHERE id = ?",
                    arguments: [result.recordID])
            }
            #expect(stored == captured.isoUTC)
        }
    }

    @Test func duplicateAndTrustReviewNotificationsMatchReviewValues() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        let (_, firstInput) = screenshot(["Completed", "-RM 36.25", "To CORNER MARKET"],
            hash: "review-first", hero: 1)
        let first = try processor.process(firstInput)
        #expect(first.outcome == .saved)
        let (_, secondInput) = screenshot(["Completed", "-RM 36.25", "To CORNER MARKET"],
            hash: "review-second", hero: 1)
        let duplicate = try processor.process(secondInput)
        #expect(duplicate.outcome == .draft && duplicate.reason == "possible duplicate")
        #expect(duplicate.amountMinor == 3625 && duplicate.merchant == "CORNER MARKET")
        let text = CaptureNotificationText.titleAndBody(duplicate, showDetails: true)
        #expect(text.body == "Possible duplicate")
        #expect(!text.body.contains("needed") && !text.body.contains("missing"))
        let review = try #require(CaptureReview.drafts(db).first { $0.id == duplicate.recordID })
        #expect(review.amountMinor == duplicate.amountMinor && review.merchant == duplicate.merchant)

        let (_, missingAmountInput) = screenshot(["Completed", "To ANOTHER SHOP"],
            hash: "missing-amount-notice")
        let missingAmount = try processor.process(missingAmountInput)
        #expect(missingAmount.amountMinor == nil)
        #expect(CaptureNotificationText.titleAndBody(missingAmount, showDetails: true).body == "Amount needed")
        let (_, missingMerchantInput) = screenshot(["Completed", "-RM 21.00"],
            hash: "missing-merchant-notice", hero: 1)
        let missingMerchant = try processor.process(missingMerchantInput)
        #expect(missingMerchant.merchant == nil)
        #expect(CaptureNotificationText.titleAndBody(missingMerchant, showDetails: true).body == "Where was this?")

        let (_, weakInput) = screenshot(["Completed", "-RM 22.00", "To UNCERTAIN SHOP"],
            hash: "trust-review", hero: 1)
        var reviewPolicy = CaptureTrustPolicy(); reviewPolicy.pinnedStage = .observe
        let weak = try processor.process(weakInput, policy: reviewPolicy)
        let weakText = CaptureNotificationText.titleAndBody(weak, showDetails: true)
        #expect(weak.amountMinor != nil && weak.merchant != nil)
        #expect(!weakText.body.contains("needed") && !weakText.body.contains("missing"))

        let prefilledUntrusted = CaptureRequest(source: "screenshot", path: "screenshot_intentional_fm",
            amountMinor: 2_300, merchant: "DIFFERENT SHOP", capturedAt: instant, timeZone: zone,
            idempotencyKey: "screenshot:prefilled-untrusted", amountTrust: .unresolved,
            merchantTrust: .unresolved)
        let prefilled = try processor.process(prefilledUntrusted)
        #expect(prefilled.outcome == .draft && prefilled.unresolved.contains(.amount))
        #expect(prefilled.unresolved.contains(.merchant))
        let prefilledReview = try #require(CaptureReview.drafts(db).first { $0.id == prefilled.recordID })
        #expect(prefilledReview.amountMinor == 2_300 && prefilledReview.merchant == "DIFFERENT SHOP")
        let prefilledNotice = CaptureNotificationText.titleAndBody(prefilled, showDetails: true)
        #expect(prefilledNotice.body == "Check amount, merchant")
    }

    @Test func saveReplayAndLab() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        let first = try processor.process(request())
        let again = try processor.process(request())
        #expect(first.outcome == .saved)
        #expect(again.outcome == .duplicate && again.recordID == first.recordID)
        #expect(try processor.process(request(amount: 1_300)).outcome == .blocked)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM transactions") } == 1)
        let log = try processor.recentLog()
        #expect(log.count == 3 && log[1].outcome == "duplicate" && log[2].reason.contains("trusted"))
        #expect(log[2].merchantResolution == "exact_alias:seed")
        // Without Debug raw diagnostics, only the bounded Capture Feedback evidence is retained.
        let retained = try JSON.decode([String: String].self, try #require(log[2].rawFields))
        #expect(Array(retained.keys) == ["captureFeedbackEvidenceJSON"])
        try processor.markNotification(recordID: first.recordID!, status: "scheduled", at: instant.date)
        #expect(try processor.recentLog()[2].notificationStatus == "scheduled")
        let detailed = CaptureNotificationText.titleAndBody(first, showDetails: true)
        #expect(detailed.title == "Saved · RM 12.50 · ZUS Coffee" && detailed.body == "Food & Drink")
        let privateText = CaptureNotificationText.titleAndBody(first, showDetails: false)
        #expect(privateText.title == "Transaction saved in Pace" && privateText.body.isEmpty)
    }

    @Test func draftPersistsAndKeepsMemory() throws {
        let url = temporaryDirectory().appendingPathComponent("capture.sqlite")
        let first = try PaceDatabase(url: url)
        let result = try CaptureProcessor(database: first).process(request(amount: nil))
        #expect(result.outcome == .draft && result.unresolved.contains(.amount))
        let reopened = try PaceDatabase(url: url)
        let row = try reopened.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM transactions WHERE id = ?", arguments: [result.recordID])!
        }
        #expect(row["status"] as String == "draft")
        #expect(row["amount_minor"] as Int? == nil)
        #expect(row["merchant_text"] as String? == "ZUS Coffee")
        #expect(row["category_id"] as String? == "food-drink")
        #expect(try reopened.writer.read { try Queries.history($0, HistoryQuery()) }.isEmpty)
        let detail = CaptureNotificationText.titleAndBody(result, showDetails: true)
        #expect(detail.title == "You just paid at ZUS Coffee" && detail.body == "Amount needed")
        let generic = CaptureNotificationText.titleAndBody(result, showDetails: false)
        #expect(generic.title == "Transaction needs attention in Pace" && generic.body.isEmpty)
    }

    @Test func missingMerchantAndNoGuessLearning() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        let missing = try processor.process(request(merchant: nil, key: "missing"))
        #expect(missing.outcome == .draft && missing.unresolved.contains(.merchant))
        #expect(CaptureNotificationText.titleAndBody(missing, showDetails: true).body == "Where was this?")
        #expect(try processor.process(request(merchant: "UNSEEN SHOP", key: "unknown")).outcome == .draft)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM merchants WHERE canonical_key = 'unseen shop'") } == 0)
    }

    @Test func ocrCounterpartyFallbackDoesNotTeachMerchantMemory() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        let observations = ["Completed", "-RM 53.00", "To NORTH QUAY BOOKS"].enumerated().map { index, text in
            ScreenshotTextLine(text, confidence: 0.98, x: 0.1, y: 0.1 + Double(index) * 0.1,
                               width: 0.7, height: index == 1 ? 0.07 : 0.035)
        }
        let input = ScreenshotIntentionalCapture.request(lines: observations,
            resolution: ScreenshotFieldResolver().resolve(observations, capturedAt: instant, timeZone: zone),
            imageHash: "fallback-no-learning", capturedAt: instant, timeZone: zone)
        #expect(input.merchant == "NORTH QUAY BOOKS")
        #expect(input.rawFields["merchantSelectionSource"] == "ocr")
        let result = try processor.process(input)
        #expect(result.outcome == .saved)
        #expect(result.merchant == "NORTH QUAY BOOKS")
        #expect(try db.writer.read { try Int.fetchOne($0,
            sql: "SELECT count(*) FROM merchants WHERE canonical_key = 'north quay books'") } == 0)
        #expect(try db.writer.read { try Int.fetchOne($0,
            sql: "SELECT count(*) FROM merchant_aliases WHERE alias_key = 'north quay books'") } == 0)
    }

    @Test func nearDuplicateButSeparateLaterPurchase() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        let saved = try processor.process(request())
        let near = try processor.process(request(offset: 60, key: "near"))
        let later = try processor.process(request(offset: 3_600, key: "later"))
        #expect(near.outcome == .draft && near.duplicateMatchID == saved.recordID)
        #expect(later.outcome == .saved)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM transactions WHERE status = 'confirmed'") } == 2)
    }

    @Test func walletDoubleAutomationReplaysWithinTriggerMinute() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        let first = WalletCaptureAdapter.request(amount: "RM 12.50", merchant: "ZUS COFFEE",
            cardOrPass: "card text", name: nil, shortcutInput: nil,
            capturedAt: instant, timeZone: zone)
        let repeated = WalletCaptureAdapter.request(amount: "RM 12.50", merchant: "ZUS COFFEE",
            cardOrPass: "card text", name: nil, shortcutInput: "extra diagnostic input",
            capturedAt: Instant(seconds: instant.seconds + 5), timeZone: zone)
        #expect(first.idempotencyKey == repeated.idempotencyKey)
        #expect(try processor.process(first, retainRawDiagnostics: true).outcome == .saved)
        #expect(try processor.recentLog()[0].rawFields?.contains("card text") == true)
        #expect(try processor.process(repeated).outcome == .duplicate)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM transactions WHERE status = 'confirmed'") } == 1)
    }

    @Test func explicitReferenceReplaysAcrossInvocationMinutes() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        let first = WalletCaptureAdapter.request(amount: "RM 12.50", merchant: "ZUS COFFEE",
            cardOrPass: "card", name: nil, shortcutInput: nil, reference: "TX-123",
            capturedAt: instant, timeZone: zone)
        let repeated = WalletCaptureAdapter.request(amount: "RM 12.50", merchant: "ZUS COFFEE",
            cardOrPass: "card", name: nil, shortcutInput: nil, reference: "TX-123",
            capturedAt: Instant(seconds: instant.seconds + 3_600), timeZone: zone)
        #expect(first.idempotencyKey == repeated.idempotencyKey)
        #expect(try processor.process(first).outcome == .saved)
        #expect(try processor.process(repeated).outcome == .duplicate)
    }

    @Test func configurableAnomaly() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        var policy = CaptureTrustPolicy(); policy.testingCeilingMinor = 1_000
        let high = try processor.process(request(), policy: policy)
        #expect(high.outcome == .draft && high.reason.contains("ceiling"))
        policy.testingCeilingMinor = 2_000
        #expect(try processor.process(request(key: "other"), policy: policy).outcome == .draft) // prior draft is a near duplicate
        #expect(try processor.process(request(offset: 3_600, key: "later"), policy: policy).outcome == .saved)
    }

    @Test func auditUndoConflict() throws {
        let db = try PaceDatabase(); let saved = try CaptureProcessor(database: db).process(request())
        let executor = LedgerExecutor(database: db)
        let edit = try executor.update(saved.recordID!, TransactionChanges(amountMinor: 2_000))
        #expect(try CaptureProcessor(database: db).recentLog()[0].feedback.contains("amount_minor"))
        #expect(try CaptureProcessor(database: db).process(request()).outcome == .duplicate)
        #expect(throws: LedgerError.undoConflict) { try executor.undo(saved.actionID!) }
        _ = try executor.undo(edit.actionID)
        #expect(try executor.undo(saved.actionID!).transaction.deletedAt != nil)
    }

    @Test func amountCorrectionDemotesWalletPath() throws {
        let db = try PaceDatabase()
        let clock = Date(timeIntervalSince1970: Double(instant.seconds + 20))
        let processor = CaptureProcessor(database: db, now: { clock })
        let saved = try processor.process(request())
        #expect(try processor.pathStates().first?.stage == .assisted)
        _ = try LedgerExecutor(database: db, now: { clock }).update(saved.recordID!,
            TransactionChanges(amountMinor: 2_000))
        let state = try processor.pathStates().first
        #expect(state?.stage == .observe && state?.amountErrors == 1)
        let later = try processor.process(request(offset: 3_600, key: "after-correction"))
        #expect(later.outcome == .draft && later.reason == "path requires review")
    }

    @Test func pinnedAutomaticMediumKeepsPendingCategory() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        var policy = CaptureTrustPolicy(); policy.pinnedStage = .automatic
        let result = try processor.process(request(merchant: "UNSEEN SHOP", key: "medium"), policy: policy)
        #expect(result.outcome == .saved && result.categoryPending)
        let row = try db.writer.read { try Row.fetchOne($0, sql: "SELECT category_pending, category_id FROM transactions WHERE id = ?", arguments: [result.recordID])! }
        #expect(row["category_pending"] as Int == 1 && row["category_id"] as String == "other")
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM merchants WHERE canonical_key = 'unseen shop'") } == 0)
    }

    @Test func failedWriteIsAtomicAndExplainedInLab() throws {
        let db = try PaceDatabase()
        try db.writer.write { connection in
            try connection.execute(sql: """
                CREATE TRIGGER deny_wallet BEFORE INSERT ON transactions WHEN NEW.source = 'wallet'
                BEGIN SELECT RAISE(ABORT, 'simulated wallet failure'); END
                """)
        }
        let processor = CaptureProcessor(database: db)
        let result = try processor.process(request())
        #expect(result.outcome == .failed)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM transactions") } == 0)
        #expect(try processor.recentLog()[0].reason.contains("simulated wallet failure"))
    }

    @Test func probeMissingFieldsAndMalformedInput() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        var invalid = request(); invalid.source = "bank_private_api"
        #expect(try processor.process(invalid).outcome == .blocked)
        #expect(try processor.recentLog()[0].reason == "malformed or unsupported input")
        let empty = WalletCaptureAdapter.request(amount: nil, merchant: nil, cardOrPass: nil, name: nil,
                                                 shortcutInput: nil, capturedAt: instant, timeZone: zone)
        #expect(empty.amountMinor == nil && empty.merchant == nil && empty.rawFields.isEmpty)
        #expect(try processor.process(empty).outcome == .draft)
        #expect(WalletCaptureAdapter.parseAmount("RM 1,234.50") == 123_450)
        #expect(WalletCaptureAdapter.parseAmount("RM 1.234,50") == 123_450)
        #expect(WalletCaptureAdapter.parseAmount("RM 12,50") == 1_250)
        #expect(WalletCaptureAdapter.parseAmount("USD 12.50") == nil)
        let unverified = WalletCaptureAdapter().adapt(.init(amount: "12.50", name: "ZUS COFFEE",
            additionalValues: ["additional1": "raw optional value"]),
            capturedAt: instant, timeZone: zone)
        #expect(unverified.amountMinor == 1_250 && unverified.amountTrust == .unresolved)
        #expect(unverified.merchant == nil && unverified.rawFields["name"] == "ZUS COFFEE")
        #expect(unverified.rawFields["additional1"] == "raw optional value")
    }

    @Test func v1MigrationPreservesLedgerAndUndo() throws {
        let url = temporaryDirectory().appendingPathComponent("v1.sqlite")
        let db = try PaceDatabase(url: url)
        let ledger = LedgerExecutor(database: db)
        let oldDraft = TransactionDraft(type: .expense, amountMinor: 1_250,
            occurredAt: instant, tzIdentifier: zone, localDate: LocalDate(iso: "2026-09-27")!,
            merchantText: "ZUS Coffee", categoryID: "food-drink", source: .keypad)
        let old = try ledger.create(oldDraft, requestID: "before-m1")
        // Recreate the pre-M1 transaction shape while retaining its real audit row.
        try db.writer.write { connection in
            try connection.execute(sql: """
                CREATE TABLE transactions_v1_fixture (
                    id TEXT PRIMARY KEY, type TEXT NOT NULL CHECK (type IN ('expense','income','refund','contribution')),
                    amount_minor INTEGER NOT NULL CHECK (amount_minor > 0 AND amount_minor <= 10000000000),
                    currency TEXT NOT NULL DEFAULT 'MYR' CHECK (currency = 'MYR'),
                    occurred_at TEXT NOT NULL, tz_identifier TEXT NOT NULL, local_date TEXT NOT NULL,
                    merchant_id TEXT REFERENCES merchants(id), merchant_text TEXT,
                    category_id TEXT REFERENCES categories(id), goal_id TEXT, note TEXT,
                    source TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'confirmed',
                    recurring_rule_id TEXT REFERENCES recurring_rules(id), occurrence_date TEXT,
                    origin_text TEXT, one_off INTEGER NOT NULL DEFAULT 0,
                    request_id TEXT UNIQUE, created_at TEXT NOT NULL, updated_at TEXT, deleted_at TEXT,
                    CHECK ((type = 'contribution') = (category_id IS NULL)),
                    CHECK (goal_id IS NULL OR type = 'contribution'),
                    CHECK ((recurring_rule_id IS NULL) = (occurrence_date IS NULL)),
                    UNIQUE (recurring_rule_id, occurrence_date)
                )
                """)
            let columns = "id,type,amount_minor,currency,occurred_at,tz_identifier,local_date,merchant_id,merchant_text,category_id,goal_id,note,source,status,recurring_rule_id,occurrence_date,origin_text,one_off,request_id,created_at,updated_at,deleted_at"
            try connection.execute(sql: "INSERT INTO transactions_v1_fixture (\(columns)) SELECT \(columns) FROM transactions")
            try connection.execute(sql: "DROP TABLE transactions")
            try connection.execute(sql: "ALTER TABLE transactions_v1_fixture RENAME TO transactions")
            try connection.execute(sql: "DROP TABLE capture_outcomes")
            try connection.execute(sql: "DROP TABLE capture_feedback")
            try connection.execute(sql: "DROP TABLE capture_path_state")
            try connection.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2_capture'")
        }
        let migrated = try PaceDatabase(url: url)
        #expect(migrated.schemaVersion == "v2_capture")
        #expect(try migrated.writer.read { try Queries.transaction($0, id: old.transaction.id)?.amountMinor } == 1_250)
        #expect(try LedgerExecutor(database: migrated).create(oldDraft, requestID: "before-m1").duplicate)
        #expect(try LedgerExecutor(database: migrated).undo(old.actionID).transaction.deletedAt != nil)
    }
}

@Suite("Screenshot M2 store integration")
struct ScreenshotCaptureStoreTests {
    let instant = Instant(iso: "2026-09-27T04:00:00+00:00")!
    let zone = "Asia/Kuala_Lumpur"

    func request(_ texts: [String], hash: String = "image-one", offset: Int64 = 0) -> CaptureRequest {
        let captureTime = Instant(seconds: instant.seconds + offset)
        let lines = texts.enumerated().map { index, text in
            ScreenshotTextLine(text, confidence: 0.98, y: Double(index) * 0.06)
        }
        let interpretation = ScreenshotInterpreter().interpret(lines, capturedAt: captureTime, timeZone: zone)
        return ScreenshotCaptureAdapter().adapt((interpretation, hash), capturedAt: captureTime, timeZone: zone)
    }

    let known = ["Payment successful", "RM 12.50", "Paid to ZUS COFFEE"]

    @Test func observeDraftPreservesMemoryAndSurvivesReopen() throws {
        let url = temporaryDirectory().appendingPathComponent("screenshot.sqlite")
        let db = try PaceDatabase(url: url)
        let result = try CaptureProcessor(database: db).process(request(known),
            retainRawDiagnostics: true, diagnostics: ["ocrStatus": "success", "parser": "generic"])
        #expect(result.outcome == .draft && result.reason == "path requires review")
        let reopened = try PaceDatabase(url: url)
        let row = try reopened.writer.read { try Row.fetchOne($0, sql: "SELECT * FROM transactions WHERE id = ?", arguments: [result.recordID])! }
        #expect(row["amount_minor"] as Int == 1_250)
        #expect(row["merchant_text"] as String == "ZUS Coffee")
        #expect(row["category_id"] as String == "food-drink")
        #expect(row["status"] as String == "draft")
        #expect(try reopened.writer.read { try Queries.history($0, HistoryQuery()) }.isEmpty)
        let log = try CaptureProcessor(database: reopened).recentLog()[0]
        #expect(log.source == "screenshot" && log.path == "screenshot_generic")
        #expect(log.rawFields?.contains("ocrStatus") == true && log.merchantResolution == "exact_alias:seed")
    }

    @Test func assistedHighSaveReplayAndUndo() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        var policy = CaptureTrustPolicy(); policy.pinnedStage = .assisted
        let first = try processor.process(request(known), policy: policy)
        let replay = try processor.process(request(known, offset: 3_600), policy: policy)
        let alteredOCRReplay = try processor.process(request(["Payment successful", "RM 12.50", "Paid to ZUS Coffee"], offset: 7_200), policy: policy)
        #expect(first.outcome == .saved && replay.outcome == .duplicate)
        #expect(alteredOCRReplay.outcome == .duplicate)
        #expect(replay.recordID == first.recordID)
        try processor.markReplayNotification(recordID: first.recordID!, status: "scheduled", at: instant.date)
        #expect(try processor.recentLog()[0].notificationStatus == "scheduled")
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM transactions WHERE status = 'confirmed'") } == 1)
        let executor = LedgerExecutor(database: db)
        let edit = try executor.update(first.recordID!, TransactionChanges(amountMinor: 2_000))
        #expect(throws: LedgerError.undoConflict) { try executor.undo(first.actionID!) }
        _ = try executor.undo(edit.actionID)
        #expect(try executor.undo(first.actionID!).transaction.deletedAt != nil)
    }

    @Test func missingFieldsAndAmbiguityBecomeDrafts() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        var policy = CaptureTrustPolicy(); policy.pinnedStage = .assisted
        let amountOnly = try processor.process(request(["Payment successful", "RM 12.50"], hash: "amount"), policy: policy)
        #expect(amountOnly.outcome == .draft && amountOnly.unresolved.contains(.merchant))
        let merchantOnly = try processor.process(request(["Payment successful", "Paid to ZUS COFFEE"], hash: "merchant"), policy: policy)
        #expect(merchantOnly.outcome == .draft && merchantOnly.unresolved.contains(.amount))
        let ambiguous = try processor.process(request(["Payment successful", "RM 12.50", "RM 13.50", "Paid to ZUS COFFEE"], hash: "ambiguous"), policy: policy)
        #expect(ambiguous.outcome == .draft && ambiguous.unresolved.contains(.amount))
        let stored = try db.writer.read { try String.fetchOne($0, sql: "SELECT amount_candidates FROM transactions WHERE id = ?", arguments: [ambiguous.recordID]) }
        #expect(stored?.contains("RM 12.50") == true && stored?.contains("RM 13.50") == true)
    }

    @Test func newMerchantDoesNotTeachMemory() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        var policy = CaptureTrustPolicy(); policy.pinnedStage = .assisted
        let result = try processor.process(request(["Payment successful", "RM 12.50", "Paid to NEW MERCHANT"], hash: "new"), policy: policy)
        #expect(result.outcome == .draft)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM merchants WHERE canonical_key = 'new merchant'") } == 0)
    }

    @Test func distinctLaterPurchaseIsNotMerged() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        var policy = CaptureTrustPolicy(); policy.pinnedStage = .assisted
        #expect(try processor.process(request(known), policy: policy).outcome == .saved)
        #expect(try processor.process(request(known, hash: "later-image", offset: 3_600), policy: policy).outcome == .saved)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM transactions WHERE status = 'confirmed'") } == 2)
    }

    @Test func referenceFromChangedImageTriggersDuplicateReview() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        var policy = CaptureTrustPolicy(); policy.pinnedStage = .assisted
        let withReference = known + ["Reference: ABC123456"]
        let first = try processor.process(request(withReference), policy: policy)
        let changed = try processor.process(request(withReference, hash: "animation-changed", offset: 60), policy: policy)
        #expect(first.outcome == .saved && changed.outcome == .draft)
        #expect(changed.duplicateMatchID == first.recordID)
    }

    @Test func nonPaymentDiagnosticNeverWritesLedger() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        let id = try processor.recordCaptureRejection(reason: "no payment found on screen",
            fields: ["paymentScreen": "notPayment"], diagnostics: ["ocrStatus": "success"],
            retainDiagnostics: true)
        try processor.markOutcomeNotification(outcomeID: id, status: "scheduled", at: instant.date)
        let entry = try processor.recentLog()[0]
        #expect(entry.source == "screenshot" && entry.outcome == "blocked")
        #expect(entry.reason == "no payment found on screen" && entry.notificationStatus == "scheduled")
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM transactions") } == 0)
    }

    @Test func failedStatusAndStaleScreenshotCannotSave() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        var policy = CaptureTrustPolicy(); policy.pinnedStage = .automatic
        let pending = try processor.process(request(known + ["Status pending"], hash: "pending"), policy: policy)
        #expect(pending.outcome == .draft && pending.unresolved.contains(.status))
        let old = try processor.process(request(known + ["18/09/2026 12:00"], hash: "old"), policy: policy)
        #expect(old.outcome == .draft && old.unresolved.contains(.date))
    }

    @Test func observedDuitNowFieldsPersistAsScreenshotDraft() throws {
        let db = try PaceDatabase(); let processor = CaptureProcessor(database: db)
        let input = request(["Completed", "-RM 11.35", "To NORTHWIND RESTAURANT",
            "25 Sep 2026, 2:44 PM", "From Ryt Credit", "Reference ID",
            "2609254EE1B9A7U", "Transaction type", "DuitNow QR",
            "Category: Food & Drink", "Recipient reference", "Transfer"], hash: "real-layout")
        let result = try processor.process(input)
        #expect(result.outcome == .draft && result.amountMinor == 1_135)
        let row = try db.writer.read {
            try Row.fetchOne($0, sql: "SELECT * FROM transactions WHERE id = ?", arguments: [result.recordID])!
        }
        #expect(row["merchant_text"] as String == "NORTHWIND RESTAURANT")
        #expect(row["external_reference"] as String == "2609254EE1B9A7U")
        #expect(row["occurred_at"] as String == Instant(iso: "2026-09-25T06:44:00+00:00")!.isoUTC)
        #expect(row["category_id"] as String? == nil)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM merchants WHERE canonical_key = 'NORTHWIND RESTAURANT'") } == 0)
    }
}
