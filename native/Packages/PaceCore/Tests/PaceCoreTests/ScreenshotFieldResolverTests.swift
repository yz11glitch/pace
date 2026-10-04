import Foundation
import Testing
@testable import PaceCore

@Suite("Step 1 screenshot field resolution") struct ScreenshotFieldResolverTests {
    let zone = "Asia/Kuala_Lumpur"
    let capture = Instant(iso: "2026-09-29T12:00:00+08:00")!

    func rows(_ texts: [String], hero: Int? = nil, confidence: Double = 0.98) -> [ScreenshotTextLine] {
        texts.enumerated().map { index, text in
            ScreenshotTextLine(text, confidence: confidence, x: index == hero ? 0.3 : 0.1,
                y: 0.08 + Double(index) * 0.075, width: index == hero ? 0.4 : 0.7,
                height: index == hero ? 0.07 : 0.035)
        }
    }
    func resolve(_ lines: [ScreenshotTextLine]) -> ScreenshotFieldResolution {
        ScreenshotFieldResolver().resolve(lines, capturedAt: capture, timeZone: zone)
    }
    func request(_ lines: [ScreenshotTextLine]) -> CaptureRequest {
        ScreenshotIntentionalCapture.request(lines: lines, resolution: resolve(lines), imageHash: "fixture",
            capturedAt: capture, timeZone: zone)
    }

    @Test func rytReconstructionRM53() {
        // Text was pasted from the capture; geometry is an explicit reconstruction.
        let lines = rows(["-RM 53.00", "To RESTORAN CONTOH", "28 Sep 2026, 2:20 PM", "Completed",
                          "Ryt Credit", "Reference ID", "260928B42BD813R", "DuitNow QR", "Food & Drink"], hero: 0)
        let result = resolve(lines), input = request(lines)
        #expect(result.amount.kind == .decisive && result.amount.value?.minorUnits == 5300)
        #expect(result.merchant.kind == .decisive && result.merchant.value == "RESTORAN CONTOH")
        #expect(result.date.occurredAt?.isoUTC == Instant(iso: "2026-09-28T14:20:00+08:00")?.isoUTC)
        #expect(input.amountTrust == .trusted && input.merchantTrust == .usable)
        #expect(result.reference.kind == .decisive && input.reference == "260928B42BD813R")
        #expect(input.path == "screenshot_intentional_fm")
        #expect(resolve(lines.filter { $0.text != "Reference ID" }).reference.value == nil)
    }

    @Test func rytReconstructionRM20KeepsOldDateDiagnosticOnly() {
        let lines = rows(["-RM 20.00", "To CONTOH BARBER SHOP", "8 Sep 2026, 3:35 PM", "Completed",
                          "Ryt Credit", "Reference ID", "26090892F2FF7J0", "DuitNow QR", "Wellness"], hero: 0)
        let result = resolve(lines), input = request(lines)
        #expect(result.amount.kind == .decisive && result.amount.value?.minorUnits == 2000)
        #expect(result.merchant.kind == .decisive && result.merchant.value == "CONTOH BARBER SHOP")
        #expect(result.date.trust == .unresolved)
        #expect(result.date.occurredAt?.isoUTC == Instant(iso: "2026-09-08T15:35:00+08:00")?.isoUTC)
        #expect(input.dateTrust == .trusted && input.occurredAt == capture)
        #expect(result.reference.kind == .decisive && input.reference == "26090892F2FF7J0")
        #expect(resolve(lines.filter { $0.text != "Reference ID" }).reference.value == nil)
    }

