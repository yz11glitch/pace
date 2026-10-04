import Foundation

/// A proleptic-Gregorian calendar date. Pace never uses the device calendar: a
/// device set to another calendar or region must not move a financial date.
public struct LocalDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month),
              (1...LocalDate.daysIn(year: year, month: month)).contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `YYYY-MM-DD` exactly.
    public init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = LocalDate(iso: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid date \(text)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }

    public var iso: String {
        "\(String(format: "%04d", year))-\(String(format: "%02d", month))-\(String(format: "%02d", day))"
    }

    public var description: String { iso }

    public static func isLeap(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }

    public static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 2: isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days since 1970-01-01 (civil-from-days, Howard Hinnant).
    public var daysSinceEpoch: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public init(daysSinceEpoch days: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        self.year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        self.month = month
        self.day = day
    }

    public func adding(days: Int) -> LocalDate { LocalDate(daysSinceEpoch: daysSinceEpoch + days) }

    public func days(until other: LocalDate) -> Int { other.daysSinceEpoch - daysSinceEpoch }

    /// Monday = 0 … Sunday = 6 (Python's `date.weekday()`).
    public var weekday: Int { ((daysSinceEpoch % 7) + 7 + 3) % 7 }

    public var daysInMonth: Int { LocalDate.daysIn(year: year, month: month) }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// A wall-clock time in some zone (no offset attached).
public struct LocalDateTime: Hashable, Sendable {
    public var date: LocalDate
    public var secondOfDay: Int
    public var microsecond: Int

    public init(date: LocalDate, secondOfDay: Int, microsecond: Int = 0) {
        self.date = date
        self.secondOfDay = secondOfDay
        self.microsecond = microsecond
    }

    /// Seconds since the epoch as if this wall time were UTC.
    var naiveSeconds: Int64 { Int64(date.daysSinceEpoch) * 86_400 + Int64(secondOfDay) }
}

/// A point in time with microsecond precision, independent of any zone.
public struct Instant: Hashable, Comparable, Sendable {
    public let seconds: Int64
    public let microsecond: Int

    public init(seconds: Int64, microsecond: Int = 0) {
        self.seconds = seconds
        self.microsecond = microsecond
    }

    public init(_ date: Date) {
        let micros = (date.timeIntervalSince1970 * 1_000_000).rounded()
        let seconds = Int64((micros / 1_000_000).rounded(.down))
        self.init(seconds: seconds, microsecond: Int(micros - Double(seconds) * 1_000_000))
    }

    public var date: Date { Date(timeIntervalSince1970: Double(seconds) + Double(microsecond) / 1_000_000) }

    public static func < (lhs: Instant, rhs: Instant) -> Bool {
        (lhs.seconds, lhs.microsecond) < (rhs.seconds, rhs.microsecond)
    }

    /// Parses an ISO 8601 timestamp with an explicit offset (`Z` or `±HH:MM`),
    /// as written by Python's `isoformat()` and JavaScript's `toISOString()`.
    public init?(iso: String) {
        let text = Array(iso)
        guard text.count >= 20, text[10] == "T" || text[10] == " ",
              let date = LocalDate(iso: String(text[0..<10])) else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= text.count, text[range].allSatisfy(\.isASCIIDigit) else { return nil }
            return Int(String(text[range]))
        }
        guard let hour = number(11..<13), text[13] == ":", let minute = number(14..<16), text[16] == ":",
              let second = number(17..<19), hour < 24, minute < 60, second < 60 else { return nil }
        var index = 19
        var microsecond = 0
        if index < text.count, text[index] == "." {
            var digits = ""
            index += 1
            while index < text.count, text[index].isASCIIDigit { digits.append(text[index]); index += 1 }
            guard !digits.isEmpty else { return nil }
            microsecond = Int(String((digits + "000000").prefix(6)))!
        }
        let offset: Int
        if index < text.count, text[index] == "Z", index + 1 == text.count {
            offset = 0
        } else if index + 6 == text.count, text[index] == "+" || text[index] == "-", text[index + 3] == ":",
                  let hours = number(index + 1..<index + 3), let minutes = number(index + 4..<index + 6) {
            offset = (text[index] == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
        } else {
            return nil
        }
        let wall = LocalDateTime(date: date, secondOfDay: hour * 3600 + minute * 60 + second)
        self.init(seconds: wall.naiveSeconds - Int64(offset), microsecond: microsecond)
    }

    /// Python's `isoformat()` of this instant in UTC, e.g. `2026-09-15T16:05:00+00:00`.
    public var isoUTC: String {
        let days = Int((seconds >= 0 ? seconds : seconds - 86_399) / 86_400)
        let secondOfDay = Int(seconds - Int64(days) * 86_400)
        let date = LocalDate(daysSinceEpoch: days)
        let time = String(format: "%02d:%02d:%02d", secondOfDay / 3600, secondOfDay % 3600 / 60, secondOfDay % 60)
        let fraction = microsecond == 0 ? "" : String(format: ".%06d", microsecond)
        return "\(date.iso)T\(time)\(fraction)+00:00"
    }
}

/// An IANA zone. Only zone rules are used here, never a device locale.
public struct Zone: Sendable {
    public let identifier: String
    private let timeZone: TimeZone

    public init?(identifier: String) {
        guard let timeZone = TimeZone(identifier: identifier) else { return nil }
        self.identifier = identifier
        self.timeZone = timeZone
    }

    public func offset(at instant: Instant) -> Int {
        timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(instant.seconds)))
    }

    /// The wall time at `instant`, with Python's `fold` (1 for the second
    /// occurrence of a repeated wall time).
    public func local(_ instant: Instant) -> (time: LocalDateTime, fold: Int) {
        let naive = instant.seconds + Int64(offset(at: instant))
        let days = Int((naive >= 0 ? naive : naive - 86_399) / 86_400)
        let time = LocalDateTime(date: LocalDate(daysSinceEpoch: days),
                                 secondOfDay: Int(naive - Int64(days) * 86_400),
                                 microsecond: instant.microsecond)
        return (time, self.instant(for: time, fold: 0).seconds == instant.seconds ? 0 : 1)
    }

    /// The instant a wall time denotes, following PEP 495: `fold` 0 picks the
    /// earlier offset for a repeated time and the pre-transition offset for a
    /// skipped time; `fold` 1 picks the later.
    public func instant(for wall: LocalDateTime, fold: Int) -> Instant {
        let naive = wall.naiveSeconds
        let before = offset(at: Instant(seconds: naive - 86_400))
        let after = offset(at: Instant(seconds: naive + 86_400))
        let chosen: Int
        if before == after {
            chosen = before
        } else {
            let earlierValid = offset(at: Instant(seconds: naive - Int64(before))) == before
            let laterValid = offset(at: Instant(seconds: naive - Int64(after))) == after
            switch (earlierValid, laterValid) {
            case (true, true), (false, false): chosen = fold == 0 ? before : after
            case (true, false): chosen = before
            case (false, true): chosen = after
            }
        }
        return Instant(seconds: naive - Int64(chosen), microsecond: wall.microsecond)
    }
}

extension Instant: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = Instant(iso: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid instant"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoUTC)
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
