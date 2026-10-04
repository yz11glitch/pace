import Foundation
import GRDB
import PaceCore
import Testing
@testable import PaceStore

/// Replays `fixtures/golden/merchant_learning.jsonl` through the native
/// executor and compares every step with the Python oracle.
@Suite("Merchant learning parity")
struct MerchantLearningParityTests {
    static func categoryName(_ db: Database, _ id: String?) throws -> String? {
        guard let id else { return nil }
        return try String.fetchOne(db, sql: "SELECT name FROM categories WHERE id = ?", arguments: [id])
    }

    static func transactionView(_ db: Database, _ id: String) throws -> [String: String] {
        let t = try Queries.transaction(db, id: id)!
        let key = try t.merchantID.flatMap { try String.fetchOne(db, sql: "SELECT canonical_key FROM merchants WHERE id = ?", arguments: [$0]) }
        return ["type": t.type.rawValue, "amount_minor": String(t.amountMinor), "merchant": t.merchantText ?? "∅",
                "merchant_key": key ?? "∅", "category": t.categoryName ?? "∅", "description": t.note ?? "∅",
                "deleted": String(t.deletedAt != nil)]
    }

    static func pythonView(_ value: [String: Any]) -> [String: String] {
        func text(_ key: String) -> String { (value[key] as? String) ?? "∅" }
        return ["type": text("type"), "amount_minor": String((value["amount_minor"] as! NSNumber).intValue),
                "merchant": text("merchant"), "merchant_key": text("merchant_key"), "category": text("category"),
                "description": text("description"), "deleted": String(value["deleted"] as! Bool)]
    }

    @Test("every scenario, step by step", arguments: Fixtures.jsonl("fixtures/golden/merchant_learning.jsonl").map { $0["id"] as! String })
    func scenario(_ id: String) throws {
        let record = Fixtures.jsonl("fixtures/golden/merchant_learning.jsonl").first { $0["id"] as! String == id }!
        let executor = LedgerExecutor(database: try PaceDatabase())
        let steps = record["steps"] as! [[String: Any]]
        let outcomes = record["outcomes"] as! [[String: Any]]
        var refs: [String: String] = [:]
        var actions: [String: String] = [:]
        for (index, (step, want)) in zip(steps, outcomes).enumerated() {
            var result: Any = NSNull()
            switch step["op"] as! String {
            case "create":
                let created = try executor.create(draft(merchant: step["merchant"] as? String, category: step["category"] as? String))
                refs[step["ref"] as! String] = created.transaction.id
                if let alias = step["as"] as? String { actions[alias] = created.actionID }
            case "edit":
                let patch = step["patch"] as! [String: Any]
                var changes = TransactionChanges()
                for (key, value) in patch {
                    switch key {
                    case "merchant": changes.merchantText = .some(value as? String)
                    case "category": changes.categoryID = .some((value as? String).map(Seeds.categoryID))
                    case "amount_minor": changes.amountMinor = (value as! NSNumber).intValue
                    case "description": changes.note = .some(value as? String)
                    case "type": changes.type = TransactionType(rawValue: value as! String)
                    default: Issue.record("unknown patch key \(key)")
                    }
                }
                actions[step["as"] as! String] = try executor.update(refs[step["ref"] as! String]!, changes).actionID
            case "delete":
                actions[step["as"] as! String] = try executor.softDelete(refs[step["ref"] as! String]!).actionID
            case "undo":
                do {
                    _ = try executor.undo(actions[step["action"] as! String]!)
                    result = "undone"
                } catch LedgerError.undoConflict {
                    result = "conflict"
                } catch LedgerError.undoNotSupported {
                    result = "unsupported"
                }
            case "resolve":
                result = try executor.database.writer.read { db -> Any in
                    guard let match = try MerchantMemory.resolveAlias(db, name: step["name"] as? String) else { return NSNull() }
                    return ["display_name": match.displayName, "category": try Self.categoryName(db, match.categoryID) ?? "∅"]
                }
            default:
                Issue.record("unknown op")
            }
            let label = "\(id) step \(index) \(step["op"]!)"
            if let wantResult = want["result"] as? String {
                #expect(result as? String == wantResult, "\(label)")
            } else if let wantMatch = want["result"] as? [String: Any] {
                let got = result as? [String: String]
                #expect(got?["display_name"] == wantMatch["display_name"] as? String, "\(label)")
                #expect(got?["category"] == ((wantMatch["category"] as? String) ?? "∅"), "\(label)")
            } else if step["op"] as! String == "resolve" {
                #expect(result is NSNull, "\(label): expected no match")
            }
            let wantTransactions = want["transactions"] as! [String: [String: Any]]
            try executor.database.writer.read { db in
                for (ref, value) in wantTransactions {
                    let view = try Self.transactionView(db, refs[ref]!)
                    #expect(view == Self.pythonView(value), "\(label) \(ref)")
                }
            }
        }
        let final = record["final"] as! [String: Any]
        try executor.database.writer.read { db in
            let merchants = try Row.fetchAll(db, sql: """
                SELECT m.canonical_key, m.display_name, c.name AS category, m.subcategory, m.is_user_taught
                FROM merchants m LEFT JOIN categories c ON c.id = m.category_id ORDER BY m.canonical_key
                """).map { row -> [String: String] in
                    ["key": row["canonical_key"], "name": row["display_name"], "category": row["category"] ?? "∅",
                     "subcategory": row["subcategory"] ?? "∅", "taught": String(row["is_user_taught"] as Int64 == 1)]
                }
            let wantMerchants = (final["merchants"] as! [[String: Any]]).map { value -> [String: String] in
                let category = (value["category"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "∅"
                return ["key": value["canonical_key"] as! String, "name": value["display_name"] as! String,
                        "category": category, "subcategory": (value["subcategory"] as? String) ?? "∅",
                        "taught": String(value["is_user_taught"] as! Bool)]
            }
            #expect(merchants == wantMerchants, "\(id) final merchants")
            let aliases = try Row.fetchAll(db, sql: """
                SELECT a.alias_key, m.canonical_key, a.source FROM merchant_aliases a JOIN merchants m ON m.id = a.merchant_id
                ORDER BY a.alias_key
                """).map { "\($0["alias_key"] as String)→\($0["canonical_key"] as String):\($0["source"] as String)" }
            let wantAliases = (final["aliases"] as! [[String: Any]]).map {
                "\($0["alias_key"] as! String)→\($0["merchant"] as! String):\($0["source"] as! String)"
            }
            #expect(aliases == wantAliases, "\(id) final aliases")
        }
    }
}
