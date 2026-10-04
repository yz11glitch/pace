import Foundation

public struct AmountValue: Codable, Sendable, Equatable {
    public let currency: String?
    public let minorUnits: Int
    public let incoming: Bool
}

public struct CandidateTrace: Codable, Sendable, Equatable {
    public let id: String
    public let value: String
    public let features: [String]
    public let score: Int
    public let rejected: String?
    public let tokenIDs: [Int]
    public let observations: [ScreenshotTextLine]
}

public struct FieldResolution<Value: Codable & Sendable>: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case decisive, ambiguous, weak, missing }
    public let kind: Kind
    public let rule: String
    public let candidates: [CandidateTrace]
    public let selected: CandidateTrace?
    public let value: Value?
    public let chooserOffer: [CandidateTrace]
}

public struct DateResolution: Codable, Sendable {
    public let kind: FieldResolution<String>.Kind
    public let rule: String
    public let candidates: [CandidateTrace]
    public let selected: CandidateTrace?
    public let occurredAtSeconds: Int64?
    public let trust: CaptureFieldTrust
    public var occurredAt: Instant? { occurredAtSeconds.map { Instant(seconds: $0) } }
}

public enum StatusEvidence: String, Codable, Sendable {
    case negative, prePayment, positive, none
    public var clean: Bool { self != .negative && self != .prePayment }
}

public struct ScreenshotFieldResolution: Codable, Sendable {
    public let amount: FieldResolution<AmountValue>
    public let merchant: FieldResolution<String>
    public let date: DateResolution
    public let reference: FieldResolution<String>
    public let status: StatusEvidence
    public let noTransactionEvidence: Bool
}

/// G3 supplies candidates and exclusions. These rules alone grant trust.
public struct ScreenshotFieldResolver: Sendable {
    public init() {}

    public func resolve(_ lines: [ScreenshotTextLine], capturedAt: Instant,
                        timeZone: String) -> ScreenshotFieldResolution {
        let report = ScreenshotFieldExtraction(capturedAt: capturedAt, timeZone: timeZone).extractFields(lines)
        let layout = ScreenshotLayout(lines)
        let spans = ScreenshotSpans(layout, capturedAt: capturedAt, timeZone: timeZone)
        let relations = ScreenshotRelations(spans)
        let incomingCue = relations.labels.contains { $0.concept == .incoming } ||
            layout.tokens.contains { token in
                !Set(ScreenshotLabels.words(token.text)).isDisjoint(with: ScreenshotLexicon.incoming) &&
                (token.relHeight >= 1.2 || token.zone(firstRelationY: nil) == .header)
            }
        let amount = resolveAmount(report.amount.candidates, spans: spans, incomingCue: incomingCue)
        let merchant = resolveMerchant(report.counterparty.candidates)
        let date = resolveDate(report.date.candidates, spans: spans, layout: layout,
                               capturedAt: capturedAt, timeZone: timeZone)
        let reference = resolveReference(report.reference.candidates)
        let status: StatusEvidence = report.statusEvidence.contains { $0.concept == .statusNegative } ? .negative :
            report.statusEvidence.contains { $0.concept == .prePayment } ? .prePayment :
            report.statusEvidence.contains { $0.concept == .statusPositive } ? .positive : .none
        return .init(amount: amount, merchant: merchant, date: date, reference: reference,
                     status: status, noTransactionEvidence: amount.kind == .missing &&
                     merchant.kind == .missing && spans.of(.money).isEmpty &&
                     spans.of(.malformedMoney).isEmpty)
    }

    private func traces(_ candidates: [ScreenFieldCandidate], prefix: String) -> [(ScreenFieldCandidate, CandidateTrace)] {
        let sorted = candidates.sorted { a, b in
            if (a.tokenIDs.min() ?? Int.max) != (b.tokenIDs.min() ?? Int.max) {
                return (a.tokenIDs.min() ?? Int.max) < (b.tokenIDs.min() ?? Int.max)
            }
            if a.value != b.value { return a.value < b.value }
            return a.source < b.source
        }
        return sorted.enumerated().map { index, candidate in
            (candidate, CandidateTrace(id: "\(prefix)\(index + 1)", value: candidate.value,
                features: candidate.features, score: candidate.score, rejected: candidate.rejected,
                tokenIDs: candidate.tokenIDs, observations: candidate.observations))
        }
    }

