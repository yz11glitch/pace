import Foundation

/// All weights describe evidence concepts. None depends on a provider, fixture, or screen class.
enum ScreenshotScoring {
    static let selectionMargin = 2
    static let currency = 3
    static let amountLabel = 3
    static let prominentMoney = 2
    static let debit = 1
    static let amountPosition = 1
    static let highConfidence = 1
    static let bareDecimal = -2
    static let repairedReading = -1
    static let alternateReading = -1
    static let counterpartyLabel = 4
    static let preposition = 3
    static let title = 1
    static let corroboratingSource = 2
    static let nearProminentMoney = 1
    static let lowConfidence = -1
    static let dateTime = 2
    static let transactionDateLabel = 3
    static let dateHeader = 1
    static let primaryReference = 4
    static let secondaryReference = 2
    static let corroborationPerOccurrence = 1
    static let maximumCorroboration = 2
}

enum ScreenField: String, Sendable { case amount, counterparty, date, reference }

/// A proposal retains its original OCR evidence, even if it loses reconciliation.
struct ScreenFieldCandidate: Sendable {
    let field: ScreenField
    let value: String
    let tokenIDs: [Int]
    let score: Int
    let features: [String]
    let rejected: String?
    let observations: [ScreenshotTextLine]
    let source: String
    let confidence: Double
    let amountMinor: Int?
    let instant: Instant?
    let dateOnly: Bool
}

struct ScreenFieldChoice: Sendable {
    let selected: ScreenFieldCandidate?
    let candidates: [ScreenFieldCandidate]
    let groups: [(value: String, score: Int)]
    let unresolved: Bool
    let margin: Int?
}

/// Stages 1–6 and field trust. No screen classification is performed here.
struct ScreenshotFieldReport: Sendable {
    let amount: ScreenFieldChoice
    let counterparty: ScreenFieldChoice
    let date: ScreenFieldChoice
    let reference: ScreenFieldChoice
    let amountMinor: Int?
    let amountText: String?
    let amountCandidates: [String]
    let amountTrust: CaptureFieldTrust
    let merchant: String?
    let merchantTrust: CaptureFieldTrust
    let occurredAt: Instant?
    let dateTrust: CaptureFieldTrust
    let referenceText: String?
    let extractionAmbiguous: Bool
    let statusEvidence: [(tokenID: Int, concept: ScreenLabelConcept, strong: Bool)]
}

struct ScreenshotFieldExtraction {
    let capturedAt: Instant
    let timeZone: String

    init(capturedAt: Instant, timeZone: String) {
        self.capturedAt = capturedAt
        self.timeZone = timeZone
    }

