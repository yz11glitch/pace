import Foundation
import GRDB
import PaceCore

/// A duplicate can point to another unsaved draft, whose amount may be null.
/// Keep that distinction rather than decoding it as a saved ledger transaction.
public struct CaptureDuplicateMatch: Identifiable, Equatable, Sendable {
    public let id: String
    public let amountMinor: Int?
    public let merchant: String?
    public let categoryName: String?
    public let occurredAt: String
    public let source: CaptureSource
    public let status: String
    public var isCaptured = true
    public var type = TransactionType.expense
    public var note: String? = nil
    public var captureSource: CaptureSource? { isCaptured ? source : nil }
    public var title: String { StoredTransaction.consumerTitle(merchant: merchant, note: note, source: captureSource, category: categoryName, type: type) }

    static func fetch(_ db: Database, id: String) throws -> CaptureDuplicateMatch? {
        try Row.fetchOne(db, sql: StoredTransaction.select + " WHERE t.id = ? AND t.deleted_at IS NULL",
                         arguments: [id]).map { row in
            CaptureDuplicateMatch(id: row["id"], amountMinor: row["amount_minor"], merchant: row["merchant_text"],
                categoryName: row["category_name"], occurredAt: row["occurred_at"],
                source: CaptureSource(source: row["source"], path: row["capture_path"]), status: row["status"],
                isCaptured: ["wallet", "screenshot"].contains(row["source"] as String),
                type: TransactionType(rawValue: row["type"]) ?? .expense, note: row["note"])
        }
    }
}

public struct CaptureReviewDraft: Identifiable, Equatable, Sendable {
    public let id: String
    public let amountMinor: Int?
    public let merchant: String?
    public let categoryID: String?
    public let capturedAt: String?
    public let createdAt: String
    public let occurredAt: String
    public let source: CaptureSource
    public let capturePath: String?
    public let categoryName: String?
    public let categoryPending: Bool
    public let unresolved: Set<CaptureField>
    public let fieldTrust: [CaptureField: CaptureFieldTrust]
    /// Grounded strings exactly as persisted. Candidate amounts/labels are not inferred.
    public let amountCandidates: [String]
    public let anomalySignals: [CaptureAnomaly]
    public let duplicateMatchID: String?
    /// Nil when the matched row is deleted or missing. Status distinguishes saved/draft.
    public let duplicateMatch: CaptureDuplicateMatch?
    /// The engine persists the ID, but not which matching rule selected it.
    public let duplicateBasis: DuplicateBasis
    public let feedbackIssue: CaptureFeedbackIssue?
    public var tzIdentifier: String? = nil

    public enum DuplicateBasis: Equatable, Sendable { case notRecorded }

    public var title: String {
        let name = merchant?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name! : source.fallbackTitle
    }

    public var attentionReason: CaptureAttentionReason {
        if duplicateMatch != nil { return .duplicate }
        if amountMinor == nil || unresolved.contains(.amount) ||
            anomalySignals.contains(where: \.needsAmountCheck) { return .amount }
        if unresolved.contains(.merchant) || merchant?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return .merchant }
        if unresolved.contains(.category) || categoryPending { return .category }
        if unresolved.contains(.date) { return .date }
        if unresolved.contains(.status) { return .status }
        return .payment
    }
}

public enum CaptureReview {
    public static func drafts(_ database: PaceDatabase) throws -> [CaptureReviewDraft] {
        try database.writer.read { db in
            try drafts(db)
        }
    }

    static func drafts(_ db: Database) throws -> [CaptureReviewDraft] {
        try Row.fetchAll(db, sql: """
            SELECT t.*, c.name AS category_name, o.fields_json, o.anomaly_json, o.duplicate_match_id
            FROM transactions t LEFT JOIN categories c ON c.id = t.category_id
            LEFT JOIN capture_outcomes o ON o.id = (
              SELECT id FROM capture_outcomes WHERE transaction_id = t.id AND outcome = 'draft'
              ORDER BY rowid ASC LIMIT 1)
            WHERE t.status = 'draft' AND t.deleted_at IS NULL
            ORDER BY t.created_at DESC, t.id
            """).map { row in
                let id: String = row["id"]
                let fields = try ((row["fields_json"] as String?) ?? (row["field_confidence"] as String?))
                    .map { try JSON.decode([String: String].self, $0) } ?? [:]
                let unresolved = Set((fields["unresolved"] ?? "").split(separator: ",")
                    .compactMap { CaptureField(rawValue: String($0)) })
                var trust: [CaptureField: CaptureFieldTrust] = [:]
                for (field, key) in [(CaptureField.amount, "amountTrust"), (.merchant, "resolvedMerchantTrust"),
                                     (.category, "resolvedCategoryTrust"), (.date, "dateTrust")] {
                    trust[field] = fields[key].flatMap(CaptureFieldTrust.init(rawValue:))
                }
                let signals = try (row["anomaly_json"] as String?)
                    .map { try JSON.decode([String].self, $0) } ?? []
                let duplicateID: String? = row["duplicate_match_id"]
                return CaptureReviewDraft(id: id, amountMinor: row["amount_minor"],
                    merchant: row["merchant_text"], categoryID: row["category_id"],
                    capturedAt: row["captured_at"], createdAt: row["created_at"], occurredAt: row["occurred_at"],
                    source: CaptureSource(source: row["source"], path: row["capture_path"]),
                    capturePath: row["capture_path"], categoryName: row["category_name"],
                    categoryPending: row["category_pending"], unresolved: unresolved, fieldTrust: trust,
                    amountCandidates: try (row["amount_candidates"] as String?)
                        .map { try JSON.decode([String].self, $0) } ?? [],
                    anomalySignals: signals.map(CaptureAnomaly.init(storedSignal:)), duplicateMatchID: duplicateID,
                    duplicateMatch: try duplicateID.flatMap { try CaptureDuplicateMatch.fetch(db, id: $0) },
                    duplicateBasis: .notRecorded,
                    feedbackIssue: try CaptureFeedbackIssueStore.state(db, transactionID: id), tzIdentifier: row["tz_identifier"])
        }
    }

