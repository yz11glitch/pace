#if DEBUG
import SwiftUI
import UIKit

/// Developer-only harness: runs the Apple Foundation Models merchant
/// categorization benchmark on this device. Not consumer UI; nothing here
/// touches the ledger or merchant memory.
struct CategorizerBenchView: View {
    @State private var runner = CategorizerBenchRunner.shared
    @State private var filter = Filter.flagged
    @State private var exportURL: URL?
    @State private var copied = false

    enum Filter: String, CaseIterable { case flagged = "Flagged", all = "All" }

    var body: some View {
        List {
            Section("Model") {
                LabeledContent("SystemLanguageModel", value: runner.availability)
                    .accessibilityIdentifier("fm-bench-availability")
                if let environment = runner.environment {
                    LabeledContent("Variant", value: environment.modelVariant ?? "n/a (needs iOS 27)")
                    if let after = environment.modelVariantAfterRun, after != environment.modelVariant {
                        LabeledContent("Variant after run", value: after)
                    }
                    LabeledContent("Context", value: environment.contextSize.map { "\($0) tokens" } ?? "n/a")
                    LabeledContent("en_MY supported", value: environment.supportsMalaysianEnglish ? "yes" : "no")
                    LabeledContent("Device", value: environment.deviceModel)
                    Text(environment.osVersion).font(.caption)
                }
                Text("On-device only: SystemLanguageModel.default, one fresh session per case. Private Cloud Compute is not used.")
                    .font(.caption)
                Button("Check availability") { runner.refreshAvailability() }
            }
            Section("Run") {
                let problems = BenchDataset.problems
                if !problems.isEmpty {
                    Text("Fixture problems: \(problems.joined(separator: "; "))").foregroundStyle(.red)
                }
                Text("\(runner.cases.count) cases · \(BenchPrompt.schemaVersion) · \(BenchDataset.version)")
                    .font(.caption)
                Picker("Prompt", selection: $runner.prompt) {
                    ForEach(BenchPromptVariant.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .disabled(runner.phase == .running)
                Stepper("Passes · \(runner.passes)", value: $runner.passes, in: 1...5)
                    .disabled(runner.phase == .running)
                Picker("Sampling", selection: $runner.sampling) {
                    ForEach(BenchSampling.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .disabled(runner.phase == .running)
                if runner.phase == .running {
                    ProgressView(value: Double(runner.results.count), total: Double(max(runner.total, 1))) {
                        Text("\(runner.results.count)/\(runner.total) · \(Int(runner.elapsedSeconds ?? 0)) s")
                    } currentValueLabel: {
                        Text(runner.current ?? "")
                    }
                    Button("Cancel", role: .destructive) { runner.cancel() }
                } else {
                    Button("Run benchmark") { exportURL = nil; runner.start() }
                        .accessibilityIdentifier("fm-bench-run")
                }
                if runner.phase == .unavailable {
                    Text("Model unavailable: \(runner.availability). Nothing was run.").foregroundStyle(.red)
                }
                if runner.phase == .cancelled { Text("Cancelled — summary covers completed cases only.") }
            }
            if let summary = runner.summary {
                summarySection(summary)
                Section("Export") {
                    Button(copied ? "Copied" : "Copy compact report") {
                        UIPasteboard.general.string = runner.reportText
                        copied = true
                    }
                    if runner.phase != .running {
                        if let exportURL {
                            ShareLink("Share full JSON", item: exportURL)
                        } else {
                            Button("Prepare JSON export") { exportURL = runner.exportFile() }
                        }
                    }
                }
                resultsSection
            }
        }
        .navigationTitle("FM categorizer")
        .onAppear { runner.refreshAvailability() }
        .onChange(of: runner.results.count) { copied = false }
    }

    private func summarySection(_ s: BenchSummary) -> some View {
        Section("Summary") {
            metric("Overall acceptable", BenchReport.fraction(s.overall.acceptable, s.overall.total))
            metric("Dangerous (confident wrong + forced)", BenchReport.fraction(s.overall.dangerous, s.overall.total))
            metric("Categorizable correct", BenchReport.fraction(s.categorizable[.correct], s.categorizable.total))
            metric("Precision when committed", BenchReport.fraction(s.categorizable[.correct], s.categorizable.committed))
            metric("Must-abstain abstained", BenchReport.fraction(s.mustAbstain[.correctAbstain], s.mustAbstain.total))
            metric("Must-abstain forced", "\(s.mustAbstain[.forced])")
            ForEach(BenchVariant.allCases, id: \.self) { variant in
                let tally = s.pairedByVariant[variant] ?? .init()
                metric("Paired · \(variant.rawValue)",
                       "\(BenchReport.fraction(tally.acceptable, tally.total)) · dangerous \(tally.dangerous)")
            }
            metric("Seed memory baseline", "\(BenchReport.fraction(s.baseline.acceptable, s.baseline.total)) · committed \(s.baseline.committed)")
            metric("Simulated memory → model", BenchReport.fraction(s.combined.acceptable, s.combined.total))
            metric("Latency", "cold \(BenchReport.ms(s.latency.coldMS)) · median \(BenchReport.ms(s.latency.warmMedianMS)) · p95 \(BenchReport.ms(s.latency.warmP95MS))")
            metric("Errors", s.errorsByKind.isEmpty ? "none"
                   : s.errorsByKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            metric("Structured-generation failures", "\(s.structuredFailures)")
            if let consistent = s.consistentAcrossPasses {
                metric("Identical across passes", BenchReport.fraction(consistent, s.repeatedCases))
            }
        }
    }

    private var resultsSection: some View {
        Section {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            ForEach(visibleResults, id: \.0.id) { result, outcome in
                NavigationLink {
                    CategorizerBenchCaseView(result: result, item: runner.cases.first { $0.id == result.caseID })
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(outcome.rawValue) · \(runner.cases.first { $0.id == result.caseID }?.merchant ?? result.caseID)")
                            .foregroundStyle(outcome.isDangerous ? .red : outcome == .missed ? .orange : .primary)
                        Text(result.output.map { "\($0.category) · \($0.certainty.rawValue) · \(Int(result.latencyMS)) ms" }
                             ?? (result.error?.kind ?? "error"))
                            .font(.caption)
                    }
                }
            }
        } header: {
            Text("Results")
        } footer: {
            Text("Flagged = confident wrong, forced, error, then missed.")
        }
    }

    private var visibleResults: [(BenchResult, BenchOutcome)] {
        let rows = runner.results.compactMap { result in runner.outcome(result).map { (result, $0) } }
        guard filter == .flagged else { return rows }
        let order: [BenchOutcome] = [.confidentWrong, .forced, .error, .missed]
        return rows.filter { order.contains($0.1) }
            .sorted { order.firstIndex(of: $0.1)! < order.firstIndex(of: $1.1)! }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).font(.callout.monospacedDigit()) }
    }
}

private struct CategorizerBenchCaseView: View {
    let result: BenchResult
    let item: BenchCase?

    var body: some View {
        List {
            if let item {
                Section("Case") {
                    LabeledContent("ID", value: item.id)
                    LabeledContent("Group / variant", value: "\(item.group.rawValue) / \(item.variant.rawValue)")
                    LabeledContent("Expected", value: item.expected.label)
                    if let note = item.note { LabeledContent("Note", value: note) }
                    Text(BenchPrompt.prompt(for: item))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Section("Model") {
                if let output = result.output {
                    LabeledContent("Category", value: output.category)
                    LabeledContent("Certainty", value: output.certainty.rawValue)
                    LabeledContent("Business type", value: output.businessType)
                }
                if let error = result.error {
                    LabeledContent("Error", value: error.kind)
                    Text(error.message).font(.caption).textSelection(.enabled)
                }
                LabeledContent("Latency", value: "\(Int(result.latencyMS)) ms")
                LabeledContent("Tokens in / out", value: "\(result.inputTokens.map(String.init) ?? "n/a") / \(result.outputTokens.map(String.init) ?? "n/a")")
                LabeledContent("Seed memory", value: result.baseline ?? "no trusted hit")
                LabeledContent("Pass", value: "\(result.pass)")
            }
        }
        .navigationTitle(item?.merchant ?? result.caseID)
    }
}
#endif
