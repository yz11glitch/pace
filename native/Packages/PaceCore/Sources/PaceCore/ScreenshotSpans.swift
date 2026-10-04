import Foundation

enum ScreenSpanKind: Sendable { case money, malformedMoney, date, time, dateTime, identifier, integer, cardMask, clock, percent, phone, text }
enum ScreenReadingSource: Sendable { case primary, alternate, joined }
struct ScreenMoney: Equatable, Sendable {
    let currency: String?
    let minorUnits: Int64
    let negative: Bool
    let explicitPlus: Bool
    let repaired: Bool
    let noCurrency: Bool
}
/// Typed evidence is not a selected transaction field. Token ids preserve OCR provenance.
struct ScreenSpan: Sendable {
    let kind: ScreenSpanKind
    let tokenIDs: [Int]
    let reading: String
    let source: ScreenReadingSource
    let normalized: String
    let money: ScreenMoney?
    let dateISO: String?
    let timeSeconds: Int?
    let instant: Instant?
}

struct ScreenshotSpans: Sendable {
    let layout: ScreenshotLayout
    let spans: [ScreenSpan]
    func of(_ kind:ScreenSpanKind) -> [ScreenSpan] { spans.filter { $0.kind == kind } }

    init(_ layout:ScreenshotLayout,capturedAt:Instant,timeZone:String) {
        self.layout=layout
        let zone=TimeZone(identifier:timeZone) ?? TimeZone(secondsFromGMT:0)!
        var output:[ScreenSpan]=[]
        for token in layout.tokens {
            for (index,reading) in ([token.normalizedText]+token.alternates).enumerated() {
                output += Self.parse(reading,ids:[token.id],source:index == 0 ? .primary : .alternate,
                                     capturedAt:capturedAt,zone:zone,chrome:token.isStatusChrome)
            }
        }
        for line in layout.lines {
            let tokens=line.tokenIDs.map { layout.tokens[$0] }
            for (a,b) in zip(tokens,tokens.dropFirst()) where a.box.horizontalGap(to:b.box) <= 0.12 {
                if Self.isCurrency(a.normalizedText) || Self.isCurrency(b.normalizedText) {
                    output += Self.parse(a.normalizedText+" "+b.normalizedText,ids:[a.id,b.id],source:.joined,
                                         capturedAt:capturedAt,zone:zone,chrome:false)
                        .filter { $0.kind == .money || $0.kind == .malformedMoney }
                }
            }
        }
        let dates=output.filter { $0.kind == .date }, times=output.filter { $0.kind == .time }
        for date in dates where date.tokenIDs.count == 1 {
            let d=layout.tokens[date.tokenIDs[0]]
            for time in times where time.tokenIDs.count == 1 && time.tokenIDs[0] != d.id {
                let t=layout.tokens[time.tokenIDs[0]]
                let adjacent=t.box.centerY > d.box.centerY && d.box.verticalGap(to:t.box) <= layout.medianTextHeight*1.5 && d.box.horizontalOverlap(with:t.box) > 0
                if (layout.sameRow(d,t) || adjacent),let day=date.dateISO,let seconds=time.timeSeconds,
                   let instant=Self.instant(day,seconds,zone) {
                    output.append(Self.span(.dateTime,[d.id,t.id],date.reading+" "+time.reading,.joined,
                                            instant.isoUTC,day:day,time:seconds,instant:instant))
                }
            }
        }
        var seen:Set<String>=[]
        spans=output.filter { seen.insert("\($0.kind)|\($0.tokenIDs)|\($0.normalized)").inserted }
    }

