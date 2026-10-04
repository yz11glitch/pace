import PaceCore
import Testing

@Suite("Screenshot interpretation")
struct ScreenshotInterpretationTests {
    let captured = Instant(iso: "2026-09-27T08:00:00+00:00")!
    let zone = "Asia/Kuala_Lumpur"

    func lines(_ texts: [String]) -> [ScreenshotTextLine] {
        texts.enumerated().map { index, text in
            ScreenshotTextLine(text, confidence: 0.98, y: Double(index) * 0.06)
        }
    }

    func parse(_ texts: [String]) -> ScreenshotInterpretation {
        ScreenshotInterpreter().interpret(lines(texts), capturedAt: captured, timeZone: zone)
    }

    @Test func clearPaymentAmountMerchantReference() {
        let value = parse(["Payment successful", "RM 23.90", "Paid to FAMILYMART KLCC", "Reference: 123456789"])
        #expect(value.detection == .payment && value.parser == "generic" && value.provider == nil)
        #expect(value.amountMinor == 2_390 && value.amountTrust == .trusted)
        #expect(value.merchant == "FAMILYMART KLCC" && value.merchantTrust == .usable)
        #expect(value.reference == "123456789" && value.statusClean)
        let request = ScreenshotCaptureAdapter().adapt((value, "abcdef"), capturedAt: captured, timeZone: zone)
        #expect(request.source == "screenshot" && request.path == "screenshot_generic")
        #expect(request.reference == "123456789" && request.idempotencyKey == "screenshot:abcdef")
        #expect(request.categoryID == nil && request.categoryTrust == .unresolved)
    }

    @Test func amountFormsAndMalformedValues() {
        #expect(parse(["Payment completed", "RM23.90", "Merchant: ZUS Coffee"]).amountMinor == 2_390)
        #expect(parse(["Payment completed", "23.90 MYR", "Merchant: ZUS Coffee"]).amountMinor == 2_390)
        #expect(parse(["Payment completed", "RM 1,234.50", "Merchant: ZUS Coffee"]).amountMinor == 123_450)
        let malformed = parse(["Payment completed", "RM 23.9", "Merchant: ZUS Coffee"])
        #expect(malformed.amountMinor == nil && malformed.amountTrust == .unresolved)
    }

    @Test func separateOCRBoxesReconstructAmountAndPayeeRows() {
        let observations = [
            ScreenshotTextLine("ZUS Coffee", x: 0.4, y: 0.3, width: 0.3),
            ScreenshotTextLine("Paid to", x: 0.1, y: 0.3, width: 0.2),
            ScreenshotTextLine("23.90", x: 0.6, y: 0.2, width: 0.2),
            ScreenshotTextLine("RM", x: 0.4, y: 0.2, width: 0.1),
            ScreenshotTextLine("Payment successful", y: 0.1)]
        let result = ScreenshotInterpreter().interpret(observations, capturedAt: captured, timeZone: zone)
        #expect(result.amountMinor == 2_390 && result.merchant == "ZUS Coffee")
    }

    @Test func multipleAmountsUseExplicitTotalNotBalance() {
        let value = parse(["Payment successful", "Balance RM 100.00", "Total paid RM 23.90",
                           "Paid to ZUS Coffee", "Transaction ID 12345678"])
        #expect(value.amountMinor == 2_390 && value.amountTrust == .trusted)
        #expect(value.amountCandidates.count == 2)
    }

    @Test func ambiguousAmountsStayUnresolved() {
        let value = parse(["Payment successful", "RM 23.90", "RM 32.90", "Paid to ZUS Coffee"])
        #expect(value.amountMinor == nil && value.extractionAmbiguous)
        #expect(value.amountCandidates.count == 2)
    }

