import Foundation
import GRDB
import PaceCore
import Testing
@testable import PaceStore

@Suite("Ledger executor")
struct ExecutorTests {
    let executor = LedgerExecutor(database: try! PaceDatabase())

    func count(_ sql: String) throws -> Int { try executor.database.writer.read { try Int.fetchOne($0, sql: sql)! } }

    @Test("a new Pace database starts with no financial history")
    func freshDatabase() throws {
        #expect(try count("SELECT count(*) FROM transactions") == 0)
        #expect(try count("SELECT count(*) FROM profile_versions") == 0)
        #expect(try count("SELECT count(*) FROM action_log") == 0)
        #expect(try count("SELECT count(*) FROM categories") == 13)
    }

    @Test("a fresh file database persists new Pace entries when reopened")
    func freshDatabasePersistsNativeEntry() throws {
        let url = temporaryDirectory().appendingPathComponent("pace.sqlite")
        let initial = try PaceDatabase(url: url)
        #expect(try initial.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM transactions") } == 0)
        let created = try LedgerExecutor(database: initial).create(draft(.expense, 1_850))
        let reopened = try PaceDatabase(url: url)
        let transaction = try reopened.writer.read { try Queries.transaction($0, id: created.transaction.id) }
        #expect(transaction?.amountMinor == 1_850)
    }

    @Test("create → update → undo → delete → undo round trip, fully audited")
    func roundTrip() throws {
        let created = try executor.create(draft(merchant: "Mamak", category: "Food & Drink"))
        let updated = try executor.update(created.transaction.id, TransactionChanges(amountMinor: 3500))
        #expect(updated.transaction.amountMinor == 3500)
        #expect(try executor.undo(updated.actionID).transaction.amountMinor == 1450)
        let deleted = try executor.softDelete(created.transaction.id)
        #expect(deleted.transaction.deletedAt != nil)
        #expect(try executor.database.writer.read { try Queries.history($0, HistoryQuery()) }.isEmpty)
        #expect(try executor.undo(deleted.actionID).transaction.deletedAt == nil)
        #expect(try count("SELECT count(*) FROM action_log") == 5)
    }

    @Test("an older edit's undo keeps later edits to other fields and conflicts on the same field")
    func undoNeverOverwritesLaterWork() throws {
        let id = try executor.create(draft()).transaction.id
        let amount = try executor.update(id, TransactionChanges(amountMinor: 2000))
        _ = try executor.update(id, TransactionChanges(note: .some("Team lunch")))
        let restored = try executor.undo(amount.actionID)
        #expect(restored.transaction.amountMinor == 1450 && restored.transaction.note == "Team lunch")

        let first = try executor.update(id, TransactionChanges(amountMinor: 2000))
        _ = try executor.update(id, TransactionChanges(amountMinor: 2500))
        #expect(throws: LedgerError.undoConflict) { try executor.undo(first.actionID) }
        #expect(try executor.database.writer.read { try Queries.transaction($0, id: id)!.amountMinor } == 2500)
    }

    @Test("undo conflicts when later active edits return a field to the older value")
    func undoAfterValueReturns() throws {
        let id = try executor.create(draft()).transaction.id
        let first = try executor.update(id, TransactionChanges(amountMinor: 2_000))
        _ = try executor.update(id, TransactionChanges(amountMinor: 2_500))
        _ = try executor.update(id, TransactionChanges(amountMinor: 2_000))
        #expect(throws: LedgerError.undoConflict) { try executor.undo(first.actionID) }
        #expect(try executor.database.writer.read { try Queries.transaction($0, id: id)!.amountMinor } == 2_000)
    }

    @Test("older edit becomes undoable after the later edit is undone")
    func undoAfterLaterUndo() throws {
        let id = try executor.create(draft()).transaction.id
        let first = try executor.update(id, TransactionChanges(amountMinor: 2_000))
        let later = try executor.update(id, TransactionChanges(amountMinor: 2_500))
        _ = try executor.undo(later.actionID)
        #expect(try executor.undo(first.actionID).transaction.amountMinor == 1_450)
    }

