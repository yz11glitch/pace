import Foundation
import PaceCore
import PaceStore

/// Deterministic data for UI tests (`-PaceSeed <name>` with `-PaceInMemory YES`).
enum DemoSeed {
    static func apply(_ name: String, executor: LedgerExecutor, today: LocalDate) {
        if name == "showcase" {
            seedShowcase(executor: executor)
            return
        }
        if name.hasPrefix("review-") {
            let captured = Instant(iso: "2026-09-28T04:00:00Z")!
            let taught = try! executor.create(TransactionDraft(type: .expense, amountMinor: 100,
                occurredAt: Instant(seconds: captured.seconds - 86_400), tzIdentifier: "Asia/Kuala_Lumpur",
                localDate: LocalDate(iso: "2026-09-27")!, merchantText: "Review Shop", categoryID: "other", source: .keypad))
            _ = try! executor.update(taught.transaction.id, .init(categoryID: "groceries"))
            var input = WalletCaptureAdapter.request(amount: name == "review-large" ? "RM 99999.99" : "RM 8.90",
                merchant: name == "review-missing-merchant" ? nil : "Review Shop", cardOrPass: nil, name: nil, shortcutInput: nil,
                capturedAt: captured, timeZone: "Asia/Kuala_Lumpur")
            if name == "review-date" { input.dateTrust = .unresolved }
            if name == "review-failed" { input.statusClean = false }
            var policy = CaptureTrustPolicy(); policy.pinnedStage = .observe
            _ = try! CaptureProcessor(database: executor.database).process(input, policy: policy)
            return
        }
        if name == "ledger-scale" || name == "ledger-edge" {
            apply("demo", executor: executor, today: today)
            let day = LocalDate(iso: "2026-09-28")!
            let instant = Instant(iso: "2026-09-28T04:00:00Z")!
            for index in 0..<(name == "ledger-scale" ? 620 : 4) {
                let type = TransactionType.allCases[index % 4]
                _ = try! executor.create(TransactionDraft(type: type, amountMinor: index == 0 ? 50 : index == 1 ? 9_999_999 : 2_390,
                    occurredAt: Instant(seconds: instant.seconds + Int64(index)), tzIdentifier: "Asia/Kuala_Lumpur", localDate: day,
                    merchantText: index == 0 ? nil : index == 1 ? "A very long merchant name at Pavilion Kuala Lumpur with another branch name that wraps" : "Ledger entry \(index)",
                    categoryID: type == .contribution ? nil : type == .income ? "income" : "other", source: .keypad))
            }
            return
        }
        if ["worst", "attention-one", "attention-many", "attention-category"].contains(name) {
            apply("demo", executor: executor, today: today)
            seedAttention(name, database: executor.database)
            return
        }
        guard name == "locale-probe" || name == "demo" else { return }
        let zone = "Asia/Kuala_Lumpur"
        func add(_ type: TransactionType, _ amount: Int, _ date: String, merchant: String? = nil, category: String? = "Other",
                 rule: (String, String)? = nil) {
            let day = LocalDate(iso: date)!
            let draft = TransactionDraft(
                type: type, amountMinor: amount, occurredAt: Instant(iso: "\(date)T12:00:00+08:00")!, tzIdentifier: zone,
                localDate: day, merchantText: merchant,
                categoryID: type == .contribution ? nil : category.map { merchantKey($0).replacingOccurrences(of: " ", with: "-") },
                source: .keypad, recurringRuleID: rule?.0, occurrenceDate: rule.flatMap { LocalDate(iso: $0.1) })
            _ = try? executor.create(draft)
        }
        _ = try? executor.setProfile(ProfileInput(
            paydayAnchor: 25, salaryMinor: 350_000, salaryDay: 25,
            effectiveCycleStart: LocalDate(iso: "2026-01-25")!,
            savingsMode: .percentage, savingsBasisPoints: 2_000, fixedCommitmentsMinor: 35_000))
        add(.income, 350_000, "2026-09-25", merchant: "Employer", category: "Income", rule: ("salary", "2026-09-25"))
        add(.expense, 1_234_567, "2026-09-25", merchant: "Big Purchase", category: "Shopping")
        add(.expense, 1_850, "2026-09-26", merchant: "Chicken Rice Shop", category: "Food & Drink")
        add(.refund, 2_850, "2026-09-26", merchant: "Shopee", category: "Shopping")
        add(.contribution, 50_000, "2026-09-26")
        add(.expense, 999, "2026-09-24", merchant: "Grab", category: "Transport")
    }

