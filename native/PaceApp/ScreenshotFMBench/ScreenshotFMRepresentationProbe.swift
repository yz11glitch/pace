#if DEBUG
import Foundation
import FoundationModels
import Observation
import PaceCore
import SwiftUI

/// Fixed IDs from vision-ocr-fm-v1. No fixture is copied or regenerated for this probe.
private enum FMProbeCases {
    static let ids = [
        "A-hero-0", "B-columns-0", "C-stacked-0", "D-alert-0", "E-title-0",
        "F-receipt-0", "G-malay-0", "H-mixed-0", "B16", "P5",
        "historical-maybank-synthetic", "A-pending", "A-failed",
        "N-overview-0", "N-list-1", "N-checkout-2", "N-promo-3", "N-chat-20",
        "N-weather-5", "N-product-6", "B24"
    ]

    static func selected(from corpus: ScreenshotFMBenchmarkCorpus) -> [ScreenshotFMBenchmarkCase]? {
        let byID = Dictionary(uniqueKeysWithValues: corpus.cases.map { ($0.id, $0) })
        let selected = ids.compactMap { byID[$0] }
        return selected.count == ids.count ? selected : nil
    }

    static func expectedKind(_ item: ScreenshotFMBenchmarkCase) -> String {
        switch item.kind {
        case "pending": return "pendingTransaction"
        case "failed": return "failedTransaction"
        case "list": return "transactionList"
        case "overview": return "accountOverview"
        case "checkout": return "checkout"
        case "chat": return "paymentRequest"
        case "promo": return "offer"
        case "product": return "product"
        case "weather": return "nonFinancial"
        case "blind" where !item.expected.isTransaction:
            switch item.id {
            case "B24": return "accountOverview"
            default: return "other"
            }
        default: return item.expected.isTransaction ? "completedTransaction" : "other"
        }
    }
}

@Generable(description: "Semantic interpretation of one screenshot OCR result")
nonisolated struct FMScreenshotDiagnosticResult {
    @Guide(description: "Choose the kind of screen shown by the whole OCR result, not merely a word or row on it")
    var screenKind: FMScreenshotScreenKind
    @Guide(description: "Exact money text selected from OCR for the transaction amount; nil if this is not a transaction amount or none is visible. Do not calculate cents")
    var selectedAmountText: String?
    @Guide(description: "confident only when the interpretation is well supported; otherwise uncertain")
    var certainty: FMScreenshotCertainty
    @Guide(description: "Merchant or counterparty name from OCR; nil if unknown")
    var merchant: String?
    @Guide(description: "Exact OCR text showing the displayed transaction date and time; nil if absent or uncertain")
    var dateTimeEvidence: String?
    @Guide(description: "Primary transaction or reference identifier from OCR; nil if its role is unknown. Never a card/account mask, merchant ID or terminal ID")
    var reference: String?
}

@Generable nonisolated enum FMScreenshotScreenKind {
    case completedTransaction, pendingTransaction, failedTransaction, transactionList
    case accountOverview, checkout, paymentRequest, offer, product, nonFinancial, other, uncertain

    var label: String {
        switch self {
        case .completedTransaction: "completedTransaction"
        case .pendingTransaction: "pendingTransaction"
        case .failedTransaction: "failedTransaction"
        case .transactionList: "transactionList"
        case .accountOverview: "accountOverview"
        case .checkout: "checkout"
        case .paymentRequest: "paymentRequest"
        case .offer: "offer"
        case .product: "product"
        case .nonFinancial: "nonFinancial"
        case .other: "other"
        case .uncertain: "uncertain"
        }
    }

    /// Explicit diagnostic eligibility. This does not participate in production capture.
    var completedCaptureEligible: Bool { self == .completedTransaction }
}

private enum FMScreenshotDiagnosticPrompt {
    static let version = "representation-probe-v1"
    static let instructions = """
    Interpret one set of Apple Vision OCR observations from a possible financial transaction screen.
    Describe the kind of the whole screen, including whether it is a completed transaction detail.
    Extract transaction facts only when supported by the OCR. The observations may include screen chrome,
    unrelated balances or totals, card/account information, merchant or terminal metadata, and multiple dates or identifiers.
    Use visual position and nearby labels to distinguish the transaction from those other details.
    A bare ID or an unlabeled number does not establish a transaction reference.
    A checkout request is not proof a payment happened. Pending and failed transaction attempts are still transaction screens.
    A transaction list is not a single completed transaction detail.
    Select the exact OCR money text for the transaction amount; do not calculate minor units.
    Quote the exact OCR observation for the displayed transaction date/time.
    Abstain with nil for any uncertain field. Do not manufacture missing financial facts or use outside knowledge.
    """
}

