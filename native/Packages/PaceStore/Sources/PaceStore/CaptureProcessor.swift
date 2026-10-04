import CryptoKit
import Foundation
import GRDB
import PaceCore

public enum CaptureOutcome: String, Sendable { case saved, draft, duplicate, blocked, failed }

public struct CaptureResult: Sendable {
    public let outcome: CaptureOutcome
    public let recordID: String?
    public let actionID: String?
    public let reason: String
    public let unresolved: Set<CaptureField>
    public let amountMinor: Int?
    public let merchant: String?
    public let categoryID: String?
    public let categoryName: String?
    public let categoryPending: Bool
    public let duplicateMatchID: String?
}

public enum CaptureNotificationText {
    public static func titleAndBody(_ result: CaptureResult, showDetails: Bool) -> (title: String, body: String) {
        guard showDetails else {
            return result.outcome == .saved ? ("Transaction saved in Pace", "") : ("Transaction needs attention in Pace", "")
        }
        let money = result.amountMinor.map { MoneyFormat(locale: .malaysia).string($0) }
        if result.outcome == .saved {
            return (["Saved", money, result.merchant].compactMap { $0 }.joined(separator: " · "),
                    result.categoryPending ? "Tap to choose a category" : result.categoryName ?? "")
        }
        // `unresolved` describes trust, not whether a value is present in the draft.
        // Anomaly and duplicate reasons take precedence over field guidance.
        if result.duplicateMatchID != nil || result.reason == "possible duplicate" {
            return ("Review capture", "Possible duplicate")
        }
        if result.reason != "path requires review" && !result.reason.hasPrefix("unresolved ") {
            return ("Review capture", result.reason)
        }
        if result.amountMinor == nil, let merchant = result.merchant {
            return ("You just paid at \(merchant)", "Amount needed")
        }
        if result.merchant == nil, let money {
            return ("You just paid \(money)", "Where was this?")
        }
        if result.amountMinor == nil && result.merchant == nil {
            return ("You just paid", "Add the amount and merchant")
        }
        let reviewReason: String
        if result.reason.hasPrefix("unresolved ") {
            reviewReason = "Check " + result.unresolved.map(\.rawValue).sorted().joined(separator: ", ")
        } else if result.reason == "path requires review" {
            reviewReason = "Review captured fields"
        } else {
            reviewReason = result.reason
        }
        return (["Review capture", money, result.merchant].compactMap { $0 }.joined(separator: " · "), reviewReason)
    }
}

public struct CaptureLogEntry: Sendable, Identifiable {
    public let id: String
    public let time: String
    public let source: String
    public let path: String
    public let outcome: String
    public let reason: String
    public let fields: String
    public let rawFields: String?
    public let merchantResolution: String?
    public let duplicateMatchID: String?
    public let anomaly: String?
    public let stage: String
    public let executionContext: String?
    public let elapsedMS: Int?
    public let intentStartedAt: String?
    public let databaseOpenMS: Int?
    public let notificationScheduledAt: String?
    public let notificationStatus: String?
    public let feedback: String
}

public enum CaptureAdapterError: Error { case malformedAmount }

private struct CaptureFingerprint: Encodable {
    let source: String
    let amountMinor: Int?
    let merchant: String?
    let categoryID: String?
    let reference: String?
    let occurredAt: String?
    let rawFields: [String: String]

    init(_ input: CaptureRequest) {
        source = input.source
        // Pixel identity is stronger replay evidence than a second OCR run's text.
        // The same image cannot become a second financial write if OCR differs later.
        if input.source == "screenshot" {
            amountMinor = nil; merchant = nil; categoryID = nil; reference = nil; occurredAt = nil
            rawFields = input.rawFields.filter { $0.key == "imageHash" }
        } else {
            amountMinor = input.amountMinor
            merchant = input.merchant
            categoryID = input.categoryID
            reference = input.reference
            occurredAt = input.occurredAt?.isoUTC
            rawFields = input.source == "wallet"
                ? input.rawFields.filter { ["amount", "merchant", "cardOrPass"].contains($0.key) }
                : input.rawFields
        }
    }
}

