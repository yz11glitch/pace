import Foundation
import Testing
@testable import PaceCore

@Suite("G1 layout and typed spans") struct ScreenshotG1Tests {
    let capture=Instant(iso:"2026-09-28T08:00:00Z")!
    let zone="Asia/Kuala_Lumpur"
    func layout(_ texts:[String]) -> ScreenshotLayout {
        ScreenshotLayout(texts.enumerated().map { i,t in ScreenshotTextLine(t,x:0.1,y:0.08+Double(i)*0.09,width:0.55,height:0.04) })
    }
    func spans(_ texts:[String]) -> ScreenshotSpans { ScreenshotSpans(layout(texts),capturedAt:capture,timeZone:zone) }
    func money(_ text:String) -> ScreenMoney? { spans([text]).of(.money).first?.money }

    @Test(arguments:[
        ("RM 12.50",1250,"MYR",false), ("-RM12.50",1250,"MYR",true),
        ("−RM 12.50",1250,"MYR",true),("–RM 12.50",1250,"MYR",true),
        ("RM -12.50",1250,"MYR",true),("+RM12.50",1250,"MYR",false),
        ("12.50 MYR",1250,"MYR",false),("RM 12.50 DR",1250,"MYR",true),("RM 12.50 CR",1250,"MYR",false),
        ("MYR 1,234.50",123450,"MYR",false),("1.234,50 EUR",123450,"EUR",false),
        ("RM 1 234,50",123450,"MYR",false),("S$ 9.00",900,"SGD",false),
        ("US$ 9.00",900,"USD",false),("€ 9.00",900,"EUR",false),
        ("£ 9.00",900,"GBP",false),("¥ 9.00",900,"JPY",false),
        ("฿ 9.00",900,"THB",false),("Rp 9.00",900,"IDR",false),
        ("₱ 9.00",900,"PHP",false),("₹ 9.00",900,"INR",false),
        ("₩ 9.00",900,"KRW",false),("USD 9",900,"USD",false)
    ]) func moneyGrammar(text:String,minor:Int64,currency:String,negative:Bool) {
        let value=money(text)
        #expect(value?.minorUnits == minor)
        #expect(value?.currency == currency)
        #expect(value?.negative == negative)
    }

