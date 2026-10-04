import Foundation
import Testing
@testable import PaceCore

@Suite("G3 independent field extraction") struct ScreenshotG3Tests {
    private let capture = Instant(iso: G0Corpus.capture)!
    private func fields(_ lines: [ScreenshotTextLine], capturedAt: Instant? = nil) -> ScreenshotFieldReport {
        ScreenshotFieldExtraction(capturedAt: capturedAt ?? capture, timeZone: G0Corpus.zone).extractFields(lines)
    }
    private func fields(_ screen: G0Screen) -> ScreenshotFieldReport {
        ScreenshotFieldExtraction(capturedAt: Instant(iso: screen.capturedAt)!, timeZone: screen.timeZone)
            .extractFields(screen.lines)
    }
    private func expectedReference(_ screen: G0Screen) -> String? {
        guard let raw = screen.truth.reference else { return nil }
        let relations = ScreenshotRelations(ScreenshotSpans(ScreenshotLayout(screen.lines),
            capturedAt: Instant(iso: screen.capturedAt)!, timeZone: screen.timeZone))
        if relations.of(.referencePrimary).isEmpty && relations.of(.referenceSecondary).contains(where: { $0.valueText == raw }) {
            return "approval:" + raw
        }
        return raw
    }
    private func snapshot(_ report: ScreenshotFieldReport) -> String {
        [report.amountMinor.map(String.init) ?? "-", report.merchant ?? "-",
         report.occurredAt.map { String($0.seconds) } ?? "-", report.referenceText ?? "-"].joined(separator: "|")
    }
    private func rows(_ texts: [String]) -> [ScreenshotTextLine] {
        texts.enumerated().map { i, text in ScreenshotTextLine(text, confidence: 0.98, x: 0.1,
            y: 0.08 + Double(i) * 0.09, width: 0.7, height: 0.035) }
    }
    private func copied(_ line: ScreenshotTextLine, text: String? = nil, x: Double? = nil,
                        y: Double? = nil, width: Double? = nil, height: Double? = nil) -> ScreenshotTextLine {
        ScreenshotTextLine(text ?? line.text, confidence: line.confidence,
                           x: x ?? line.x, y: y ?? line.y, width: width ?? line.width,
                           height: height ?? line.height, pass: line.pass, alternates: line.alternates)
    }
    @Test func generatedFieldGatesAndScoreboard() {
        let screens = G0Corpus.generated().filter { G0Corpus.archetypes.contains($0.kind) }
        for split in ["dev", "holdout"] {
            let subset = screens.filter { $0.split == split }
            var hits = [0,0,0,0], missing = [0,0,0,0], wrong = [0,0,0,0], wrongTrusted = 0
            var labelled = 0, labelledHits = 0, titleTrusted = 0
            for screen in subset {
                let result = fields(screen)
                let actual: [String?] = [result.amountMinor.map(String.init), result.merchant,
                    result.occurredAt.map { String($0.seconds) }, result.referenceText]
                let expectedReference = expectedReference(screen)
                let expected: [String?] = [screen.truth.amountMinor.map(String.init), screen.truth.merchant,
                    screen.truth.occurredAt.flatMap { Instant(iso: $0).map { String($0.seconds) } }, expectedReference]
                for i in 0..<4 {
                    if actual[i] == expected[i] { hits[i] += 1 }
                    else if actual[i] == nil { missing[i] += 1 }
                    else { wrong[i] += 1 }
                }
                if result.amountMinor != screen.truth.amountMinor && result.amountTrust == .trusted { wrongTrusted += 1 }
                let relations = ScreenshotRelations(ScreenshotSpans(ScreenshotLayout(screen.lines),
                    capturedAt: Instant(iso: screen.capturedAt)!, timeZone: screen.timeZone))
                if !relations.of(.counterparty).isEmpty {
                    labelled += 1
                    if result.merchant == screen.truth.merchant { labelledHits += 1 }
                    #expect(result.merchant == screen.truth.merchant, "\(screen.id) labelled merchant")
                }
                if result.counterparty.selected?.source == "header title" && result.merchantTrust == .trusted { titleTrusted += 1 }
                #expect(result.amountMinor == nil || result.amountMinor == screen.truth.amountMinor || result.amountTrust != .trusted)
                #expect(result.referenceText == nil || result.referenceText == expectedReference)
            }
            print("G3 \(split) \(subset.count) amount \(hits[0])/\(missing[0])/\(wrong[0]) merchant \(hits[1])/\(missing[1])/\(wrong[1]) date \(hits[2])/\(missing[2])/\(wrong[2]) reference \(hits[3])/\(missing[3])/\(wrong[3]); labelled \(labelledHits)/\(labelled), wrong trusted amount \(wrongTrusted), trusted titles \(titleTrusted)")
            if split == "holdout" {
                #expect(Double(hits[0]) / Double(subset.count) >= 0.95)
                #expect(wrongTrusted == 0)
                #expect(Double(labelledHits) / Double(labelled) >= 0.95 && wrong[1] == 0)
                #expect(Double(hits[2]) / Double(subset.count) >= 0.95)
                #expect(wrong[3] == 0)
                #expect(titleTrusted == 0)
            }
        }
    }
    @Test func blindFieldExpectationsAndNegativeGuards() throws {
        let blind = try G0Corpus.fixtures().filter { $0.split == "blind" }
        var hits = [0,0,0,0], misses = [0,0,0,0]
        for screen in blind where screen.truth.payment {
            let result = fields(screen)
            let actual: [String?] = [result.amountMinor.map(String.init), result.merchant,
                result.occurredAt.map { String($0.seconds) }, result.referenceText]
            let expectedReference = expectedReference(screen)
            let expected: [String?] = [screen.truth.amountMinor.map(String.init), screen.truth.merchant,
                screen.truth.occurredAt.flatMap { Instant(iso: $0).map { String($0.seconds) } }, expectedReference]
            for i in 0..<4 {
                if actual[i] == expected[i] { hits[i] += 1 } else { misses[i] += 1 }
            }
            #expect(result.amountMinor == screen.truth.amountMinor, "\(screen.id) amount")
            #expect(result.merchant == screen.truth.merchant, "\(screen.id) merchant: \(result.merchant ?? "-")")
            #expect(result.occurredAt?.seconds == screen.truth.occurredAt.flatMap { Instant(iso: $0)?.seconds }, "\(screen.id) date")
            #expect(result.referenceText == expectedReference, "\(screen.id) reference")
        }
        print("G3 blind positive fields (truth) correct/missing: amount \(hits[0])/\(misses[0]), merchant \(hits[1])/\(misses[1]), date \(hits[2])/\(misses[2]), reference \(hits[3])/\(misses[3])")
        for screen in blind where !screen.truth.payment {
            let report = fields(screen)
            #expect(report.referenceText == nil, "\(screen.id) negative reference")
            #expect(report.merchant == nil, "\(screen.id) negative merchant")
        }
    }
    @Test func metamorphicFieldInvariance() {
        let positives = G0Corpus.generated().filter { G0Corpus.archetypes.contains($0.kind) }
        var checks = 0, failures: [String] = []
        for screen in positives {
            let base = fields(screen), lines = screen.lines
            let variants: [[ScreenshotTextLine]] = [
                Array(lines.reversed()),
                lines.map { copied($0, x: min(0.98, $0.x + 0.02), y: min(0.98, $0.y + 0.02)) },
                lines.map { copied($0, width: $0.width * 0.8, height: $0.height * 0.8) },
                lines + [ScreenshotTextLine("Help", x: 0.05, y: 0.94, width: 0.18),
                         ScreenshotTextLine("9:41", x: 0.02, y: 0.005, width: 0.10)]
            ]
            for (index, variant) in variants.enumerated() {
                let actual = snapshot(fields(variant))
                if actual != snapshot(base) { failures.append("\(screen.id) variant \(index): \(actual) != \(snapshot(base))") }
                checks += 1
            }
            let renamed = lines.map { copied($0, text: $0.text.replacingOccurrences(of: screen.truth.merchant!, with: "NOVA TERRA WORKS")) }
            let changed = fields(renamed)
            if changed.amountMinor != base.amountMinor || changed.occurredAt?.seconds != base.occurredAt?.seconds || changed.referenceText != base.referenceText || changed.merchant != "NOVA TERRA WORKS" {
                failures.append("\(screen.id) rename: \(snapshot(changed)) != expected NOVA TERRA WORKS")
            }
            checks += 1
        }
        print("G3 metamorphic invariance: \(checks-failures.count)/\(checks); first failures \(failures.prefix(20))")
        #expect(failures.isEmpty)
    }
    @Test func splitAndMergedBoxesPreserveFields() {
        let original = [ScreenshotTextLine("Payment successful", x: 0.20, y: 0.08),
                        ScreenshotTextLine("RM 42.00", x: 0.36, y: 0.20, width: 0.30, height: 0.07),
                        ScreenshotTextLine("Paid to", x: 0.08, y: 0.36, width: 0.20),
                        ScreenshotTextLine("NORTH QUAY BOOKS", x: 0.43, y: 0.36, width: 0.45),
                        ScreenshotTextLine("Date", x: 0.08, y: 0.51, width: 0.20),
                        ScreenshotTextLine("27 Sep 2026 14:05", x: 0.43, y: 0.51, width: 0.45),
                        ScreenshotTextLine("Reference", x: 0.08, y: 0.67, width: 0.20),
                        ScreenshotTextLine("QX742661", x: 0.43, y: 0.67, width: 0.30)]
        let base = fields(original)
        let split = [original[0], ScreenshotTextLine("RM", x: 0.36, y: 0.20, width: 0.08, height: 0.07),
                     ScreenshotTextLine("42.00", x: 0.46, y: 0.20, width: 0.18, height: 0.07)] + Array(original.dropFirst(2))
        let merged = [original[0], original[1], ScreenshotTextLine("Paid to NORTH QUAY BOOKS", x: 0.08, y: 0.36, width: 0.80),
                      original[4], original[5], ScreenshotTextLine("Reference QX742661", x: 0.08, y: 0.67, width: 0.70)]
        #expect(snapshot(fields(split)) == snapshot(base))
        #expect(snapshot(fields(merged)) == snapshot(base))
    }
    @Test func independentGeneratorsAndAdversarialEvidence() {
        let fixture = rows(["Payment successful", "Amount RM 42.00", "Merchant Name ORCHID BOOKS",
                            "Transaction Date 27/09/2026 14:05", "Transaction ID QX742661"])
        let base = fields(fixture)
        #expect(base.amountMinor == 4200 && base.merchant == "ORCHID BOOKS")
        #expect(base.referenceText == "QX742661" && base.occurredAt != nil)
        for removed in 1...4 {
            var without = fixture; without.remove(at: removed)
            let result = fields(without)
            if removed != 1 { #expect(result.amountMinor == base.amountMinor) }
            if removed != 2 { #expect(result.merchant == base.merchant) }
            if removed != 3 { #expect(result.occurredAt?.seconds == base.occurredAt?.seconds) }
            if removed != 4 { #expect(result.referenceText == base.referenceText) }
        }
        let competing = fields(rows(["Payment successful", "RM 42.00", "Total RM 42.00", "Balance RM 900.00",
                                     "Merchant Name ORCHID BOOKS", "Transaction ID QX742661",
                                     "Approval Code 551203", "Merchant ID 84261938", "Terminal ID 63120945",
                                     "Card **** 9012", "Due Date 30/09/2026 14:05", "Transaction Date 27/09/2026 14:05"]))
        #expect(competing.amountMinor == 4200)
        #expect(competing.amount.candidates.contains { $0.rejected?.contains("excluded amount label") == true })
        #expect(competing.merchant == "ORCHID BOOKS")
        #expect(competing.referenceText == "QX742661")
        #expect(competing.reference.candidates.contains { $0.value == "84261938" && $0.rejected != nil })
        #expect(competing.reference.candidates.contains { $0.value == "63120945" && $0.rejected != nil })
        #expect(competing.date.candidates.contains { $0.rejected?.contains("other date label") == true }, "\(competing.date.candidates.map { ($0.value,$0.rejected ?? "ok") })")
        let conflict = fields(rows(["Transaction ID QX742661", "Reference No AB739201", "RM 42.00"]))
        #expect(conflict.referenceText == nil && conflict.reference.unresolved)
        let unknown = fields(rows(["Payment completed", "RM 42.00", "AB739201", "Card **** 9012"]))
        #expect(unknown.referenceText == nil)
        #expect(unknown.reference.candidates.contains { $0.value == "AB739201" && $0.rejected == "unlabelled identifier" })
        let bareID = fields(rows(["Transaction successful", "RM 42.00", "ID ZX746820", "27/09/2026 14:05"]))
        #expect(bareID.referenceText == nil)
        #expect(bareID.reference.candidates.contains { $0.value == "ZX746820" && $0.rejected?.contains("excluded identifier label") == true })
        let unreadable = fields(rows(["Payment completed", "RM 42.00", "Transaction Date 27/19/2026 14:05"]))
        #expect(unreadable.occurredAt == nil && unreadable.dateTrust == .unresolved)
        let context = fields(rows(["Payment completed", "Balance RM 950.00", "Fee RM 4.00",
                                   "Cashback RM 2.00", "Credit limit RM 5,000.00", "Card **** 9012", "From account **** 3812",
                                   "Transaction type Card purchase", "Category Books", "Memo Thank you",
                                   "Reference AB739201", "9:41"]))
        #expect(context.amountMinor == nil)
        #expect(context.merchant == nil)
        #expect(context.referenceText == "AB739201")
        #expect(context.occurredAt == nil)
        #expect(context.dateTrust == .trusted)
        let alternative = fields([ScreenshotTextLine("Total", x: 0.08, y: 0.20, width: 0.20),
                                  ScreenshotTextLine("RM 18.60", x: 0.5, y: 0.20, width: 0.30,
                                                     alternates: ["RM 18.60", "RM 19.60"])])
        #expect(alternative.amountMinor == nil && alternative.amount.unresolved)
        #expect(alternative.amount.candidates.contains { $0.value == "RM 19.60" && $0.features.contains("alternate reading") })
        let dateOnly = fields(rows(["Transaction Date 28/09/2026", "Amount RM 42.00"]))
        #expect(dateOnly.occurredAt?.seconds == capture.seconds && dateOnly.dateTrust == .trusted)
        let morning = Instant(iso: "2026-09-27T23:00:00Z")!
        let morningDate = fields(rows(["Transaction Date 28/09/2026", "Amount RM 42.00"]), capturedAt: morning)
        #expect(morningDate.occurredAt?.seconds == morning.seconds && morningDate.dateTrust == .trusted)
        let priorDate = fields(rows(["Transaction Date 27/09/2026", "Amount RM 42.00"]))
        #expect(priorDate.occurredAt == nil && priorDate.dateTrust == .unresolved)
    }
    @Test func physicalFixturesAreHeldOutRegressionEvidence() throws {
        let screens = try G0Corpus.fixtures().filter { $0.split == "physical-holdout" }
        var hits = [0,0,0,0]
        for screen in screens {
            let result = fields(screen)
            if result.amountMinor == screen.truth.amountMinor { hits[0] += 1 }
            if result.merchant == screen.truth.merchant { hits[1] += 1 }
            if result.occurredAt?.seconds == screen.truth.occurredAt.flatMap({ Instant(iso: $0)?.seconds }) { hits[2] += 1 }
            if result.referenceText == screen.truth.reference { hits[3] += 1 }
        }
        print("G3 physical synthetic held-out: \(screens.count) screens, amount \(hits[0]), merchant \(hits[1]), date \(hits[2]), reference \(hits[3])")
    }
    @Test func legacyGateAndSnapshotDiff() throws {
        let screens = G0Corpus.generated() + (try G0Corpus.fixtures())
        var accepted = 0, rejected = 0, changed = 0, forbidden = 0
        var bySplit: [String: Int] = [:]
        for screen in screens {
            let at = Instant(iso: screen.capturedAt)!
            let old = LegacyScreenshotInterpreter().interpret(screen.lines, capturedAt: at, timeZone: screen.timeZone)
            let new = ScreenshotInterpreter().interpret(screen.lines, capturedAt: at, timeZone: screen.timeZone)
            #expect(old.detection == new.detection, "\(screen.id) classification changed at G3")
            if old.detection == .payment { accepted += 1 } else { rejected += 1 }
            let oldFields = [old.amountMinor.map(String.init) ?? "-", old.merchant ?? "-", old.occurredAt?.isoUTC ?? "-", old.reference ?? "-"]
            let newFields = [new.amountMinor.map(String.init) ?? "-", new.merchant ?? "-", new.occurredAt?.isoUTC ?? "-", new.reference ?? "-"]
            if oldFields != newFields {
                changed += 1; bySplit[screen.split, default: 0] += 1
                if old.detection != .payment { forbidden += 1 }
            }
        }
        print("G3 legacy snapshot diff: \(changed)/\(screens.count) field reports changed; legacy gate accepted \(accepted), rejected \(rejected); by split \(bySplit); rejected changed \(forbidden)")
        #expect(forbidden == 0)
    }
}
