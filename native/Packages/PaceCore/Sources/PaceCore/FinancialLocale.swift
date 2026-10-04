/// Pace's financial locale: money and date semantics that never come from the
/// device region. The developer's test device is English / United States; the
/// financial locale is Malaysia / MYR.
public struct FinancialLocale: Codable, Equatable, Sendable {
    public enum DateOrder: String, Codable, Sendable { case dayFirst }

    public let identifier: String
    public let currencyCode: String
    public let currencySymbol: String
    public let numericDateOrder: DateOrder
    /// Vision OCR languages, chosen by the financial locale.
    public let ocrLanguages: [String]
    /// Calendar presentation follows the financial locale, never the device region.
    /// 0 = Monday, 6 = Sunday (matching LocalDate.weekday).
    public let weekStart: Int

    public static let malaysia = FinancialLocale(
        identifier: "MY", currencyCode: "MYR", currencySymbol: "RM",
        numericDateOrder: .dayFirst, ocrLanguages: ["en-US", "ms-MY"], weekStart: 0)
}

/// Pace's money language: `RM 1,234.56`, full cents, en-MY grouping. Built by
/// hand from integer minor units — no system number formatting, so a US-region
/// device can never render "MYR 18.00" or "$18.00".
public struct MoneyFormat: Sendable {
    public let locale: FinancialLocale

    public init(locale: FinancialLocale = .malaysia) { self.locale = locale }

    /// `RM 3,500.00`. Negative values keep their sign: `−RM 12.00`.
    public func string(_ minor: Int) -> String {
        minor < 0 ? "\u{2212}\(unsigned(-minor))" : unsigned(minor)
    }

    /// A flow-direction amount as in the visual identity spec:
    /// `− RM 18.00`, `+ RM 2,600.00`, `↑ RM 500.00`.
    public func flow(_ minor: Int, type: TransactionType) -> String {
        switch type {
        case .expense: "\u{2212} \(unsigned(minor))"
        case .income, .refund: "+ \(unsigned(minor))"
        case .contribution: "\u{2191} \(unsigned(minor))"
        }
    }

    /// A natural VoiceOver form independent of the phone's region and currency settings.
    public func spoken(_ minor: Int) -> String {
        let magnitude = abs(minor)
        let ringgit = magnitude / 100
        let sen = magnitude % 100
        let value = sen == 0 ? "\(ringgit) ringgit" : "\(ringgit) ringgit \(sen)"
        return minor < 0 ? "minus \(value)" : value
    }

    public func spokenFlow(_ minor: Int, type: TransactionType) -> String {
        let value = spoken(minor)
        switch type {
        case .expense: return "minus \(value)"
        case .income, .refund: return "plus \(value)"
        case .contribution: return "set aside \(value)"
        }
    }

    /// Digits only, for the keypad display: `1,234.50`.
    public func digits(_ minor: Int) -> String {
        let whole = String(minor / 100)
        var grouped = ""
        for (index, character) in whole.enumerated() {
            if index > 0, (whole.count - index) % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        let cents = minor % 100
        return "\(grouped).\(cents < 10 ? "0" : "")\(cents)"
    }

    private func unsigned(_ minor: Int) -> String { "\(locale.currencySymbol) \(digits(minor))" }
}
