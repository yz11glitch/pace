import Foundation

/// Evidence adapter for an intentional screenshot capture.
public enum ScreenshotIntentionalCapture {
    public struct Money: Sendable {
        public let selectedText: String?
        public let matchedText: String?
        public let parsedMinor: Int?
        public let amountMinor: Int?
        public let currency: String?
        public let trust: CaptureFieldTrust
        public let reason: String
    }

    public static func money(_ selectedText: String?, lines: [ScreenshotTextLine],
                             capturedAt: Instant, timeZone: String) -> Money {
        guard let selectedText, !selectedText.isEmpty, selectedText != "NONE" else {
            return .init(selectedText: selectedText, matchedText: nil, parsedMinor: nil, amountMinor: nil,
                         currency: nil, trust: .unresolved, reason: "no selected amount")
        }
        let layout = ScreenshotLayout(lines)
        let spans = ScreenshotSpans(layout, capturedAt: capturedAt, timeZone: timeZone)
        let relations = ScreenshotRelations(spans)
        // Parse the selection with the same typed recognizer as OCR. Compare currency and
        // magnitude; a debit sign is presentation of direction, not a different amount.
        let selectedSpans = ScreenshotSpans(ScreenshotLayout([ScreenshotTextLine(selectedText)]),
                                            capturedAt: capturedAt, timeZone: timeZone).of(.money)
        let selectedMoney = selectedSpans.first(where: { $0.reading == selectedText })?.money
        guard let selectedMoney, let selectedCurrency = selectedMoney.currency,
              !selectedMoney.repaired, !selectedMoney.noCurrency else {
            return .init(selectedText: selectedText, matchedText: nil, parsedMinor: nil, amountMinor: nil,
                         currency: nil, trust: .unresolved, reason: "selected text is not explicit typed money")
        }
        let quotedSpans = spans.of(.money).filter {
            $0.money?.currency == selectedCurrency && $0.money?.minorUnits == selectedMoney.minorUnits
        }
        let primarySpans = quotedSpans.filter { $0.source == .primary }
        let matches = primarySpans.filter { !excluded($0, relations: relations) }
        let rejection = quotedSpans.isEmpty ? "no typed OCR money span matches selected currency and value" :
            primarySpans.isEmpty ? "selected money is only an alternate or joined OCR reading" :
            matches.isEmpty ? "selected money is excluded by nearby OCR evidence" :
            "selected OCR money did not parse into valid minor units"
        guard let span = matches.first, let parsed = span.money,
              let amount = Int(exactly: parsed.minorUnits),
              (1...maximumAmountMinor).contains(amount) else {
            return .init(selectedText: selectedText, matchedText: nil, parsedMinor: nil, amountMinor: nil,
                         currency: nil, trust: .unresolved, reason: rejection)
        }
        let trusted = parsed.currency == "MYR" && !parsed.repaired && !parsed.noCurrency &&
            span.tokenIDs.allSatisfy { layout.tokens[$0].confidence >= 0.80 }
        return .init(selectedText: selectedText, matchedText: span.reading, parsedMinor: amount,
                     amountMinor: trusted ? amount : nil, currency: parsed.currency,
                     trust: trusted ? .trusted : .unresolved,
                     reason: trusted ? "grounded MYR amount by typed currency and value" :
                        parsed.currency != "MYR" ? "selected OCR money is not explicit MYR" :
                        parsed.repaired ? "OCR money reading required digit repair" :
                        span.tokenIDs.contains(where: { layout.tokens[$0].confidence < 0.80 }) ?
                            "selected OCR money confidence below 0.80" : "selected OCR money needs review")
    }

    public static func merchant(_ selectedText: String?, lines: [ScreenshotTextLine]) -> (name: String?, trust: CaptureFieldTrust) {
        guard let selectedText, !selectedText.isEmpty, selectedText != "NONE",
              selectedText.count <= 100, selectedText.contains(where: \.isLetter),
              let observation = lines.first(where: { $0.text.contains(selectedText) && $0.confidence >= 0.80 }) else {
            return (nil, .unresolved)
        }
        // Exact substring support allows OCR such as "Paid to ZUS COFFEE" while preserving
        // the merchant's visible spelling for exact alias lookup in MerchantMemory.
        guard !observation.text.isEmpty else { return (nil, .unresolved) }
        return (selectedText, .usable)
    }

    public static func request(lines: [ScreenshotTextLine], resolution: ScreenshotFieldResolution,
                               imageHash: String,
                               capturedAt: Instant, timeZone: String) -> CaptureRequest {
        var rawFields = ["imageHash": imageHash]
        if resolution.merchant.kind == .decisive, let merchant = resolution.merchant.value {
            rawFields["ocrMerchantCandidate"] = merchant
        }
        rawFields["merchantSelectionSource"] = resolution.merchant.kind == .decisive ? "ocr" : "none"
        rawFields["merchantFallbackCandidate"] = resolution.merchant.value ?? "none"
        if resolution.amount.kind == .weak { rawFields["amountWeakReason"] = resolution.amount.rule }
        let amountMinor = resolution.amount.value?.currency == "MYR" ? resolution.amount.value?.minorUnits : nil
        let amountCandidates = resolution.amount.chooserOffer.isEmpty ?
            resolution.amount.selected.map { [$0.value] } ?? [] : resolution.amount.chooserOffer.map(\.value)
        let merchant = resolution.merchant.kind == .decisive ? resolution.merchant.value :
            (resolution.merchant.kind == .weak ||
             resolution.merchant.kind == .ambiguous && resolution.merchant.rule == "title-only counterparty") ?
                resolution.merchant.value : nil
        return CaptureRequest(source: "screenshot", path: "screenshot_intentional_fm",
                              amountMinor: amountMinor, merchant: merchant,
                              // Back Tap means the payment happened now. Screen dates are evidence
                              // for diagnostics only and never decide the ledger date on this path.
                              occurredAt: capturedAt,
                              capturedAt: capturedAt, timeZone: timeZone,
                              reference: resolution.reference.value,
                              idempotencyKey: "screenshot:\(imageHash)",
                              rawFields: rawFields,
                              amountTrust: resolution.amount.kind == .decisive ? .trusted : .unresolved,
                              merchantTrust: resolution.merchant.kind == .decisive ? .usable : .unresolved,
                              dateTrust: .trusted, statusClean: resolution.status.clean,
                              extractionAmbiguous: resolution.amount.kind == .ambiguous,
                              amountCandidates: amountCandidates)
    }

    private static func excluded(_ span: ScreenSpan, relations: ScreenshotRelations) -> Bool {
        if relations.of(.amountExcluded).contains(where: { pair in
            pair.valueSpan?.normalized == span.normalized &&
                pair.valueTokenIDs.contains(where: span.tokenIDs.contains)
        }) { return true }
        return span.tokenIDs.contains { id in
            !Set(ScreenshotLabels.words(relations.layout.tokens[id].text))
                .isDisjoint(with: ScreenshotLexicon.excludedAmounts)
        }
    }
}
