import Foundation
import GRDB
import PaceCore

/// Consumer provenance only; unknown paths stay generic instead of guessing a provider.
public enum CaptureSource: Equatable, Sendable {
    case applePay, backTap, other

    public init(source: String, path: String?) {
        if source == "wallet" { self = .applePay }
        else if source == "screenshot", path == "screenshot_intentional_fm" { self = .backTap }
        else { self = .other }
    }

    public var label: String {
        switch self { case .applePay: "Apple Pay"; case .backTap: "Back Tap"; case .other: "Capture" }
    }
    public var fallbackTitle: String {
        switch self { case .applePay: "Apple Pay payment"; case .backTap: "Back Tap payment"; case .other: "Captured payment" }
    }
}

/// Projection of persisted anomaly signals, never a new trust decision.
public enum CaptureAnomaly: Equatable, Sendable {
    case ambiguousAmount, merchantLarge, personalLarge, newMerchantLarge, pathLarge, learningLarge, other

    public var needsAmountCheck: Bool { self != .other }

    init(storedSignal: String) {
        switch storedSignal {
        case "amount extraction ambiguous": self = .ambiguousAmount
        case "cold-start testing ceiling": self = .learningLarge
        case "above personal 99th percentile": self = .personalLarge
        case "new merchant above personal 90th percentile": self = .newMerchantLarge
        case "above merchant robust bound": self = .merchantLarge
        case "above observe path threshold", "above assisted path threshold", "above automatic path threshold": self = .pathLarge
        default: self = .other
        }
    }
}

public enum CaptureAttentionReason: CaseIterable, Equatable, Sendable {
    case category, amount, merchant, duplicate, date, status, payment
}

/// Step 1's intentionally small copy catalogue. Raw diagnostics never pass through.
public enum ReasonCopy {
    /// The pending notification shares the attention vocabulary. The original
    /// diagnostic reason is read only here and never returned as consumer copy.
    public static func short(_ result: CaptureResult) -> String {
        if result.duplicateMatchID != nil { return short(.duplicate) }
        let anomalies = result.reason.split(separator: ",")
            .map { CaptureAnomaly(storedSignal: $0.trimmingCharacters(in: .whitespaces)) }
        if result.amountMinor == nil || result.unresolved.contains(.amount) ||
            anomalies.contains(where: \.needsAmountCheck) { return short(.amount) }
        if result.merchant == nil || result.unresolved.contains(.merchant) { return short(.merchant) }
        if result.categoryPending || result.unresolved.contains(.category) { return short(.category) }
        if result.unresolved.contains(.date) { return short(.date) }
        if result.unresolved.contains(.status) { return short(.status) }
        return short(.payment)
    }

    public static func short(_ reason: CaptureAttentionReason) -> String {
        switch reason {
        case .category: "Needs a category"
        case .amount: "Check the amount"
        case .merchant: "Merchant needed"
        case .duplicate: "Possible duplicate"
        case .date: "Check the date"
        case .status: "Check this payment"
        case .payment: "Check this payment"
        }
    }
}

public struct CaptureAttentionCounts: Equatable, Sendable {
    public let draftCount: Int
    public let categoryPendingCount: Int
    /// Available only when the sole actionable item is a draft.
    public let singleDraftID: String?
    public var total: Int { draftCount + categoryPendingCount }

    public var summary: String {
        var parts: [String] = []
        if draftCount > 0 {
            parts.append(draftCount == 1 ? "1 capture needs you" : "\(draftCount) captures need you")
        }
        if categoryPendingCount > 0 { parts.append("\(categoryPendingCount) needs a category") }
        return parts.joined(separator: " · ")
    }

    public static let empty = CaptureAttentionCounts(draftCount: 0, categoryPendingCount: 0, singleDraftID: nil)
}

extension Queries {
    public static func captureAttention(_ db: Database) throws -> CaptureAttentionCounts {
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(status = 'draft'), 0) AS drafts,
                   COALESCE(SUM(status = 'confirmed' AND category_pending = 1
                     AND source IN ('wallet', 'screenshot')), 0) AS categories,
                   MIN(CASE WHEN status = 'draft' THEN id END) AS draft_id
            FROM transactions WHERE deleted_at IS NULL
            """)!
        let drafts: Int = row["drafts"], categories: Int = row["categories"]
        return CaptureAttentionCounts(draftCount: drafts, categoryPendingCount: categories,
            singleDraftID: drafts == 1 && categories == 0 ? row["draft_id"] : nil)
    }

    /// Global attention is independent of History's period, filter and row limit.
    public static func categoryPendingCaptures(_ db: Database) throws -> [StoredTransaction] {
        try Row.fetchAll(db, sql: StoredTransaction.select + """
             WHERE t.status = 'confirmed' AND t.deleted_at IS NULL AND t.category_pending = 1
             AND t.source IN ('wallet', 'screenshot') ORDER BY t.created_at DESC, t.id
            """).map(StoredTransaction.init)
    }
}
