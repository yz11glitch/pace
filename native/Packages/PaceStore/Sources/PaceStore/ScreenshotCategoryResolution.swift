import Foundation
import PaceCore

public struct ScreenshotCategorySuggestion: Sendable {
    public let name: String?
    public let error: String?

    public init(name: String?, error: String? = nil) {
        self.name = name; self.error = error
    }
}

public struct ScreenshotCategoryResolution: Sendable {
    public let categoryID: String
    public let source: String
    public let memoryCategoryID: String?
    public let fmAttempted: Bool
    public let fmCategory: String?
    public let validation: String
    public let fmError: String?
}

extension CaptureProcessor {
    /// Read trusted exact-alias memory before invoking the model. This only chooses a
    /// category for the capture; merchant learning remains exclusive to user edits.
    public func screenshotCategory(for input: CaptureRequest, ocrText: [String],
        suggest: @Sendable (String, [String]) async -> ScreenshotCategorySuggestion
    ) async throws -> ScreenshotCategoryResolution {
        let memory = try await database.writer.read { db in
            let ocr = try MerchantMemory.resolveAlias(db, name: input.rawFields["ocrMerchantCandidate"])
            return try ocr ?? MerchantMemory.resolveAlias(db, name: input.merchant)
        }
        if let category = memory?.categoryID {
            return .init(categoryID: category, source: "merchant_memory", memoryCategoryID: category,
                         fmAttempted: false, fmCategory: nil, validation: "memory", fmError: nil)
        }
        guard let merchant = input.merchant, input.merchantTrust != .unresolved else {
            return .init(categoryID: "other", source: "fallback_other", memoryCategoryID: nil,
                         fmAttempted: false, fmCategory: nil, validation: "no grounded merchant", fmError: nil)
        }
        let result = await suggest(merchant, ocrText)
        if let name = result.name, EntryRules.categoryChoices(for: .expense).contains(name) {
            return .init(categoryID: merchantKey(name).replacingOccurrences(of: " ", with: "-"),
                         source: "apple_fm", memoryCategoryID: nil, fmAttempted: true,
                         fmCategory: name, validation: "valid Pace category", fmError: result.error)
        }
        return .init(categoryID: "other", source: "fallback_other", memoryCategoryID: nil,
                     fmAttempted: true, fmCategory: result.name,
                     validation: result.name == nil ? "no category" : "invalid Pace category",
                     fmError: result.error)
    }
}