private struct FMProbeClaim: Codable {
    let screenKind: String
    let completedCaptureEligible: Bool
    let selectedAmountText: String?
    let certainty: String
    let merchant: String?
    let dateTimeEvidence: String?
    let reference: String?
}

private struct FMProbeDiagnosticRecord: Codable {
    let claim: FMProbeClaim?
    let parsedMoney: ScreenshotFMProbeMoneyResult?
    let verifiedOtherFields: ScreenshotFMVerified?
    let errorKind: String?
    let errorMessage: String?
    let latencyMS: Double
    let inputTokens: Int?
    let outputTokens: Int?
}

private struct FMProbePair: Codable, Identifiable {
    let caseID: String
    let v1: ScreenshotFMBenchmarkRecord
    let diagnostic: FMProbeDiagnosticRecord
    var id: String { caseID }
}

private struct FMProbeExport: Codable {
    let version: String
    let v1PromptVersion: String
    let v1SchemaVersion: String
    let diagnosticPromptVersion: String
    let diagnosticInstructions: String
    let cases: [ScreenshotFMBenchmarkCase]
    let records: [FMProbePair]
    let summaryA: FMProbeArmScore
    let summaryB: FMProbeArmScore
    let device: String
    let os: String
    let availability: String
    let startedAt: String
}

private struct FMProbeDiagnosticEvaluator: Sendable {
    let model: SystemLanguageModel

    func evaluate(_ item: ScreenshotFMBenchmarkCase) async -> FMProbeDiagnosticRecord {
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Double {
            let delta = clock.now - start
            return Double(delta.components.seconds) * 1000 + Double(delta.components.attoseconds) / 1e15
        }
        do {
            let session = LanguageModelSession(model: model, instructions: FMScreenshotDiagnosticPrompt.instructions)
            let response = try await session.respond(to: FMScreenshotPrompt.input(item),
                generating: FMScreenshotDiagnosticResult.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 450))
            let output = response.content
            let claim = FMProbeClaim(screenKind: output.screenKind.label,
                completedCaptureEligible: output.screenKind.completedCaptureEligible,
                selectedAmountText: output.selectedAmountText,
                certainty: output.certainty == .confident ? "confident" : "uncertain",
                merchant: output.merchant, dateTimeEvidence: output.dateTimeEvidence,
                reference: output.reference)
            let instant = Instant(iso: item.capturedAt)!
            let money = ScreenshotFMProbeMoney.parse(claim.selectedAmountText, lines: item.lines,
                capturedAt: instant, timeZone: item.timeZone)
            let other = ScreenshotFMGrounding.verify(.init(isTransaction: claim.completedCaptureEligible,
                certainty: claim.certainty, merchant: claim.merchant,
                dateTimeEvidence: claim.dateTimeEvidence, reference: claim.reference),
                lines: item.lines, capturedAt: instant, timeZone: item.timeZone)
            var inputTokens: Int?, outputTokens: Int?
            if #available(iOS 27.0, macOS 27.0, *) {
                inputTokens = response.usage.input.totalTokenCount
                outputTokens = response.usage.output.totalTokenCount
            }
            return .init(claim: claim, parsedMoney: money, verifiedOtherFields: other,
                errorKind: nil, errorMessage: nil, latencyMS: elapsed(),
                inputTokens: inputTokens, outputTokens: outputTokens)
        } catch let LanguageModelSession.GenerationError.refusal(refusal, _) {
            let duration = elapsed()
            let explanation = (try? await refusal.explanation.content) ?? "no explanation returned"
            return .init(claim: nil, parsedMoney: nil, verifiedOtherFields: nil,
                errorKind: "refusal", errorMessage: explanation, latencyMS: duration,
                inputTokens: nil, outputTokens: nil)
        } catch {
            let classified = BenchClassifier.classify(error)
            return .init(claim: nil, parsedMoney: nil, verifiedOtherFields: nil,
                errorKind: classified.kind, errorMessage: classified.message, latencyMS: elapsed(),
                inputTokens: nil, outputTokens: nil)
        }
    }
}

