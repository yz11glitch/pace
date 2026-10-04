import Foundation

/// Port of `noted.normalize.recover_amount` — the most important safety code in
/// Pace. Rules, order, tiers and reasons match the Python oracle exactly
/// (`fixtures/golden/amounts.jsonl`). An ambiguous bare 3–4 digit amount such
/// as "1250" never resolves without a prior: it returns the two alternatives.
public struct AmountResolution: Equatable, Sendable {
    public var amountMinor: Int?
    public var currency: String
    public var provisionalTier: String
    public var rung: Int?
    public var surfaceForm: String
    public var surfaceClass: String
    public var alternativesMinor: [Int]
    public var reason: String

    public init(_ amountMinor: Int?, _ provisionalTier: String, _ rung: Int?, _ surfaceForm: String,
                _ surfaceClass: String, _ alternativesMinor: [Int] = [], reason: String) {
        self.amountMinor = amountMinor
        self.currency = "MYR"
        self.provisionalTier = provisionalTier
        self.rung = rung
        self.surfaceForm = surfaceForm
        self.surfaceClass = surfaceClass
        self.alternativesMinor = alternativesMinor
        self.reason = reason
    }
}

/// Personal magnitude priors (`recover_amount`'s `priors` dict).
public struct AmountPriors: Codable, Sendable {
    public struct Merchant: Codable, Sendable {
        public var name: String?
        public var aliases: [String]?
        public var amountCount: Int?
        public var amountMinMinor: Int?
        public var amountMaxMinor: Int?
        public var amountMedianMinor: Int?

        enum CodingKeys: String, CodingKey {
            case name, aliases
            case amountCount = "amount_count", amountMinMinor = "amount_min_minor"
            case amountMaxMinor = "amount_max_minor", amountMedianMinor = "amount_median_minor"
        }
    }

    public struct Global: Codable, Sendable {
        public var amountCount: Int?
        public var amountP99Minor: Int?

        enum CodingKeys: String, CodingKey {
            case amountCount = "amount_count", amountP99Minor = "amount_p99_minor"
        }
    }

    public struct Category: Codable, Sendable {
        public var name: String?
        public var keywords: [String]?
        public var amountMinMinor: Int?
        public var amountMaxMinor: Int
        public var amountMedianMinor: Int?

        enum CodingKeys: String, CodingKey {
            case name, keywords
            case amountMinMinor = "amount_min_minor", amountMaxMinor = "amount_max_minor"
            case amountMedianMinor = "amount_median_minor"
        }
    }

    public var merchants: [Merchant]?
    public var global: Global?
    public var categories: [Category]?

    public init(merchants: [Merchant]? = nil, global: Global? = nil, categories: [Category]? = nil) {
        self.merchants = merchants
        self.global = global
        self.categories = categories
    }
}

public enum AmountNormalizer {
    static let ones: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let numberWords: Set<String> = Set(ones.keys).union(tens.keys).union(["and", "hundred", "thousand", "point"])
    static let minorWords: Set<String> = ["sen", "cent", "cents"]
    static let currencyWords: Set<String> = Set(["ringgit", "dollar", "dollars"]).union(minorWords)

    private static let numberWordPattern: String = {
        let words = numberWords.subtracting(["point", "and"]).sorted { ($0.count, $1) > ($1.count, $0) }
        return "(?:" + words.joined(separator: "|") + ")"
    }()

