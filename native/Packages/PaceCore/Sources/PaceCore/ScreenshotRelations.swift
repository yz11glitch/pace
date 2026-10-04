import Foundation

enum ScreenPairRelation: Sendable { case inline, right, below, above }

/// A structural label/value proposal. Selection across fields belongs to G3.
struct ScreenSemanticPair: Sendable {
    let label: ScreenLabel
    let valueText: String
    let valueKind: ScreenSpanKind
    let valueSpan: ScreenSpan?
    let valueTokenIDs: [Int]
    let relation: ScreenPairRelation
    let geometryScore: Int
    let distance: Double
    let features: [String]
    let labelObservations: [ScreenshotTextLine]
    let valueObservations: [ScreenshotTextLine]
}

struct ScreenshotRelations: Sendable {
    let layout: ScreenshotLayout
    let spans: ScreenshotSpans
    let labels: [ScreenLabel]
    let pairs: [ScreenSemanticPair]

    init(_ spans:ScreenshotSpans) {
        self.layout=spans.layout
        self.spans=spans
        var labels=spans.layout.tokens.flatMap(ScreenshotLabels.labels).filter { label in
            guard let inline=label.inlineValue else { return true }
            return !Self.values(in:inline,token:spans.layout.tokens[label.tokenID],concept:label.concept,spans:spans).isEmpty
        }
        for index in labels.indices where labels[index].normalizedWords == ["paid"] {
            let token=spans.layout.tokens[labels[index].tokenID]
            let nearby=spans.layout.tokens.contains { candidate in
                candidate.id != token.id && abs(candidate.box.centerY-token.box.centerY) <= spans.layout.medianTextHeight*3 &&
                    spans.spans.contains { $0.kind == .money && $0.tokenIDs.contains(candidate.id) }
            }
            if nearby {
                labels[index] = .init(concept:.amountTotal,tokenID:token.id,labelText:labels[index].labelText,
                                    normalizedWords:labels[index].normalizedWords,inlineValue:nil,isPreposition:false)
            }
        }
        var proposals:[ScreenSemanticPair]=[]
        for label in labels { proposals += Self.proposals(for:label,layout:spans.layout,spans:spans,known:labels) }
        // A short unknown caption is retained only when geometry actually supports a value.
        for token in spans.layout.tokens where !labels.contains(where:{ $0.tokenID == token.id }) && !token.isStatusChrome {
            let words=ScreenshotLabels.words(token.normalizedText)
            guard (1...4).contains(words.count),!token.normalizedText.contains(where:\.isNumber),
                  token.relHeight <= 1.2,!words.allSatisfy(ScreenshotLexicon.words.contains),
                  !spans.spans.contains(where:{ $0.tokenIDs == [token.id] && $0.kind != .text }) else { continue }
            let label=ScreenLabel(concept:.unknownLabel,tokenID:token.id,labelText:token.normalizedText,
                                  normalizedWords:words,inlineValue:nil,isPreposition:false)
            let candidates=Self.proposals(for:label,layout:spans.layout,spans:spans,known:labels)
            if !candidates.isEmpty { labels.append(label);proposals += candidates }
        }
        // Geometry establishes ownership of a value token. Keep alternative values for a label.
        let ordered=proposals.sorted {
            if ($0.label.concept == .unknownLabel) != ($1.label.concept == .unknownLabel) {
                return $0.label.concept != .unknownLabel
            }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.geometryScore != $1.geometryScore { return $0.geometryScore > $1.geometryScore }
            if $0.label.tokenID != $1.label.tokenID { return $0.label.tokenID < $1.label.tokenID }
            return $0.valueText < $1.valueText
        }
        var owner:[Int:Int]=[:]
        var kept:[ScreenSemanticPair]=[]
        for pair in ordered {
            if pair.valueTokenIDs.contains(where:{ owner[$0] != nil && owner[$0] != pair.label.tokenID }) { continue }
            for id in pair.valueTokenIDs { owner[id]=pair.label.tokenID }
            kept.append(pair)
        }
        let extended = kept.map { pair -> ScreenSemanticPair in
            guard pair.label.concept == .counterparty, pair.valueKind == .text,
                  pair.relation != .inline, let first = pair.valueTokenIDs.first,
                  let tail = Self.continuation(after: spans.layout.tokens[first], layout: spans.layout,
                    spans: spans, known: labels, owner: owner, currentLabel: pair.label.tokenID) else { return pair }
            return .init(label: pair.label, valueText: pair.valueText + " " + tail.text,
                valueKind: pair.valueKind, valueSpan: pair.valueSpan,
                valueTokenIDs: pair.valueTokenIDs + [tail.id], relation: pair.relation,
                geometryScore: pair.geometryScore, distance: pair.distance,
                features: pair.features, labelObservations: pair.labelObservations,
                valueObservations: pair.valueObservations + [tail.original])
        }
        self.labels=labels.sorted { $0.tokenID < $1.tokenID }
        self.pairs=extended.sorted {
            if $0.label.tokenID != $1.label.tokenID { return $0.label.tokenID < $1.label.tokenID }
            if $0.geometryScore != $1.geometryScore { return $0.geometryScore > $1.geometryScore }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.valueText < $1.valueText
        }
    }

