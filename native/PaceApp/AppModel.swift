import Foundation
import Observation
import UIKit
import PaceCore
import PaceStore

/// App state. Reads go through `Queries`; ledger changes are logged and undoable.
@Observable
final class AppModel {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let undoActionID: String?
        var undoIsDraftDiscard = false
    }

    private(set) var database: PaceDatabase
    private(set) var executor: LedgerExecutor
    private let launch: LaunchOptions

    var home: HomeSnapshot?
    var upcomingSalary: SalaryRule?
    var history: [StoredTransaction] = []
    /// Home's recent list; independent of History's search and range.
    var recent: [StoredTransaction] = []
    var categories: [PaceStore.Category] = []
    var captureAttention = CaptureAttentionCounts.empty
    var refreshVersion = 0
    var historyQuery = HistoryQuery()
    var toast: Toast?
    var toastTouchedID: UUID?
    var errorMessage: String?
    let money = MoneyFormat(locale: .malaysia)

    init(launch: LaunchOptions = .current) {
        self.launch = launch
        let database: PaceDatabase
        if launch.inMemory {
            database = try! PaceDatabase()
        } else {
            let group = Bundle.main.bundleIdentifier.map { "group.\($0)" }
            database = try! PaceDatabase(url: PaceDatabase.defaultURL(appGroup: group))
        }
        self.database = database
        self.executor = LedgerExecutor(database: database, now: launch.now)
        #if DEBUG
        if launch.inMemory, let seed = launch.seed { DemoSeed.apply(seed, executor: executor, today: today) }
        #endif
        if !launch.inMemory { _ = try? Backup.autoSnapshot(database, directory: Self.snapshotDirectory) }
        refresh()
    }

    // MARK: Clock and zone — the device time zone, never the device region.

    var zone: Zone { Zone(identifier: launch.timeZone) ?? Zone(identifier: "Asia/Kuala_Lumpur")! }
    var now: Instant { Instant(launch.now()) }
    var today: LocalDate { zone.local(now).time.date }

    static var snapshotDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Pace/Snapshots", isDirectory: true)
    }

    // MARK: Reads

    func refresh() {
        do {
            let today = today
            let query = historyQuery
            let (home, history, recent, categories, attention) = try database.writer.read { db in
                (try Queries.home(db, today: today), try Queries.history(db, query),
                 try Queries.history(db, HistoryQuery(limit: 3)), try Queries.categories(db),
                 try Queries.captureAttention(db))
            }
            let upcomingSalary = try database.writer.read { try Queries.nextSalaryChange($0, after: home.cycle.start) }
            self.home = home
            self.history = history
            self.recent = recent
            self.categories = categories
            self.upcomingSalary = upcomingSalary
            self.captureAttention = attention
            self.refreshVersion += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var profile: Profile? { home?.profile }

    /// Typed amounts accept "," as the decimal mark (some regions' decimal pads).
    static func amountMinor(typed text: String) -> Int {
        Keypad.amountMinor(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    func categoryName(_ id: String?) -> String? { categories.first { $0.id == id }?.name }

    func categoryID(_ name: String) -> String? { categories.first { $0.name == name }?.id }

    func resolveMerchant(_ name: String) -> MerchantMatch? {
        try? database.writer.read { try Queries.resolveMerchant($0, name: name) }
    }

    func openSalaryOccurrence() -> ExpectedOccurrence? {
        try? database.writer.read { [today] in try Queries.openSalaryOccurrence($0, today: today) }
    }

    // MARK: Writes

    @discardableResult
    func perform(_ message: (Executed) -> String, _ write: () throws -> Executed) -> Executed? {
        do {
            let executed = try write()
            refresh()
            if executed.kind == "delete_transaction" { PaceHaptics.destructive() }
            else if executed.kind == "undo" { PaceHaptics.undo() }
            else { PaceHaptics.success() }
            toast = Toast(message: message(executed), undoActionID: executed.kind == "undo" ? nil : executed.actionID)
            return executed
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func save(_ draft: TransactionDraft, requestID: String) -> Bool {
        perform({ executed in
            let t = executed.transaction
            let label = t.merchantText.flatMap { $0.isEmpty ? nil : $0 } ?? t.categoryName ?? t.type.label
            return "Saved · \(money.string(t.amountMinor)) · \(label)"
        }) { try executor.create(draft, requestID: requestID) } != nil
    }

    /// Capture presents its own committed result, so it does not emit a toast.
    /// The executor preserves request idempotency for entry creation.
    func saveEntry(_ draft: TransactionDraft, requestID: String) -> Executed? {
        do {
            let result = try executor.create(draft, requestID: requestID)
            refresh()
            PaceHaptics.success()
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func update(_ id: String, _ changes: TransactionChanges,
                captureFeedbackIssue: CaptureFeedbackIssue? = nil, remember: Bool = true) -> Bool {
        perform({ _ in "Changes saved" }) {
            try executor.update(id, changes, captureFeedbackIssue: captureFeedbackIssue, remember: remember)
        } != nil
    }

    func setCaptureFeedbackIssue(_ id: String, _ issue: CaptureFeedbackIssue, quiet: Bool = false) -> Bool {
        do {
            if quiet, try CaptureFeedbackIssueStore.state(database, transactionID: id) == issue { return true }
            try CaptureFeedbackIssueStore.set(database, transactionID: id, issue: issue)
            if !quiet {
                refresh()
                PaceHaptics.success()
                toast = Toast(message: issue.explicitlyReportedIssue ? "Problem reported" : "Report removed", undoActionID: nil)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(_ id: String) {
        perform({ executed in "Deleted \(money.string(executed.transaction.amountMinor))" }) { try executor.softDelete(id) }
    }

    func undo(_ actionID: String, draftDiscard: Bool = false) {
        if draftDiscard {
            do {
                try executor.undoDraftDiscard(actionID)
                refresh()
                PaceHaptics.undo()
                toast = Toast(message: "Undone", undoActionID: nil)
            } catch { errorMessage = error.localizedDescription }
            return
        }
        perform({ _ in "Undone" }) { try executor.undo(actionID) }
    }

    @discardableResult
    func discardCapture(_ id: String, feedbackIssue: CaptureFeedbackIssue? = nil) -> Bool {
        do {
            // Existing callers may persist a report before deletion. Review now
            // writes independently, so discard itself never carries stale UI state.
            if let feedbackIssue {
                try CaptureFeedbackIssueStore.set(database, transactionID: id, issue: feedbackIssue)
            }
            let actionID = try CaptureReview.discard(database, id: id, now: launch.now)
            refresh()
            if let actionID {
                PaceHaptics.destructive()
                toast = Toast(message: "Capture discarded", undoActionID: actionID, undoIsDraftDiscard: true)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func confirmCapture(_ id: String, amount: Int, merchant: String, categoryID: String,
                        remember: Bool, occurredAt: Instant?, note: String??) -> Bool {
        do {
            let action = try CaptureReview.confirm(database, id: id, amountMinor: amount,
                merchant: merchant, categoryID: categoryID, remember: remember, occurredAt: occurredAt, note: note)
            refresh()
            let transaction = try database.writer.read { try Queries.confirmedTransaction($0, id: id) }!
            PaceHaptics.success()
            toast = Toast(message: "Saved · \(money.string(amount)) · \(transaction.title)", undoActionID: action)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func setProfile(_ input: ProfileInput) -> Bool {
        do {
            let priorRule = try database.writer.read {
                try Queries.salaryRule($0, forCycleStarting: input.effectiveCycleStart)
            }
            let saved = try executor.setProfile(input)
            refresh()
            let currentCycle = Cycle.containing(today, anchorDay: input.paydayAnchor ?? 1)
            let message = input.effectiveCycleStart > currentCycle.start && priorRule?.id != saved.salaryRule?.id
                ? "Salary scheduled from \(input.effectiveCycleStart.iso)" : "Profile saved"
            toast = Toast(message: message, undoActionID: nil)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: Data

    func makeBackupFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pace-\(today.iso).sqlite")
        do {
            try Backup.snapshot(database, to: url)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func makeJSONExport() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pace-\(today.iso).json")
        do {
            try Backup.exportJSON(database, to: url)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func restore(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try Backup.restore(database, from: url, safetyDirectory: Self.snapshotDirectory)
            refresh()
            toast = Toast(message: "Backup restored. A safety copy of the previous data was kept.", undoActionID: nil)
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func resetPaceData() -> Bool {
        do {
            try PaceDataMaintenance.resetPaceData(database)
            let defaults = UserDefaults.standard
            for key in ["pace.appearance", "pace.entryDurations", "pace.capture.pendingOpenRecord"] {
                defaults.removeObject(forKey: key)
            }
            if let bundle = Bundle.main.bundleIdentifier,
               let captureDefaults = UserDefaults(suiteName: "group.\(bundle)") {
                for key in ["pace.capture.showNotificationDetails", "pace.capture.testingCeilingMinor",
                            "pace.capture.screenshotStage", "pace.capture.applePayStage"] {
                    captureDefaults.removeObject(forKey: key)
                }
            }
            historyQuery = HistoryQuery()
            errorMessage = nil
            refresh()
            do {
                if !launch.inMemory { try Backup.removeManagedSnapshots(in: Self.snapshotDirectory) }
                toast = Toast(message: "Pace data reset. Capture Feedback kept.", undoActionID: nil)
            } catch {
                errorMessage = "Pace data reset, but local snapshots could not be removed: \(error.localizedDescription)"
            }
            return true
        } catch {
            errorMessage = "Reset failed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func clearCaptureFeedback() -> Bool {
        do {
            if !launch.inMemory { try Backup.clearFeedbackFromManagedSnapshots(in: Self.snapshotDirectory) }
            try PaceDataMaintenance.clearCaptureFeedback(database)
            let export = FileManager.default.temporaryDirectory.appendingPathComponent("pace-capture-feedback.json")
            if FileManager.default.fileExists(atPath: export.path) { try FileManager.default.removeItem(at: export) }
            errorMessage = nil
            toast = Toast(message: "Capture Feedback cleared", undoActionID: nil)
            return true
        } catch {
            errorMessage = "Clear Capture Feedback failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Entry timing

    private static let timingKey = "pace.entryDurations"

    func recordEntryDuration(_ seconds: Double) {
        var durations = UserDefaults.standard.array(forKey: Self.timingKey) as? [Double] ?? []
        durations.append(seconds)
        UserDefaults.standard.set(Array(durations.suffix(50)), forKey: Self.timingKey)
    }

    var entryDurations: [Double] { UserDefaults.standard.array(forKey: Self.timingKey) as? [Double] ?? [] }

    func resetEntryDurations() { UserDefaults.standard.removeObject(forKey: Self.timingKey) }
}

/// Launch arguments used by UI tests and demos. Production launches use none.
struct LaunchOptions {
    var inMemory = false
    var seed: String?
    var timeZone = TimeZone.current.identifier
    var now: @Sendable () -> Date = { Date() }

    static var current: LaunchOptions {
        let defaults = UserDefaults.standard
        var options = LaunchOptions()
        options.inMemory = defaults.bool(forKey: "PaceInMemory")
        options.seed = defaults.string(forKey: "PaceSeed")
        if let zone = defaults.string(forKey: "PaceTimeZone") { options.timeZone = zone }
        if let fixed = defaults.string(forKey: "PaceFixedNow").flatMap(Instant.init(iso:)) {
            let date = fixed.date
            options.now = { date }
        }
        return options
    }
}

/// Emitted only after successful writes or explicit decisions.
enum PaceHaptics {
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func destructive() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func undo() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
