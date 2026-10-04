import Foundation
import GRDB
import PaceCore
import Testing
@testable import PaceStore

@Suite("Backup and restore")
struct BackupTests {
    @Test("backup and restore retain salary amounts for earlier pay cycles")
    func salaryHistory() throws {
        let directory = temporaryDirectory()
        let database = try PaceDatabase(url: directory.appendingPathComponent("pace.sqlite"))
        let executor = LedgerExecutor(database: database)
        try executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 350_000, salaryDay: 25,
                                             effectiveCycleStart: LocalDate(iso: "2026-01-25")!))
        try executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 400_000, salaryDay: 25,
                                             effectiveCycleStart: LocalDate(iso: "2026-09-25")!))
        let backup = directory.appendingPathComponent("salary-history.sqlite")
        try Backup.snapshot(database, to: backup)
        try executor.setProfile(ProfileInput(paydayAnchor: 25, salaryMinor: 450_000, salaryDay: 25,
                                             effectiveCycleStart: LocalDate(iso: "2026-10-25")!))
        try Backup.restore(database, from: backup, safetyDirectory: directory.appendingPathComponent("safety"))
        for (date, expected) in [("2026-08-26", 350_000), ("2026-09-26", 400_000)] {
            let home = try database.writer.read { try Queries.home($0, today: LocalDate(iso: date)!) }
            #expect(home.plan?.planningIncomeMinor == expected, "\(date)")
        }
        let october = try database.writer.read {
            try Queries.home($0, today: LocalDate(iso: "2026-10-26")!)
        }
        #expect(october.plan?.planningIncomeMinor == 400_000)
    }

    @Test("snapshot → restore round trip, with a pre-restore safety snapshot")
    func roundTrip() throws {
        let directory = temporaryDirectory()
        let database = try PaceDatabase(url: directory.appendingPathComponent("live/pace.sqlite"))
        let executor = LedgerExecutor(database: database)
        _ = try executor.create(draft(.expense, 1_800, merchant: "Grab", category: "Transport"))
        let backup = directory.appendingPathComponent("backup.sqlite")
        try Backup.snapshot(database, to: backup)
        _ = try executor.create(draft(.expense, 999))
        let safety = try Backup.restore(database, from: backup, safetyDirectory: directory.appendingPathComponent("safety"))
        let restored = try database.writer.read { try Queries.history($0, HistoryQuery()) }
        #expect(restored.map(\.amountMinor) == [1_800])
        let safetyDatabase = try PaceDatabase(url: safety)
        #expect(try safetyDatabase.writer.read { try Queries.history($0, HistoryQuery()) }.count == 2)
    }

    @Test("restore refuses files that are not Pace databases or are corrupt")
    func validation() throws {
        let directory = temporaryDirectory()
        let database = try PaceDatabase(url: directory.appendingPathComponent("pace.sqlite"))
        let foreign = directory.appendingPathComponent("foreign.sqlite")
        let queue = try DatabaseQueue(path: foreign.path)
        try queue.write { try $0.execute(sql: "CREATE TABLE notes (id INTEGER)") }
        try queue.close()
        #expect(throws: BackupError.self) { try Backup.restore(database, from: foreign, safetyDirectory: directory) }
        let garbage = directory.appendingPathComponent("garbage.sqlite")
        try Data("definitely not sqlite".utf8).write(to: garbage)
        #expect(throws: BackupError.self) { try Backup.validate(garbage) }
    }

    @Test("a backup from a newer schema is refused")
    func newerSchema() throws {
        let directory = temporaryDirectory()
        let newer = directory.appendingPathComponent("newer.sqlite")
        let database = try PaceDatabase(url: newer)
        try database.writer.write { try $0.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99')") }
        #expect(throws: BackupError.newerSchema) { try Backup.validate(newer) }
    }

    @Test("a structurally valid SQLite file with broken references is refused")
    func foreignKeyIntegrity() throws {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("broken.sqlite")
        let database = try PaceDatabase(url: url)
        let id = try LedgerExecutor(database: database).create(draft()).transaction.id
        try database.writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "UPDATE transactions SET category_id = 'missing-category' WHERE id = ?", arguments: [id])
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        #expect(throws: BackupError.self) { try Backup.validate(url) }
    }

    @Test("automatic snapshots are rate-limited and keep a bounded history")
    func autoSnapshots() throws {
        let directory = temporaryDirectory()
        let database = try PaceDatabase(url: directory.appendingPathComponent("pace.sqlite"))
        let snapshots = directory.appendingPathComponent("snapshots")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(try Backup.autoSnapshot(database, directory: snapshots, retention: 3, now: start) != nil)
        #expect(try Backup.autoSnapshot(database, directory: snapshots, retention: 3, now: start) == nil)
        for day in 1...5 {
            let url = try Backup.autoSnapshot(database, directory: snapshots, retention: 3, interval: 0,
                                              now: start.addingTimeInterval(Double(day) * 86_400))
            #expect(url != nil)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: snapshots.path).sorted()
        #expect(files.count == 3, "\(files)")
    }

    @Test("JSON export carries every table in Pace's financial locale")
    func jsonExport() throws {
        let database = try PaceDatabase()
        _ = try LedgerExecutor(database: database).create(draft(.expense, 1_800))
        let url = temporaryDirectory().appendingPathComponent("export.json")
        try Backup.exportJSON(database, to: url)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(object["format"] as? String == "pace-export" && object["currency"] as? String == "MYR")
        #expect((object["transactions"] as? [Any])?.count == 1)
    }
}