    @Test func exclusionsAndDistinctValues() {
        let decisive = [
            ["Payment successful", "-RM 20.00", "Balance RM 200.00", "To NORTH QUAY BOOKS"],
            ["Payment successful", "-RM 20.00", "Baki RM 200.00", "To NORTH QUAY BOOKS"],
            ["Paid RM 20.00", "You saved RM 5.00", "Cashback RM 3.00", "To NORTH QUAY BOOKS"],
            ["Payment successful", "-RM 20.00", "Discount RM 5.00", "To NORTH QUAY BOOKS"],
            ["Payment successful", "-RM 20.00", "Amount RM 20.00", "Tip RM 2.00", "To NORTH QUAY BOOKS"],
            ["You paid RM 20.00 at NORTH QUAY BOOKS"]
        ]
        for text in decisive {
            let result = resolve(rows(text, hero: text.contains("-RM 20.00") ? 1 : nil))
            #expect(result.amount.kind == .decisive, "\(text): \(result.amount.rule)")
            #expect(result.amount.value?.minorUnits == 2000)
        }
        let ambiguous = [
            ["Payment successful", "Subtotal RM 18.00", "Service fee RM 2.00", "Total RM 20.00", "To NORTH QUAY BOOKS"],
            ["Transfer amount RM 20.00", "Service charge RM 0.50", "Total debited RM 20.50", "To NORTH QUAY BOOKS"],
            ["RM 18.00", "Total RM 20.00", "To NORTH QUAY BOOKS"],
            ["-RM 18.00", "-RM 20.00", "To NORTH QUAY BOOKS"],
            ["Price RM 25.00", "Voucher -RM 5.00", "Total RM 20.00", "To NORTH QUAY BOOKS"]
        ]
        for text in ambiguous {
            let result = resolve(rows(text, hero: 0))
            #expect(result.amount.kind == .ambiguous, "\(text): \(result.amount.rule)")
            #expect(result.amount.chooserOffer.count >= 2)
            #expect(request(rows(text, hero: 0)).amountTrust == .unresolved)
        }
    }

    @Test func weakIncomingForeignAndOCR() {
        let incoming = rows(["Refund successful", "+RM 20.00", "From NORTH QUAY BOOKS"], hero: 1)
        #expect(resolve(incoming).amount.kind == .weak)
        #expect(resolve(incoming).amount.value?.incoming == true)
        #expect(request(incoming).amountTrust == .unresolved)
        for cue in ["refund", "refunded", "received", "credited", "reversal"] {
            let screen = rows(["\(cue) successful", "-RM 20.00", "From NORTH QUAY BOOKS"], hero: 1)
            #expect(resolve(screen).amount.kind == .weak, "\(cue) must not become an expense")
            #expect(request(screen).amountTrust == .unresolved)
        }
        let onlyPlus = rows(["+RM 20.00", "To NORTH QUAY BOOKS"], hero: 0)
        #expect(resolve(onlyPlus).amount.kind == .weak)
        let foreign = rows(["USD 12.99", "To NORTH QUAY BOOKS"], hero: 0)
        #expect(resolve(foreign).amount.kind == .weak)
        #expect(request(foreign).amountMinor == nil)
        let equivalent = rows(["USD 12.99", "RM 55.20", "To NORTH QUAY BOOKS"], hero: 0)
        #expect(resolve(equivalent).amount.kind == .ambiguous)
        let bare = rows(["20.00", "To NORTH QUAY BOOKS"], hero: 0)
        #expect(resolve(bare).amount.kind != .decisive)
        let low = rows(["-RM 20.00", "To NORTH QUAY BOOKS"], hero: 0, confidence: 0.6)
        #expect(resolve(low).amount.kind == .weak)
        let confusable = rows(["-RM 2O.OO", "To NORTH QUAY BOOKS"], hero: 0)
        #expect(resolve(confusable).amount.kind != .decisive)
        let spaced = rows(["-RM 2 0.00", "To NORTH QUAY BOOKS"], hero: 0)
        #expect(resolve(spaced).amount.kind != .decisive)
        let stacked = [ScreenshotTextLine("RM", x: 0.3, y: 0.1, width: 0.2),
                       ScreenshotTextLine("20.00", x: 0.3, y: 0.2, width: 0.2)]
        #expect(resolve(stacked).amount.kind != .decisive)
        #expect(resolve(rows(["Share", "Help"])).noTransactionEvidence)
    }

