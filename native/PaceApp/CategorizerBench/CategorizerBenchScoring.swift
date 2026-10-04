#if DEBUG
import Foundation

/// The model's self-reported certainty. Foundation Models exposes no token
/// probabilities, so this is a constrained label, not a calibrated confidence.
nonisolated enum BenchCertainty: String, Codable, Sendable { case confident, uncertain }

nonisolated struct BenchModelOutput: Codable, Hashable, Sendable {
    var businessType: String
    /// A Pace category or `BenchPrompt.unknown`.
    var category: String
    var certainty: BenchCertainty
}

nonisolated struct BenchError: Codable, Hashable, Sendable {
    /// `availability`, `decodingFailure`, `unsupportedGuide`, `guardrail`, `refusal`, …
    var kind: String
    var message: String
    var isStructuredGeneration: Bool { kind == "decodingFailure" || kind == "unsupportedGuide" || kind == "invalidCategory" }
}

nonisolated struct BenchResult: Codable, Hashable, Identifiable, Sendable {
    let caseID: String
    let pass: Int
    let output: BenchModelOutput?
    let error: BenchError?
    let latencyMS: Double
    let inputTokens: Int?
    let outputTokens: Int?
    /// The seed merchant pack's trusted category, when it has one (non-AI baseline).
    let baseline: String?
    var id: String { "\(caseID)#\(pass)" }
}

nonisolated enum BenchOutcome: String, Codable, CaseIterable, Sendable {
    /// Committed to an acceptable category.
    case correct
    /// Abstained where abstention is expected or allowed.
    case correctAbstain
    /// `abstainOr`: committed to a tolerated category.
    case tolerated
    /// Categorizable, but the model abstained (coverage loss, not harm).
    case missed
    /// Categorizable, committed to a wrong category.
    case confidentWrong
    /// Should abstain, committed to a category outside the tolerated list.
    case forced
    case error

    var isAcceptable: Bool { self == .correct || self == .correctAbstain || self == .tolerated }
    var isDangerous: Bool { self == .confidentWrong || self == .forced }
}

nonisolated enum BenchScoring {
    /// A prediction Pace could act on: a real category with certainty `confident`.
    /// `Unknown`, or any category marked `uncertain`, is an abstention.
    static func committed(_ output: BenchModelOutput, allowed: Set<String>) -> String? {
        output.certainty == .confident && allowed.contains(output.category) ? output.category : nil
    }

    static func outcome(_ expected: BenchExpectation, committed: String?, failed: Bool) -> BenchOutcome {
        if failed { return .error }
        switch expected {
        case let .category(list):
            guard let committed else { return .missed }
            return list.contains(committed) ? .correct : .confidentWrong
        case .abstain:
            return committed == nil ? .correctAbstain : .forced
        case let .abstainOr(list):
            guard let committed else { return .correctAbstain }
            return list.contains(committed) ? .tolerated : .forced
        }
    }

    static func outcome(_ item: BenchCase, _ result: BenchResult, allowed: Set<String>) -> BenchOutcome {
        guard let output = result.output, result.error == nil else { return .error }
        return outcome(item.expected, committed: committed(output, allowed: allowed), failed: false)
    }

    /// What the seed merchant pack alone does: a trusted hit commits, a miss abstains.
    static func baselineOutcome(_ item: BenchCase, _ baseline: String?) -> BenchOutcome {
        outcome(item.expected, committed: baseline, failed: false)
    }

    /// Option A as a simulation only: merchant memory first, the model on a miss.
    static func combinedOutcome(_ item: BenchCase, _ result: BenchResult, allowed: Set<String>) -> BenchOutcome {
        result.baseline != nil ? baselineOutcome(item, result.baseline) : outcome(item, result, allowed: allowed)
    }
}

