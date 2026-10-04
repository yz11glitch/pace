#if DEBUG
import Foundation
import FoundationModels
import Observation
import PaceCore
import SwiftUI

/// Fixed subset of the existing v1 OCR corpus; no new or live screenshots.
private enum SingleDecisionCases {
    static let ids = [
        "A-hero-0", "F-receipt-0", "A-hero-28", "B16", "historical-maybank-synthetic",
        "N-overview-0", "N-list-1", "N-checkout-2", "N-chat-20", "N-promo-3",
        "N-product-6", "N-weather-5", "A-pending", "A-failed", "B24"
    ]

    static func selected(from corpus: ScreenshotFMBenchmarkCorpus) -> [ScreenshotFMBenchmarkCase]? {
        let indexed = Dictionary(uniqueKeysWithValues: corpus.cases.map { ($0.id, $0) })
        let result = ids.compactMap { indexed[$0] }
        return result.count == ids.count ? result : nil
    }

    static func expectedKind(_ id: String) -> String {
        switch id {
        case "N-overview-0", "B24": "accountOverview"
        case "N-list-1": "transactionList"
        case "N-checkout-2": "checkout"
        case "N-chat-20": "paymentRequest"
        case "N-promo-3": "offer"
        case "N-product-6", "N-weather-5": "nonFinancial"
        case "A-pending": "pendingTransaction"
        case "A-failed": "failedTransaction"
        default: "completedTransaction"
        }
    }
}

@Generable(description: "One money selection from OCR")
nonisolated private struct SelectedMoneyOnly {
    @Guide(description: "Copy only the exact money text for a completed transaction amount from OCR. Return NONE if there is no completed transaction amount. Do not calculate or explain")
    var selectedMoneyText: String
}

@Generable(description: "Kind of the whole screenshot")
nonisolated private struct ScreenKindOnly {
    @Guide(description: "Classify the whole screen, not an isolated row, price, or payment request")
    var screenKind: SingleDecisionScreenKind
}

@Generable nonisolated private enum SingleDecisionScreenKind {
    case completedTransaction, pendingTransaction, failedTransaction, transactionList
    case accountOverview, checkout, paymentRequest, offer, nonFinancial, uncertain

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
        case .nonFinancial: "nonFinancial"
        case .uncertain: "uncertain"
        }
    }
}

private enum SingleDecisionPrompt {
    static let version = "single-decision-probe-v1"
    static let money = """
    Read these Apple Vision OCR observations. Select the exact money text for the amount of a completed transaction detail.
    If the screen is a list, account overview, checkout, payment request, offer, product, unrelated screen, or a pending or failed attempt, return NONE.
    Return only the OCR money text or NONE. Do not calculate, convert, or explain.
    """
    static let screen = """
    Read these Apple Vision OCR observations. Classify the whole screen.
    A completed transaction detail is different from a pending or failed attempt, transaction list, account overview,
    checkout, payment request, offer, product, or unrelated screen. A row in a list is not a whole transaction detail.
    Choose uncertain if the screen kind is not clear. Do not extract fields or explain.
    """
}

private struct MoneyOnlyRecord: Codable, Sendable {
    let selectedMoneyText: String?
    /// FoundationModels Response.rawContent.jsonString; generated structured content, not model token logits.
    let rawGeneratedContentJSON: String?
    let exactOCRTextPresent: Bool?
    let parsedMoney: ScreenshotFMProbeMoneyResult?
    let groundingAccepted: Bool
    let errorKind: String?
    let errorMessage: String?
    let latencyMS: Double
    let inputTokens: Int?
    let outputTokens: Int?
}

private struct ScreenOnlyRecord: Codable, Sendable {
    let screenKind: String?
    let rawGeneratedContentJSON: String?
    let completedCaptureEligible: Bool
    let errorKind: String?
    let errorMessage: String?
    let latencyMS: Double
    let inputTokens: Int?
    let outputTokens: Int?
}

private struct SingleDecisionPair: Codable, Identifiable, Sendable {
    let caseID: String
    let money: MoneyOnlyRecord
    let screen: ScreenOnlyRecord
    var id: String { caseID }
}

