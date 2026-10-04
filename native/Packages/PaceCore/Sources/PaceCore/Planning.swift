/// Port of `noted.planning`.
///
/// - Cycle: monthly payday anchor N (1–31), from day N to the day before day N
///   next month; N past a month's end clamps to the last day. N = 1 is a
///   calendar month. No business-day or holiday adjustment in V1.
/// - Planning income = actual income + expected rule occurrences in the cycle
///   not yet materialised by a linked transaction. Nothing is counted twice.
/// - Left per day divides what is left by the days remaining, today included.
public struct Cycle: Equatable, Sendable {
    public let start: LocalDate
    public let end: LocalDate

    public var days: Int { start.days(until: end) + 1 }

    public func contains(_ date: LocalDate) -> Bool { start <= date && date <= end }

    public static func containing(_ day: LocalDate, anchorDay: Int) -> Cycle {
        precondition((1...31).contains(anchorDay), "payday anchor must be 1-31")
        var start = anchored(day.year, day.month, anchorDay)
        if day < start {
            let (year, month) = addMonths(day.year, day.month, -1)
            start = anchored(year, month, anchorDay)
        }
        let (nextYear, nextMonth) = addMonths(start.year, start.month, 1)
        return Cycle(start: start, end: anchored(nextYear, nextMonth, anchorDay).adding(days: -1))
    }

    static func anchored(_ year: Int, _ month: Int, _ day: Int) -> LocalDate {
        LocalDate(year: year, month: month, day: min(day, LocalDate.daysIn(year: year, month: month)))!
    }

    static func addMonths(_ year: Int, _ month: Int, _ delta: Int) -> (Int, Int) {
        let index = year * 12 + (month - 1) + delta
        let wrapped = ((index % 12) + 12) % 12
        return ((index - wrapped) / 12, wrapped + 1)
    }
}

public enum RuleKind: String, Codable, Sendable { case income, expense, contribution }

/// A recurring monthly rule on day N (clamped to month end). It is used
/// for the salary.
public struct MonthlyRule: Codable, Equatable, Sendable {
    public var id: String
    public var kind: RuleKind
    public var amountMinor: Int
    public var dayOfMonth: Int
    public var start: LocalDate
    public var end: LocalDate?

    public init(id: String, kind: RuleKind, amountMinor: Int, dayOfMonth: Int, start: LocalDate, end: LocalDate? = nil) {
        self.id = id
        self.kind = kind
        self.amountMinor = amountMinor
        self.dayOfMonth = dayOfMonth
        self.start = start
        self.end = end
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, start, end
        case amountMinor = "amount_minor", dayOfMonth = "day_of_month"
    }

    public func occurrences(from start: LocalDate, through end: LocalDate) -> [LocalDate] {
        var result: [LocalDate] = []
        var (year, month) = (start.year, start.month)
        while LocalDate(year: year, month: month, day: 1)! <= end {
            let occurrence = Cycle.anchored(year, month, dayOfMonth)
            if start <= occurrence, occurrence <= end, occurrence >= self.start,
               self.end.map({ occurrence <= $0 }) ?? true {
                result.append(occurrence)
            }
            (year, month) = Cycle.addMonths(year, month, 1)
        }
        return result
    }
}

public enum SavingsMode: String, Codable, Sendable { case fixed, percentage }

public struct PlanParameters: Codable, Equatable, Sendable {
    public var anchorDay: Int
    public var savingsMode: SavingsMode
    public var savingsTargetMinor: Int
    public var savingsBasisPoints: Int
    public var fixedCommitmentsMinor: Int

    public init(anchorDay: Int, savingsMode: SavingsMode = .fixed, savingsTargetMinor: Int = 0,
                savingsBasisPoints: Int = 0, fixedCommitmentsMinor: Int = 0) {
        self.anchorDay = anchorDay
        self.savingsMode = savingsMode
        self.savingsTargetMinor = savingsTargetMinor
        self.savingsBasisPoints = savingsBasisPoints
        self.fixedCommitmentsMinor = fixedCommitmentsMinor
    }

    enum CodingKeys: String, CodingKey {
        case anchorDay = "anchor_day", savingsMode = "savings_mode", savingsTargetMinor = "savings_target_minor"
        case savingsBasisPoints = "savings_basis_points", fixedCommitmentsMinor = "fixed_commitments_minor"
    }
}

