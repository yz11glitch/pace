#if DEBUG
import Foundation
import FoundationModels
import PaceCore

/// Prompt wordings under test. Same categories, definitions, schema and per-case
/// input; only the instruction framing differs. Add a case (never edit one) so
/// runs stay comparable.
nonisolated enum BenchPromptVariant: String, CaseIterable, Codable, Sendable {
    /// Imperative "Rules:" list.
    case v1 = "prompt-v1"
    /// Routine-bookkeeping framing with plain guidance. Added after prompt-v1 drew
    /// deterministic "sensitive content" refusals on the Mac smoke run.
    case v2 = "prompt-v2-bookkeeping"
}

/// Prompt and schema for the benchmark. Bump the versions whenever wording,
/// definitions or schema change so runs stay comparable.
nonisolated enum BenchPrompt {
    static let schemaVersion = "schema-v1"
    static let unknown = "Unknown"

    /// Pace's actual expense taxonomy (`EntryRules`); Income never applies to a payment.
    static let categories = EntryRules.categoryChoices(for: .expense)
    static let outputCategories = categories + [unknown]

    private static let definitions: [String: String] = [
        "Food & Drink": "restaurants, cafés, hawker stalls, fast food, drinks, food delivery",
        "Groceries": "supermarkets, mini-markets, sundry shops, fresh produce",
        "Transport": "fuel, tolls, parking, rides, public transit, vehicle upkeep",
        "Shopping": "retail goods, clothing, electronics, household items, online marketplaces",
        "Bills & Utilities": "electricity, water, sewerage, mobile and internet plans, other recurring bills",
        "Health": "clinics, hospitals, dental, pharmacies, medical care",
        "Entertainment": "cinemas, streaming, games, events, leisure activities",
        "Education": "schools, kindergartens, tuition, universities, courses",
        "Services": "personal and household services such as haircuts, laundry, repairs, courier, printing",
        "Travel": "flights, hotels, travel bookings, intercity trips",
        "Gifts & Donations": "charity, zakat, religious donations, gifts",
        "Other": "an identifiable business that fits none of the above",
    ]

    static func instructions(_ variant: BenchPromptVariant) -> String {
        let list = categories.map { "- \($0): \(definitions[$0] ?? "")" }.joined(separator: "\n")
        switch variant {
        case .v1: return """
        You assign one Pace spending category to a single payment made in Malaysia.
        Merchant names may be Malay, Chinese or English, abbreviated, garbled by OCR, or a registered company name.

        Pace categories:
        \(list)
        - \(unknown): the merchant name and context do not reveal what kind of business it is

        Rules:
        - Decide only from the merchant name and the context given. Do not invent facts about the merchant.
        - A person's name, a generic company or trading name, initials, or a payment gateway does not reveal the business. Answer \(unknown) with certainty uncertain, unless the source category makes it clear.
        - The source category comes from the bank or e-wallet app. It is often right but can be generic or wrong. When it conflicts with a clearly identifiable merchant, follow the merchant.
        - If the business sells things that fit several categories and the purchase is not known, use certainty uncertain.
        - Use certainty confident only when the kind of business is clear.
        """
        case .v2: return """
        You help a personal budgeting app file everyday payments made in Malaysia. This is routine bookkeeping for the account owner.
        For one payment, pick the Pace category that fits the merchant.

        Pace categories:
        \(list)
        - \(unknown): the merchant name and context do not reveal what kind of business it is

        Guidance:
        - Merchant names may be Malay, Chinese or English, abbreviated, garbled by OCR, or a registered company name.
        - If the name is a person's name, a generic company or trading name, initials, or a payment gateway, the kind of business is not known: choose \(unknown) and uncertain, unless the source category makes it clear.
        - The source category comes from the bank or e-wallet app. It is often right but can be generic or wrong. If it conflicts with a clearly identifiable merchant, go with the merchant.
        - If the business sells things in several categories and the purchase is not known, choose uncertain.
        - Choose confident only when the kind of business is clear.
        """
        }
    }

    static func prompt(for item: BenchCase) -> String {
        var lines = ["Merchant: \(item.merchant)"]
        if let source = item.sourceCategory { lines.append("Source category from payment app: \(source)") }
        if let payment = item.payment { lines.append("Payment method: \(payment)") }
        lines.append("Country: Malaysia")
        return lines.joined(separator: "\n")
    }
}

