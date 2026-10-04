#if DEBUG
import SwiftUI
import UIKit
import PaceCore

struct ScreenshotFMBenchView: View {
    @State private var runner = ScreenshotFMBenchRunner.shared
    @State private var exportURL: URL?
    @State private var copied = false

    var body: some View {
        List {
            Section("On-device model") {
                LabeledContent("Availability", value: runner.availability)
                LabeledContent("Device", value: BenchDevice.hardwareModel)
                Text(ProcessInfo.processInfo.operatingSystemVersionString).font(.caption)
                Text("Apple Vision OCR fixtures → SystemLanguageModel.default. One fresh on-device session per case; no image or network inference.")
                    .font(.caption)
                Button("Check availability") { runner.refreshAvailability() }
            }
            Section("Run") {
                if let error = runner.loadError { Text(error).foregroundStyle(.red) }
                if let corpus = runner.corpus {
                    Text("\(corpus.cases.count) fixed OCR cases · \(corpus.version) · \(FMScreenshotPrompt.version)")
                        .font(.caption)
                    Text("Includes synthetic physical regressions; no real Capture Lab JSON was available in this repository.")
                        .font(.caption)
                }
                if runner.phase == .running {
                    ProgressView(value: Double(runner.records.count), total: Double(runner.corpus?.cases.count ?? 1)) {
                        Text("\(runner.records.count)/\(runner.corpus?.cases.count ?? 0) · \(runner.current ?? "")")
                    }
                    Button("Cancel", role: .destructive) { runner.cancel() }
                } else {
                    Button("Run benchmark") { exportURL = nil; runner.start() }
                        .disabled(runner.corpus == nil)
                        .accessibilityIdentifier("fm-screenshot-bench-run")
                }
                if runner.phase == .unavailable {
                    Text("Model unavailable. Nothing was run.").foregroundStyle(.red)
                }
                if runner.phase == .cancelled { Text("Cancelled; results cover completed cases only.") }
            }
            if let summary = runner.summary {
                Section("Apple FM · verified") {
                    metric("Screen classification", summary.classification.fraction)
                    metric("Amount", summary.appleFM.amount.fraction)
                    metric("Merchant", summary.appleFM.merchant.fraction)
                    metric("Displayed date/time", summary.appleFM.date.fraction)
                    metric("Reference", summary.appleFM.reference.fraction)
                    metric("Complete useful", summary.completeUseful.fraction)
                    metric("Correct abstentions", summary.abstention.fraction)
                }
                Section("G3 · same cases") {
                    metric("Amount", summary.g3.amount.fraction)
                    metric("Merchant", summary.g3.merchant.fraction)
                    metric("Displayed date/time", summary.g3.date.fraction)
                    metric("Reference", summary.g3.reference.fraction)
                    Text("G3 has no final screen classification; comparison is informational.").font(.caption)
                }
                Section("Safety and runtime") {
                    metric("Grounding rejections", display(summary.groundingFailures))
                    metric("Dangerous raw claims", display(summary.dangerousErrors))
                    metric("Refusals", "\(summary.refusalCount)")
                    metric("Availability failures", "\(summary.availabilityFailures)")
                    metric("Other errors", display(summary.errors))
                    metric("Cold / median / p95 ms", [summary.coldLatencyMS, summary.medianLatencyMS, summary.p95LatencyMS]
                        .map { $0.map { String(Int($0)) } ?? "n/a" }.joined(separator: " / "))
                }
                Section("Export") {
                    Button(copied ? "Copied" : "Copy summary") {
                        UIPasteboard.general.string = runner.reportText; copied = true
                    }
                    if runner.phase != .running {
                        if let exportURL { ShareLink("Share detailed JSON", item: exportURL) }
                        else { Button("Prepare detailed JSON") { exportURL = runner.exportFile() } }
                    }
                }
                Section("Cases") {
                    ForEach(runner.records, id: \.caseID) { record in
                        DisclosureGroup(record.caseID) {
                            if let item = runner.corpus?.cases.first(where: { $0.id == record.caseID }) {
                                LabeledContent("Source", value: item.source)
                                LabeledContent("Expected transaction", value: item.expected.isTransaction ? "yes" : "no")
                                Text(FMScreenshotPrompt.input(item)).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            }
                            if let claim = record.claim {
                                LabeledContent("Model", value: "transaction \(claim.isTransaction), \(claim.certainty)")
                                LabeledContent("Claims", value: "\(claim.amountMinor.map(String.init) ?? "—") · \(claim.merchant ?? "—") · \(claim.dateTimeEvidence ?? "—") · \(claim.reference ?? "—")")
                            }
                            if let checked = record.verified {
                                LabeledContent("Verified", value: "\(checked.amountMinor.map(String.init) ?? "—") · \(checked.merchant ?? "—") · \(checked.occurredAt ?? "—") · \(checked.reference ?? "—")")
                                if !checked.rejected.isEmpty { Text("Rejected: \(display(checked.rejected))").foregroundStyle(.red) }
                            }
                            if let error = record.errorKind { Text("\(error): \(record.errorMessage ?? "")").foregroundStyle(.red) }
                            LabeledContent("G3", value: "\(record.g3.amountMinor.map(String.init) ?? "—") · \(record.g3.merchant ?? "—") · \(record.g3.occurredAt ?? "—") · \(record.g3.reference ?? "—")")
                            LabeledContent("Latency", value: "\(Int(record.latencyMS)) ms")
                        }
                    }
                }
            }
        }
        .navigationTitle("FM screenshot benchmark")
        .onAppear { runner.refreshAvailability() }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        LabeledContent(name) { Text(value).font(.callout.monospacedDigit()) }
    }
    private func display(_ values: [String: Int]) -> String {
        values.isEmpty ? "none" : values.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
    private func display(_ values: [String: String]) -> String {
        values.isEmpty ? "none" : values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
    }
}
#endif