    /// Public-only fictional portfolio data; never used with a file database.
    private static func seedShowcase(executor: LedgerExecutor) {
        let zone = "Asia/Kuala_Lumpur"
        let profile = try! executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 420_000,
            salaryDay: 25, effectiveCycleStart: LocalDate(iso: "2026-09-25")!,
            savingsMode: .percentage, savingsBasisPoints: 1_500,
            fixedCommitmentsMinor: 115_000)) // Rent 900 + Phone 50 + Gym 200.
        func add(_ type: TransactionType, _ amount: Int, _ day: String, _ merchant: String?, _ category: String?) {
            _ = try! executor.create(TransactionDraft(type: type, amountMinor: amount,
                occurredAt: Instant(iso: "\(day)T10:00:00+08:00")!, tzIdentifier: zone,
                localDate: LocalDate(iso: day)!, merchantText: merchant, categoryID: category, source: .keypad,
                recurringRuleID: type == .income ? profile.salaryRule?.id : nil,
                occurrenceDate: type == .income ? LocalDate(iso: day) : nil))
        }
        add(.income, 420_000, "2026-09-25", "Employer", "income")
        add(.refund, 1_500, "2026-09-26", "Bookshop", "shopping")
        let expenses: [(Int, String, String)] = [
            (650, "Kopi Corner", "food-drink"), (900, "Nasi Lemak Stall", "food-drink"),
            (1_420, "Grab", "transport"), (4_830, "Pasar Mini", "groceries"),
            (2_390, "Northwind Pharmacy", "health"), (3_500, "Bookshop", "shopping"),
            (6_000, "Petrol", "transport"), (2_800, "Cinema", "entertainment")]
        for day in 15...28 {
            let item = expenses[(day - 15) % expenses.count]
            add(.expense, item.0, String(format: "2026-09-%02d", day), item.1, item.2)
        }
        add(.contribution, 63_000, "2026-09-25", nil, nil)
        let captured = Instant(iso: "2026-09-28T04:00:00Z")!
        let processor = CaptureProcessor(database: executor.database, now: { captured.date })
        var policy = CaptureTrustPolicy(); policy.pinnedStage = .observe
        let ambiguous = CaptureRequest(source: "screenshot", path: "screenshot_generic",
            amountMinor: nil, merchant: "Pasar Mini", capturedAt: captured, timeZone: zone,
            amountTrust: .unresolved, merchantTrust: .usable, extractionAmbiguous: true,
            amountCandidates: ["RM 12.00", "RM 21.00"])
        precondition(try! processor.process(ambiguous, policy: policy).outcome == .draft)
        let missing = WalletCaptureAdapter.request(amount: "RM 23.90", merchant: nil,
            cardOrPass: nil, name: nil, shortcutInput: nil,
            capturedAt: Instant(seconds: captured.seconds + 60), timeZone: zone)
        precondition(try! processor.process(missing, policy: policy).outcome == .draft)
        let category = WalletCaptureAdapter.request(amount: "RM 8.90", merchant: "Kopi Kiosk",
            cardOrPass: nil, name: nil, shortcutInput: nil,
            capturedAt: Instant(seconds: captured.seconds + 120), timeZone: zone)
        precondition(try! processor.process(category, policy: policy).outcome == .draft)
        let review = CaptureRequest(source: "screenshot", path: "screenshot_intentional_fm",
            amountMinor: 4_290, merchant: "Kedai Buku Ilmu", categoryID: "shopping",
            occurredAt: captured, capturedAt: Instant(seconds: captured.seconds + 180), timeZone: zone,
            amountTrust: .trusted, merchantTrust: .usable, categoryTrust: .usable)
        precondition(try! processor.process(review, policy: policy).outcome == .draft)
    }

    /// Small repeatable Step 0 baseline, using the production adapters and processor.
    /// `demo` supplies zero pending items; the attention seeds isolate navigation cases.
    private static func seedAttention(_ name: String, database: PaceDatabase) {
        let captured = Instant(iso: "2026-09-28T04:00:00Z")!
        func pay(_ amount: String?, _ merchant: String?, _ offset: Int64,
                 stage: CaptureStage = .observe) {
            let input = WalletCaptureAdapter.request(amount: amount.map { "RM \($0)" }, merchant: merchant,
                cardOrPass: nil, name: nil, shortcutInput: nil,
                capturedAt: Instant(seconds: captured.seconds + offset), timeZone: "Asia/Kuala_Lumpur")
            var policy = CaptureTrustPolicy(); policy.pinnedStage = stage
            let time = input.capturedAt.date
            let result = try! CaptureProcessor(database: database, now: { time }).process(input, policy: policy)
            precondition(result.outcome == (stage == .automatic ? .saved : .draft))
        }
        if name != "attention-category" {
            pay("18.50", "Restoran Nasi Kandar Pelita Jalan Ampang (Cawangan Suria KLCC) Sdn Bhd", 0)
        }
        if name == "attention-many" || name == "worst" {
            pay("23.90", nil, 60) // Missing merchant.
            pay(nil, "Pasar Malam", 120) // Missing amount.
            pay("23.90", nil, 180) // Possible duplicate + missing merchant.
            let ambiguous = CaptureRequest(source: "screenshot", path: "screenshot_generic",
                amountMinor: nil, merchant: "Kedai Buku", categoryID: "shopping",
                capturedAt: Instant(seconds: captured.seconds + 240), timeZone: "Asia/Kuala_Lumpur",
                amountTrust: .unresolved, merchantTrust: .usable, extractionAmbiguous: true,
                amountCandidates: ["RM 12.00", "RM 21.00"])
            let time = ambiguous.capturedAt.date
            precondition(try! CaptureProcessor(database: database, now: { time }).process(ambiguous).outcome == .draft)
        }
        if name == "attention-category" || name == "worst" {
            pay("8.90", "Kiosk Baru", 3_600, stage: .automatic)
        }
    }
}