    @Test func moneyRepairsMalformedAndExclusions() {
        let repaired=money("RM 6O.OO")
        #expect(repaired?.minorUnits == 6000 && repaired?.repaired == true)
        #expect(money("6O.OO") == nil)
        #expect(spans(["RM 23.9"]).of(.malformedMoney).count == 1)
        #expect(spans(["RM 23.9"]).of(.money).isEmpty)
        for text in ["14:05", "27/09/2026", "**** **** 9012", "QX742661", "012-3456789", "12.50%", "123456"] {
            #expect(spans([text]).of(.money).isEmpty,"\(text) should not be money")
        }
        let bare=money("12.50")
        #expect(bare?.minorUnits == 1250 && bare?.noCurrency == true)
    }
    @Test func splitMoneyAndAlternates() {
        let observations=[ScreenshotTextLine("RM",x:0.20,y:0.2,width:0.08,height:0.02),
                          ScreenshotTextLine("60.00",x:0.31,y:0.21,width:0.22,height:0.06)]
        let result=ScreenshotSpans(ScreenshotLayout(observations),capturedAt:capture,timeZone:zone)
        #expect(result.of(.money).contains { $0.money?.minorUnits == 6000 && $0.source == .joined })
        let far=[observations[0],ScreenshotTextLine("60.00",x:0.6,y:0.21,width:0.22,height:0.06)]
        #expect(!ScreenshotSpans(ScreenshotLayout(far),capturedAt:capture,timeZone:zone).of(.money).contains { $0.source == .joined })
        let alternate=ScreenshotTextLine("RM 6O.OO",x:0.2,y:0.2,alternates:["RM 60.00","RM 60.00","RM 61.00"])
        let readings=ScreenshotSpans(ScreenshotLayout([alternate]),capturedAt:capture,timeZone:zone).of(.money)
        #expect(readings.filter { $0.money?.minorUnits == 6000 }.count == 1)
        #expect(readings.contains { $0.money?.minorUnits == 6100 && $0.source == .alternate })
    }
    @Test(arguments:[
        ("27/09/2026 14:05", "2026-09-27T06:05:00Z"),
        ("27-09-26 14:05:12", "2026-09-27T06:05:12Z"),
        ("2026.09.27 14:05", "2026-09-27T06:05:00Z"),
        ("27 Sep 2026, 2:05 PM", "2026-09-27T06:05:00Z"),
        ("Sep 27, 2026 at 2:05 p.m.", "2026-09-27T06:05:00Z"),
        ("27 Ogos 2026 14:05", "2026-08-27T06:05:00Z"),
        ("27 Mac 2026 14:05", "2026-03-27T06:05:00Z"),
        ("27 Mei 2026 14:05", "2026-05-27T06:05:00Z"),
        ("27 Dis 2026 14:05", "2026-12-27T06:05:00Z"),
        ("Today 14:05", "2026-09-28T06:05:00Z"),
        ("01/02/2026 09:30", "2026-02-01T01:30:00Z"),
        ("Yesterday 14:05", "2026-09-27T06:05:00Z"),
        ("Semalam 14:05", "2026-09-27T06:05:00Z")
    ]) func dateGrammar(text:String,expected:String) {
        #expect(spans([text]).of(.dateTime).contains { $0.instant?.seconds == Instant(iso:expected)?.seconds })
    }
    @Test func separateDateTimeAndChrome() {
        let s=ScreenshotSpans(ScreenshotLayout([
            ScreenshotTextLine("9:41",x:0.02,y:0.005,width:0.1),
            ScreenshotTextLine("87%",x:0.84,y:0.005,width:0.1),
            ScreenshotTextLine("Carrier",x:0.12,y:0.006,width:0.13,height:0.02),
            ScreenshotTextLine("27 Sep 2026",x:0.1,y:0.3,width:0.45,height:0.04),
            ScreenshotTextLine("2:05 PM",x:0.1,y:0.35,width:0.3,height:0.04)]),capturedAt:capture,timeZone:zone)
        #expect(s.layout.tokens.filter(\.isStatusChrome).count == 3)
        #expect(s.of(.clock).count == 1)
        #expect(s.of(.dateTime).contains { $0.instant?.seconds == Instant(iso:"2026-09-27T06:05:00Z")?.seconds })
    }
    @Test func identifiersMasksPhonesAndTextStayPrimitive() {
        let s=spans(["Reference QX742661","**** **** **** 9012","ending in 9812","012-3456789","4.5%","Orchid Books"])
        #expect(s.of(.identifier).contains { $0.normalized == "QX742661" })
        #expect(spans(["555012"]).of(.integer).first?.normalized == "555012")
        #expect(spans(["555012"]).of(.identifier).first?.normalized == "555012")
        #expect(s.of(.cardMask).count == 2)
        #expect(s.of(.phone).count == 1)
        #expect(s.of(.percent).count == 1)
        #expect(s.of(.identifier).allSatisfy { !$0.normalized.contains("9012") && !$0.normalized.contains("9812") })
        #expect(s.of(.text).contains { $0.reading == "Orchid Books" })
    }
    @Test func geometryIndependentOfObservationOrderAndSize() {
        let base=[ScreenshotTextLine("Total",x:0.08,y:0.3,width:0.18,height:0.025),
                  ScreenshotTextLine("RM 24.00",x:0.50,y:0.29,width:0.25,height:0.075),
                  ScreenshotTextLine("Reference",x:0.08,y:0.46,width:0.25,height:0.03),
                  ScreenshotTextLine("AB123456",x:0.53,y:0.46,width:0.24,height:0.03)]
        let a=ScreenshotLayout(base),b=ScreenshotLayout(base.reversed())
        #expect(a.tokens.map(\.text) == b.tokens.map(\.text))
        #expect(a.lines.map(\.tokenIDs) == b.lines.map(\.tokenIDs))
        #expect(a.sameRow(a.tokens[0],a.tokens[1]))
        #expect(a.rightOf(a.tokens[0]).first?.text == "RM 24.00")
        #expect(a.keyValueLines().count == 2)
        #expect(a.tokens[1].relHeight >= 2)
        #expect(a.columns().count >= 2)
    }
    @Test func inlineTextAndInvalidDatesStayTyped() {
        let s=spans(["Reference QX742661", "Spent RM 12.50 at ORCHID BOOKS", "Date 31/02/2026 14:05"])
        #expect(s.of(.text).contains { $0.normalized == "reference" })
        #expect(s.of(.text).contains { $0.normalized.contains("orchid books") })
        #expect(!s.of(.date).contains { $0.reading.contains("31/02") })
        #expect(spans(["25:62"]).of(.time).isEmpty)
        #expect(spans(["RM 12,34.50"]).of(.money).isEmpty)
    }
    @Test func primitiveInvarianceOverGeneratedArchetypes() {
        let screens=G0Corpus.generated().filter { G0Corpus.archetypes.contains($0.kind) }
        for screen in screens {
            func evidence(_ lines:[ScreenshotTextLine]) -> (Set<String>,Set<String>,Set<String>) {
                let s=ScreenshotSpans(ScreenshotLayout(lines),capturedAt:Instant(iso:screen.capturedAt)!,timeZone:screen.timeZone)
                return (Set(s.of(.money).map(\.normalized)),Set(s.of(.dateTime).map(\.normalized)),Set(s.of(.identifier).map(\.normalized)))
            }
            let original=evidence(screen.lines)
            let shuffled=evidence(Array(screen.lines.reversed()))
            #expect(original.0 == shuffled.0 && original.1 == shuffled.1 && original.2 == shuffled.2)
            let shifted=screen.lines.map { l in ScreenshotTextLine(l.text,confidence:l.confidence,x:min(0.98,l.x+0.04),y:min(0.98,l.y+0.04),width:l.width,height:l.height,pass:l.pass,alternates:l.alternates) }
            let moved=evidence(shifted)
            #expect(original.0 == moved.0 && original.1 == moved.1 && original.2 == moved.2)
        }
    }
    @Test func observationEvidenceAndRelations() {
        let a=ScreenshotTextLine("  Total   Paid  ",confidence:0.71,x:0.08,y:0.30,width:0.20,height:0.025,
                                 pass:"recovery:v1",alternates:["Total Paid"])
        let b=ScreenshotTextLine("RM 12.50",x:0.50,y:0.27,width:0.25,height:0.075)
        let c=ScreenshotTextLine("Other",x:0.08,y:0.50,width:0.2,height:0.03)
        let model=ScreenshotLayout([c,b,a])
        let label=model.tokens.first { $0.text == a.text }!
        let amount=model.tokens.first { $0.text == b.text }!
        #expect(label.normalizedText == "Total Paid")
        #expect(label.confidence == 0.71 && label.pass == "recovery:v1")
        #expect(label.alternates == ["Total Paid"])
        #expect(model.sameRow(label,amount))
        #expect(model.rightOf(label).first?.id == amount.id)
        #expect(model.nearest(to:label,where:{ $0.text.hasPrefix("RM") })?.id == amount.id)
        #expect(model.below(label).contains { $0.text == "Other" })
        #expect(label.zone(firstRelationY:0.4) == .header)
        #expect(model.tokens.first { $0.text == "Other" }?.zone(firstRelationY:0.4) == .body)
        #expect(model.tokens.map(\.text) == ScreenshotLayout([a,b,c]).tokens.map(\.text))
    }
    @Test func mixedBoxPreservesIndependentTypes() {
        let s=spans(["Paid RM 12.50 Ref QX742661", "Card **** 9012 Ref ZZ009911"])
        #expect(s.of(.money).contains { $0.money?.minorUnits == 1250 })
        #expect(s.of(.identifier).contains { $0.normalized == "QX742661" })
        #expect(spans(["555012"]).of(.integer).first?.normalized == "555012")
        #expect(spans(["555012"]).of(.identifier).first?.normalized == "555012")
        #expect(s.of(.identifier).contains { $0.normalized == "ZZ009911" })
        #expect(s.of(.cardMask).count == 1)
        #expect(s.of(.text).contains { $0.normalized.contains("ref") })
    }
    @Test func corpusPrimitiveCoverage() throws {
        let generated=G0Corpus.generated().filter { G0Corpus.archetypes.contains($0.kind) }
        var bySplit:[String:(count:Int,money:Int,date:Int,id:Int)]=[:]
        for screen in generated {
            let s=ScreenshotSpans(ScreenshotLayout(screen.lines),capturedAt:Instant(iso:screen.capturedAt)!,timeZone:screen.timeZone)
            var c=bySplit[screen.split] ?? (0,0,0,0)
            c.count += 1
            if s.of(.money).contains(where:{ $0.money?.minorUnits == screen.truth.amountMinor.map(Int64.init) }) { c.money += 1 }
            if s.of(.dateTime).contains(where:{ $0.instant?.seconds == screen.truth.occurredAt.flatMap { Instant(iso:$0)?.seconds } }) { c.date += 1 }
            if s.of(.identifier).contains(where:{ $0.normalized == screen.truth.reference }) { c.id += 1 }
            bySplit[screen.split]=c
        }
        for split in ["dev","holdout"] {
            let c=bySplit[split]!
            print("G1 primitives \(split): \(c.money)/\(c.count) money, \(c.date)/\(c.count) dates, \(c.id)/\(c.count) identifiers")
            #expect(c.money >= c.count*9/10)
            #expect(c.date >= c.count*9/10)
            #expect(c.id >= c.count*9/10)
        }
        let blind=try G0Corpus.fixtures().filter { $0.split == "blind" && $0.truth.payment }
        #expect(blind.count >= 15)
        let recognized=blind.filter { screen in
            let s=ScreenshotSpans(ScreenshotLayout(screen.lines),capturedAt:Instant(iso:screen.capturedAt)!,timeZone:screen.timeZone)
            return s.of(.money).contains { $0.money?.minorUnits == screen.truth.amountMinor.map(Int64.init) }
        }
        #expect(recognized.count >= 12)
        let dated=blind.filter { $0.truth.occurredAt != nil }
        let dateHits=dated.filter { screen in
            let s=ScreenshotSpans(ScreenshotLayout(screen.lines),capturedAt:Instant(iso:screen.capturedAt)!,timeZone:screen.timeZone)
            return s.of(.dateTime).contains { $0.instant?.seconds == screen.truth.occurredAt.flatMap { Instant(iso:$0)?.seconds } }
        }
        let referenced=blind.filter { $0.truth.reference != nil }
        let referenceHits=referenced.filter { screen in
            let s=ScreenshotSpans(ScreenshotLayout(screen.lines),capturedAt:Instant(iso:screen.capturedAt)!,timeZone:screen.timeZone)
            return s.of(.identifier).contains { $0.normalized == screen.truth.reference }
        }
        print("G1 blind primitives: money \(recognized.count)/\(blind.count), date \(dateHits.count)/\(dated.count), identifier \(referenceHits.count)/\(referenced.count)")
        #expect(dateHits.count >= 8)
        #expect(referenceHits.count >= 8)
    }
}