    @Test func lowDigitConfidenceForcesReview() {
        var values = lines(["Payment successful", "RM 23.90", "Paid to ZUS Coffee"])
        values[1] = ScreenshotTextLine("RM 23.90", confidence: 0.68, y: 0.06)
        let value = ScreenshotInterpreter().interpret(values, capturedAt: captured, timeZone: zone)
        #expect(value.amountMinor == 2_390 && value.amountTrust == .unresolved)
        #expect(value.extractionAmbiguous)
    }

    @Test func lowPayeeConfidenceCannotBorrowTrustedMemory() {
        var values = lines(["Payment successful", "RM 23.90", "Paid to ZUS Coffee"])
        values[2] = ScreenshotTextLine("Paid to ZUS Coffee", confidence: 0.62, y: 0.12)
        let value = ScreenshotInterpreter().interpret(values, capturedAt: captured, timeZone: zone)
        #expect(value.merchant == "ZUS Coffee" && value.merchantTrust == .unresolved)
    }

    @Test func foreignCurrencyHintForcesAmountReview() {
        let value = parse(["Payment successful", "RM 23.90", "Exchange USD 5.25", "Paid to ZUS Coffee"])
        #expect(value.amountMinor == 2_390 && value.amountTrust == .unresolved)
        #expect(value.extractionAmbiguous)
    }

    @Test func unrelatedNumbersAreNotAmounts() {
        let value = parse(["Payment successful", "Transaction ID 1234567890", "27/09/2026 15:42",
                           "Merchant: ZUS Coffee"])
        #expect(value.amountMinor == nil && value.merchant == "ZUS Coffee")
        #expect(value.reference == "1234567890")
    }

    @Test func missingMerchantAndMissingAmountPreservePartialEvidence() {
        let noMerchant = parse(["Payment successful", "RM 12.50"])
        #expect(noMerchant.amountMinor == 1_250 && noMerchant.merchant == nil)
        let noAmount = parse(["Payment successful", "Paid to ZUS Coffee"])
        #expect(noAmount.amountMinor == nil && noAmount.merchant == "ZUS Coffee")
    }

    @Test func nonPaymentIsRejectedBeforeFinancialAdapter() {
        let result = parse(["Weather today", "Cloudy", "RM 23.90", "ZUS Coffee"])
        #expect(result.detection == .notPayment && result.amountMinor == nil)
    }

    @Test func weakPaymentEvidenceIsDraftableWithoutConfirmedStatus() {
        let value = parse(["Merchant: ZUS Coffee", "RM 12.50", "Reference: ABC123456"])
        #expect(value.detection == .payment && !value.statusClean)
        #expect(value.merchant == "ZUS Coffee" && value.reference == "ABC123456")
    }

    @Test func textOrderDoesNotRequireProviderTemplate() {
        let value = parse(["Paid to ZUS Coffee", "RM 23.90", "Payment completed", "Reference: ABC123456"])
        #expect(value.detection == .payment && value.amountMinor == 2_390)
        #expect(value.merchant == "ZUS Coffee" && value.reference == "ABC123456")
    }

    @Test func failedPaymentRemainsReviewable() {
        let result = parse(["Payment unsuccessful", "RM 23.90", "Paid to ZUS Coffee"])
        #expect(result.detection == .payment && !result.statusClean)
        let conflicting = parse(["Payment successful", "Status pending", "RM 23.90", "Paid to ZUS Coffee"])
        #expect(conflicting.detection == .payment && !conflicting.statusClean)
    }

    @Test func explicitDateUsesDayFirstAndStaleness() {
        let fresh = parse(["Payment successful", "RM 12.50", "Paid to ZUS Coffee", "27/09/2026 15:42"])
        #expect(fresh.occurredAt != nil && fresh.dateTrust == .trusted)
        #expect(fresh.occurredAt?.seconds == Instant(iso: "2026-09-27T07:42:00+00:00")?.seconds)
        let old = parse(["Payment successful", "RM 12.50", "Paid to ZUS Coffee", "18/09/2026 15:42"])
        #expect(old.occurredAt != nil && old.dateTrust == .unresolved)
        let absent = parse(["Payment successful", "RM 12.50", "Paid to ZUS Coffee"])
        #expect(absent.occurredAt == nil && absent.dateTrust == .trusted)
    }