private struct SingleDecisionSummary: Codable {
    var completedCases = 0
    var noneligibleCases = 0
    var moneySelectionsAttempted = 0
    var supportedSelections = 0
    var semanticAmountsCorrect = 0
    var parseSuccesses = 0
    var wrongMoneySelections = 0
    var unsupportedSelections = 0
    var correctAbstentions = 0
    var completedRecognized = 0
    var noneligibleRejected = 0
    var falsePositives = 0
    var falseNegatives = 0
    var kindConfusion: [String: Int] = [:]
    var moneyErrors: [String: Int] = [:]
    var screenErrors: [String: Int] = [:]
    var moneyLatencies: [Double] = []
    var screenLatencies: [Double] = []

    init(cases: [ScreenshotFMBenchmarkCase], records: [SingleDecisionPair]) {
        let indexed = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        for pair in records {
            guard let item = indexed[pair.caseID] else { continue }
            let expectedKind = SingleDecisionCases.expectedKind(item.id)
            let completed = expectedKind == "completedTransaction"
            if completed { completedCases += 1 } else { noneligibleCases += 1 }
            if let error = pair.money.errorKind { moneyErrors[error, default: 0] += 1 }
            if let error = pair.screen.errorKind { screenErrors[error, default: 0] += 1 }
            if pair.money.latencyMS > 0 { moneyLatencies.append(pair.money.latencyMS) }
            if pair.screen.latencyMS > 0 { screenLatencies.append(pair.screen.latencyMS) }
            let money = pair.money.parsedMoney
            if let selected = pair.money.selectedMoneyText, selected != "NONE" { moneySelectionsAttempted += 1 }
            if pair.money.exactOCRTextPresent == true { supportedSelections += 1 }
            if money?.status == "supported" { parseSuccesses += 1 }
            if pair.money.groundingAccepted {
                if completed && money?.amountMinor == item.expected.amountMinor { semanticAmountsCorrect += 1 }
                else { wrongMoneySelections += 1 }
            } else if pair.money.selectedMoneyText != nil && money?.status != "abstained" {
                unsupportedSelections += 1
            } else if !completed && money?.status == "abstained" { correctAbstentions += 1 }
            let actualKind = pair.screen.screenKind ?? "error"
            kindConfusion["\(expectedKind) → \(actualKind)", default: 0] += 1
            if completed {
                if pair.screen.completedCaptureEligible { completedRecognized += 1 }
                else { falseNegatives += 1 }
            } else if pair.screen.completedCaptureEligible { falsePositives += 1 }
            else { noneligibleRejected += 1 }
        }
    }

    var moneyMedianMS: Int { median(moneyLatencies) }
    var screenMedianMS: Int { median(screenLatencies) }
    private func median(_ values: [Double]) -> Int {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : Int(sorted[sorted.count / 2])
    }
}

private struct SingleDecisionExport: Codable {
    let version: String
    let moneySchema: String
    let screenSchema: String
    let moneyInstructions: String
    let screenInstructions: String
    let cases: [ScreenshotFMBenchmarkCase]
    let records: [SingleDecisionPair]
    let summary: SingleDecisionSummary
    let device: String
    let os: String
    let availability: String
    let startedAt: String
}

private struct SingleDecisionEvaluator: Sendable {
    let model: SystemLanguageModel

