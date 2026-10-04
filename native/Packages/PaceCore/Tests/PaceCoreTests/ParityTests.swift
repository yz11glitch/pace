import Foundation
import Testing
@testable import PaceCore

/// 100% parity with the Python/JS oracles on every exported fixture.
@Suite("Golden-fixture parity")
struct ParityTests {
    @Test("amounts: every field of every resolution matches the oracle")
    func amounts() {
        let records = GoldenFixtures.records("amounts.jsonl")
        #expect(records.count >= 30)
        var failures: [String] = []
        for record in records {
            let priors = record.isNull("priors") ? nil : GoldenFixtures.decode(AmountPriors.self, record["priors"]!)
            let got = AmountNormalizer.recover(record.string("text")!, priors: priors, wholeBare: record.bool("whole_bare"))
            let want = record.dict("expect")!
            let matches = got.amountMinor == want.int("amount_minor")
                && got.currency == want.string("currency")
                && got.provisionalTier == want.string("provisional_tier")
                && got.rung == want.int("rung")
                && got.surfaceForm == want.string("surface_form")
                && got.surfaceClass == want.string("surface_class")
                && got.alternativesMinor == (want["alternatives_minor"] as! [NSNumber]).map(\.intValue)
                && got.reason == want.string("reason")
            if !matches { failures.append("\(record.string("id")!) \(record.string("text")!.debugDescription): got \(got), want \(want)") }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) mismatches:\n" + failures.prefix(20).joined(separator: "\n")))
    }

    @Test("merchant keys and canonical text")
    func textKeys() {
        for record in GoldenFixtures.records("text_keys.jsonl") {
            let input = record.string("input")!
            #expect(merchantKey(input) == record.string("merchant_key"), "merchant_key(\(input.debugDescription))")
            #expect(canonicalText(input) == record.string("canonical_text"), "canonical_text(\(input.debugDescription))")
        }
    }

