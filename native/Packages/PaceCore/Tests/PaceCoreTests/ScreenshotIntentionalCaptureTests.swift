import Foundation
import Testing
@testable import PaceCore

@Suite("Intentional screenshot capture evidence") struct ScreenshotIntentionalCaptureTests {
    private let captured = Instant(iso: "2026-09-28T00:00:00Z")!
    private let zone = "Asia/Kuala_Lumpur"

    private func lines(_ texts: [String]) -> [ScreenshotTextLine] {
        texts.enumerated().map { index, text in
            ScreenshotTextLine(text, confidence: 0.98, x: 0.1, y: 0.1 + Double(index) * 0.1,
                               width: 0.7, height: 0.035)
        }
    }
    private func request(_ ocr: [ScreenshotTextLine], hash: String) -> CaptureRequest {
        ScreenshotIntentionalCapture.request(lines: ocr,
            resolution: ScreenshotFieldResolver().resolve(ocr, capturedAt: captured, timeZone: zone),
            imageHash: hash, capturedAt: captured, timeZone: zone)
    }

    @Test func selectsGroundedMoneyAndMerchantWithBalanceDecoy() {
        let ocr = lines(["Payment successful", "Total -RM 577.52", "Balance RM 900.00", "Paid to ZUS COFFEE"])
        let amount = ScreenshotIntentionalCapture.money("-RM 577.52", lines: ocr,
            capturedAt: captured, timeZone: zone)
        #expect(amount.amountMinor == 57752)
        #expect(amount.currency == "MYR")
        #expect(amount.trust == .trusted)
        let request = request(ocr, hash: "abc")
        #expect(request.amountMinor == 57752)
        #expect(request.amountTrust == .trusted)
        #expect(request.merchant == "ZUS COFFEE")
        #expect(request.merchantTrust == .usable)
        #expect(request.statusClean)
        #expect(request.idempotencyKey == "screenshot:abc")
    }

    @Test func inventedAndExcludedMoneyCannotBecomeTrusted() {
        let ocr = lines(["Payment successful", "Total RM 12.80", "Balance RM 200.00"])
        let invented = ScreenshotIntentionalCapture.money("RM 99.00", lines: ocr,
            capturedAt: captured, timeZone: zone)
        #expect(invented.amountMinor == nil)
        #expect(invented.reason == "no typed OCR money span matches selected currency and value")
        let balance = ScreenshotIntentionalCapture.money("RM 200.00", lines: ocr,
            capturedAt: captured, timeZone: zone)
        #expect(balance.amountMinor == nil)
        #expect(balance.reason == "selected money is excluded by nearby OCR evidence")
        let request = request(ocr, hash: "def")
        #expect(request.amountTrust == .trusted)
        #expect(request.amountMinor == 1280)
        #expect(request.merchant == nil)
        #expect(request.merchantTrust == .unresolved)
    }

    @Test func nonMYRCurrencyAndPendingStatusRequireReview() {
        let ocr = lines(["Payment pending", "USD 15.00", "Paid to EXAMPLE SHOP"])
        let money = ScreenshotIntentionalCapture.money("USD 15.00", lines: ocr,
            capturedAt: captured, timeZone: zone)
        #expect(money.parsedMinor == 1500)
        #expect(money.amountMinor == nil)
        #expect(money.reason == "selected OCR money is not explicit MYR")
        let request = request(ocr, hash: "ghi")
        #expect(request.amountMinor == nil)
        #expect(request.amountTrust == .unresolved)
        #expect(!request.statusClean)
    }

    @Test func debitSignAndMoneySpacingGroundByCurrencyAndValue() {
        let ocr = lines(["Completed", "-RM 53.00", "To NORTH QUAY BOOKS"])
        for selected in ["RM 53.00", "RM53.00", "MYR 53.00"] {
            let result = ScreenshotIntentionalCapture.money(selected, lines: ocr,
                capturedAt: captured, timeZone: zone)
            #expect(result.matchedText == "-RM 53.00")
            #expect(result.currency == "MYR")
            #expect(result.amountMinor == 5300)
            #expect(result.trust == .trusted)
        }
    }

    @Test func moneyMismatchAndReferencesCannotGround() {
        let ocr = lines(["Completed", "-RM 53.00", "Reference 260928B42BD813R"])
        for selected in ["RM 54.00", "USD 53.00", "260928B42BD813R"] {
            let result = ScreenshotIntentionalCapture.money(selected, lines: ocr,
                capturedAt: captured, timeZone: zone)
            #expect(result.amountMinor == nil)
            #expect(result.trust == .unresolved)
        }
        let referenceOnly = ScreenshotIntentionalCapture.money("RM 53.00",
            lines: lines(["Reference 260928B42BD813R"]), capturedAt: captured, timeZone: zone)
        #expect(referenceOnly.amountMinor == nil)
    }

    @Test func strongCounterpartyResolvesWithoutFieldFM() {
        let ocr = lines(["Completed", "-RM 53.00", "To NORTH QUAY BOOKS", "Reference 260928B42BD813R"])
        let request = request(ocr, hash: "fallback")
        #expect(request.merchant == "NORTH QUAY BOOKS")
        #expect(request.merchantTrust == .usable)
        #expect(request.rawFields["merchantSelectionSource"] == "ocr")
        #expect(request.amountMinor == 5300)
    }

    @Test func weakMerchantEvidenceRemainsUnresolved() {
        let request = request(lines(["Completed", "RM 53.00", "NORTH QUAY BOOKS"]), hash: "weak")
        #expect(request.merchant == nil)
        #expect(request.merchantTrust == .unresolved)
        #expect(request.rawFields["merchantSelectionSource"] == "none")

        let lowConfidence = [ScreenshotTextLine("Completed", confidence: 0.98, y: 0.1),
            ScreenshotTextLine("RM 53.00", confidence: 0.98, y: 0.2),
            ScreenshotTextLine("To NORTH QUAY BOOKS", confidence: 0.62, y: 0.3)]
        let uncertain = self.request(lowConfidence, hash: "uncertain")
        #expect(uncertain.merchant == "NORTH QUAY BOOKS")
        #expect(uncertain.merchantTrust == .unresolved)
    }
}
