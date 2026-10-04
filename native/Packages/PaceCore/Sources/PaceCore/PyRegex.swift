import Foundation

/// A thin wrapper over ICU regular expressions with Python `re` call shapes
/// (`search`, `match` at a position, `fullmatch`, `finditer`, `split`, `sub`).
/// Ported patterns keep their Python spelling so parity is reviewable.
struct PyRegex: @unchecked Sendable {
    private let regex: NSRegularExpression
    /// `\A(?:pattern)\z`, so full matches backtrack like Python's `fullmatch`.
    private let whole: NSRegularExpression

    init(_ pattern: String) {
        // Patterns are compile-time constants; an invalid one is a programming error.
        regex = try! NSRegularExpression(pattern: pattern)
        whole = try! NSRegularExpression(pattern: "\\A(?:\(pattern))\\z")
    }

    struct Match {
        let source: NSString
        let result: NSTextCheckingResult

        func group(_ index: Int = 0) -> String? {
            let range = result.range(at: index)
            return range.location == NSNotFound ? nil : source.substring(with: range)
        }

        var start: Int { result.range.location }
        var end: Int { result.range.location + result.range.length }
    }

    private static let options: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]

    func search(_ text: String, from position: Int = 0) -> Match? {
        let source = text as NSString
        guard position <= source.length,
              let result = regex.firstMatch(in: text, options: Self.options,
                                            range: NSRange(location: position, length: source.length - position))
        else { return nil }
        return Match(source: source, result: result)
    }

    /// Python `pattern.match(text, pos)`: anchored at `position`.
    func match(_ text: String, at position: Int) -> Match? {
        let source = text as NSString
        guard position <= source.length,
              let result = regex.firstMatch(in: text, options: Self.options.union(.anchored),
                                            range: NSRange(location: position, length: source.length - position))
        else { return nil }
        return Match(source: source, result: result)
    }

    func fullMatch(_ text: String) -> Match? {
        let source = text as NSString
        guard let result = whole.firstMatch(in: text, options: Self.options,
                                            range: NSRange(location: 0, length: source.length)) else { return nil }
        return Match(source: source, result: result)
    }

    func finditer(_ text: String) -> [Match] {
        let source = text as NSString
        return regex.matches(in: text, options: Self.options, range: NSRange(location: 0, length: source.length))
            .map { Match(source: source, result: $0) }
    }

    func findall(_ text: String) -> [String] { finditer(text).map { $0.group()! } }

    func split(_ text: String) -> [String] {
        let source = text as NSString
        var parts: [String] = []
        var cursor = 0
        for match in finditer(text) {
            parts.append(source.substring(with: NSRange(location: cursor, length: match.start - cursor)))
            cursor = match.end
        }
        parts.append(source.substring(from: cursor))
        return parts
    }

    func sub(_ text: String, _ replacement: String) -> String {
        regex.stringByReplacingMatches(in: text, options: Self.options,
                                       range: NSRange(location: 0, length: (text as NSString).length),
                                       withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    static func escape(_ text: String) -> String { NSRegularExpression.escapedPattern(for: text) }
}

/// Python's `int()` over a regex digit group: any Unicode decimal digits.
func pyInt(_ text: String) -> Int? {
    guard !text.isEmpty else { return nil }
    var value = 0
    for character in text {
        guard let digit = character.wholeNumberValue, character.isNumber, (0...9).contains(digit) else { return nil }
        let (shifted, overflow1) = value.multipliedReportingOverflow(by: 10)
        let (next, overflow2) = shifted.addingReportingOverflow(digit)
        guard !overflow1, !overflow2 else { return nil }
        value = next
    }
    return value
}