/// An App Intent parameter adapter. Only a parameter actually supplied by Shortcuts is populated.
public struct WalletCaptureFields: Sendable {
    public var amount: String?
    public var merchant: String?
    public var cardOrPass: String?
    public var name: String?
    public var shortcutInput: String?
    public var reference: String?
    public var additionalValues: [String: String]
    public init(amount: String? = nil, merchant: String? = nil, cardOrPass: String? = nil,
                name: String? = nil, shortcutInput: String? = nil, reference: String? = nil,
                additionalValues: [String: String] = [:]) {
        self.amount = amount; self.merchant = merchant; self.cardOrPass = cardOrPass
        self.name = name; self.shortcutInput = shortcutInput; self.reference = reference
        self.additionalValues = additionalValues
    }
}

public struct WalletCaptureAdapter: CaptureInputAdapter {
    public init() {}

    public func adapt(_ payload: WalletCaptureFields, capturedAt: Instant, timeZone: String) -> CaptureRequest {
        Self.request(amount: payload.amount, merchant: payload.merchant,
                     cardOrPass: payload.cardOrPass, name: payload.name,
                     shortcutInput: payload.shortcutInput, reference: payload.reference,
                     additionalValues: payload.additionalValues,
                     capturedAt: capturedAt, timeZone: timeZone)
    }

    public static func parseAmount(_ raw: String?) -> Int? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !text.contains("USD"), !text.contains("SGD"), !text.contains("EUR"), !text.contains("REFUND"),
              !text.contains("-") else { return nil }
        text = text.replacingOccurrences(of: "MYR", with: "").replacingOccurrences(of: "RM", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept either decimal separator without guessing an ambiguous amount.
        if text.contains(",") && text.contains(".") {
            if text.lastIndex(of: ",")! > text.lastIndex(of: ".")! {
                text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            }
        } else if let comma = text.lastIndex(of: ","), !text.contains(".") {
            let fractionalDigits = text.distance(from: text.index(after: comma), to: text.endIndex)
            if fractionalDigits <= 2 { text = text.replacingOccurrences(of: ",", with: ".") }
        }
        guard text.range(of: #"^\d{1,3}(,\d{3})*(\.\d{1,2})?$|^\d+(\.\d{1,2})?$"#,
                         options: .regularExpression) != nil else { return nil }
        let parts = text.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false)
        guard let major = Int(parts[0]), major <= 100_000_000 else { return nil }
        let minor = parts.count == 2 ? Int(String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0 : 0
        let value = major * 100 + minor
        return value > 0 && value <= maximumAmountMinor ? value : nil
    }