    func of(_ concept:ScreenLabelConcept) -> [ScreenSemanticPair] { pairs.filter { $0.label.concept == concept } }

    private static let epsilon = 1e-9
    private static func proposals(for label:ScreenLabel,layout:ScreenshotLayout,spans:ScreenshotSpans,
                                  known:[ScreenLabel]) -> [ScreenSemanticPair] {
        let anchor=layout.tokens[label.tokenID]
        if let inline=label.inlineValue {
            let values=values(in:inline,token:anchor,concept:label.concept,spans:spans)
            if !values.isEmpty { return values.map { pair(label,$0,.inline,3,0,layout) } }
        }
        let maximum=layout.medianTextHeight*2.0
        let right=layout.tokens.filter { token in
            token.id != anchor.id &&
                (layout.sameRow(anchor,token) || abs(token.box.centerY-anchor.box.centerY) <= layout.medianTextHeight*0.9) &&
                token.box.x > anchor.box.x &&
                anchor.box.horizontalGap(to:token.box) < 0.9
        }.sorted { separation(anchor,$0) < separation(anchor,$1) }
        let below=layout.tokens.filter { token in
            token.id != anchor.id && token.box.centerY > anchor.box.centerY &&
                anchor.box.verticalGap(to:token.box) <= maximum + epsilon &&
                (abs(token.box.x-anchor.box.x) <= 0.05 + epsilon || abs(token.box.centerX-anchor.box.centerX) <= 0.08 + epsilon)
        }.sorted { separation(anchor,$0) < separation(anchor,$1) }
        let above=layout.tokens.filter { token in
            token.id != anchor.id && token.box.centerY < anchor.box.centerY && token.relHeight >= 1.3 &&
                token.box.verticalGap(to:anchor.box) <= maximum + epsilon &&
                (abs(token.box.x-anchor.box.x) <= 0.05 + epsilon || abs(token.box.centerX-anchor.box.centerX) <= 0.08 + epsilon)
        }.sorted { separation(anchor,$0) < separation(anchor,$1) }
        for (relation,score,candidates) in [(ScreenPairRelation.right,3,right),(.below,2,below),(.above,1,above)] {
            var pairs:[ScreenSemanticPair]=[]
            for token in candidates {
                guard !token.isStatusChrome,!known.contains(where:{ $0.tokenID == token.id }) else { continue }
                for value in values(in:token.normalizedText,token:token,concept:label.concept,spans:spans) {
                    pairs.append(pair(label,value,relation,score,separation(anchor,token),layout))
                }
            }
            if !pairs.isEmpty { return pairs }
        }
        return []
    }

