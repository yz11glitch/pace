import Foundation
import FoundationModels
import PaceCore
import PaceStore

@Generable(description: "One Pace spending category for a completed payment")
nonisolated private struct CaptureCategorySelection {
    @Guide(description: "Select exactly one Pace expense category",
           .anyOf(EntryRules.categoryChoices(for: .expense)))
    var category: String
}

enum ScreenshotCategoryService {
    private static let definitions = """
        Food & Drink: restaurants, cafés, food delivery, drinks
        Groceries: supermarkets, markets, fresh produce
        Transport: fuel, tolls, parking, rides, transit
        Shopping: retail goods, electronics, clothing, marketplaces
        Bills & Utilities: utilities, mobile and internet bills
        Health: clinics, hospitals, pharmacies
        Entertainment: movies, games, events, leisure
        Education: schools, tuition, courses
        Services: personal and household services
        Travel: flights, hotels, travel bookings
        Gifts & Donations: gifts, charity, donations
        Other: none of these categories fits or the business is unclear
        """

    static func suggest(merchant: String, ocrText: [String]) async -> ScreenshotCategorySuggestion {
        let context = ocrText.prefix(24).map { String($0.prefix(200)) }.joined(separator: "\n")
        do {
            let session = LanguageModelSession(model: .default, instructions: """
                Help the account owner categorize one completed payment for routine budgeting.
                Choose your best single Pace expense category. Use the grounded merchant and
                visible OCR context, including any source category, but do not invent facts.
                The source category can be generic or mistaken. Return only the category.

                Pace categories:\n\(definitions)
                """)
            let response = try await session.respond(to: "Merchant: \(merchant)\nOCR context:\n\(context)",
                generating: CaptureCategorySelection.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 80))
            return .init(name: response.content.category)
        } catch {
            return .init(name: nil, error: String((String(reflecting: type(of: error)) + ": " +
                String(describing: error)).prefix(500)))
        }
    }
}