/// Guided-generation schema: the framework constrains decoding to this shape,
/// so the output is never prose parsed with a regex.
@Generable(description: "Pace category decision for one payment merchant")
nonisolated struct MerchantCategoryResult {
    @Guide(description: "The kind of business the merchant name shows, in 1 to 4 words, or unknown")
    var businessType: String
    @Guide(description: "The best Pace category, or Unknown when the kind of business is not identifiable",
           .anyOf(BenchPrompt.outputCategories))
    var category: String
    @Guide(description: "confident only when the kind of business is clear; otherwise uncertain")
    var certainty: MerchantCertainty
}

@Generable
nonisolated enum MerchantCertainty {
    case confident, uncertain
}

nonisolated enum BenchSampling: String, CaseIterable, Codable, Sendable {
    /// Deterministic decoding: reruns isolate model/OS changes from sampling noise.
    case greedy
    /// The framework's default sampling, to measure run-to-run variability.
    case systemDefault

    var options: GenerationOptions {
        switch self {
        case .greedy: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120)
        case .systemDefault: GenerationOptions(maximumResponseTokens: 120)
        }
    }
}

/// One isolated request per case: a fresh session, so no transcript carries over.
/// Only `SystemLanguageModel` is used — the on-device model. Private Cloud
/// Compute is a separate model type this file never references.
nonisolated struct BenchClassifier: Sendable {
    let model: SystemLanguageModel
    let prompt: BenchPromptVariant
    let sampling: BenchSampling

    struct Outcome: Sendable {
        var output: BenchModelOutput?
        var error: BenchError?
        var latencyMS: Double
        var inputTokens: Int?
        var outputTokens: Int?
    }

    func classify(_ item: BenchCase) async -> Outcome {
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Double {
            let duration = clock.now - start
            return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        do {
            let session = LanguageModelSession(model: model, instructions: BenchPrompt.instructions(prompt))
            let response = try await session.respond(to: BenchPrompt.prompt(for: item),
                                                     generating: MerchantCategoryResult.self,
                                                     options: sampling.options)
            let latency = elapsed()
            var tokens: (Int, Int)?
            if #available(iOS 27.0, macOS 27.0, *) {
                tokens = (response.usage.input.totalTokenCount, response.usage.output.totalTokenCount)
            }
            let content = response.content
            let output = BenchModelOutput(businessType: content.businessType, category: content.category,
                                          certainty: content.certainty == .confident ? .confident : .uncertain)
            // `anyOf` should make this impossible; count it as a structured-generation failure if not.
            let error = BenchPrompt.outputCategories.contains(content.category) ? nil
                : BenchError(kind: "invalidCategory", message: content.category)
            return Outcome(output: output, error: error, latencyMS: latency, inputTokens: tokens?.0, outputTokens: tokens?.1)
        } catch let LanguageModelSession.GenerationError.refusal(refusal, _) {
            // Latency stops at the refusal; the explanation is a second, untimed request.
            let latency = elapsed()
            let explanation = (try? await refusal.explanation.content) ?? "no explanation returned"
            return Outcome(output: nil, error: BenchError(kind: "refusal", message: explanation), latencyMS: latency)
        } catch {
            return Outcome(output: nil, error: Self.classify(error), latencyMS: elapsed())
        }
    }

    static func classify(_ error: any Error) -> BenchError {
        let message = String(describing: error)
        // The iOS 27 runtime reports session failures (refusals included) as `LanguageModelError`.
        if #available(iOS 27.0, macOS 27.0, *), let modern = error as? LanguageModelError {
            return classify(modern)
        }
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return BenchError(kind: "other:\(type(of: error))", message: message)
        }
        let kind = switch generation {
        case .exceededContextWindowSize: "exceededContextWindow"
        case .assetsUnavailable: "assetsUnavailable"
        case .guardrailViolation: "guardrail"
        case .unsupportedGuide: "unsupportedGuide"
        case .unsupportedLanguageOrLocale: "unsupportedLanguageOrLocale"
        case .decodingFailure: "decodingFailure"
        case .rateLimited: "rateLimited"
        case .concurrentRequests: "concurrentRequests"
        case .refusal: "refusal"
        @unknown default: "generation:other"
        }
        return BenchError(kind: kind, message: message)
    }

    /// `LanguageModelError.Refusal` exposes no explanation getter, only a description and metadata.
    @available(iOS 27.0, macOS 27.0, *)
    private static func classify(_ error: LanguageModelError) -> BenchError {
        func detail(_ description: String, _ metadata: [String: any Sendable]) -> String {
            metadata.isEmpty ? description
                : description + " · " + metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        }
        return switch error {
        case let .refusal(value): BenchError(kind: "refusal", message: detail(value.debugDescription, value.metadata))
        case let .guardrailViolation(value): BenchError(kind: "guardrail", message: detail(value.debugDescription, value.metadata))
        case let .contextSizeExceeded(value):
            BenchError(kind: "exceededContextWindow", message: detail(value.debugDescription, value.metadata))
        case let .rateLimited(value): BenchError(kind: "rateLimited", message: detail(value.debugDescription, value.metadata))
        case let .unsupportedGenerationGuide(value):
            BenchError(kind: "unsupportedGuide", message: detail(value.debugDescription, value.metadata))
        case let .unsupportedLanguageOrLocale(value):
            BenchError(kind: "unsupportedLanguageOrLocale", message: detail(value.debugDescription, value.metadata))
        case let .timeout(value): BenchError(kind: "timeout", message: detail(value.debugDescription, value.metadata))
        case let .unsupportedCapability(value):
            BenchError(kind: "unsupportedCapability", message: detail(value.debugDescription, value.metadata))
        case let .unsupportedTranscriptContent(value):
            BenchError(kind: "unsupportedTranscriptContent", message: detail(value.debugDescription, value.metadata))
        @unknown default: BenchError(kind: "languageModel:other", message: String(describing: error))
        }
    }
}

