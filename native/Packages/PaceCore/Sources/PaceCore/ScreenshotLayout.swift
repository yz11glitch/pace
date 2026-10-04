import Foundation

/// Geometry derived from normalized Vision coordinates. Original observations remain in each token.
struct ScreenshotRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var right: Double { x + width }
    var bottom: Double { y + height }
    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
    var area: Double { width * height }
    func verticalOverlap(with other: Self) -> Double { max(0, min(bottom, other.bottom) - max(y, other.y)) }
    func horizontalOverlap(with other: Self) -> Double { max(0, min(right, other.right) - max(x, other.x)) }
    func horizontalGap(to other: Self) -> Double { max(0, other.x - right) }
    func verticalGap(to other: Self) -> Double { max(0, other.y - bottom) }
    func sharesVisualLine(with other: Self) -> Bool {
        let smaller = min(height, other.height)
        return smaller > 0 && verticalOverlap(with: other) >= smaller * 0.5
    }
}

enum ScreenBand: Sendable { case upper, middle, lower }
enum ScreenAlignment: Sendable { case left, center, right }
enum ScreenZone: Sendable { case chrome, header, body }

struct ScreenToken: Sendable {
    let id: Int
    let original: ScreenshotTextLine
    let normalizedText: String
    let box: ScreenshotRect
    let relHeight: Double
    let band: ScreenBand
    let alignment: ScreenAlignment
    let isStatusChrome: Bool
    var text: String { original.text }
    var confidence: Double { original.confidence }
    var pass: String { original.pass }
    var alternates: [String] { original.alternates }
    var centerY: Double { box.centerY }
    var prominence: Double { relHeight }

    /// G2 supplies the first label/value relation. Until then, non-chrome tokens are provisional header.
    func zone(firstRelationY: Double? = nil) -> ScreenZone {
        if isStatusChrome { return .chrome }
        guard let firstRelationY else { return .header }
        return centerY < firstRelationY ? .header : .body
    }
}

struct ScreenVisualLine: Sendable {
    let index: Int
    let tokenIDs: [Int]
    let top: Double
    let bottom: Double
    let left: Double
    let right: Double
    var height: Double { bottom - top }
}

/// Pure layout features. Token ids and reading order are derived from geometry, never OCR array order.
struct ScreenshotLayout: Sendable {
    let tokens: [ScreenToken]
    let lines: [ScreenVisualLine]
    let medianTextHeight: Double

