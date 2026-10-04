import Foundation
import Testing
@testable import PaceCore

/// Rebuild with PACE_FM_BENCH_EXPORT=1 swift test --filter ScreenshotFMBenchmarkCorpusTests.
/// The checked-in OCR corpus and DEBUG-only app embedding are compared byte-for-byte.
@Suite("FM screenshot benchmark corpus") struct ScreenshotFMBenchmarkCorpusTests {
    private func benchmarkCase(_ screen: G0Screen, source: String) -> ScreenshotFMBenchmarkCase {
        let isTransaction = screen.kind != "checkout" && screen.truth.payment
        let relations = ScreenshotRelations(ScreenshotSpans(ScreenshotLayout(screen.lines),
            capturedAt: Instant(iso: screen.capturedAt)!, timeZone: screen.timeZone))
        let reference: String?
        if let raw = screen.truth.reference, !raw.hasPrefix("approval:"),
           relations.of(.referencePrimary).isEmpty,
           relations.of(.referenceSecondary).contains(where: { $0.valueText == raw }) {
            reference = "approval:" + raw
        } else { reference = screen.truth.reference }
        return .init(id: screen.id, source: source, kind: screen.kind,
                     capturedAt: screen.capturedAt, timeZone: screen.timeZone, lines: screen.lines,
                     expected: .init(isTransaction: isTransaction,
                                     amountMinor: isTransaction ? screen.truth.amountMinor : nil,
                                     merchant: isTransaction ? screen.truth.merchant : nil,
                                     occurredAt: isTransaction ? screen.truth.occurredAt : nil,
                                     reference: isTransaction ? reference : nil))
    }
    private func manual(_ id: String, _ state: String) -> ScreenshotFMBenchmarkCase {
        let lines = ["Transfer \(state)", "Amount RM 48.30", "Recipient OAK HARBOUR WORKS",
                     "Transaction Date 27/09/2026 14:05", "Transaction ID ZX483018", "Card **** 3127"]
            .enumerated().map { i, text in
                ScreenshotTextLine(text, confidence: 0.96, x: 0.1, y: 0.09 + Double(i)*0.12,
                                   width: 0.75, height: 0.035)
            }
        return .init(id: id, source: "manual-adversarial", kind: state,
                     capturedAt: G0Corpus.capture, timeZone: G0Corpus.zone, lines: lines,
                     expected: .init(isTransaction: true, amountMinor: 4830,
                                     merchant: "OAK HARBOUR WORKS", occurredAt: "2026-09-27T06:05:00Z",
                                     reference: "ZX483018"))
    }
    private func makeCorpus() throws -> ScreenshotFMBenchmarkCorpus {
        let generated = G0Corpus.generated()
        let indexes = Set(stride(from: 0, through: 63, by: 7))
        let positives = generated.filter { screen in
            G0Corpus.archetypes.contains(screen.kind) &&
                (screen.id.split(separator: "-").last.flatMap { Int($0) }.map(indexes.contains) ?? false)
        }.map { benchmarkCase($0, source: $0.split == "dev" ? "generated-development" : "generated-heldout") }
        let negativeKinds = ["overview", "list", "checkout", "promo", "chat", "weather", "product", "pending"]
        let negative = negativeKinds.flatMap { kind in
            generated.filter { $0.kind == kind }.prefix(3).map { benchmarkCase($0, source: "generated-adversarial") }
        }
        let fixtures = try G0Corpus.fixtures()
        let blind = fixtures.filter { $0.split == "blind" }.map { benchmarkCase($0, source: "blind") }
        let physical = fixtures.filter { $0.split == "physical-holdout" }
            .map { benchmarkCase($0, source: "physical-synthetic") }
        return .init(version: "vision-ocr-fm-v1", seed: "0x2026092860",
                     cases: positives + negative + blind + physical +
                        [manual("A-pending", "pending"), manual("A-failed", "failed")])
    }
    @Test func resourceMatchesGenerator() throws {
        let corpus = try makeCorpus()
        #expect(corpus.cases.count == 134)
        #expect(Set(corpus.cases.map(\.id)).count == 134)
        #expect(corpus.cases.filter { $0.source == "generated-development" }.count == 50)
        #expect(corpus.cases.filter { $0.source == "generated-heldout" }.count == 30)
        #expect(corpus.cases.filter { $0.source == "generated-adversarial" }.count == 24)
        #expect(corpus.cases.filter { $0.source == "blind" }.count == 24)
        #expect(corpus.cases.filter { $0.source == "physical-synthetic" }.count == 4)
        #expect(corpus.cases.filter { $0.source == "manual-adversarial" }.count == 2)
        #expect(corpus.cases.filter { !$0.expected.isTransaction }.count >= 25)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(corpus)
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let native = tests.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        // .txt keeps G0's JSON fixture enumeration focused on G0Screen files.
        let resource = tests.appendingPathComponent("Fixtures/FM/screenshot-fm-benchmark-v1.txt")
        let encoded = data.base64EncodedString()
        let chunks = stride(from: 0, to: encoded.count, by: 120).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(120, encoded.count - offset))
            return String(encoded[start..<end])
        }
        let source = """
        #if DEBUG
        import Foundation
        /// Generated by ScreenshotFMBenchmarkCorpusTests. No benchmark fixture is copied into Release.
        enum ScreenshotFMBenchData {
            static let json = Data(base64Encoded: [
        \(chunks.map { "                \"\($0)\"" }.joined(separator: ",\n"))
            ].joined())!
        }
        #endif
        """
        let dataSource = native.appendingPathComponent("PaceApp/ScreenshotFMBench/ScreenshotFMBenchData.swift")
        if ProcessInfo.processInfo.environment["PACE_FM_BENCH_EXPORT"] == "1" {
            try data.write(to: resource, options: .atomic)
            try Data(source.utf8).write(to: dataSource, options: .atomic)
        }
        #expect(try Data(contentsOf: resource) == data)
        #expect(try Data(contentsOf: dataSource) == Data(source.utf8))
        print("FM benchmark corpus: 134 cases, 80 generated positive, 24 generated adversarial, 24 blind, 4 physical synthetic, 2 manual adversarial")
    }

    @Test func g3ComparatorRunsOnExactSelectedCorpus() throws {
        let corpus = try makeCorpus()
        let records = corpus.cases.map { item in
            ScreenshotFMBenchmarkRecord(caseID: item.id, claim: nil, verified: nil,
                g3: ScreenshotFMGrounding.g3Fields(lines: item.lines,
                    capturedAt: Instant(iso: item.capturedAt)!, timeZone: item.timeZone))
        }
        let score = ScreenshotFMBenchmarkSummary(cases: corpus.cases, records: records)
        let positive = corpus.cases.filter(\.expected.isTransaction).count
        #expect(score.g3.amount.total == positive)
        #expect(score.g3.merchant.total == positive)
        #expect(score.g3.date.total == positive)
        #expect(score.g3.reference.total == positive)
        print("FM benchmark G3 comparator: amount \(score.g3.amount.fraction), merchant \(score.g3.merchant.fraction), date \(score.g3.date.fraction), reference \(score.g3.reference.fraction)")
    }
}
