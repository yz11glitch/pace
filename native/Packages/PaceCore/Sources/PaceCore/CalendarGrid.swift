/// Calendar reporting uses the financial locale's week start, independent of
/// the phone's region. A cell is nil only where the month does not occupy it.
public enum CalendarGrid {
    public static func days(year: Int, month: Int, weekStart: Int) -> [LocalDate?] {
        precondition((0...6).contains(weekStart))
        let first = LocalDate(year: year, month: month, day: 1)!
        let leading = (first.weekday - weekStart + 7) % 7
        let count = LocalDate.daysIn(year: year, month: month)
        var cells: [LocalDate?] = Array(repeating: nil, count: leading)
        cells += (1...count).map { LocalDate(year: year, month: month, day: $0)! }
        cells += Array(repeating: nil, count: (7 - cells.count % 7) % 7)
        return cells
    }
}
