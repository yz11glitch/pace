#if DEBUG
import Foundation
import Testing
@testable import PaceCore

@Suite("FM screenshot benchmark grounding") struct ScreenshotFMBenchmarkTests {
    private let captured = Instant(iso: "2026-09-28T00:00:00Z")!
    private let zone = "Asia/Kuala_Lumpur"

    private func lines(_ texts: [String]) -> [ScreenshotTextLine] {
        texts.enumerated().map { i, text in
            ScreenshotTextLine(text, confidence: 0.98, x: 0.12, y: 0.08 + Double(i)*0.1,
                               width: 0.7, height: 0.04)
        }
    }

    @Test func supportedClaimsAndUnsupportedFinancialFacts() {
        let ocr = lines(["Payment complete", "Amount RM 42.30", "Paid to NORTH QUAY STUDIO",
                         "Transaction Date 27/09/2026 14:05", "Transaction ID TX483026", "Card **** 3127"])
        let valid = ScreenshotFMGrounding.verify(.init(isTransaction: true, amountMinor: 4230,
            amountEvidence: "RM 42.30", currency: "MYR", merchant: "NORTH QUAY STUDIO",
            dateTimeEvidence: "27/09/2026 14:05", reference: "TX483026"),
            lines: ocr, capturedAt: captured, timeZone: zone)
        #expect(valid.amountMinor == 4230)
        #expect(valid.merchant == "NORTH QUAY STUDIO")
        #expect(valid.occurredAt == "2026-09-27T06:05:00+00:00")
        #expect(valid.reference == "TX483026")
        #expect(valid.rejected.isEmpty)

        let invented = ScreenshotFMGrounding.verify(.init(isTransaction: true, amountMinor: 9930,
            amountEvidence: "RM 42.30", merchant: "UNKNOWN SHOP",
            dateTimeEvidence: "26/09/2026 14:05", reference: "TX999999"),
            lines: ocr, capturedAt: captured, timeZone: zone)
        #expect(invented.amountMinor == nil)
        #expect(invented.merchant == nil)
        #expect(invented.occurredAt == nil)
        #expect(invented.reference == nil)
        #expect(invented.rejected.count == 4)
    }

    @Test func unknownAndMaskedIdentifiersNeverBecomeReferences() {
        let ocr = lines(["ID AP622190", "Card **** 3127", "Merchant ID MID8080", "Terminal ID TM3030"])
        for reference in ["AP622190", "3127", "MID8080", "TM3030"] {
            let result = ScreenshotFMGrounding.verify(.init(isTransaction: true, reference: reference),
                lines: ocr, capturedAt: captured, timeZone: zone)
            #expect(result.reference == nil)
            #expect(result.rejected["reference"] != nil)
        }
    }

    @Test func approvalIsSecondaryNotPrimary() {
        let ocr = lines(["Approval Code AP622190", "Card **** 3127"])
        let result = ScreenshotFMGrounding.verify(.init(isTransaction: true, reference: "AP622190"),
            lines: ocr, capturedAt: captured, timeZone: zone)
        #expect(result.reference == "approval:AP622190")
    }

    @Test func scoresSafetyErrorsSeparately() {
        let item = ScreenshotFMBenchmarkCase(id: "test", source: "unit", kind: "overview",
            capturedAt: captured.isoUTC, timeZone: zone, lines: [],
            expected: .init(isTransaction: false, amountMinor: nil, merchant: nil, occurredAt: nil, reference: nil))
        let verified = ScreenshotFMVerified(amountMinor: nil, merchant: nil, occurredAt: nil,
                                            reference: nil, rejected: ["amount": "unsupported"], evidence: [:])
        let g3 = ScreenshotFMG3Fields(amountMinor: nil, merchant: nil, occurredAt: nil, reference: nil,
                                      amountTrust: "missing", merchantTrust: "missing", dateTrust: "missing")
        let record = ScreenshotFMBenchmarkRecord(caseID: "test",
            claim: .init(isTransaction: true, certainty: "confident", amountMinor: 1000,
                         merchant: "INVENTED", dateTimeEvidence: "yesterday", reference: "Q999"),
            verified: verified, g3: g3, latencyMS: 200)
        let score = ScreenshotFMBenchmarkSummary(cases: [item], records: [record])
        #expect(score.classification.correct == 0)
        #expect(score.dangerousErrors["falsePositiveTransaction"] == 1)
        #expect(score.dangerousErrors["amount"] == 1)
        #expect(score.dangerousErrors["merchant"] == 1)
        #expect(score.dangerousErrors["date"] == 1)
        #expect(score.dangerousErrors["reference"] == 1)
        #expect(score.groundingFailures["amount"] == 1)
    }
}
#endif
