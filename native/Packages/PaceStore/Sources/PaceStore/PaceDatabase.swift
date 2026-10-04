import Foundation
import GRDB
import PaceCore

/// The Pace database: one SQLite file in the App Group container, WAL mode,
/// foreign keys on. File protection stays at the iOS default
/// (`completeUntilFirstUserAuthentication`) so intents can write while the
/// phone is locked after first unlock.
public final class PaceDatabase: Sendable {
    public let writer: any DatabaseWriter
    public let url: URL?

    public static let appGroupIdentifierKey = "PaceAppGroupIdentifier"

    /// Opens (creating and migrating) the database at `url`.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try DatabasePool(path: url.path, configuration: Self.configuration())
        self.url = url
        try Schema.migrator.migrate(writer)
    }

    /// An in-memory database for tests and previews.
    public init() throws {
        writer = try DatabaseQueue(configuration: Self.configuration())
        url = nil
        try Schema.migrator.migrate(writer)
    }

    static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.label = "Pace"
        return configuration
    }

    /// The default location: the App Group container shared with App Intents
    /// when available, else Application Support.
    public static func defaultURL(appGroup: String?) -> URL {
        let base = appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            ?? URL.applicationSupportDirectory
        return base.appendingPathComponent("Pace", isDirectory: true).appendingPathComponent("pace.sqlite")
    }

    public var schemaVersion: String? {
        try? writer.read { db in try Schema.migrator.appliedMigrations(db).last }
    }
}

/// A row snapshot for the audit log: exact column values, JSON-encoded with sorted keys.
enum SnapshotValue: Codable, Equatable, Sendable {
    case null, int(Int64), text(String)

    init(_ value: DatabaseValue) {
        switch value.storage {
        case .null: self = .null
        case let .int64(number): self = .int(number)
        case let .string(text): self = .text(text)
        case let .double(number): self = .text(String(number))
        case let .blob(data): self = .text(data.base64EncodedString())
        }
    }

    var databaseValue: DatabaseValue {
        switch self {
        case .null: .null
        case let .int(number): number.databaseValue
        case let .text(text): text.databaseValue
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let number = try? container.decode(Int64.self) { self = .int(number) }
        else { self = .text(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .int(number): try container.encode(number)
        case let .text(text): try container.encode(text)
        }
    }
}

typealias Snapshot = [String: SnapshotValue]

enum JSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
}

extension Database {
    func snapshot(_ table: String, id: String) throws -> Snapshot? {
        guard let row = try Row.fetchOne(self, sql: "SELECT * FROM \(table) WHERE id = ?", arguments: [id]) else { return nil }
        var snapshot: Snapshot = [:]
        for column in row.columnNames { snapshot[column] = SnapshotValue(row[column] as DatabaseValue) }
        return snapshot
    }
}

/// Timestamps are stored as UTC ISO 8601 instants, fixing Noted's mixed offsets.
enum Timestamp {
    static func string(_ date: Date) -> String { Instant(date).isoUTC }
}
