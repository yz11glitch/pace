import Foundation
import GRDB
import PaceCore

/// Port of `noted.merchants`: exact-alias resolution (never similarity),
/// context rules, and learning only from explicit user corrections. Undo
/// reverts a correction's learning unless a later correction reinforced it
/// (decision O5). Parity: `fixtures/golden/merchant_learning.jsonl`.
public struct MerchantMatch: Equatable, Sendable {
    public let merchantID: String
    public let displayName: String
    public let categoryID: String?
    public let subcategory: String?
    public let method: String
    public let aliasID: Int64
}

/// What one correction taught and what it replaced.
struct LearningRecord: Codable, Equatable, Sendable {
    struct MerchantFields: Codable, Equatable, Sendable {
        var categoryID: String?
        var subcategory: String?
        var isUserTaught: Int64
    }

    struct AliasChange: Codable, Equatable, Sendable {
        struct Mapping: Codable, Equatable, Sendable {
            var merchantID: String
            var source: String
        }

        var aliasKey: String
        var before: Mapping?
    }

    var merchantID: String
    var merchantCreated: Bool
    var merchantBefore: MerchantFields?
    var merchantAfter: MerchantFields
    var aliases: [AliasChange]
}

enum MerchantMemory {
    static func resolveAlias(_ db: Database, name: String?, context: String = "") throws -> MerchantMatch? {
        let key = merchantKey(name ?? "")
        guard !key.isEmpty, let row = try Row.fetchOne(db, sql: """
            SELECT m.*, a.id AS alias_id FROM merchant_aliases a JOIN merchants m ON m.id = a.merchant_id
            WHERE a.alias_key = ? AND a.source IN ('user', 'seed')
            """, arguments: [key]) else { return nil }
        return try withContext(db, row, normalizedContext: merchantKey(context))
    }