    init(_ observations: [ScreenshotTextLine]) {
        let valid = observations.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let heights = valid.map(\.height).filter { $0 > 0 }.sorted()
        let median = heights.isEmpty ? 0.03 : heights[heights.count / 2]
        medianTextHeight = median
        let sorted = valid.sorted {
            let a = ScreenshotRect(x:$0.x,y:$0.y,width:$0.width,height:$0.height)
            let b = ScreenshotRect(x:$1.x,y:$1.y,width:$1.width,height:$1.height)
            if a.centerY != b.centerY { return a.centerY < b.centerY }
            if a.x != b.x { return a.x < b.x }
            if $0.text != $1.text { return $0.text < $1.text }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            if $0.pass != $1.pass { return $0.pass < $1.pass }
            return $0.alternates.lexicographicallyPrecedes($1.alternates)
        }
        tokens = sorted.enumerated().map { index, source in
            let box = ScreenshotRect(x:source.x,y:source.y,width:source.width,height:source.height)
            let normalized = source.text.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in:.whitespacesAndNewlines)
                .replacingOccurrences(of:#"\s+"#,with:" ",options:.regularExpression)
            let band: ScreenBand = box.centerY < 1.0/3 ? .upper : box.centerY < 2.0/3 ? .middle : .lower
            let alignment: ScreenAlignment = box.centerX < 1.0/3 ? .left : box.centerX < 2.0/3 ? .center : .right
            let carrierLike = box.x < 0.25 && box.height <= median * 0.8 &&
                normalized.range(of:#"^[\p{L} ]{2,16}$"#,options:.regularExpression) != nil
            let chrome = box.y < 0.04 && (carrierLike ||
                normalized.range(of:#"^\d{1,2}:\d{2}(?:\s*(?:AM|PM))?$"#,options:[.regularExpression,.caseInsensitive]) != nil ||
                normalized.range(of:#"^(?:\d{1,3}%|battery\s*\d{1,3}%|wifi|signal|[1-5]g)$"#,options:[.regularExpression,.caseInsensitive]) != nil)
            return ScreenToken(id:index,original:source,normalizedText:normalized,box:box,
                               relHeight:source.height/median,band:band,alignment:alignment,isStatusChrome:chrome)
        }
        var parent = Array(tokens.indices)
        func root(_ i:Int) -> Int {
            var n=i
            while parent[n] != n { n=parent[n] }
            return n
        }
        for i in tokens.indices {
            for j in tokens.indices where j > i && tokens[i].box.sharesVisualLine(with:tokens[j].box) {
                parent[root(j)] = root(i)
            }
        }
        var groups:[Int:[ScreenToken]] = [:]
        for token in tokens { groups[root(token.id),default:[]].append(token) }
        let ordered = groups.values.sorted {
            let at = $0.map { $0.box.centerY }.reduce(0,+)/Double($0.count)
            let bt = $1.map { $0.box.centerY }.reduce(0,+)/Double($1.count)
            return at == bt ? ($0.map(\.box.x).min() ?? 0) < ($1.map(\.box.x).min() ?? 0) : at < bt
        }
        lines = ordered.enumerated().map { i,group in
            let visual = group.sorted { $0.box.x == $1.box.x ? $0.id < $1.id : $0.box.x < $1.box.x }
            return ScreenVisualLine(index:i,tokenIDs:visual.map(\.id),top:group.map(\.box.y).min()!,
                                    bottom:group.map(\.box.bottom).max()!,left:group.map(\.box.x).min()!,
                                    right:group.map(\.box.right).max()!)
        }
    }

    func visualLine(of tokenID:Int) -> ScreenVisualLine? { lines.first { $0.tokenIDs.contains(tokenID) } }
    func sameRow(_ a:ScreenToken,_ b:ScreenToken) -> Bool { visualLine(of:a.id)?.index == visualLine(of:b.id)?.index }
    func rightOf(_ anchor:ScreenToken, maximumGap:Double? = nil) -> [ScreenToken] {
        tokens.filter { $0.id != anchor.id && sameRow(anchor,$0) && $0.box.x >= anchor.box.right &&
            (maximumGap == nil || anchor.box.horizontalGap(to:$0.box) <= maximumGap!) }
        .sorted { distance(anchor,$0) < distance(anchor,$1) }
    }
    func below(_ anchor:ScreenToken, maximumGap:Double? = nil) -> [ScreenToken] {
        tokens.filter { $0.id != anchor.id && $0.box.centerY > anchor.box.centerY &&
            $0.box.horizontalOverlap(with:anchor.box) > 0 &&
            (maximumGap == nil || anchor.box.verticalGap(to:$0.box) <= maximumGap!) }
        .sorted { distance(anchor,$0) < distance(anchor,$1) }
    }
    func nearest(to anchor:ScreenToken, where allowed:(ScreenToken)->Bool) -> ScreenToken? {
        tokens.filter { $0.id != anchor.id && allowed($0) }.min { distance(anchor,$0) < distance(anchor,$1) }
    }
    func keyValueLines(minimumGap:Double = 0.15) -> [ScreenVisualLine] {
        lines.filter { line in
            let values=line.tokenIDs.map { tokens[$0] }
            return zip(values,values.dropFirst()).contains { $0.box.horizontalGap(to:$1.box) >= minimumGap }
        }
    }
    func columns(edge:KeyPath<ScreenshotRect,Double> = \.x,tolerance:Double = 0.03) -> [[Int]] {
        var result:[[Int]]=[]
        for token in tokens.sorted(by:{ $0.box[keyPath:edge] < $1.box[keyPath:edge] }) {
            if let index=result.firstIndex(where:{ abs(tokens[$0[0]].box[keyPath:edge]-token.box[keyPath:edge]) <= tolerance }) {
                result[index].append(token.id)
            } else { result.append([token.id]) }
        }
        return result
    }
    private func distance(_ a:ScreenToken,_ b:ScreenToken) -> Double {
        hypot(a.box.centerX-b.box.centerX,a.box.centerY-b.box.centerY)
    }
}