    func extractFields(_ observations: [ScreenshotTextLine]) -> ScreenshotFieldReport {
        let layout = ScreenshotLayout(observations)
        let spans = ScreenshotSpans(layout, capturedAt: capturedAt, timeZone: timeZone)
        let relations = ScreenshotRelations(spans)
        let amountCandidates = amounts(relations)
        let counterpartyCandidates = counterparties(relations)
        let dateCandidates = dates(relations)
        let referenceCandidates = references(relations)

        // A selected typed field owns its OCR token(s). Each generator above ran independently.
        let reference = Self.choose(referenceCandidates, multiplePrimariesConflict: true)
        let date = Self.choose(Self.excluding(dateCandidates, claimedBy: reference))
        let amount = Self.choose(Self.excluding(amountCandidates, claimedBy: [reference, date]))
        let counterparty = Self.choose(Self.excluding(counterpartyCandidates, claimedBy: [reference, date, amount]))

        let selectedAmount = amount.selected
        let money = spans.of(.money)
        let foreignBody = money.contains { span in
            guard let currency = span.money?.currency, currency != "MYR" else { return false }
            return span.tokenIDs.contains { id in layout.tokens[id].zone(firstRelationY: firstRelationY(relations)) == .body } ||
                (selectedAmount != nil && !span.tokenIDs.allSatisfy { selectedAmount!.tokenIDs.contains($0) })
        }
        let malformed = spans.of(.malformedMoney).contains { span in
            span.tokenIDs.contains { id in
                layout.tokens[id].zone(firstRelationY: firstRelationY(relations)) == .header ||
                relations.of(.amountTotal).contains { !$0.valueTokenIDs.filter { span.tokenIDs.contains($0) }.isEmpty }
            }
        }
        let amountAmbiguous = amount.unresolved || malformed || foreignBody ||
            (selectedAmount != nil && selectedAmount!.confidence < 0.80)
        let amountTrusted = selectedAmount != nil && !amountAmbiguous &&
            selectedAmount!.features.contains("currency anchored") &&
            !selectedAmount!.features.contains("alternate reading") &&
            !selectedAmount!.features.contains("repaired reading") &&
            !selectedAmount!.features.contains("foreign currency") &&
            selectedAmount!.confidence >= 0.80 &&
            selectedAmount!.observations.allSatisfy { $0.pass == "primary" }
        let merchant = counterparty.selected
        let merchantStrong = merchant?.features.contains("counterparty label") == true ||
            merchant?.features.contains("preposition") == true
        let merchantTrust: CaptureFieldTrust = merchant != nil && merchantStrong &&
            merchant!.confidence >= 0.80 && !counterparty.unresolved ? .usable : .unresolved

        let dateLike = spans.spans.contains { [.date, .dateTime].contains($0.kind) } ||
            layout.tokens.contains { token in
                token.text.range(of: #"(?i)\b\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}\b|\b\d{4}[/.-]\d{1,2}[/.-]\d{1,2}\b|\b\d{1,2}\s+[a-z]{3,9}\s+\d{4}\b"#, options: .regularExpression) != nil
            }
        var selectedDate = date.selected?.instant
        var dateTrust: CaptureFieldTrust = dateLike ? .unresolved : .trusted
        if let candidate = date.selected, !date.unresolved {
            if candidate.dateOnly {
                let zone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                if let sameDay = candidate.instant.map({ calendar.isDate(Date(timeIntervalSince1970: Double($0.seconds)), inSameDayAs: Date(timeIntervalSince1970: Double(capturedAt.seconds))) }), sameDay {
                    selectedDate = capturedAt; dateTrust = .trusted
                } else { selectedDate = nil }
            } else if let instant = candidate.instant {
                let age = capturedAt.seconds - instant.seconds
                dateTrust = age <= 86_400 ? .trusted : age <= 7 * 86_400 ? .usable : .unresolved
            }
        }
        let referenceText: String? = reference.selected.map { candidate in
            candidate.features.contains("secondary reference") ? "approval:" + candidate.value : candidate.value
        }
        let status = relations.labels.compactMap { label -> (tokenID: Int, concept: ScreenLabelConcept, strong: Bool)? in
            guard [.statusPositive, .statusNegative, .prePayment].contains(label.concept) else { return nil }
            let token = layout.tokens[label.tokenID]
            return (label.tokenID, label.concept, token.relHeight >= 1.2 || relations.pairs.contains { $0.label.tokenID == label.tokenID })
        }
        return .init(amount: amount, counterparty: counterparty, date: date, reference: reference,
                     amountMinor: selectedAmount?.amountMinor, amountText: selectedAmount?.value,
                     amountCandidates: (money.map(\.reading) + spans.of(.malformedMoney).map(\.reading)),
                     amountTrust: amountTrusted ? .trusted : .unresolved,
                     merchant: merchant?.value, merchantTrust: merchantTrust,
                     occurredAt: selectedDate, dateTrust: dateTrust,
                     referenceText: referenceText, extractionAmbiguous: amountAmbiguous,
                     statusEvidence: status)
    }

    private func firstRelationY(_ relations: ScreenshotRelations) -> Double? {
        relations.pairs.filter { [.counterparty, .amountTotal, .transactionDate,
                                  .referencePrimary, .referenceSecondary].contains($0.label.concept) }
            .map { relations.layout.tokens[$0.label.tokenID].centerY }.min()
    }

    private func candidate(_ field: ScreenField, _ value: String, _ ids: [Int], _ score: Int,
                           _ features: [String], _ rejected: String?, _ source: String,
                           _ layout: ScreenshotLayout, amount: Int? = nil,
                           instant: Instant? = nil, dateOnly: Bool = false) -> ScreenFieldCandidate {
        let distinct = Array(Set(ids)).sorted()
        let observations = distinct.map { layout.tokens[$0].original }
        return .init(field: field, value: value, tokenIDs: distinct, score: score,
                     features: features, rejected: rejected, observations: observations,
                     source: source, confidence: observations.map(\.confidence).min() ?? 0,
                     amountMinor: amount, instant: instant, dateOnly: dateOnly)
    }

    private func amounts(_ r: ScreenshotRelations) -> [ScreenFieldCandidate] {
        let money = r.spans.of(.money)
        let largest = money.map { span in span.tokenIDs.map { r.layout.tokens[$0].relHeight }.max() ?? 0 }.max() ?? 0
        let relationY = firstRelationY(r)
        let listRows = r.layout.lines.filter { line in
            let words = line.tokenIDs.map { r.layout.tokens[$0].text }.joined(separator: " ")
            return words.range(of: #"(?i)\b(?:\d{1,2}\s+[a-z]{3}|\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4})\b"#, options: .regularExpression) != nil &&
                money.contains { !$0.tokenIDs.filter { line.tokenIDs.contains($0) }.isEmpty }
        }.count >= 2
        return money.map { span in
            let ids = span.tokenIDs, tokens = ids.map { r.layout.tokens[$0] }
            let paired = r.pairs.filter { $0.valueSpan?.kind == .money && $0.valueSpan?.normalized == span.normalized && !$0.valueTokenIDs.filter { ids.contains($0) }.isEmpty }
            var score = 0, features: [String] = [], rejected: String?
            if span.money?.noCurrency == false { score += ScreenshotScoring.currency; features.append("currency anchored") }
            let inlineAmountLabel = tokens.flatMap { ScreenshotLabels.labels(in: $0) }
                .first { $0.concept == .amountTotal && $0.inlineValue?.contains(span.reading) == true }
            if let label = paired.first(where: { $0.label.concept == .amountTotal })?.label ?? inlineAmountLabel {
                score += ScreenshotScoring.amountLabel; features.append("amount label: \(label.labelText)")
            } else if let prefix = tokens.compactMap({ token -> String? in
                guard let range = token.text.range(of: span.reading, options: .caseInsensitive) else { return nil }
                let before = String(token.text[..<range.lowerBound])
                let words = Set(ScreenshotLabels.words(before))
                guard !words.isDisjoint(with: ScreenshotLexicon.amountWords),
                      words.isDisjoint(with: ScreenshotLexicon.excludedAmounts) else { return nil }
                return before.trimmingCharacters(in: .whitespacesAndNewlines)
            }).first {
                score += ScreenshotScoring.amountLabel; features.append("amount label: \(prefix)")
            }
            if tokens.contains(where: { token in
                let words = Set(ScreenshotLabels.words(token.text))
                return !words.isDisjoint(with: ["paid", "spent", "sent", "charged", "debited"]) ||
                    !words.isDisjoint(with: ["to", "at", "kepada"])
            }) { features.append("payment sentence") }
            let prominence = tokens.map(\.relHeight).max() ?? 0
            if prominence >= 1.4 && prominence >= largest { score += ScreenshotScoring.prominentMoney; features.append("largest prominent money") }
            if span.money?.negative == true { score += ScreenshotScoring.debit; features.append("debit sign") }
            if tokens.contains(where: { $0.alignment == .center || $0.zone(firstRelationY: relationY) == .header }) {
                score += ScreenshotScoring.amountPosition; features.append("center or header")
            }
            let confidence = tokens.map(\.confidence).min() ?? 0
            if confidence >= 0.90 { score += ScreenshotScoring.highConfidence; features.append("high confidence") }
            if span.money?.noCurrency == true {
                score += ScreenshotScoring.bareDecimal; features.append("no currency")
                if prominence < 1.6 && !paired.contains(where: { $0.label.concept == .amountTotal }) { rejected = "unanchored bare decimal" }
            }
            if span.money?.repaired == true { score += ScreenshotScoring.repairedReading; features.append("repaired reading") }
            if span.source == .alternate { score += ScreenshotScoring.alternateReading; features.append("alternate reading") }
            if let currency = span.money?.currency, currency != "MYR" { features.append("foreign currency") }
            if let excluded = paired.first(where: { $0.label.concept == .amountExcluded }) { rejected = "excluded amount label: \(excluded.label.labelText)" }
            if rejected == nil && tokens.contains(where: { !Set(ScreenshotLabels.words($0.text)).isDisjoint(with: ScreenshotLexicon.excludedAmounts) }) {
                rejected = "excluded amount context"
            }
            if rejected == nil && tokens.contains(where: { token in
                token.text.range(of: #"(?i)\b(?:get|earn|up\s+to|off)\b|%"#, options: .regularExpression) != nil
            }) { rejected = "promotional context" }
            if rejected == nil && tokens.contains(where: { token in token.isStatusChrome || r.labels.contains { $0.tokenID == token.id && $0.concept == .chrome } }) { rejected = "chrome" }
            if rejected == nil && listRows && !paired.contains(where: { $0.label.concept == .amountTotal }) { rejected = "list row" }
            return candidate(.amount, span.reading, ids, score, features, rejected, "money span", r.layout,
                             amount: span.money.flatMap { Int(exactly: $0.minorUnits) })
        }
    }

    private func counterparties(_ r: ScreenshotRelations) -> [ScreenFieldCandidate] {
        let layout = r.layout
        let firstY = firstRelationY(r)
        let prominent = r.spans.of(.money).filter { $0.tokenIDs.contains { layout.tokens[$0].relHeight >= 1.4 } }
            .max { ($0.tokenIDs.map { layout.tokens[$0].relHeight }.max() ?? 0) < ($1.tokenIDs.map { layout.tokens[$0].relHeight }.max() ?? 0) }
        let prominentLine = prominent?.tokenIDs.first.flatMap { layout.visualLine(of: $0)?.index }
        let blocked = Set(r.pairs.filter { [.source, .memo, .typeCategory, .unknownLabel, .nonTransactionIdentifier].contains($0.label.concept) }.flatMap(\.valueTokenIDs))
        func valid(_ text: String, _ ids: [Int]) -> Bool {
            guard text.contains(where: \.isLetter), text.count <= 100,
                  !ScreenshotLexicon.words.contains(text.lowercased()),
                  ScreenshotLabels.concept(for: text) == nil,
                  ids.allSatisfy({ !blocked.contains($0) && !layout.tokens[$0].isStatusChrome }) else { return false }
            return !r.spans.spans.contains { span in
                span.tokenIDs == ids && [.money, .date, .dateTime, .identifier, .cardMask, .phone, .clock, .percent].contains(span.kind) &&
                (span.reading.caseInsensitiveCompare(text) == .orderedSame ||
                 ids.count == 1 && layout.tokens[ids[0]].text == text && span.kind == .money)
            }
        }
        var output: [ScreenFieldCandidate] = []
        for pair in r.of(.counterparty) where valid(pair.valueText, pair.valueTokenIDs) {
            let preposition = pair.label.isPreposition
            var features = [preposition ? "preposition" : "counterparty label", "geometry \(pair.relation)"]
            var score = preposition ? ScreenshotScoring.preposition : ScreenshotScoring.counterpartyLabel
            if let p = prominentLine, pair.valueTokenIDs.contains(where: { id in
                layout.visualLine(of: id).map { abs($0.index-p) <= 3 } ?? false
            }) { score += ScreenshotScoring.nearProminentMoney; features.append("near prominent money") }
            if pair.valueObservations.map(\.confidence).min() ?? 0 < 0.80 { score += ScreenshotScoring.lowConfidence; features.append("low confidence") }
            output.append(candidate(.counterparty, pair.valueText, pair.valueTokenIDs, score, features,
                                    nil, "semantic pair", layout))
        }
        // A preposition after a typed money span is still a structural counterparty cue.
        // This covers sentence-style alerts without making arbitrary prose a title.
        for token in layout.tokens where r.spans.of(.money).contains(where: { $0.tokenIDs == [token.id] }) {
            guard let range = token.text.range(of: #"(?i)\bat\s+\p{L}[^\n]*$"#, options: .regularExpression) else { continue }
            let tail = String(token.text[range]).replacingOccurrences(of: #"(?i)^at\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard valid(tail, [token.id]) else { continue }
            let score = ScreenshotScoring.preposition + (token.confidence < 0.80 ? ScreenshotScoring.lowConfidence : 0)
            output.append(candidate(.counterparty, tail, [token.id], score, ["preposition", "after money span"],
                                    nil, "sentence preposition", layout))
        }
        let contextSignals = (r.spans.of(.money).isEmpty ? 0 : 1) +
            (r.spans.of(.dateTime).isEmpty ? 0 : 1) +
            (r.of(.referencePrimary).isEmpty && r.of(.referenceSecondary).isEmpty ? 0 : 1) +
            (r.labels.contains { [.statusPositive, .statusNegative].contains($0.concept) } ? 1 : 0)
        let moneyLine = r.spans.of(.money).compactMap { $0.tokenIDs.first.flatMap { layout.visualLine(of: $0)?.index } }.min()
        var titles: [ScreenFieldCandidate] = []
        for token in layout.tokens {
            guard token.zone(firstRelationY: firstY) == .header,
                  !r.labels.contains(where: { $0.tokenID == token.id && $0.concept != .unknownLabel }),
                  !blocked.contains(token.id),
                  (ScreenshotLabels.words(token.text).count >= 2 || token.relHeight >= 1.2),
                  token.text.range(of: #"(?i)\b(?:offer|deal|sale)\b.*\b(?:ends|soon|off)\b"#,
                                   options: .regularExpression) == nil,
                  token.text.filter(\.isLetter).count >= 3, token.text.count <= 60,
                  valid(token.text, [token.id]) else { continue }
            let line = layout.visualLine(of: token.id)?.index
            let adjacent = line.flatMap { l in prominentLine.map { abs(l-$0) <= 1 } } ?? false
            let receiptHeader = contextSignals >= 2 && moneyLine.map { moneyIndex in line.map { $0 <= moneyIndex } ?? false } == true &&
                token.box.centerY < 0.5
            guard token.relHeight >= 1.2 || adjacent || receiptHeader else { continue }
            var score = ScreenshotScoring.title, features = ["prominent title"]
            if receiptHeader && token.relHeight < 1.2 && !adjacent { features = ["structured header title"] }
            if let p = prominentLine, let l = line, abs(l-p) <= 3 {
                score += ScreenshotScoring.nearProminentMoney; features.append("near prominent money")
            }
            if token.confidence < 0.80 { score += ScreenshotScoring.lowConfidence; features.append("low confidence") }
            titles.append(candidate(.counterparty, token.text, [token.id], score, features,
                                    nil, "header title", layout))
        }
        if let first = titles.min(by: { a, b in
            let ay = layout.tokens[a.tokenIDs[0]].box.centerY, by = layout.tokens[b.tokenIDs[0]].box.centerY
            return ay == by ? a.value < b.value : ay < by
        }) { output.append(first) }
        return output
    }

    private func dates(_ r: ScreenshotRelations) -> [ScreenFieldCandidate] {
        let layout = r.layout, relationY = firstRelationY(r)
        let dateTimes = r.spans.of(.dateTime)
        let dateTokens = Set(dateTimes.flatMap(\.tokenIDs))
        let source = dateTimes + r.spans.of(.date).filter { span in !span.tokenIDs.allSatisfy(dateTokens.contains) }
        return source.map { span in
            let pairs = r.pairs.filter { pair in
                [.transactionDate, .otherDate].contains(pair.label.concept) &&
                !pair.valueTokenIDs.filter { span.tokenIDs.contains($0) }.isEmpty
            }
            var score = 0, features: [String] = [], rejected: String?
            if span.kind == .dateTime { score += ScreenshotScoring.dateTime; features.append("date and time") }
            if let label = pairs.first(where: { $0.label.concept == .transactionDate }) {
                score += ScreenshotScoring.transactionDateLabel; features.append("transaction date label: \(label.label.labelText)")
            }
            if span.tokenIDs.contains(where: { layout.tokens[$0].zone(firstRelationY: relationY) == .header }) {
                score += ScreenshotScoring.dateHeader; features.append("header date")
            }
            if let other = pairs.first(where: { $0.label.concept == .otherDate }) { rejected = "other date label: \(other.label.labelText)" }
            let instant: Instant?
            if span.kind == .date { instant = Self.noon(for: span.dateISO, timeZone: timeZone) }
            else { instant = span.instant }
            if rejected == nil, let instant {
                if span.kind == .date {
                    let zone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
                    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date(timeIntervalSince1970: Double(instant.seconds))),
                                                       to: calendar.startOfDay(for: Date(timeIntervalSince1970: Double(capturedAt.seconds)))).day ?? 0
                    if days < 0 || days > 400 { rejected = "date outside transaction window" }
                } else if capturedAt.seconds - instant.seconds < -600 || capturedAt.seconds - instant.seconds > 400 * 86_400 {
                    rejected = "date outside transaction window"
                }
            }
            return candidate(.date, span.normalized, span.tokenIDs, score, features,
                             rejected, "date span", layout, instant: instant, dateOnly: span.kind == .date)
        }
    }

    private func references(_ r: ScreenshotRelations) -> [ScreenFieldCandidate] {
        r.spans.of(.identifier).map { span in
            let pairs = r.pairs.filter { pair in
                pair.valueKind == .identifier && pair.valueTokenIDs == span.tokenIDs &&
                pair.valueSpan?.normalized == span.normalized
            }
            var score = 0, features: [String] = [], rejected: String? = "unlabelled identifier"
            if let pair = pairs.first(where: { $0.label.concept == .referencePrimary }) {
                score = ScreenshotScoring.primaryReference; features = ["primary reference", "label: \(pair.label.labelText)"]; rejected = nil
            } else if let pair = pairs.first(where: { $0.label.concept == .referenceSecondary }) {
                score = ScreenshotScoring.secondaryReference; features = ["secondary reference", "label: \(pair.label.labelText)"]; rejected = nil
            } else if let pair = pairs.first(where: { [.nonTransactionIdentifier, .memo, .unknownIdentifier, .unknownLabel].contains($0.label.concept) }) {
                rejected = "excluded identifier label: \(pair.label.labelText)"
            }
            if r.spans.spans.contains(where: { $0.tokenIDs == span.tokenIDs && [.cardMask, .phone].contains($0.kind) }) { rejected = "masked account or phone" }
            return candidate(.reference, span.reading, span.tokenIDs, score, features,
                             rejected, "identifier span", r.layout)
        }
    }

    private static func noon(for iso: String?, timeZone: String) -> Instant? {
        guard let iso else { return nil }
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(timeZone: calendar.timeZone, year: parts[0], month: parts[1], day: parts[2], hour: 12)
        return calendar.date(from: components).map { Instant(seconds: Int64($0.timeIntervalSince1970)) }
    }

    private static func excluding(_ candidates: [ScreenFieldCandidate], claimedBy choices: [ScreenFieldChoice]) -> [ScreenFieldCandidate] {
        let selections = choices.compactMap(\.selected)
        let claimed = Set(selections.flatMap(\.tokenIDs))
        return candidates.map { candidate in
            let separateSpanInSameBox = candidate.features.contains("after money span") &&
                selections.contains { $0.field == .amount && $0.tokenIDs == candidate.tokenIDs &&
                    !$0.value.localizedCaseInsensitiveContains(candidate.value) }
            guard candidate.rejected == nil,
                  candidate.tokenIDs.contains(where: { claimed.contains($0) }) && !separateSpanInSameBox else { return candidate }
            return .init(field: candidate.field, value: candidate.value, tokenIDs: candidate.tokenIDs,
                         score: candidate.score, features: candidate.features,
                         rejected: "token claimed by higher priority field", observations: candidate.observations,
                         source: candidate.source, confidence: candidate.confidence,
                         amountMinor: candidate.amountMinor, instant: candidate.instant, dateOnly: candidate.dateOnly)
        }
    }
    private static func excluding(_ candidates: [ScreenFieldCandidate], claimedBy choice: ScreenFieldChoice) -> [ScreenFieldCandidate] {
        excluding(candidates, claimedBy: [choice])
    }

    private static func choose(_ candidates: [ScreenFieldCandidate], multiplePrimariesConflict: Bool = false) -> ScreenFieldChoice {
        let viable = candidates.filter { $0.rejected == nil }
        let primary = viable.filter { $0.features.contains("primary reference") }
        let pool = primary.isEmpty ? viable : primary
        let local = pool.filter { !$0.features.contains("foreign currency") }
        let ranked = pool.first?.field == .amount && !local.isEmpty ? local : pool
        var groups: [String: [ScreenFieldCandidate]] = [:]
        for item in ranked {
            let key: String
            switch item.field {
            case .amount: key = item.amountMinor.map(String.init) ?? item.value
            case .counterparty: key = item.value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            case .date: key = item.instant.map { String($0.seconds) } ?? item.value
            case .reference: key = item.value.uppercased()
            }
            groups[key, default: []].append(item)
        }
        let scored: [(String, Int, ScreenFieldCandidate)] = groups.map { key, items in
            let ordered = items.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return $0.value < $1.value
            }
            var tokenSets = Set<String>()
            for item in items { tokenSets.insert(item.tokenIDs.map(String.init).joined(separator: ",")) }
            let extra = min(ScreenshotScoring.maximumCorroboration, max(0, tokenSets.count - 1))
            let sourceBonus = items.contains { $0.features.contains("counterparty label") } &&
                items.contains { $0.features.contains("prominent title") } ? ScreenshotScoring.corroboratingSource : 0
            return (key, ordered[0].score + extra * ScreenshotScoring.corroborationPerOccurrence + sourceBonus, ordered[0])
        }.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0 < b.0
        }
        let margin = scored.count > 1 ? scored[0].1 - scored[1].1 : nil
        let conflict = multiplePrimariesConflict && scored.count > 1 && !primary.isEmpty
        let unresolved = conflict || (margin != nil && margin! < ScreenshotScoring.selectionMargin)
        return .init(selected: unresolved ? nil : scored.first?.2,
                     candidates: candidates, groups: scored.map { (value: $0.0, score: $0.1) },
                     unresolved: unresolved, margin: margin)
    }
}
