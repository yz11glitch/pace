import Foundation

/// OCR's text and geometry are evidence. This type deliberately has no Vision dependency,
/// so payment interpretation can be tested with fixed observations.
public struct ScreenshotTextLine: Sendable, Codable, Equatable {
    public let text: String
    public let confidence: Double
    public let x: Double
    public let y: Double // Distance from the top, normalized to 0...1.
    public let width: Double
    public let height: Double
    public let pass: String
    public let alternates: [String]

    public init(_ text: String, confidence: Double = 1, x: Double = 0, y: Double = 0,
                width: Double = 1, height: Double = 0.03, pass: String = "primary",
                alternates: [String] = []) {
        self.text = text; self.confidence = confidence; self.x = x; self.y = y
        self.width = width; self.height = height; self.pass = pass; self.alternates = alternates
    }

    private enum CodingKeys: String, CodingKey {
        case text, confidence, x, y, width, height, pass, alternates
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try values.decode(String.self, forKey: .text),
                  confidence: try values.decode(Double.self, forKey: .confidence),
                  x: try values.decode(Double.self, forKey: .x),
                  y: try values.decode(Double.self, forKey: .y),
                  width: try values.decode(Double.self, forKey: .width),
                  height: try values.decode(Double.self, forKey: .height),
                  pass: try values.decodeIfPresent(String.self, forKey: .pass) ?? "primary",
                  alternates: try values.decodeIfPresent([String].self, forKey: .alternates) ?? [])
    }
}

public enum ScreenshotDetection: String, Sendable { case payment, notPayment }

public struct ScreenshotInterpretation: Sendable {
    public let detection: ScreenshotDetection
    public let parser: String
    public let provider: String?
    public let amountMinor: Int?
    public let amountText: String?
    public let amountTrust: CaptureFieldTrust
    public let amountCandidates: [String]
    public let merchant: String?
    public let merchantTrust: CaptureFieldTrust
    public let reference: String?
    public let occurredAt: Instant?
    public let dateTrust: CaptureFieldTrust
    public let statusClean: Bool
    public let extractionAmbiguous: Bool
    public let reason: String
    public let evidence: [String]
}

/// Provider parsers can be registered once real screenshots establish their layout.
/// A parser must return nil if its actual template is not recognized.
public protocol ScreenshotPaymentParser: Sendable {
    var identifier: String { get }
    func parse(_ lines: [ScreenshotTextLine], capturedAt: Instant, timeZone: String) -> ScreenshotInterpretation?
}

struct LegacyScreenshotInterpreter: Sendable {
    public var templates: [any ScreenshotPaymentParser]
    public init(templates: [any ScreenshotPaymentParser] = []) { self.templates = templates }