    static let minorSuffix = PyRegex(
        #"\s+(?:and\s+)?(?:([0-9]+)\s*(?:sen|cents?)\b|¢\s*([0-9]+)\b|([0-9]+)\s*¢"#
            + "|((?:\(numberWordPattern)\\s+)*\(numberWordPattern))\\s+(?:sen|cents?)\\b)")
    static let minorOnly = PyRegex(#"(?<![\w.])([0-9]+)\s*(?:sen|cents?)\b|¢\s*([0-9]+)\b|(?<![\w.])([0-9]+)\s*¢"#)
    static let alternativesSplit = PyRegex(#"\b(?:or|versus)\b"#)
    static let thousands = PyRegex(#"\b([0-9]{1,3}(?:,[0-9]{3})+)\b"#)
    static let rmPrefixed = PyRegex(#"\brm\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)\b"#)
    static let decimalDigits = PyRegex(#"\b([0-9]+)\.([0-9]{1,2})\b"#)
    static let ringgitSuffixed = PyRegex(#"(?<![\w.])([0-9]+)\s+ringgit\b"#)
    static let twoDigitSeparator = PyRegex(#"\b([0-9]{1,3})[, ]([0-9]{2})\b"#)
    static let asciiWords = PyRegex(#"[a-z]+"#)
    static let bareThreeOrFour = PyRegex(#"(?<![\w.])([0-9]{3,4})(?![\w.])"#)
    static let bareOneOrTwo = PyRegex(#"(?<![\w.])([0-9]{1,2})(?![\w.])"#)
    static let nonWord = PyRegex(#"[^\w\s]"#)

    // MARK: - Word numbers

    static func parseCardinal(_ tokens: [String]) -> Int? {
        let allowed = numberWords.subtracting(["point"])
        guard !tokens.isEmpty, tokens.allSatisfy(allowed.contains) else { return nil }
        var current = 0, total = 0
        var sawNumber = false
        for token in tokens where token != "and" {
            sawNumber = true
            if let value = ones[token] {
                current += value
            } else if let value = tens[token] {
                current += value
            } else if token == "hundred" {
                current = max(1, current) * 100
            } else if token == "thousand" {
                total += max(1, current) * 1000
                current = 0
            }
        }
        return sawNumber ? total + current : nil
    }

    static func twoPart(_ tokens: [String]) -> (Int, Int)? {
        guard tokens.count > 1 else { return nil }
        for split in 1..<tokens.count {
            if let left = parseCardinal(Array(tokens[..<split])), (0...99).contains(left),
               let right = parseCardinal(Array(tokens[split...])), (0...99).contains(right),
               tens[tokens[split]] != nil, right >= 10 {
                return (left, right)
            }
        }
        return nil
    }

    // MARK: - Minor units

    private enum MinorSuffix { case none, value(Int, end: Int), outOfRange }

    private static func minorSuffix(_ normalized: String, _ end: Int) -> MinorSuffix {
        guard let match = minorSuffix.match(normalized, at: end) else { return .none }
        let value: Int?
        if let digits = match.group(1) ?? match.group(2) ?? match.group(3) {
            value = pyInt(digits)
        } else if let words = match.group(4) {
            value = parseCardinal(words.split(separator: " ").map(String.init))
        } else {
            value = nil
        }
        guard let value, (0...99).contains(value) else { return .outOfRange }
        return .value(value, end: match.end)
    }

    private static func outOfRange(_ text: String) -> AmountResolution {
        AmountResolution(nil, "C", nil, text, "other", reason: "minor-unit component outside 0-99 requires confirmation")
    }

    private static func tooLarge(_ text: String) -> AmountResolution {
        // Python has unbounded integers; Swift must not trap. No real amount is this large.
        AmountResolution(nil, "C", nil, text, "other", reason: "amount too large")
    }

    /// `Decimal(digits) * 100` for `[0-9,]+(\.[0-9]{1,2})?` without floating point.
    static func minorUnits(_ digits: String) -> Int? {
        let parts = digits.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false)
        guard let whole = pyInt(String(parts[0])) else { return nil }
        var fraction = 0
        if parts.count == 2 {
            guard let value = pyInt(String((parts[1] + "00").prefix(2))) else { return nil }
            fraction = value
        }
        let (scaled, overflow1) = whole.multipliedReportingOverflow(by: 100)
        let (total, overflow2) = scaled.addingReportingOverflow(fraction)
        return overflow1 || overflow2 ? nil : total
    }

    // MARK: - Priors

    private static func merchantPrior(_ text: String, _ priors: AmountPriors?) -> AmountPriors.Merchant? {
        let normalized = nonWord.sub(canonicalText(text), "")
        for merchant in priors?.merchants ?? [] {
            let aliases = [merchant.name ?? ""] + (merchant.aliases ?? [])
            // Python `key in normalized`; an empty key is contained in every string.
            let matches = aliases.contains { alias in
                guard !alias.isEmpty else { return false }
                let key = nonWord.sub(canonicalText(alias), "")
                return key.isEmpty || normalized.contains(key)
            }
            if matches, (merchant.amountCount ?? 0) >= 5 { return merchant }
        }
        return nil
    }

    private static func chooseWithPrior(_ integerMinor: Int, _ decimalMinor: Int,
                                        low: Int, high: Int, median: Int?) -> Int? {
        let median = median ?? (low + high) / 2
        let inRange = [integerMinor, decimalMinor].filter { low <= $0 && $0 <= high }
        if inRange.count == 1 { return inRange[0] }
        if inRange.count == 2 { return inRange.min { abs($0 - median) < abs($1 - median) } }
        return nil
    }

    private static func contextChoice(_ text: String, _ integerMinor: Int, _ decimalMinor: Int,
                                      _ priors: AmountPriors?) -> (Int, Int, String)? {
        if let prior = merchantPrior(text, priors), let low = prior.amountMinMinor, let high = prior.amountMaxMinor,
           let chosen = chooseWithPrior(integerMinor, decimalMinor, low: low, high: high, median: prior.amountMedianMinor) {
            return (chosen, 2, "merchant magnitude prior")
        }
        if let global = priors?.global, (global.amountCount ?? 0) >= 50, let p99 = global.amountP99Minor {
            let below = [integerMinor, decimalMinor].filter { $0 <= p99 }
            let above = [integerMinor, decimalMinor].filter { $0 > p99 }
            if below.count == 1, above.count == 1 { return (below[0], 3, "global personal p99 prior") }
        }
        let normalized = canonicalText(text)
        for category in priors?.categories ?? [] {
            let keywords = category.keywords ?? []
            let hit = keywords.contains { keyword in
                PyRegex(#"\b"# + PyRegex.escape(canonicalText(keyword)) + #"\b"#).search(normalized) != nil
            }
            if hit, let chosen = chooseWithPrior(integerMinor, decimalMinor, low: category.amountMinMinor ?? 0,
                                                 high: category.amountMaxMinor,
                                                 median: category.amountMedianMinor ?? category.amountMaxMinor / 2) {
                return (chosen, 4, "category prior: \(category.name ?? "unnamed")")
            }
        }
        return nil
    }

    // MARK: - The ladder

    public static func recover(_ text: String, priors: AmountPriors? = nil, wholeBare: Bool = false) -> AmountResolution {
        let normalized = canonicalText(text)

        // Two or more monetary alternatives are not one value; "20 or so" still is.
        let parts = alternativesSplit.split(normalized)
        if parts.count > 1,
           parts.filter({ recover($0, priors: priors, wholeBare: wholeBare).amountMinor != nil }).count >= 2 {
            return AmountResolution(nil, "C", nil, text, "other", reason: "multiple possible amounts require confirmation")
        }

        if let match = thousands.search(normalized) {
            guard let value = minorUnits(match.group(1)!) else { return tooLarge(text) }
            return AmountResolution(value, "A", nil, match.group()!, "bare_integer", reason: "thousands separator")
        }

        // RM-prefixed digits are explicit major units and never gain an inferred decimal point.
        if let match = rmPrefixed.search(normalized) {
            let digits = match.group(1)!
            guard let value = minorUnits(digits) else { return tooLarge(text) }
            if !digits.contains(".") {
                switch minorSuffix(normalized, match.end) {
                case .outOfRange:
                    return outOfRange(text)
                case let .value(fraction, end):
                    let surface = (normalized as NSString).substring(with: NSRange(location: match.start, length: end - match.start))
                    return AmountResolution(value + fraction, "A", nil, surface, "currency_prefixed",
                                            reason: "RM-prefixed digits with a minor-unit component")
                case .none:
                    break
                }
            }
            return AmountResolution(value, "A", nil, match.group()!, "currency_prefixed", reason: "unambiguous RM-prefixed digits")
        }

        if let match = decimalDigits.search(normalized) {
            guard let value = minorUnits("\(match.group(1)!).\(match.group(2)!)") else { return tooLarge(text) }
            return AmountResolution(value, "A", nil, match.group()!, "decimal_digits", reason: "explicit decimal digits")
        }

        // A digit integer qualified by "ringgit" is literal major units.
        if let match = ringgitSuffixed.search(normalized) {
            guard let whole = minorUnits(match.group(1)!) else { return tooLarge(text) }
            var fraction = 0
            var end = match.end
            switch minorSuffix(normalized, match.end) {
            case .outOfRange: return outOfRange(text)
            case let .value(value, suffixEnd): fraction = value; end = suffixEnd
            case .none: break
            }
            let surface = (normalized as NSString).substring(with: NSRange(location: match.start, length: end - match.start))
            return AmountResolution(whole + fraction, "A", nil, surface, "currency_suffixed",
                                    reason: "explicit digit integer qualified by ringgit")
        }

        // Comma plus two digits, or spaced two-part digits, are decimal separators (rung 1).
        if let match = twoDigitSeparator.search(normalized) {
            let group = match.group()!
            let value = pyInt(match.group(1)!)! * 100 + pyInt(match.group(2)!)!
            return AmountResolution(value, "B", 1, group, group.contains(" ") ? "spaced" : "other",
                                    reason: "two-digit separator rule")
        }

        // "50 sen", "¢50", "50¢", "50 cents" are sen, never whole ringgit.
        if let match = minorOnly.search(normalized) {
            let value = pyInt(match.group(1) ?? match.group(2) ?? match.group(3)!)
            guard let value, value > 0, value <= 99 else { return outOfRange(text) }
            return AmountResolution(value, "A", nil, match.group()!, "minor_units", reason: "explicit minor-unit digits")
        }

        var numberRuns: [[String]] = []
        var run: [String] = []
        for word in asciiWords.findall(normalized) {
            if numberWords.contains(word) || currencyWords.contains(word) {
                run.append(word)
            } else if !run.isEmpty {
                numberRuns.append(run)
                run = []
            }
        }
        if !run.isEmpty { numberRuns.append(run) }

        for originalRun in numberRuns.reversed() { // self-corrections prefer the last amount
            let surface = originalRun.joined(separator: " ")
            let run = originalRun.filter { !currencyWords.contains($0) }
            if let point = run.firstIndex(of: "point") {
                let whole = parseCardinal(Array(run[..<point]))
                let decimals = run[(point + 1)...].compactMap { ones[$0] }.filter { $0 < 10 }
                if let whole, !decimals.isEmpty {
                    let fraction = (decimals + [0, 0]).prefix(2)
                    return AmountResolution(whole * 100 + fraction[0] * 10 + fraction[1], "A", nil, surface,
                                            "word_form", reason: "explicit point form")
                }
            }
            if let split = originalRun.firstIndex(of: "ringgit") {
                let whole = parseCardinal(originalRun[..<split].filter { !currencyWords.contains($0) })
                let fraction = parseCardinal(originalRun[(split + 1)...].filter { !currencyWords.contains($0) })
                if let whole {
                    if let fraction, fraction > 99 { return outOfRange(text) }
                    return AmountResolution(whole * 100 + (fraction ?? 0), "A", nil, surface, "word_form",
                                            reason: "currency word split")
                }
            }
            if let minorIndex = originalRun.firstIndex(where: minorWords.contains) {
                let tokens = originalRun[..<minorIndex].filter { !currencyWords.contains($0) }
                if let value = parseCardinal(tokens), value > 0, twoPart(tokens) == nil {
                    if value > 99 { return outOfRange(text) }
                    return AmountResolution(value, "A", nil, surface, "word_form", reason: "minor-unit word form")
                }
            }
            let cardinal = parseCardinal(run)
            if let cardinal, run.contains("hundred") || run.contains("thousand") {
                return AmountResolution(cardinal * 100, "A", nil, surface, "word_form", reason: "magnitude word")
            }
            if let (major, minor) = twoPart(run) {
                return AmountResolution(major * 100 + minor, "B", 1, surface, "word_form",
                                        reason: "compound word form without magnitude")
            }
            // Filler such as "oh and" forms a zero-valued run; it is not an amount.
            if let cardinal, cardinal > 0 {
                return AmountResolution(cardinal * 100, "A", nil, surface, "word_form", reason: "cardinal words")
            }
        }

        // A bare 3/4 digit ITN output could be whole currency or an inserted decimal.
        if let match = bareThreeOrFour.finditer(normalized).last {
            let digits = match.group(1)!
            let integerMinor = pyInt(digits)! * 100
            let decimalMinor = pyInt(String(digits.dropLast(2)))! * 100 + pyInt(String(digits.suffix(2)))!
            if wholeBare {
                return AmountResolution(integerMinor, "A", nil, digits, "bare_integer",
                                        reason: "clear income or contribution whole-RM amount")
            }
            if let (chosen, rung, reason) = contextChoice(normalized, integerMinor, decimalMinor, priors) {
                return AmountResolution(chosen, "B", rung, digits, "bare_integer", [integerMinor, decimalMinor], reason: reason)
            }
            return AmountResolution(nil, "B'", 5, digits, "bare_integer", [decimalMinor, integerMinor],
                                    reason: "ambiguous bare integer requires confirmation")
        }

        if let match = bareOneOrTwo.search(normalized) {
            return AmountResolution(pyInt(match.group(1)!)! * 100, "A", nil, match.group(1)!, "bare_integer",
                                    reason: "unambiguous one/two-digit integer")
        }

        return AmountResolution(nil, "C", nil, "", "other", reason: "no recoverable amount")
    }
}