    public static func request(amount: String?, merchant: String?, cardOrPass: String?, name: String?,
                               shortcutInput: String?, reference: String? = nil,
                               additionalValues: [String: String] = [:],
                               capturedAt: Instant, timeZone: String) -> CaptureRequest {
        var raw = ["amount": amount, "merchant": merchant, "cardOrPass": cardOrPass,
                   "name": name, "shortcutInput": shortcutInput, "reference": reference].compactMapValues { $0 }
        for (key, value) in additionalValues where ["additional1", "additional2", "additional3"].contains(key) {
            raw[key] = value
        }
        // "Name" is probe-only until device test B establishes what that variable means.
        let merchantText = merchant?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let amountMinor = parseAmount(amount)
        let explicitMYR = amount?.uppercased().contains("RM") == true || amount?.uppercased().contains("MYR") == true
        // The invocation minute is the strongest repeat evidence available until device test B
        // establishes whether Shortcuts offers a stable transaction reference.
        let minute = capturedAt.seconds / 60
        let keyParts = reference?.isEmpty == false ? ["reference", reference!] :
            ["fields", merchant ?? "", amount ?? "", cardOrPass ?? "", String(minute)]
        let key = SHA256.hash(data: Data(keyParts.joined(separator: "\u{1f}").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return CaptureRequest(source: "wallet", path: "apple_pay", amountMinor: amountMinor,
                              merchant: merchantText, capturedAt: capturedAt, timeZone: timeZone,
                              reference: reference?.nilIfEmpty, idempotencyKey: "wallet:\(key)", rawFields: raw,
                              amountTrust: amountMinor != nil && explicitMYR ? .trusted : .unresolved,
                              merchantTrust: merchantText == nil ? .unresolved : .usable)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The sole external capture writer. Decisions and writes share one SQLite write transaction,
/// so concurrent intents cannot both pass the duplicate check.
public final class CaptureProcessor: Sendable {
    public let database: PaceDatabase
    private let executor: LedgerExecutor
    private let now: @Sendable () -> Date

    public init(database: PaceDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database; self.executor = LedgerExecutor(database: database, now: now); self.now = now
    }

    public func process(_ input: CaptureRequest, policy: CaptureTrustPolicy = .init(),
                        executionContext: String = "unknown", retainRawDiagnostics: Bool = false,
                        intentStartedAt: Date? = nil, databaseOpenMS: Int? = nil,
                        diagnostics: [String: String] = [:],
                        feedbackEvidence: IntentionalCaptureEvidence? = nil) throws -> CaptureResult {
        let start = now()
        guard ["wallet", "screenshot", "receipt", "text", "dictation", "keypad"].contains(input.source),
              let zone = Zone(identifier: input.timeZone), input.rawFields.values.allSatisfy({ $0.count <= 4_096 }),
              (input.merchant?.count ?? 0) <= 200, (input.reference?.count ?? 0) <= 200,
              (input.idempotencyKey?.count ?? 0) <= 256,
              input.amountMinor == nil || (1...maximumAmountMinor).contains(input.amountMinor!) else {
            try? database.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO capture_outcomes (id, recorded_at, source, capture_path, outcome, reason,
                      fields_json, policy_version, trust_stage, execution_context)
                    VALUES (?, ?, ?, ?, 'blocked', 'malformed or unsupported input', '{}', ?, ?, ?)
                    """, arguments: [UUID().uuidString.lowercased(), Timestamp.string(now()),
                                     String(input.source.prefix(100)), String(input.path.prefix(100)),
                                     policy.version, policy.stage.rawValue, executionContext])
            }
            return .init(outcome: .blocked, recordID: nil, actionID: nil, reason: "malformed or unsupported input",
                         unresolved: [], amountMinor: nil, merchant: nil, categoryID: nil, categoryName: nil,
                         categoryPending: false, duplicateMatchID: nil)
        }
        do {
        return try database.writer.write { db in
            let recordTime = Timestamp.string(now())
            let initialStage: CaptureStage = ["apple_pay", "screenshot_intentional_fm"].contains(input.path) ? .assisted : .observe
            let pathState = try CaptureEvidence.ensure(db, path: input.path, initial: initialStage, stamp: recordTime)
            var effectivePolicy = policy
            effectivePolicy.stage = policy.pinnedStage ?? pathState.stage
            let captureFingerprint = SHA256.hash(data: Data(try JSON.encode(CaptureFingerprint(input)).utf8))
                .map { String(format: "%02x", $0) }.joined()
            let existing = try input.idempotencyKey.flatMap { key in
                try Row.fetchOne(db, sql: "SELECT id, status, capture_fingerprint FROM transactions WHERE dedupe_key = ?", arguments: [key])
            }
            let ocrMemory = input.path == "screenshot_intentional_fm"
                ? try MerchantMemory.resolveAlias(db, name: input.rawFields["ocrMerchantCandidate"]) : nil
            let memory = try ocrMemory ?? MerchantMemory.resolveAlias(db, name: input.merchant)
            let aliasSource = try memory.flatMap { match in
                try String.fetchOne(db, sql: "SELECT source FROM merchant_aliases WHERE id = ?",
                                    arguments: [match.aliasID])
            }
            let suppliedCategory = try (input.categoryTrust == .trusted ||
                (input.path == "screenshot_intentional_fm" && input.categoryTrust == .usable)) ? input.categoryID.flatMap { id in
                try String.fetchOne(db, sql: "SELECT id FROM categories WHERE id = ?", arguments: [id])
            } : nil
            let contextRules = try memory.map { match in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM merchant_context_rules WHERE merchant_id = ?",
                                     arguments: [match.merchantID]) ?? 0
            } ?? 0
            let merchant = CaptureMerchant(id: memory?.merchantID, name: memory?.displayName ?? input.merchant,
                                           categoryID: memory?.categoryID ?? suppliedCategory,
                                           known: memory != nil, categoryTrusted: memory?.categoryID != nil &&
                                               (contextRules == 0 || memory?.method.hasPrefix("context:") == true),
                                           resolution: memory.map { "\($0.method):\(aliasSource ?? "unknown")" } ?? "raw payee")
            let cutoff = Instant(seconds: input.capturedAt.seconds - 90 * 86_400).isoUTC
            let amounts: [Int] = try Int.fetchAll(db, sql: """
                SELECT amount_minor FROM transactions WHERE status = 'confirmed' AND deleted_at IS NULL
                AND type = 'expense' AND occurred_at >= ?
                """, arguments: [cutoff])
            let merchantAmounts: [Int] = try memory.map { match in
                try Int.fetchAll(db, sql: """
                    SELECT amount_minor FROM transactions WHERE status = 'confirmed' AND deleted_at IS NULL
                    AND type = 'expense' AND merchant_id = ?
                    """, arguments: [match.merchantID])
            } ?? []
            var matchID: String?
            if let reference = input.reference, !reference.isEmpty {
                matchID = try String.fetchOne(db, sql: """
                    SELECT id FROM transactions WHERE external_reference = ? AND deleted_at IS NULL LIMIT 1
                    """, arguments: [reference])
            }
            if matchID == nil, let amount = input.amountMinor {
                let lower = Instant(seconds: (input.occurredAt ?? input.capturedAt).seconds - 1_800).isoUTC
                let upper = Instant(seconds: (input.occurredAt ?? input.capturedAt).seconds + 1_800).isoUTC
                let candidates = try Row.fetchAll(db, sql: """
                    SELECT id, merchant_text FROM transactions WHERE amount_minor = ? AND occurred_at BETWEEN ? AND ?
                    AND deleted_at IS NULL ORDER BY occurred_at DESC
                    """, arguments: [amount, lower, upper])
                let key = merchantKey(merchant.name ?? "")
                matchID = candidates.first { row in
                    let other = merchantKey((row["merchant_text"] as String?) ?? "")
                    return key.isEmpty || other.isEmpty || key == other
                }.map { $0["id"] as String }
            }
            let decision = CaptureTrustDecision.decide(input, merchant: merchant,
                history: CaptureHistory(merchantAmounts: merchantAmounts, personalAmounts: amounts),
                duplicateMatchID: matchID, policy: effectivePolicy)
            let fields = try JSON.encode([
                "amountMinor": input.amountMinor.map(String.init) ?? "missing",
                "merchant": merchant.name ?? "missing", "categoryID": merchant.categoryID ?? "missing",
                "capturedAt": input.capturedAt.isoUTC, "occurredAt": (input.occurredAt ?? input.capturedAt).isoUTC,
                "amountTrust": input.amountTrust.rawValue, "merchantTrust": input.merchantTrust.rawValue,
                "resolvedMerchantTrust": memory == nil ? input.merchantTrust.rawValue : "trusted",
                "resolvedCategoryTrust": merchant.categoryTrusted ? "trusted" : merchant.categoryID == nil ? "unresolved" : "usable",
                "dateTrust": input.dateTrust.rawValue, "categoryTrust": input.categoryTrust.rawValue,
                "reference": input.reference ?? "missing",
                "amountCandidates": input.amountCandidates.joined(separator: " | "),
                "unresolved": decision.unresolved.map(\.rawValue).sorted().joined(separator: ",")])
            let categoryName = try merchant.categoryID.flatMap { id in
                try String.fetchOne(db, sql: "SELECT name FROM categories WHERE id = ?", arguments: [id])
            }
            let outcome: CaptureOutcome
            let recordID: String?
            let actionID: String?
            let reason: String
            if let existing {
                if existing["capture_fingerprint"] as String? != captureFingerprint {
                    outcome = .blocked; reason = "idempotency key reused with different fields"
                } else {
                    outcome = .duplicate; reason = "idempotent replay of \(existing["status"] as String)"
                }
                recordID = existing["id"]; actionID = nil
            } else if decision.disposition == .save, let amount = input.amountMinor {
                let date = zone.local(input.occurredAt ?? input.capturedAt).time.date
                let draft = TransactionDraft(type: .expense, amountMinor: amount,
                    occurredAt: input.occurredAt ?? input.capturedAt, tzIdentifier: input.timeZone,
                    localDate: date, merchantID: memory?.merchantID, merchantText: merchant.name,
                    categoryID: merchant.categoryID ?? "other", source: EntrySource(rawValue: input.source)!)
                let fingerprint = SHA256.hash(data: Data(try JSON.encode(draft).utf8))
                    .map { String(format: "%02x", $0) }.joined()
                let result = try executor.createInTransaction(db, draft, requestID: input.idempotencyKey,
                                                               fingerprint: input.idempotencyKey == nil ? nil : fingerprint)
                try db.execute(sql: """
                    UPDATE transactions SET dedupe_key = ?, capture_fingerprint = ?, source_detail = ?, captured_at = ?,
                    category_pending = ?, capture_path = ?, trust_stage_at_capture = ?,
                    external_reference = ? WHERE id = ?
                    """, arguments: [input.idempotencyKey, captureFingerprint, input.source, input.capturedAt.isoUTC,
                                     decision.categoryPending ? 1 : 0, input.path, effectivePolicy.stage.rawValue,
                                     input.reference, result.transaction.id])
                // The create audit must include capture metadata so its Undo checks the
                // exact committed snapshot, including fields written by this processor.
                let finalSnapshot = try db.snapshot("transactions", id: result.transaction.id)
                try db.execute(sql: "UPDATE action_log SET after_json = ? WHERE id = ?",
                               arguments: [try finalSnapshot.map(JSON.encode), result.actionID])
                outcome = .saved; recordID = result.transaction.id; actionID = result.actionID
                reason = decision.reason
            } else {
                let id = UUID().uuidString.lowercased()
                let date = zone.local(input.occurredAt ?? input.capturedAt).time.date
                try db.execute(sql: """
                    INSERT INTO transactions (id, type, amount_minor, occurred_at, tz_identifier, local_date,
                      merchant_id, merchant_text, category_id, source, status, request_id, created_at,
                      field_confidence, amount_candidates, captured_at, source_detail, dedupe_key, capture_fingerprint, seen_at, status_flag,
                      capture_path, trust_stage_at_capture, external_reference)
                    VALUES (?, 'expense', ?, ?, ?, ?, ?, ?, ?, ?, 'draft', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [id, input.amountMinor, (input.occurredAt ?? input.capturedAt).isoUTC,
                                     input.timeZone, date.iso, memory?.merchantID, merchant.name,
                                     merchant.categoryID, input.source, input.idempotencyKey,
                                     recordTime, fields, try JSON.encode(input.amountCandidates), input.capturedAt.isoUTC, input.source,
                                     input.idempotencyKey, captureFingerprint, recordTime, decision.reason, input.path,
                                     effectivePolicy.stage.rawValue, input.reference])
                let after = try db.snapshot("transactions", id: id)
                actionID = try executor.log(db, kind: "create_capture_draft", target: id, before: nil, after: after)
                outcome = .draft; recordID = id; reason = decision.reason
            }
            if outcome == .saved || outcome == .draft {
                try CaptureEvidence.incrementCapture(db, path: input.path, stamp: recordTime)
            }
            var retainedFields = retainRawDiagnostics ? input.rawFields.merging(diagnostics) { _, extra in extra } : [:]
            if input.path == "screenshot_intentional_fm", let feedbackEvidence,
               outcome == .saved || outcome == .draft {
                retainedFields["captureFeedbackEvidenceJSON"] = try JSON.encode(feedbackEvidence)
            }
            // Apple Pay feedback evidence is recorded after the decision and write; it is never read
            // back into capture, M1 or Merchant Memory.
            if input.path == "apple_pay", outcome == .saved || outcome == .draft {
                retainedFields["captureFeedbackEvidenceJSON"] = try JSON.encode(ApplePayCaptureEvidence(input,
                    merchantResolution: merchant.resolution, memoryCategoryID: memory?.categoryID,
                    memoryCategoryTrusted: merchant.categoryTrusted, categoryPending: decision.categoryPending,
                    finalCategoryID: outcome == .saved ? merchant.categoryID ?? "other" : merchant.categoryID,
                    outcome: outcome, executionContext: executionContext,
                    trustStage: effectivePolicy.stage.rawValue))
            }
            try db.execute(sql: """
                INSERT INTO capture_outcomes (id, recorded_at, source, capture_path, outcome, reason,
                  transaction_id, action_id, fields_json, raw_fields_json, merchant_resolution,
                  duplicate_match_id, anomaly_json, policy_version, trust_stage, execution_context, elapsed_ms,
                  intent_started_at, database_open_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString.lowercased(), recordTime, input.source, input.path,
                                 outcome.rawValue, reason, recordID, actionID, fields,
                                 retainedFields.isEmpty ? nil : try JSON.encode(retainedFields),
                                 merchant.resolution, matchID,
                                 try JSON.encode(decision.anomalySignals), policy.version, effectivePolicy.stage.rawValue,
                                 executionContext, Int(now().timeIntervalSince(start) * 1_000),
                                 intentStartedAt.map(Timestamp.string), databaseOpenMS])
            if input.path == "screenshot_intentional_fm" {
                try db.execute(sql: """
                    UPDATE capture_outcomes SET raw_fields_json = NULL
                    WHERE capture_path = 'screenshot_intentional_fm' AND raw_fields_json IS NOT NULL
                      AND id NOT IN (SELECT id FROM capture_outcomes
                        WHERE capture_path = 'screenshot_intentional_fm' AND raw_fields_json IS NOT NULL
                        ORDER BY rowid DESC LIMIT 200)
                    """)
            }
            if input.path == "apple_pay" {
                try Self.pruneApplePayFeedback(db)
            }
            return CaptureResult(outcome: outcome, recordID: recordID, actionID: actionID,
                                 reason: reason, unresolved: decision.unresolved, amountMinor: input.amountMinor,
                                 merchant: merchant.name, categoryID: merchant.categoryID, categoryName: categoryName,
                                 categoryPending: decision.categoryPending, duplicateMatchID: matchID)
        }
        } catch {
            let reason = "capture write failed: \(error.localizedDescription)"
            try? recordActionFailure(recordID: nil, reason: reason, source: input.source, path: input.path)
            return CaptureResult(outcome: .failed, recordID: nil, actionID: nil, reason: reason,
                                 unresolved: [], amountMinor: input.amountMinor, merchant: input.merchant,
                                 categoryID: nil, categoryName: nil, categoryPending: false, duplicateMatchID: nil)
        }
    }

    /// Keeps the newest 200 Apple Pay feedback payloads. Unlike the screenshot path, other
    /// retained Debug diagnostics on these rows are left in place.
    private static func pruneApplePayFeedback(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, raw_fields_json FROM capture_outcomes
            WHERE capture_path = 'apple_pay' AND raw_fields_json LIKE '%"captureFeedbackEvidenceJSON"%'
            ORDER BY rowid DESC LIMIT -1 OFFSET 200
            """)
        for row in rows {
            var fields = try JSON.decode([String: String].self, row["raw_fields_json"] as String)
            for key in ["captureFeedbackEvidenceJSON", "captureFeedbackReportedIssue",
                        "captureFeedbackUserNote", "captureFeedbackArchivedRecordJSON"] {
                fields.removeValue(forKey: key)
            }
            try db.execute(sql: "UPDATE capture_outcomes SET raw_fields_json = ? WHERE id = ?",
                arguments: [fields.isEmpty ? nil : try JSON.encode(fields), row["id"] as String])
        }
    }

    public func recordActionFailure(recordID: String?, reason: String,
                                    source: String = "notification", path: String = "notification") throws {
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO capture_outcomes (id, recorded_at, source, capture_path, outcome, reason,
                  transaction_id, fields_json, policy_version, trust_stage)
                VALUES (?, ?, ?, ?, 'failed', ?, ?, '{}', 1, 'observe')
                """, arguments: [UUID().uuidString.lowercased(), Timestamp.string(now()), source,
                                 path, String(reason.prefix(500)), recordID])
        }
    }

    /// Diagnostics for a screenshot that never reaches the financial writer, such as an
    /// unrelated screen or unreadable image. It cannot create a ledger transaction.
    @discardableResult
    public func recordCaptureRejection(reason: String, outcome: CaptureOutcome = .blocked,
                                       fields: [String: String] = [:], diagnostics: [String: String] = [:],
                                       executionContext: String = "unknown", retainDiagnostics: Bool = false,
                                       intentStartedAt: Date? = nil, databaseOpenMS: Int? = nil) throws -> String {
        let id = UUID().uuidString.lowercased()
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO capture_outcomes (id, recorded_at, source, capture_path, outcome, reason,
                  fields_json, raw_fields_json, policy_version, trust_stage, execution_context,
                  intent_started_at, database_open_ms)
                VALUES (?, ?, 'screenshot', 'screenshot_generic', ?, ?, ?, ?, 1, 'observe', ?, ?, ?)
                """, arguments: [id, Timestamp.string(now()), outcome.rawValue, String(reason.prefix(500)),
                                 try JSON.encode(fields), retainDiagnostics ? try JSON.encode(diagnostics) : nil,
                                 executionContext, intentStartedAt.map(Timestamp.string), databaseOpenMS])
        }
        return id
    }

    public func markOutcomeNotification(outcomeID: String, status: String, at: Date) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                UPDATE capture_outcomes SET notification_scheduled_at = ?, notification_status = ? WHERE id = ?
                """, arguments: [Timestamp.string(at), String(status.prefix(100)), outcomeID])
        }
    }

    public func markReplayNotification(recordID: String, status: String, at: Date) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                UPDATE capture_outcomes SET notification_scheduled_at = ?, notification_status = ?
                WHERE id = (SELECT id FROM capture_outcomes WHERE transaction_id = ?
                  AND outcome = 'duplicate' ORDER BY rowid DESC LIMIT 1)
                """, arguments: [Timestamp.string(at), String(status.prefix(100)), recordID])
        }
    }

    public func markNotification(recordID: String, status: String, at: Date) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                UPDATE capture_outcomes SET notification_scheduled_at = ?, notification_status = ?
                WHERE id = (SELECT id FROM capture_outcomes WHERE transaction_id = ?
                  AND outcome IN ('saved', 'draft') ORDER BY rowid DESC LIMIT 1)
                """, arguments: [Timestamp.string(at), String(status.prefix(100)), recordID])
        }
    }

    public func recentLog(limit: Int = 100) throws -> [CaptureLogEntry] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM capture_outcomes ORDER BY rowid DESC LIMIT ?", arguments: [limit])
                .map { row in
                    let recordID: String? = row["transaction_id"]
                    let actions = try recordID.map { id in
                        try Row.fetchAll(db, sql: """
                            SELECT kind, before_json, after_json FROM action_log
                            WHERE target_id = ? AND kind IN ('update_transaction', 'undo') ORDER BY rowid
                            """, arguments: [id])
                    } ?? []
                    let feedback = try actions.map { action -> String in
                        let before = try (action["before_json"] as String?).map { try JSON.decode(Snapshot.self, $0) }
                        let after = try (action["after_json"] as String?).map { try JSON.decode(Snapshot.self, $0) }
                        let fields = ["amount_minor", "merchant_text", "category_id", "deleted_at"]
                            .filter { before?[$0] != after?[$0] }
                        return "\(action["kind"] as String): \(fields.joined(separator: ", "))"
                    }.joined(separator: "; ")
                    return CaptureLogEntry(id: row["id"], time: row["recorded_at"], source: row["source"],
                    path: row["capture_path"], outcome: row["outcome"], reason: row["reason"],
                    fields: row["fields_json"], rawFields: row["raw_fields_json"],
                    merchantResolution: row["merchant_resolution"], duplicateMatchID: row["duplicate_match_id"],
                    anomaly: row["anomaly_json"], stage: row["trust_stage"],
                    executionContext: row["execution_context"], elapsedMS: row["elapsed_ms"],
                    intentStartedAt: row["intent_started_at"], databaseOpenMS: row["database_open_ms"],
                    notificationScheduledAt: row["notification_scheduled_at"],
                    notificationStatus: row["notification_status"],
                    feedback: feedback)
                }
        }
    }
}
