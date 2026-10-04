import CryptoKit
import Foundation
import GRDB
import PaceCore

public enum LedgerError: Error, Equatable, LocalizedError {
    case invalid(String)
    case notFound
    case deleted
    case requestConflict
    /// A later action replaced what this action wrote; undo that change first.
    case undoConflict
    case undoNotSupported(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(reason): reason
        case .notFound: "That entry no longer exists."
        case .deleted: "That entry was deleted."
        case .requestConflict: "This request was already saved with different details."
        case .undoConflict: "A later change replaced this. Undo that change first."
        case let .undoNotSupported(kind): "\(kind) can't be undone."
        }
    }
}

public enum EntrySource: String, Codable, Sendable {
    case keypad, text, dictation, receipt, screenshot, wallet, recurring, `import`
}

/// A transaction to create. Category is a category *id*.
public struct TransactionDraft: Codable, Equatable, Sendable {
    public var type: TransactionType
    public var amountMinor: Int
    public var occurredAt: Instant
    public var tzIdentifier: String
    public var localDate: LocalDate
    public var merchantID: String?
    public var merchantText: String?
    public var categoryID: String?
    public var note: String?
    public var source: EntrySource
    public var recurringRuleID: String?
    public var occurrenceDate: LocalDate?
    public var originText: String?

    public init(type: TransactionType, amountMinor: Int, occurredAt: Instant, tzIdentifier: String, localDate: LocalDate,
                merchantID: String? = nil, merchantText: String? = nil, categoryID: String?, note: String? = nil,
                source: EntrySource, recurringRuleID: String? = nil, occurrenceDate: LocalDate? = nil,
                originText: String? = nil) {
        self.type = type
        self.amountMinor = amountMinor
        self.occurredAt = occurredAt
        self.tzIdentifier = tzIdentifier
        self.localDate = localDate
        self.merchantID = merchantID
        self.merchantText = merchantText
        self.categoryID = categoryID
        self.note = note
        self.source = source
        self.recurringRuleID = recurringRuleID
        self.occurrenceDate = occurrenceDate
        self.originText = originText
    }
}

/// A sparse edit. `.some(nil)` clears a nullable field.
public struct TransactionChanges: Equatable, Sendable {
    public var type: TransactionType?
    public var amountMinor: Int?
    public var merchantText: String??
    public var categoryID: String??
    public var note: String??
    public var localDate: LocalDate?
    public var occurredAt: Instant?
    public var recurringLink: (ruleID: String, occurrence: LocalDate)??

    public init(type: TransactionType? = nil, amountMinor: Int? = nil, merchantText: String?? = nil,
                categoryID: String?? = nil, note: String?? = nil, localDate: LocalDate? = nil,
                occurredAt: Instant? = nil, recurringLink: (ruleID: String, occurrence: LocalDate)?? = nil) {
        self.type = type
        self.amountMinor = amountMinor
        self.merchantText = merchantText
        self.categoryID = categoryID
        self.note = note
        self.localDate = localDate
        self.occurredAt = occurredAt
        self.recurringLink = recurringLink
    }

    public static func == (lhs: TransactionChanges, rhs: TransactionChanges) -> Bool {
        lhs.type == rhs.type && lhs.amountMinor == rhs.amountMinor && lhs.merchantText == rhs.merchantText
            && lhs.categoryID == rhs.categoryID && lhs.note == rhs.note && lhs.localDate == rhs.localDate
            && lhs.occurredAt == rhs.occurredAt
            && lhs.recurringLink??.ruleID == rhs.recurringLink??.ruleID
            && lhs.recurringLink??.occurrence == rhs.recurringLink??.occurrence
            && (lhs.recurringLink == nil) == (rhs.recurringLink == nil)
    }

    var isEmpty: Bool {
        type == nil && amountMinor == nil && merchantText == nil && categoryID == nil && note == nil
            && localDate == nil && occurredAt == nil && recurringLink == nil
    }
}

