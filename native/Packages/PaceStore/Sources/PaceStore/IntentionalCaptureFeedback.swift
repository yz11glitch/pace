import Foundation
import GRDB
import PaceCore

/// Local diagnostic evidence only. It has no input to resolution, M1, or Merchant Memory.
public struct IntentionalCaptureEvidence: Codable, Sendable {
    public struct Category: Codable, Sendable {
        public let memoryCategoryID: String?
        public let fmAttempted: Bool
        public let fmCategory: String?
        public let fmError: String?
        public let source: String
        public let finalCategoryID: String

        public init(_ result: ScreenshotCategoryResolution) {
            memoryCategoryID = result.memoryCategoryID
            fmAttempted = result.fmAttempted
            fmCategory = result.fmCategory
            fmError = result.fmError
            source = result.source
            finalCategoryID = result.categoryID
        }
    }

    public let vision: ScreenshotFixture
    public let visionTruncated: Bool
    public let resolver: ScreenshotFieldResolution
    public let category: Category

    public init(lines: [ScreenshotTextLine], capturedAt: Instant, timeZone: String,
                resolver: ScreenshotFieldResolution, category: ScreenshotCategoryResolution) throws {
        let retained = try ScreenshotObservationDiagnostics.retainedFixture(
            capturedAt: capturedAt, timeZone: timeZone, lines: lines)
        vision = retained.fixture
        visionTruncated = retained.truncated
        self.resolver = resolver
        self.category = Category(category)
    }
}

/// The capture system a feedback record came from. Every source shares one dataset and export.
public enum CaptureFeedbackSource: String, Codable, Sendable, CaseIterable {
    case intentionalBackTap
    case applePay

    /// The ledger capture path that retains feedback for this source.
    public var capturePath: String {
        switch self {
        case .intentionalBackTap: "screenshot_intentional_fm"
        case .applePay: "apple_pay"
        }
    }

    public init?(capturePath: String) {
        guard let source = Self.allCases.first(where: { $0.capturePath == capturePath }) else { return nil }
        self = source
    }

    static var capturePathsSQL: String { allCases.map { "'\($0.capturePath)'" }.joined(separator: ", ") }
}

/// What the Apple Pay Shortcut action actually supplied, and what Pace decided from it.
/// This path has no screenshot, OCR, resolver or FM step, so none is represented. The
/// card/pass, Name, Shortcut Input and additional values are probe-only and are recorded
/// by parameter name, never by value.
public struct ApplePayCaptureEvidence: Codable, Sendable, Equatable {
    public struct Received: Codable, Sendable, Equatable {
        /// The Amount parameter exactly as supplied, including any currency marker.
        public let amountText: String?
        /// The Merchant parameter exactly as supplied.
        public let merchantText: String?
        public let referenceSupplied: Bool
        public let suppliedParameters: [String]
    }

    public struct Category: Codable, Sendable, Equatable {
        /// `merchantMemory`, `defaultOther` (saved with no known category), or `none` (draft).
        public let source: String
        public let memoryCategoryID: String?
        public let memoryCategoryTrusted: Bool
        public let categoryPending: Bool
        public let finalCategoryID: String?
    }

    public let received: Received
    public let parsedAmountMinor: Int?
    public let amountTrust: String
    public let merchantTrust: String
    public let merchantResolution: String
    public let category: Category
    public let capturedAt: String
    public let timeZone: String
    public let executionContext: String
    public let trustStage: String

    init(_ input: CaptureRequest, merchantResolution: String, memoryCategoryID: String?,
         memoryCategoryTrusted: Bool, categoryPending: Bool, finalCategoryID: String?,
         outcome: CaptureOutcome, executionContext: String, trustStage: String) {
        received = Received(amountText: input.rawFields["amount"].map { String($0.prefix(200)) },
            merchantText: input.rawFields["merchant"].map { String($0.prefix(200)) },
            referenceSupplied: input.reference != nil,
            suppliedParameters: input.rawFields.keys.sorted())
        parsedAmountMinor = input.amountMinor
        amountTrust = input.amountTrust.rawValue
        merchantTrust = input.merchantTrust.rawValue
        self.merchantResolution = merchantResolution
        category = Category(
            source: memoryCategoryID != nil ? "merchantMemory" : outcome == .saved ? "defaultOther" : "none",
            memoryCategoryID: memoryCategoryID, memoryCategoryTrusted: memoryCategoryTrusted,
            categoryPending: categoryPending, finalCategoryID: finalCategoryID)
        capturedAt = input.capturedAt.isoUTC
        timeZone = input.timeZone
        self.executionContext = executionContext
        self.trustStage = trustStage
    }
}

