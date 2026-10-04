import Foundation
import GRDB

/// Explicit local data operations. The feedback archive stays in capture_outcomes;
/// all other live rows are reset to the same seeds as a newly migrated database.
public enum PaceDataMaintenance {
    public static func resetPaceData(_ database: PaceDatabase) throws {
        try database.writer.write { db in
            let records = try CaptureProcessor.feedbackRecords(db)
            for record in records {
                guard let raw = try String.fetchOne(db, sql: "SELECT raw_fields_json FROM capture_outcomes WHERE id = ?",
                    arguments: [record.captureUUID]) else { continue }
                var fields = try JSON.decode([String: String].self, raw)
                fields["captureFeedbackArchivedRecordJSON"] = try JSON.encode(record)
                try db.execute(sql: "UPDATE capture_outcomes SET raw_fields_json = ? WHERE id = ?",
                    arguments: [try JSON.encode(fields), record.captureUUID])
            }
            let ids = records.map(\.captureUUID)
            if ids.isEmpty {
                try db.execute(sql: "DELETE FROM capture_outcomes")
            } else {
                let slots = Array(repeating: "?", count: ids.count).joined(separator: ",")
                try db.execute(sql: "DELETE FROM capture_outcomes WHERE id NOT IN (\(slots))",
                    arguments: StatementArguments(ids))
            }
            for table in ["capture_feedback", "capture_path_state", "request_idempotency",
                          "action_log", "transactions", "profile_versions", "recurring_rules",
                          "merchant_context_rules", "merchant_aliases", "merchants", "categories", "preferences"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            try db.execute(sql: "DELETE FROM sqlite_sequence WHERE name IN ('merchant_aliases', 'merchant_context_rules', 'profile_versions')")
            try Seeds.insert(db)
        }
    }

    public static func clearCaptureFeedback(_ database: PaceDatabase) throws {
        try database.writer.write { db in try clearCaptureFeedback(db) }
    }

    static func clearCaptureFeedback(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, raw_fields_json FROM capture_outcomes
            WHERE capture_path IN (\(CaptureFeedbackSource.capturePathsSQL)) AND raw_fields_json IS NOT NULL
            """)
        for row in rows {
            var fields = try JSON.decode([String: String].self, row["raw_fields_json"] as String)
            guard fields["captureFeedbackEvidenceJSON"] != nil else { continue }
            let id: String = row["id"]
            if fields["captureFeedbackArchivedRecordJSON"] != nil {
                try db.execute(sql: "DELETE FROM capture_outcomes WHERE id = ?", arguments: [id])
            } else {
                for key in ["captureFeedbackEvidenceJSON", "captureFeedbackReportedIssue",
                            "captureFeedbackUserNote"] {
                    fields.removeValue(forKey: key)
                }
                try db.execute(sql: "UPDATE capture_outcomes SET raw_fields_json = ? WHERE id = ?",
                    arguments: [fields.isEmpty ? nil : try JSON.encode(fields), id])
            }
        }
    }
}
