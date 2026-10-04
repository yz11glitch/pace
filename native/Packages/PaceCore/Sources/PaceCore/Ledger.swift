/// The four flow classes. Direction lives in the type; amounts are never negative.
public enum TransactionType: String, Codable, CaseIterable, Sendable {
    case expense, income, refund, contribution

    /// Consumer label (PWA `FLOW_LABELS`).
    public var label: String {
        switch self {
        case .expense: "Spent"
        case .income: "Earned"
        case .refund: "Refund"
        case .contribution: "Set aside"
        }
    }

    /// `category IS NULL` exactly when the type is `contribution`.
    public func acceptsCategory(_ category: String?) -> Bool {
        (self == .contribution) == (category == nil)
    }
}

/// The inputs every financial identity reads. Deleted rows never count.
public struct LedgerRow: Codable, Equatable, Sendable {
    public var type: TransactionType
    public var amountMinor: Int
    public var category: String?
    public var merchant: String?
    public var localDate: LocalDate?
    public var isDeleted: Bool
    public var recurringRuleID: String?
    public var occurrenceDate: LocalDate?

    public init(type: TransactionType, amountMinor: Int, category: String? = nil, merchant: String? = nil,
                localDate: LocalDate? = nil, isDeleted: Bool = false, recurringRuleID: String? = nil,
                occurrenceDate: LocalDate? = nil) {
        self.type = type
        self.amountMinor = amountMinor
        self.category = category
        self.merchant = merchant
        self.localDate = localDate
        self.isDeleted = isDeleted
        self.recurringRuleID = recurringRuleID
        self.occurrenceDate = occurrenceDate
    }
}

/// Maximum amount accepted anywhere (API bound carried from Noted).
public let maximumAmountMinor = 10_000_000_000