public struct IntentionalCaptureValues: Codable, Sendable, Equatable {
    public let amountMinor: Int?
    public let merchant: String?
    public let categoryID: String?
    public let ledgerTimestamp: String?
    public let reference: String?
    public let note: String?
}

public struct IntentionalCaptureFeedbackRecord: Codable, Sendable {
    public struct M1: Codable, Sendable {
        public let outcome: String
        public let reviewReason: String
        public let duplicateMatchID: String?
        public let anomalyReasons: [String]
        public let unresolvedTrustFields: [String]
    }

    public let captureUUID: String
    public let captureSource: CaptureFeedbackSource
    public let captureTimestamp: String
    public let capturePath: String
    public let transactionID: String
    /// Back Tap screenshot evidence; absent for Apple Pay.
    public let vision: ScreenshotFixture?
    public let visionTruncated: Bool?
    public let resolver: ScreenshotFieldResolution?
    public let category: IntentionalCaptureEvidence.Category?
    /// Apple Pay input and decision evidence; absent for Back Tap.
    public let applePay: ApplePayCaptureEvidence?
    public let m1: M1
    public let predicted: IntentionalCaptureValues
    public let corrected: IntentionalCaptureValues
    public let changedFields: [String]
    public let explicitlyReportedIssue: Bool
    public let userFeedbackNote: String?
    public let outcome: String
}

// Version 1 exports had no explicit user report. Decode them as unreported.
// Versions 1–2 were Back Tap only and had no source tag; the source follows the capture path.
extension IntentionalCaptureFeedbackRecord {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        captureUUID = try values.decode(String.self, forKey: .captureUUID)
        captureTimestamp = try values.decode(String.self, forKey: .captureTimestamp)
        capturePath = try values.decode(String.self, forKey: .capturePath)
        captureSource = try values.decodeIfPresent(CaptureFeedbackSource.self, forKey: .captureSource)
            ?? CaptureFeedbackSource(capturePath: capturePath) ?? .intentionalBackTap
        transactionID = try values.decode(String.self, forKey: .transactionID)
        vision = try values.decodeIfPresent(ScreenshotFixture.self, forKey: .vision)
        visionTruncated = try values.decodeIfPresent(Bool.self, forKey: .visionTruncated)
        resolver = try values.decodeIfPresent(ScreenshotFieldResolution.self, forKey: .resolver)
        category = try values.decodeIfPresent(IntentionalCaptureEvidence.Category.self, forKey: .category)
        applePay = try values.decodeIfPresent(ApplePayCaptureEvidence.self, forKey: .applePay)
        m1 = try values.decode(M1.self, forKey: .m1)
        predicted = try values.decode(IntentionalCaptureValues.self, forKey: .predicted)
        corrected = try values.decode(IntentionalCaptureValues.self, forKey: .corrected)
        changedFields = try values.decode([String].self, forKey: .changedFields)
        explicitlyReportedIssue = try values.decodeIfPresent(Bool.self, forKey: .explicitlyReportedIssue) ?? false
        userFeedbackNote = try values.decodeIfPresent(String.self, forKey: .userFeedbackNote)
        outcome = try values.decode(String.self, forKey: .outcome)
    }
}

public struct IntentionalCaptureFeedbackExport: Codable, Sendable {
    public struct Summary: Codable, Sendable {
        public let totalCaptures: Int
        public let acceptedUnchanged: Int
        public let corrected: Int
        public let abandonedDeleted: Int
        public let pendingReview: Int
        public let correctionCountsByField: [String: Int]
        public let reportedIssues: Int
        public let reportedIssuesByChangedField: [String: Int]
        /// Keyed by `CaptureFeedbackSource` raw value; every supported source is present.
        public let byCaptureSource: [String: SourceSummary]
    }

