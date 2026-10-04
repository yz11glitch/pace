import Foundation
import Testing
@testable import PaceCore

@Suite("Screenshot diagnostics")
struct ScreenshotDiagnosticsTests {
    @Test func olderLinesDecodeWithDefaults() throws {
        let old = #"{"text":"RM 60.00","confidence":0.97,"x":0.123,"y":0.234,"width":0.345,"height":0.045}"#
        let line = try JSONDecoder().decode(ScreenshotTextLine.self, from: Data(old.utf8))
        #expect(line.pass == "primary")
        #expect(line.alternates.isEmpty)
        #expect(line.text == "RM 60.00")
    }

    @Test func metadataAndFixtureRoundTripWithoutOtherState() throws {
        let line = ScreenshotTextLine("RM 6O.OO", confidence: 0.81, x: 0.1234, y: 0.2345,
                                      width: 0.3456, height: 0.0456, pass: "primary",
                                      alternates: ["RM 60.00", "RM 6O.00"])
        let capturedAt = Instant(seconds: 1_795_000_000)
        let fixture = ScreenshotFixture(capturedAt: capturedAt, timeZone: "Asia/Kuala_Lumpur", lines: [line])
        let json = try fixture.json()
        let decoded = try JSONDecoder().decode(ScreenshotFixture.self, from: Data(json.utf8))
        #expect(decoded == fixture)
        #expect(json.contains("\"capturedAt\""))
        #expect(json.contains("\"timeZone\""))
        #expect(json.contains("\"alternates\""))
        #expect(!json.contains("imageHash"))
        #expect(!json.contains("merchantMemory"))
    }

    @Test func onlyDigitBoxesRetainTopThreeReadings() {
        #expect(ScreenshotObservationDiagnostics.alternates(from: ["RM 6O.OO", "RM 60.00", "RM 6O.00", "RM 60.0O"])
                == ["RM 60.00", "RM 6O.00"])
        #expect(ScreenshotObservationDiagnostics.alternates(from: ["Completed", "CompIeted"]).isEmpty)
        #expect(ScreenshotObservationDiagnostics.alternates(from: ["RM 6O.OO", "RM 60.00"])
                == ["RM 60.00"])
    }

    @Test func boundedDiagnosticsDisplayAndInterpretationAreUnchanged() throws {
        let capturedAt = Instant(seconds: 1_795_000_000)
        let lines = [
            ScreenshotTextLine("Payment successful", y: 0.1),
            ScreenshotTextLine("RM 23.90", y: 0.2),
            ScreenshotTextLine("Paid to ZUS Coffee", y: 0.3)]
        let enriched = lines.map {
            ScreenshotTextLine($0.text, confidence: $0.confidence, x: $0.x, y: $0.y,
                               width: $0.width, height: $0.height, pass: "primary",
                               alternates: ["other 123"])
        }
        let interpreter = ScreenshotInterpreter()
        let before = interpreter.interpret(lines, capturedAt: capturedAt, timeZone: "Asia/Kuala_Lumpur")
        let after = interpreter.interpret(enriched, capturedAt: capturedAt, timeZone: "Asia/Kuala_Lumpur")
        #expect(before.detection == after.detection)
        #expect(before.amountMinor == after.amountMinor)
        #expect(before.amountTrust == after.amountTrust)
        #expect(before.merchant == after.merchant)
        #expect(before.reference == after.reference)
        #expect(before.occurredAt == after.occurredAt)
        #expect(before.dateTrust == after.dateTrust)
        #expect(before.statusClean == after.statusClean)
        #expect(before.reason == after.reason)
        let stored = try ScreenshotObservationDiagnostics.retainedFixture(
            capturedAt: capturedAt, timeZone: "Asia/Kuala_Lumpur", lines: enriched)
        #expect(!stored.truncated)
        #expect(stored.fixture.lines == enriched)
        #expect(ScreenshotObservationDiagnostics.display(enriched).contains("0.200, 1.000, 0.030"))
    }

    @Test func observationLimitIsReported() throws {
        let lines = (0..<125).map { ScreenshotTextLine("Line \($0)", y: Double($0) / 125) }
        let stored = try ScreenshotObservationDiagnostics.retainedFixture(
            capturedAt: Instant(seconds: 1_795_000_000), timeZone: "Asia/Kuala_Lumpur", lines: lines)
        #expect(stored.truncated)
        #expect(stored.fixture.lines.count <= 120)
        #expect(try stored.fixture.json().utf8.count <= 8_192)
    }
}
