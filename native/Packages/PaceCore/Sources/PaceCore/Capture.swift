import Foundation

/// Values are assertions by an adapter, with their evidence kept separately.
/// A Wallet Shortcut parameter is never assumed to exist merely because it is named here.
public enum CaptureFieldTrust: String, Codable, Sendable { case trusted, usable, unresolved }
public enum CaptureStage: String, Codable, Sendable { case observe, assisted, automatic }
public enum CaptureField: String, Codable, Hashable, Sendable { case amount, merchant, category, date, status }

public protocol CaptureInputAdapter {
    associatedtype Payload
    func adapt(_ payload: Payload, capturedAt: Instant, timeZone: String) -> CaptureRequest
}

public struct CaptureRequest: Sendable {
    public var source: String
    public var path: String
    public var amountMinor: Int?
    public var merchant: String?
    public var categoryID: String?
    public var occurredAt: Instant?
    public var capturedAt: Instant
    public var timeZone: String
    public var reference: String?
    public var idempotencyKey: String?
    public var rawFields: [String: String]
    public var amountCandidates: [String]
    public var amountTrust: CaptureFieldTrust
    public var merchantTrust: CaptureFieldTrust
    public var categoryTrust: CaptureFieldTrust
    public var dateTrust: CaptureFieldTrust
    public var statusClean: Bool
    public var extractionAmbiguous: Bool

    public init(source: String, path: String, amountMinor: Int?, merchant: String?, categoryID: String? = nil,
                occurredAt: Instant? = nil, capturedAt: Instant, timeZone: String,
                reference: String? = nil, idempotencyKey: String? = nil, rawFields: [String: String] = [:],
                amountTrust: CaptureFieldTrust = .unresolved, merchantTrust: CaptureFieldTrust = .unresolved,
                categoryTrust: CaptureFieldTrust = .unresolved,
                dateTrust: CaptureFieldTrust = .trusted, statusClean: Bool = true,
                extractionAmbiguous: Bool = false, amountCandidates: [String] = []) {
        self.source = source; self.path = path; self.amountMinor = amountMinor; self.merchant = merchant
        self.categoryID = categoryID; self.occurredAt = occurredAt; self.capturedAt = capturedAt
        self.timeZone = timeZone; self.reference = reference; self.idempotencyKey = idempotencyKey
        self.rawFields = rawFields; self.amountTrust = amountTrust; self.merchantTrust = merchantTrust
        self.categoryTrust = categoryTrust
        self.dateTrust = dateTrust; self.statusClean = statusClean; self.extractionAmbiguous = extractionAmbiguous
        self.amountCandidates = amountCandidates
    }
}

public struct CaptureMerchant: Sendable {
    public var id: String?
    public var name: String?
    public var categoryID: String?
    public var known: Bool
    public var categoryTrusted: Bool
    public var resolution: String

    public init(id: String? = nil, name: String? = nil, categoryID: String? = nil,
                known: Bool = false, categoryTrusted: Bool = false, resolution: String = "none") {
        self.id = id; self.name = name; self.categoryID = categoryID
        self.known = known; self.categoryTrusted = categoryTrusted; self.resolution = resolution
    }
}

public struct CaptureHistory: Sendable {
    public var merchantAmounts: [Int]
    public var personalAmounts: [Int]
    public init(merchantAmounts: [Int] = [], personalAmounts: [Int] = []) {
        self.merchantAmounts = merchantAmounts; self.personalAmounts = personalAmounts
    }
}

/// Versioned values may be changed by a personal-build Lab without changing the financial engine.
public struct CaptureTrustPolicy: Sendable {
    public var version: Int = 1
    public var stage: CaptureStage = .assisted
    public var pinnedStage: CaptureStage?
    public var saveAutomatically = true
    public var reviewUnusual = true
    public var testingCeilingMinor: Int? = 50_000
    public var minimumPersonalHistory = 30
    public var minimumMerchantHistory = 5
    public var assistedPersonalPercentile = 95
    public var observePersonalPercentile = 90
    public var merchantMedianMultiplier = 3
    public var merchantMADMultiplier = 4
    public var observeToAssistedCount = 20
    public var assistedToAutomaticCount = 100
    public var minimumAmountPrecisionPercent = 98
    public var minimumMerchantPrecisionPercent = 90
    public init() {}
}

public struct CapturePathEvidence: Sendable {
    public var reviewedCaptures: Int
    public var amountErrors: Int
    public var merchantErrors: Int
    public var recentSoftErrors: Int
    public var autoSavedAmountError: Bool
    public init(reviewedCaptures: Int, amountErrors: Int, merchantErrors: Int,
                recentSoftErrors: Int = 0, autoSavedAmountError: Bool = false) {
        self.reviewedCaptures = reviewedCaptures; self.amountErrors = amountErrors
        self.merchantErrors = merchantErrors; self.recentSoftErrors = recentSoftErrors
        self.autoSavedAmountError = autoSavedAmountError
    }
}

