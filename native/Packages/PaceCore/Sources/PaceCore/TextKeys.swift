import Foundation

/// Port of `noted.normalize.canonical_text`: NFKC, Unicode case folding,
/// intra-word hyphens to spaces, whitespace collapsed.
public func canonicalText(_ text: String) -> String {
    var value = text.precomposedStringWithCompatibilityMapping
        .folding(options: .caseInsensitive, locale: nil)
        .replacingOccurrences(of: "\u{2019}", with: "'")
    value = TextPatterns.intraWordHyphen.sub(value, " ")
    return TextPatterns.whitespace.sub(value, " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Port of `noted.merchants.merchant_key`: the exact-match key for merchant aliases.
public func merchantKey(_ value: String) -> String {
    let folded = value.folding(options: .caseInsensitive, locale: nil)
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .decomposedStringWithCompatibilityMapping
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: folded.unicodeScalars.filter { $0.properties.canonicalCombiningClass == .notReordered })
    var key = TextPatterns.apostropheOrAmpersand.sub(String(scalars), " ")
    key = TextPatterns.companySuffix.sub(key, " ")
    return TextPatterns.nonAlphanumeric.sub(key, " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

enum TextPatterns {
    static let intraWordHyphen = PyRegex(#"(?<=\w)-(?=\w)"#)
    static let whitespace = PyRegex(#"\s+"#)
    static let apostropheOrAmpersand = PyRegex(#"['&]"#)
    static let companySuffix = PyRegex(#"\b(?:sdn\s*bhd|s\s*/\s*b)\b"#)
    static let nonAlphanumeric = PyRegex(#"[^a-z0-9]+"#)
}