    private func ranked(_ items: [(ScreenFieldCandidate, CandidateTrace)]) -> [(ScreenFieldCandidate, CandidateTrace)] {
        items.sorted { a, b in
            if a.0.score != b.0.score { return a.0.score > b.0.score }
            if a.0.confidence != b.0.confidence { return a.0.confidence > b.0.confidence }
            return a.1.id < b.1.id
        }
    }

    private func resolveAmount(_ candidates: [ScreenFieldCandidate], spans: ScreenshotSpans,
                               incomingCue: Bool) -> FieldResolution<AmountValue> {
        let all = traces(candidates, prefix: "A")
        let viable = ranked(all.filter { $0.0.rejected == nil && $0.0.amountMinor != nil })
        // Distinct currency/value groups, ignoring a debit sign and repeated OCR observations.
        var seen = Set<String>()
        let groups = viable.filter { candidate, _ in
            let currency = spans.of(.money).first(where: {
                $0.tokenIDs == candidate.tokenIDs && $0.reading == candidate.value
            })?.money?.currency
            return seen.insert("\(currency ?? "none"):\(candidate.amountMinor!)").inserted
        }
        let offer = groups.map(\.1)
        func value(_ candidate: ScreenFieldCandidate) -> AmountValue? {
            guard let minor = candidate.amountMinor else { return nil }
            let money = spans.of(.money).first { $0.tokenIDs == candidate.tokenIDs && $0.reading == candidate.value }?.money
            return .init(currency: money?.currency, minorUnits: minor,
                         incoming: incomingCue || money?.explicitPlus == true)
        }
        guard let first = groups.first else {
            return .init(kind: .missing, rule: "no viable transaction amount", candidates: all.map(\.1),
                         selected: nil, value: nil, chooserOffer: [])
        }
        if groups.count > 1 {
            return .init(kind: .ambiguous, rule: "multiple viable amount values", candidates: all.map(\.1),
                         selected: first.1, value: value(first.0), chooserOffer: offer)
        }
        let group = viable.filter { $0.0.amountMinor == first.0.amountMinor &&
            value($0.0)?.currency == value(first.0)?.currency }
        let groupIncoming = group.contains { value($0.0)?.incoming == true }
        let strong = group.first { candidate, _ in
            candidate.features.contains("currency anchored") &&
            !candidate.features.contains("repaired reading") &&
            !candidate.features.contains("alternate reading") &&
            candidate.observations.allSatisfy { $0.pass == "primary" && $0.confidence >= 0.80 } &&
            value(candidate)?.currency == "MYR" &&
            (candidate.features.contains("largest prominent money") ||
             candidate.features.contains(where: { $0.hasPrefix("amount label:") }) ||
             candidate.features.contains("payment sentence")) &&
            !groupIncoming && value(candidate)?.incoming == false
        }
        if let strong {
            return .init(kind: .decisive, rule: "single strong salient MYR value", candidates: all.map(\.1),
                         selected: strong.1, value: value(strong.0), chooserOffer: [])
        }
        let reason = groupIncoming ? "incoming payment direction" :
            value(first.0)?.currency != "MYR" ? "not explicit MYR" :
            first.0.features.contains("repaired reading") || first.0.features.contains("alternate reading") ? "weak OCR reading" :
            first.0.confidence < 0.80 ? "low OCR confidence" : "amount lacks strong salient evidence"
        return .init(kind: .weak, rule: reason, candidates: all.map(\.1),
                     selected: first.1, value: value(first.0), chooserOffer: [])
    }

    private func resolveMerchant(_ candidates: [ScreenFieldCandidate]) -> FieldResolution<String> {
        let all = traces(candidates, prefix: "M")
        let viable = ranked(all.filter { $0.0.rejected == nil })
        let strong = viable.filter { $0.0.features.contains("counterparty label") || $0.0.features.contains("preposition") }
        func distinct(_ items: [(ScreenFieldCandidate, CandidateTrace)]) -> [(ScreenFieldCandidate, CandidateTrace)] {
            var seen = Set<String>()
            return items.filter { candidate, _ in
                let key = candidate.value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX"))
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                return seen.insert(key).inserted
            }
        }
        let groups = distinct(strong)
        if groups.count > 1 {
            return .init(kind: .ambiguous, rule: "multiple strong counterparties", candidates: all.map(\.1),
                         selected: nil, value: nil, chooserOffer: groups.map(\.1))
        }
        if let first = groups.first {
            let decisive = first.0.confidence >= 0.80 && first.0.observations.allSatisfy { $0.pass == "primary" }
            return .init(kind: decisive ? .decisive : .weak,
                         rule: decisive ? "single strong counterparty relationship" : "low OCR confidence",
                         candidates: all.map(\.1), selected: first.1, value: first.0.value, chooserOffer: [])
        }
        let titles = distinct(viable)
        if let first = titles.first {
            return .init(kind: .ambiguous, rule: "title-only counterparty", candidates: all.map(\.1),
                         selected: first.1, value: first.0.value, chooserOffer: titles.map(\.1))
        }
        return .init(kind: .missing, rule: "no counterparty candidate", candidates: all.map(\.1),
                     selected: nil, value: nil, chooserOffer: [])
    }

