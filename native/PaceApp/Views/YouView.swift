import PaceCore
import PaceStore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Profile (payday anchor, salary as a recurring income rule, savings target)
/// and data: Files backup/restore, JSON export.
struct YouView: View {
    private enum DataAction { case reset, clearFeedback }

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @AppStorage("pace.appearance") private var appearance = 0
    @FocusState private var amountFocused: Bool
    @State private var anchor: Int?
    @State private var salary = ""
    @State private var salaryDay = 25
    @State private var salaryEffectiveSelection: LocalDate?
    @State private var savingsMode = SavingsMode.fixed
    @State private var savingsAmount = ""
    @State private var savingsPercent = ""
    @State private var commitments = ""
    @State private var loadedVersion: Int64 = -1

    @State private var restoring = false
    @State private var pendingRestore: URL?
    @State private var exportFile: ExportFile?
    @State private var pendingDataAction: DataAction?
    @State private var showNotificationDetails = true
    @Environment(\.openURL) private var openURL
    #if DEBUG
    @State private var showingCaptureLab = false
    #endif

    var body: some View {
        Form {
            Section {
                Picker("Payday", selection: $anchor) {
                    Text("Not set").tag(Int?.none)
                    ForEach(1...31, id: \.self) { Text(ordinal($0)).tag(Int?.some($0)) }
                }
                .accessibilityIdentifier("profile-payday")
                amountField("Monthly salary", text: $salary, id: "profile-salary")
                Picker("Salary arrives on", selection: $salaryDay) {
                    ForEach(1...31, id: \.self) { Text(ordinal($0)).tag($0) }
                }
                if salaryChanged {
                    DatePicker("Salary change from", selection: Binding(
                        get: { DateText.date(salaryEffectiveSelection ?? model.today) },
                        set: { salaryEffectiveSelection = DateText.local($0) }),
                        in: DateText.date(model.today)..., displayedComponents: .date)
                        .environment(\.calendar, DateText.utcCalendar)
                        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                        .environment(\.locale, Locale(identifier: "en_MY"))
                }
                if let upcoming = model.upcomingSalary {
                    LabeledContent("Scheduled salary",
                                   value: "\(model.money.string(upcoming.amountMinor)) from \(DateText.long(upcoming.start))")
                }
            } header: {
                Text("Your cycle")
            } footer: {
                Text("Your cycle runs from payday to the day before next payday. Days 29–31 use the month's last day when a month is shorter. Salary changes start \(DateText.long(selectedSalaryCycle.start)); earlier cycles keep their salary. Salary counts as expected until you log it.")
            }
            Section("Savings") {
                Picker("Target", selection: $savingsMode) {
                    Text("Fixed amount").tag(SavingsMode.fixed)
                    Text("% of income").tag(SavingsMode.percentage)
                }
                if savingsMode == .fixed {
                    amountField("Savings target", text: $savingsAmount, id: "profile-savings")
                } else {
                    HStack {
                        Text("Percentage")
                        Spacer()
                        TextField("20", text: $savingsPercent).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                        Text("%").foregroundStyle(Theme.ink3)
                    }
                }
                amountField("Fixed commitments", text: $commitments, id: "profile-commitments")
            }
            if let error = model.errorMessage {
                Section { Text(error).font(Theme.body(14)).foregroundStyle(Theme.warn) }
            }
            Section("App") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                LabeledContent("Time zone", value: model.zone.identifier)
            }
            Section {
                Button("Review capture drafts") { router.reviewCaptures() }
                Toggle("Show transaction details", isOn: $showNotificationDetails)
                    .onChange(of: showNotificationDetails) { _, value in
                        captureDefaults?.set(value, forKey: CaptureNotifications.detailsKey)
                        if !value { Task { await CaptureNotifications.removeDeliveredCaptureNotifications() } }
                    }
                Button("Open Pace notification settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            } header: {
                Text("Capture notifications")
            } footer: {
                Text("Pace includes payment details when this is on. iOS decides when previews appear. For details only while unlocked, set Pace’s iOS Show Previews to When Unlocked.")
            }
            Section {
                Button("Export backup (.sqlite)") { exportFile = model.makeBackupFile().map(ExportFile.init) }
                Button("Export data (JSON)") { exportFile = model.makeJSONExport().map(ExportFile.init) }
                Button("Restore from backup…", role: .destructive) { restoring = true }
                Button("Reset Pace Data", role: .destructive) { pendingDataAction = .reset }
                    .accessibilityIdentifier("reset-pace-data")
                Button("Clear Capture Feedback", role: .destructive) { pendingDataAction = .clearFeedback }
                    .accessibilityIdentifier("clear-capture-feedback")
            } header: {
                Text("Data")
            } footer: {
                Text("Stored on this iPhone. Pace keeps automatic local snapshots; export a backup to Files to keep a copy outside the app. JSON exports are plain text.")
            }
            Section("About") {
                LabeledContent("Financial locale", value: "Malaysia · MYR")
                #if DEBUG
                Button("Capture Lab") { showingCaptureLab = true }
                LabeledContent("Keypad entries timed", value: timingSummary)
                    .accessibilityIdentifier("entry-timing")
                Button("Reset entry timing") { model.resetEntryDurations(); loadedVersion = -2 }
                #endif
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
            }
        }
        .navigationTitle("You")
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            if dirty {
                Button("Save") { saveProfile() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("profile-save")
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { amountFocused = false }
            }
        }
        .onAppear {
            load()
            showNotificationDetails = captureDefaults?.object(forKey: CaptureNotifications.detailsKey) as? Bool ?? true
        }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.data, .database]) { result in
            if case let .success(url) = result { pendingRestore = url }
        }
        .confirmationDialog("Replace all Pace data with this backup?", isPresented: Binding(
            get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }), titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                if let url = pendingRestore { model.restore(from: url) }
                pendingRestore = nil
                load(force: true)
            }
        } message: {
            Text("A safety copy of the current data is kept first.")
        }
        .alert(pendingDataAction == .reset ? "Reset Pace Data?" : "Clear Capture Feedback?",
               isPresented: Binding(get: { pendingDataAction != nil },
                                    set: { if !$0 { pendingDataAction = nil } })) {
            if pendingDataAction == .reset {
                Button("Reset Data", role: .destructive) {
                    pendingDataAction = nil
                    if model.resetPaceData() {
                        load(force: true)
                        showNotificationDetails = true
                        Task { await CaptureNotifications.removeDeliveredCaptureNotifications() }
                    }
                }
            } else {
                Button("Clear Feedback", role: .destructive) {
                    pendingDataAction = nil
                    _ = model.clearCaptureFeedback()
                }
            }
            Button("Cancel", role: .cancel) { pendingDataAction = nil }
        } message: {
            Text(pendingDataAction == .reset
                ? "This will delete your transactions and other local Pace data. Capture Feedback will be kept."
                : "This will permanently delete the local capture feedback dataset. Your Pace transactions and other app data will be kept.")
        }
        .sheet(item: $exportFile) { file in ShareSheet(url: file.url) }
        #if DEBUG
        .sheet(isPresented: $showingCaptureLab) { CaptureLabView() }
        #endif
    }

    private var captureDefaults: UserDefaults? {
        Bundle.main.bundleIdentifier.flatMap { UserDefaults(suiteName: "group.\($0)") }
    }

    private var timingSummary: String {
        let durations = model.entryDurations.sorted()
        guard !durations.isEmpty else { return "none yet" }
        let middle = durations.count / 2
        let median = durations.count % 2 == 0 ? (durations[middle - 1] + durations[middle]) / 2 : durations[middle]
        return "\(durations.count) · median \(String(format: "%.1f", median)) s"
    }

    private var selectedSalaryCycle: Cycle {
        Cycle.containing(salaryEffectiveSelection ?? model.today, anchorDay: anchor ?? 1)
    }

    private var dirty: Bool {
        let profile = model.profile
        return anchor != profile?.paydayAnchor ||
            AppModel.amountMinor(typed: salary) != (profile?.salaryRule?.amountMinor ?? 0) ||
            salaryDay != (profile?.salaryRule?.dayOfMonth ?? 25) ||
            savingsMode != (profile?.savingsMode ?? .fixed) ||
            AppModel.amountMinor(typed: savingsAmount) != (profile?.savingsTargetMinor ?? 0) ||
            AppModel.amountMinor(typed: savingsPercent) != (profile?.savingsBasisPoints ?? 0) ||
            AppModel.amountMinor(typed: commitments) != (profile?.fixedCommitmentsMinor ?? 0)
    }

    private var salaryChanged: Bool {
        AppModel.amountMinor(typed: salary) != (model.profile?.salaryRule?.amountMinor ?? 0) ||
        salaryDay != (model.profile?.salaryRule?.dayOfMonth ?? 25)
    }

    private func ordinal(_ day: Int) -> String {
        let suffix = (11...13).contains(day % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][day % 10] ?? "th"
        return "\(day)\(suffix)"
    }

    private func amountField(_ label: String, text: Binding<String>, id: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { Text(label); Spacer(); moneyInput(text, id: id).frame(minWidth: 110, maxWidth: 170) }
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                moneyInput(text, id: id)
            }
        }
    }

    private func moneyInput(_ text: Binding<String>, id: String) -> some View {
        HStack {
            Text("RM").foregroundStyle(Theme.ink3)
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($amountFocused)
                .accessibilityIdentifier(id)
        }
        .font(Theme.body(16, .medium))
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface2))
    }

    private func plain(_ minor: Int) -> String {
        minor == 0 ? "" : MoneyFormat().digits(minor).replacingOccurrences(of: ",", with: "")
    }

    private func load() { load(force: false) }

    private func load(force: Bool) {
        let profile = model.profile
        guard force || loadedVersion != (profile?.versionID ?? 0) else { return }
        loadedVersion = profile?.versionID ?? 0
        anchor = profile?.paydayAnchor
        salary = plain(profile?.salaryRule?.amountMinor ?? 0)
        salaryDay = profile?.salaryRule?.dayOfMonth ?? 25
        salaryEffectiveSelection = model.today
        savingsMode = profile?.savingsMode ?? .fixed
        savingsAmount = plain(profile?.savingsTargetMinor ?? 0)
        savingsPercent = profile.map { String(format: "%g", Double($0.savingsBasisPoints) / 100) } ?? ""
        commitments = plain(profile?.fixedCommitmentsMinor ?? 0)
    }

    private func saveProfile() {
        let input = ProfileInput(
            paydayAnchor: anchor, salaryMinor: AppModel.amountMinor(typed: salary), salaryDay: salaryDay,
            effectiveCycleStart: Cycle.containing(salaryEffectiveSelection ?? model.today, anchorDay: anchor ?? 1).start,
            savingsMode: savingsMode, savingsTargetMinor: savingsMode == .fixed ? AppModel.amountMinor(typed: savingsAmount) : 0,
            savingsBasisPoints: savingsMode == .percentage ? AppModel.amountMinor(typed: savingsPercent) : 0,
            fixedCommitmentsMinor: AppModel.amountMinor(typed: commitments))
        if model.setProfile(input) { load(force: true) }
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Hands a file to the system share sheet ("Save to Files", AirDrop).
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
