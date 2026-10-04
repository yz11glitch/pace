#if DEBUG
import Foundation

/// Diagnostic-only parsing of a model-selected OCR money string. The model never supplies cents.
public struct ScreenshotFMProbeMoneyResult: Codable, Sendable {
    public let status: String
    public let amountMinor: Int?
    public let currency: String?
    public let matchedMoneyText: String?
    public let ocrObservation: String?
}

public enum ScreenshotFMProbeMoney {
    public static func parse(_ selectedText: String?, lines: [ScreenshotTextLine],
                             capturedAt: Instant, timeZone: String) -> ScreenshotFMProbeMoneyResult {
        guard let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(status: "abstained", amountMinor: nil, currency: nil,
                         matchedMoneyText: nil, ocrObservation: nil)
        }
        let layout = ScreenshotLayout(lines)
        let spans = ScreenshotSpans(layout, capturedAt: capturedAt, timeZone: timeZone)
        let relations = ScreenshotRelations(spans)
        let selected = comparable(selectedText)
        let candidate = spans.of(.money).first { span in
            comparable(span.reading) == selected && !excluded(span, relations: relations)
        }
        guard let candidate, let money = candidate.money, let amount = Int(exactly: money.minorUnits) else {
            return .init(status: "unsupported", amountMinor: nil, currency: nil,
                         matchedMoneyText: nil, ocrObservation: nil)
        }
        let observation = candidate.tokenIDs.map { layout.tokens[$0].text }.joined(separator: " ")
        return .init(status: "supported", amountMinor: amount, currency: money.currency,
                     matchedMoneyText: candidate.reading, ocrObservation: observation)
    }

    private static func comparable(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private static func excluded(_ span: ScreenSpan, relations: ScreenshotRelations) -> Bool {
        if relations.of(.amountExcluded).contains(where: { pair in
            pair.valueSpan?.normalized == span.normalized &&
                !pair.valueTokenIDs.filter { span.tokenIDs.contains($0) }.isEmpty
        }) { return true }
        return span.tokenIDs.contains { id in
            !Set(ScreenshotLabels.words(relations.layout.tokens[id].text))
                .isDisjoint(with: ScreenshotLexicon.excludedAmounts)
        }
    }
}
#endif
