import Foundation
import GRDB
import PaceCore

public struct StoredTransaction: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public var type: TransactionType
    public var amountMinor: Int
    public var occurredAt: Instant
    public var tzIdentifier: String
    public var localDate: LocalDate
    public var merchantID: String?
    public var merchantText: String?
    public var categoryID: String?
    public var categoryName: String?
    public var note: String?
    public var source: String
    public var capturePath: String?
    public var categoryPending: Bool
    public var status: String
    public var recurringRuleID: String?
    public var occurrenceDate: LocalDate?
    public var createdAt: String
    public var updatedAt: String?
    public var deletedAt: String?

    public var captureSource: CaptureSource? {
        guard source == "wallet" || source == "screenshot" else { return nil }
        return CaptureSource(source: source, path: capturePath)
    }

    public var hasMerchant: Bool { merchantText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }

    public var title: String {
        Self.consumerTitle(merchant: merchantText, note: note, source: captureSource, category: categoryName, type: type)
    }

    static func consumerTitle(merchant: String?, note: String?, source: CaptureSource?, category: String?, type: TransactionType) -> String {
        if let merchant, !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return merchant }
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return note }
        if let source { return source.fallbackTitle }
        if let category, category != "Other" { return category }
        switch type {
        case .expense: return "Expense"
        case .income: return "Income"
        case .refund: return "Refund"
        case .contribution: return "Set aside"
        }
    }

    public var kindLabel: String {
        if categoryPending { return "Needs a category" }
        switch type {
        case .income: return categoryName ?? "Income"
        case .contribution: return "Set aside"
        case .refund: return categoryName.map { "Refund · \($0)" } ?? "Refund"
        case .expense: return categoryName ?? "Expense"
        }
    }

    public var ledgerMetadata: String {
        var parts = kindLabel == title ? [] : [kindLabel]
        if let captureSource { parts.append(captureSource.label) }
        return parts.joined(separator: " · ")
    }

    public var ledgerRow: LedgerRow {
        LedgerRow(type: type, amountMinor: amountMinor, category: categoryName, merchant: merchantText,
                  localDate: localDate, isDeleted: deletedAt != nil, recurringRuleID: recurringRuleID,
                  occurrenceDate: occurrenceDate)
    }

    static let select = """
        SELECT t.*, c.name AS category_name FROM transactions t LEFT JOIN categories c ON c.id = t.category_id
        """

    init(row: Row) {
        id = row["id"]
        type = TransactionType(rawValue: row["type"])!
        amountMinor = row["amount_minor"]
        occurredAt = Instant(iso: row["occurred_at"])!
        tzIdentifier = row["tz_identifier"]
        localDate = LocalDate(iso: row["local_date"])!
        merchantID = row["merchant_id"]
        merchantText = row["merchant_text"]
        categoryID = row["category_id"]
        categoryName = row["category_name"]
        note = row["note"]
        source = row["source"]
        capturePath = row["capture_path"]
        categoryPending = row["category_pending"]
        status = row["status"]
        recurringRuleID = row["recurring_rule_id"]
        occurrenceDate = (row["occurrence_date"] as String?).flatMap(LocalDate.init(iso:))
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
        deletedAt = row["deleted_at"]
    }

    static func fetch(_ db: Database, id: String) throws -> StoredTransaction? {
        try Row.fetchOne(db, sql: select + " WHERE t.id = ?", arguments: [id]).map(StoredTransaction.init)
    }
}

public struct Category: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let nature: String
}

public struct SalaryRule: Equatable, Sendable {
    public let id: String
    public let amountMinor: Int
    public let dayOfMonth: Int
    public let start: LocalDate

    init(id: String, amountMinor: Int, dayOfMonth: Int, start: LocalDate) {
        self.id = id
        self.amountMinor = amountMinor
        self.dayOfMonth = dayOfMonth
        self.start = start
    }

    public var monthlyRule: MonthlyRule {
        MonthlyRule(id: id, kind: .income, amountMinor: amountMinor, dayOfMonth: dayOfMonth, start: start)
    }

    init(row: Row) {
        id = row["id"]
        amountMinor = row["amount_minor"]
        dayOfMonth = row["day_of_month"]
        start = LocalDate(iso: row["start_date"])!
    }
}

public struct Profile: Equatable, Sendable {
    public let versionID: Int64
    public let paydayAnchor: Int?
    public let salaryRule: SalaryRule?
    public let savingsMode: SavingsMode
    public let savingsTargetMinor: Int
    public let savingsBasisPoints: Int
    public let fixedCommitmentsMinor: Int
    public let financialLocale: String