@MainActor @Observable private final class FMRepresentationProbeRunner {
    static let shared = FMRepresentationProbeRunner()
    private(set) var cases: [ScreenshotFMBenchmarkCase] = []
    private(set) var loadError: String?
    private(set) var records: [FMProbePair] = []
    private(set) var availability = "not checked"
    private(set) var running = false
    private(set) var current: String?
    private(set) var startedAt = ""
    private var task: Task<Void, Never>?

    private init() {
        do {
            let corpus = try JSONDecoder().decode(ScreenshotFMBenchmarkCorpus.self, from: ScreenshotFMBenchData.json)
            guard let selected = FMProbeCases.selected(from: corpus) else {
                loadError = "One or more fixed probe IDs are missing from the v1 corpus"; return
            }
            cases = selected
        } catch { loadError = "Benchmark corpus unavailable: \(error)" }
    }

    func refreshAvailability() { availability = BenchDevice.availabilityLabel(SystemLanguageModel.default.availability) }

    func start() {
        guard !running, loadError == nil, !cases.isEmpty else { return }
        let model = SystemLanguageModel.default
        refreshAvailability()
        records = []
        startedAt = ISO8601DateFormatter().string(from: Date())
        guard model.availability == .available else { return }
        running = true
        let v1 = FMScreenshotEvaluator(model: model)
        let diagnostic = FMProbeDiagnosticEvaluator(model: model)
        task = Task { [weak self, cases] in
            for (index, item) in cases.enumerated() {
                if Task.isCancelled { break }
                self?.current = item.id
                let old: ScreenshotFMBenchmarkRecord
                let new: FMProbeDiagnosticRecord
                if index.isMultiple(of: 2) {
                    old = await v1.evaluate(item)
                    if Task.isCancelled { break }
                    new = await diagnostic.evaluate(item)
                } else {
                    new = await diagnostic.evaluate(item)
                    if Task.isCancelled { break }
                    old = await v1.evaluate(item)
                }
                self?.records.append(.init(caseID: item.id, v1: old, diagnostic: new))
            }
            self?.running = false
            self?.current = nil
            self?.task = nil
        }
    }

    func cancel() { task?.cancel() }

