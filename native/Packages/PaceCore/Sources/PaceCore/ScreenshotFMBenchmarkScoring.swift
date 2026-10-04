#if DEBUG
import Foundation

public struct ScreenshotFMBenchmarkRecord: Codable, Sendable {
    public let caseID: String
    public let claim: ScreenshotFMClaim?
    public let verified: ScreenshotFMVerified?
    public let g3: ScreenshotFMG3Fields
    public let errorKind: String?
    public let errorMessage: String?
    public let latencyMS: Double
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(caseID: String, claim: ScreenshotFMClaim?, verified: ScreenshotFMVerified?,
                g3: ScreenshotFMG3Fields, errorKind: String? = nil, errorMessage: String? = nil,
                latencyMS: Double = 0, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.caseID = caseID; self.claim = claim; self.verified = verified; self.g3 = g3
        self.errorKind = errorKind; self.errorMessage = errorMessage; self.latencyMS = latencyMS
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}

public struct ScreenshotFMMetric: Codable, Sendable {
    public var correct = 0
    public var total = 0
    public var missing = 0
    public var wrong = 0
    public var fraction: String { total == 0 ? "n/a" : "\(correct)/\(total) (\(Int(Double(correct) * 100 / Double(total)))%)" }
    mutating func add(_ matched: Bool, missing isMissing: Bool) {
        total += 1
        if matched { correct += 1 }
        else if isMissing { missing += 1 }
        else { wrong += 1 }
    }
}

public struct ScreenshotFMFieldMetrics: Codable, Sendable {
    public var amount = ScreenshotFMMetric()
    public var merchant = ScreenshotFMMetric()
    public var date = ScreenshotFMMetric()
    public var reference = ScreenshotFMMetric()
}

public struct ScreenshotFMBenchmarkSummary: Codable, Sendable {
    public var casesRun = 0
    public var classification = ScreenshotFMMetric()
    public var appleFM = ScreenshotFMFieldMetrics()
    public var g3 = ScreenshotFMFieldMetrics()
    public var completeUseful = ScreenshotFMMetric()
    public var abstention = ScreenshotFMMetric()
    public var groundingFailures: [String: Int] = [:]
    public var dangerousErrors: [String: Int] = [:]
    public var errors: [String: Int] = [:]
    public var refusalCount = 0
    public var availabilityFailures = 0
    public var coldLatencyMS: Double?
    public var medianLatencyMS: Double?
    public var p95LatencyMS: Double?

    public init(cases: [ScreenshotFMBenchmarkCase], records: [ScreenshotFMBenchmarkRecord],
                availabilityFailed: Bool = false) {
        if availabilityFailed { availabilityFailures = 1 }
        let indexed = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        var latencies: [Double] = []
        for record in records {
            guard let item = indexed[record.caseID] else { continue }
            casesRun += 1
            if let kind = record.errorKind {
                errors[kind, default: 0] += 1
                if kind == "refusal" { refusalCount += 1 }
                if kind == "unavailable" { availabilityFailures += 1 }
            }
            if record.latencyMS > 0 { latencies.append(record.latencyMS) }
            if let claim = record.claim {
                classification.add(claim.isTransaction == item.expected.isTransaction, missing: false)
                if claim.isTransaction && !item.expected.isTransaction {
                    dangerousErrors["falsePositiveTransaction", default: 0] += 1
                }
            } else { classification.add(false, missing: true) }

            let expected = item.expected
            let verified = record.verified
            let amountOK = equal(expected.amountMinor, verified?.amountMinor)
            let merchantOK = equal(expected.merchant, verified?.merchant)
            let dateOK = equalDate(expected.occurredAt, verified?.occurredAt)
            let referenceOK = equal(expected.reference, verified?.reference)
            if expected.isTransaction {
                appleFM.amount.add(amountOK, missing: verified?.amountMinor == nil)
                appleFM.merchant.add(merchantOK, missing: verified?.merchant == nil)
                appleFM.date.add(dateOK, missing: verified?.occurredAt == nil)
                appleFM.reference.add(referenceOK, missing: verified?.reference == nil)
                g3.amount.add(equal(expected.amountMinor, record.g3.amountMinor), missing: record.g3.amountMinor == nil)
                g3.merchant.add(equal(expected.merchant, record.g3.merchant), missing: record.g3.merchant == nil)
                g3.date.add(equalDate(expected.occurredAt, record.g3.occurredAt), missing: record.g3.occurredAt == nil)
                g3.reference.add(equal(expected.reference, record.g3.reference), missing: record.g3.reference == nil)
                completeUseful.add(record.claim?.isTransaction == true && amountOK && merchantOK && dateOK && referenceOK,
                                   missing: record.claim == nil)
            }
            for field in ["amount", "merchant", "date", "reference"] {
                if verified?.rejected[field] != nil { groundingFailures[field, default: 0] += 1 }
            }
            if let claim = record.claim {
                let claims: [(String, Bool, Bool)] = [
                    ("amount", claim.amountMinor != nil, equal(expected.amountMinor, claim.amountMinor)),
                    ("merchant", claim.merchant != nil, equal(expected.merchant, claim.merchant)),
                    ("date", claim.dateTimeEvidence != nil, expected.occurredAt != nil && dateOK),
                    ("reference", claim.reference != nil, expected.reference != nil && referenceOK)
                ]
                for (field, made, correct) in claims {
                    if made && !correct && (field != "merchant" || claim.certainty == "confident") {
                        dangerousErrors[field, default: 0] += 1
                    }
                    if !made && fieldExpected(field, expected) { abstention.add(false, missing: true) }
                    if !made && !fieldExpected(field, expected) { abstention.add(true, missing: false) }
                }
            }
        }
        coldLatencyMS = latencies.first
        let warm = Array(latencies.dropFirst()).sorted()
        if !warm.isEmpty {
            medianLatencyMS = warm[warm.count / 2]
            p95LatencyMS = warm[min(warm.count - 1, Int(Double(warm.count - 1) * 0.95))]
        }
    }

    private func fieldExpected(_ field: String, _ expected: ScreenshotFMBenchmarkTruth) -> Bool {
        switch field {
        case "amount": expected.amountMinor != nil
        case "merchant": expected.merchant != nil
        case "date": expected.occurredAt != nil
        default: expected.reference != nil
        }
    }
    private func equal(_ a: Int?, _ b: Int?) -> Bool { a == b }
    private func equalDate(_ a: String?, _ b: String?) -> Bool {
        if let a, let b, let first = Instant(iso: a), let second = Instant(iso: b) { return first == second }
        return a == b
    }
    private func equal(_ a: String?, _ b: String?) -> Bool {
        func norm(_ s: String?) -> String? {
            s?.precomposedStringWithCompatibilityMapping.lowercased()
                .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
        }
        return norm(a) == norm(b)
    }
}
#endif
