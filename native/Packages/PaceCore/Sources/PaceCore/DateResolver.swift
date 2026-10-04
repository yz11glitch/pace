import Foundation

/// Port of `noted.dates`: fail-closed resolution of date and period
/// expressions. Numeric dates are day first (Pace's financial locale), and the
/// capture zone is explicit — never the device region.
public enum DateResolver {
    public struct Resolved: Equatable, Sendable {
        public let occurredAt: Instant
        public let localDate: LocalDate
    }

    static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august",
                             "september", "october", "november", "december"]
    static let monthAbbreviations = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    static let months: [String: Int] = {
        var result: [String: Int] = [:]
        for (index, name) in monthNames.enumerated() { result[name] = index + 1 }
        for (index, name) in monthAbbreviations.enumerated() where result[name] == nil { result[name] = index + 1 }
        return result
    }()
    static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    private static let monthAlternation = (monthNames + monthAbbreviations).joined(separator: "|")
    static let lastWeekday = PyRegex(#"last\s+("# + weekdays.joined(separator: "|") + ")")
    static let numeric = PyRegex(#"(\d{1,2})([/.-])(\d{1,2})(?:\2(\d{2}|\d{4}))?"#)
    static let explicit = PyRegex(#"(?:(\d{1,2})\s+)?("# + monthAlternation + #")(?:\s+(\d{4}))?"#)
    static let lastDays = PyRegex(#"last\s+(\d+)\s+days"#)
    static let monthPeriod = PyRegex("(" + monthAlternation + #")(?:\s+(\d{4}))?"#)

    /// Python `str.strip(chars)`.
    static func strip(_ text: String, _ characters: Set<Character>) -> String {
        var slice = Substring(text)
        while let first = slice.first, characters.contains(first) { slice.removeFirst() }
        while let last = slice.last, characters.contains(last) { slice.removeLast() }
        return String(slice)
    }

    public static func resolveDate(_ expr: String, capturedAt: Instant, zone: Zone) -> Resolved? {
        let (local, fold) = zone.local(capturedAt)
        let value = strip(canonicalText(expr), [" ", ".", ",", "!", "?"])

        // Wall-clock arithmetic on the same time of day; the result has fold 0.
        func shifted(days: Int) -> Resolved {
            var wall = local
            wall.date = local.date.adding(days: -days)
            return Resolved(occurredAt: zone.instant(for: wall, fold: 0), localDate: wall.date)
        }
        // `datetime.combine(target, local.timetz())` keeps the captured fold.
        func combined(_ date: LocalDate) -> Resolved {
            var wall = local
            wall.date = date
            return Resolved(occurredAt: zone.instant(for: wall, fold: fold), localDate: date)
        }

        let offsets = ["just now": 0, "earlier": 0, "today": 0, "yesterday": 1, "two days ago": 2]
        if let days = offsets[value] {
            // Same-day expressions keep the captured instant.
            return days == 0 ? Resolved(occurredAt: capturedAt, localDate: local.date) : shifted(days: days)
        }
        if let match = lastWeekday.fullMatch(value), let target = weekdays.firstIndex(of: match.group(1)!) {
            let back = ((local.date.weekday - target) % 7 + 7) % 7
            return shifted(days: back == 0 ? 7 : back)
        }
        if let match = numeric.fullMatch(strip(expr, [" ", ",", "!", "?"])) {
            var year = local.date.year
            if let yearText = match.group(4) {
                year = pyInt(yearText)! + (yearText.count == 2 ? 2000 : 0)
            }
            guard let date = LocalDate(year: year, month: pyInt(match.group(3)!)!, day: pyInt(match.group(1)!)!) else { return nil }
            return combined(date)
        }
        guard let match = explicit.fullMatch(value), let dayText = match.group(1) else { return nil }
        let year = match.group(3).flatMap(pyInt) ?? local.date.year
        guard let date = LocalDate(year: year, month: months[match.group(2)!]!, day: pyInt(dayText)!) else { return nil }
        return combined(date)
    }

    public static func resolvePeriod(_ expr: String, capturedAt: Instant, zone: Zone) -> (start: LocalDate, end: LocalDate)? {
        let today = zone.local(capturedAt).time.date
        let value = strip(canonicalText(expr), [" ", ".", ",", "!", "?"])
        func monthBounds(_ year: Int, _ month: Int) -> (LocalDate, LocalDate) {
            (LocalDate(year: year, month: month, day: 1)!,
             LocalDate(year: year, month: month, day: LocalDate.daysIn(year: year, month: month))!)
        }
        switch value {
        case "today": return (today, today)
        case "yesterday": return (today.adding(days: -1), today.adding(days: -1))
        case "this week": return (today.adding(days: -today.weekday), today)
        case "last week":
            let end = today.adding(days: -(today.weekday + 1))
            return (end.adding(days: -6), end)
        case "this month": return (LocalDate(year: today.year, month: today.month, day: 1)!, today)
        case "last month":
            let previousEnd = LocalDate(year: today.year, month: today.month, day: 1)!.adding(days: -1)
            return monthBounds(previousEnd.year, previousEnd.month)
        case "this year": return (LocalDate(year: today.year, month: 1, day: 1)!, today)
        default: break
        }
        if let match = lastDays.fullMatch(value) {
            guard let count = pyInt(match.group(1)!), count > 0 else { return nil }
            return (today.adding(days: -(count - 1)), today)
        }
        if let match = monthPeriod.fullMatch(value) {
            let year = match.group(2).flatMap(pyInt) ?? today.year
            guard (1...9999).contains(year) else { return nil }
            let (start, end) = monthBounds(year, months[match.group(1)!]!)
            return (start, start <= today && today <= end ? min(end, today) : end)
        }
        return nil
    }
}
