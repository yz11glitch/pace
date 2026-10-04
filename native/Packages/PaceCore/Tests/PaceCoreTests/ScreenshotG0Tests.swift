import Foundation
import Testing
@testable import PaceCore

private func changed(_ s: G0Screen, _ lines: [ScreenshotTextLine], merchant: String? = nil) -> G0Screen {
    G0Screen(id:s.id,kind:s.kind,split:s.split,capturedAt:s.capturedAt,timeZone:s.timeZone,
             truth:G0Truth(payment:s.truth.payment,amountMinor:s.truth.amountMinor,merchant:merchant ?? s.truth.merchant,
                           occurredAt:s.truth.occurredAt,reference:s.truth.reference),lines:lines)
}
private func copy(_ l: ScreenshotTextLine, text: String? = nil, x: Double? = nil, y: Double? = nil,
                  width: Double? = nil, height: Double? = nil) -> ScreenshotTextLine {
    ScreenshotTextLine(text ?? l.text,confidence:l.confidence,x:x ?? l.x,y:y ?? l.y,width:width ?? l.width,
                       height:height ?? l.height,pass:l.pass,alternates:l.alternates)
}
private enum Metamorphic {
    static let names = ["shuffle","shift-x","shift-x-negative","shift-y","shift-y-negative","rescale","rescale-small","split","merge","wording","noise","rename"]
    static func apply(_ s:G0Screen,_ name:String) -> G0Screen {
        var lines = s.lines
        switch name {
        case "shuffle": lines = lines.enumerated().sorted { ($0.offset*37)%101 < ($1.offset*37)%101 }.map(\.element)
        case "shift-x": lines = lines.map { copy($0,x:min(0.98,$0.x+0.05)) }
        case "shift-x-negative": lines = lines.map { copy($0,x:max(0.005,$0.x-0.05)) }
        case "shift-y": lines = lines.map { copy($0,y:min(0.98,$0.y+0.045)) }
        case "shift-y-negative": lines = lines.map { copy($0,y:max(0.005,$0.y-0.045)) }
        case "rescale": lines = lines.map { copy($0,width:min(0.98,$0.width*0.85),height:$0.height*1.3) }
        case "rescale-small": lines = lines.map { copy($0,width:$0.width*0.8,height:$0.height*0.8) }
        case "split":
            if let i = lines.firstIndex(where: { $0.text.contains(" ") && $0.text.count > 5 }) {
                let parts = lines[i].text.split(separator:" ",maxSplits:1).map(String.init)
                lines.replaceSubrange(i...i,with:[copy(lines[i],text:parts[0],width:lines[i].width*0.4),
                                                 copy(lines[i],text:parts[1],x:lines[i].x+lines[i].width*0.45,width:lines[i].width*0.55)])
            }
        case "merge":
            if let i = lines.indices.dropLast().first(where: { ["Reference No.","Reference","Transaction ID","Pay To"].contains(lines[$0].text) }) {
                lines.replaceSubrange(i...i+1,with:[copy(lines[i],text:lines[i].text+" "+lines[i+1].text)])
            }
        case "wording":
            lines = lines.map { l in
                var t=l.text
                for (a,b) in [("Reference:","Payment Ref:"),("Recipient Name","Receiver Name"),("Pay To","Beneficiary"),("Total","Amount paid"),("Date & Time","Transaction date")] {
                    if t.hasPrefix(a) { t=b+t.dropFirst(a.count); break }
                }
                return copy(l,text:t)
            }
        case "noise": lines += [ScreenshotTextLine("9:41",x:0.02,y:0.005,width:0.1),
                                ScreenshotTextLine("Special offer tomorrow",x:0.57,y:0.84,width:0.35),
                                ScreenshotTextLine("Balance RM 987.65",x:0.57,y:0.89,width:0.35),
                                ScreenshotTextLine("Help",x:0.07,y:0.94,width:0.4)]
        case "rename":
            guard let merchant=s.truth.merchant else { return s }
            lines=lines.map { copy($0,text:$0.text.replacingOccurrences(of:merchant,with:"ZORO MELA STUDIO")) }
            return changed(s,lines,merchant:"ZORO MELA STUDIO")
        default: break
        }
        return changed(s,lines)
    }
}
private struct Counts {
    var correct=0,missing=0,wrong=0,wrongTrusted=0
    mutating func add<T:Equatable>(_ actual:T?,_ expected:T?,trusted:Bool=false) {
        if actual == expected { correct += 1 }
        else if actual == nil { missing += 1 }
        else { wrong += 1; if trusted { wrongTrusted += 1 } }
    }
    var summary:String { "\(correct)/\(missing)/\(wrong)/\(wrongTrusted)" }
}
private func digest(_ data:Data) -> String {
    var h:UInt64=0xcbf29ce484222325
    for b in data { h=(h ^ UInt64(b)) &* 0x100000001b3 }
    return String(format:"%016llx",h)
}
@Suite("G0 screenshot measurement") struct ScreenshotG0Tests {
    @Test func corpusShapeAndDeterminism() throws {
        let a=G0Corpus.generated()
        #expect(try G0Corpus.bytes(a) == G0Corpus.bytes(G0Corpus.generated()))
        #expect(try G0Corpus.bytes(a) != G0Corpus.bytes(G0Corpus.generated(seed:G0Corpus.seed+1)))
        #expect(a.count == 867)
        #expect(a.filter(\.truth.payment).count == 667)
        #expect(a.filter { !$0.truth.payment }.count == 200)
        for family in G0Corpus.archetypes { #expect(a.filter { $0.kind == family }.count == 75) }
        #expect(a.filter { $0.split == "dev" }.count == 575)
        #expect(a.filter { $0.split == "holdout" }.count == 292)
        #expect(a.filter { G0Corpus.archetypes.contains($0.kind) }.allSatisfy { $0.truth.amountMinor != nil && $0.truth.merchant != nil && $0.truth.occurredAt != nil && $0.truth.reference != nil })
    }
    @Test func fixturesLoad() throws {
        let f=try G0Corpus.fixtures()
        #expect(f.filter { $0.split == "blind" }.count == 24)
        #expect(f.filter { $0.split == "physical-holdout" }.count == 4)
        let ids=Set(f.map(\.id))
        for id in ["P1","P2","P3","P4","P5","P6","P7","N1","N2"] { #expect(ids.contains(id)) }
        #expect(f.filter { $0.split == "blind" }.allSatisfy { s in
            !s.lines.contains { l in ["SKYFARE","KLINIK","NORTHWIND RESTAURANT","Maybank","Ryt"].contains { l.text.localizedCaseInsensitiveContains($0) } }
        })
    }
    @Test func metamorphicTruthAndDeterminism() throws {
        for s in G0Corpus.generated().filter(\.truth.payment) {
            for name in Metamorphic.names {
                let a=Metamorphic.apply(s,name), b=Metamorphic.apply(s,name)
                #expect(try G0Corpus.bytes([a]) == G0Corpus.bytes([b]))
                #expect(a.truth.payment == s.truth.payment)
                #expect(a.truth.amountMinor == s.truth.amountMinor)
                #expect(a.truth.occurredAt == s.truth.occurredAt)
                #expect(a.truth.reference == s.truth.reference)
                #expect(a.truth.merchant == (name == "rename" && s.truth.merchant != nil ? "ZORO MELA STUDIO" : s.truth.merchant))
            }
        }
    }
    @Test func sourceScan() throws {
        let tests=URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        let package=tests.deletingLastPathComponent().deletingLastPathComponent()
        let native=package.deletingLastPathComponent().deletingLastPathComponent()
        let words=["maybank","ryt","mae","cimb","touch 'n go","tng","grabpay","shopeepay","SKYFARE","klinik","Contoh Sejahtera","NORTHWIND RESTAURANT","555012","5550001234","99999998","2609010000A000X","2609254ee1b9a7u"]
        var count=0
        for root in [package.appendingPathComponent("Sources"),native.appendingPathComponent("PaceApp")] {
            guard let e=FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil) else { Issue.record("Missing scan root \(root.path)"); continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                // Frozen debug FM probes contain historical provider examples and are not
                // part of the capture implementation; keep scanning every production source.
                if url.path.contains("/ScreenshotFMBench/") { continue }
                if root.lastPathComponent == "PaceApp" && !(url.lastPathComponent.hasPrefix("Screenshot") || url.lastPathComponent == "CaptureLabView.swift") { continue }
                count += 1
                let source=try String(contentsOf:url,encoding:.utf8)
                for word in words {
                    let pattern = #"(?i)(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for:word) + #"(?![\p{L}\p{N}])"#
                    let regex=try NSRegularExpression(pattern:pattern)
                    #expect(regex.firstMatch(in:source,range:NSRange(source.startIndex...,in:source)) == nil,"\(word) in \(url.path)")
                }
            }
        }
        #expect(count >= 10)
        let captureIntent = try String(contentsOf: native.appendingPathComponent("PaceApp/ScreenshotCaptureIntent.swift"),
                                       encoding: .utf8)
        #expect(!captureIntent.contains("ScreenshotSemanticSelectionService.select"))
        print("G0 source scan: PASS (\(count) Swift files)")
    }
    @Test func legacyBaseline() throws {
        let screens=G0Corpus.generated() + (try G0Corpus.fixtures())
        var rows:[String:[String:Counts]]=[:], snapshot:[String]=[]
        for s in screens {
            let r=LegacyScreenshotInterpreter().interpret(s.lines,capturedAt:Instant(iso:s.capturedAt)!,timeZone:s.timeZone), key="\(s.split)/\(s.kind)"
            var f=rows[key] ?? [:]
            func add<T:Equatable>(_ field:String,_ actual:T?,_ expected:T?,trusted:Bool=false) {
                var c=f[field] ?? Counts(); c.add(actual,expected,trusted:trusted); f[field]=c
            }
            add("class",r.detection == .payment,s.truth.payment)
            add("amount",r.amountMinor,s.truth.amountMinor,trusted:r.amountTrust == .trusted)
            add("merchant",r.merchant,s.truth.merchant,trusted:r.merchantTrust == .trusted)
            add("date",r.occurredAt?.seconds,s.truth.occurredAt.flatMap { Instant(iso:$0)?.seconds },trusted:r.dateTrust == .trusted)
            add("reference",r.reference,s.truth.reference)
            rows[key]=f
            snapshot.append([s.id,r.detection.rawValue,r.amountMinor.map(String.init) ?? "-",r.merchant ?? "-",r.occurredAt?.isoUTC ?? "-",r.reference ?? "-"].joined(separator:"|"))
        }
        let hash=digest(Data(snapshot.joined(separator:"\n").utf8))
        print("G0 BASELINE digest=\(hash) screens=\(screens.count)")
        print("correct/missing/wrong/wrong-and-trusted")
        for key in rows.keys.sorted() {
            let f=rows[key]!
            print("\(key) | \(["class","amount","merchant","date","reference"].map { "\($0):\(f[$0]!.summary)" }.joined(separator:" | "))")
        }
        let url=Bundle.module.url(forResource:"legacy-baseline",withExtension:"txt",subdirectory:nil)!
        let expected=try String(contentsOf:url,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        #expect(hash == expected)
    }
    @Test(.disabled("enabled at G3/G4")) func releaseThresholds() throws {
        // Activate field checks at G3 and full classification, blind, and invariance checks at G4.
        let generated=G0Corpus.generated()
        let holdout=generated.filter { $0.split == "holdout" && G0Corpus.archetypes.contains($0.kind) }
        let results=holdout.map { ($0,$0.interpret()) }
        func rate(_ predicate:(G0Screen,ScreenshotInterpretation)->Bool) -> Double {
            Double(results.filter { predicate($0.0,$0.1) }.count)/Double(results.count)
        }
        #expect(rate { _,r in r.detection == .payment } >= 0.97)
        #expect(rate { s,r in r.amountMinor == s.truth.amountMinor } >= 0.95)
        #expect(rate { s,r in r.merchant == s.truth.merchant } >= 0.95)
        #expect(rate { s,r in r.occurredAt?.seconds == s.truth.occurredAt.flatMap { Instant(iso:$0)?.seconds } } >= 0.95)
        #expect(results.allSatisfy { s,r in r.amountMinor == nil || r.amountMinor == s.truth.amountMinor || r.amountTrust != .trusted })
        #expect(results.allSatisfy { s,r in r.reference == nil || r.reference == s.truth.reference })
        #expect(results.filter { $0.0.kind == "E-title" }.allSatisfy { $0.1.merchantTrust != .trusted })
        let blind=try G0Corpus.fixtures().filter { $0.split == "blind" }
        #expect(blind.allSatisfy { s in
            let r=s.interpret()
            return (r.detection == .payment) == s.truth.payment && r.amountMinor == s.truth.amountMinor &&
                r.merchant == s.truth.merchant && r.reference == s.truth.reference &&
                r.occurredAt?.seconds == s.truth.occurredAt.flatMap { Instant(iso:$0)?.seconds }
        })
        #expect(generated.filter { !$0.truth.payment && $0.kind != "list" }.allSatisfy { $0.interpret().detection == .notPayment })
        #expect(generated.filter { $0.kind == "list" }.allSatisfy { $0.interpret().detection == .notPayment })
        #expect(generated.filter { $0.kind == "checkout" || $0.kind == "pending" }.allSatisfy {
            let r=$0.interpret(); return r.detection == .payment && !r.statusClean
        })
        #expect(generated.filter { $0.truth.payment && G0Corpus.archetypes.contains($0.kind) }.allSatisfy { s in
            return Metamorphic.names.allSatisfy { name in
                let variant=Metamorphic.apply(s,name), transformed=variant.interpret()
                return transformed.detection == .payment && transformed.amountMinor == variant.truth.amountMinor &&
                    transformed.reference == variant.truth.reference &&
                    transformed.occurredAt?.seconds == variant.truth.occurredAt.flatMap { Instant(iso:$0)?.seconds } &&
                    transformed.merchant == variant.truth.merchant
            }
        })
    }
}