    /// Real soft deletion, with an audited Undo token. Never confirms, teaches,
    /// or treats discarding an unsaved draft as an M1 amount error.
    /// The original capture outcome/evidence is retained; Feedback derives
    /// abandonedDeleted from deleted_at and pendingReview again after Undo.
    @discardableResult
    public static func discard(_ database: PaceDatabase, id: String,
                               now: @escaping @Sendable () -> Date = { Date() }) throws -> String? {
        try database.writer.write { db in
            guard let before = try db.snapshot("transactions", id: id) else { throw LedgerError.notFound }
            guard before["status"] == .text("draft") else { throw LedgerError.invalid("That capture is already saved.") }
            guard before["deleted_at"] == .null else { return nil }
            let stamp = Timestamp.string(now())
            try db.execute(sql: "UPDATE transactions SET deleted_at = ?, updated_at = ? WHERE id = ?",
                           arguments: [stamp, stamp, id])
            let actionID = try LedgerExecutor(database: database, now: now).log(db, kind: "discard_capture_draft",
                target: id, before: before, after: db.snapshot("transactions", id: id))
            // Append the lifecycle outcome without rewriting or copying feedback evidence.
            // Its action_id points to the audit row (including undone_at after Undo).
            try db.execute(sql: """
                INSERT INTO capture_outcomes (id, recorded_at, source, capture_path, outcome, reason,
                  transaction_id, action_id, fields_json, policy_version, trust_stage)
                SELECT ?, ?, source, capture_path, 'discarded', 'Discarded by user',
                  transaction_id, ?, fields_json, policy_version, trust_stage
                FROM capture_outcomes WHERE transaction_id = ? AND outcome = 'draft'
                ORDER BY rowid ASC LIMIT 1
                """, arguments: [UUID().uuidString.lowercased(), stamp, actionID, id])
            return actionID
        }
    }

    /// Only an explicit user action may teach this captured merchant to memory.
    public static func confirm(_ database: PaceDatabase, id: String, amountMinor: Int,
                               merchant: String, categoryID: String,
                               remember: Bool = true, occurredAt: Instant? = nil,
                               note: String?? = nil) throws -> String {
        guard (1...maximumAmountMinor).contains(amountMinor), merchant.count <= 200 else {
            throw LedgerError.invalid("Review needs a valid amount.")
        }
        return try database.writer.write { db in
            guard let before = try db.snapshot("transactions", id: id),
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM transactions WHERE id = ? AND status = 'draft' AND deleted_at IS NULL", arguments: [id])
            else { throw LedgerError.notFound }
            guard try String.fetchOne(db, sql: "SELECT id FROM categories WHERE id = ? AND archived = 0", arguments: [categoryID]) != nil
            else { throw LedgerError.invalid("Choose a category.") }
            let priorMerchant: String? = row["merchant_text"]
            let teaching = try MerchantTeaching.review(db, priorMerchant: priorMerchant,
                merchant: merchant, categoryID: categoryID)
            // Preserve confirmation's existing reinforcement semantics, including
            // seed → user ownership when the category is already remembered.
            // The shared projection omits a checkbox when no future mapping changes.
            let learning: LearningRecord?
            if remember, !merchantKey(merchant).isEmpty {
                learning = try MerchantMemory.learnCorrection(db, sourceName: priorMerchant,
                    correctedName: merchant, categoryID: categoryID,
                    learnAlias: teaching?.learnAlias ?? false, learnCategory: true)
            } else { learning = nil }
            let name = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            let merchantID = try learning?.merchantID ?? MerchantMemory.resolveAlias(db, name: name)?.merchantID
            try db.execute(sql: """
                UPDATE transactions SET amount_minor = ?, merchant_text = ?, merchant_id = ?,
                    category_id = ?, category_pending = 0, status = 'confirmed', updated_at = ? WHERE id = ?
                """, arguments: [amountMinor, name.isEmpty ? nil : name, merchantID, categoryID,
                                  Timestamp.string(Date()), id])
            if let occurredAt {
                let zone = Zone(identifier: row["tz_identifier"] as String)!
                try db.execute(sql: "UPDATE transactions SET occurred_at = ?, local_date = ? WHERE id = ?",
                    arguments: [occurredAt.isoUTC, zone.local(occurredAt).time.date.iso, id])
            }
            if let note {
                guard (note?.count ?? 0) <= 1_000 else { throw LedgerError.invalid("Note is too long.") }
                try db.execute(sql: "UPDATE transactions SET note = ? WHERE id = ?", arguments: [note, id])
            }
            let after = try db.snapshot("transactions", id: id)
            let actionID = try LedgerExecutor(database: database).log(db, kind: "update_transaction", target: id,
                before: before, after: after, metadata: try learning.map { try JSON.encode(["learning": $0]) })
            let oldAmount: Int? = row["amount_minor"]
            let oldCategory: String? = row["category_id"]
            let merchantCorrected = priorMerchant.map { merchantKey($0) != merchantKey(merchant) } ?? false
            try CaptureEvidence.feedback(db, transactionID: id, actionID: actionID,
                amountError: oldAmount.map { $0 != amountMinor } ?? false,
                merchantError: merchantCorrected,
                softError: merchantCorrected || (oldCategory.map { $0 != categoryID } ?? false),
                now: Date())
            return actionID
        }
    }
}