    public struct SourceSummary: Codable, Sendable, Equatable {
        public let total: Int
        public let acceptedUnchanged: Int
        public let corrected: Int
        public let reportedIssues: Int
        public let correctionCountsByField: [String: Int]
    }

    public let schemaVersion: Int
    public let generatedAt: String
    public let appVersion: String?
    public let buildVersion: String?
    public let resolverVersion: String
    public let summary: Summary
    public let records: [IntentionalCaptureFeedbackRecord]

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

extension IntentionalCaptureFeedbackExport.Summary {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        totalCaptures = try values.decode(Int.self, forKey: .totalCaptures)
        acceptedUnchanged = try values.decode(Int.self, forKey: .acceptedUnchanged)
        corrected = try values.decode(Int.self, forKey: .corrected)
        abandonedDeleted = try values.decode(Int.self, forKey: .abandonedDeleted)
        pendingReview = try values.decode(Int.self, forKey: .pendingReview)
        correctionCountsByField = try values.decode([String: Int].self, forKey: .correctionCountsByField)
        reportedIssues = try values.decodeIfPresent(Int.self, forKey: .reportedIssues) ?? 0
        reportedIssuesByChangedField = try values.decodeIfPresent([String: Int].self,
            forKey: .reportedIssuesByChangedField) ?? [:]
        byCaptureSource = try values.decodeIfPresent([String: IntentionalCaptureFeedbackExport.SourceSummary].self,
            forKey: .byCaptureSource) ?? [:]
    }
}

public extension CaptureProcessor {
    /// The last 200 real captures per feedback source with retained evidence. Capture outcomes
    /// and financial audit actions remain in the ledger; only old diagnostic payloads are bounded.
    func intentionalCaptureFeedback(appVersion: String? = nil, buildVersion: String? = nil,
                                    generatedAt: Date = Date()) throws -> IntentionalCaptureFeedbackExport {
        let records = try database.writer.read { try Self.feedbackRecords($0) }
        var corrections: [String: Int] = [:]
        var reportedByField: [String: Int] = [:]
        for record in records {
            for field in record.changedFields { corrections[field, default: 0] += 1 }
            if record.explicitlyReportedIssue {
                for field in record.changedFields { reportedByField[field, default: 0] += 1 }
            }
        }
        var bySource: [String: IntentionalCaptureFeedbackExport.SourceSummary] = [:]
        for source in CaptureFeedbackSource.allCases {
            let scoped = records.filter { $0.captureSource == source }
            var fields: [String: Int] = [:]
            for record in scoped { for field in record.changedFields { fields[field, default: 0] += 1 } }
            bySource[source.rawValue] = .init(total: scoped.count,
                acceptedUnchanged: scoped.filter { $0.outcome == "acceptedUnchanged" }.count,
                corrected: scoped.filter { !$0.changedFields.isEmpty }.count,
                reportedIssues: scoped.filter(\.explicitlyReportedIssue).count,
                correctionCountsByField: fields)
        }
        return IntentionalCaptureFeedbackExport(schemaVersion: 3,
            generatedAt: Timestamp.string(generatedAt), appVersion: appVersion, buildVersion: buildVersion,
            resolverVersion: "intentional-step1-feedback-v1",
            summary: .init(totalCaptures: records.count,
                acceptedUnchanged: records.filter { $0.outcome == "acceptedUnchanged" }.count,
                corrected: records.filter { !$0.changedFields.isEmpty }.count,
                abandonedDeleted: records.filter { $0.outcome == "abandonedDeleted" }.count,
                pendingReview: records.filter { $0.outcome == "pendingReview" }.count,
                correctionCountsByField: corrections,
                reportedIssues: records.filter(\.explicitlyReportedIssue).count,
                reportedIssuesByChangedField: reportedByField, byCaptureSource: bySource), records: records)
    }

