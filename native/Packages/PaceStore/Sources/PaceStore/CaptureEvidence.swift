import Foundation
import GRDB
import PaceCore

public struct CapturePathState: Sendable {
    public let path: String
    public let stage: CaptureStage
    public let captures: Int
    public let reviewed: Int
    public let amountErrors: Int
    public let merchantErrors: Int
    public let lastChangeReason: String?
}

/// C13 evidence storage. Only explicit corrections and Undo count as errors;
/// untouched auto-saves do not certify themselves as accurate reviews.
enum CaptureEvidence {
    static func state(_ db: Database, path: String) throws -> CapturePathState? {
        try Row.fetchOne(db, sql: "SELECT * FROM capture_path_state WHERE path = ?", arguments: [path]).map { row in
            CapturePathState(path: row["path"], stage: CaptureStage(rawValue: row["stage"]) ?? .observe,
                captures: row["captures"], reviewed: row["reviewed"],
                amountErrors: row["amount_errors"], merchantErrors: row["merchant_errors"],
                lastChangeReason: row["last_change_reason"])
        }
    }

    static func ensure(_ db: Database, path: String, initial: CaptureStage, stamp: String) throws -> CapturePathState {
        try db.execute(sql: """
            INSERT OR IGNORE INTO capture_path_state (path, stage, updated_at) VALUES (?, ?, ?)
            """, arguments: [path, initial.rawValue, stamp])
        return try state(db, path: path)!
    }

    static func incrementCapture(_ db: Database, path: String, stamp: String) throws {
        try db.execute(sql: "UPDATE capture_path_state SET captures = captures + 1, updated_at = ? WHERE path = ?",
                       arguments: [stamp, path])
    }

    static func feedback(_ db: Database, transactionID: String, actionID: String,
                         amountError: Bool, merchantError: Bool, softError: Bool,
                         now: Date) throws {
        guard amountError || merchantError || softError,
              let row = try Row.fetchOne(db, sql: """
                  SELECT capture_path, status, created_at FROM transactions WHERE id = ?
                  """, arguments: [transactionID]),
              let path: String = row["capture_path"], row["status"] as String == "confirmed",
              let created = Instant(iso: row["created_at"] as String),
              (0...7 * 86_400).contains(now.timeIntervalSince(created.date)) else { return }
        let stamp = Timestamp.string(now)
        let initial: CaptureStage = path == "apple_pay" ? .assisted : .observe
        let before = try ensure(db, path: path, initial: initial, stamp: stamp)
        try db.execute(sql: """
            INSERT OR IGNORE INTO capture_feedback (action_id, path, amount_error, merchant_error, soft_error, recorded_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [actionID, path, amountError ? 1 : 0, merchantError ? 1 : 0,
                             softError ? 1 : 0, stamp])
        let recentSoft = try Int.fetchOne(db, sql: """
            SELECT COALESCE(sum(soft_error), 0) FROM (
                SELECT soft_error FROM capture_feedback WHERE path = ? ORDER BY rowid DESC LIMIT 20
            )
            """, arguments: [path]) ?? 0
        let evidence = CapturePathEvidence(reviewedCaptures: before.reviewed + 1,
            amountErrors: before.amountErrors + (amountError ? 1 : 0),
            merchantErrors: before.merchantErrors + (merchantError ? 1 : 0),
            recentSoftErrors: recentSoft, autoSavedAmountError: amountError)
        let next = CaptureLadder.next(before.stage, evidence: evidence, policy: .init())
        let reason = next != before.stage ? (amountError ? "amount correction or Undo" : "two recent soft errors") : before.lastChangeReason
        try db.execute(sql: """
            UPDATE capture_path_state SET stage = ?, reviewed = ?, amount_errors = ?, merchant_errors = ?,
                last_change_reason = ?, updated_at = ? WHERE path = ?
            """, arguments: [next.rawValue, evidence.reviewedCaptures, evidence.amountErrors,
                             evidence.merchantErrors, reason, stamp, path])
    }
}

public extension CaptureProcessor {
    func pathStates() throws -> [CapturePathState] {
        try database.writer.read { db in
            let paths = try String.fetchAll(db, sql: "SELECT path FROM capture_path_state ORDER BY path")
            return try paths.compactMap { try CaptureEvidence.state(db, path: $0) }
        }
    }
}
