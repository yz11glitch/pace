import Foundation

enum ScreenLabelConcept: Sendable {
    case counterparty, referencePrimary, referenceSecondary, nonTransactionIdentifier, unknownIdentifier
    case memo, source, amountTotal, amountExcluded, transactionDate, otherDate
    case statusPositive, statusNegative, incoming, prePayment, chrome, typeCategory, rail, unknownLabel
}

struct ScreenLabel: Sendable {
    let concept: ScreenLabelConcept
    let tokenID: Int
    let labelText: String
    let normalizedWords: [String]
    let inlineValue: String?
    let isPreposition: Bool
}

/// Compositional labels. Unknown words terminate inline prefix parsing rather than extending a label.
enum ScreenshotLabels {
    static func words(_ text:String) -> [String] {
        let folded=text.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of:"’",with:"'")
        guard let regex=try? NSRegularExpression(pattern:#"[\p{L}\p{N}]+|#|&"#) else { return [] }
        return regex.matches(in:folded,range:NSRange(folded.startIndex...,in:folded)).compactMap { match in
            guard let range=Range(match.range,in:folded) else { return nil }
            let value=String(folded[range])
            switch value {
            case "names": return "name"
            case "references": return "reference"
            case "transactions": return "transaction"
            case "payments": return "payment"
            case "receipts": return "receipt"
            case "charges": return "charge"
            default: return value
            }
        }
    }

    static func concept(for phrase:String) -> ScreenLabelConcept? {
        let parts=words(phrase)
        guard !parts.isEmpty,parts.count <= 5,parts.allSatisfy(ScreenshotLexicon.words.contains) else { return nil }
        let set=Set(parts)
        let has:(Set<String>)->Bool = { !set.isDisjoint(with:$0) }
        let heads=ScreenshotLexicon.identifierHeads
        if has(heads) {
            if has(ScreenshotLexicon.memoQualifiers) && (set.contains("reference") || set.contains("ref")) { return .memo }
            if has(ScreenshotLexicon.nonTransactionQualifiers) { return .nonTransactionIdentifier }
            if has(ScreenshotLexicon.authorizationQualifiers) { return .referenceSecondary }
            if has(ScreenshotLexicon.transactionQualifiers) { return .referencePrimary }
            if set.contains("reference") || set.contains("ref") { return .referencePrimary }
            return .unknownIdentifier
        }
        if has(ScreenshotLexicon.negativeStatus) { return .statusNegative }
        if has(ScreenshotLexicon.incoming) { return .incoming }
        if set.contains("slide") && set.contains("pay") || set.contains("bayar") && set.contains("sekarang") {
            return .prePayment
        }
        if set.contains("memo") || set.contains("note") || set.contains("payment") && set.contains("details") {
            return .memo
        }
        if has(ScreenshotLexicon.institutions) { return .source }
        if has(ScreenshotLexicon.counterparties) { return .counterparty }
        if has(ScreenshotLexicon.positiveStatus) &&
            !has(["total", "amount", "jumlah", "amaun"]) { return .statusPositive }
        if has(ScreenshotLexicon.excludedAmounts) { return .amountExcluded }
        if has(ScreenshotLexicon.amountWords) {
            if set.contains("paid") && parts.count == 1 { return .statusPositive }
            if set.contains("pay") && set.contains("now") { return .prePayment }
            return .amountTotal
        }
        if has(ScreenshotLexicon.dateWords) { return has(ScreenshotLexicon.otherDateWords) ? .otherDate : .transactionDate }
        if has(ScreenshotLexicon.negativeStatus) { return .statusNegative }
        if set.contains("slide") && set.contains("pay") || set.contains("bayar") && set.contains("sekarang") {
            return .prePayment
        }
        if has(ScreenshotLexicon.positiveStatus) { return .statusPositive }
        if has(ScreenshotLexicon.prePayment) { return .prePayment }
        if has(ScreenshotLexicon.chrome) { return .chrome }
        if has(ScreenshotLexicon.typeCategory) { return .typeCategory }
        if has(ScreenshotLexicon.rails) { return .rail }
        return nil
    }

    static func labels(in token:ScreenToken) -> [ScreenLabel] {
        let text=token.normalizedText
        let normalized=words(text)
        guard !normalized.isEmpty else { return [] }
        // The value starts at the first word after the longest known prefix. Punctuation before it is trimmed.
        guard let regex=try? NSRegularExpression(pattern:#"[\p{L}\p{N}]+|#|&"#) else { return [] }
        let matches=regex.matches(in:text,range:NSRange(text.startIndex...,in:text))
        var best:ScreenLabel?
        for count in 1...min(5,matches.count) {
            guard let end=Range(matches[count-1].range,in:text)?.upperBound else { continue }
            let prefix=String(text[..<end])
            guard let concept=concept(for:prefix) else { continue }
            let suffix=String(text[end...]).trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters))
            best = .init(concept:concept,tokenID:token.id,labelText:prefix,normalizedWords:Array(normalized.prefix(count)),
                       inlineValue:suffix.isEmpty ? nil : suffix,isPreposition:false)
        }
        if let best { return [best] }
        // Preposition cues work even when followed by an otherwise unknown counterparty name.
        let lower=text.lowercased()
        for cue in ["paid to", "pay to", "sent to", "transfer to", "to", "at", "kepada", "ke"] {
            guard lower.hasPrefix(cue+" "),normalized.count <= 10 else { continue }
            let suffix=String(text.dropFirst(cue.count)).trimmingCharacters(in:.whitespacesAndNewlines)
            guard !suffix.isEmpty,suffix.contains(where:\.isLetter) else { continue }
            return [.init(concept:.counterparty,tokenID:token.id,labelText:String(text.prefix(cue.count)),
                          normalizedWords:words(cue),inlineValue:suffix,isPreposition:true)]
        }
        return []
    }
}
