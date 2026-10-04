import Foundation
import Testing
@testable import PaceCore

@Suite("G2 labels and semantic relations") struct ScreenshotG2Tests {
    let captured=Instant(iso:"2026-09-28T08:00:00Z")!
    let zone="Asia/Kuala_Lumpur"
    func model(_ lines:[ScreenshotTextLine]) -> ScreenshotRelations {
        let layout=ScreenshotLayout(lines)
        return ScreenshotRelations(ScreenshotSpans(layout,capturedAt:captured,timeZone:zone))
    }
    func rows(_ text:[String]) -> [ScreenshotTextLine] {
        text.enumerated().map { i,t in ScreenshotTextLine(t,x:0.1,y:0.12+Double(i)*0.055,width:0.55,height:0.035) }
    }
    @Test(arguments:[
        ("Merchant Name",ScreenLabelConcept.counterparty), ("Paid to",.counterparty),
        ("Receiver Name",.counterparty),("Beneficiary Bank",.source),
        ("Reference",.referencePrimary),("Order No.",.referencePrimary),
        ("Txn Ref",.referencePrimary),("Invoice Number",.referencePrimary),
        ("Payment Ref",.referencePrimary),("No. Rujukan",.referencePrimary),
        ("Rujukan Transaksi",.referencePrimary),
        ("Auth No",.referenceSecondary),("Approval Code",.referenceSecondary),
        ("Customer ID",.nonTransactionIdentifier),("Merchant ID",.nonTransactionIdentifier),
        ("Recipient reference",.memo),("Amount paid",.amountTotal),
        ("Available Balance",.amountExcluded),("Due Date",.otherDate),
        ("Date & Time",.transactionDate),("Tarikh",.transactionDate),
        ("Payment successful",.statusPositive),("Payment pending",.statusNegative),
        ("Pay now",.prePayment),("Slide to pay",.prePayment),
        ("Bayar sekarang",.prePayment),("Payment details",.memo),
        ("Transaction type",.typeCategory),
        ("Share receipt",.chrome),("DuitNow QR",.rail)
    ]) func compositionalConcept(phrase:String,expected:ScreenLabelConcept) {
        #expect(ScreenshotLabels.concept(for:phrase) == expected)
        #expect(ScreenshotLabels.concept(for:phrase.uppercased()+":") == expected)
    }
    @Test func heldOutPhrasesAreComposedNotListed() throws {
        let path=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/PaceCore/ScreenshotLexicon.swift")
        let source=try String(contentsOf:path,encoding:.utf8).lowercased()
        for phrase in ["Order No.","Receiver Name","Txn Ref","Invoice Number","Beneficiary Bank",
                       "Due Date","Customer ID","Auth No","Payment Ref"] {
            #expect(!source.contains(phrase.lowercased()))
            #expect(ScreenshotLabels.concept(for:phrase) != nil)
        }
        for falseLabel in ["Orchid Books","Silver Fern Cafe","Flight Desk","Can you pay me","27 Sep 2026"] {
            #expect(ScreenshotLabels.concept(for:falseLabel) == nil)
        }
        #expect(ScreenshotLabels.concept(for:"referenceS") == .referencePrimary)
        #expect(ScreenshotLabels.concept(for:"service charges") == .amountExcluded)
    }
    @Test func inlineLongestPrefixAndTypedValue() {
        let r=model(rows(["Merchant ID 84261938","Merchant Name ORCHID BOOKS", "Payment Ref QX742661",
                          "Approval Code 551203", "Paid to SABLE STUDIO", "Total paid RM 23.90"]))
        #expect(r.of(.nonTransactionIdentifier).contains { $0.valueText == "84261938" && $0.relation == .inline })
        #expect(r.of(.counterparty).contains { $0.valueText == "ORCHID BOOKS" && $0.label.labelText == "Merchant Name" })
        #expect(r.of(.counterparty).contains { $0.valueText == "SABLE STUDIO" })
        #expect(r.of(.referencePrimary).contains { $0.valueText == "QX742661" })
        #expect(r.of(.referenceSecondary).contains { $0.valueText == "551203" })
        #expect(r.of(.amountTotal).contains { $0.valueSpan?.money?.minorUnits == 2390 })
        #expect(r.labels.first { $0.labelText == "Merchant ID" }?.inlineValue == "84261938")
    }
    @Test func rightBelowAboveAndVisualOrder() {
        let observations=[
            ScreenshotTextLine("Total",x:0.08,y:0.13,width:0.20,height:0.035),
            ScreenshotTextLine("RM 42.00",x:0.61,y:0.13,width:0.25,height:0.035),
            ScreenshotTextLine("Merchant",x:0.08,y:0.30,width:0.25,height:0.035),
            ScreenshotTextLine("MAPLE STUDIO",x:0.08,y:0.36,width:0.42,height:0.035),
            ScreenshotTextLine("RM 77.70",x:0.39,y:0.53,width:0.23,height:0.075),
            ScreenshotTextLine("Paid",x:0.40,y:0.62,width:0.21,height:0.03)]
        let a=model(observations), b=model(observations.reversed())
        #expect(a.pairs.map { "\($0.label.concept):\($0.valueText):\($0.relation)" } ==
                b.pairs.map { "\($0.label.concept):\($0.valueText):\($0.relation)" })
        #expect(a.of(.amountTotal).contains { $0.relation == .right && $0.geometryScore == 3 && $0.valueSpan?.money?.minorUnits == 4200 })
        #expect(a.of(.counterparty).contains { $0.relation == .below && $0.geometryScore == 2 && $0.valueText == "MAPLE STUDIO" })
        #expect(a.of(.amountTotal).contains { $0.relation == .above && $0.geometryScore == 1 && $0.valueSpan?.money?.minorUnits == 7770 })
    }
    @Test func inlinePriorityAndTypedDecoys() {
        let r=model([
            ScreenshotTextLine("Reference AB739201",x:0.08,y:0.12,width:0.45,height:0.04),
            ScreenshotTextLine("ZX991122",x:0.68,y:0.12,width:0.22,height:0.04),
            ScreenshotTextLine("Amount",x:0.08,y:0.28,width:0.22,height:0.04),
            ScreenshotTextLine("012-3456789",x:0.39,y:0.28,width:0.20,height:0.04),
            ScreenshotTextLine("RM 38.40",x:0.70,y:0.28,width:0.25,height:0.04),
            ScreenshotTextLine("Due Date",x:0.08,y:0.44,width:0.24,height:0.04),
            ScreenshotTextLine("30/10/2026 09:30",x:0.50,y:0.44,width:0.42,height:0.04),
            ScreenshotTextLine("at LANTERN CAFE",x:0.08,y:0.62,width:0.50,height:0.04)])
        #expect(r.of(.referencePrimary).count == 1)
        #expect(r.of(.referencePrimary)[0].valueText == "AB739201")
        #expect(r.of(.amountTotal).contains { $0.valueSpan?.money?.minorUnits == 3840 })
        #expect(r.of(.amountTotal).allSatisfy { !$0.valueText.contains("012") })
        #expect(r.of(.otherDate).contains { $0.valueKind == .dateTime })
        #expect(r.of(.counterparty).contains { $0.valueText == "LANTERN CAFE" })
    }
    @Test func masksCompetingIdentifiersAndNearestLabel() {
        let r=model([
            ScreenshotTextLine("Card",x:0.08,y:0.10,width:0.20),
            ScreenshotTextLine("**** **** 9012",x:0.56,y:0.10,width:0.30),
            ScreenshotTextLine("Merchant ID",x:0.08,y:0.22,width:0.28),
            ScreenshotTextLine("84261938",x:0.56,y:0.22,width:0.24),
            ScreenshotTextLine("Approval Code",x:0.08,y:0.34,width:0.27),
            ScreenshotTextLine("551203",x:0.56,y:0.34,width:0.20),
            ScreenshotTextLine("Transaction ID",x:0.08,y:0.46,width:0.29),
            ScreenshotTextLine("QX742661",x:0.56,y:0.46,width:0.25)])
        #expect(r.of(.source).contains { $0.valueKind == .cardMask })
        #expect(r.of(.nonTransactionIdentifier).contains { $0.valueText == "84261938" })
        #expect(r.of(.referenceSecondary).contains { $0.valueText == "551203" })
        #expect(r.of(.referencePrimary).contains { $0.valueText == "QX742661" })
        #expect(r.of(.referencePrimary).allSatisfy { !$0.valueText.contains("9012") && $0.valueText != "84261938" })
        #expect(r.pairs.flatMap(\.valueTokenIDs).count == Set(r.pairs.flatMap(\.valueTokenIDs)).count)
    }
    @Test func merchantNameThatBeginsWithLabelWordIsStillText() {
        let r=model([ScreenshotTextLine("Merchant",x:0.10,y:0.20,width:0.27,height:0.04),
                     ScreenshotTextLine("Payment House",x:0.53,y:0.20,width:0.35,height:0.04)])
        #expect(r.of(.counterparty).contains { $0.valueText == "Payment House" })
        #expect(!r.labels.contains { $0.labelText == "Payment" && $0.inlineValue == "House" })
    }
    @Test func merchantWrapStopsAtNextLabel() {
        let r=model([
            ScreenshotTextLine("Merchant Name",x:0.1,y:0.10,width:0.3,height:0.035),
            ScreenshotTextLine("NORTH QUAY",x:0.1,y:0.155,width:0.4,height:0.035),
            ScreenshotTextLine("TRAVEL SERVICES",x:0.1,y:0.205,width:0.4,height:0.035),
            ScreenshotTextLine("Reference",x:0.1,y:0.255,width:0.25,height:0.035),
            ScreenshotTextLine("AB739201",x:0.1,y:0.31,width:0.25,height:0.035)])
        #expect(r.of(.counterparty).contains { $0.valueText == "NORTH QUAY TRAVEL SERVICES" && $0.valueTokenIDs.count == 2 })
        #expect(r.of(.referencePrimary).contains { $0.valueText == "AB739201" })
        #expect(r.of(.counterparty).allSatisfy { !$0.valueText.contains("Reference") })
    }
    @Test func alternateOCRReadingsStayAsCompetingPairs() {
        let r=model([ScreenshotTextLine("Amount",x:0.08,y:0.20,width:0.25,height:0.04),
                     ScreenshotTextLine("RM 12.00",x:0.52,y:0.20,width:0.30,height:0.04,
                                        alternates:["RM 13.00","RM 13.00"])])
        let amounts=r.of(.amountTotal)
        #expect(Set(amounts.compactMap { $0.valueSpan?.money?.minorUnits }) == [1200,1300])
        #expect(amounts.contains { $0.valueSpan?.source == .alternate })
        #expect(amounts.allSatisfy { $0.valueTokenIDs.count == 1 && $0.labelObservations.count == 1 })
    }
    @Test func ambiguousAlternativesAndUnknownCaption() {
        let r=model([
            ScreenshotTextLine("Amount",x:0.08,y:0.20,width:0.25,height:0.04),
            ScreenshotTextLine("RM 12.00",x:0.45,y:0.20,width:0.20,height:0.04),
            ScreenshotTextLine("RM 13.00",x:0.72,y:0.20,width:0.20,height:0.04),
            ScreenshotTextLine("Mystery",x:0.08,y:0.40,width:0.25,height:0.04),
            ScreenshotTextLine("QX742661",x:0.52,y:0.40,width:0.22,height:0.04)])
        #expect(r.of(.amountTotal).count == 2)
        #expect(Set(r.of(.amountTotal).map(\.valueText)) == ["RM 12.00","RM 13.00"])
        #expect(r.of(.unknownLabel).contains { $0.valueText == "QX742661" })
        #expect(r.of(.referencePrimary).isEmpty)
    }
    @Test func nearestLabelAndNoiseDoNotCreateMerchant() {
        let r=model([
            ScreenshotTextLine("Reference",x:0.06,y:0.2,width:0.20,height:0.04),
            ScreenshotTextLine("Transaction ID",x:0.36,y:0.2,width:0.24,height:0.04),
            ScreenshotTextLine("AB742661",x:0.68,y:0.2,width:0.22,height:0.04),
            ScreenshotTextLine("Merchant",x:0.08,y:0.4,width:0.26,height:0.04),
            ScreenshotTextLine("Done",x:0.51,y:0.4,width:0.17,height:0.04),
            ScreenshotTextLine("RM 24.00",x:0.20,y:0.6,width:0.30,height:0.06)])
        #expect(r.of(.referencePrimary).count == 1)
        #expect(r.of(.referencePrimary)[0].label.labelText == "Transaction ID")
        #expect(r.of(.counterparty).isEmpty)
        #expect(r.of(.unknownLabel).allSatisfy { $0.valueText != "RM 24.00" })
    }
    @Test func orderShiftAndRenameInvariance() {
        let screens=G0Corpus.generated().filter { G0Corpus.archetypes.contains($0.kind) }
        for screen in screens {
            func signature(_ lines:[ScreenshotTextLine]) -> [String] {
                let r=ScreenshotRelations(ScreenshotSpans(ScreenshotLayout(lines),capturedAt:Instant(iso:screen.capturedAt)!,timeZone:screen.timeZone))
                return r.pairs.map { "\($0.label.concept)|\($0.valueText)|\($0.relation)" }.sorted()
            }
            let baseline=signature(screen.lines)
            #expect(baseline == signature(Array(screen.lines.reversed())))
            let dx=max(0,min(0.04,0.98-(screen.lines.map { $0.x+$0.width }.max() ?? 0)))
            let dy=max(0,min(0.04,0.98-(screen.lines.map { $0.y+$0.height }.max() ?? 0)))
            let shifted=screen.lines.map { l in ScreenshotTextLine(l.text,confidence:l.confidence,x:l.x+dx,y:l.y+dy,width:l.width,height:l.height,pass:l.pass,alternates:l.alternates) }
            let moved=signature(shifted)
            #expect(baseline == moved, "\(screen.id): \(baseline) versus \(moved)")
            let merchant=screen.truth.merchant!
            let renamed=screen.lines.map { l in ScreenshotTextLine(l.text.replacingOccurrences(of:merchant,with:"NOVA TERRA WORKS"),confidence:l.confidence,x:l.x,y:l.y,width:l.width,height:l.height,pass:l.pass,alternates:l.alternates) }
            let originalPairs=baseline.filter { $0.contains("counterparty|") }
            let renamedPairs=signature(renamed).filter { $0.contains("counterparty|") }
            #expect(originalPairs.count == renamedPairs.count)
            if !originalPairs.isEmpty { #expect(renamedPairs.contains { $0.contains("NOVA TERRA WORKS") }) }
        }
    }
    @Test func blindPairingScoreboard() throws {
        let blind=try G0Corpus.fixtures().filter { $0.split == "blind" && $0.truth.payment }
        var amount=0,merchant=0,date=0,reference=0
        for screen in blind {
            let r=ScreenshotRelations(ScreenshotSpans(ScreenshotLayout(screen.lines),capturedAt:Instant(iso:screen.capturedAt)!,timeZone:screen.timeZone))
            if r.of(.amountTotal).contains(where:{ $0.valueSpan?.money?.minorUnits == screen.truth.amountMinor.map(Int64.init) }) { amount += 1 }
            if r.of(.counterparty).contains(where:{ $0.valueText == screen.truth.merchant }) { merchant += 1 }
            if r.of(.transactionDate).contains(where:{ $0.valueSpan?.instant?.seconds == screen.truth.occurredAt.flatMap { Instant(iso:$0)?.seconds } }) { date += 1 }
            if r.of(.referencePrimary).contains(where:{ $0.valueText == screen.truth.reference }) { reference += 1 }
        }
        print("G2 blind explicit pairs: amount \(amount)/\(blind.count), counterparty \(merchant)/\(blind.count), date \(date)/\(blind.count), reference \(reference)/\(blind.count)")
        #expect(amount == 4)
        #expect(merchant == 9)
        #expect(date == 4)
        #expect(reference == 11)
        let eligible:[ScreenLabelConcept:Set<String>] = [
            .amountTotal:["B15","B16","P2","P6"],
            .counterparty:["B15","B18","B19","P1","P2","P3","P5","P6","P7"],
            .transactionDate:["B17","P1","P2","P7"],
            .referencePrimary:["B10","B11","B12","B13","B15","B16","B18","P1","P2","P4","P7"],
            .referenceSecondary:["P3"]]
        for screen in blind {
            let r=ScreenshotRelations(ScreenshotSpans(ScreenshotLayout(screen.lines),capturedAt:Instant(iso:screen.capturedAt)!,timeZone:screen.timeZone))
            for (concept,ids) in eligible where ids.contains(screen.id) {
                #expect(!r.of(concept).isEmpty,"\(screen.id) missing explicit \(concept) relation")
            }
        }
    }
    @Test func nonTransactionScreensDoNotInventCounterpartyOrReference() throws {
        let negatives=G0Corpus.generated().filter { !$0.truth.payment } +
            (try G0Corpus.fixtures().filter { ["N1","N2"].contains($0.id) })
        #expect(negatives.count == 202)
        for screen in negatives {
            let r=ScreenshotRelations(ScreenshotSpans(ScreenshotLayout(screen.lines),capturedAt:Instant(iso:screen.capturedAt)!,timeZone:screen.timeZone))
            #expect(r.of(.counterparty).isEmpty,"\(screen.id) created a counterparty pair")
            #expect(r.of(.referencePrimary).isEmpty,"\(screen.id) created a reference pair")
        }
    }
    @Test func corpusPairingScoreboard() throws {
        let screens=G0Corpus.generated().filter { G0Corpus.archetypes.contains($0.kind) }
        var table:[String:[String:(hit:Int,total:Int)]] = [:]
        for screen in screens {
            let relations=ScreenshotRelations(ScreenshotSpans(ScreenshotLayout(screen.lines),
                capturedAt:Instant(iso:screen.capturedAt)!,timeZone:screen.timeZone))
            let family=screen.kind
            let expected:[(String,ScreenLabelConcept,String)] = [
                ("amount",.amountTotal,screen.truth.amountMinor.map(String.init) ?? ""),
                ("counterparty",.counterparty,screen.truth.merchant ?? ""),
                ("date",.transactionDate,screen.truth.occurredAt ?? ""),
                ("reference",.referencePrimary,screen.truth.reference ?? "")]
            for (field,concept,value) in expected {
                var row=table[family] ?? [:],count=row[field] ?? (0,0)
                count.total += 1
                let hit=relations.of(concept).contains { pair in
                    switch field {
                    case "amount": return pair.valueSpan?.money?.minorUnits == screen.truth.amountMinor.map(Int64.init)
                    case "counterparty": return pair.valueText == value
                    case "date": return pair.valueSpan?.instant?.seconds == Instant(iso:value)?.seconds
                    default: return pair.valueText == value
                    }
                }
                if hit { count.hit += 1 }
                row[field]=count;table[family]=row
            }
        }
        for family in G0Corpus.archetypes {
            let row=table[family]!
            print("G2 \(family): " + ["amount","counterparty","date","reference"].map { "\($0) \(row[$0]!.hit)/\(row[$0]!.total)" }.joined(separator:", "))
        }
        // Only layouts with an explicit label/value relation are gated at G2.
        #expect(table["B-columns"]!["amount"]!.hit >= 60)
        #expect(table["B-columns"]!["counterparty"]!.hit >= 60)
        #expect(table["C-stacked"]!["counterparty"]!.hit >= 60)
        #expect(table["F-receipt"]!["reference"]!.hit >= 60)
        #expect(table["G-malay"]!["counterparty"]!.hit >= 60)
        #expect(table["H-mixed"]!["reference"]!.hit >= 60)
    }
}