    @Test func observedDuitNowConfirmationLayout() {
        let observations = [
            ScreenshotTextLine("Completed", x: 0.35, y: 0.07),
            ScreenshotTextLine("-RM 11.35", x: 0.32, y: 0.16),
            ScreenshotTextLine("To NORTHWIND RESTAURANT", x: 0.16, y: 0.24),
            ScreenshotTextLine("25 Sep 2026, 2:44 PM", x: 0.16, y: 0.33),
            ScreenshotTextLine("From Ryt Credit", x: 0.16, y: 0.43),
            ScreenshotTextLine("Reference ID", x: 0.16, y: 0.52),
            ScreenshotTextLine("2609254EE1B9A7U", x: 0.16, y: 0.57),
            ScreenshotTextLine("Transaction type", x: 0.16, y: 0.64),
            ScreenshotTextLine("DuitNow QR", x: 0.16, y: 0.69),
            ScreenshotTextLine("Category: Food & Drink", x: 0.16, y: 0.76),
            ScreenshotTextLine("Recipient reference", x: 0.16, y: 0.83),
            ScreenshotTextLine("Transfer", x: 0.16, y: 0.88)]
        let value = ScreenshotInterpreter().interpret(observations, capturedAt: captured, timeZone: zone)
        #expect(value.detection == .payment && value.statusClean)
        #expect(value.amountMinor == 1_135 && value.amountTrust == .trusted)
        #expect(value.merchant == "NORTHWIND RESTAURANT" && value.merchantTrust == .usable)
        #expect(value.reference == "2609254EE1B9A7U")
        #expect(value.occurredAt?.seconds == Instant(iso: "2026-09-25T06:44:00+00:00")?.seconds)
        #expect(value.dateTrust == .usable) // Displayed transaction was two days before capture.
        let request = ScreenshotCaptureAdapter().adapt((value, "duitnow-image"), capturedAt: captured, timeZone: zone)
        #expect(request.occurredAt == value.occurredAt && request.capturedAt == captured)
        #expect(request.categoryID == nil && request.categoryTrust == .unresolved)
    }

    @Test func splitReferenceBoxesAndDateLinesUseLayout() {
        let observations = [
            ScreenshotTextLine("Completed", y: 0.05),
            ScreenshotTextLine("RM 11.35", y: 0.12),
            ScreenshotTextLine("To", x: 0.10, y: 0.20, width: 0.1),
            ScreenshotTextLine("NORTHWIND RESTAURANT", x: 0.28, y: 0.20, width: 0.3),
            ScreenshotTextLine("25 Sep 2026", y: 0.30),
            ScreenshotTextLine("2:44 PM", y: 0.35),
            ScreenshotTextLine("Reference ID", x: 0.10, y: 0.45),
            ScreenshotTextLine("2609254EE1B9A7U", x: 0.48, y: 0.45),
            ScreenshotTextLine("Transaction type", y: 0.55),
            ScreenshotTextLine("DuitNow QR", y: 0.60)]
        let value = ScreenshotInterpreter().interpret(observations, capturedAt: captured, timeZone: zone)
        #expect(value.merchant == "NORTHWIND RESTAURANT")
        #expect(value.reference == "2609254EE1B9A7U")
        #expect(value.occurredAt?.seconds == Instant(iso: "2026-09-25T06:44:00+00:00")?.seconds)
    }

    @Test func unanchoredToAndReferenceWordsAreNotPayeeOrReference() {
        let value = parse(["Payment completed", "RM 11.35", "How to transfer money",
                           "Recipient reference", "Transfer", "Reference ID", "Category Food & Drink"])
        #expect(value.detection == .payment)
        #expect(value.merchant == nil && value.reference == nil)
    }
}