    @Test("undo is idempotent; undoing an undo or a profile change is refused cleanly")
    func undoEdges() throws {
        let id = try executor.create(draft()).transaction.id
        let edit = try executor.update(id, TransactionChanges(amountMinor: 2000))
        let first = try executor.undo(edit.actionID)
        #expect(try executor.undo(edit.actionID).actionID == first.actionID)
        #expect(throws: LedgerError.undoNotSupported("undo")) { try executor.undo(first.actionID) }
        try executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 350_000, salaryDay: 25,
                                             effectiveCycleStart: LocalDate(iso: "2026-01-25")!))
        let profileAction = try executor.database.writer.read {
            try String.fetchOne($0, sql: "SELECT id FROM action_log WHERE kind = 'set_profile'")!
        }
        #expect(throws: LedgerError.undoNotSupported("set_profile")) { try executor.undo(profileAction) }
    }

    @Test("a repeated request id replays the first write; a different payload conflicts")
    func idempotency() throws {
        let first = try executor.create(draft(), requestID: "req-1")
        let replay = try executor.create(draft(), requestID: "req-1")
        #expect(replay.duplicate && replay.transaction.id == first.transaction.id && replay.actionID == first.actionID)
        #expect(throws: LedgerError.requestConflict) { try executor.create(draft(.expense, 9999), requestID: "req-1") }
        #expect(try count("SELECT count(*) FROM transactions") == 1)
    }

    @Test("invalid writes are rejected and leave nothing behind")
    func validation() throws {
        #expect(throws: LedgerError.self) { try executor.create(draft(.expense, 0)) }
        #expect(throws: LedgerError.self) { try executor.create(draft(.expense, maximumAmountMinor + 1)) }
        var noCategory = draft()
        noCategory.categoryID = nil
        #expect(throws: LedgerError.self) { try executor.create(noCategory) }
        var contributionWithCategory = draft(.contribution)
        contributionWithCategory.categoryID = Seeds.categoryID("Other")
        #expect(throws: LedgerError.self) { try executor.create(contributionWithCategory) }
        let id = try executor.create(draft()).transaction.id
        #expect(throws: LedgerError.self) { try executor.update(id, TransactionChanges(type: .contribution)) }
        _ = try executor.softDelete(id)
        #expect(throws: LedgerError.deleted) { try executor.update(id, TransactionChanges(amountMinor: 5)) }
        #expect(try count("SELECT count(*) FROM transactions") == 1)
        #expect(try count("SELECT count(*) FROM action_log") == 2)
    }

    @Test("the schema enforces the category rule and positive amounts even without the executor")
    func schemaChecks() throws {
        try executor.database.writer.write { db in
            let insert = """
                INSERT INTO transactions (id, type, amount_minor, occurred_at, tz_identifier, local_date, category_id, source, created_at)
                VALUES (?, ?, ?, '2026-09-17T04:00:00+00:00', 'Asia/Kuala_Lumpur', '2026-09-17', ?, 'keypad', 'x')
                """
            #expect(throws: DatabaseError.self) { try db.execute(sql: insert, arguments: ["a", "contribution", 1, "other"]) }
            #expect(throws: DatabaseError.self) { try db.execute(sql: insert, arguments: ["b", "expense", 1, nil]) }
            #expect(throws: DatabaseError.self) { try db.execute(sql: insert, arguments: ["c", "expense", 0, "other"]) }
        }
    }

    @Test("profile versions and changed salary rules are appended")
    func profileVersions() throws {
        let start = LocalDate(iso: "2026-01-01")!
        try executor.setProfile(ProfileInput(paydayAnchor: nil, salaryMinor: 320_000, salaryDay: 1, effectiveCycleStart: start))
        let profile = try executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 350_000, salaryDay: 25,
                                                           effectiveCycleStart: LocalDate(iso: "2026-01-25")!,
                                                           savingsMode: .percentage, savingsBasisPoints: 2_000))
        #expect(profile.paydayAnchor == 25 && profile.salaryRule?.amountMinor == 350_000)
        #expect(try count("SELECT count(*) FROM profile_versions") == 2)
        #expect(try count("SELECT count(*) FROM recurring_rules") == 2)
        #expect(throws: LedgerError.self) {
            try executor.setProfile(ProfileInput(paydayAnchor: 32, salaryMinor: 1, salaryDay: 1, effectiveCycleStart: start))
        }
        #expect(throws: LedgerError.self) {
            try executor.setProfile(ProfileInput(paydayAnchor: 1, salaryMinor: 100, salaryDay: 1, effectiveCycleStart: start,
                                                 savingsTargetMinor: 80, fixedCommitmentsMinor: 30))
        }
    }

    @Test("salary changes preserve the previous pay cycle's plan")
    func salaryChangeKeepsHistoricalPlan() throws {
        let january = LocalDate(iso: "2026-01-25")!
        try executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 350_000, salaryDay: 25,
                                             effectiveCycleStart: january))
        let august = LocalDate(iso: "2026-08-26")!
        let before = try executor.database.writer.read { try Queries.home($0, today: august) }
        #expect(before.plan?.planningIncomeMinor == 350_000)
        try executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 400_000, salaryDay: 25,
                                             effectiveCycleStart: LocalDate(iso: "2026-09-25")!))
        let past = try executor.database.writer.read { try Queries.home($0, today: august) }
        let current = try executor.database.writer.read {
            try Queries.home($0, today: LocalDate(iso: "2026-09-26")!)
        }
        #expect(past.plan?.planningIncomeMinor == 350_000)
        #expect(current.plan?.planningIncomeMinor == 400_000)
        let originalAmount = try executor.database.writer.read {
            try Int.fetchOne($0, sql: "SELECT amount_minor FROM recurring_rules WHERE id = 'salary'")
        }
        #expect(originalAmount == 350_000)
        let audit = try executor.database.writer.read {
            try Row.fetchOne($0, sql: "SELECT before_json, after_json, metadata_json FROM action_log WHERE kind = 'set_profile' ORDER BY rowid DESC LIMIT 1")!
        }
        let priorProfile = try JSON.decode(Snapshot.self, audit["before_json"] as String)
        let savedProfile = try JSON.decode(Snapshot.self, audit["after_json"] as String)
        let detail = try JSONSerialization.jsonObject(with: Data((audit["metadata_json"] as String).utf8)) as! [String: Any]
        #expect(priorProfile["salary_rule_id"] == .text("salary"))
        #expect(savedProfile["salary_rule_id"] != .text("salary"))
        #expect(detail["effectiveCycleStart"] as? String == "2026-09-25")
    }

    @Test("future salary changes and later current-cycle edits retain every salary interval")
    func salaryScheduleOrder() throws {
        func date(_ value: String) -> LocalDate { LocalDate(iso: value)! }
        try executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 350_000, salaryDay: 25,
                                             effectiveCycleStart: date("2026-01-25")))
        try executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 450_000, salaryDay: 31,
                                             effectiveCycleStart: date("2026-11-25")))
        try executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 400_000, salaryDay: 25,
                                             effectiveCycleStart: date("2026-09-25")))
        #expect(try count("SELECT count(*) FROM recurring_rules") == 3)
        let expected = [("2026-08-26", 350_000), ("2026-09-26", 400_000),
                        ("2026-10-26", 400_000), ("2026-11-26", 450_000)]
        for (day, amount) in expected {
            let home = try executor.database.writer.read { try Queries.home($0, today: date(day)) }
            #expect(home.plan?.planningIncomeMinor == amount, "\(day)")
        }
        let upcoming = try executor.database.writer.read {
            try Queries.nextSalaryChange($0, after: date("2026-09-25"))
        }
        #expect(upcoming?.amountMinor == 450_000 && upcoming?.dayOfMonth == 31
                && upcoming?.start == date("2026-11-25"))
        let octoberOccurrence = try executor.database.writer.read {
            try Queries.openSalaryOccurrence($0, today: date("2026-10-26"))
        }
        let novemberOccurrence = try executor.database.writer.read {
            try Queries.openSalaryOccurrence($0, today: date("2026-11-26"))
        }
        #expect(octoberOccurrence?.date == date("2026-10-25"))
        #expect(novemberOccurrence?.date == date("2026-11-30"))

        // Saving another profile field must not create a duplicate salary rule.
        try executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 400_000, salaryDay: 25,
                                             effectiveCycleStart: date("2026-09-25"), savingsTargetMinor: 20_000))
        #expect(try count("SELECT count(*) FROM recurring_rules") == 3)
        let november = try executor.database.writer.read { try Queries.home($0, today: date("2026-11-26")) }
        #expect(november.plan?.planningIncomeMinor == 450_000)
    }

    @Test("a salary already logged in the selected cycle is not expected twice after its rule changes")
    func sameCycleSalaryChangeAfterPayment() throws {
        func date(_ value: String) -> LocalDate { LocalDate(iso: value)! }
        try executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 350_000, salaryDay: 25,
                                             effectiveCycleStart: date("2026-01-25")))
        var salary = draft(.income, 350_000, date: "2026-09-25", category: "Income")
        salary.recurringRuleID = "salary"
        salary.occurrenceDate = date("2026-09-25")
        let paid = try executor.create(salary)
        try executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 400_000, salaryDay: 25,
                                             effectiveCycleStart: date("2026-09-25")))
        let home = try executor.database.writer.read { try Queries.home($0, today: date("2026-09-26")) }
        #expect(home.plan?.planningIncomeMinor == 350_000)
        #expect(home.plan?.expectedIncomeMinor == 0)
        #expect(try executor.database.writer.read {
            try Queries.openSalaryOccurrence($0, today: date("2026-09-26"))
        } == nil)
        var duplicate = draft(.income, 400_000, date: "2026-09-25", category: "Income")
        duplicate.recurringRuleID = home.profile?.salaryRule?.id
        duplicate.occurrenceDate = date("2026-09-25")
        #expect(throws: LedgerError.self) { try executor.create(duplicate) }
        let extraIncome = try executor.create(draft(.income, 1_000, date: "2026-09-26", category: "Income"))
        #expect(throws: LedgerError.self) {
            try executor.update(extraIncome.transaction.id,
                                TransactionChanges(recurringLink: .some((ruleID: duplicate.recurringRuleID!,
                                                                         occurrence: date("2026-09-25")))))
        }
        let deletion = try executor.softDelete(paid.transaction.id)
        let afterDelete = try executor.database.writer.read { try Queries.home($0, today: date("2026-09-26")) }
        #expect(afterDelete.plan?.planningIncomeMinor == 401_000)
        #expect(afterDelete.plan?.expectedIncomeMinor == 400_000)
        _ = try executor.create(duplicate)
        #expect(throws: LedgerError.undoConflict) { try executor.undo(deletion.actionID) }
    }

    @Test("Home: expected salary counts until a linked Earned entry materialises it — never twice")
    func homeSalary() throws {
        try executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 350_000, salaryDay: 25,
                                             effectiveCycleStart: LocalDate(iso: "2026-01-25")!, savingsTargetMinor: 50_000))
        let today = LocalDate(iso: "2026-09-26")!
        var home = try executor.database.writer.read { try Queries.home($0, today: today) }
        #expect(home.plan?.planningIncomeMinor == 350_000)
        let open = try executor.database.writer.read { try Queries.openSalaryOccurrence($0, today: today) }!
        #expect(open.date.iso == "2026-09-25")
        var salary = draft(.income, 350_000, date: "2026-09-25", category: "Income")
        salary.recurringRuleID = open.ruleID
        salary.occurrenceDate = open.date
        _ = try executor.create(salary)
        _ = try executor.create(draft(.income, 80_000, date: "2026-09-26", category: "Income"))
        _ = try executor.create(draft(.expense, 12_000, date: "2026-09-26"))
        home = try executor.database.writer.read { try Queries.home($0, today: today) }
        let plan = try #require(home.plan)
        #expect(plan.planningIncomeMinor == 430_000 && plan.expectedIncomeMinor == 0)
        #expect(plan.leftMinor == 430_000 - 50_000 - 12_000)
        #expect(plan.daysLeftIncludingToday == 29)
        #expect(throws: LedgerError.self) { try executor.create(salary) }  // one salary link per cycle
    }

    @Test("without a payday anchor Home shows calendar-month actuals and no plan")
    func homeWithoutAnchor() throws {
        _ = try executor.create(draft(.expense, 1_000, date: "2026-09-02"))
        _ = try executor.create(draft(.expense, 2_000, date: "2026-08-31"))
        let home = try executor.database.writer.read { try Queries.home($0, today: LocalDate(iso: "2026-09-26")!) }
        #expect(home.plan == nil && home.actual.spending == 1_000 && home.cycle.start.iso == "2026-09-01")
    }

    @Test("history search covers merchant, note, category and amount")
    func historySearch() throws {
        _ = try executor.create(draft(.expense, 1_850, merchant: "Chicken Rice Shop", category: "Food & Drink"))
        _ = try executor.create(draft(.expense, 900, category: "Transport", note: "parking at KLCC"))
        func search(_ text: String) throws -> Int {
            try executor.database.writer.read { try Queries.history($0, HistoryQuery(text: text)).count }
        }
        #expect(try search("chicken") == 1)
        #expect(try search("klcc") == 1)
        #expect(try search("transport") == 1)
        #expect(try search("18.50") == 1)
        #expect(try search("RM 9") == 1)
        #expect(try search("100%") == 0)
    }

    @Test("stored instants are UTC; the capture zone is kept per row")
    func timestamps() throws {
        let created = try executor.create(draft())
        let raw = try executor.database.writer.read {
            try Row.fetchOne($0, sql: "SELECT occurred_at, tz_identifier FROM transactions WHERE id = ?", arguments: [created.transaction.id])!
        }
        #expect(raw["occurred_at"] as String == "2026-09-17T04:00:00+00:00")
        #expect(raw["tz_identifier"] as String == kualaLumpur)
    }
}