    public func interpret(_ lines: [ScreenshotTextLine], capturedAt: Instant,
                          timeZone: String) -> ScreenshotInterpretation {
        let ordered = Self.rows(lines)
        let text = ordered.map(\.text).joined(separator: "\n")
        let statusPhrases = [#"(?i)\bpayment\s+(?:successful|completed|success|unsuccessful|failed|pending)\b"#,
                             #"(?i)\btransaction\s+(?:successful|failed)\b"#,
                             #"(?i)\btransfer\s+(?:successful|failed)\b"#,
                             #"(?i)\b(?:pembayaran|bayaran)\s+berjaya\b"#]
        let statusEvidence = statusPhrases.contains { Self.matches(text, $0) }
        let payeeEvidence = Self.matches(text, #"(?i)\b(paid\s+to|you\s+paid)\b"#)
        let duitNowEvidence = Self.matches(text, #"(?i)\bduitnow\b"#) &&
            Self.matches(text, #"(?i)\b(paid|payment|berjaya|successful|transaction)\b"#)
        let weakPaymentEvidence = Self.matches(text, #"(?i)\bRM\s*\d|\d[\d.,]*\s*MYR\b"#) &&
            Self.matches(text, #"(?i)\b(merchant|payee|recipient)\s*[:\-]"#) &&
            Self.matches(text, #"(?i)\b(reference|transaction\s+(?:id|no))\b"#)
        guard statusEvidence || payeeEvidence || duitNowEvidence || weakPaymentEvidence else {
            return .init(detection: .notPayment, parser: "detector", provider: nil,
                         amountMinor: nil, amountText: nil, amountTrust: .unresolved,
                         amountCandidates: [], merchant: nil, merchantTrust: .unresolved,
                         reference: nil, occurredAt: nil, dateTrust: .unresolved,
                         statusClean: false, extractionAmbiguous: false,
                         reason: "no payment confirmation evidence", evidence: Array(ordered.prefix(8).map(\.text)))
        }
        for template in templates {
            if let result = template.parse(lines, capturedAt: capturedAt, timeZone: timeZone) { return result }
        }
        return Self.generic(ordered, capturedAt: capturedAt, timeZone: timeZone,
                            statusUncertain: weakPaymentEvidence && !statusEvidence && !payeeEvidence && !duitNowEvidence)
    }

    private struct Row {
        var text: String
        var confidence: Double
        var x: Double
        var y: Double
    }

    private static func rows(_ lines: [ScreenshotTextLine]) -> [Row] {
        var groups: [[ScreenshotTextLine]] = []
        for line in lines.filter({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .sorted(by: { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }) {
            if let index = groups.indices.last, abs(groups[index][0].y - line.y) <= 0.018 {
                groups[index].append(line)
            } else { groups.append([line]) }
        }
        return groups.map { group in
            let sorted = group.sorted { $0.x < $1.x }
            return Row(text: sorted.map(\.text).joined(separator: " "),
                       confidence: sorted.map(\.confidence).min() ?? 0,
                       x: sorted[0].x, y: sorted[0].y)
        }
    }

    private struct AmountCandidate {
        var text: String
        var minor: Int?
        var row: Int
        var score: Int
        var confidence: Double
    }

    private static func generic(_ rows: [Row], capturedAt: Instant,
                                timeZone: String, statusUncertain: Bool) -> ScreenshotInterpretation {
        let fullText = rows.map(\.text).joined(separator: "\n")
        let failed = matches(fullText, #"(?i)\b(failed|unsuccessful|pending|declined|rejected|gagal|tidak\s+berjaya|refund|reversed)\b"#)
        let foreignCurrency = matches(fullText, #"(?i)\b(USD|SGD|EUR|GBP)\b"#)
        var candidates: [AmountCandidate] = []
        let currencyPattern = #"(?i)(?<![A-Z0-9])(?:RM\s*[0-9][0-9.,]*|[0-9][0-9.,]*\s*MYR)(?![A-Z0-9.,])"#
        for (index, row) in rows.enumerated() {
            for value in captures(row.text, pattern: currencyPattern) {
                let previous = index > 0 ? rows[index - 1].text : ""
                let totalLabel = #"(?i)\b(amount\s+paid|payment\s+amount|total\s+paid|total|jumlah|paid)\b"#
                let excludedLabel = #"(?i)\b(balance|available|cashback|service\s+fee|charges|change|baki|wallet\s+balance)\b"#
                let currentStrong = matches(row.text, totalLabel)
                let strong = currentStrong || matches(previous, totalLabel)
                let excluded = matches(row.text, excludedLabel) || (!currentStrong && matches(previous, excludedLabel))
                candidates.append(.init(text: value, minor: parseMYR(value), row: index,
                                        score: excluded ? -1 : strong ? 2 : 0,
                                        confidence: row.confidence))
            }
        }
        let viable = candidates.filter { $0.score >= 0 && $0.minor != nil }
        let strong = viable.filter { $0.score == 2 }
        let central = viable.count == 1 && rows[viable[0].row].y <= 0.45 &&
            matches(fullText, #"(?i)\b(successful|completed|success|berjaya)\b"#)
        let chosen: AmountCandidate? = strong.count == 1 ? strong[0] : central ? viable[0] : nil
        let ambiguous = (viable.count > 1 && chosen == nil) ||
            candidates.contains(where: { $0.minor == nil && $0.score >= 0 }) ||
            (chosen != nil && chosen!.confidence < 0.80) || foreignCurrency
        let amountTrust: CaptureFieldTrust = chosen != nil && !ambiguous ? .trusted : .unresolved

        var merchants: [(text: String, confidence: Double)] = []
        for (index, row) in rows.enumerated() {
            let pattern = #"(?i)\b(?:paid\s+to|merchant|payee|recipient)\s*[:\-]?\s*(.*)$"#
            let labelled = captures(row.text, pattern: pattern, group: 1).first
            // A bare "to" is meaningful only as a whole payee row, immediately below
            // the payment amount on a screen with positive completion evidence.
            let toPayee = captures(row.text, pattern: #"(?i)^to\s+(.+)$"#, group: 1).first
            let amountAbove = chosen.map { row.y > rows[$0.row].y && row.y - rows[$0.row].y <= 0.25 } ?? false
            let completedScreen = matches(fullText, #"(?i)\b(completed|successful|berjaya)\b"#) &&
                matches(fullText, #"(?i)\b(payment|transaction|duitnow)\b"#)
            guard let raw = labelled ?? (amountAbove && completedScreen ? toPayee : nil) else { continue }
            let next = index + 1 < rows.count ? rows[index + 1].text : ""
            let value = (raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? next : raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2 && value.count <= 100 && value.rangeOfCharacter(from: .letters) != nil &&
                !matches(value, #"(?i)\b(RM|MYR|reference|transaction|successful|completed)\b"#) {
                merchants.append((value, row.confidence))
            }
        }
        let distinctMerchants = Array(Set(merchants.map { $0.text.lowercased() }))
        let merchant = distinctMerchants.count == 1 ? merchants.first?.text : nil
        let merchantConfidence = merchants.map(\.confidence).min() ?? 0
        let referencePattern = #"(?i)^(?:reference(?:\s+(?:id|number|no))?|transaction\s+(?:id|no)|ref(?:\s+no)?)\s*(?:[:#\-]\s*|\s+)([A-Z0-9][A-Z0-9\-]{4,39})\s*$"#
        let referenceLabel = #"(?i)^(?:reference(?:\s+(?:id|number|no))?|transaction\s+(?:id|no)|ref(?:\s+no)?)\s*[:#\-]?\s*$"#
        var references: [String] = []
        for (index, row) in rows.enumerated() where row.confidence >= 0.80 {
            if let value = captures(row.text, pattern: referencePattern, group: 1).first {
                references.append(value)
            } else if matches(row.text, referenceLabel), index + 1 < rows.count {
                let next = rows[index + 1]
                if next.confidence >= 0.80 && next.y - row.y <= 0.10 &&
                    abs(next.x - row.x) <= 0.55 &&
                    matches(next.text, #"(?i)^[A-Z0-9][A-Z0-9\-]{4,39}$"#) &&
                    matches(next.text, #"\d"#) {
                    references.append(next.text)
                }
            }
        }
        let reference = Set(references.map { $0.uppercased() }).count == 1 ? references.first : nil
        let date = explicitDate(rows, capturedAt: capturedAt, timeZone: timeZone)
        let evidence = rows.enumerated().filter { index, row in
            candidates.contains(where: { $0.row == index }) ||
            (merchant.map { row.text.localizedCaseInsensitiveContains($0) } ?? false) ||
            matches(row.text, #"(?i)\b(paid|payment|berjaya|successful|completed|merchant|payee|recipient|reference|transaction|date|time|category|duitnow)\b"#) ||
            matches(row.text, #"\b\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}\b"#)
        }.prefix(12).map { String($0.element.text.prefix(160)) }
        return .init(detection: .payment, parser: "generic", provider: nil,
                     amountMinor: chosen?.minor, amountText: chosen?.text, amountTrust: amountTrust,
                     amountCandidates: candidates.map(\.text), merchant: merchant,
                     merchantTrust: merchant == nil || merchantConfidence < 0.80 ? .unresolved : .usable,
                     reference: reference, occurredAt: date.instant, dateTrust: date.trust,
                     statusClean: !failed && !statusUncertain, extractionAmbiguous: ambiguous,
                     reason: failed || statusUncertain ? "payment status needs review" : ambiguous ? "amount evidence is ambiguous" :
                        chosen == nil ? "amount not found" : "generic payment evidence",
                     evidence: evidence)
    }

    private static func explicitDate(_ rows: [Row], capturedAt: Instant,
                                     timeZone: String) -> (instant: Instant?, trust: CaptureFieldTrust) {
        let numeric = #"\b\d{2}/\d{2}/\d{4}\s+\d{1,2}:\d{2}\b"#
        let monthName = #"(?i)\b\d{1,2}\s+[A-Z]{3,9}\s+\d{4},?\s+\d{1,2}:\d{2}\s*[AP]M\b"#
        var found: [String: Double] = [:]
        for (index, row) in rows.enumerated() {
            let combined = index + 1 < rows.count && rows[index + 1].y - row.y <= 0.08
                ? row.text + " " + rows[index + 1].text : row.text
            let confidence = combined == row.text ? row.confidence : min(row.confidence, rows[index + 1].confidence)
            for value in captures(combined, pattern: numeric) + captures(combined, pattern: monthName) {
                found[value] = max(found[value] ?? 0, confidence)
            }
        }
        guard found.count == 1, let (value, confidence) = found.first,
              confidence >= 0.80, let zone = Zone(identifier: timeZone) else {
            return (nil, found.isEmpty ? .trusted : .unresolved)
        }
        let parts = value.replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        let day: LocalDate?
        let hour: Int
        let minute: Int
        if value.contains("/") {
            guard parts.count == 5, let d = Int(parts[0]), let m = Int(parts[1]),
                  let y = Int(parts[2]), let h = Int(parts[3]), let min = Int(parts[4]) else {
                return (nil, .unresolved)
            }
            day = LocalDate(year: y, month: m, day: d); hour = h; minute = min
        } else {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard parts.count == 6, let d = Int(parts[0]),
                  let m = months.firstIndex(of: String(parts[1].lowercased().prefix(3))),
                  let y = Int(parts[2]), let h = Int(parts[3]), let min = Int(parts[4]),
                  (1...12).contains(h) else { return (nil, .unresolved) }
            day = LocalDate(year: y, month: m + 1, day: d)
            hour = h % 12 + (parts[5].uppercased() == "PM" ? 12 : 0); minute = min
        }
        guard let day, (0...23).contains(hour), (0...59).contains(minute) else { return (nil, .unresolved) }
        let instant = zone.instant(for: LocalDateTime(date: day, secondOfDay: hour * 3_600 + minute * 60), fold: 0)
        let age = capturedAt.seconds - instant.seconds
        return (instant, age < -600 || age > 7 * 86_400 ? .unresolved : age > 86_400 ? .usable : .trusted)
    }

    private static func parseMYR(_ raw: String) -> Int? {
        var text = raw.uppercased().replacingOccurrences(of: "MYR", with: "")
            .replacingOccurrences(of: "RM", with: "").trimmingCharacters(in: .whitespaces)
        guard matches(text, #"^(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{2})?$"#) else { return nil }
        text = text.replacingOccurrences(of: ",", with: "")
        let pieces = text.split(separator: ".")
        guard let major = Int(pieces[0]), major <= 100_000_000 else { return nil }
        let cents = pieces.count == 2 ? Int(pieces[1]) ?? 0 : 0
        let minor = major * 100 + cents
        return (1...10_000_000_000).contains(minor) ? minor : nil
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func captures(_ text: String, pattern: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > group, let value = Range(match.range(at: group), in: text) else { return nil }
            return String(text[value])
        }
    }
}

public struct ScreenshotInterpreter: Sendable {
    public var templates: [any ScreenshotPaymentParser]
    public init(templates: [any ScreenshotPaymentParser] = []) { self.templates = templates }

    public func interpret(_ lines: [ScreenshotTextLine], capturedAt: Instant,
                          timeZone: String) -> ScreenshotInterpretation {
        // G3 keeps the historical detection decision while replacing accepted screens' fields.
        let legacy = LegacyScreenshotInterpreter(templates: templates)
            .interpret(lines, capturedAt: capturedAt, timeZone: timeZone)
        guard legacy.detection == .payment, legacy.parser == "generic",
              !templates.contains(where: { $0.identifier == legacy.parser }) else { return legacy }
        let fields = ScreenshotFieldExtraction(capturedAt: capturedAt, timeZone: timeZone)
            .extractFields(lines)
        return .init(detection: legacy.detection, parser: "generic", provider: nil,
                     amountMinor: fields.amountMinor, amountText: fields.amountText,
                     amountTrust: fields.amountTrust, amountCandidates: fields.amountCandidates,
                     merchant: fields.merchant, merchantTrust: fields.merchantTrust,
                     reference: fields.referenceText, occurredAt: fields.occurredAt,
                     dateTrust: fields.dateTrust, statusClean: legacy.statusClean,
                     extractionAmbiguous: fields.extractionAmbiguous,
                     reason: fields.extractionAmbiguous ? "amount evidence is ambiguous" :
                        fields.amountMinor == nil ? "amount not found" : "generic payment evidence",
                     evidence: legacy.evidence)
    }
}

public struct ScreenshotCaptureAdapter: CaptureInputAdapter {
    public init() {}
    public func adapt(_ payload: (interpretation: ScreenshotInterpretation, imageHash: String),
                      capturedAt: Instant, timeZone: String) -> CaptureRequest {
        let result = payload.interpretation
        return CaptureRequest(source: "screenshot", path: result.provider.map { "screenshot_\($0)" } ?? "screenshot_generic",
                              amountMinor: result.amountMinor, merchant: result.merchant,
                              occurredAt: result.occurredAt, capturedAt: capturedAt, timeZone: timeZone,
                              reference: result.reference, idempotencyKey: "screenshot:\(payload.imageHash)",
                              rawFields: ["imageHash": payload.imageHash],
                              amountTrust: result.amountTrust, merchantTrust: result.merchantTrust,
                              dateTrust: result.dateTrust, statusClean: result.statusClean,
                              extractionAmbiguous: result.extractionAmbiguous,
                              amountCandidates: result.amountCandidates)
    }
}