nonisolated enum BenchDevice {
    static func availabilityLabel(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available: "available"
        case .unavailable(.deviceNotEligible): "unavailable: device not eligible"
        case .unavailable(.appleIntelligenceNotEnabled): "unavailable: Apple Intelligence not enabled"
        case .unavailable(.modelNotReady): "unavailable: model not ready (downloading or preparing)"
        case let .unavailable(other): "unavailable: \(other)"
        }
    }

    /// Hardware identifier such as `iPhone16,2`, from the public `uname` call.
    static var hardwareModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func environment(model: SystemLanguageModel, prompt: BenchPromptVariant,
                            sampling: BenchSampling) -> BenchEnvironment {
        var variant: String?
        var contextSize: Int?
        if #available(iOS 27.0, macOS 27.0, *) {
            variant = model.variant.displayName
            contextSize = model.contextSize
        }
        let bundle = Bundle.main.infoDictionary
        return BenchEnvironment(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: hardwareModel,
            availability: availabilityLabel(model.availability),
            modelVariant: variant, contextSize: contextSize,
            supportsMalaysianEnglish: model.supportsLocale(Locale(identifier: "en_MY")),
            supportsCurrentLocale: model.supportsLocale(),
            promptVersion: prompt.rawValue, schemaVersion: BenchPrompt.schemaVersion,
            datasetVersion: BenchDataset.version, sampling: sampling.rawValue,
            appVersion: "\(bundle?["CFBundleShortVersionString"] as? String ?? "?") (\(bundle?["CFBundleVersion"] as? String ?? "?"))",
            startedAt: ISO8601DateFormatter().string(from: Date()))
    }
}
#endif
