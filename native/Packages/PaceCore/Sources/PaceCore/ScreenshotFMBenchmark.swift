#if DEBUG
import Foundation

/// Debug experiment data. The original G0 OCR observations are kept verbatim.
public struct ScreenshotFMBenchmarkCase: Codable, Sendable, Identifiable {
    public let id: String
    public let source: String
    public let kind: String
    public let capturedAt: String
    public let timeZone: String
    public let lines: [ScreenshotTextLine]
    public let expected: ScreenshotFMBenchmarkTruth
}

public struct ScreenshotFMBenchmarkTruth: Codable, Sendable {
    /// A transaction detail, including pending/failed attempts; checkout is not a transaction.
    public let isTransaction: Bool
    public let amountMinor: Int?
    public let merchant: String?
    public let occurredAt: String?
    public let reference: String?
}

public struct ScreenshotFMBenchmarkCorpus: Codable, Sendable {
    public let version: String
    public let seed: String
    public let cases: [ScreenshotFMBenchmarkCase]
}

/// A transport type between guided generation and the pure verifier. Evidence strings
/// must quote OCR text; nil means the model abstained on that field.
public struct ScreenshotFMClaim: Codable, Sendable {
    public let isTransaction: Bool
    public let transactionType: String
    public let state: String
    public let certainty: String
    public let amountMinor: Int?
    public let amountEvidence: String?
    public let currency: String?
    public let merchant: String?
    public let dateTimeEvidence: String?
    public let reference: String?

    public init(isTransaction: Bool, transactionType: String = "unknown", state: String = "unknown",
                certainty: String = "uncertain", amountMinor: Int? = nil, amountEvidence: String? = nil,
                currency: String? = nil, merchant: String? = nil, dateTimeEvidence: String? = nil,
                reference: String? = nil) {
        self.isTransaction = isTransaction; self.transactionType = transactionType
        self.state = state; self.certainty = certainty; self.amountMinor = amountMinor
        self.amountEvidence = amountEvidence; self.currency = currency; self.merchant = merchant
        self.dateTimeEvidence = dateTimeEvidence; self.reference = reference
    }
}

public struct ScreenshotFMVerified: Codable, Sendable {
    public let amountMinor: Int?
    public let merchant: String?
    public let occurredAt: String?
    public let reference: String?
    /// A claimed value unsupported by the supplied OCR and generic typed/semantic evidence.
    public let rejected: [String: String]
    public let evidence: [String: String]
}

public struct ScreenshotFMG3Fields: Codable, Sendable {
    public let amountMinor: Int?
    public let merchant: String?
    public let occurredAt: String?
    public let reference: String?
    public let amountTrust: String
    public let merchantTrust: String
    public let dateTrust: String
}