    private func resolveDate(_ candidates: [ScreenFieldCandidate], spans: ScreenshotSpans,
                             layout: ScreenshotLayout, capturedAt: Instant, timeZone: String) -> DateResolution {
        let all = traces(candidates, prefix: "D")
        let viable = ranked(all.filter { $0.0.rejected == nil && $0.0.instant != nil })
        var seen = Set<Int64>()
        let distinct = viable.filter { seen.insert($0.0.instant!.seconds).inserted }
        if distinct.count > 1 {
            return .init(kind: .ambiguous, rule: "conflicting displayed dates", candidates: all.map(\.1),
                         selected: nil, occurredAtSeconds: nil, trust: .unresolved)
        }
        if let first = distinct.first, let instant = first.0.instant {
            let zone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let sameDay = calendar.isDate(Date(timeIntervalSince1970: Double(instant.seconds)),
                                          inSameDayAs: Date(timeIntervalSince1970: Double(capturedAt.seconds)))
            let resolved = first.0.dateOnly && sameDay ? capturedAt : instant
            let age = capturedAt.seconds - resolved.seconds
            let trust: CaptureFieldTrust = age <= 86_400 ? .trusted : age <= 7 * 86_400 ? .usable : .unresolved
            return .init(kind: trust == .unresolved ? .weak : .decisive,
                         rule: first.0.dateOnly ? (sameDay ? "same-day displayed date" : "displayed date-only at local noon") :
                             (trust == .unresolved ? "displayed date older than seven days" : "displayed transaction date-time"),
                         candidates: all.map(\.1), selected: first.1,
                         occurredAtSeconds: resolved.seconds, trust: trust)
        }
        let dateLike = !spans.of(.date).isEmpty || !spans.of(.dateTime).isEmpty ||
            layout.tokens.contains { $0.text.range(of: #"(?i)\b\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}\b|\b\d{4}[/.-]\d{1,2}[/.-]\d{1,2}\b|\b\d{1,2}\s+[a-z]{3,9}\s+\d{4}\b"#,
                options: .regularExpression) != nil }
        return .init(kind: dateLike ? .weak : .missing,
                     rule: dateLike ? "displayed date unresolvable" : "no displayed date; capture time",
                     candidates: all.map(\.1), selected: nil,
                     occurredAtSeconds: dateLike ? nil : capturedAt.seconds,
                     trust: dateLike ? .unresolved : .trusted)
    }

    private func resolveReference(_ candidates: [ScreenFieldCandidate]) -> FieldResolution<String> {
        let all = traces(candidates, prefix: "R")
        let viable = ranked(all.filter { $0.0.rejected == nil })
        let primary = viable.filter { $0.0.features.contains("primary reference") }
        let pool = primary.isEmpty ? viable : primary
        var seen = Set<String>()
        let groups = pool.filter { seen.insert($0.0.value.uppercased()).inserted }
        if groups.count > 1 {
            return .init(kind: .ambiguous, rule: "conflicting labelled references", candidates: all.map(\.1),
                         selected: nil, value: nil, chooserOffer: [])
        }
        if let first = groups.first {
            let value = first.0.features.contains("secondary reference") ? "approval:" + first.0.value : first.0.value
            return .init(kind: .decisive, rule: first.0.features.contains("secondary reference") ?
                "labelled approval code" : "labelled primary reference", candidates: all.map(\.1),
                selected: first.1, value: value, chooserOffer: [])
        }
        return .init(kind: .missing, rule: "no labelled transaction reference", candidates: all.map(\.1),
                     selected: nil, value: nil, chooserOffer: [])
    }
}