    private struct Value {
        let text:String
        let kind:ScreenSpanKind
        let span:ScreenSpan?
        let ids:[Int]
        let feature:String
    }
    private static func values(in raw:String,token:ScreenToken,concept:ScreenLabelConcept,spans:ScreenshotSpans) -> [Value] {
        var result:[Value]=[]
        if let primary=value(in:raw,token:token,concept:concept,spans:spans) { result.append(primary) }
        let allowed:[ScreenSpanKind]
        switch concept {
        case .amountTotal,.amountExcluded: allowed=[.money]
        case .transactionDate,.otherDate: allowed=[.dateTime,.date,.time]
        case .referencePrimary,.referenceSecondary,.nonTransactionIdentifier,.unknownIdentifier: allowed=[.identifier]
        default: allowed=[]
        }
        for alternate in spans.spans where alternate.source == .alternate &&
            alternate.tokenIDs == [token.id] && allowed.contains(alternate.kind) {
            let candidate=Value(text:alternate.reading,kind:alternate.kind,span:alternate,
                                ids:alternate.tokenIDs,feature:"alternate typed reading")
            if !result.contains(where:{ $0.span?.normalized == alternate.normalized }) { result.append(candidate) }
        }
        return result
    }
    private static func value(in raw:String,token:ScreenToken,concept:ScreenLabelConcept,spans:ScreenshotSpans) -> Value? {
        let text=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let typed=spans.spans.filter { candidate in
            guard candidate.tokenIDs.contains(token.id) else { return false }
            if text.localizedCaseInsensitiveContains(candidate.reading) { return true }
            // G1's same-box DateTime reading retains the whole OCR box, including an inline label.
            if candidate.kind == .dateTime && candidate.tokenIDs == [token.id] {
                let parts=spans.spans.filter { $0.tokenIDs == [token.id] && ($0.kind == .date || $0.kind == .time) }
                return parts.contains(where:{ $0.kind == .date && text.localizedCaseInsensitiveContains($0.reading) }) &&
                    parts.contains(where:{ $0.kind == .time && text.localizedCaseInsensitiveContains($0.reading) })
            }
            return false
        }
        func first(_ kinds:[ScreenSpanKind]) -> ScreenSpan? {
            kinds.lazy.compactMap { kind in typed.first { $0.kind == kind } }.first
        }
        switch concept {
        case .amountTotal,.amountExcluded:
            guard let span=first([.money]) else { return nil }
            return .init(text:span.reading,kind:.money,span:span,ids:span.tokenIDs,feature:"typed money")
        case .transactionDate,.otherDate:
            guard let span=first([.dateTime,.date,.time]) else { return nil }
            return .init(text:text.localizedCaseInsensitiveContains(span.reading) ? span.reading : text,
                         kind:span.kind,span:span,ids:span.tokenIDs,feature:"typed date/time")
        case .referencePrimary,.referenceSecondary,.nonTransactionIdentifier,.unknownIdentifier:
            guard let span=first([.identifier]) else { return nil }
            return .init(text:span.reading,kind:.identifier,span:span,ids:span.tokenIDs,feature:"typed identifier")
        case .counterparty:
            guard text.count <= 80,text.filter(\.isLetter).count >= 3,
                  !typed.contains(where:{ [.money,.date,.dateTime,.time,.clock,.cardMask,.phone,.percent].contains($0.kind) &&
                    $0.reading.caseInsensitiveCompare(text) == .orderedSame }),
                  ScreenshotLabels.concept(for:text) == nil else { return nil }
            return .init(text:text,kind:.text,span:nil,ids:[token.id],feature:"text value")
        case .source:
            if let span=first([.cardMask,.identifier]) {
                return .init(text:span.reading,kind:span.kind,span:span,ids:span.tokenIDs,feature:"source evidence")
            }
            guard text.contains(where:\.isLetter) else { return nil }
            return .init(text:text,kind:.text,span:nil,ids:[token.id],feature:"source text")
        case .memo,.typeCategory,.unknownLabel:
            if let span=first([.identifier,.money,.dateTime,.cardMask]) {
                return .init(text:span.reading,kind:span.kind,span:span,ids:span.tokenIDs,feature:"typed context")
            }
            guard text.contains(where:\.isLetter) else { return nil }
            return .init(text:text,kind:.text,span:nil,ids:[token.id],feature:"context text")
        default: return nil
        }
    }
    private static func pair(_ label:ScreenLabel,_ value:Value,_ relation:ScreenPairRelation,_ score:Int,
                             _ distance:Double,_ layout:ScreenshotLayout) -> ScreenSemanticPair {
        return .init(label:label,valueText:value.text,valueKind:value.kind,valueSpan:value.span,
                     valueTokenIDs:value.ids,relation:relation,geometryScore:score,distance:distance,
                     features:[value.feature,"geometry \(relation)"],
                     labelObservations:[layout.tokens[label.tokenID].original],
                     valueObservations:value.ids.map { layout.tokens[$0].original })
    }
    private static func continuation(after token:ScreenToken,layout:ScreenshotLayout,spans:ScreenshotSpans,
                                     known:[ScreenLabel], owner:[Int:Int], currentLabel:Int) -> ScreenToken? {
        let candidates=layout.tokens.filter { next in
            let hasLabelToLeft = layout.tokens.contains { left in
                left.id != next.id && layout.sameRow(left,next) && left.box.x < next.box.x &&
                    (known.contains { $0.tokenID == left.id } || !ScreenshotLabels.labels(in:left).isEmpty ||
                     (left.normalizedText.count <= 40 && !left.normalizedText.contains(where:\.isNumber) &&
                      (1...4).contains(ScreenshotLabels.words(left.normalizedText).count) &&
                      left.relHeight <= 1.2))
            }
            let ownedByOtherPair = owner[next.id].map { $0 != currentLabel } ?? false
            return next.id != token.id && next.box.centerY > token.box.centerY &&
                token.box.verticalGap(to:next.box) <= layout.medianTextHeight*1.6 + epsilon &&
                abs(next.box.x-token.box.x) <= 0.05 + epsilon &&
                abs(next.relHeight-token.relHeight) <= 0.5 + epsilon &&
                next.normalizedText.contains(where:\.isLetter) &&
                ScreenshotLabels.labels(in:next).isEmpty && !hasLabelToLeft && !ownedByOtherPair &&
                !spans.spans.contains(where: { $0.tokenIDs == [next.id] &&
                    [.money,.date,.dateTime,.time,.identifier,.cardMask,.phone,.clock,.percent].contains($0.kind) &&
                    $0.reading.caseInsensitiveCompare(next.normalizedText) == .orderedSame })
        }.sorted { separation(token,$0) < separation(token,$1) }
        return candidates.first
    }
    private static func separation(_ a:ScreenToken,_ b:ScreenToken) -> Double {
        hypot(a.box.centerX-b.box.centerX,a.box.centerY-b.box.centerY)
    }
}
