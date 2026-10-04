import Foundation
import GRDB
import PaceCore
@testable import PaceStore

enum Fixtures {
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("fixtures/golden").path) { return url }
        }
        fatalError("repository root not found")
    }()

    static func jsonl(_ path: String) -> [[String: Any]] {
        let text = try! String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n").map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pace-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let kualaLumpur = "Asia/Kuala_Lumpur"

func draft(_ type: TransactionType = .expense, _ amount: Int = 1450, date: String = "2026-09-17",
           merchant: String? = nil, category: String? = "Other", note: String? = nil) -> TransactionDraft {
    TransactionDraft(type: type, amountMinor: amount, occurredAt: Instant(iso: "\(date)T12:00:00+08:00")!,
                     tzIdentifier: kualaLumpur, localDate: LocalDate(iso: date)!, merchantText: merchant,
                     categoryID: type == .contribution ? nil : category.map(Seeds.categoryID), note: note,
                     source: .keypad)
}
