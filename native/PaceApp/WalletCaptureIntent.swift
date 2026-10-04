import AppIntents
import Foundation
import PaceCore
import PaceStore
import UIKit

/// Shortcuts exposes each value as an optional, explicitly wired text parameter.
/// Apple does not guarantee any Wallet Transaction variable to this action.
struct LogWalletPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Apple Pay payment with Pace"
    static let description = IntentDescription("Record the values wired from a Wallet Transaction automation.")
    static let supportedModes: IntentModes = .background
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Amount") var amount: String?
    @Parameter(title: "Merchant") var merchant: String?
    @Parameter(title: "Card or Pass") var cardOrPass: String?
    @Parameter(title: "Name") var name: String?
    @Parameter(title: "Shortcut Input") var shortcutInput: String?
    @Parameter(title: "Transaction reference (if offered)") var reference: String?
    @Parameter(title: "Additional Value 1") var additional1: String?
    @Parameter(title: "Additional Value 2") var additional2: String?
    @Parameter(title: "Additional Value 3") var additional3: String?

    func perform() async throws -> some IntentResult {
        let began = Date()
        let bundle = Bundle.main.bundleIdentifier ?? ""
        let database = try PaceDatabase(url: PaceDatabase.defaultURL(appGroup: "group.\(bundle)"))
        let databaseOpenMS = Int(Date().timeIntervalSince(began) * 1_000)
        let request = WalletCaptureAdapter.request(amount: amount, merchant: merchant,
            cardOrPass: cardOrPass, name: name, shortcutInput: shortcutInput, reference: reference,
            additionalValues: ["additional1": additional1, "additional2": additional2, "additional3": additional3].compactMapValues { $0 },
            capturedAt: Instant(began), timeZone: TimeZone.current.identifier)
        var policy = CaptureTrustPolicy()
        let settings = UserDefaults(suiteName: "group.\(bundle)")
        if let ceiling = settings?.object(forKey: "pace.capture.testingCeilingMinor") as? Int {
            policy.testingCeilingMinor = ceiling
        }
        if let stage = settings?.string(forKey: "pace.capture.applePayStage").flatMap(CaptureStage.init(rawValue:)) {
            policy.pinnedStage = stage
        }
        let appState: String = await MainActor.run {
            switch UIApplication.shared.applicationState {
            case .active: "foreground"
            case .background: "background"
            case .inactive: "inactive"
            @unknown default: "unknown"
            }
        }
        #if DEBUG
        let retainRawDiagnostics = true
        #else
        let retainRawDiagnostics = false
        #endif
        let result = try CaptureProcessor(database: database).process(request, policy: policy,
            executionContext: "app_intent_\(appState)", retainRawDiagnostics: retainRawDiagnostics,
            intentStartedAt: began, databaseOpenMS: databaseOpenMS)
        await CaptureNotifications.removeOldSavedNotifications()
        let notificationStatus = await CaptureNotifications.post(result)
        if let recordID = result.recordID, result.outcome == .saved || result.outcome == .draft {
            try? CaptureProcessor(database: database).markNotification(recordID: recordID,
                status: notificationStatus, at: Date())
        }
        return .result()
    }
}

struct PaceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LogWalletPaymentIntent(), phrases: ["Log a payment with \(.applicationName)"],
                    shortTitle: "Log Apple Pay payment", systemImageName: "creditcard")
        AppShortcut(intent: LogScreenshotIntent(), phrases: ["Log a screenshot with \(.applicationName)"],
                    shortTitle: "Log Screenshot", systemImageName: "text.viewfinder")
    }
}
