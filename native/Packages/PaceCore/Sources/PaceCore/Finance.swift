/// Port of `noted.finance`: the authoritative financial identities.
///
/// The eight invariants (pinned by `FinanceInvariantTests` and the Python
/// `tests/test_gate_b3.py`):
/// 1. spending = expenses − refunds
/// 2. retained = income − spending
/// 3. unallocated surplus = retained − contributions
/// 4. spendable = income − contributions
/// 5. retained = contributions + unallocated surplus
/// 6. savings rate = retained ÷ income, unavailable when income is 0
/// 7. contribution rate = contributions ÷ income, unavailable when income is 0
/// 8. refunds never add to income, contributions never carry a category, and
///    deleted rows never count
public struct FinancialSummary: Equatable, Sendable {
    public let income: Int
    public let spending: Int
    public let contributions: Int
    public let retained: Int
    public let unallocatedSurplus: Int
    public let spendable: Int
    public let savingsRate: Double?
    public let contributionRate: Double?
}

public enum Finance {
    private static func total(_ rows: [LedgerRow], _ type: TransactionType) -> Int {
        rows.lazy.filter { !$0.isDeleted && $0.type == type }.reduce(0) { $0 + $1.amountMinor }
    }

    public static func income(_ rows: [LedgerRow]) -> Int { total(rows, .income) }
    public static func spending(_ rows: [LedgerRow]) -> Int { total(rows, .expense) - total(rows, .refund) }
    public static func contributions(_ rows: [LedgerRow]) -> Int { total(rows, .contribution) }

    public static func summarize(_ rows: [LedgerRow]) -> FinancialSummary {
        let income = income(rows)
        let spending = spending(rows)
        let contributions = contributions(rows)
        let retained = income - spending
        return FinancialSummary(
            income: income, spending: spending, contributions: contributions, retained: retained,
            unallocatedSurplus: retained - contributions, spendable: income - contributions,
            savingsRate: income > 0 ? Double(retained) / Double(income) : nil,
            contributionRate: income > 0 ? Double(contributions) / Double(income) : nil)
    }

    /// Net spending by category (expenses minus refunds).
    public static func categoryTotals(_ rows: [LedgerRow]) -> [String: Int] {
        var totals: [String: Int] = [:]
        for row in rows where !row.isDeleted && (row.type == .expense || row.type == .refund) {
            totals[row.category ?? "", default: 0] += row.type == .expense ? row.amountMinor : -row.amountMinor
        }
        return totals
    }

    /// Net spending by merchant for rows that name one.
    public static func merchantSpendingTotals(_ rows: [LedgerRow]) -> [String: Int] {
        var totals: [String: Int] = [:]
        for row in rows where !row.isDeleted && (row.type == .expense || row.type == .refund) {
            guard let merchant = row.merchant else { continue }
            totals[merchant, default: 0] += row.type == .expense ? row.amountMinor : -row.amountMinor
        }
        return totals
    }
}
