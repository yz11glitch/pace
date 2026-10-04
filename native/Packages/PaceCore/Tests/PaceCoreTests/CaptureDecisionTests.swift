import PaceCore
import Testing

@Suite("Capture trust")
struct CaptureDecisionTests {
    let instant = Instant(iso: "2026-09-27T04:00:00+00:00")!

    func input(amount: Int? = 1_250, merchant: String? = "ZUS Coffee") -> CaptureRequest {
        CaptureRequest(source: "wallet", path: "apple_pay", amountMinor: amount, merchant: merchant,
                       capturedAt: instant, timeZone: "Asia/Kuala_Lumpur",
                       amountTrust: amount == nil ? .unresolved : .trusted,
                       merchantTrust: merchant == nil ? .unresolved : .usable)
    }

    let known = CaptureMerchant(id: "zus", name: "ZUS Coffee", categoryID: "food-drink",
                                known: true, categoryTrusted: true, resolution: "exact_alias")

    @Test func highAndStages() {
        var policy = CaptureTrustPolicy(); policy.testingCeilingMinor = nil
        let high = CaptureTrustDecision.decide(input(), merchant: known, history: .init(),
                                               duplicateMatchID: nil, policy: policy)
        #expect(high.disposition == .save)
        policy.stage = .observe
        #expect(CaptureTrustDecision.decide(input(), merchant: known, history: .init(),
                                             duplicateMatchID: nil, policy: policy).disposition == .draft)
    }

    @Test func mediumNeedsAutomatic() {
        let raw = CaptureMerchant(name: "Unknown", known: false)
        var policy = CaptureTrustPolicy(); policy.testingCeilingMinor = nil
        let request = input(merchant: "Unknown")
        #expect(CaptureTrustDecision.decide(request, merchant: raw, history: .init(),
                                             duplicateMatchID: nil, policy: policy).disposition == .draft)
        policy.stage = .automatic
        let result = CaptureTrustDecision.decide(request, merchant: raw, history: .init(),
                                                 duplicateMatchID: nil, policy: policy)
        #expect(result.disposition == .save && result.categoryPending)
    }

    @Test func missingFieldsAndDuplicate() {
        var policy = CaptureTrustPolicy(); policy.testingCeilingMinor = nil
        let missing = CaptureTrustDecision.decide(input(amount: nil), merchant: known,
                                                  history: .init(), duplicateMatchID: nil, policy: policy)
        #expect(missing.disposition == .draft && missing.unresolved == [.amount])
        let duplicate = CaptureTrustDecision.decide(input(), merchant: known,
                                                    history: .init(), duplicateMatchID: "existing", policy: policy)
        #expect(duplicate.disposition == .draft && duplicate.duplicateMatchID == "existing")
    }

    @Test func anomalySignalsAndSwitch() {
        var policy = CaptureTrustPolicy(); policy.testingCeilingMinor = 1_000
        let cold = CaptureTrustDecision.decide(input(), merchant: known, history: .init(),
                                               duplicateMatchID: nil, policy: policy)
        #expect(cold.disposition == .draft && cold.anomalySignals.contains("cold-start testing ceiling"))
        policy.reviewUnusual = false
        #expect(CaptureTrustDecision.decide(input(), merchant: known, history: .init(),
                                             duplicateMatchID: nil, policy: policy).disposition == .save)
        var ambiguous = input(); ambiguous.extractionAmbiguous = true
        #expect(CaptureTrustDecision.decide(ambiguous, merchant: known, history: .init(),
                                             duplicateMatchID: nil, policy: policy).disposition == .draft)
    }

    @Test func merchantHistorySignal() {
        var policy = CaptureTrustPolicy(); policy.testingCeilingMinor = nil
        let amount = input(amount: 10_000)
        let history = CaptureHistory(merchantAmounts: [1_000, 1_000, 1_100, 1_200, 1_000])
        let result = CaptureTrustDecision.decide(amount, merchant: known, history: history,
                                                 duplicateMatchID: nil, policy: policy)
        #expect(result.disposition == .draft && result.anomalySignals.contains("above merchant robust bound"))
    }

    @Test func ladderThresholdsAndDemotion() {
        let policy = CaptureTrustPolicy()
        #expect(CaptureLadder.next(.observe, evidence: .init(reviewedCaptures: 19, amountErrors: 0, merchantErrors: 0), policy: policy) == .observe)
        #expect(CaptureLadder.next(.observe, evidence: .init(reviewedCaptures: 20, amountErrors: 0, merchantErrors: 1), policy: policy) == .assisted)
        #expect(CaptureLadder.next(.assisted, evidence: .init(reviewedCaptures: 100, amountErrors: 2, merchantErrors: 10), policy: policy) == .automatic)
        #expect(CaptureLadder.next(.automatic, evidence: .init(reviewedCaptures: 101, amountErrors: 1, merchantErrors: 0, autoSavedAmountError: true), policy: policy) == .assisted)
    }

    @Test func lessProvenPathUsesLowerPersonalThreshold() {
        var policy = CaptureTrustPolicy(); policy.testingCeilingMinor = nil
        let history = CaptureHistory(personalAmounts: Array(100...129).map { $0 * 100 })
        let request = input(amount: 12_800)
        let assisted = CaptureTrustDecision.decide(request, merchant: known, history: history,
                                                   duplicateMatchID: nil, policy: policy)
        #expect(assisted.anomalySignals.contains("above assisted path threshold"))
        policy.stage = .automatic
        let automatic = CaptureTrustDecision.decide(request, merchant: known, history: history,
                                                    duplicateMatchID: nil, policy: policy)
        #expect(automatic.disposition == .save)
    }
}
