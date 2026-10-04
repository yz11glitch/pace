import Foundation
import PaceCore

// G0-only ground truth. Nil means the field is absent from the screen, including negatives.
struct G0Truth: Codable {
    let payment: Bool
    let amountMinor: Int?
    let merchant: String?
    let occurredAt: String?
    let reference: String?
}

struct G0Screen: Codable {
    let id: String
    let kind: String
    let split: String
    let capturedAt: String
    let timeZone: String
    let truth: G0Truth
    let lines: [ScreenshotTextLine]

    func interpret() -> ScreenshotInterpretation {
        ScreenshotInterpreter().interpret(lines, capturedAt: Instant(iso: capturedAt)!, timeZone: timeZone)
    }
}

private struct G0Random {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
    mutating func index(_ count: Int) -> Int { Int(next() % UInt64(count)) }
    mutating func pick<T>(_ values: [T]) -> T { values[index(values.count)] }
}

enum G0Corpus {
    static let seed: UInt64 = 0x2026_0928_60
    static let archetypes = ["A-hero", "B-columns", "C-stacked", "D-alert", "E-title", "F-receipt", "G-malay", "H-mixed"]
    static let capture = "2026-09-28T08:00:00Z"
    static let zone = "Asia/Kuala_Lumpur"

    static func generated(seed: UInt64 = seed) -> [G0Screen] {
        var rng = G0Random(state: seed)
        var corpus: [G0Screen] = []
        let syllables = ["aro", "bexa", "cori", "duma", "elvi", "feno", "gala", "hoku", "juna", "kivo", "lora", "mexo", "navi", "peta", "qumi", "sora"]
        let suffixes = ["WORKS", "CAFE", "STUDIO", "MARKET", "TRAVEL", "LAB", "BOOKS", "& CO"]
        for family in archetypes.indices {
            for number in 0..<75 {
                let amount = 100 + rng.index(98_000)
                let amountString = String(format: "%d.%02d", amount / 100, amount % 100)
                let baseMerchant = rng.pick(syllables).capitalized + rng.pick(syllables) + " " + rng.pick(suffixes)
                let merchant = rng.index(8) == 0 ? "\(baseMerchant) MYR - TRIP \(rng.index(90000)+10000)" : baseMerchant
                let ref = "Q\(family)\(String(format: "%08d", rng.index(100_000_000)))"
                let minute = rng.index(60)
                let date = rng.pick([
                    String(format: "27/09/2026 14:%02d", minute),
                    String(format: "27 Sep 2026, 2:%02d PM", minute),
                    String(format: "2026-09-27 14:%02d", minute),
                    String(format: "27-09-2026 14:%02d", minute)])
                let expectedDate = String(format: "2026-09-27T06:%02d:00Z", minute)
                let split = family < 5 ? "dev" : "holdout"
                let amountLabel = rng.pick(split == "dev" ? ["RM", "RM ", "MYR "] : ["RM ", "MYR ", "RM-"])
                let amountText = amountLabel + amountString
                var cells: [(String, Double, Double, Double, Double)] = []
                func add(_ text: String, _ x: Double, _ y: Double, _ width: Double = 0.38, _ height: Double = 0.035) {
                    cells.append((text,x,y,width,height))
                }
                switch family {
                case 0:
                    add(rng.pick(["Payment successful","Payment completed"]), 0.28, 0.08); add(amountText, 0.37, 0.22, 0.28, 0.07)
                    add("Paid to \(merchant)", 0.12, 0.39); add(date, 0.12, 0.58); add("Reference: \(ref)", 0.12, 0.73)
                case 1:
                    add("Transaction approved", 0.09, 0.08); add("Amount", 0.08, 0.23); add(amountText, 0.55, 0.23)
                    add(rng.pick(["Recipient Name","Receiver Name","Beneficiary"]), 0.08, 0.36); add(merchant, 0.55, 0.36)
                    add("Date & Time", 0.08, 0.49); add(date, 0.55, 0.49)
                    add("Reference No.", 0.08, 0.63); add(ref, 0.55, 0.63)
                case 2:
                    add("Successful", 0.37, 0.07); add("Total", 0.09, 0.21); add(amountText, 0.09, 0.27, 0.4, 0.06)
                    add(rng.pick(["Pay To","Receiver","Beneficiary"]), 0.09, 0.40); add(merchant, 0.09, 0.46)
                    add("Date", 0.09, 0.58); add(date, 0.09, 0.64); add("Transaction No.", 0.09, 0.75); add(ref, 0.09, 0.81)
                case 3:
                    add("Transaction Approved", 0.08, 0.12); add("Spent \(amountText) at \(merchant)", 0.08, 0.30, 0.8)
                    add(date, 0.08, 0.47); add("Auth Ref \(ref)", 0.08, 0.66)
                case 4:
                    add(merchant, 0.12, 0.10, 0.65, 0.055); add("-\(amountText)", 0.33, 0.27, 0.32, 0.08)
                    add("Paid", 0.41, 0.46); add(date, 0.14, 0.59); add("Transaction ID", 0.14, 0.73); add(ref, 0.14, 0.79)
                case 5:
                    add("Receipt", 0.10, 0.07); add(merchant, 0.10, 0.18, 0.65, 0.06)
                    add("Item", 0.10, 0.35); add("Service", 0.10, 0.45)
                    add("Total", 0.10, 0.58); add(amountText, 0.60, 0.58)
                    add(rng.pick(["Order No.","Invoice Number"]), 0.10, 0.70); add(ref, 0.56, 0.70); add(date, 0.10, 0.82)
                case 6:
                    add("Pembayaran Berjaya", 0.22, 0.07); add(amountText, 0.36, 0.21, 0.35, 0.07)
                    add("Penerima", 0.10, 0.37); add(merchant, 0.10, 0.43)
                    add("Tarikh", 0.10, 0.57); add(date, 0.10, 0.63)
                    add(rng.pick(["No. Rujukan","Rujukan Transaksi"]), 0.10, 0.75); add(ref, 0.10, 0.81)
                default:
                    add("Completed", 0.38, 0.06); add("-\(amountText)", 0.35, 0.20, 0.35, 0.07)
                    add("To \(merchant)", 0.11, 0.35); add("Transaction date", 0.11, 0.50); add(date, 0.54, 0.50)
                    add(rng.pick(["Payment Ref","Txn Ref"]), 0.11, 0.66); add(ref, 0.54, 0.66)
                }
                if rng.index(3) == 0 { add(rng.pick(["9:41", "Back", "Share receipt", "Offer ends soon"]), 0.04, 0.015) }
                if rng.index(4) == 0 { add("From account **** \(rng.index(9000)+1000)", 0.10, 0.91) }
                if rng.index(5) == 0 { add("Balance RM \(rng.index(900)+100).00", 0.58, 0.89) }
                let lines = cells.map { cell in
                    ScreenshotTextLine(cell.0, confidence: Double(80+rng.index(20))/100, x:max(0.01,cell.1 + Double(rng.index(21)-10)/1000), y:max(0.005,cell.2 + Double(rng.index(21)-10)/1000),
                                       width:cell.3, height:cell.4)
                }
                corpus.append(.init(id:"\(archetypes[family])-\(number)",kind:archetypes[family],split:split,
                                    capturedAt:capture,timeZone:zone,
                                    truth:.init(payment:true,amountMinor:amount,merchant:merchant,
                                                occurredAt:expectedDate,reference:ref),lines:lines))
            }
        }
        let negatives = ["overview", "list", "checkout", "promo", "chat", "weather", "product", "pending"]
        for index in 0..<267 {
            let kind = negatives[index % negatives.count]
            let price = String(format: "RM %d.%02d", 1+rng.index(900),rng.index(100))
            let texts: [String]
            switch kind {
            case "overview": texts = ["Accounts", "Available balance \(price)", "Recent activity"]
            case "list": texts = ["Transactions", "Sep 27  -RM8.20  PLACE ONE", "Sep 26  -RM17.40  PLACE TWO", "Transfer successful", "Sep 25  -RM52.00  PLACE THREE"]
            case "checkout": texts = ["Your cart", "Total \(price)", "Pay now"]
            case "promo": texts = ["Weekend offer", "Get \(price) cashback", "Terms apply"]
            case "chat": texts = ["Messages", "Can you pay me \(price)?", "Maybe later"]
            case "weather": texts = ["Weather", "Cloudy today", "Umbrella from \(price)"]
            case "product": texts = ["Product detail", "Price \(price)", "Add to bag"]
            default: texts = [index % 2 == 0 ? "Transfer pending" : "Transfer failed", "Amount \(price)", "Review before sending"]
            }
            let lines = texts.enumerated().map { i,t in ScreenshotTextLine(t, confidence:0.9, x:0.08, y:0.1+Double(i)*0.14, width:0.8) }
            corpus.append(.init(id:"N-\(kind)-\(index)",kind:kind,split:index % 4 == 0 ? "holdout" : "dev",
                                capturedAt:capture,timeZone:zone,
                                truth:.init(payment:kind == "pending" || kind == "checkout",amountMinor:(kind == "pending" || kind == "checkout") ? Int(price.dropFirst(3).replacingOccurrences(of:".",with:"")) : nil,merchant:nil,occurredAt:nil,reference:nil),lines:lines))
        }
        return corpus
    }

    static func fixtures() throws -> [G0Screen] {
        let urls = Bundle.module.urls(forResourcesWithExtension:"json",subdirectory:nil) ?? []
        return try urls.map { try JSONDecoder().decode(G0Screen.self, from:Data(contentsOf:$0)) }.sorted { $0.id < $1.id }
    }

    static func bytes(_ screens: [G0Screen]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(screens)
    }
}