    private static func span(_ kind:ScreenSpanKind,_ ids:[Int],_ reading:String,_ source:ScreenReadingSource,
                             _ normalized:String,money:ScreenMoney?=nil,day:String?=nil,
                             time:Int?=nil,instant:Instant?=nil) -> ScreenSpan {
        .init(kind:kind,tokenIDs:ids,reading:reading,source:source,normalized:normalized,
              money:money,dateISO:day,timeSeconds:time,instant:instant)
    }
    private static let currencies=Set(Locale.commonISOCurrencyCodes.map { $0.uppercased() })
    private static let currencyRegex = #"(?:[A-Z]{3}|RM|S\$|US\$|Rp|[$€£¥฿₱₹₩])"#
    private static let numberRegex = #"[0-9OIl|SB][0-9OIl|SB., ]*"#
    private static func currency(_ raw:String) -> String? {
        switch raw.uppercased() {
        case "RM": return "MYR"; case "S$": return "SGD"; case "US$","$": return "USD"
        case "€": return "EUR"; case "£": return "GBP"; case "¥": return "JPY"
        case "฿": return "THB"; case "RP": return "IDR"; case "₱": return "PHP"
        case "₹": return "INR"; case "₩": return "KRW"
        default: return currencies.contains(raw.uppercased()) ? raw.uppercased() : nil
        }
    }
    private static func isCurrency(_ raw:String) -> Bool {
        let t=raw.trimmingCharacters(in:.whitespaces)
        return currency(t) != nil || ["-","−","–","+","-RM","RM-","MYR-"].contains(t.uppercased())
    }
    private static func parse(_ raw:String,ids:[Int],source:ScreenReadingSource,capturedAt:Instant,
                              zone:TimeZone,chrome:Bool) -> [ScreenSpan] {
        let text=raw.precomposedStringWithCanonicalMapping.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var result:[ScreenSpan]=[]
        let masks=matches(text,#"(?i)(?:[*•x]{2,}[\s-]*){1,4}\d{2,4}|\bending\s+(?:in\s+)?\d{4}\b"#)
        let phones=matches(text,#"(?<!\w)(?:\+\d{1,3}[ -])?0?\d{2,3}-\d{3,4}[ -]?\d{3,4}(?!\w)"#)
        let percents=matches(text,#"(?<!\d)\d+(?:[.,]\d+)?\s*%"#)
        for m in masks { result.append(span(.cardMask,ids,m,source,m.uppercased())) }
        for m in phones { result.append(span(.phone,ids,m,source,m.filter(\.isNumber))) }
        for m in percents { result.append(span(.percent,ids,m,source,m.replacingOccurrences(of:" ",with:""))) }
        let excluded = !masks.isEmpty || !phones.isEmpty || !percents.isEmpty
        let dates=dateReadings(text,capturedAt,zone), times=timeReadings(text)
        for d in dates { result.append(span(.date,ids,d.raw,source,d.iso,day:d.iso)) }
        for t in times { result.append(span(chrome ? .clock : .time,ids,t.raw,source,String(t.seconds),time:t.seconds)) }
        if let d=dates.first,let t=times.first,let instant=instant(d.iso,t.seconds,zone) {
            result.append(span(.dateTime,ids,text,source,instant.isoUTC,day:d.iso,time:t.seconds,instant:instant))
        }
        result += moneyReadings(text,ids,source)
        if !excluded {
            if !result.contains(where:{ $0.kind == .money || $0.kind == .malformedMoney }) && dates.isEmpty && times.isEmpty {
                for n in matches(text,#"(?<![\w.,])\d[\d, ]*[.,]\d{2}(?![\d%])"#) {
                    if let minor=number(n) {
                        result.append(span(.money,ids,n,source,String(minor),money:.init(currency:nil,minorUnits:minor,negative:false,explicitPlus:false,repaired:false,noCurrency:true)))
                    }
                }
            }
        }
        for id in matches(text,#"(?i)(?<![A-Z0-9])[A-Z0-9][A-Z0-9/-]{4,39}(?![A-Z0-9])"#) where id.contains(where:\.isNumber) {
            let occupied=result.contains { typed in
                typed.kind != .text && typed.reading.localizedCaseInsensitiveContains(id)
            }
            if !occupied { result.append(span(.identifier,ids,id,source,id.uppercased())) }
        }
        for integer in matches(text,#"(?<![A-Z0-9])\d{1,18}(?![A-Z0-9])"#) {
            let occupied=result.contains { typed in
                typed.kind != .identifier && typed.kind != .text && typed.reading.contains(integer)
            }
            if !occupied { result.append(span(.integer,ids,integer,source,integer)) }
        }
        // Keep label/title prose even when an inline typed value was found in the same OCR box.
        var remainder=text
        for typed in result where typed.kind != .dateTime && typed.kind != .text {
            remainder=remainder.replacingOccurrences(of:typed.reading,with:"",options:.caseInsensitive)
        }
        remainder=remainder.trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters))
        if remainder.contains(where:\.isLetter) { result.append(span(.text,ids,remainder,source,remainder.lowercased())) }
        return result
    }
    private static func moneyReadings(_ text:String,_ ids:[Int],_ source:ScreenReadingSource) -> [ScreenSpan] {
        let prefix = #"(?i)(?<![A-Z0-9])([-−–+]?)[ ]*("# + currencyRegex + #")[ ]*([-−–+]?)[ ]*("# + numberRegex + #")(?:\s*(DR|CR))?(?![A-Z0-9])"#
        let suffix = #"(?i)(?<![A-Z0-9])([-−–+]?)[ ]*("# + numberRegex + #")[ ]*("# + currencyRegex + #")(?:\s*(DR|CR))?(?![A-Z0-9])"#
        var result:[ScreenSpan]=[]
        for (pattern,c,n,extra,trailing) in [(prefix,2,4,3,5),(suffix,3,2,0,4)] {
            guard let regex=try? NSRegularExpression(pattern:pattern) else { continue }
            for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
                func part(_ i:Int) -> String {
                    guard i > 0,let range=Range(match.range(at:i),in:text) else { return "" }
                    return String(text[range]).trimmingCharacters(in:.whitespaces)
                }
                guard let cur=currency(part(c)),let range=Range(match.range,in:text) else { continue }
                let raw=String(text[range]).trimmingCharacters(in:.whitespaces)
                let digits=part(n), repaired=repair(digits)
                let negative=[part(1),part(extra),part(trailing)].contains { ["-","−","–","DR"].contains($0.uppercased()) }
                let explicitPlus=[part(1),part(extra),part(trailing)].contains { $0 == "+" }
                if let minor=number(repaired) {
                    result.append(span(.money,ids,raw,source,"\(cur):\(negative ? "-" : "+")\(minor)",
                                       money:.init(currency:cur,minorUnits:minor,negative:negative,explicitPlus:explicitPlus,repaired:repaired != digits,noCurrency:false)))
                } else { result.append(span(.malformedMoney,ids,raw,source,raw.uppercased())) }
            }
        }
        return result
    }
    private static func repair(_ raw:String) -> String {
        let map:[Character:Character]=["O":"0","I":"1","l":"1","|":"1","S":"5","B":"8"]
        return String(raw.map { map[$0] ?? $0 })
    }
    private static func number(_ raw:String) -> Int64? {
        let value=raw.trimmingCharacters(in:.whitespaces)
        guard !value.isEmpty,value.allSatisfy({ $0.isNumber || ",. ".contains($0) }) else { return nil }
        let chars=Array(value), last=chars.lastIndex(where:{ $0 == "." || $0 == "," })
        let decimal:Bool
        if let last { let tail=chars.count-last-1; if tail == 1 { return nil }; decimal=tail == 2 }
        else { decimal=false }
        let majorPart=decimal ? String(chars[..<last!]) : value
        let cents=decimal ? Int64(String(chars[(last!+1)...])) : 0
        let groups=majorPart.split(whereSeparator:{ ",. ".contains($0) })
        guard !groups.isEmpty,groups.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        if groups.count > 1 { guard (1...3).contains(groups[0].count),groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil } }
        guard let major=Int64(groups.joined()),major <= 100_000_000 else { return nil }
        let minor=major*100+(cents ?? 0)
        return (1...10_000_000_000).contains(minor) ? minor : nil
    }
    private struct Day { let raw:String; let iso:String }
    private static func dateReadings(_ value:String,_ capturedAt:Instant,_ zone:TimeZone) -> [Day] {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=zone
        var output:[Day]=[]
        for relative in matches(value,#"(?i)\b(?:today|yesterday|semalam)\b"#) {
            let offset=relative.lowercased() == "today" ? 0 : -1
            if let day=calendar.date(byAdding:.day,value:offset,to:Date(timeIntervalSince1970:Double(capturedAt.seconds))) {
                let c=calendar.dateComponents([.year,.month,.day],from:day)
                output.append(.init(raw:relative,iso:String(format:"%04d-%02d-%02d",c.year!,c.month!,c.day!)))
            }
        }
        let months:[String:Int]=["jan":1,"january":1,"januari":1,"feb":2,"february":2,"februari":2,
            "mar":3,"march":3,"mac":3,"apr":4,"april":4,"mei":5,"may":5,"jun":6,"june":6,
            "jul":7,"july":7,"julai":7,"aug":8,"august":8,"ogos":8,"sep":9,"sept":9,"september":9,
            "oct":10,"october":10,"okt":10,"oktober":10,"nov":11,"november":11,"dec":12,"december":12,"dis":12,"disember":12]
        for (pattern,order) in [(#"\b(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\b"#,0),
                                (#"\b(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})\b"#,1),
                                (#"(?i)\b(\d{1,2})\s+([A-Z]+)\s+(\d{4})\b"#,2),
                                (#"(?i)\b([A-Z]+)\s+(\d{1,2}),?\s+(\d{4})\b"#,3)] {
            guard let regex=try? NSRegularExpression(pattern:pattern) else { continue }
            for match in regex.matches(in:value,range:NSRange(value.startIndex...,in:value)) {
                func part(_ i:Int) -> String { guard let r=Range(match.range(at:i),in:value) else { return "" };return String(value[r]) }
                var year=0,month=0,day=0
                switch order {
                case 0: year=Int(part(1)) ?? 0;month=Int(part(2)) ?? 0;day=Int(part(3)) ?? 0
                case 1: day=Int(part(1)) ?? 0;month=Int(part(2)) ?? 0;year=Int(part(3)) ?? 0
                case 2: day=Int(part(1)) ?? 0;month=months[part(2).lowercased()] ?? 0;year=Int(part(3)) ?? 0
                default: month=months[part(1).lowercased()] ?? 0;day=Int(part(2)) ?? 0;year=Int(part(3)) ?? 0
                }
                if year < 100 { year += year >= 70 ? 1900 : 2000 }
                let c=DateComponents(timeZone:zone,year:year,month:month,day:day,hour:12)
                guard let date=calendar.date(from:c) else { continue }
                let check=calendar.dateComponents([.year,.month,.day],from:date)
                guard check.year == year && check.month == month && check.day == day else { continue }
                output.append(.init(raw:part(0),iso:String(format:"%04d-%02d-%02d",year,month,day)))
            }
        }
        var seen:Set<String>=[]
        return output.filter { seen.insert($0.iso).inserted }
    }
    private struct Time { let raw:String; let seconds:Int }
    private static func timeReadings(_ value:String) -> [Time] {
        guard let regex=try? NSRegularExpression(pattern:#"(?i)(?<!\d)(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM|a\.m\.|p\.m\.)?(?!\d)"#) else { return [] }
        return regex.matches(in:value,range:NSRange(value.startIndex...,in:value)).compactMap { m in
            func part(_ i:Int) -> String { guard let r=Range(m.range(at:i),in:value) else { return "" };return String(value[r]) }
            guard var hour=Int(part(1)),let minute=Int(part(2)),let second=Int(part(3).isEmpty ? "0" : part(3)),minute<60,second<60 else { return nil }
            let meridiem=part(4).lowercased().replacingOccurrences(of:".",with:"")
            if meridiem.isEmpty { guard hour<24 else { return nil } }
            else { guard (1...12).contains(hour) else { return nil };hour=hour%12+(meridiem == "pm" ? 12 : 0) }
            return .init(raw:part(0),seconds:hour*3600+minute*60+second)
        }
    }
    private static func instant(_ day:String,_ seconds:Int,_ zone:TimeZone) -> Instant? {
        let parts=day.split(separator:"-").compactMap { Int($0) };guard parts.count == 3 else { return nil }
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=zone
        let c=DateComponents(timeZone:zone,year:parts[0],month:parts[1],day:parts[2],
                             hour:seconds/3600,minute:(seconds%3600)/60,second:seconds%60)
        guard let date=calendar.date(from:c) else { return nil }
        return Instant(seconds:Int64(date.timeIntervalSince1970))
    }
    private static func matches(_ text:String,_ pattern:String) -> [String] {
        guard let regex=try? NSRegularExpression(pattern:pattern) else { return [] }
        return regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { m in
            guard let r=Range(m.range,in:text) else { return nil };return String(text[r])
        }
    }
}
