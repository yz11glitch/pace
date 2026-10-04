#if DEBUG
import GRDB
import PaceCore
import PaceStore

/// Non-AI baseline: what Pace already knows about a first-seen merchant on a
/// fresh install — the seed merchant pack. Resolution mirrors
/// `MerchantMemory.resolveAlias` (exact alias key, never similarity), and a hit
/// counts only when capture would trust it (`CaptureProcessor`: no context rules,
/// since the benchmark supplies no note). Runs on a private in-memory database:
/// the device ledger and its merchant memory are never opened.
nonisolated struct SeedMemoryBaseline: Sendable {
    private let database: PaceDatabase

    init() throws { database = try PaceDatabase() }

    func category(for merchant: String) -> String? {
        let key = merchantKey(merchant)
        guard !key.isEmpty else { return nil }
        return try? database.writer.read { db -> String? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT m.id, c.name FROM merchant_aliases a
                JOIN merchants m ON m.id = a.merchant_id JOIN categories c ON c.id = m.category_id
                WHERE a.alias_key = ? AND a.source IN ('user', 'seed')
                """, arguments: [key]) else { return nil }
            let rules = try Int.fetchOne(db, sql: "SELECT count(*) FROM merchant_context_rules WHERE merchant_id = ?",
                                         arguments: [row["id"] as String]) ?? 0
            return rules == 0 ? row["name"] : nil
        }
    }
}
#endif