    @Test("dates and periods across zones, DST gaps and repeated hours")
    func dates() {
        var failures: [String] = []
        let records = GoldenFixtures.records("dates.jsonl")
        for record in records {
            let captured = Instant(iso: record.string("captured_at")!)!
            let zone = Zone(identifier: record.string("tz")!)!
            let expr = record.string("expr")!
            let want = record.dict("expect")
            let summary: [String: String]?
            if record.string("kind") == "date" {
                summary = DateResolver.resolveDate(expr, capturedAt: captured, zone: zone).map {
                    ["occurred_at_utc": $0.occurredAt.isoUTC, "local_date": $0.localDate.iso]
                }
            } else {
                summary = DateResolver.resolvePeriod(expr, capturedAt: captured, zone: zone).map {
                    ["start": $0.start.iso, "end": $0.end.iso]
                }
            }
            if summary != (want as? [String: String]) {
                failures.append("\(record.string("id")!) \(record.string("kind")!) \(expr.debugDescription) @\(record.string("captured_at")!) \(record.string("tz")!): got \(String(describing: summary)) want \(String(describing: want))")
            }
        }
        #expect(records.count > 1000)
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) mismatches:\n" + failures.prefix(20).joined(separator: "\n")))
    }

    static func ledgerRow(_ value: [String: Any]) -> LedgerRow {
        LedgerRow(type: TransactionType(rawValue: value.string("type")!)!, amountMinor: value.int("amount_minor")!,
                  category: value.string("category"), merchant: value.string("merchant"),
                  localDate: value.string("local_date").flatMap(LocalDate.init(iso:)),
                  isDeleted: !value.isNull("deleted_at"),
                  recurringRuleID: value.string("recurring_rule_id"),
                  occurrenceDate: value.string("occurrence_date").flatMap(LocalDate.init(iso:)))
    }

    static func summaryMismatches(_ got: FinancialSummary, _ want: [String: Any]) -> [String] {
        var fields: [String] = []
        if got.income != want.int("income") { fields.append("income") }
        if got.spending != want.int("spending") { fields.append("spending") }
        if got.contributions != want.int("contributions") { fields.append("contributions") }
        if got.retained != want.int("retained") { fields.append("retained") }
        if got.unallocatedSurplus != want.int("unallocated_surplus") { fields.append("unallocated_surplus") }
        if got.spendable != want.int("spendable") { fields.append("spendable") }
        if got.savingsRate != (want["savings_rate"] as? NSNumber)?.doubleValue { fields.append("savings_rate") }
        if got.contributionRate != (want["contribution_rate"] as? NSNumber)?.doubleValue { fields.append("contribution_rate") }
        return fields
    }

    static func summaryMatches(_ got: FinancialSummary, _ want: [String: Any]) -> Bool {
        summaryMismatches(got, want).isEmpty
    }

    @Test("finance identities, category and merchant totals")
    func finance() {
        for record in GoldenFixtures.records("finance.jsonl") {
            let rows = (record["rows"] as! [[String: Any]]).map(Self.ledgerRow)
            let want = record.dict("expect")!
            let summary = Finance.summarize(rows)
            #expect(Self.summaryMatches(summary, want.dict("summary")!),
                    Comment(rawValue: "\(record.string("id")!): \(Self.summaryMismatches(summary, want.dict("summary")!))"))
            #expect(Finance.categoryTotals(rows) == (want["category_totals"] as! [String: NSNumber]).mapValues(\.intValue))
            #expect(Finance.merchantSpendingTotals(rows) == (want["merchant_spending_totals"] as! [String: NSNumber]).mapValues(\.intValue))
        }
    }

    @Test("payday cycles and cycle plans")
    func planning() {
        var failures: [String] = []
        for record in GoldenFixtures.records("planning.jsonl") {
            let id = record.string("id")!
            let today = LocalDate(iso: record.string("today")!)!
            let want = record.dict("expect")!
            if record.string("kind") == "cycle" {
                let cycle = Cycle.containing(today, anchorDay: record.int("anchor_day")!)
                if cycle.start.iso != want.string("start") || cycle.end.iso != want.string("end") || cycle.days != want.int("days") {
                    failures.append("\(id): got \(cycle) want \(want)")
                }
                continue
            }
            let rows = (record["rows"] as! [[String: Any]]).map(Self.ledgerRow)
            let rules = GoldenFixtures.decode([MonthlyRule].self, record["rules"]!)
            let parameters = GoldenFixtures.decode(PlanParameters.self, record["params"]!)
            let plan = Planning.plan(rows: rows, today: today, rules: rules, parameters: parameters)
            let cycle = want.dict("cycle")!
            let occurrences = (want["expected_occurrences"] as! [[String: Any]]).map {
                ExpectedOccurrence(ruleID: $0.string("rule_id")!, date: LocalDate(iso: $0.string("date")!)!,
                                   amountMinor: $0.int("amount_minor")!)
            }
            let ok = plan.cycle.start.iso == cycle.string("start_date") && plan.cycle.end.iso == cycle.string("end_date")
                && plan.cycle.days == cycle.int("days_in_cycle") && plan.daysElapsed == cycle.int("days_elapsed")
                && plan.daysLeftIncludingToday == cycle.int("days_left_including_today")
                && Self.summaryMatches(plan.actual, want.dict("actual")!)
                && plan.expectedIncomeMinor == want.int("expected_income_minor")
                && plan.expectedOccurrences == occurrences
                && plan.planningIncomeMinor == want.int("planning_income_minor")
                && plan.savingsTargetMinor == want.int("savings_target_minor")
                && plan.remainingToSetAsideMinor == want.int("remaining_to_set_aside_minor")
                && plan.plannedSpendableMinor == want.int("planned_spendable_minor")
                && plan.discretionaryEnvelopeMinor == want.int("discretionary_envelope_minor")
                && plan.leftMinor == want.int("left_minor") && plan.leftPerDayMinor == want.int("left_per_day_minor")
                && plan.paceMarkerMinor == want.int("pace_marker_minor")
                && plan.spendingPerElapsedDayMinor == want.int("spending_per_elapsed_day_minor")
                && plan.plannedDailyDiscretionaryMinor == want.int("planned_daily_discretionary_minor")
            if !ok { failures.append("\(id): got \(plan) want \(want)") }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) mismatches:\n" + failures.prefix(5).joined(separator: "\n")))
    }

    @Test("keypad construction matches ui-core.js")
    func keypad() {
        for record in GoldenFixtures.records("keypad.jsonl") {
            let value = (record["keys"] as! [String]).reduce("") { current, key in
                switch key {
                case "del": Keypad.apply(.delete, to: current)
                case ".": Keypad.apply(.point, to: current)
                default: Keypad.apply(.digit(Int(key)!), to: current)
                }
            }
            #expect(value == record.string("value"), "\(record.string("id")!)")
            #expect(Keypad.amountMinor(value) == record.int("amount_minor"), "\(record.string("id")!)")
            #expect(Keypad.isValid(value) == record.bool("valid"), "\(record.string("id")!)")
        }
    }

    @Test("money formatting matches the PWA money language")
    func money() {
        for record in GoldenFixtures.records("money.jsonl") {
            #expect(MoneyFormat().string(record.int("minor")!) == record.string("text"))
        }
    }

    @Test("note → merchant/description mapping")
    func noteFields() {
        for record in GoldenFixtures.records("note_fields.jsonl") {
            let got = EntryRules.noteFields(record.string("note")!)
            let want = record.dict("expect")!
            #expect(got.merchant == want.string("merchant") && got.description == want.string("description"),
                    "\(record.string("note")!.debugDescription)")
        }
    }

    @Test("category defaults and choices by type")
    func categories() {
        for record in GoldenFixtures.records("categories.jsonl") {
            let type = TransactionType(rawValue: record.string("type")!)!
            let defaults = record.dict("defaults")!
            let selected: String? = defaults.bool("selected") ? "Other" : record.string("selected")
            let remembered: String? = defaults.bool("remembered") ? "Other" : record.string("remembered")
            #expect(EntryRules.category(for: type, selected: selected, remembered: remembered) == record.string("category"),
                    "\(record.string("id")!)")
            #expect(EntryRules.categoryChoices(for: type) == record["choices"] as! [String])
        }
    }
}