    @Test func merchantContinuationAndReferences() {
        let processor = [ScreenshotTextLine("Payment to", x: 0.05, y: 0.15, width: 0.20),
                         ScreenshotTextLine("GrabPay", x: 0.45, y: 0.15, width: 0.35),
                         ScreenshotTextLine("Merchant", x: 0.05, y: 0.22, width: 0.20),
                         ScreenshotTextLine("KEDAI ABC", x: 0.45, y: 0.22, width: 0.35),
                         ScreenshotTextLine("-RM 20.00", x: 0.3, y: 0.06, width: 0.4, height: 0.07)]
        let merchant = resolve(processor).merchant
        #expect(merchant.kind == .ambiguous)
        #expect(!merchant.candidates.contains { $0.value == "GrabPay KEDAI ABC" })
        let recipient = [ScreenshotTextLine("Recipient", x: 0.05, y: 0.15, width: 0.20),
                         ScreenshotTextLine("ALI BIN ABU", x: 0.45, y: 0.15, width: 0.35),
                         ScreenshotTextLine("Recipient bank", x: 0.05, y: 0.22, width: 0.20),
                         ScreenshotTextLine("CIMB Bank", x: 0.45, y: 0.22, width: 0.35)]
        #expect(resolve(recipient).merchant.value == "ALI BIN ABU")
        let title = resolve(rows(["NORTH QUAY BOOKS", "Paid RM 20.00", "Completed"], hero: 0))
        #expect(title.merchant.kind == .ambiguous)
        let labelled = resolve(rows(["Payment successful", "-RM 20.00", "To NORTH QUAY BOOKS",
                                     "Transaction ID QX742661", "Merchant ID 84261938", "Terminal ID 63120945"]))
        #expect(labelled.reference.value == "QX742661")
        #expect(labelled.reference.candidates.contains { $0.value == "84261938" && $0.rejected != nil })
        #expect(resolve(rows(["-RM 20.00", "To NORTH QUAY BOOKS", "QX742661"])).reference.value == nil)
    }

    @Test func dateRulesAndOrderInvariance() {
        let oldDate = rows(["-RM 20.00", "To NORTH QUAY BOOKS", "8 Sep 2026, 3:35 PM"], hero: 0)
        let base = resolve(oldDate)
        #expect(base.date.occurredAt?.isoUTC == Instant(iso: "2026-09-08T15:35:00+08:00")?.isoUTC)
        #expect(base.date.trust == .unresolved)
        let dateOnly = resolve(rows(["-RM 20.00", "To NORTH QUAY BOOKS", "8 Sep 2026"], hero: 0))
        #expect(dateOnly.date.occurredAt?.isoUTC == Instant(iso: "2026-09-08T12:00:00+08:00")?.isoUTC)
        let noDate = resolve(rows(["-RM 20.00", "To NORTH QUAY BOOKS"], hero: 0))
        #expect(noDate.date.kind == .missing && noDate.date.occurredAt == capture)
        let recent = resolve(rows(["-RM 20.00", "To NORTH QUAY BOOKS", "27 Sep 2026, 3:35 PM"], hero: 0))
        #expect(recent.date.trust == .usable)
        #expect(recent.date.occurredAt?.isoUTC == Instant(iso: "2026-09-27T15:35:00+08:00")?.isoUTC)
        let today = resolve(rows(["-RM 20.00", "To NORTH QUAY BOOKS", "29 Sep 2026"], hero: 0))
        #expect(today.date.trust == .trusted && today.date.occurredAt == capture)
        let future = resolve(rows(["-RM 20.00", "To NORTH QUAY BOOKS", "9 Oct 2026"], hero: 0))
        #expect(future.date.trust == .unresolved && future.date.occurredAt == nil)
        let unparseable = resolve(rows(["-RM 20.00", "To NORTH QUAY BOOKS", "29/19/2026"], hero: 0))
        #expect(unparseable.date.trust == .unresolved && unparseable.date.occurredAt == nil)
        let conflicting = resolve(rows(["-RM 20.00", "To NORTH QUAY BOOKS",
            "Transaction date 27 Sep 2026, 3:35 PM", "Transaction date 28 Sep 2026, 3:35 PM"], hero: 0))
        #expect(conflicting.date.kind == .ambiguous && conflicting.date.trust == .unresolved)
        let reversed = resolve(Array(oldDate.reversed()))
        #expect(reversed.amount.kind == base.amount.kind && reversed.amount.value == base.amount.value)
        #expect(reversed.merchant.kind == base.merchant.kind && reversed.merchant.value == base.merchant.value)
        #expect(reversed.date.occurredAt == base.date.occurredAt)
    }

