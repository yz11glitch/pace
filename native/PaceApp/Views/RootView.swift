import Observation
import PaceCore
import PaceStore
import SwiftUI

@MainActor @Observable
final class Router {
    enum Tab: Hashable { case home, history, you }
    enum Sheet: Identifiable {
        case capture(Date)
        case edit(StoredTransaction)
        case captureDrafts(String?)
        #if DEBUG
        case captureLab
        #endif
        var id: String {
            switch self {
            case .capture: "capture"
            case let .edit(transaction): "edit-\(transaction.id)"
            case .captureDrafts: "capture-drafts"
            #if DEBUG
            case .captureLab: "capture-lab"
            #endif
            }
        }
    }
    var tab: Tab = .home
    var sheet: Sheet?
    func capture() { sheet = .capture(Date()) }
    func edit(_ transaction: StoredTransaction) { sheet = .edit(transaction) }
    func reviewCaptures(_ id: String? = nil) { sheet = .captureDrafts(id) }
    func showHistory() { tab = .history }
    func showYou() { tab = .you }
    #if DEBUG
    func showCaptureLab() { tab = .you; sheet = .captureLab }
    #endif
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var router = Router()
    @AppStorage("pace.appearance") private var appearance = 0

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Home", systemImage: "house", value: Router.Tab.home) {
                NavigationStack { HomeView() }
            }
            Tab("History", systemImage: "list.bullet.rectangle.portrait", value: Router.Tab.history) {
                NavigationStack { HistoryView() }
            }
            Tab("You", systemImage: "slider.horizontal.3", value: Router.Tab.you) {
                NavigationStack { YouView() }
            }
        }
        .tabBarMinimizeBehavior(.never)
        .tint(Theme.ink)
        .environment(router)
        .tabViewBottomAccessory { CaptureBar().environment(router) }
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case let .capture(openedAt):
                EntrySheet(openedAt: openedAt)
                    .environment(router)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationBackground(Theme.card)
            case let .edit(transaction):
                EditSheet(transaction: transaction)
                    .environment(router)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationBackground(Theme.card)
            case let .captureDrafts(id):
                CaptureDraftsView(selectedID: id)
            #if DEBUG
            case .captureLab:
                CaptureLabView()
            #endif
            }
        }
        // Transient banners float at the top safe area so they never cover the tab bar
        // or the Capture accessory; content layout is unaffected.
        .overlay(alignment: .top) {
            if router.sheet == nil { ToastView() }
        }
        .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
        .onReceive(NotificationCenter.default.publisher(for: .paceCaptureOpenRecord)) { notice in
            guard let id = notice.object as? String else { return }
            openCaptureRecord(id)
        }
        .onAppear {
            if let id = UserDefaults.standard.string(forKey: "pace.capture.pendingOpenRecord") {
                openCaptureRecord(id)
            }
        }
    }

    private func openCaptureRecord(_ id: String) {
        UserDefaults.standard.removeObject(forKey: "pace.capture.pendingOpenRecord")
        model.refresh()
        if let transaction = try? model.database.writer.read({ try Queries.confirmedTransaction($0, id: id) }) {
            router.edit(transaction)
        } else {
            router.reviewCaptures(id)
        }
    }
}

struct CaptureBar: View {
    @Environment(Router.self) private var router
    var body: some View {
        Button { router.capture() } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.accent))
                Text("Capture").font(Theme.body(15, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Capture")
        .accessibilityIdentifier("add-button")
        .keyboardShortcut("n", modifiers: .command)
        .padding(.horizontal, 16)
    }
}

