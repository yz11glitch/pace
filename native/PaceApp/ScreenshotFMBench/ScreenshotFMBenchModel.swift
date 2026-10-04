#if DEBUG
import Foundation
import FoundationModels
import PaceCore

@Generable(description: "Evidence-bound interpretation of one screenshot OCR result")
nonisolated struct FMScreenshotResult {
    @Guide(description: "True only if the OCR describes an actual transaction or transaction attempt, including pending or failed; false for checkout, account overview, product, chat or unrelated screens")
    var isTransaction: Bool
    @Guide(description: "Payment, transfer, refund, withdrawal, other, or unknown")
    var transactionType: String
    @Guide(description: "Completed, pending, failed, cancelled, or unknown")
    var state: String
    @Guide(description: "confident only when the selected interpretation is well supported; otherwise uncertain")
    var certainty: FMScreenshotCertainty
    @Guide(description: "Selected transaction amount in minor currency units, such as cents; nil if not clear")
    var amountMinor: Int?
    @Guide(description: "Exact OCR text showing that selected amount; nil when amount is nil")
    var amountEvidence: String?
    @Guide(description: "Currency code if explicitly shown or unambiguous from the symbol; otherwise nil")
    var currency: String?
    @Guide(description: "Merchant or counterparty name from OCR; nil if unknown")
    var merchant: String?
    @Guide(description: "Exact OCR text showing the displayed transaction date and time; nil if absent or uncertain")
    var dateTimeEvidence: String?
    @Guide(description: "Primary transaction or reference identifier from OCR; nil if its role is unknown. Never a card/account mask, merchant ID or terminal ID")
    var reference: String?
}

@Generable nonisolated enum FMScreenshotCertainty { case confident, uncertain }

nonisolated enum FMScreenshotPrompt {
    static let version = "prompt-v1"
    static let schema = "schema-v1"
    static let instructions = """
    Interpret one set of Apple Vision OCR observations from a possible financial transaction screen.
    Extract transaction facts only when supported by the OCR. The observations may include screen chrome,
    unrelated balances or totals, card/account information, merchant or terminal metadata, and multiple dates or identifiers.
    Use visual position and nearby labels to distinguish the transaction from those other details.
    A bare ID or an unlabeled number does not establish a transaction reference.
    A checkout request is not proof a payment happened. Pending and failed transaction attempts are still transaction screens.
    Quote the exact OCR observation that supports the selected amount and displayed transaction date/time.
    Abstain with nil for any uncertain field. Do not manufacture missing financial facts or use outside knowledge.
    """

    static func input(_ item: ScreenshotFMBenchmarkCase) -> String {
        let observations = item.lines.enumerated().sorted {
            if abs($0.element.y - $1.element.y) > 0.015 { return $0.element.y < $1.element.y }
            if $0.element.x != $1.element.x { return $0.element.x < $1.element.x }
            return $0.offset < $1.offset
        }.map { _, line in
            let x = Int((line.x * 100).rounded())
            let y = Int((line.y * 100).rounded())
            let alternatives = line.alternates.isEmpty ? "" : " [alt: \(line.alternates.joined(separator: " | "))]"
            return "(x\(x),y\(y)) \(line.text)\(alternatives)"
        }
        return "Vision OCR observations (top-origin coordinates, percent):\n" + observations.joined(separator: "\n")
    }
}

nonisolated struct FMScreenshotEvaluator: Sendable {
    let model: SystemLanguageModel

    func evaluate(_ item: ScreenshotFMBenchmarkCase) async -> ScreenshotFMBenchmarkRecord {
        let instant = Instant(iso: item.capturedAt)!
        let g3 = ScreenshotFMGrounding.g3Fields(lines: item.lines, capturedAt: instant, timeZone: item.timeZone)
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Double {
            let delta = clock.now - start
            return Double(delta.components.seconds) * 1000 + Double(delta.components.attoseconds) / 1e15
        }
        do {
            let session = LanguageModelSession(model: model, instructions: FMScreenshotPrompt.instructions)
            let response = try await session.respond(to: FMScreenshotPrompt.input(item),
                                                     generating: FMScreenshotResult.self,
                                                     options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 450))
            let output = response.content
            let claim = ScreenshotFMClaim(isTransaction: output.isTransaction,
                transactionType: output.transactionType, state: output.state,
                certainty: output.certainty == .confident ? "confident" : "uncertain",
                amountMinor: output.amountMinor, amountEvidence: output.amountEvidence,
                currency: output.currency, merchant: output.merchant,
                dateTimeEvidence: output.dateTimeEvidence, reference: output.reference)
            let verified = ScreenshotFMGrounding.verify(claim, lines: item.lines,
                                                        capturedAt: instant, timeZone: item.timeZone)
            var inputTokens: Int?, outputTokens: Int?
            if #available(iOS 27.0, macOS 27.0, *) {
                inputTokens = response.usage.input.totalTokenCount
                outputTokens = response.usage.output.totalTokenCount
            }
            return .init(caseID: item.id, claim: claim, verified: verified, g3: g3,
                         latencyMS: elapsed(), inputTokens: inputTokens, outputTokens: outputTokens)
        } catch let LanguageModelSession.GenerationError.refusal(refusal, _) {
            let duration = elapsed()
            let explanation = (try? await refusal.explanation.content) ?? "no explanation returned"
            return .init(caseID: item.id, claim: nil, verified: nil, g3: g3,
                         errorKind: "refusal", errorMessage: explanation, latencyMS: duration)
        } catch {
            let classified = BenchClassifier.classify(error)
            return .init(caseID: item.id, claim: nil, verified: nil, g3: g3,
                         errorKind: classified.kind, errorMessage: classified.message, latencyMS: elapsed())
        }
    }
}
#endif
