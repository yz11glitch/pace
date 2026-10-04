import Foundation
import GRDB
import PaceCore

/// Future mapping changes shared by the executor and consequence control.
/// This only describes an explicit save; it never resolves or teaches a capture.
public struct MerchantTeaching: Equatable, Sendable {
    public let merchant: String
    public let priorMerchant: String?
    public let categoryID: String?
    public let learnAlias: Bool
    public let learnCategory: Bool

    public func consequence(categoryName: String?) -> String {
        func short(_ text: String) -> String { text.count > 44 ? String(text.prefix(43)) + "…" : text }
        if learnCategory {
            return "File future \(short(merchant)) payments under \(categoryName ?? "this category")"
        }
        return "Show future “\(short(priorMerchant ?? merchant))” payments as \(short(merchant))"
    }

    public static func edit(current: StoredTransaction, changes: TransactionChanges) -> Self? {
        let newName = changes.merchantText ?? current.merchantText
        let newCategory = changes.categoryID ?? current.categoryID
        let oldKey = merchantKey(current.merchantText ?? ""), newKey = merchantKey(newName ?? "")
        let rename = changes.merchantText != nil && !oldKey.isEmpty && !newKey.isEmpty && oldKey != newKey
        let category = changes.categoryID != nil && newCategory != current.categoryID
            && (changes.type ?? current.type) == current.type && newCategory != nil
        guard (rename || category), !newKey.isEmpty, let newName else { return nil }
        return Self(merchant: newName, priorMerchant: current.merchantText, categoryID: newCategory,
                    learnAlias: rename, learnCategory: category)
    }

    public static func review(_ database: PaceDatabase, id: String, merchant: String, categoryID: String) throws -> Self? {
        try database.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT merchant_text FROM transactions WHERE id = ? AND status = 'draft' AND deleted_at IS NULL", arguments: [id])
            else { throw LedgerError.notFound }
            return try review(db, priorMerchant: row["merchant_text"], merchant: merchant, categoryID: categoryID)
        }
    }

    static func review(_ db: Database, priorMerchant: String?, merchant: String, categoryID: String) throws -> Self? {
        let key = merchantKey(merchant)
        guard !key.isEmpty else { return nil }
        let rename = priorMerchant.map { !merchantKey($0).isEmpty && merchantKey($0) != key } ?? false
        // An already remembered category has no new consequence to offer.
        let match = try MerchantMemory.resolveAlias(db, name: merchant)
        let category = match?.categoryID != categoryID
        guard rename || category else { return nil }
        return Self(merchant: merchant, priorMerchant: priorMerchant, categoryID: categoryID,
                    learnAlias: rename, learnCategory: category)
    }
}

extension Queries {
    public static func merchantSuggestions(_ db: Database, text: String) throws -> [String] {
        let names = try String.fetchAll(db, sql: "SELECT DISTINCT display_name FROM merchants ORDER BY display_name")
        let key = merchantKey(text)
        return Array(names.filter { key.isEmpty || merchantKey($0).contains(key) }.prefix(8))
    }
}