struct TransactionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicType
    let transaction: StoredTransaction
    var showDate = false
    var showCaptureTime = false

    var body: some View {
        let value = Text(model.money.flow(transaction.amountMinor, type: transaction.type))
            .font(Theme.body(16, .semibold, relativeTo: .callout))
            .monospacedDigit()
            .foregroundStyle(Theme.tint(for: transaction.type))
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: transaction.categoryPending ? "circle.dashed" : transaction.type == .contribution ? CategorySymbol.name("Set aside") :
                    transaction.type == .income ? CategorySymbol.name("Income") : CategorySymbol.name(transaction.categoryName))
                .font(.system(size: 22))
                .foregroundStyle(Theme.ink2)
                .frame(width: 24)
                .accessibilityHidden(true)
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    titleAndSubtitle
                    value.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                titleAndSubtitle
                Spacer(minLength: 4)
                value.fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.vertical, 9)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(transaction.title), \(subtitle), \(model.money.spokenFlow(transaction.amountMinor, type: transaction.type))")
    }

    private var titleAndSubtitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(transaction.title).font(Theme.body(15, .semibold, relativeTo: .subheadline)).foregroundStyle(transaction.hasMerchant ? Theme.ink : Theme.ink2)
                .lineLimit(transaction.hasMerchant ? 2 : 1)
            Text(subtitle).font(Theme.body(13, .medium, relativeTo: .footnote)).foregroundStyle(Theme.ink2).lineLimit(dynamicType.isAccessibilitySize ? 2 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        if showCaptureTime {
            var parts = transaction.kindLabel == transaction.title ? [] : [transaction.kindLabel]
            if transaction.captureSource != nil, transaction.localDate == model.today {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_MY")
                formatter.timeZone = TimeZone(identifier: transaction.tzIdentifier)
                formatter.timeStyle = .short
                parts.append(formatter.string(from: transaction.occurredAt.date))
            } else {
                parts.append(transaction.localDate == model.today ? "Today" : transaction.localDate == model.today.adding(days: -1) ? "Yesterday" : DateText.day(transaction.localDate))
            }
            if let source = transaction.captureSource { parts.append(source.label) }
            return parts.joined(separator: " · ")
        }
        return [showDate ? DateText.short(transaction.localDate) : "", transaction.ledgerMetadata]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0
    var body: some View {
        ZStack {
            if let toast = model.toast {
                HStack(spacing: 12) {
                    Text(toast.message)
                        .font(Theme.body(15, .medium))
                        .foregroundStyle(Theme.card)
                        .accessibilityIdentifier("toast-message")
                    Spacer(minLength: 0)
                    if let id = toast.undoActionID {
                        Button("Undo") { model.undo(id, draftDiscard: toast.undoIsDraftDiscard) }
                            .font(Theme.body(15, .semibold))
                            .foregroundStyle(Theme.card)
                            .accessibilityIdentifier("toast-undo")
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("toast")
                .offset(y: dragOffset)
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        model.toastTouchedID = toast.id
                        dragOffset = drag.translation.height < 0 ? drag.translation.height : drag.translation.height * 0.25
                    }
                    .onEnded { drag in
                        model.toastTouchedID = nil
                        if (drag.translation.height < -45 || drag.predictedEndTranslation.height < -80), model.toast?.id == toast.id {
                            withAnimation(.easeOut(duration: 0.14)) { model.toast = nil }
                        }
                        withAnimation(.easeOut(duration: 0.14)) { dragOffset = 0 }
                    })
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .id(toast.id)
                .task(id: toast.id) {
                    dragOffset = 0
                    var remaining = 50
                    while remaining > 0 {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        guard model.toast?.id == toast.id else { return }
                        if model.toastTouchedID != toast.id { remaining -= 1 }
                    }
                    if model.toast?.id == toast.id { model.toast = nil }
                }
                .onDisappear { if model.toastTouchedID == toast.id { model.toastTouchedID = nil } }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast?.id)
    }
}

/// The same restrained entry on Home (primary) and History (secondary).
struct CaptureAttentionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        Button { router.reviewCaptures(model.captureAttention.singleDraftID) } label: {
            HStack(spacing: 12) {
                Image(systemName: "circle.dashed").accessibilityHidden(true)
                Text(model.captureAttention.summary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote).accessibilityHidden(true)
            }
            .font(Theme.body(15, .medium))
            .foregroundStyle(Theme.ink2)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PaceRowButtonStyle())
        .accessibilityIdentifier("capture-attention")
    }
}