    static func current(_ db: Database) throws -> Profile? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT p.*, r.amount_minor AS rule_amount, r.day_of_month AS rule_day, r.start_date AS rule_start
            FROM profile_versions p LEFT JOIN recurring_rules r ON r.id = p.salary_rule_id
            ORDER BY p.id DESC LIMIT 1
            """) else { return nil }
        let rule: SalaryRule? = (row["salary_rule_id"] as String?).map {
            SalaryRule(id: $0, amountMinor: row["rule_amount"], dayOfMonth: row["rule_day"],
                       start: LocalDate(iso: row["rule_start"])!)
        }
        return Profile(versionID: row["id"], paydayAnchor: row["payday_anchor"], salaryRule: rule,
                       savingsMode: SavingsMode(rawValue: row["savings_mode"])!, savingsTargetMinor: row["savings_target_minor"],
                       savingsBasisPoints: row["savings_basis_points"], fixedCommitmentsMinor: row["fixed_commitments_minor"],
                       financialLocale: row["financial_locale"])
    }

    /// The salary rule active at a payday-cycle boundary. Each salary change
    /// has its own row; old amounts and salary days remain queryable.
    static func salaryRule(_ db: Database, forCycleStarting start: LocalDate) throws -> SalaryRule? {
        try Row.fetchOne(db, sql: """
            SELECT r.* FROM recurring_rules r
            WHERE r.id IN (SELECT salary_rule_id FROM profile_versions WHERE salary_rule_id IS NOT NULL)
              AND r.start_date <= ? AND (r.end_date IS NULL OR r.end_date >= ?)
            ORDER BY r.start_date DESC, r.rowid DESC LIMIT 1
            """, arguments: [start.iso, start.iso]).map(SalaryRule.init)
    }

    static func nextSalaryRule(_ db: Database, after start: LocalDate) throws -> SalaryRule? {
        try Row.fetchOne(db, sql: """
            SELECT r.* FROM recurring_rules r
            WHERE r.id IN (SELECT salary_rule_id FROM profile_versions WHERE salary_rule_id IS NOT NULL)
              AND r.start_date > ? AND (r.end_date IS NULL OR r.end_date >= r.start_date)
            ORDER BY r.start_date, r.rowid DESC LIMIT 1
            """, arguments: [start.iso]).map(SalaryRule.init)
    }

    func withSalaryRule(_ rule: SalaryRule?) -> Profile {
        Profile(versionID: versionID, paydayAnchor: paydayAnchor, salaryRule: rule,
                savingsMode: savingsMode, savingsTargetMinor: savingsTargetMinor,
                savingsBasisPoints: savingsBasisPoints, fixedCommitmentsMinor: fixedCommitmentsMinor,
                financialLocale: financialLocale)
    }

    public var planParameters: PlanParameters? {
        paydayAnchor.map {
            PlanParameters(anchorDay: $0, savingsMode: savingsMode, savingsTargetMinor: savingsTargetMinor,
                           savingsBasisPoints: savingsBasisPoints, fixedCommitmentsMinor: fixedCommitmentsMinor)
        }
    }
}

/// Home: the cycle's plan when the payday anchor is set; otherwise
/// calendar-month actuals and a prompt to finish the profile.
public struct HomeSnapshot: Equatable, Sendable {
    public let today: LocalDate
    public let cycle: Cycle
    public let actual: FinancialSummary
    public let plan: CyclePlan?
    public let profile: Profile?
}

public struct HistoryQuery: Equatable, Sendable {
    public var start: LocalDate?
    public var end: LocalDate?
    public var text: String
    public var limit: Int?

    public init(start: LocalDate? = nil, end: LocalDate? = nil, text: String = "", limit: Int? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.limit = limit
    }
}

public enum Queries {
    public static func categories(_ db: Database) throws -> [Category] {
        try Row.fetchAll(db, sql: "SELECT * FROM categories WHERE archived = 0 ORDER BY sort").map {
            Category(id: $0["id"], name: $0["name"], nature: $0["nature"])
        }
    }

    public static func transaction(_ db: Database, id: String) throws -> StoredTransaction? {
        try StoredTransaction.fetch(db, id: id)
    }

    public static func confirmedTransaction(_ db: Database, id: String) throws -> StoredTransaction? {
        try Row.fetchOne(db, sql: StoredTransaction.select + " WHERE t.id = ? AND t.status = 'confirmed' AND t.deleted_at IS NULL",
                         arguments: [id]).map(StoredTransaction.init)
    }

    /// History: confirmed, non-deleted rows, newest first. Text search covers
    /// merchant, note, category and amount ("18" or "18.50").
    public static func history(_ db: Database, _ query: HistoryQuery) throws -> [StoredTransaction] {
        var clauses = ["t.deleted_at IS NULL", "t.status = 'confirmed'"]
        var arguments: [DatabaseValueConvertible] = []
        if let start = query.start { clauses.append("t.local_date >= ?"); arguments.append(start.iso) }
        if let end = query.end { clauses.append("t.local_date <= ?"); arguments.append(end.iso) }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            var textClause = """
                (t.merchant_text LIKE ? ESCAPE '\\' OR t.note LIKE ? ESCAPE '\\' OR c.name LIKE ? ESCAPE '\\'
                """
            arguments += [pattern, pattern, pattern]
            let amountText = text.replacingOccurrences(of: "rm", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
            if !amountText.isEmpty, amountText.allSatisfy({ $0.isNumber || $0 == "." }),
               amountText.filter({ $0 == "." }).count <= 1 {
                textClause += " OR t.amount_minor = ?"
                arguments.append(Keypad.amountMinor(amountText))
            }
            clauses.append(textClause + ")")
        }
        let limitClause: String
        if let limit = query.limit { limitClause = " LIMIT ?"; arguments.append(limit) }
        else { limitClause = "" }
        return try Row.fetchAll(db, sql: StoredTransaction.select + " WHERE " + clauses.joined(separator: " AND ")
                                + " ORDER BY t.local_date DESC, t.occurred_at DESC, t.created_at DESC" + limitClause,
                                arguments: StatementArguments(arguments)).map(StoredTransaction.init)
    }

    /// Confirmed, non-deleted rows that can affect a cycle's figures.
    public static func cycleRows(_ db: Database, _ cycle: Cycle) throws -> [StoredTransaction] {
        try Row.fetchAll(db, sql: StoredTransaction.select + """
             WHERE t.deleted_at IS NULL AND t.status = 'confirmed'
             AND ((t.local_date >= ? AND t.local_date <= ?) OR (t.occurrence_date >= ? AND t.occurrence_date <= ?))
            """, arguments: [cycle.start.iso, cycle.end.iso, cycle.start.iso, cycle.end.iso]).map(StoredTransaction.init)
    }

    /// Latest saved settings. A scheduled salary can be newer than the rule
    /// active today; `home(_:today:)` resolves salary for its queried cycle.
    public static func profile(_ db: Database) throws -> Profile? { try Profile.current(db) }

    public static func salaryRule(_ db: Database, forCycleStarting start: LocalDate) throws -> SalaryRule? {
        try Profile.salaryRule(db, forCycleStarting: start)
    }

    public static func nextSalaryChange(_ db: Database, after cycleStart: LocalDate) throws -> SalaryRule? {
        try Profile.nextSalaryRule(db, after: cycleStart)
    }

    public static func home(_ db: Database, today: LocalDate) throws -> HomeSnapshot {
        let latest = try Profile.current(db)
        let parameters = latest?.planParameters
        let cycle = Cycle.containing(today, anchorDay: parameters?.anchorDay ?? 1)
        let profile = try latest?.withSalaryRule(Profile.salaryRule(db, forCycleStarting: cycle.start))
        let rows = try cycleRows(db, cycle).map(\.ledgerRow)
        // A salary already logged against an earlier version of the rule still
        // satisfies this cycle after a same-cycle salary change.
        let salaryAlreadyLinked = try Int.fetchOne(db, sql: """
            SELECT 1 FROM transactions t
            WHERE t.deleted_at IS NULL AND t.status = 'confirmed'
              AND t.recurring_rule_id IN (SELECT salary_rule_id FROM profile_versions WHERE salary_rule_id IS NOT NULL)
              AND t.occurrence_date BETWEEN ? AND ? LIMIT 1
            """, arguments: [cycle.start.iso, cycle.end.iso]) != nil
        let plan = parameters.map {
            Planning.plan(rows: rows, today: today,
                          rules: salaryAlreadyLinked ? [] : profile?.salaryRule.map { [$0.monthlyRule] } ?? [], parameters: $0)
        }
        let actual = Finance.summarize(rows.filter { row in row.localDate.map { cycle.start <= $0 && $0 <= today } ?? false })
        return HomeSnapshot(today: today, cycle: cycle, actual: actual, plan: plan, profile: profile)
    }

    /// The salary occurrence a new Earned entry could satisfy in `today`'s cycle.
    public static func openSalaryOccurrence(_ db: Database, today: LocalDate) throws -> ExpectedOccurrence? {
        try home(db, today: today).plan?.expectedOccurrences.first
    }

    public static func resolveMerchant(_ db: Database, name: String) throws -> MerchantMatch? {
        try MerchantMemory.resolveAlias(db, name: name)
    }
}