/// The outcome of one write; `actionID` is the undo token.
public struct Executed: Equatable, Sendable {
    public let actionID: String
    public let kind: String
    public let transaction: StoredTransaction
    public let duplicate: Bool
}

/// The profile: a payday anchor, the salary as a recurring income rule, and a savings target.
public struct ProfileInput: Equatable, Sendable {
    public var paydayAnchor: Int?
    public var salaryMinor: Int
    public var salaryDay: Int
    /// The payday-cycle start from which this salary amount and day apply.
    public var effectiveCycleStart: LocalDate
    public var savingsMode: SavingsMode
    public var savingsTargetMinor: Int
    public var savingsBasisPoints: Int
    /// Temporary planning field for fixed commitments.
    public var fixedCommitmentsMinor: Int

    public init(paydayAnchor: Int?, salaryMinor: Int, salaryDay: Int, effectiveCycleStart: LocalDate,
                savingsMode: SavingsMode = .fixed, savingsTargetMinor: Int = 0, savingsBasisPoints: Int = 0,
                fixedCommitmentsMinor: Int = 0) {
        self.paydayAnchor = paydayAnchor
        self.salaryMinor = salaryMinor
        self.salaryDay = salaryDay
        self.effectiveCycleStart = effectiveCycleStart
        self.savingsMode = savingsMode
        self.savingsTargetMinor = savingsTargetMinor
        self.savingsBasisPoints = savingsBasisPoints
        self.fixedCommitmentsMinor = fixedCommitmentsMinor
    }

    func validate() throws {
        if let anchor = paydayAnchor, !(1...31).contains(anchor) { throw LedgerError.invalid("Payday must be day 1–31.") }
        guard (0...maximumAmountMinor).contains(salaryMinor), (0...maximumAmountMinor).contains(savingsTargetMinor),
              (0...maximumAmountMinor).contains(fixedCommitmentsMinor) else { throw LedgerError.invalid("Amount out of range.") }
        guard (1...31).contains(salaryDay) else { throw LedgerError.invalid("Salary day must be 1–31.") }
        guard Cycle.containing(effectiveCycleStart, anchorDay: paydayAnchor ?? 1).start == effectiveCycleStart else {
            throw LedgerError.invalid("Choose the start of a pay cycle for the salary change.")
        }
        guard (0...10_000).contains(savingsBasisPoints) else { throw LedgerError.invalid("Savings percentage must be 0–100%.") }
        if savingsMode == .fixed, fixedCommitmentsMinor + savingsTargetMinor > salaryMinor {
            throw LedgerError.invalid("Commitments plus savings can't exceed income.")
        }
    }
}

private struct ProfileChangeAudit: Codable {
    let effectiveCycleStart: String
    let previousSalaryRuleBefore: Snapshot?
    let previousSalaryRuleAfter: Snapshot?
    let selectedSalaryRuleAfter: Snapshot?
}

/// Primary ledger write path; capture/review components write directly and log
/// through the executor. Ledger writes use a SQLite transaction with an audit row.
public final class LedgerExecutor: Sendable {
    public let database: PaceDatabase
    private let now: @Sendable () -> Date

