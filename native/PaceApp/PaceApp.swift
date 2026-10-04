import SwiftUI
import UserNotifications

@main
struct PaceApp: App {
    @UIApplicationDelegateAdaptor(CaptureNotificationDelegate.self) private var captureNotifications
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() { Theme.registerFonts() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .task {
                    guard !LaunchOptions.current.inMemory else { return }
                    _ = try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .badge, .sound])
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // The day or cycle may have rolled over while in the background.
            if phase == .active {
                model.refresh()
                Task { await CaptureNotifications.removeOldSavedNotifications() }
            }
        }
    }
}
