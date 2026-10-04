// Not wired into capture. Retained as the comparison baseline for the screenshot benchmarks.
import Foundation
import FoundationModels
import PaceCore

@Generable(description: "One money selection from Vision OCR")
nonisolated private struct CaptureMoneySelection {
    @Guide(description: "Copy the exact visible OCR money text that is the transaction amount. Return NONE when unsure. Do not calculate or explain")
    var selectedMoneyText: String
}

@Generable(description: "One merchant selection from Vision OCR")
nonisolated private struct CaptureMerchantSelection {
    @Guide(description: "Copy only the merchant or counterparty name exactly as it appears in OCR. Return NONE when unsure. Do not explain")
    var selectedMerchantText: String
}

struct ScreenshotSemanticSelections {
    let moneyText: String?
    let merchantText: String?
    let moneyError: String?
    let merchantError: String?
    let moneyMS: Int
    let merchantMS: Int
}

/// Separate one-field calls keep financial arithmetic and screen classification out of FM.
enum ScreenshotSemanticSelectionService {
    static func select(_ lines: [ScreenshotTextLine]) async -> ScreenshotSemanticSelections {
        let evidence = input(lines)
        let moneyStart = Date()
        let money: String?
        let moneyError: String?
        do {
            let session = LanguageModelSession(model: .default, instructions: """
                The user just made a transaction and intentionally captured its confirmation screen.
                From these Apple Vision OCR observations, select the exact money text showing the
                transaction amount. Ignore balances, fees, cashback, limits, and other monetary values.
                Return NONE if the amount cannot be determined. Copy OCR text verbatim.
                """)
            let response = try await session.respond(to: evidence, generating: CaptureMoneySelection.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120))
            money = response.content.selectedMoneyText.trimmingCharacters(in: .whitespacesAndNewlines)
            moneyError = nil
        } catch {
            money = nil
            moneyError = Self.diagnosticError(error)
        }
        let moneyMS = Int(Date().timeIntervalSince(moneyStart) * 1_000)
        let merchantStart = Date()
        let merchant: String?
        let merchantError: String?
        do {
            let session = LanguageModelSession(model: .default, instructions: """
                The user just made a transaction and intentionally captured its confirmation screen.
                From these Apple Vision OCR observations, select only the merchant or counterparty
                that received the transaction. Copy its name verbatim from OCR.
                Return NONE if uncertain. Do not infer a business name from outside knowledge.
                """)
            let response = try await session.respond(to: evidence, generating: CaptureMerchantSelection.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120))
            merchant = response.content.selectedMerchantText.trimmingCharacters(in: .whitespacesAndNewlines)
            merchantError = nil
        } catch {
            merchant = nil
            merchantError = Self.diagnosticError(error)
        }
        return .init(moneyText: money, merchantText: merchant, moneyError: moneyError,
                     merchantError: merchantError, moneyMS: moneyMS,
                     merchantMS: Int(Date().timeIntervalSince(merchantStart) * 1_000))
    }

    private static func input(_ lines: [ScreenshotTextLine]) -> String {
        let ordered = lines.enumerated().sorted {
            if abs($0.element.y - $1.element.y) > 0.015 { return $0.element.y < $1.element.y }
            if $0.element.x != $1.element.x { return $0.element.x < $1.element.x }
            return $0.offset < $1.offset
        }
        let observations = ordered.map { _, line in
            "(x\(Int((line.x * 100).rounded())),y\(Int((line.y * 100).rounded()))) \(line.text)"
        }
        return "Vision OCR observations (top-origin coordinates, percent):\n" + observations.joined(separator: "\n")
    }

    private static func diagnosticError(_ error: Error) -> String {
        String((String(reflecting: type(of: error)) + ": " + String(describing: error)).prefix(500))
    }
}