nonisolated struct BenchTally: Codable, Hashable, Sendable {
    var total = 0
    var counts: [BenchOutcome: Int] = [:]

    subscript(_ outcome: BenchOutcome) -> Int { counts[outcome, default: 0] }
    var acceptable: Int { BenchOutcome.allCases.filter(\.isAcceptable).reduce(0) { $0 + self[$1] } }
    var dangerous: Int { self[.confidentWrong] + self[.forced] }
    var committed: Int { self[.correct] + self[.tolerated] + dangerous }

    mutating func add(_ outcome: BenchOutcome) {
        total += 1
        counts[outcome, default: 0] += 1
    }
}

nonisolated struct BenchLatency: Codable, Hashable, Sendable {
    var coldMS: Double?
    var warmCount = 0
    var warmMedianMS: Double?
    var warmP95MS: Double?
    var warmMaxMS: Double?

    init(_ results: [BenchResult]) {
        guard let first = results.first else { return }
        coldMS = first.latencyMS
        let warm = results.dropFirst().filter { $0.error == nil }.map(\.latencyMS).sorted()
        warmCount = warm.count
        guard !warm.isEmpty else { return }
        warmMedianMS = Self.percentile(warm, 0.5)
        warmP95MS = warm.count >= 20 ? Self.percentile(warm, 0.95) : nil
        warmMaxMS = warm.last
    }

    /// Nearest-rank percentile of a sorted sample.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
    }
}

nonisolated struct BenchSummary: Codable, Sendable {
    var results = 0
    var passes = 0
    var overall = BenchTally()
    /// Cases whose expectation is `.category`.
    var categorizable = BenchTally()
    /// The raw category (ignoring certainty) was acceptable, on categorizable cases.
    var categorizableTentativeCorrect = 0
    var mustAbstain = BenchTally()
    var mustAbstainForcedIntoOther = 0
    var dependsOnPurchase = BenchTally()
    var byVariant: [BenchVariant: BenchTally] = [:]
    var byGroup: [BenchGroup: BenchTally] = [:]
    /// Merchants that appear with at least one source-category variant, split by variant.
    var pairedByVariant: [BenchVariant: BenchTally] = [:]
    var pairedMerchants = 0
    var certaintyMix: [BenchCertainty: Int] = [:]
    var unknownAnswers = 0
    var errorsByKind: [String: Int] = [:]
    var structuredFailures = 0
    var latency: BenchLatency
    var baseline = BenchTally()
    var combined = BenchTally()
    /// Cases run more than once whose (category, certainty) matched on every pass.
    var consistentAcrossPasses: Int?
    var repeatedCases = 0

    init(cases: [BenchCase], results input: [BenchResult], allowed: Set<String>) {
        let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        let pairedNames = Set(cases.filter { $0.variant != .merchantOnly }.map(\.merchant))
        pairedMerchants = pairedNames.count
        results = input.count
        passes = input.map(\.pass).max() ?? 0
        latency = BenchLatency(input)
        for result in input {
            guard let item = byID[result.caseID] else { continue }
            let outcome = BenchScoring.outcome(item, result, allowed: allowed)
            overall.add(outcome)
            byVariant[item.variant, default: .init()].add(outcome)
            byGroup[item.group, default: .init()].add(outcome)
            if pairedNames.contains(item.merchant) { pairedByVariant[item.variant, default: .init()].add(outcome) }
            switch item.expected {
            case let .category(list):
                categorizable.add(outcome)
                if let output = result.output, list.contains(output.category) { categorizableTentativeCorrect += 1 }
            case .abstain:
                mustAbstain.add(outcome)
                if outcome == .forced, result.output?.category == "Other" { mustAbstainForcedIntoOther += 1 }
            case .abstainOr:
                dependsOnPurchase.add(outcome)
            }
            if let output = result.output {
                certaintyMix[output.certainty, default: 0] += 1
                if !allowed.contains(output.category) { unknownAnswers += 1 }
            }
            if let error = result.error {
                errorsByKind[error.kind, default: 0] += 1
                if error.isStructuredGeneration { structuredFailures += 1 }
            }
            if result.pass == 1 {
                baseline.add(BenchScoring.baselineOutcome(item, result.baseline))
            }
            combined.add(BenchScoring.combinedOutcome(item, result, allowed: allowed))
        }
        let repeated = Dictionary(grouping: input, by: \.caseID).filter { $0.value.count > 1 }
        repeatedCases = repeated.count
        if !repeated.isEmpty {
            consistentAcrossPasses = repeated.values.filter { runs in
                Set(runs.map { "\($0.output?.category ?? "error:\($0.error?.kind ?? "")")|\($0.output?.certainty.rawValue ?? "")" }).count == 1
            }.count
        }
    }
}

