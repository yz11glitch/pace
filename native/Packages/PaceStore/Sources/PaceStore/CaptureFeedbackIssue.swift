import Foundation
import GRDB

/// An explicit user signal, independent of edits to the captured transaction.
public struct CaptureFeedbackIssue: Equatable, Sendable {
    public let explicitlyReportedIssue: Bool
    public let userFeedbackNote: String?

    public init(explicitlyReportedIssue: Bool, userFeedbackNote: String? = nil) {
        self.explicitlyReportedIssue = explicitlyReportedIssue
        let note = userFeedbackNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userFeedbackNote = explicitlyReportedIssue && note?.isEmpty == false ? note : nil
    }
}

public enum CaptureFeedbackIssueStore {
    public static func state(_ database: PaceDatabase, transactionID: String) throws -> CaptureFeedbackIssue? {
        try database.writer.read { db in try state(db, transactionID: transactionID) }
    }

    public static func set(_ database: PaceDatabase, transactionID: String,
                           issue: CaptureFeedbackIssue) throws {
        try database.writer.write { db in try set(db, transactionID: transactionID, issue: issue) }
    }

    static func state(_ db: Database, transactionID: String) throws -> CaptureFeedbackIssue? {
        guard let (_, fields) = try associatedRecord(db, transactionID: transactionID) else { return nil }
        return CaptureFeedbackIssue(explicitlyReportedIssue: fields["captureFeedbackReportedIssue"] == "true",
            userFeedbackNote: fields["captureFeedbackUserNote"])
    }

    static func set(_ db: Database, transactionID: String, issue: CaptureFeedbackIssue) throws {
        guard (issue.userFeedbackNote?.count ?? 0) <= 1_000 else { throw LedgerError.invalid("Keep the note to 1,000 characters.") }
        guard let (id, originalFields) = try associatedRecord(db, transactionID: transactionID) else {
            throw LedgerError.invalid("This transaction has no capture feedback record.")
        }
        var fields = originalFields
        if issue.explicitlyReportedIssue {
            fields["captureFeedbackReportedIssue"] = "true"
            fields["captureFeedbackUserNote"] = issue.userFeedbackNote
        } else {
            fields.removeValue(forKey: "captureFeedbackReportedIssue")
            fields.removeValue(forKey: "captureFeedbackUserNote")
        }
        try db.execute(sql: "UPDATE capture_outcomes SET raw_fields_json = ? WHERE id = ?",
            arguments: [try JSON.encode(fields), id])
    }

    private static func associatedRecord(_ db: Database, transactionID: String) throws -> (String, [String: String])? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, raw_fields_json FROM capture_outcomes
            WHERE transaction_id = ? AND capture_path IN (\(CaptureFeedbackSource.capturePathsSQL))
              AND outcome IN ('saved', 'draft') AND raw_fields_json IS NOT NULL
            ORDER BY rowid ASC
            """, arguments: [transactionID])
        for row in rows {
            let fields = try JSON.decode([String: String].self, row["raw_fields_json"] as String)
            if fields["captureFeedbackEvidenceJSON"] != nil { return (row["id"], fields) }
        }
        return nil
    }
}