    func exportFile() -> URL? {
        guard !records.isEmpty else { return nil }
        let (summaryA, summaryB) = FMProbeScoring.scores(cases, records)
        let export = FMProbeExport(version: "representation-probe-v1", v1PromptVersion: FMScreenshotPrompt.version,
            v1SchemaVersion: FMScreenshotPrompt.schema, diagnosticPromptVersion: FMScreenshotDiagnosticPrompt.version,
            diagnosticInstructions: FMScreenshotDiagnosticPrompt.instructions, cases: cases, records: records,
            summaryA: summaryA, summaryB: summaryB,
            device: BenchDevice.hardwareModel, os: ProcessInfo.processInfo.operatingSystemVersionString,
            availability: availability, startedAt: startedAt)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pace-fm-representation-probe-\(startedAt.replacingOccurrences(of: ":", with: "-")).json")
        guard let data = try? encoder.encode(export), (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}

private struct FMProbeArmScore: Codable {
    var correctSelection = 0
    var expectedAmounts = 0
    var parsedSupported = 0
    var selectedTexts = 0
    var wrongSelection = 0
    var unsupported = 0
    var amountGroundingFailures = 0
    var completedCorrect = 0
    var completedTotal = 0
    var negativeRejected = 0
    var negativeTotal = 0
    var ineligibleRejected = 0
    var ineligibleTotal = 0
    var falsePositiveCompleted = 0
    var falsePositiveTransaction = 0
    var falseNegativeCompleted = 0
    var kindConfusion: [String: Int] = [:]
    var merchantCorrect = 0
    var dateCorrect = 0
    var referenceCorrect = 0
    var positiveTotal = 0
    var errors: [String: Int] = [:]
    var latencies: [Double] = []
    var medianMS: Int { let sorted = latencies.sorted(); return sorted.isEmpty ? 0 : Int(sorted[sorted.count / 2]) }
}

private enum FMProbeScoring {
    static func scores(_ cases: [ScreenshotFMBenchmarkCase], _ records: [FMProbePair]) -> (FMProbeArmScore, FMProbeArmScore) {
        let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        var old = FMProbeArmScore(), new = FMProbeArmScore()
        for pair in records {
            guard let item = byID[pair.caseID] else { continue }
            let expected = item.expected
            let instant = Instant(iso: item.capturedAt)!
            let oldClaim = pair.v1.claim
            let oldMoney = ScreenshotFMProbeMoney.parse(oldClaim?.amountEvidence,
                lines: item.lines, capturedAt: instant, timeZone: item.timeZone)
            let newClaim = pair.diagnostic.claim
            let newMoney = pair.diagnostic.parsedMoney
            let expectedCompleted = FMProbeCases.expectedKind(item) == "completedTransaction"
            let oldCompleted = oldClaim?.isTransaction == true && oldClaim?.state.lowercased() == "completed"
            let newCompleted = newClaim?.completedCaptureEligible == true
            let oldKind = oldClaim.map { "\($0.isTransaction ? "transaction" : "nonTransaction")/\($0.state)" } ?? "error"
            let newKind = newClaim?.screenKind ?? "error"
            score(&old, expected: expected, expectedCompleted: expectedCompleted,
                predictedCompleted: oldCompleted, predictedTransaction: oldClaim?.isTransaction == true,
                kind: oldKind, expectedKind: FMProbeCases.expectedKind(item),
                selectedText: oldClaim?.amountEvidence, money: oldMoney,
                amountRejected: pair.v1.verified?.rejected["amount"] != nil,
                verified: pair.v1.verified, error: pair.v1.errorKind, latency: pair.v1.latencyMS)
            score(&new, expected: expected, expectedCompleted: expectedCompleted,
                predictedCompleted: newCompleted, predictedTransaction: newCompleted,
                kind: newKind, expectedKind: FMProbeCases.expectedKind(item),
                selectedText: newClaim?.selectedAmountText, money: newMoney,
                amountRejected: newMoney?.status == "unsupported",
                verified: pair.diagnostic.verifiedOtherFields,
                error: pair.diagnostic.errorKind, latency: pair.diagnostic.latencyMS)
        }
        return (old, new)
    }

    private static func score(_ result: inout FMProbeArmScore, expected: ScreenshotFMBenchmarkTruth,
                              expectedCompleted: Bool, predictedCompleted: Bool, predictedTransaction: Bool,
                              kind: String, expectedKind: String, selectedText: String?,
                              money: ScreenshotFMProbeMoneyResult?, amountRejected: Bool,
                              verified: ScreenshotFMVerified?, error: String?, latency: Double) {
        if let error { result.errors[error, default: 0] += 1 }
        if latency > 0 { result.latencies.append(latency) }
        result.kindConfusion["\(expectedKind) → \(kind)", default: 0] += 1
        if expectedCompleted {
            result.completedTotal += 1
            if predictedCompleted { result.completedCorrect += 1 }
            else { result.falseNegativeCompleted += 1 }
        } else {
            result.ineligibleTotal += 1
            if !predictedCompleted { result.ineligibleRejected += 1 }
            else { result.falsePositiveCompleted += 1 }
        }
        if !expected.isTransaction {
            result.negativeTotal += 1
            if !predictedCompleted { result.negativeRejected += 1 }
            if predictedTransaction { result.falsePositiveTransaction += 1 }
        } else {
            result.positiveTotal += 1
            if equal(expected.merchant, verified?.merchant) { result.merchantCorrect += 1 }
            if equalDate(expected.occurredAt, verified?.occurredAt) { result.dateCorrect += 1 }
            if equal(expected.reference, verified?.reference) { result.referenceCorrect += 1 }
            if expected.amountMinor != nil { result.expectedAmounts += 1 }
        }
        if selectedText != nil { result.selectedTexts += 1 }
        if money?.status == "supported" { result.parsedSupported += 1 }
        if money?.status == "unsupported" { result.unsupported += 1 }
        if amountRejected { result.amountGroundingFailures += 1 }
        if let parsed = money?.amountMinor {
            if expected.isTransaction && expected.amountMinor == parsed { result.correctSelection += 1 }
            else { result.wrongSelection += 1 }
        }
    }

    private static func equal(_ a: String?, _ b: String?) -> Bool {
        func norm(_ text: String?) -> String? {
            text?.precomposedStringWithCompatibilityMapping.lowercased()
                .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
        }
        return norm(a) == norm(b)
    }
    private static func equalDate(_ a: String?, _ b: String?) -> Bool {
        if let a, let b, let first = Instant(iso: a), let second = Instant(iso: b) { return first == second }
        return a == b
    }
}

struct ScreenshotFMRepresentationProbeView: View {
    @State private var runner = FMRepresentationProbeRunner.shared
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section("Representation A/B · DEBUG only") {
                Text("\(runner.cases.count) fixed cases from vision-ocr-fm-v1 · two fresh on-device sessions per case · no capture or storage")
                    .font(.caption)
                Text("A: v1 Int + Bool. B: OCR money text + screen kind. Only completedTransaction is capture-eligible in this diagnostic.")
                    .font(.caption)
                LabeledContent("Model", value: runner.availability)
                if let error = runner.loadError { Text(error).foregroundStyle(.red) }
                if runner.running {
                    ProgressView(value: Double(runner.records.count), total: Double(runner.cases.count)) {
                        Text("\(runner.records.count)/\(runner.cases.count) · \(runner.current ?? "")")
                    }
                    Button("Cancel", role: .destructive) { runner.cancel() }
                } else {
                    Button("Run A/B probe") { exportURL = nil; runner.start() }
                        .disabled(runner.cases.isEmpty || runner.loadError != nil)
                        .accessibilityIdentifier("fm-representation-probe-run")
                }
            }
            if !runner.records.isEmpty {
                let (old, new) = FMProbeScoring.scores(runner.cases, runner.records)
                Section("Amount · A / B") {
                    metric("Correct money selection", old.correctSelection, new.correctSelection, "/\(old.expectedAmounts)")
                    metric("Non-nil selected text", old.selectedTexts, new.selectedTexts, "/\(runner.records.count)")
                    metric("Deterministically parsed", old.parsedSupported, new.parsedSupported, "/\(runner.records.count)")
                    metric("Wrong money selection", old.wrongSelection, new.wrongSelection)
                    metric("Unsupported money text", old.unsupported, new.unsupported)
                    metric("Grounding failures", old.amountGroundingFailures, new.amountGroundingFailures)
                    Text("A selection parses amountEvidence independently of A's Int and currency. B parses selectedAmountText with Pace's OCR money parser.")
                        .font(.caption)
                }
                Section("Screen · A / B") {
                    metric("Completed correctly", old.completedCorrect, new.completedCorrect, "/\(old.completedTotal)")
                    metric("Negatives not completed", old.negativeRejected, new.negativeRejected, "/\(old.negativeTotal)")
                    metric("All ineligible not completed", old.ineligibleRejected, new.ineligibleRejected, "/\(old.ineligibleTotal)")
                    metric("Completed false positives", old.falsePositiveCompleted, new.falsePositiveCompleted)
                    metric("Transaction false positives", old.falsePositiveTransaction, new.falsePositiveTransaction)
                    metric("Completed false negatives", old.falseNegativeCompleted, new.falseNegativeCompleted)
                    Text("A transaction false positives use isTransaction. A completed eligibility also requires state=completed. B uses only screenKind=completedTransaction.")
                        .font(.caption)
                    Text("A screen outcomes").font(.caption.bold())
                    ForEach(old.kindConfusion.sorted { $0.key < $1.key }, id: \.key) { entry in
                        LabeledContent(entry.key, value: "\(entry.value)")
                    }
                    Text("B screen kinds").font(.caption.bold())
                    ForEach(new.kindConfusion.sorted { $0.key < $1.key }, id: \.key) { entry in
                        LabeledContent(entry.key, value: "\(entry.value)")
                    }
                }
                Section("Other fields · A / B") {
                    metric("Merchant", old.merchantCorrect, new.merchantCorrect, "/\(old.positiveTotal)")
                    metric("Date/time", old.dateCorrect, new.dateCorrect, "/\(old.positiveTotal)")
                    metric("Reference", old.referenceCorrect, new.referenceCorrect, "/\(old.positiveTotal)")
                    metric("Median latency ms", old.medianMS, new.medianMS)
                    metric("Refusals", old.errors["refusal", default: 0], new.errors["refusal", default: 0])
                    Text("A errors: \(display(old.errors)); B errors: \(display(new.errors))").font(.caption)
                }
                Section("Export") {
                    if let exportURL { ShareLink("Share detailed A/B JSON", item: exportURL) }
                    else if !runner.running {
                        Button("Prepare detailed A/B JSON") { exportURL = runner.exportFile() }
                    }
                }
                Section("Per-case evidence") {
                    ForEach(runner.records) { pair in
                        if let item = runner.cases.first(where: { $0.id == pair.caseID }) {
                            DisclosureGroup(pair.caseID) {
                                LabeledContent("Expected kind", value: FMProbeCases.expectedKind(item))
                                LabeledContent("Expected amount minor", value: item.expected.amountMinor.map(String.init) ?? "—")
                                LabeledContent("Expected other", value: "\(item.expected.merchant ?? "—") · \(item.expected.occurredAt ?? "—") · \(item.expected.reference ?? "—")")
                                Text(FMScreenshotPrompt.input(item)).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                                if let claim = pair.v1.claim {
                                    LabeledContent("A screen", value: "\(claim.isTransaction) · \(claim.state) · \(claim.certainty)")
                                    LabeledContent("A amount", value: "\(claim.amountMinor.map(String.init) ?? "—") · \(claim.amountEvidence ?? "—") · \(claim.currency ?? "—")")
                                    LabeledContent("A other", value: "\(claim.merchant ?? "—") · \(claim.dateTimeEvidence ?? "—") · \(claim.reference ?? "—")")
                                }
                                if let checked = pair.v1.verified {
                                    LabeledContent("A verified", value: "\(checked.amountMinor.map(String.init) ?? "—") · \(checked.merchant ?? "—") · \(checked.occurredAt ?? "—") · \(checked.reference ?? "—")")
                                    Text("A rejected: \(display(checked.rejected))").font(.caption)
                                }
                                if let claim = pair.diagnostic.claim {
                                    LabeledContent("B kind", value: "\(claim.screenKind) · eligible \(claim.completedCaptureEligible) · \(claim.certainty)")
                                    LabeledContent("B selected money", value: claim.selectedAmountText ?? "—")
                                    LabeledContent("B other", value: "\(claim.merchant ?? "—") · \(claim.dateTimeEvidence ?? "—") · \(claim.reference ?? "—")")
                                }
                                if let parsed = pair.diagnostic.parsedMoney {
                                    LabeledContent("B parse", value: "\(parsed.status) · \(parsed.amountMinor.map(String.init) ?? "—") · \(parsed.currency ?? "—")")
                                    LabeledContent("B money source", value: parsed.ocrObservation ?? "—")
                                }
                                if let checked = pair.diagnostic.verifiedOtherFields {
                                    LabeledContent("B verified other", value: "\(checked.merchant ?? "—") · \(checked.occurredAt ?? "—") · \(checked.reference ?? "—")")
                                    Text("B rejected other: \(display(checked.rejected))").font(.caption)
                                }
                                LabeledContent("Latency A / B", value: "\(Int(pair.v1.latencyMS)) / \(Int(pair.diagnostic.latencyMS)) ms")
                                if let error = pair.v1.errorKind { Text("A error: \(error) · \(pair.v1.errorMessage ?? "")").foregroundStyle(.red) }
                                if let error = pair.diagnostic.errorKind { Text("B error: \(error) · \(pair.diagnostic.errorMessage ?? "")").foregroundStyle(.red) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("FM representation probe")
        .onAppear { runner.refreshAvailability() }
    }

    private func metric(_ title: String, _ a: Int, _ b: Int, _ denominator: String = "") -> some View {
        LabeledContent(title, value: "\(a)\(denominator) / \(b)\(denominator)")
    }

    private func display<T>(_ values: [String: T]) -> String {
        values.isEmpty ? "none" : values.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }.joined(separator: "; ")
    }
}
#endif
