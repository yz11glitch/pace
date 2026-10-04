import Foundation
import GRDB
import PaceCore

public enum BackupError: Error, Equatable, LocalizedError {
    case integrity(String)
    case notPace(String)
    case newerSchema

    public var errorDescription: String? {
        switch self {
        case let .integrity(detail): "The backup failed an integrity check (\(detail))."
        case let .notPace(detail): "That file isn't a Pace backup (\(detail))."
        case .newerSchema: "That backup is from a newer version of Pace."
        }
    }
}

/// Backups to Files (SQLite snapshot + JSON export) and restore with
/// integrity validation and a pre-restore snapshot (ported from `noted/backup.py`).
public enum Backup {
    static let requiredTables: Set<String> = ["transactions", "categories", "merchants", "action_log", "profile_versions"]

    /// A consistent online snapshot (SQLite backup API), validated after writing.
    public static func snapshot(_ database: PaceDatabase, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let destination = try DatabaseQueue(path: url.path)
        try database.writer.backup(to: destination)
        // A backup is one self-contained file: no WAL side files to lose in Files.
        try destination.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
        try destination.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        try validate(url)
    }

    /// Checks integrity, that it is a Pace database, and that its schema is not newer than this app.
    public static func validate(_ url: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let queue: DatabaseQueue
        do { queue = try DatabaseQueue(path: url.path, configuration: configuration) } catch {
            throw BackupError.notPace("unreadable")
        }
        defer { try? queue.close() }
        try queue.read { db in
            let check = try String.fetchOne(db, sql: "PRAGMA quick_check")
            guard check == "ok" else { throw BackupError.integrity(check ?? "no result") }
            if try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") != nil {
                throw BackupError.integrity("broken foreign-key reference")
            }
            let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            let missing = requiredTables.subtracting(tables)
            guard missing.isEmpty else { throw BackupError.notPace("missing \(missing.sorted().joined(separator: ", "))") }
            let applied = try Schema.migrator.appliedIdentifiers(db)
            let known = Set(Schema.migrator.migrations)
            guard applied.isSubset(of: known) else { throw BackupError.newerSchema }
            guard applied.contains("v1") else { throw BackupError.notPace("missing v1 migration") }
        }
    }

    /// Replaces the live contents with a validated backup, after snapshotting
    /// the live database to `safetyDirectory`. Returns the safety snapshot.
    @discardableResult
    public static func restore(_ database: PaceDatabase, from backup: URL, safetyDirectory: URL, now: Date = Date()) throws -> URL {
        try validate(backup)
        try FileManager.default.createDirectory(at: safetyDirectory, withIntermediateDirectories: true)
        let safety = safetyDirectory.appendingPathComponent("pre-restore-\(stamp(now)).sqlite")
        try snapshot(database, to: safety)
        let source = try DatabaseQueue(path: backup.path)
        try source.backup(to: database.writer)
        try source.close()
        try Schema.migrator.migrate(database.writer)
        return safety
    }

    /// Keeps a rolling set of automatic local snapshots; takes one when the newest is older than `interval`.
    @discardableResult
    public static func autoSnapshot(_ database: PaceDatabase, directory: URL, retention: Int = 14,
                                    interval: TimeInterval = 20 * 3600, now: Date = Date()) throws -> URL? {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("auto-") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        if let newest = existing.first,
           let modified = try newest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           now.timeIntervalSince(modified) < interval {
            return nil
        }
        let url = directory.appendingPathComponent("auto-\(stamp(now)).sqlite")
        try snapshot(database, to: url)
        try manager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        for expired in ([url] + existing).dropFirst(retention) { try? manager.removeItem(at: expired) }
        return url
    }

    /// Only snapshots created and named by Pace. User-exported Files backups are outside this directory.
    public static func removeManagedSnapshots(in directory: URL) throws {
        for url in try managedSnapshots(in: directory) { try FileManager.default.removeItem(at: url) }
    }

    /// Clear feedback copies in app-managed backups while leaving their ledger data intact.
    public static func clearFeedbackFromManagedSnapshots(in directory: URL) throws {
        for url in try managedSnapshots(in: directory) {
            let queue = try DatabaseQueue(path: url.path)
            do {
                try queue.write { db in
                    if try db.tableExists("capture_outcomes") { try PaceDataMaintenance.clearCaptureFeedback(db) }
                }
                try queue.close()
            } catch {
                try? queue.close()
                throw error
            }
        }
    }

    private static func managedSnapshots(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { url in
                url.pathExtension == "sqlite" &&
                    (url.lastPathComponent.hasPrefix("auto-") || url.lastPathComponent.hasPrefix("pre-restore-"))
            }
    }

    /// A plain-text export (all rows, category names resolved). Not encrypted.
    public static func exportJSON(_ database: PaceDatabase, to url: URL, now: Date = Date()) throws {
        let payload: [String: Any] = try database.writer.read { db in
            func rows(_ sql: String) throws -> [[String: Any]] {
                try Row.fetchAll(db, sql: sql).map { row in
                    var object: [String: Any] = [:]
                    for column in row.columnNames {
                        let value: DatabaseValue = row[column]
                        switch value.storage {
                        case .null: object[column] = NSNull()
                        case let .int64(number): object[column] = number
                        case let .double(number): object[column] = number
                        case let .string(text): object[column] = text
                        case let .blob(data): object[column] = data.base64EncodedString()
                        }
                    }
                    return object
                }
            }
            return [
                "format": "pace-export", "version": 1, "exported_at": Timestamp.string(now),
                "financial_locale": FinancialLocale.malaysia.identifier, "currency": "MYR",
                "transactions": try rows(StoredTransaction.select + " ORDER BY t.local_date, t.created_at"),
                "categories": try rows("SELECT * FROM categories ORDER BY sort"),
                "merchants": try rows("SELECT * FROM merchants ORDER BY canonical_key"),
                "merchant_aliases": try rows("SELECT * FROM merchant_aliases ORDER BY alias_key"),
                "recurring_rules": try rows("SELECT * FROM recurring_rules"),
                "profile_versions": try rows("SELECT * FROM profile_versions ORDER BY id"),
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func stamp(_ date: Date) -> String {
        Instant(date).isoUTC.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "+0000", with: "Z")
    }
}