public struct ExpectedOccurrence: Equatable, Sendable {
    public let ruleID: String
    public let date: LocalDate
    public let amountMinor: Int
}

public struct CyclePlan: Equatable, Sendable {
    public let cycle: Cycle
    public let asOf: LocalDate
    public let daysElapsed: Int
    public let daysLeftIncludingToday: Int
    public let actual: FinancialSummary
    public let expectedIncomeMinor: Int
    public let expectedOccurrences: [ExpectedOccurrence]
    public let planningIncomeMinor: Int
    public let savingsTargetMinor: Int
    public let remainingToSetAsideMinor: Int
    public let plannedSpendableMinor: Int
    public let discretionaryEnvelopeMinor: Int
    public let leftMinor: Int
    public let leftPerDayMinor: Int
    public let paceMarkerMinor: Int
    public let spendingPerElapsedDayMinor: Int
    public let plannedDailyDiscretionaryMinor: Int
}

public enum Planning {
    /// Nearest sen, exact half-sen rounded up.
    public static func percentage(of amountMinor: Int, basisPoints: Int) -> Int {
        floorDivide(amountMinor * basisPoints + 5_000, 10_000)
    }

    /// Whole sen per day, truncated toward zero.
    public static func wholeMinorPerDay(_ amountMinor: Int, days: Int) -> Int {
        guard days > 0 else { return 0 }
        return amountMinor >= 0 ? amountMinor / days : -((-amountMinor) / days)
    }

    static func floorDivide(_ a: Int, _ b: Int) -> Int {
        let quotient = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
    }

    public static func plan(rows: [LedgerRow], today: LocalDate, rules: [MonthlyRule],
                            parameters: PlanParameters) -> CyclePlan {
        let cycle = Cycle.containing(today, anchorDay: parameters.anchorDay)
        let active = rows.filter { !$0.isDeleted }
        let inCycle = active.filter { row in
            guard let date = row.localDate else { return false }
            return cycle.start <= date && date <= today
        }
        let actual = Finance.summarize(inCycle)
        let linked = Set(active.compactMap { row -> String? in
            guard let rule = row.recurringRuleID, let date = row.occurrenceDate else { return nil }
            return "\(rule)|\(date.iso)"
        })
        var expected: [ExpectedOccurrence] = []
        for rule in rules where rule.kind == .income {
            for occurrence in rule.occurrences(from: cycle.start, through: cycle.end)
            where !linked.contains("\(rule.id)|\(occurrence.iso)") {
                expected.append(ExpectedOccurrence(ruleID: rule.id, date: occurrence, amountMinor: rule.amountMinor))
            }
        }
        let expectedIncome = expected.reduce(0) { $0 + $1.amountMinor }
        let planningIncome = actual.income + expectedIncome
        let savingsTarget = parameters.savingsMode == .fixed
            ? parameters.savingsTargetMinor
            : percentage(of: planningIncome, basisPoints: parameters.savingsBasisPoints)
        let plannedSpendable = planningIncome - savingsTarget
        let envelope = plannedSpendable - parameters.fixedCommitmentsMinor
        let left = envelope - actual.spending
        let daysElapsed = cycle.start.days(until: today) + 1
        let daysLeft = today.days(until: cycle.end) + 1
        return CyclePlan(
            cycle: cycle, asOf: today, daysElapsed: daysElapsed, daysLeftIncludingToday: daysLeft,
            actual: actual, expectedIncomeMinor: expectedIncome, expectedOccurrences: expected,
            planningIncomeMinor: planningIncome, savingsTargetMinor: savingsTarget,
            remainingToSetAsideMinor: savingsTarget - actual.contributions,
            plannedSpendableMinor: plannedSpendable, discretionaryEnvelopeMinor: envelope,
            leftMinor: left, leftPerDayMinor: wholeMinorPerDay(left, days: daysLeft),
            paceMarkerMinor: wholeMinorPerDay(envelope * daysElapsed, days: cycle.days),
            spendingPerElapsedDayMinor: wholeMinorPerDay(actual.spending, days: daysElapsed),
            plannedDailyDiscretionaryMinor: wholeMinorPerDay(envelope, days: cycle.days))
    }
}