    func money(_ item: ScreenshotFMBenchmarkCase) async -> MoneyOnlyRecord {
        let clock = ContinuousClock(); let start = clock.now
        func elapsed() -> Double {
            let delta = clock.now - start
            return Double(delta.components.seconds) * 1000 + Double(delta.components.attoseconds) / 1e15
        }
        do {
            let session = LanguageModelSession(model: model, instructions: SingleDecisionPrompt.money)
            let response = try await session.respond(to: FMScreenshotPrompt.input(item),
                generating: SelectedMoneyOnly.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120))
            let selected = response.content.selectedMoneyText.trimmingCharacters(in: .whitespacesAndNewlines)
            let abstained = selected == "NONE"
            let exact = abstained ? nil : item.lines.contains { line in
                line.text.contains(selected) || line.alternates.contains { $0.contains(selected) }
            }
            let parsed = ScreenshotFMProbeMoney.parse(abstained ? nil : selected, lines: item.lines,
                capturedAt: Instant(iso: item.capturedAt)!, timeZone: item.timeZone)
            var inputTokens: Int?, outputTokens: Int?
            if #available(iOS 27.0, macOS 27.0, *) {
                inputTokens = response.usage.input.totalTokenCount
                outputTokens = response.usage.output.totalTokenCount
            }
            return .init(selectedMoneyText: selected, rawGeneratedContentJSON: response.rawContent.jsonString,
                exactOCRTextPresent: exact, parsedMoney: parsed,
                groundingAccepted: exact == true && parsed.status == "supported",
                errorKind: nil, errorMessage: nil, latencyMS: elapsed(),
                inputTokens: inputTokens, outputTokens: outputTokens)
        } catch let LanguageModelSession.GenerationError.refusal(refusal, _) {
            let duration = elapsed()
            let explanation = (try? await refusal.explanation.content) ?? "no explanation returned"
            return .init(selectedMoneyText: nil, rawGeneratedContentJSON: nil,
                exactOCRTextPresent: nil, parsedMoney: nil, groundingAccepted: false,
                errorKind: "refusal", errorMessage: explanation, latencyMS: duration,
                inputTokens: nil, outputTokens: nil)
        } catch {
            let error = BenchClassifier.classify(error)
            return .init(selectedMoneyText: nil, rawGeneratedContentJSON: nil,
                exactOCRTextPresent: nil, parsedMoney: nil, groundingAccepted: false,
                errorKind: error.kind, errorMessage: error.message, latencyMS: elapsed(),
                inputTokens: nil, outputTokens: nil)
        }
    }

    func screen(_ item: ScreenshotFMBenchmarkCase) async -> ScreenOnlyRecord {
        let clock = ContinuousClock(); let start = clock.now
        func elapsed() -> Double {
            let delta = clock.now - start
            return Double(delta.components.seconds) * 1000 + Double(delta.components.attoseconds) / 1e15
        }
        do {
            let session = LanguageModelSession(model: model, instructions: SingleDecisionPrompt.screen)
            let response = try await session.respond(to: FMScreenshotPrompt.input(item),
                generating: ScreenKindOnly.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120))
            let kind = response.content.screenKind.label
            var inputTokens: Int?, outputTokens: Int?
            if #available(iOS 27.0, macOS 27.0, *) {
                inputTokens = response.usage.input.totalTokenCount
                outputTokens = response.usage.output.totalTokenCount
            }
            return .init(screenKind: kind, rawGeneratedContentJSON: response.rawContent.jsonString,
                completedCaptureEligible: kind == "completedTransaction", errorKind: nil,
                errorMessage: nil, latencyMS: elapsed(), inputTokens: inputTokens, outputTokens: outputTokens)
        } catch let LanguageModelSession.GenerationError.refusal(refusal, _) {
            let duration = elapsed()
            let explanation = (try? await refusal.explanation.content) ?? "no explanation returned"
            return .init(screenKind: nil, rawGeneratedContentJSON: nil, completedCaptureEligible: false,
                errorKind: "refusal", errorMessage: explanation, latencyMS: duration,
                inputTokens: nil, outputTokens: nil)
        } catch {
            let error = BenchClassifier.classify(error)
            return .init(screenKind: nil, rawGeneratedContentJSON: nil, completedCaptureEligible: false,
                errorKind: error.kind, errorMessage: error.message, latencyMS: elapsed(),
                inputTokens: nil, outputTokens: nil)
        }
    }
}

@MainActor @Observable private final class SingleDecisionRunner {
    static let shared = SingleDecisionRunner()
    private(set) var cases: [ScreenshotFMBenchmarkCase] = []
    private(set) var loadError: String?
    private(set) var records: [SingleDecisionPair] = []
    private(set) var availability = "not checked"
    private(set) var running = false
    private(set) var current: String?
    private(set) var startedAt = ""
    private var task: Task<Void, Never>?

