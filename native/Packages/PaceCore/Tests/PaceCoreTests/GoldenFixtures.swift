import Foundation

/// Loads `fixtures/golden/*.jsonl` exported from the Python/JS oracles.
enum GoldenFixtures {
    static let directory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent("fixtures/golden")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        fatalError("fixtures/golden not found above \(#filePath)")
    }()

    /// Parsed with `JSONDecoder`: `JSONSerialization` mis-rounds some
    /// 17-significant-digit doubles (e.g. 0.013484172592897546), which would
    /// hide exact rate parity.
    static func records(_ name: String) -> [[String: Any]] {
        let text = try! String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        return text.split(separator: "\n").map {
            try! JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)).any as! [String: Any]
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: Any) -> T {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try! JSONDecoder().decode(T.self, from: data)
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
    func bool(_ key: String) -> Bool { (self[key] as? Bool) ?? false }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func isNull(_ key: String) -> Bool { self[key] == nil || self[key] is NSNull }
}

/// A JSON value decoded exactly, bridged to `Any` for the fixture readers.
enum JSONValue: Decodable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    var any: Any {
        switch self {
        case .null: NSNull()
        case let .bool(value): value
        case let .int(value): NSNumber(value: value)
        case let .double(value): NSNumber(value: value)
        case let .string(value): value
        case let .array(values): values.map(\.any)
        case let .object(values): values.mapValues(\.any)
        }
    }
}