nonisolated enum BenchReport {
    static func fraction(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "\(part)/0" : "\(part)/\(whole) (\(Int((Double(part) / Double(whole) * 100).rounded()))%)"
    }

    static func ms(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) ms" } ?? "n/a" }

    static func line(_ tally: BenchTally) -> String {
        "acceptable \(fraction(tally.acceptable, tally.total)) · dangerous \(fraction(tally.dangerous, tally.total)) · missed \(tally[.missed]) · errors \(tally[.error])"
    }

    /// A compact, paste-able report: environment, metrics, then every dangerous and missed case.
    static func text(environment: BenchEnvironment, cases: [BenchCase], results: [BenchResult],
                     summary s: BenchSummary, allowed: Set<String>, durationSeconds: Double?) -> String {
        var out: [String] = []
        out.append("PACE APPLE FM CATEGORIZER BENCHMARK")
        out.append("device \(environment.deviceModel) · \(environment.osVersion)")
        out.append("model SystemLanguageModel.default · \(environment.modelVariant ?? "variant n/a") (after run: \(environment.modelVariantAfterRun ?? "n/a")) · context \(environment.contextSize.map(String.init) ?? "n/a") · \(environment.availability)")
        out.append("locale en_MY supported \(environment.supportsMalaysianEnglish) · current \(environment.supportsCurrentLocale)")
        out.append("\(environment.promptVersion) · \(environment.schemaVersion) · \(environment.datasetVersion) · sampling \(environment.sampling) · passes \(s.passes)")
        out.append("started \(environment.startedAt) · duration \(durationSeconds.map { String(format: "%.0f s", $0) } ?? "n/a")")
        out.append("")
        out.append("OVERALL \(s.results) results")
        out.append("  exact (correct + correct abstain) \(fraction(s.overall[.correct] + s.overall[.correctAbstain], s.overall.total))")
        out.append("  " + line(s.overall))
        out.append("  dangerous among committed \(fraction(s.overall.dangerous, s.overall.committed))")
        out.append("CATEGORIZABLE \(s.categorizable.total)")
        out.append("  correct \(fraction(s.categorizable[.correct], s.categorizable.total)) · wrong \(s.categorizable[.confidentWrong]) · abstained \(s.categorizable[.missed]) · errors \(s.categorizable[.error])")
        out.append("  precision when committed \(fraction(s.categorizable[.correct], s.categorizable.committed))")
        out.append("  raw guess right ignoring certainty \(fraction(s.categorizableTentativeCorrect, s.categorizable.total))")
        out.append("MUST ABSTAIN \(s.mustAbstain.total)")
        out.append("  abstained \(fraction(s.mustAbstain[.correctAbstain], s.mustAbstain.total)) · forced \(s.mustAbstain[.forced]) (into Other \(s.mustAbstainForcedIntoOther)) · errors \(s.mustAbstain[.error])")
        out.append("DEPENDS ON PURCHASE \(s.dependsOnPurchase.total)")
        out.append("  abstained \(s.dependsOnPurchase[.correctAbstain]) · tolerated \(s.dependsOnPurchase[.tolerated]) · wrong \(s.dependsOnPurchase[.forced]) · errors \(s.dependsOnPurchase[.error])")
        out.append("BY VARIANT (all cases)")
        for variant in BenchVariant.allCases { out.append("  \(variant.rawValue): \(line(s.byVariant[variant] ?? .init()))") }
        out.append("BY VARIANT (\(s.pairedMerchants) merchants run with and without a source category)")
        for variant in BenchVariant.allCases { out.append("  \(variant.rawValue): \(line(s.pairedByVariant[variant] ?? .init()))") }
        out.append("BY GROUP")
        for group in BenchGroup.allCases { out.append("  \(group.rawValue): \(line(s.byGroup[group] ?? .init()))") }
        out.append("CERTAINTY confident \(s.certaintyMix[.confident, default: 0]) · uncertain \(s.certaintyMix[.uncertain, default: 0]) · Unknown answers \(s.unknownAnswers)")
        out.append("LATENCY cold \(ms(s.latency.coldMS)) · warm median \(ms(s.latency.warmMedianMS)) · p95 \(ms(s.latency.warmP95MS)) · max \(ms(s.latency.warmMaxMS)) · n \(s.latency.warmCount)")
        out.append("ERRORS \(s.errorsByKind.isEmpty ? "none" : s.errorsByKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")) · structured-generation failures \(s.structuredFailures)")
        out.append("BASELINE seed merchant memory only (pass 1): \(line(s.baseline)) · committed \(s.baseline.committed)")
        out.append("SIMULATED A memory then model: \(line(s.combined))")
        if let consistent = s.consistentAcrossPasses {
            out.append("CONSISTENCY identical on every pass \(fraction(consistent, s.repeatedCases))")
        }
        let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        let flagged = results.compactMap { result -> (BenchOutcome, BenchCase, BenchResult)? in
            guard let item = byID[result.caseID] else { return nil }
            let outcome = BenchScoring.outcome(item, result, allowed: allowed)
            return outcome.isDangerous || outcome == .missed || outcome == .error ? (outcome, item, result) : nil
        }
        for heading in [BenchOutcome.confidentWrong, .forced, .error, .missed] {
            let rows = flagged.filter { $0.0 == heading }
            guard !rows.isEmpty else { continue }
            out.append("")
            out.append("\(heading.rawValue.uppercased()) \(rows.count)")
            for (_, item, result) in rows { out.append("  " + describe(item, result)) }
        }
        return out.joined(separator: "\n")
    }

    static func describe(_ item: BenchCase, _ result: BenchResult) -> String {
        let context = [item.sourceCategory.map { "src \($0)" }, item.payment].compactMap { $0 }.joined(separator: ", ")
        let got = result.output.map { "\($0.category) · \($0.certainty.rawValue) · \"\($0.businessType)\"" }
            ?? "error \(result.error?.kind ?? "?")"
        return "\(item.merchant)\(context.isEmpty ? "" : " [\(context)]") · expected \(item.expected.label) · got \(got)\(result.pass > 1 ? " · pass \(result.pass)" : "")"
    }
}

/// What was measured, on what, with which prompt: enough to rerun after an OS/model update.
nonisolated struct BenchEnvironment: Codable, Sendable {
    var osVersion: String
    var deviceModel: String
    var availability: String
    var modelVariant: String?
    /// Re-read when the run ends: the variant reported before the first request can differ.
    var modelVariantAfterRun: String? = nil
    var contextSize: Int?
    var supportsMalaysianEnglish: Bool
    var supportsCurrentLocale: Bool
    var promptVersion: String
    var schemaVersion: String
    var datasetVersion: String
    var sampling: String
    var appVersion: String
    var startedAt: String
}

/// The exported JSON: self-contained, so two runs can be diffed offline.
nonisolated struct BenchExport: Codable, Sendable {
    var environment: BenchEnvironment
    var durationSeconds: Double?
    var categories: [String]
    var instructions: String
    var cases: [BenchCase]
    var results: [BenchResult]
    var summary: BenchSummary
}
#endif