    private init() {
        do {
            let corpus = try JSONDecoder().decode(ScreenshotFMBenchmarkCorpus.self, from: ScreenshotFMBenchData.json)
            guard let selected = SingleDecisionCases.selected(from: corpus) else {
                loadError = "A fixed case ID is missing from the v1 corpus"; return
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
        let evaluator = SingleDecisionEvaluator(model: model)
        task = Task { [weak self, cases] in
            for (index, item) in cases.enumerated() {
                if Task.isCancelled { break }
                self?.current = item.id
                let money: MoneyOnlyRecord
                let screen: ScreenOnlyRecord
                if index.isMultiple(of: 2) {
                    money = await evaluator.money(item)
                    if Task.isCancelled { break }
                    screen = await evaluator.screen(item)
                } else {
                    screen = await evaluator.screen(item)
                    if Task.isCancelled { break }
                    money = await evaluator.money(item)
                }
                self?.records.append(.init(caseID: item.id, money: money, screen: screen))
            }
            self?.running = false
            self?.current = nil
            self?.task = nil
        }
    }

    func cancel() { task?.cancel() }

    func exportFile() -> URL? {
        guard !records.isEmpty else { return nil }
        let export = SingleDecisionExport(version: SingleDecisionPrompt.version,
            moneySchema: "selectedMoneyText: String (NONE means abstain)",
            screenSchema: "screenKind: completedTransaction | pendingTransaction | failedTransaction | transactionList | accountOverview | checkout | paymentRequest | offer | nonFinancial | uncertain",
            moneyInstructions: SingleDecisionPrompt.money, screenInstructions: SingleDecisionPrompt.screen,
            cases: cases, records: records, summary: .init(cases: cases, records: records),
            device: BenchDevice.hardwareModel, os: ProcessInfo.processInfo.operatingSystemVersionString,
            availability: availability, startedAt: startedAt)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pace-fm-single-decision-\(startedAt.replacingOccurrences(of: ":", with: "-")).json")
        guard let data = try? encoder.encode(export), (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}

struct ScreenshotFMSingleDecisionProbeView: View {
    @State private var runner = SingleDecisionRunner.shared
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section("Two one-field calls · DEBUG only") {
                Text("\(runner.cases.count) fixed v1 OCR cases. Money and screen calls use separate fresh on-device sessions; no capture or storage.")
                    .font(.caption)
                LabeledContent("Model", value: runner.availability)
                if let error = runner.loadError { Text(error).foregroundStyle(.red) }
                if runner.running {
                    ProgressView(value: Double(runner.records.count), total: Double(runner.cases.count)) {
                        Text("\(runner.records.count)/\(runner.cases.count) · \(runner.current ?? "")")
                    }
                    Button("Cancel", role: .destructive) { runner.cancel() }
                } else {
                    Button("Run single-decision probe") { exportURL = nil; runner.start() }
                        .disabled(runner.cases.isEmpty || runner.loadError != nil)
                        .accessibilityIdentifier("fm-single-decision-probe-run")
                }
            }
            if !runner.records.isEmpty {
                let score = SingleDecisionSummary(cases: runner.cases, records: runner.records)
                Section("Money only") {
                    LabeledContent("Exact OCR text present", value: "\(score.supportedSelections)/\(runner.records.count)")
                    LabeledContent("Correct semantic amount", value: "\(score.semanticAmountsCorrect)/\(score.completedCases)")
                    LabeledContent("Deterministic parse success", value: "\(score.parseSuccesses)/\(score.moneySelectionsAttempted)")
                    LabeledContent("Wrong money selection", value: "\(score.wrongMoneySelections)")
                    LabeledContent("Unsupported / invented", value: "\(score.unsupportedSelections)")
                    LabeledContent("Correct abstention", value: "\(score.correctAbstentions)/\(score.noneligibleCases)")
                    LabeledContent("Median latency", value: "\(score.moneyMedianMS) ms")
                    Text("Errors: \(display(score.moneyErrors))").font(.caption)
                }
                Section("Screen kind only") {
                    LabeledContent("Completed recall", value: "\(score.completedRecognized)/\(score.completedCases)")
                    LabeledContent("Noneligible rejection", value: "\(score.noneligibleRejected)/\(score.noneligibleCases)")
                    LabeledContent("False positives / negatives", value: "\(score.falsePositives) / \(score.falseNegatives)")
                    LabeledContent("Median latency", value: "\(score.screenMedianMS) ms")
                    Text("Errors: \(display(score.screenErrors))").font(.caption)
                    ForEach(score.kindConfusion.sorted { $0.key < $1.key }, id: \.key) { entry in
                        LabeledContent(entry.key, value: "\(entry.value)")
                    }
                }
                Section("Export") {
                    if let exportURL { ShareLink("Share detailed JSON", item: exportURL) }
                    else if !runner.running { Button("Prepare detailed JSON") { exportURL = runner.exportFile() } }
                }
                Section("Cases") {
                    ForEach(runner.records) { pair in
                        if let item = runner.cases.first(where: { $0.id == pair.caseID }) {
                            DisclosureGroup(pair.caseID) {
                                let expectedKind = SingleDecisionCases.expectedKind(pair.caseID)
                                let expectedAmount = expectedKind == "completedTransaction" ? item.expected.amountMinor : nil
                                LabeledContent("Fixture source", value: item.source)
                                LabeledContent("Expected kind", value: expectedKind)
                                LabeledContent("Expected completed amount", value: expectedAmount.map(String.init) ?? "none")
                                Text(FMScreenshotPrompt.input(item)).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                                LabeledContent("Money selected", value: pair.money.selectedMoneyText ?? "error")
                                LabeledContent("Verbatim OCR text", value: pair.money.exactOCRTextPresent.map { $0 ? "yes" : "no" } ?? "n/a")
                                LabeledContent("Deterministic parse", value: pair.money.parsedMoney?.status ?? "error")
                                LabeledContent("Money parsed", value: "\(pair.money.parsedMoney?.currency ?? "—") · \(pair.money.parsedMoney?.amountMinor.map(String.init) ?? "—")")
                                LabeledContent("Grounded", value: pair.money.groundingAccepted ? "yes" : "no")
                                LabeledContent("Money correct", value: moneyCorrect(pair.money, expectedAmount: expectedAmount) ? "yes" : "no")
                                LabeledContent("Money latency", value: "\(Int(pair.money.latencyMS)) ms")
                                if let raw = pair.money.rawGeneratedContentJSON { Text("Money raw: \(raw)").font(.caption.monospaced()).textSelection(.enabled) }
                                if let error = pair.money.errorKind { Text("Money error: \(error) · \(pair.money.errorMessage ?? "")").foregroundStyle(.red) }
                                LabeledContent("Screen kind", value: pair.screen.screenKind ?? "error")
                                LabeledContent("Capture eligible", value: pair.screen.completedCaptureEligible ? "yes" : "no")
                                LabeledContent("Screen correct", value: pair.screen.screenKind == expectedKind ? "yes" : "no")
                                LabeledContent("Eligibility correct", value: pair.screen.completedCaptureEligible == (expectedKind == "completedTransaction") ? "yes" : "no")
                                LabeledContent("Screen latency", value: "\(Int(pair.screen.latencyMS)) ms")
                                if let raw = pair.screen.rawGeneratedContentJSON { Text("Screen raw: \(raw)").font(.caption.monospaced()).textSelection(.enabled) }
                                if let error = pair.screen.errorKind { Text("Screen error: \(error) · \(pair.screen.errorMessage ?? "")").foregroundStyle(.red) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("FM single decisions")
        .onAppear { runner.refreshAvailability() }
    }

    private func moneyCorrect(_ record: MoneyOnlyRecord, expectedAmount: Int?) -> Bool {
        if let expectedAmount { return record.groundingAccepted && record.parsedMoney?.amountMinor == expectedAmount }
        return record.parsedMoney?.status == "abstained"
    }
    private func display(_ values: [String: Int]) -> String {
        values.isEmpty ? "none" : values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
    }
}
#endif
