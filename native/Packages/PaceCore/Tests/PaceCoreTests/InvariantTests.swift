import Foundation
import Testing
@testable import PaceCore

/// The eight financial invariants (see `Finance`), checked over random ledgers.
@Suite("Financial invariants")
struct InvariantTests {
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    static func ledger(_ generator: inout SeededGenerator) -> [LedgerRow] {
        (0..<Int.random(in: 0...40, using: &generator)).map { _ in
            let type = TransactionType.allCases.randomElement(using: &generator)!
            return LedgerRow(type: type, amountMinor: Int.random(in: 1...maximumAmountMinor, using: &generator),
                             category: type == .contribution ? nil : EntryRules.categories.randomElement(using: &generator),
                             merchant: ["Grab", nil, "Mamak"].randomElement(using: &generator)!,
                             isDeleted: Int.random(in: 0..<10, using: &generator) == 0)
        }
    }

    @Test("all eight invariants hold on 2,000 random ledgers")
    func invariants() {
        var generator = SeededGenerator(state: 20_260_926)
        for _ in 0..<2_000 {
            let rows = Self.ledger(&generator)
            let active = rows.filter { !$0.isDeleted }
            let s = Finance.summarize(rows)
            let expenses = active.filter { $0.type == .expense }.reduce(0) { $0 + $1.amountMinor }
            let refunds = active.filter { $0.type == .refund }.reduce(0) { $0 + $1.amountMinor }
            #expect(s.spending == expenses - refunds)                                   // 1
            #expect(s.retained == s.income - s.spending)                                // 2
            #expect(s.unallocatedSurplus == s.retained - s.contributions)               // 3
            #expect(s.spendable == s.income - s.contributions)                          // 4
            #expect(s.retained == s.contributions + s.unallocatedSurplus)               // 5
            #expect(s.savingsRate == (s.income > 0 ? Double(s.retained) / Double(s.income) : nil))            // 6
            #expect(s.contributionRate == (s.income > 0 ? Double(s.contributions) / Double(s.income) : nil))  // 7
            // 8: refunds never add to income; deleted rows never count.
            #expect(s.income == active.filter { $0.type == .income }.reduce(0) { $0 + $1.amountMinor })
            #expect(Finance.summarize(active) == s)
            #expect(rows.allSatisfy { $0.type.acceptsCategory($0.category) })
        }
    }

    @Test("category is null exactly for contributions")
    func categoryRule() {
        #expect(TransactionType.contribution.acceptsCategory(nil))
        #expect(!TransactionType.contribution.acceptsCategory("Other"))
        for type in [TransactionType.expense, .income, .refund] {
            #expect(type.acceptsCategory("Other"))
            #expect(!type.acceptsCategory(nil))
        }
    }

    @Test("zero income makes rates unavailable, not zero")
    func zeroIncome() {
        let s = Finance.summarize([LedgerRow(type: .expense, amountMinor: 100, category: "Other")])
        #expect(s.savingsRate == nil && s.contributionRate == nil)
    }
}

/// Pace's financial locale is independent of the device.
@Suite("Financial locale independence")
struct LocaleIndependenceTests {
    @Test("money language is fixed: RM prefix, full cents, en-MY grouping")
    func money() {
        let format = MoneyFormat()
        #expect(format.string(1800) == "RM 18.00")
        #expect(format.string(350_000) == "RM 3,500.00")
        #expect(format.string(10_000_000_000) == "RM 100,000,000.00")
        #expect(format.string(-1_250) == "\u{2212}RM 12.50")
        #expect(format.flow(1800, type: .expense) == "\u{2212} RM 18.00")
        #expect(format.flow(260_000, type: .income) == "+ RM 2,600.00")
        #expect(format.flow(2_850, type: .refund) == "+ RM 28.50")
        #expect(format.flow(50_000, type: .contribution) == "\u{2191} RM 500.00")
    }

    @Test("spoken money and week start follow the financial locale")
    func accessibilityMoney() {
        let format = MoneyFormat()
        #expect(format.spoken(0) == "0 ringgit")
        #expect(format.spoken(1_482_50) == "1482 ringgit 50")
        #expect(format.spoken(-18_00) == "minus 18 ringgit")
        #expect(format.spokenFlow(2_850, type: .refund) == "plus 28 ringgit 50")
        #expect(format.spokenFlow(500_00, type: .contribution) == "set aside 500 ringgit")
        #expect(FinancialLocale.malaysia.weekStart == 0)
    }

    @Test("calendar month follows financial week start")
    func calendarWeekStart() {
        let monday = CalendarGrid.days(year: 2026, month: 9, weekStart: 0)
        #expect(monday.count == 35)
        #expect(monday[0] == nil)
        #expect(monday[1]?.iso == "2026-09-01")
        let sunday = CalendarGrid.days(year: 2026, month: 9, weekStart: 6)
        #expect(sunday[2]?.iso == "2026-09-01")
    }

    @Test("numeric dates are day first whatever the zone")
    func dayFirst() {
        let captured = Instant(iso: "2026-09-26T09:30:00+08:00")!
        for zone in ["Asia/Kuala_Lumpur", "America/New_York", "UTC"] {
            let resolved = DateResolver.resolveDate("3/4", capturedAt: captured, zone: Zone(identifier: zone)!)
            #expect(resolved?.localDate.iso == "2026-04-03")
        }
    }

    /// Structural guard: no financial code may read device locale, calendar or
    /// formatters. Region changes then cannot alter money, dates or cycles.
    @Test("engine sources never consult device locale, calendar or formatters")
    func noDeviceLocale() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let forbidden = ["Locale.current", "Locale.autoupdatingCurrent", "Calendar.current", "Calendar.autoupdatingCurrent",
                         "NumberFormatter", "DateFormatter", "TimeZone.current", ".formatted(", "FormatStyle"]
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                #expect(!text.contains(token), "\(file.lastPathComponent) uses \(token)")
            }
        }
    }
}

@Suite("Pasted money input")
struct PastedMoneyInputTests {
    @Test("typed amounts fail closed instead of silently truncating fractions")
    func excessiveFraction() {
        #expect(Keypad.amountMinor("12.345") == 0)
        #expect(Keypad.amountMinor("12.34") == 1_234)
        #expect(Keypad.amountMinor(".5") == 50)
        #expect(Keypad.amountMinor("92233720368547759") == 0)
    }
}
