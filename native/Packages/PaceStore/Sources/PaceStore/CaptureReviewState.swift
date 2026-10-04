import Foundation
import PaceCore

public enum CaptureReviewState: CaseIterable, Equatable, Sendable {
    case checkOnce, category, ambiguousAmount, amountMissing, merchantMissing, duplicate, unusuallyLarge, mayHaveFailed, dateUnclear
}

/// Local answers advance the presentation, never the stored trust decision.
public struct CaptureReviewAnswers: Equatable, Sendable {
    public var fields: Set<CaptureField> = []
    public var keepDuplicate = false
    public var amountChecked = false
    public init() {}
}

extension CaptureReviewDraft {
    /// Existing usable category evidence is a suggestion, never a selected answer.
    public var suggestedCategory: String? {
        guard fieldTrust[.category] == .usable, let categoryName, categoryName != "Other" else { return nil }
        return categoryName
    }

    public func reviewState(answers: CaptureReviewAnswers = .init()) -> CaptureReviewState {
        if duplicateMatch != nil && !answers.keepDuplicate { return .duplicate }
        if !answers.fields.contains(.amount) {
            if anomalySignals.contains(.ambiguousAmount), !amountCandidates.isEmpty { return .ambiguousAmount }
            if amountMinor == nil || unresolved.contains(.amount) { return .amountMissing }
        }
        if !answers.amountChecked && anomalySignals.contains(where: { $0.needsAmountCheck && $0 != .ambiguousAmount }) {
            return .unusuallyLarge
        }
        if !answers.fields.contains(.merchant) && (unresolved.contains(.merchant) || merchant?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) {
            return .merchantMissing
        }
        if !answers.fields.contains(.category) && (unresolved.contains(.category) || categoryPending || fieldTrust[.category] == .unresolved) { return .category }
        if !answers.fields.contains(.date) && unresolved.contains(.date) { return .dateUnclear }
        if !answers.fields.contains(.status) && unresolved.contains(.status) { return .mayHaveFailed }
        return .checkOnce
    }
}

extension ReasonCopy {
    public static func shortReview(_ state: CaptureReviewState) -> String {
        switch state {
        case .checkOnce: "Check once"
        case .category: "New merchant"
        case .ambiguousAmount: "Which amount?"
        case .amountMissing: "Amount missing"
        case .merchantMissing: "Merchant missing"
        case .duplicate: "Possible duplicate"
        case .unusuallyLarge: "Larger than usual"
        case .mayHaveFailed: "May have failed"
        case .dateUnclear: "Date unclear"
        }
    }

    public static func question(_ state: CaptureReviewState, amount: String, hasUntrustedAmount: Bool = false) -> String {
        switch state {
        case .checkOnce: "Check this capture once"
        case .category: "Which category is this?"
        case .ambiguousAmount: "Which amount did you pay?"
        case .amountMissing: hasUntrustedAmount ? "Is \(amount) right?" : "How much did you pay?"
        case .merchantMissing: "Where did you pay?"
        case .duplicate: "Looks like this payment is already in Pace"
        case .unusuallyLarge: "Is \(amount) right?"
        case .mayHaveFailed: "This payment may not have gone through"
        case .dateUnclear: "When was this?"
        }
    }

    public static func evidence(_ state: CaptureReviewState, draft: CaptureReviewDraft, reported: Bool) -> String? {
        switch state {
        case .checkOnce:
            return reported ? nil : draft.source == .backTap ?
                "Pace checks new Back Tap captures before it saves them automatically. Nothing looks wrong with this one." :
                "Check the details before saving this payment."
        case .category:
            return draft.fieldTrust[.merchant] == .trusted || draft.fieldTrust[.category] == .trusted ?
                "Choose a category for this payment." : "First payment Pace has seen at this merchant."
        case .ambiguousAmount: return "The screen showed \(draft.amountCandidates.count) amounts."
        case .amountMissing: return "Pace couldn't read the amount on the screen."
        case .merchantMissing: return "The capture didn't include a merchant name."
        case .duplicate: return "Compare this capture with the payment already in Pace."
        case .unusuallyLarge:
            let signals = draft.anomalySignals
            if signals.contains(.merchantLarge) { return "Much more than you usually spend at \(draft.title)." }
            if signals.contains(.personalLarge) { return "Larger than almost all your payments in the last 90 days." }
            if signals.contains(.pathLarge) { return "Larger than most of your payments in the last 90 days." }
            if signals.contains(.newMerchantLarge) { return "Larger than most of your payments, at a merchant Pace hasn't seen before." }
            return "Pace double-checks larger payments while it learns your spending."
        case .mayHaveFailed: return "The screen didn't show it as successful."
        case .dateUnclear: return "Pace couldn't confirm the date on the screen."
        }
    }
}
