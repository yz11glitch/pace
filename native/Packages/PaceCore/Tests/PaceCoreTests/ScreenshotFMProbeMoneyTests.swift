#if DEBUG
import Foundation
import Testing
@testable import PaceCore

@Suite("FM representation probe money parsing") struct ScreenshotFMProbeMoneyTests {
    private let captured = Instant(iso: "2026-09-28T00:00:00Z")!
    private let zone = "Asia/Kuala_Lumpur"

    private func lines(_ texts: [String]) -> [ScreenshotTextLine] {
        texts.enumerated().map { index, text in
            ScreenshotTextLine(text, confidence: 0.98, x: 0.1, y: 0.1 + Double(index) * 0.1,
                               width: 0.7, height: 0.035)
        }
    }

    @Test func exactSelectedMoneyUsesTypedOCRAndCanonicalCurrency() {
        let ocr = lines(["Spent RM 949.27 at DUMAKIVO LAB", "Balance RM 120.00"])
        let result = ScreenshotFMProbeMoney.parse("RM 949.27", lines: ocr, capturedAt: captured, timeZone: zone)
        #expect(result.status == "supported")
        #expect(result.amountMinor == 94927)
        #expect(result.currency == "MYR")
        #expect(result.ocrObservation == "Spent RM 949.27 at DUMAKIVO LAB")
    }

    @Test func debitSignAndSplitCurrencyAreParsedWithoutModelArithmetic() {
        let signed = ScreenshotFMProbeMoney.parse("-RM 563.76", lines: lines(["-RM 563.76"]),
                                                  capturedAt: captured, timeZone: zone)
        #expect(signed.amountMinor == 56376)
        #expect(signed.currency == "MYR")
        let split = [ScreenshotTextLine("RM", confidence: 0.98, x: 0.35, y: 0.19, width: 0.1, height: 0.02),
                     ScreenshotTextLine("15.00", confidence: 0.98, x: 0.47, y: 0.215, width: 0.32, height: 0.06)]
        let result = ScreenshotFMProbeMoney.parse("15.00", lines: split, capturedAt: captured, timeZone: zone)
        #expect(result.status == "supported")
        #expect(result.amountMinor == 1500)
    }

    @Test func unsupportedTextAndExcludedMoneyAreRejected() {
        let ocr = lines(["Payment complete", "Total RM 12.80", "Balance RM 200.00"])
        #expect(ScreenshotFMProbeMoney.parse(nil, lines: ocr, capturedAt: captured, timeZone: zone).status == "abstained")
        #expect(ScreenshotFMProbeMoney.parse("nil", lines: ocr, capturedAt: captured, timeZone: zone).status == "unsupported")
        #expect(ScreenshotFMProbeMoney.parse("RM 200.00", lines: ocr, capturedAt: captured, timeZone: zone).status == "unsupported")
        #expect(ScreenshotFMProbeMoney.parse("RM 12.80", lines: ocr, capturedAt: captured, timeZone: zone).amountMinor == 1280)
    }
}
#endif
