import Foundation

/// Ports of the PWA entry rules in `public/ui-core.js` (keypad limits,
/// note → merchant mapping, category defaults). Parity: `fixtures/golden/keypad.jsonl`,
/// `note_fields.jsonl`, `categories.jsonl`.
public enum Keypad {
    public enum Key: Hashable, Sendable {
        case digit(Int), point, delete
    }

    /// `keypadAmount`: at most 7 digits, at most 2 decimals, a leading zero is replaced.
    public static func apply(_ key: Key, to current: String) -> String {
        switch key {
        case .delete:
            return String(current.dropLast())
        case .point:
            return current.contains(".") ? current : (current.isEmpty ? "0" : current) + "."
        case let .digit(value):
            guard (0...9).contains(value) else { return current }
            if let dot = current.firstIndex(of: "."), current[current.index(after: dot)...].count >= 2 { return current }
            if current.filter(\.isASCIIDigit).count >= 7 { return current }
            if current == "0" { return String(value) }
            return current + String(value)
        }
    }

    /// `amountMinor` for keypad and pasted text-field strings, exact (no floating point).
    public static func amountMinor(_ value: String) -> Int {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              parts.count == 1 || parts[1].count <= 2,
              let whole = parts[0].isEmpty ? 0 : Int(parts[0]), whole <= maximumAmountMinor / 100 else { return 0 }
        let fraction = parts.count == 2 ? Int(String((parts[1] + "00").prefix(2))) ?? 0 : 0
        return whole * 100 + fraction
    }

    public static func isValid(_ value: String) -> Bool {
        let minor = amountMinor(value)
        return minor > 0 && minor <= maximumAmountMinor
    }
}

public enum EntryRules {
    public static let categories = [
        "Food & Drink", "Groceries", "Transport", "Shopping", "Bills & Utilities", "Health", "Entertainment",
        "Education", "Services", "Travel", "Gifts & Donations", "Income", "Other",
    ]

    /// `noteFields`: a short label is a merchant; a sentence is a description.
    public static func noteFields(_ note: String) -> (merchant: String, description: String) {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ("", "") }
        let endsLikeSentence = text.range(of: #"[.!?]\s*$"#, options: .regularExpression) != nil
        return text.utf16.count <= 60 && !endsLikeSentence ? (text, "") : ("", text)
    }

    public static func categoryChoices(for type: TransactionType) -> [String] {
        switch type {
        case .contribution: []
        case .income: ["Income"]
        case .expense, .refund: categories.filter { $0 != "Income" }
        }
    }

    /// `transactionCategory`: the category a saved row carries for its type.
    public static func category(for type: TransactionType, selected: String? = "Other",
                                remembered: String? = "Other") -> String? {
        switch type {
        case .income: return "Income"
        case .contribution: return nil
        case .expense, .refund:
            if let selected, !selected.isEmpty, selected != "Income" { return selected }
            if let remembered, !remembered.isEmpty, remembered != "Income" { return remembered }
            return "Other"
        }
    }
}
