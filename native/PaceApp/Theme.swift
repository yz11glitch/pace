import CoreText
import PaceCore
import SwiftUI
import UIKit

/// Pace visual identity:
/// terracotta = action/spend, money-green = received, warm cream surfaces.
nonisolated enum Theme {
    static let background = Color("Canvas")
    static let card = Color("Sheet")
    static let surface2 = Color("Well")
    static let ink = Color("Ink")
    static let ink2 = Color("Ink2")
    static let ink3 = Color("Muted")
    static let hair = Color("Separator")
    static let boundary = Color("Boundary")
    static let brand = Color("Brand")
    static let accent = Color("Action")
    static let onAccent = Color("OnAction")
    static let positive = Color("Positive")
    static let warn = Color("Danger")
    static let warnWell = Color("DangerWell")

    static let bodyFont = "HankenGrotesk-Regular"
    static let displayFont = "BricolageGrotesque96ptBold-Regular"

    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(bodyFont, size: size, relativeTo: style).weight(weight)
    }

    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom(displayFont, size: size, relativeTo: style)
    }

    /// Registers the bundled OFL fonts (converted from the PWA's woff2 files).
    static func registerFonts() {
        for name in ["HankenGrotesk", "BricolageGrotesque"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func tint(for type: TransactionType) -> Color {
        switch type {
        case .income, .refund: positive
        case .expense, .contribution: ink
        }
    }
}

/// English, day-first date labels built from `LocalDate` — independent of
/// the device region (`26 Sep 2026`, `Sat 26 Sep`).
enum DateText {
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    static func short(_ date: LocalDate) -> String { "\(date.day) \(months[date.month - 1])" }
    static func long(_ date: LocalDate) -> String { "\(date.day) \(months[date.month - 1]) \(date.year)" }
    static func day(_ date: LocalDate) -> String { "\(weekdays[date.weekday]) \(short(date))" }
    static func range(_ cycle: Cycle) -> String { "\(short(cycle.start)) – \(short(cycle.end))" }

    /// A `LocalDate` ↔ `Date` bridge for the date picker, pinned to UTC so no zone shifts the day.
    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_MY")
        return calendar
    }

    static func date(_ local: LocalDate) -> Date {
        Date(timeIntervalSince1970: Double(local.daysSinceEpoch) * 86_400 + 43_200)
    }

    static func local(_ date: Date) -> LocalDate {
        LocalDate(daysSinceEpoch: Int((date.timeIntervalSince1970 / 86_400).rounded(.down)))
    }
}