    private static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        (" " + text + " ").contains(" " + phrase + " ") && !phrase.isEmpty
    }

    private static func withContext(_ db: Database, _ row: Row, normalizedContext: String) throws -> MerchantMatch {
        let merchantID: String = row["id"]
        var categoryID: String? = row["category_id"]
        var subcategory: String? = row["subcategory"]
        var method = "exact_alias"
        let rules = try Row.fetchAll(db, sql: """
            SELECT keyword, category_id, subcategory FROM merchant_context_rules
            WHERE merchant_id = ? ORDER BY priority DESC, keyword
            """, arguments: [merchantID])
        for rule in rules where containsPhrase(normalizedContext, rule["keyword"]) {
            categoryID = rule["category_id"]
            subcategory = rule["subcategory"]
            method = "context:\(rule["keyword"] as String)"
            break
        }
        return MerchantMatch(merchantID: merchantID, displayName: row["display_name"], categoryID: categoryID,
                             subcategory: subcategory, method: method, aliasID: row["alias_id"])
    }

    private static func fields(_ db: Database, _ merchantID: String) throws -> LearningRecord.MerchantFields? {
        try Row.fetchOne(db, sql: "SELECT category_id, subcategory, is_user_taught FROM merchants WHERE id = ?",
                         arguments: [merchantID]).map {
            .init(categoryID: $0["category_id"], subcategory: $0["subcategory"], isUserTaught: $0["is_user_taught"])
        }
    }

    /// Persist an explicit correction inside the caller's transaction.
    static func learnCorrection(_ db: Database, sourceName: String?, correctedName: String, categoryID: String?,
                                learnAlias: Bool, learnCategory: Bool) throws -> LearningRecord {
        let correctedKey = merchantKey(correctedName)
        guard !correctedKey.isEmpty else { throw LedgerError.invalid("corrected merchant must have a normalized name") }
        var merchantID = try String.fetchOne(db, sql: "SELECT id FROM merchants WHERE canonical_key = ?",
                                             arguments: [correctedKey])
        if merchantID == nil {
            merchantID = try String.fetchOne(db, sql: """
                SELECT m.id FROM merchants m JOIN merchant_aliases a ON a.merchant_id = m.id
                WHERE a.alias_key = ? AND a.source IN ('user', 'seed')
                """, arguments: [correctedKey])
        }
        let before: LearningRecord.MerchantFields?
        let id: String
        if let merchantID {
            id = merchantID
            before = try fields(db, id)
            if learnCategory {
                try db.execute(sql: """
                    UPDATE merchants SET category_id = ?,
                    subcategory = CASE WHEN category_id IS ? THEN subcategory ELSE NULL END,
                    is_user_taught = 1 WHERE id = ?
                    """, arguments: [categoryID, categoryID, id])
            } else if learnAlias {
                try db.execute(sql: "UPDATE merchants SET is_user_taught = 1 WHERE id = ?", arguments: [id])
            }
        } else {
            id = UUID().uuidString.lowercased()
            before = nil
            try db.execute(sql: """
                INSERT INTO merchants (id, canonical_key, display_name, category_id, is_user_taught)
                VALUES (?, ?, ?, ?, 1)
                """, arguments: [id, correctedKey, correctedName.trimmingCharacters(in: .whitespacesAndNewlines),
                                 learnCategory ? categoryID : nil])
        }
        var keys: Set<String> = [correctedKey]
        if learnAlias, let sourceName {
            let sourceKey = merchantKey(sourceName)
            if !sourceKey.isEmpty { keys.insert(sourceKey) }
        }
        var aliases: [LearningRecord.AliasChange] = []
        for key in keys.sorted() {
            let previous = try Row.fetchOne(db, sql: "SELECT merchant_id, source FROM merchant_aliases WHERE alias_key = ?",
                                            arguments: [key])
            try db.execute(sql: """
                INSERT INTO merchant_aliases (merchant_id, alias_key, source) VALUES (?, ?, 'user')
                ON CONFLICT(alias_key) DO UPDATE SET merchant_id = excluded.merchant_id, source = 'user'
                """, arguments: [id, key])
            aliases.append(.init(aliasKey: key, before: previous.map { .init(merchantID: $0["merchant_id"], source: $0["source"]) }))
        }
        return LearningRecord(merchantID: id, merchantCreated: before == nil, merchantBefore: before,
                              merchantAfter: try fields(db, id)!, aliases: aliases)
    }

    /// Undo one correction's learning, leaving anything a later correction owns.
    static func revert(_ db: Database, _ record: LearningRecord, reinforcedAliases: Set<String>,
                       merchantReinforced: Bool) throws {
        for alias in record.aliases where !reinforcedAliases.contains(alias.aliasKey) {
            guard let current = try Row.fetchOne(db, sql: "SELECT merchant_id, source FROM merchant_aliases WHERE alias_key = ?",
                                                 arguments: [alias.aliasKey]),
                  current["merchant_id"] as String == record.merchantID, current["source"] as String == "user"
            else { continue }
            if let before = alias.before {
                try db.execute(sql: "UPDATE merchant_aliases SET merchant_id = ?, source = ? WHERE alias_key = ?",
                               arguments: [before.merchantID, before.source, alias.aliasKey])
            } else {
                try db.execute(sql: "DELETE FROM merchant_aliases WHERE alias_key = ?", arguments: [alias.aliasKey])
            }
        }
        guard !merchantReinforced, let current = try fields(db, record.merchantID), current == record.merchantAfter else { return }
        if record.merchantCreated {
            let inUse = try Int.fetchOne(db, sql: """
                SELECT (SELECT count(*) FROM transactions WHERE merchant_id = ?)
                     + (SELECT count(*) FROM merchant_aliases WHERE merchant_id = ?)
                     + (SELECT count(*) FROM recurring_rules WHERE merchant_id = ?)
                """, arguments: [record.merchantID, record.merchantID, record.merchantID]) ?? 0
            if inUse == 0 {
                try db.execute(sql: "DELETE FROM merchants WHERE id = ?", arguments: [record.merchantID])
            }
            return
        }
        if let before = record.merchantBefore {
            try db.execute(sql: "UPDATE merchants SET category_id = ?, subcategory = ?, is_user_taught = ? WHERE id = ?",
                           arguments: [before.categoryID, before.subcategory, before.isUserTaught, record.merchantID])
        }
    }
}