/// Pure C13 ladder transition. Evidence collection is separate from the write decision.
public enum CaptureLadder {
    public static func next(_ current: CaptureStage, evidence: CapturePathEvidence,
                            policy: CaptureTrustPolicy) -> CaptureStage {
        if evidence.autoSavedAmountError || evidence.recentSoftErrors >= 2 {
            switch current {
            case .automatic: return .assisted
            case .assisted: return .observe
            case .observe: return .observe
            }
        }
        switch current {
        case .observe:
            return evidence.reviewedCaptures >= policy.observeToAssistedCount &&
                evidence.amountErrors == 0 && evidence.merchantErrors <= 1 ? .assisted : .observe
        case .assisted:
            return evidence.reviewedCaptures >= policy.assistedToAutomaticCount &&
                evidence.amountErrors * 100 <= evidence.reviewedCaptures * (100 - policy.minimumAmountPrecisionPercent) &&
                evidence.merchantErrors * 100 <= evidence.reviewedCaptures * (100 - policy.minimumMerchantPrecisionPercent)
                ? .automatic : .assisted
        case .automatic: return .automatic
        }
    }
}

public enum CaptureDisposition: String, Sendable { case save, draft, duplicate, blocked }
public struct CaptureDecision: Sendable {
    public var disposition: CaptureDisposition
    public var reason: String
    public var unresolved: Set<CaptureField>
    public var categoryPending: Bool
    public var anomalySignals: [String]
    public var duplicateMatchID: String?
}

public enum CaptureTrustDecision {
    private static func percentile(_ values: [Int], _ numerator: Int, _ denominator: Int) -> Int? {
        guard !values.isEmpty else { return nil }
        let ordered = values.sorted()
        return ordered[min(ordered.count - 1, (ordered.count - 1) * numerator / denominator)]
    }

    public static func decide(_ request: CaptureRequest, merchant: CaptureMerchant,
                              history: CaptureHistory, duplicateMatchID: String?,
                              policy: CaptureTrustPolicy) -> CaptureDecision {
        var unresolved = Set<CaptureField>()
        if request.amountMinor == nil || request.amountTrust != .trusted { unresolved.insert(.amount) }
        if merchant.name == nil || request.merchantTrust == .unresolved { unresolved.insert(.merchant) }
        if request.dateTrust == .unresolved { unresolved.insert(.date) }
        if !request.statusClean { unresolved.insert(.status) }
        var signals: [String] = []
        if request.extractionAmbiguous { signals.append("amount extraction ambiguous") }
        if policy.reviewUnusual, let amount = request.amountMinor {
            if history.personalAmounts.count < policy.minimumPersonalHistory {
                if let ceiling = policy.testingCeilingMinor, amount > ceiling { signals.append("cold-start testing ceiling") }
            } else {
                if let p99 = percentile(history.personalAmounts, 99, 100), amount > p99 {
                    signals.append("above personal 99th percentile")
                }
                let reliabilityPercentile = policy.stage == .observe ? policy.observePersonalPercentile
                    : policy.stage == .assisted ? policy.assistedPersonalPercentile : 99
                if reliabilityPercentile < 99,
                   let sourceBound = percentile(history.personalAmounts, reliabilityPercentile, 100),
                   amount > sourceBound {
                    signals.append("above \(policy.stage.rawValue) path threshold")
                }
                if !merchant.known, let p90 = percentile(history.personalAmounts, 90, 100), amount > p90 {
                    signals.append("new merchant above personal 90th percentile")
                }
            }
            if history.merchantAmounts.count >= policy.minimumMerchantHistory,
               let median = percentile(history.merchantAmounts, 1, 2) {
                let deviations = history.merchantAmounts.map { abs($0 - median) }
                let mad = percentile(deviations, 1, 2) ?? 0
                let bound = max(median * policy.merchantMedianMultiplier,
                                median + policy.merchantMADMultiplier * mad)
                if amount > bound { signals.append("above merchant robust bound") }
            }
        }
        if let duplicateMatchID {
            return .init(disposition: .draft, reason: "possible duplicate", unresolved: unresolved,
                         categoryPending: false, anomalySignals: signals, duplicateMatchID: duplicateMatchID)
        }
        if !signals.isEmpty {
            return .init(disposition: .draft, reason: signals.joined(separator: ", "), unresolved: unresolved,
                         categoryPending: false, anomalySignals: signals, duplicateMatchID: nil)
        }
        if !unresolved.isEmpty {
            return .init(disposition: .draft, reason: "unresolved " + unresolved.map(\.rawValue).sorted().joined(separator: ", "),
                         unresolved: unresolved, categoryPending: false, anomalySignals: [], duplicateMatchID: nil)
        }
        let high = merchant.known && merchant.categoryTrusted && merchant.categoryID != nil
        let intentionalScreenshot = request.path == "screenshot_intentional_fm"
        let canSave = policy.saveAutomatically &&
            (high || intentionalScreenshot ? policy.stage != .observe : policy.stage == .automatic)
        if intentionalScreenshot {
            return .init(disposition: canSave ? .save : .draft,
                         reason: canSave ? "trusted financial fields" : "path requires review",
                         unresolved: [], categoryPending: false,
                         anomalySignals: [], duplicateMatchID: nil)
        }
        return .init(disposition: canSave ? .save : .draft,
                     reason: canSave ? (high ? "trusted fields and merchant memory" : "reliable numbers; category pending")
                                     : "path requires review",
                     unresolved: high ? [] : [.category], categoryPending: canSave && !high,
                     anomalySignals: [], duplicateMatchID: nil)
    }
}