    @Test func scenarioMetamorphicInvariance() {
        let cases = [
            rows(["-RM 53.00", "To NORTH QUAY BOOKS", "28 Sep 2026, 2:20 PM", "Completed"], hero: 0),
            rows(["Payment successful", "Subtotal RM 18.00", "Service fee RM 2.00",
                  "Total RM 20.00", "To NORTH QUAY BOOKS"]),
            rows(["Refund successful", "+RM 20.00", "From NORTH QUAY BOOKS"], hero: 1)
        ]
        func copy(_ line: ScreenshotTextLine, x: Double? = nil, y: Double? = nil,
                  width: Double? = nil, height: Double? = nil) -> ScreenshotTextLine {
            ScreenshotTextLine(line.text, confidence: line.confidence, x: x ?? line.x, y: y ?? line.y,
                width: width ?? line.width, height: height ?? line.height,
                pass: line.pass, alternates: line.alternates)
        }
        for lines in cases {
            let base = resolve(lines)
            let variants = [
                Array(lines.reversed()),
                lines.map { copy($0, x: min(0.98, $0.x + 0.02), y: min(0.98, $0.y + 0.02)) },
                lines.map { copy($0, width: $0.width * 0.85, height: $0.height * 0.85) },
                lines + [ScreenshotTextLine("Help", x: 0.05, y: 0.94, width: 0.2)]
            ]
            for variant in variants {
                let actual = resolve(variant)
                #expect(actual.amount.kind == base.amount.kind && actual.amount.value == base.amount.value)
                #expect(actual.merchant.kind == base.merchant.kind && actual.merchant.value == base.merchant.value)
                #expect(actual.date.kind == base.date.kind && actual.date.occurredAt == base.date.occurredAt)
                #expect(actual.reference.kind == base.reference.kind && actual.reference.value == base.reference.value)
            }
        }
    }

    @Test func traceIsCodableAndCandidateIDsAreStable() throws {
        let lines = rows(["Completed", "Subtotal RM 18.00", "Total RM 20.00",
            "To NORTH QUAY BOOKS", "Transaction ID QX742661"])
        let first = resolve(lines)
        let encoded = try JSONEncoder().encode(first)
        let decoded = try JSONDecoder().decode(ScreenshotFieldResolution.self, from: encoded)
        #expect(decoded.amount.kind == .ambiguous)
        #expect(decoded.amount.candidates.map(\.id) == first.amount.candidates.map(\.id))
        #expect(decoded.amount.candidates.map(\.tokenIDs) == first.amount.candidates.map(\.tokenIDs))
        #expect(decoded.reference.value == "QX742661")
        #expect(resolve(Array(lines.reversed())).amount.candidates.map(\.id) == first.amount.candidates.map(\.id))
    }

    @Test func g0PositiveAmountGate() {
        let screens = G0Corpus.generated().filter { G0Corpus.archetypes.contains($0.kind) }
        var moved = 0
        for screen in screens {
            let captured = Instant(iso: screen.capturedAt)!
            let g3 = ScreenshotFieldExtraction(capturedAt: captured, timeZone: screen.timeZone).extractFields(screen.lines)
            let result = ScreenshotFieldResolver().resolve(screen.lines, capturedAt: captured, timeZone: screen.timeZone)
            if g3.amountTrust == .trusted && g3.amountMinor == screen.truth.amountMinor {
                if result.amount.kind != .decisive { moved += 1 }
                #expect(result.amount.kind == .decisive, "\(screen.id): \(result.amount.rule)")
                #expect(result.amount.value?.minorUnits == screen.truth.amountMinor)
            }
            #expect(result.amount.kind != .decisive || result.amount.value?.minorUnits == screen.truth.amountMinor)
            #expect(result.merchant.kind != .decisive || result.merchant.value == screen.truth.merchant)
        }
        print("Step 1 G0 decisive to ambiguous/weak: \(moved) of \(screens.count)")
    }

    @Test func existingMaybankSyntheticMaterialRemainsGrounded() throws {
        let screen = try #require(G0Corpus.fixtures().first { $0.id == "historical-maybank-synthetic" })
        let captured = Instant(iso: screen.capturedAt)!
        let result = ScreenshotFieldResolver().resolve(screen.lines, capturedAt: captured, timeZone: screen.timeZone)
        #expect(result.amount.value?.minorUnits == 18591)
        #expect(result.amount.kind == .weak) // Uniform synthetic text has no D-A4 salience.
        #expect(result.merchant.kind == .decisive && result.merchant.value == screen.truth.merchant)
        #expect(result.reference.value == "approval:555012")
        #expect(result.reference.candidates.contains { $0.value == "99999998" && $0.rejected != nil })
        #expect(result.reference.candidates.contains { $0.value == "5550001234" && $0.rejected != nil })
    }
}