    internal static func feedbackRecords(_ db: Database) throws -> [IntentionalCaptureFeedbackRecord] {
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM capture_outcomes
                WHERE capture_path IN (\(CaptureFeedbackSource.capturePathsSQL)) AND outcome IN ('saved', 'draft')
                  AND raw_fields_json LIKE '%"captureFeedbackEvidenceJSON"%'
                ORDER BY rowid DESC
                """)
            var perSource: [CaptureFeedbackSource: Int] = [:]
            return try rows.compactMap { row in
                guard let source = CaptureFeedbackSource(capturePath: row["capture_path"]),
                      perSource[source, default: 0] < 200 else { return nil }
                perSource[source, default: 0] += 1
                guard let transactionID: String = row["transaction_id"],
                      let raw: String = row["raw_fields_json"] else { return nil }
                let rawFields = try JSON.decode([String: String].self, raw)
                guard let evidenceJSON = rawFields["captureFeedbackEvidenceJSON"] else { return nil }
                if let archived = rawFields["captureFeedbackArchivedRecordJSON"] {
                    return try JSON.decode(IntentionalCaptureFeedbackRecord.self, archived)
                }
                guard let transaction = try db.snapshot("transactions", id: transactionID) else { return nil }
                let screenshot = source == .intentionalBackTap
                    ? try JSON.decode(IntentionalCaptureEvidence.self, evidenceJSON) : nil
                let applePay = source == .applePay
                    ? try JSON.decode(ApplePayCaptureEvidence.self, evidenceJSON) : nil
                let fields = try JSON.decode([String: String].self, row["fields_json"] as String)
                // Apple Pay saves an unknown merchant as Other; that is Pace's produced category.
                let originalCategory = applePay.map { $0.category.finalCategoryID }
                    ?? fields["categoryID"].flatMap { $0 == "missing" ? nil : $0 }
                let original = IntentionalCaptureValues(
                    amountMinor: Int(fields["amountMinor"] ?? ""),
                    merchant: fields["merchant"].flatMap { $0 == "missing" ? nil : $0 },
                    categoryID: originalCategory,
                    ledgerTimestamp: fields["occurredAt"],
                    reference: fields["reference"].flatMap { $0 == "missing" ? nil : $0 },
                    note: nil)
                func string(_ key: String) -> String? {
                    if case let .text(value)? = transaction[key] { return value }
                    return nil
                }
                func integer(_ key: String) -> Int? {
                    if case let .int(value)? = transaction[key] { return Int(exactly: value) }
                    return nil
                }
                let current = IntentionalCaptureValues(amountMinor: integer("amount_minor"),
                    merchant: string("merchant_text"), categoryID: string("category_id"),
                    ledgerTimestamp: string("occurred_at"), reference: string("external_reference"),
                    note: string("note"))
                let changed = [
                    ("amount", original.amountMinor != current.amountMinor),
                    ("merchant", original.merchant != current.merchant),
                    ("category", original.categoryID != current.categoryID),
                    ("timestamp", original.ledgerTimestamp != current.ledgerTimestamp),
                    ("reference", original.reference != current.reference),
                    ("note", original.note != current.note)
                ].compactMap { $0.1 ? $0.0 : nil }
                let deleted = transaction["deleted_at"] != .null
                let reported = rawFields["captureFeedbackReportedIssue"] == "true"
                let status = deleted ? "abandonedDeleted" : string("status") == "draft" ? "pendingReview" :
                    reported ? (changed.isEmpty ? "reportedCaptureIssue" : "reportedAndCorrected") :
                    changed.isEmpty ? "acceptedUnchanged" : "editedNotReported"
                let unresolved = (fields["unresolved"] ?? "").split(separator: ",").map(String.init)
                let anomaly: [String] = try (row["anomaly_json"] as String?)
                    .map { try JSON.decode([String].self, $0) } ?? []
                return IntentionalCaptureFeedbackRecord(captureUUID: row["id"], captureSource: source,
                    captureTimestamp: fields["capturedAt"] ?? row["recorded_at"],
                    capturePath: row["capture_path"], transactionID: transactionID,
                    vision: screenshot?.vision, visionTruncated: screenshot?.visionTruncated,
                    resolver: screenshot?.resolver, category: screenshot?.category, applePay: applePay,
                    m1: .init(outcome: row["outcome"], reviewReason: row["reason"],
                        duplicateMatchID: row["duplicate_match_id"], anomalyReasons: anomaly,
                        unresolvedTrustFields: unresolved),
                    predicted: original, corrected: current, changedFields: changed,
                    explicitlyReportedIssue: reported,
                    userFeedbackNote: reported ? rawFields["captureFeedbackUserNote"] : nil,
                    outcome: status)
            }
    }
}
