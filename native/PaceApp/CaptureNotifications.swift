import Foundation
import PaceCore
import PaceStore
import UserNotifications
import UIKit

/// Notification delivery is best effort; the database write is already complete.
enum CaptureNotifications {
    static let savedCategory = "pace.capture.saved"
    static let draftCategory = "pace.capture.draft"
    static let infoCategory = "pace.capture.info"
    static let detailsKey = "pace.capture.showNotificationDetails"

    static var showDetails: Bool {
        let group = Bundle.main.bundleIdentifier.map { "group.\($0)" }
        guard let defaults = group.flatMap(UserDefaults.init(suiteName:)) else { return true }
        return defaults.object(forKey: detailsKey) as? Bool ?? true
    }

    static func register() {
        let undo = UNNotificationAction(identifier: "pace.capture.undo", title: "Undo",
                                        options: [.destructive, .authenticationRequired])
        let edit = UNNotificationAction(identifier: "pace.capture.edit", title: "Edit", options: [.foreground])
        let saved = UNNotificationCategory(identifier: savedCategory, actions: [undo, edit], intentIdentifiers: [],
                                           hiddenPreviewsBodyPlaceholder: "Transaction saved in Pace")
        let draft = UNNotificationCategory(identifier: draftCategory, actions: [edit], intentIdentifiers: [],
                                           hiddenPreviewsBodyPlaceholder: "Transaction needs attention in Pace")
        let info = UNNotificationCategory(identifier: infoCategory, actions: [], intentIdentifiers: [],
                                          hiddenPreviewsBodyPlaceholder: "Pace capture result")
        UNUserNotificationCenter.current().setNotificationCategories([saved, draft, info])
    }

    static func postNoPayment() async -> String { await postInformation("No payment found on screen") }

    static func postOCRFailure() async -> String { await postInformation("Couldn't read screenshot") }

    static func postCaptureFailure() async -> String { await postInformation("Couldn't process screenshot") }

    static func postDuplicate(_ result: CaptureResult) async -> String {
        let draft = result.reason.contains("draft")
        let title: String
        if showDetails {
            let amount = result.amountMinor.map { MoneyFormat(locale: .malaysia).string($0) }
            title = ([draft ? "Already in Drafts" : "Already saved", amount, result.merchant]
                .compactMap { $0 }).joined(separator: " · ")
        } else { title = "Capture already in Pace" }
        return await postInformation(title)
    }

    private static func postInformation(_ title: String) async -> String {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return "not authorized"
        }
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = infoCategory
        content.threadIdentifier = "pace.capture"
        content.title = title
        content.interruptionLevel = .passive
        do {
            try await center.add(UNNotificationRequest(identifier: "pace.capture.info.\(UUID().uuidString)",
                                                       content: content, trigger: nil))
            return "scheduled"
        } catch { return "schedule failed: \(error.localizedDescription)" }
    }

    static func post(_ result: CaptureResult) async -> String {
        guard result.outcome == .saved || result.outcome == .draft, let id = result.recordID else { return "not applicable" }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings()
        guard status.authorizationStatus == .authorized || status.authorizationStatus == .provisional else {
            return "not authorized"
        }
        let content = UNMutableNotificationContent()
        content.threadIdentifier = "pace.capture"
        content.interruptionLevel = .active
        content.sound = result.outcome == .draft ? .default : nil
        content.userInfo = ["recordID": id, "actionID": result.actionID ?? ""]
        content.categoryIdentifier = result.outcome == .saved ? savedCategory : draftCategory
        var message = CaptureNotificationText.titleAndBody(result, showDetails: showDetails)
        if showDetails, result.outcome == .draft { message.body = ReasonCopy.short(result) }
        content.title = message.title
        content.body = message.body
        let request = UNNotificationRequest(identifier: "pace.capture.\(id)", content: content, trigger: nil)
        do {
            try await center.add(request)
            return "scheduled"
        } catch {
            return "schedule failed: \(error.localizedDescription)"
        }
    }

    static func removeOldSavedNotifications() async {
        let center = UNUserNotificationCenter.current()
        let old = await center.deliveredNotifications().filter {
            $0.request.content.categoryIdentifier == savedCategory &&
                Date().timeIntervalSince($0.date) > 3_600
        }.map { $0.request.identifier }
        if !old.isEmpty { center.removeDeliveredNotifications(withIdentifiers: old) }
    }

    static func removeDeliveredCaptureNotifications() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.deliveredNotifications().filter {
            $0.request.content.threadIdentifier == "pace.capture"
        }.map { $0.request.identifier }
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }
}

final class CaptureNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CaptureNotifications.register()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let recordID = info["recordID"] as? String else { return }
        if response.actionIdentifier == "pace.capture.undo", let actionID = info["actionID"] as? String, !actionID.isEmpty {
            let bundle = Bundle.main.bundleIdentifier ?? ""
            do {
                let database = try PaceDatabase(url: PaceDatabase.defaultURL(appGroup: "group.\(bundle)"))
                _ = try LedgerExecutor(database: database).undo(actionID)
                center.removeDeliveredNotifications(withIdentifiers: [response.notification.request.identifier])
            } catch {
                let bundle = Bundle.main.bundleIdentifier ?? ""
                if let database = try? PaceDatabase(url: PaceDatabase.defaultURL(appGroup: "group.\(bundle)")) {
                    try? CaptureProcessor(database: database).recordActionFailure(recordID: recordID,
                        reason: "notification Undo: \(error.localizedDescription)")
                }
            }
        } else if response.actionIdentifier == "pace.capture.edit" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run {
                UserDefaults.standard.set(recordID, forKey: "pace.capture.pendingOpenRecord")
                NotificationCenter.default.post(name: .paceCaptureOpenRecord, object: recordID)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

extension Notification.Name {
    static let paceCaptureOpenRecord = Notification.Name("paceCaptureOpenRecord")
}
