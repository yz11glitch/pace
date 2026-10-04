#if DEBUG
import Foundation
import FoundationModels
import Observation

/// Drives a benchmark run. Held as a singleton so a run survives closing
/// Capture Lab. Reads nothing from and writes nothing to the Pace database;
/// results live in memory until exported.
@MainActor
@Observable
final class CategorizerBenchRunner {
    static let shared = CategorizerBenchRunner()

    enum Phase: Equatable { case idle, running, finished, cancelled, unavailable }

    let cases = BenchDataset.cases
    let allowed = Set(BenchPrompt.categories)
    var passes = 1
    var prompt = BenchPromptVariant.v1
    var sampling = BenchSampling.greedy
    private(set) var phase = Phase.idle
    private(set) var availability = "not checked"
    private(set) var environment: BenchEnvironment?
    private(set) var results: [BenchResult] = []
    private(set) var summary: BenchSummary?
    private(set) var current: String?
    private(set) var durationSeconds: Double?
    private var startedAt: Date?
    private var task: Task<Void, Never>?

    var total: Int { cases.count * passes }
    var elapsedSeconds: Double? { startedAt.map { durationSeconds ?? Date().timeIntervalSince($0) } }

    func refreshAvailability() {
        let model = SystemLanguageModel.default
        availability = BenchDevice.availabilityLabel(model.availability)
        if phase != .running { environment = BenchDevice.environment(model: model, prompt: prompt, sampling: sampling) }
    }

    func start() {
        guard phase != .running else { return }
        let model = SystemLanguageModel.default
        refreshAvailability()
        results = []
        summary = nil
        durationSeconds = nil
        guard model.availability == .available else {
            phase = .unavailable
            return
        }
        phase = .running
        let started = Date()
        startedAt = started
        let classifier = BenchClassifier(model: model, prompt: prompt, sampling: sampling)
        let baseline = try? SeedMemoryBaseline()
        let passes = passes
        task = Task { [weak self, cases] in
            let known = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, baseline?.category(for: $0.merchant)) })
            run: for pass in 1...passes {
                for item in cases {
                    if Task.isCancelled { break run }
                    self?.current = "pass \(pass) · \(item.merchant)"
                    let outcome = await classifier.classify(item)
                    self?.append(BenchResult(caseID: item.id, pass: pass, output: outcome.output, error: outcome.error,
                                             latencyMS: outcome.latencyMS, inputTokens: outcome.inputTokens,
                                             outputTokens: outcome.outputTokens, baseline: known[item.id] ?? nil))
                }
            }
            self?.finish(cancelled: Task.isCancelled, started: started)
        }
    }

    func cancel() { task?.cancel() }

    private func append(_ result: BenchResult) {
        results.append(result)
        if results.count % 10 == 0 { summary = BenchSummary(cases: cases, results: results, allowed: allowed) }
    }

    private func finish(cancelled: Bool, started: Date) {
        durationSeconds = Date().timeIntervalSince(started)
        if #available(iOS 27.0, *) { environment?.modelVariantAfterRun = SystemLanguageModel.default.variant.displayName }
        summary = BenchSummary(cases: cases, results: results, allowed: allowed)
        current = nil
        phase = cancelled ? .cancelled : .finished
        task = nil
    }

    var reportText: String {
        guard let environment, let summary else { return "No results yet." }
        return BenchReport.text(environment: environment, cases: cases, results: results, summary: summary,
                                allowed: allowed, durationSeconds: durationSeconds)
    }

    /// Writes the self-contained JSON export to the temporary directory for sharing.
    func exportFile() -> URL? {
        guard let environment, let summary else { return nil }
        let export = BenchExport(environment: environment, durationSeconds: durationSeconds,
                                 categories: BenchPrompt.categories, instructions: BenchPrompt.instructions(prompt),
                                 cases: cases, results: results, summary: summary)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stamp = environment.startedAt.replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-fm-categorizer-\(environment.deviceModel)-\(environment.promptVersion)-\(stamp).json")
        guard let data = try? encoder.encode(export), (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    func outcome(_ result: BenchResult) -> BenchOutcome? {
        cases.first { $0.id == result.caseID }.map { BenchScoring.outcome($0, result, allowed: allowed) }
    }
}
#endif