/// The verifier does not select missing values or decide the screen class. It only checks
/// facts proposed by the model against Vision observations already available to Pace.
public enum ScreenshotFMGrounding {
    public static func verify(_ claim: ScreenshotFMClaim, lines: [ScreenshotTextLine],
                              capturedAt: Instant, timeZone: String) -> ScreenshotFMVerified {
        let layout = ScreenshotLayout(lines)
        let spans = ScreenshotSpans(layout, capturedAt: capturedAt, timeZone: timeZone)
        let relations = ScreenshotRelations(spans)
        var rejected: [String: String] = [:], evidence: [String: String] = [:]
        var amount: Int?, merchant: String?, occurredAt: String?, reference: String?

        if claim.amountMinor != nil || claim.amountEvidence != nil || claim.currency != nil {
            if let minor = claim.amountMinor, let quote = nonempty(claim.amountEvidence),
               let span = spans.of(.money).first(where: { candidate in
                   candidate.money?.minorUnits == Int64(minor) && equivalent(candidate.reading, quote) &&
                   (claim.currency == nil || candidate.money?.currency?.caseInsensitiveCompare(claim.currency!) == .orderedSame) &&
                   !excludedAmount(candidate, relations: relations)
               }) {
                amount = minor; evidence["amount"] = span.reading
            } else { rejected["amount"] = "amount, currency, or quoted OCR money evidence does not agree" }
        }
        if let value = nonempty(claim.merchant) {
            let candidate = normalized(value)
            let blocked = Set(relations.pairs.filter {
                [.source, .memo, .typeCategory, .nonTransactionIdentifier, .unknownLabel].contains($0.label.concept)
            }.flatMap(\.valueTokenIDs))
            let supported = !candidate.isEmpty && value.contains(where: \.isLetter) &&
                ScreenshotLabels.concept(for: value) == nil &&
                !ScreenshotLexicon.words.contains(candidate) &&
                !spans.spans.contains(where: { span in
                    [.money, .date, .dateTime, .identifier, .cardMask, .phone, .clock, .percent].contains(span.kind) &&
                    normalized(span.reading) == candidate
                }) &&
                layout.tokens.contains(where: { token in
                    !blocked.contains(token.id) && !token.isStatusChrome && normalized(token.text).contains(candidate)
                })
            if supported { merchant = value; evidence["merchant"] = value }
            else { rejected["merchant"] = "counterparty text is absent or belongs to another field" }
        }
        if let quote = nonempty(claim.dateTimeEvidence), quote.contains(where: \.isNumber) {
            let match = spans.spans.filter { span in
                [.dateTime, .date].contains(span.kind) &&
                (containsEvidence(span.reading, quote) || span.tokenIDs.contains { id in containsEvidence(layout.tokens[id].text, quote) }) &&
                !relations.of(.otherDate).contains { pair in
                    !pair.valueTokenIDs.filter { span.tokenIDs.contains($0) }.isEmpty
                }
            }.sorted { $0.kind == .dateTime && $1.kind != .dateTime }.first
            if let match, match.kind == .dateTime, let instant = match.instant {
                occurredAt = instant.isoUTC; evidence["date"] = match.reading
            } else if let match, match.kind == .date, let day = match.dateISO {
                // A date-only claim remains date-only. No capture-time timestamp is invented.
                occurredAt = day; evidence["date"] = match.reading
            } else { rejected["date"] = "quoted transaction date/time has no matching OCR date evidence" }
        }
        if let value = nonempty(claim.reference) {
            let raw = value.hasPrefix("approval:") ? String(value.dropFirst("approval:".count)) : value
            let candidate = spans.of(.identifier).first { equivalent($0.reading, raw) }
            if let candidate,
               !spans.spans.contains(where: { $0.tokenIDs == candidate.tokenIDs && [.cardMask, .phone].contains($0.kind) }) {
                let matching = relations.pairs.filter { pair in
                    pair.valueKind == .identifier && pair.valueTokenIDs == candidate.tokenIDs &&
                        pair.valueSpan?.normalized == candidate.normalized
                }
                if matching.contains(where: { $0.label.concept == .referencePrimary }) {
                    reference = candidate.reading; evidence["reference"] = candidate.reading
                } else if matching.contains(where: { $0.label.concept == .referenceSecondary }) {
                    reference = "approval:" + candidate.reading; evidence["reference"] = candidate.reading
                } else { rejected["reference"] = "identifier lacks a transaction/reference or approval label" }
            } else { rejected["reference"] = "reference is absent from OCR identifiers or is a mask/phone" }
        }
        return .init(amountMinor: amount, merchant: merchant, occurredAt: occurredAt,
                     reference: reference, rejected: rejected, evidence: evidence)
    }

    /// Informational G3 comparison; no legacy detection gate and no classification.
    public static func g3Fields(lines: [ScreenshotTextLine], capturedAt: Instant,
                                timeZone: String) -> ScreenshotFMG3Fields {
        let result = ScreenshotFieldExtraction(capturedAt: capturedAt, timeZone: timeZone).extractFields(lines)
        return .init(amountMinor: result.amountMinor, merchant: result.merchant,
                     occurredAt: result.occurredAt?.isoUTC, reference: result.referenceText,
                     amountTrust: result.amountTrust.rawValue, merchantTrust: result.merchantTrust.rawValue,
                     dateTrust: result.dateTrust.rawValue)
    }

    private static func excludedAmount(_ span: ScreenSpan, relations: ScreenshotRelations) -> Bool {
        if relations.of(.amountExcluded).contains(where: { pair in
            pair.valueSpan?.normalized == span.normalized && !pair.valueTokenIDs.filter { span.tokenIDs.contains($0) }.isEmpty
        }) { return true }
        return span.tokenIDs.contains { id in
            !Set(ScreenshotLabels.words(relations.layout.tokens[id].text)).isDisjoint(with: ScreenshotLexicon.excludedAmounts)
        }
    }
    private static func nonempty(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func equivalent(_ a: String, _ b: String) -> Bool {
        normalized(a).replacingOccurrences(of: " ", with: "") ==
            normalized(b).replacingOccurrences(of: " ", with: "")
    }
    private static func containsEvidence(_ ocr: String, _ quoted: String) -> Bool {
        let quote = normalized(quoted).replacingOccurrences(of: " ", with: "")
        return quote.count >= 6 && normalized(ocr).replacingOccurrences(of: " ", with: "").contains(quote)
    }
}
#endif
