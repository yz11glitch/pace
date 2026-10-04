import Foundation

/// Only OCR evidence and the interpretation clock are exported. No image or app state is retained.
public struct ScreenshotFixture: Codable, Sendable, Equatable {
    public let capturedAt: String
    public let timeZone: String
    public let lines: [ScreenshotTextLine]

    public init(capturedAt: Instant, timeZone: String, lines: [ScreenshotTextLine]) {
        self.capturedAt = capturedAt.isoUTC
        self.timeZone = timeZone
        self.lines = lines
    }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public enum ScreenshotObservationDiagnostics {
    public static let displayLimit = 120
    public static let retainedByteLimit = 8_192

    /// Vision's first reading stays authoritative. Retain the other top-three readings
    /// only when one of those readings contains a digit.
    public static func alternates(from topCandidates: [String]) -> [String] {
        let top = Array(topCandidates.prefix(3))
        guard top.contains(where: { $0.contains(where: \.isNumber) }) else { return [] }
        return Array(top.dropFirst())
    }

    /// Bound the Debug database payload. A truncated export is visibly marked in the Lab.
    public static func retainedFixture(capturedAt: Instant, timeZone: String,
                                       lines: [ScreenshotTextLine]) throws -> (fixture: ScreenshotFixture, truncated: Bool) {
        var retained = Array(lines.prefix(displayLimit))
        while true {
            let fixture = ScreenshotFixture(capturedAt: capturedAt, timeZone: timeZone, lines: retained)
            if try fixture.json().utf8.count <= retainedByteLimit {
                return (fixture, retained.count < lines.count)
            }
            retained.removeLast()
        }
    }

    public static func display(_ lines: [ScreenshotTextLine]) -> String {
        lines.map { line in
            let alternate = line.alternates.isEmpty ? "" : " | alternates: " + line.alternates.joined(separator: " ; ")
            return String(format: "%.3f (%.3f, %.3f, %.3f, %.3f) [%@]: %@%@",
                          locale: Locale(identifier: "en_US_POSIX"),
                          line.confidence, line.x, line.y, line.width, line.height,
                          line.pass, line.text, alternate)
        }.joined(separator: "\n")
    }
}
