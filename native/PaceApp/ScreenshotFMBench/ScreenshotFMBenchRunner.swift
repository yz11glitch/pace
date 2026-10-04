#if DEBUG
import Foundation
import FoundationModels
import Observation
import PaceCore

private struct FMScreenshotExport: Codable {
    let promptVersion: String
    let schemaVersion: String
    let instructions: String
    let corpus: ScreenshotFMBenchmarkCorpus
    let records: [ScreenshotFMBenchmarkRecord]
    let summary: ScreenshotFMBenchmarkSummary
    let device: String
    let os: String
    let availability: String
    let startedAt: String
    let durationSeconds: Double?
}

/// Memory-only debug experiment. No store, capture service, or merchant memory reference.
@MainActor @Observable final class ScreenshotFMBenchRunner {
    static let shared = ScreenshotFMBenchRunner()
    enum Phase { case idle, running, finished, cancelled, unavailable }

    private(set) var phase = Phase.idle
    private(set) var availability = "not checked"
    private(set) var corpus: ScreenshotFMBenchmarkCorpus?
    private(set) var loadError: String?
    private(set) var records: [ScreenshotFMBenchmarkRecord] = []
    private(set) var summary: ScreenshotFMBenchmarkSummary?
    private(set) var current: String?
    private(set) var durationSeconds: Double?
    private(set) var startedAt: String?
    private var task: Task<Void, Never>?

    private init() {
        do {
            corpus = try JSONDecoder().decode(ScreenshotFMBenchmarkCorpus.self, from: ScreenshotFMBenchData.json)
        } catch { loadError = "Benchmark fixture unavailable: \(error)" }
    }

    func refreshAvailability() {
        availability = BenchDevice.availabilityLabel(SystemLanguageModel.default.availability)
    }
    func start() {
        guard phase != .running, let corpus, loadError == nil else { return }
        let model = SystemLanguageModel.default
        refreshAvailability()
        records = []; summary = nil; durationSeconds = nil
        startedAt = ISO8601DateFormatter().string(from: Date())
        guard model.availability == .available else {
            phase = .unavailable
            summary = ScreenshotFMBenchmarkSummary(cases: corpus.cases, records: [], availabilityFailed: true)
            return
        }
        phase = .running
        let begin = Date()
        let evaluator = FMScreenshotEvaluator(model: model)
        task = Task { [weak self, cases = corpus.cases] in
            for item in cases {
                if Task.isCancelled { break }
                self?.current = item.id
                let record = await evaluator.evaluate(item)
                self?.records.append(record)
                if let self, self.records.count % 10 == 0 {
                    self.summary = ScreenshotFMBenchmarkSummary(cases: cases, records: self.records)
                }
            }
            self?.durationSeconds = Date().timeIntervalSince(begin)
            if let self {
                self.summary = ScreenshotFMBenchmarkSummary(cases: cases, records: self.records)
                self.phase = Task.isCancelled ? .cancelled : .finished
                self.current = nil; self.task = nil
            }
        }
    }
    func cancel() { task?.cancel() }

    var reportText: String {
        guard let s = summary else { return "No results yet." }
        func fields(_ x: ScreenshotFMFieldMetrics) -> String {
            "amount \(x.amount.fraction); merchant \(x.merchant.fraction); date/time \(x.date.fraction); reference \(x.reference.fraction)"
        }
        return """
        Vision OCR → Apple FM benchmark · \(corpus?.version ?? "?") · \(records.count)/\(corpus?.cases.count ?? 0) cases
        \(BenchDevice.hardwareModel) · \(ProcessInfo.processInfo.operatingSystemVersionString) · model \(availability)
        Classification \(s.classification.fraction)
        Apple FM grounded: \(fields(s.appleFM))
        G3 fields: \(fields(s.g3))
        Complete useful transactions \(s.completeUseful.fraction)
        Correct abstentions \(s.abstention.fraction)
        Grounding failures \(s.groundingFailures.sorted { $0.key < $1.key })
        Dangerous raw claims \(s.dangerousErrors.sorted { $0.key < $1.key })
        Refusals \(s.refusalCount); model availability failures \(s.availabilityFailures); errors \(s.errors.sorted { $0.key < $1.key })
        Latency ms: cold \(s.coldLatencyMS.map { Int($0) } ?? -1), warm median \(s.medianLatencyMS.map { Int($0) } ?? -1), p95 \(s.p95LatencyMS.map { Int($0) } ?? -1)
        """
    }

    func exportFile() -> URL? {
        guard let corpus, let summary else { return nil }
        let export = FMScreenshotExport(promptVersion: FMScreenshotPrompt.version,
            schemaVersion: FMScreenshotPrompt.schema, instructions: FMScreenshotPrompt.instructions,
            corpus: corpus, records: records, summary: summary,
            device: BenchDevice.hardwareModel, os: ProcessInfo.processInfo.operatingSystemVersionString,
            availability: availability, startedAt: startedAt ?? "", durationSeconds: durationSeconds)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pace-fm-screenshot-\(startedAt?.replacingOccurrences(of: ":", with: "-") ?? "run").json")
        guard let data = try? encoder.encode(export), (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}
#endif