    public init(database: PaceDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    private static let ignoredOnUndo: Set<String> = ["id", "created_at", "updated_at"]

    @discardableResult
    func log(_ db: Database, kind: String, table: String = "transactions", target: String,
                     before: Snapshot?, after: Snapshot?, metadata: String? = nil, undoOf: String? = nil) throws -> String {
        let id = UUID().uuidString.lowercased()
        try db.execute(sql: """
            INSERT INTO action_log (id, kind, target_table, target_id, before_json, after_json, metadata_json, executed_at, undo_of)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, kind, table, target, try before.map(JSON.encode), try after.map(JSON.encode),
                             metadata, Timestamp.string(now()), undoOf])
        return id
    }

    private static func validate(type: TransactionType, amountMinor: Int, categoryID: String?, merchantText: String?,
                                 note: String?) throws {
        guard amountMinor > 0, amountMinor <= maximumAmountMinor else { throw LedgerError.invalid("Enter an amount above RM 0.00.") }
        guard type.acceptsCategory(categoryID) else {
            throw LedgerError.invalid(type == .contribution ? "Set aside has no category." : "Choose a category.")
        }
        if (merchantText?.count ?? 0) > 200 { throw LedgerError.invalid("Merchant is too long.") }
        if (note?.count ?? 0) > 500 { throw LedgerError.invalid("Note is too long.") }
    }

    /// Salary rule versions share one expected payment per pay cycle. The
    /// schema's (rule_id, occurrence_date) uniqueness alone is insufficient
    /// after a salary changes within that cycle.
    private static func validateSalaryLink(_ db: Database, ruleID: String?, occurrence: LocalDate?,
                                           excluding transactionID: String? = nil) throws {
        guard let ruleID, let occurrence else { return }
        let salaryRule = try Int.fetchOne(db, sql: """
            SELECT 1 FROM profile_versions WHERE salary_rule_id = ? LIMIT 1
            """, arguments: [ruleID]) != nil
        guard salaryRule else { return }
        let anchor = try Profile.current(db)?.paydayAnchor ?? 1
        let cycle = Cycle.containing(occurrence, anchorDay: anchor)
        let duplicate = try Int.fetchOne(db, sql: """
            SELECT 1 FROM transactions
            WHERE deleted_at IS NULL AND status = 'confirmed' AND id != ?
              AND recurring_rule_id IN (SELECT salary_rule_id FROM profile_versions WHERE salary_rule_id IS NOT NULL)
              AND occurrence_date BETWEEN ? AND ? LIMIT 1
            """, arguments: [transactionID ?? "", cycle.start.iso, cycle.end.iso]) != nil
        guard !duplicate else { throw LedgerError.invalid("Salary is already linked for this pay cycle.") }
    }

    // MARK: Create

    public func create(_ draft: TransactionDraft, requestID: String? = nil) throws -> Executed {
        try Self.validate(type: draft.type, amountMinor: draft.amountMinor, categoryID: draft.categoryID,
                          merchantText: draft.merchantText, note: draft.note)
        guard Zone(identifier: draft.tzIdentifier) != nil else { throw LedgerError.invalid("Unknown time zone.") }
        let fingerprint = try requestID.map { _ in
            SHA256.hash(data: Data(try JSON.encode(draft).utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return try database.writer.write { db in
            try createInTransaction(db, draft, requestID: requestID, fingerprint: fingerprint)
        }
    }

    func createInTransaction(_ db: Database, _ draft: TransactionDraft, requestID: String?,
                             fingerprint: String?) throws -> Executed {
            if let requestID, let fingerprint, let replay = try replay(db, requestID: requestID, fingerprint: fingerprint) {
                return replay
            }
            try Self.validateSalaryLink(db, ruleID: draft.recurringRuleID, occurrence: draft.occurrenceDate)
            let id = UUID().uuidString.lowercased()
            let createdAt = Timestamp.string(now())
            try db.execute(sql: """
                INSERT INTO transactions (id, type, amount_minor, occurred_at, tz_identifier, local_date, merchant_id,
                    merchant_text, category_id, note, source, status, recurring_rule_id, occurrence_date, origin_text,
                    request_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'confirmed', ?, ?, ?, ?, ?)
                """, arguments: [id, draft.type.rawValue, draft.amountMinor, draft.occurredAt.isoUTC, draft.tzIdentifier,
                                 draft.localDate.iso, draft.merchantID, draft.merchantText, draft.categoryID, draft.note,
                                 draft.source.rawValue, draft.recurringRuleID, draft.occurrenceDate?.iso, draft.originText,
                                 requestID, createdAt])
            if let merchantID = draft.merchantID {
                try db.execute(sql: "UPDATE merchants SET hit_count = hit_count + 1, last_seen_at = ? WHERE id = ?",
                               arguments: [createdAt, merchantID])
            }
            let after = try db.snapshot("transactions", id: id)
            let actionID = try log(db, kind: "create_transaction", target: id, before: nil, after: after)
            if let requestID, let fingerprint {
                try db.execute(sql: """
                    INSERT INTO request_idempotency (request_id, request_fingerprint, action_log_id, committed_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [requestID, fingerprint, actionID, createdAt])
            }
            return Executed(actionID: actionID, kind: "create_transaction",
                            transaction: try StoredTransaction.fetch(db, id: id)!, duplicate: false)
    }

    private func replay(_ db: Database, requestID: String, fingerprint: String) throws -> Executed? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT i.request_fingerprint, a.id AS action_id, a.target_id FROM request_idempotency i
            JOIN action_log a ON a.id = i.action_log_id WHERE i.request_id = ?
            """, arguments: [requestID]) else { return nil }
        guard row["request_fingerprint"] as String == fingerprint else { throw LedgerError.requestConflict }
        guard let transaction = try StoredTransaction.fetch(db, id: row["target_id"]) else { throw LedgerError.notFound }
        return Executed(actionID: row["action_id"], kind: "create_transaction", transaction: transaction, duplicate: true)
    }

    // MARK: Update

    public func update(_ id: String, _ changes: TransactionChanges, explicitUserEdit: Bool = true,
                       captureFeedbackIssue: CaptureFeedbackIssue? = nil, remember: Bool = true) throws -> Executed {
        guard !changes.isEmpty else { throw LedgerError.invalid("Nothing to change.") }
        return try database.writer.write { db in
            guard let before = try db.snapshot("transactions", id: id),
                  let current = try StoredTransaction.fetch(db, id: id) else { throw LedgerError.notFound }
            guard current.deletedAt == nil else { throw LedgerError.deleted }
            var values: [(String, DatabaseValueConvertible?)] = []
            var candidate = current
            if let type = changes.type { values.append(("type", type.rawValue)); candidate.type = type }
            if let amount = changes.amountMinor { values.append(("amount_minor", amount)); candidate.amountMinor = amount }
            if let merchant = changes.merchantText { values.append(("merchant_text", merchant)); candidate.merchantText = merchant }
            if let category = changes.categoryID { values.append(("category_id", category)); candidate.categoryID = category }
            // An explicit category choice resolves saved capture attention, including
            // choosing the existing Other value. Learning conditions below are unchanged.
            if explicitUserEdit, changes.categoryID != nil || changes.type == .income || changes.type == .contribution {
                values.append(("category_pending", 0))
            }
            if let note = changes.note { values.append(("note", note)); candidate.note = note }
            if let date = changes.localDate { values.append(("local_date", date.iso)); candidate.localDate = date }
            if let occurred = changes.occurredAt { values.append(("occurred_at", occurred.isoUTC)) }
            if let link = changes.recurringLink {
                values.append(("recurring_rule_id", link?.ruleID))
                values.append(("occurrence_date", link?.occurrence.iso))
                try Self.validateSalaryLink(db, ruleID: link?.ruleID, occurrence: link?.occurrence,
                                            excluding: id)
            }
            try Self.validate(type: candidate.type, amountMinor: candidate.amountMinor, categoryID: candidate.categoryID,
                              merchantText: candidate.merchantText, note: candidate.note)

            var metadata: String?
            if explicitUserEdit {
                if changes.merchantText != nil, merchantKey(candidate.merchantText ?? "").isEmpty {
                    values.append(("merchant_id", nil))
                }
                if let teaching = MerchantTeaching.edit(current: current, changes: changes), remember {
                    let learning = try MerchantMemory.learnCorrection(
                        db, sourceName: current.merchantText, correctedName: teaching.merchant,
                        categoryID: candidate.categoryID, learnAlias: teaching.learnAlias,
                        learnCategory: teaching.learnCategory)
                    values.append(("merchant_id", learning.merchantID))
                    metadata = try JSON.encode(["learning": learning])
                }
            }
            let assignments = values.map { "\($0.0) = ?" }.joined(separator: ", ")
            try db.execute(sql: "UPDATE transactions SET \(assignments), updated_at = ? WHERE id = ?",
                           arguments: StatementArguments(values.map(\.1) + [Timestamp.string(now()), id]))
            let after = try db.snapshot("transactions", id: id)
            let actionID = try log(db, kind: "update_transaction", target: id, before: before, after: after, metadata: metadata)
            if explicitUserEdit {
                let amountError = before["amount_minor"] != after?["amount_minor"]
                let merchantError = before["merchant_text"] != after?["merchant_text"]
                let softError = merchantError || before["category_id"] != after?["category_id"]
                try CaptureEvidence.feedback(db, transactionID: id, actionID: actionID,
                                             amountError: amountError, merchantError: merchantError,
                                             softError: softError, now: now())
            }
            if let captureFeedbackIssue {
                try CaptureFeedbackIssueStore.set(db, transactionID: id, issue: captureFeedbackIssue)
            }
            return Executed(actionID: actionID, kind: "update_transaction",
                            transaction: try StoredTransaction.fetch(db, id: id)!, duplicate: false)
        }
    }

    // MARK: Delete (soft; nothing is ever hard-deleted)

    public func softDelete(_ id: String) throws -> Executed {
        try database.writer.write { db in
            guard let before = try db.snapshot("transactions", id: id) else { throw LedgerError.notFound }
            if before["deleted_at"] == .null {
                let stamp = Timestamp.string(now())
                try db.execute(sql: "UPDATE transactions SET deleted_at = ?, updated_at = ? WHERE id = ?",
                               arguments: [stamp, stamp, id])
            }
            let after = try db.snapshot("transactions", id: id)
            let actionID = try log(db, kind: "delete_transaction", target: id, before: before, after: after)
            if before["deleted_at"] == .null {
                try CaptureEvidence.feedback(db, transactionID: id, actionID: actionID,
                                             amountError: true, merchantError: false, softError: false, now: now())
            }
            return Executed(actionID: actionID, kind: "delete_transaction",
                            transaction: try StoredTransaction.fetch(db, id: id)!, duplicate: false)
        }
    }

    // MARK: Undo

    /// Reverts exactly what `actionID` wrote, only while it is still there, and
    /// reverts the merchant memory that correction taught (decision O5).
    public func undo(_ actionID: String) throws -> Executed {
        try database.writer.write { db in
            let result = try undoInTransaction(db, actionID: actionID)
            return Executed(actionID: result.actionID, kind: "undo",
                            transaction: try StoredTransaction.fetch(db, id: result.targetID)!, duplicate: result.duplicate)
        }
    }

    /// Uses the same snapshot/conflict machinery without decoding a nullable draft
    /// amount as a confirmed ledger transaction.
    public func undoDraftDiscard(_ actionID: String) throws {
        try database.writer.write { db in
            guard try String.fetchOne(db, sql: "SELECT kind FROM action_log WHERE id = ?",
                                      arguments: [actionID]) == "discard_capture_draft" else {
                throw LedgerError.undoNotSupported("That action")
            }
            _ = try undoInTransaction(db, actionID: actionID)
        }
    }

    private func undoInTransaction(_ db: Database, actionID: String) throws
        -> (actionID: String, targetID: String, duplicate: Bool) {
            guard let action = try Row.fetchOne(db, sql: "SELECT rowid AS seq, * FROM action_log WHERE id = ?",
                                                arguments: [actionID]) else { throw LedgerError.notFound }
            let kind: String = action["kind"]
            guard action["target_table"] as String == "transactions", kind != "undo" else {
                throw LedgerError.undoNotSupported(kind)
            }
            let targetID: String = action["target_id"]
            if action["undone_at"] as String? != nil {
                let undoID = try String.fetchOne(db, sql: "SELECT id FROM action_log WHERE undo_of = ? ORDER BY rowid LIMIT 1",
                                                 arguments: [actionID])
                return (undoID ?? actionID, targetID, true)
            }
            let before = try (action["before_json"] as String?).map { try JSON.decode(Snapshot.self, $0) }
            let after = try JSON.decode(Snapshot.self, action["after_json"])
            guard let current = try db.snapshot("transactions", id: targetID) else { throw LedgerError.notFound }
            let stamp = Timestamp.string(now())
            let written: Set<String>
            var restore: [(String, DatabaseValue)] = []
            if let before {
                written = Set(after.keys.filter { !Self.ignoredOnUndo.contains($0) && after[$0] != before[$0] })
                restore = written.sorted().map { ($0, (before[$0] ?? .null).databaseValue) }
            } else {
                written = Set(after.keys.filter { !Self.ignoredOnUndo.contains($0) })
                restore = [("deleted_at", stamp.databaseValue)]
            }
            // The value alone is not enough: later edits may have changed a
            // field and then restored this action's value. Active audit rows
            // still own that field until those edits are undone.
            let laterActions = try Row.fetchAll(db, sql: """
                SELECT before_json, after_json FROM action_log
                WHERE target_table = 'transactions' AND target_id = ? AND rowid > ?
                AND undone_at IS NULL AND kind != 'undo'
                """, arguments: [targetID, action["seq"] as Int64])
            for later in laterActions {
                let laterBefore = try (later["before_json"] as String?).map { try JSON.decode(Snapshot.self, $0) }
                let laterAfter = try JSON.decode(Snapshot.self, later["after_json"])
                let laterWritten = Set(laterAfter.keys.filter {
                    !Self.ignoredOnUndo.contains($0) && (laterBefore == nil || laterAfter[$0] != laterBefore?[$0])
                })
                guard written.isDisjoint(with: laterWritten) else { throw LedgerError.undoConflict }
            }
            guard written.allSatisfy({ current[$0] == after[$0] }) else { throw LedgerError.undoConflict }
            if let before {
                let deleted = (written.contains("deleted_at") ? before["deleted_at"] : current["deleted_at"]) ?? .null
                let rule = (written.contains("recurring_rule_id") ? before["recurring_rule_id"]
                            : current["recurring_rule_id"]) ?? .null
                let occurrence = (written.contains("occurrence_date") ? before["occurrence_date"]
                                  : current["occurrence_date"]) ?? .null
                if deleted == .null, case let .text(ruleID) = rule,
                   case let .text(dateText) = occurrence, let date = LocalDate(iso: dateText) {
                    do { try Self.validateSalaryLink(db, ruleID: ruleID, occurrence: date, excluding: targetID) }
                    catch LedgerError.invalid { throw LedgerError.undoConflict }
                }
            }
            if !restore.isEmpty {
                let assignments = restore.map { "\($0.0) = ?" }.joined(separator: ", ")
                try db.execute(sql: "UPDATE transactions SET \(assignments), updated_at = ? WHERE id = ?",
                               arguments: StatementArguments(restore.map(\.1) + [stamp.databaseValue, targetID.databaseValue]))
            }
            if let metadata = action["metadata_json"] as String?,
               let learning = try JSON.decode([String: LearningRecord].self, metadata)["learning"] {
                let later = try String.fetchAll(db, sql: """
                    SELECT metadata_json FROM action_log WHERE kind = 'update_transaction' AND undone_at IS NULL
                    AND metadata_json IS NOT NULL AND rowid > ?
                    """, arguments: [action["seq"] as Int64]).compactMap {
                        try JSON.decode([String: LearningRecord].self, $0)["learning"]
                    }.filter { $0.merchantID == learning.merchantID }
                try MerchantMemory.revert(db, learning,
                                          reinforcedAliases: Set(later.flatMap { $0.aliases.map(\.aliasKey) }),
                                          merchantReinforced: !later.isEmpty)
            }
            let restored = try db.snapshot("transactions", id: targetID)
            let undoID = try log(db, kind: "undo", target: targetID, before: current, after: restored, undoOf: actionID)
            try db.execute(sql: "UPDATE action_log SET undone_at = ? WHERE id = ?", arguments: [stamp, actionID])
            if kind == "create_transaction" {
                try CaptureEvidence.feedback(db, transactionID: targetID, actionID: undoID,
                                             amountError: true, merchantError: false, softError: false, now: now())
            }
            return (undoID, targetID, false)
    }

    // MARK: Profile

    /// Appends a profile version. Salary rule values are immutable: a change
    /// closes the preceding rule at the previous cycle's end and inserts a new
    /// rule from the selected cycle. Audited; not undoable.
    @discardableResult
    public func setProfile(_ input: ProfileInput) throws -> Profile {
        try input.validate()
        return try database.writer.write { db in
            let stamp = Timestamp.string(now())
            let previous = try Profile.current(db)
            let profileBefore = try previous.flatMap { try db.snapshot("profile_versions", id: String($0.versionID)) }
            let active = try Profile.salaryRule(db, forCycleStarting: input.effectiveCycleStart)
            let ruleBefore = try active.flatMap { try db.snapshot("recurring_rules", id: $0.id) }
            let ruleID: String
            if let active, active.amountMinor == input.salaryMinor, active.dayOfMonth == input.salaryDay {
                ruleID = active.id
            } else {
                let nextStart = try Profile.nextSalaryRule(db, after: input.effectiveCycleStart)?.start
                if let active {
                    try db.execute(sql: "UPDATE recurring_rules SET end_date = ?, updated_at = ? WHERE id = ?",
                                   arguments: [input.effectiveCycleStart.adding(days: -1).iso, stamp, active.id])
                }
                let hasSalaryRule = try Int.fetchOne(db, sql: """
                    SELECT 1 FROM profile_versions WHERE salary_rule_id IS NOT NULL LIMIT 1
                    """) != nil
                ruleID = hasSalaryRule ? "salary-\(UUID().uuidString.lowercased())" : "salary"
                try db.execute(sql: """
                    INSERT INTO recurring_rules (id, kind, label, amount_minor, amount_mode, day_of_month, start_date,
                        end_date, category_id, mode, created_at, updated_at)
                    VALUES (?, 'income', 'Salary', ?, 'fixed', ?, ?, ?, ?, 'draft', ?, ?)
                    """, arguments: [ruleID, input.salaryMinor, input.salaryDay, input.effectiveCycleStart.iso,
                                     nextStart?.adding(days: -1).iso, Seeds.categoryID("Income"), stamp, stamp])
            }
            try db.execute(sql: """
                INSERT INTO profile_versions (payday_anchor, salary_rule_id, savings_mode, savings_target_minor,
                    savings_basis_points, fixed_commitments_minor, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [input.paydayAnchor, ruleID, input.savingsMode.rawValue, input.savingsTargetMinor,
                                 input.savingsBasisPoints, input.fixedCommitmentsMinor, stamp])
            let versionID = String(db.lastInsertedRowID)
            let audit = ProfileChangeAudit(
                effectiveCycleStart: input.effectiveCycleStart.iso,
                previousSalaryRuleBefore: ruleBefore,
                previousSalaryRuleAfter: try active.flatMap { try db.snapshot("recurring_rules", id: $0.id) },
                selectedSalaryRuleAfter: try db.snapshot("recurring_rules", id: ruleID))
            try log(db, kind: "set_profile", table: "profile_versions", target: versionID,
                    before: profileBefore, after: try db.snapshot("profile_versions", id: versionID),
                    metadata: try JSON.encode(audit))
            return try Profile.current(db)!
        }
    }
}
