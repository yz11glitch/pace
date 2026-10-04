import PaceCore
import PaceStore
import SwiftUI

/// Global pending work, independent of the ledger period.
struct CaptureDraftsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType
    let selectedID: String?
    @State private var drafts: [CaptureReviewDraft] = []
    @State private var error: String?
    @State private var path: [String] = []
    @State private var categoryPending: [StoredTransaction] = []
    @State private var editing: StoredTransaction?
    @State private var openedSelection = false
    @State private var openedDirectly = false
    @State private var detent = PresentationDetent.large
    @State private var width: CGFloat = 430

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error { Text(error).foregroundStyle(Theme.warn) }
                if drafts.isEmpty && categoryPending.isEmpty && error == nil {
                    ContentUnavailableView("All caught up", systemImage: "checkmark",
                                           description: Text("Nothing needs you."))
                        .listRowBackground(Theme.background)
                }
                if !drafts.isEmpty {
                    Section {
                        ForEach(drafts) { draft in
                            NavigationLink(value: draft.id) {
                                attentionItem(title: draft.title, amount: draft.amountMinor,
                                    reason: ReasonCopy.shortReview(draft.reviewState()), source: draft.source,
                                    capturedAt: draft.capturedAt)
                            }
                            .accessibilityIdentifier("pending-draft-\(draft.id)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Discard", role: .destructive) {
                                    if model.discardCapture(draft.id) { load() }
                                    else { error = model.errorMessage }
                                }
                            }
                            .accessibilityAction(named: "Discard") {
                                if model.discardCapture(draft.id) { load() }
                                else { error = model.errorMessage }
                            }
                            .listRowBackground(Theme.background)
                        }
                    } header: { Text("Not saved yet") }
                      footer: { Text("These don't count until you save them.") }
                }
                if !categoryPending.isEmpty {
                    Section("Saved · needs a category") {
                        ForEach(categoryPending) { transaction in
                            Button { editing = transaction } label: {
                                attentionItem(title: transaction.title, amount: transaction.amountMinor,
                                    reason: ReasonCopy.short(.category),
                                    source: CaptureSource(source: transaction.source, path: transaction.capturePath))
                            }
                            .accessibilityIdentifier("pending-category-\(transaction.id)")
                            .listRowBackground(Theme.background)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .listStyle(.plain)
            .navigationTitle("Needs you")
            .accessibilityIdentifier("needs-you-list")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: String.self) { id in
                if let draft = drafts.first(where: { $0.id == id }) {
                    CaptureDraftReviewView(draft: draft, onStateChange: { state in
                        let decision = state == .duplicate || state == .unusuallyLarge || state == .mayHaveFailed
                        detent = decision && width > 375 && !dynamicType.isAccessibilitySize ? .medium : .large
                    }) {
                        path = []
                        detent = .large
                        load()
                        if openedDirectly || model.captureAttention.total == 0 { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackground(Theme.background)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .sheet(item: $editing) { transaction in
            EditSheet(transaction: transaction, openAtCategory: true)
        }
        // Root's toast is behind a presented sheet. Reuse it here so list swipes
        // and Review discards have the same transient Undo within the sheet.
        .overlay(alignment: .top) {
            if editing == nil { ToastView().padding(.top, 44) }
        }
        .onAppear(perform: load)
        .onChange(of: model.refreshVersion) { load() }
    }

    private func attentionItem(title: String, amount: Int?, reason: String,
                               source: CaptureSource, capturedAt: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle.dashed").foregroundStyle(Theme.ink2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.body(15, .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(amount.map(model.money.string) ?? "Amount not known")
                    .font(Theme.body(15, .medium)).monospacedDigit().foregroundStyle(Theme.ink2)
                Text(metadata(reason: reason, source: source, capturedAt: capturedAt))
                    .font(Theme.body(13, .medium, relativeTo: .footnote)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func metadata(reason: String, source: CaptureSource, capturedAt: String?) -> String {
        var parts = [reason, source.label]
        if let instant = capturedAt.flatMap(Instant.init(iso:)) {
            let time = DateFormatter()
            time.locale = Locale(identifier: "en_MY")
            time.timeZone = TimeZone(identifier: model.zone.identifier)
            time.timeStyle = .short
            parts.append("\(DateText.short(model.zone.local(instant).time.date)) · \(time.string(from: instant.date))")
        }
        return parts.joined(separator: " · ")
    }

    private func load() {
        do {
            drafts = try CaptureReview.drafts(model.database)
            categoryPending = try model.database.writer.read { try Queries.categoryPendingCaptures($0) }
            error = nil
            if !openedSelection, let selectedID, drafts.contains(where: { $0.id == selectedID }) {
                path = [selectedID]
                openedDirectly = true
            }
            openedSelection = true
        }
        catch { self.error = error.localizedDescription }
    }
}

private struct CaptureDraftReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicType
    let draft: CaptureReviewDraft
    let onStateChange: (CaptureReviewState) -> Void
    let onConfirmed: () -> Void
    @State private var amount = ""
    @State private var merchant = ""
    @State private var category = "Other"
    @State private var date = LocalDate(iso: "2026-01-01")!
    @State private var chosenInstant: Instant?
    @State private var note = ""
    @State private var answers = CaptureReviewAnswers()
    @State private var remember = true
    @State private var reported = false
    @State private var feedbackNote = ""
    @State private var error: String?
    @State private var loaded = false
    @State private var editor: Editor?
    @FocusState private var merchantFocused: Bool
    enum Editor: String, Identifiable { case amount, merchant, category, date, note; var id: Self { self } }

    private var state: CaptureReviewState { draft.reviewState(answers: answers) }
    private var amountMinor: Int { Keypad.amountMinor(amount) }
    private var categoryID: String { model.categoryID(category) ?? "other" }
    private var valid: Bool { Keypad.isValid(amount) && merchant.count <= 200 && note.count <= 1_000 && feedbackNote.count <= 1_000 }
    private var changed: Bool {
        amountMinor != draft.amountMinor || merchant != (draft.merchant ?? "") || categoryID != (draft.categoryID ?? "other") || chosenInstant != nil || !note.isEmpty
    }
    private var teaching: MerchantTeaching? {
        guard state == .checkOnce, valid else { return nil }
        return try? MerchantTeaching.review(model.database, id: draft.id, merchant: merchant, categoryID: categoryID)
    }
    private var amountUncertain: Bool { !answers.fields.contains(.amount) && (draft.amountMinor == nil || draft.unresolved.contains(.amount) || draft.anomalySignals.contains(.ambiguousAmount)) }
    private var merchantUncertain: Bool { !answers.fields.contains(.merchant) && (draft.unresolved.contains(.merchant) || merchant.isEmpty) }
    private var captured: Instant { Instant(iso: draft.capturedAt ?? draft.occurredAt) ?? model.now }
    private var zone: Zone { draft.tzIdentifier.flatMap(Zone.init(identifier:)) ?? model.zone }
    private var context: String {
        DateText.context(captured, source: draft.source, zone: zone, today: model.today) + (reported ? " · Problem reported" : "")
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if reported { reportLine.id("capture-report-line") }
                    Theme.hair.frame(height: 1)
                    QuestionBlock(question: ReasonCopy.question(state, amount: model.money.string(amountMinor), hasUntrustedAmount: draft.amountMinor != nil),
                        evidence: ReasonCopy.evidence(state, draft: draft, reported: reported))
                        .accessibilityIdentifier("review-question")
                    answerControl
                    if state == .checkOnce {
                        VStack(spacing: 0) {
                            FieldRow(label: "Category", value: category) { editor = .category }
                            FieldRow(label: "Merchant", value: merchant.isEmpty ? "Add merchant" : merchant, placeholder: merchant.isEmpty) { editor = .merchant }
                            FieldRow(label: "Date", value: DateText.long(date)) { editor = .date }
                            FieldRow(label: "Note", value: note.isEmpty ? "Add note" : note, placeholder: note.isEmpty) { editor = .note }
                        }
                    }
                    if let error { Text(error).font(Theme.body(13)).foregroundStyle(Theme.warn) }
                }.padding(20)
            }
            .onChange(of: reported) {
                if reported, dynamicType.isAccessibilitySize { scroll.scrollTo("capture-report-line", anchor: .top) }
            }
        }
        .background(Theme.background)
        .navigationTitle("Review capture").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { if persistReport() { onConfirmed() } } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Keep for later").accessibilityIdentifier("review-close")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if draft.feedbackIssue != nil {
                        Button("Report a capture problem", systemImage: "flag") { report() }
                    }
                    Button("Discard capture", systemImage: "trash", role: .destructive) { discard() }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("More actions").accessibilityIdentifier("review-more")
            }
        }
        .safeAreaInset(edge: .bottom) { actions }
        .interactiveDismissDisabled(feedbackNote.count > 1_000)
        .sheet(item: $editor) { field in fieldEditor(field) }
        .onAppear(perform: load)
        .onChange(of: feedbackNote) { _, value in
            if reported && value.count <= 1_000 { _ = persistReport() }
        }
        .onChange(of: state) { merchantFocused = state == .merchantMissing; onStateChange(state) }
        .onDisappear { if reported { _ = persistReport() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(context).font(Theme.body(13, .medium, relativeTo: .footnote)).foregroundStyle(Theme.ink2)
            Button { editor = .amount } label: {
                Group {
                    if amountUncertain { Text("RM —").font(Theme.display(40)).foregroundStyle(Theme.ink) }
                    else { MoneyText(minor: amountMinor, size: 40) }
                }
                .padding(amountUncertain ? 10 : 0)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(amountUncertain ? Theme.boundary : .clear, style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
            }.buttonStyle(PaceRowButtonStyle()).accessibilityIdentifier("review-amount")
            Button { editor = .merchant } label: {
                Text(merchantUncertain ? "Merchant unknown" : merchant.isEmpty ? draft.source.fallbackTitle : merchant)
                    .font(Theme.body(17, .semibold)).foregroundStyle(merchant.isEmpty ? Theme.ink2 : Theme.ink)
                    .lineLimit(dynamicType.isAccessibilitySize ? 4 : 3)
                    .padding(merchantUncertain ? 10 : 0)
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(merchantUncertain ? Theme.boundary : .clear, style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
            }.buttonStyle(PaceRowButtonStyle())
            if state != .category && state != .checkOnce {
                Text(category).font(Theme.body(13)).foregroundStyle(Theme.ink2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reportLine: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Problem reported", systemImage: "flag").foregroundStyle(Theme.ink2)
                Spacer()
                Button("Remove") {
                    if model.setCaptureFeedbackIssue(draft.id, .init(explicitlyReportedIssue: false), quiet: true) {
                        reported = false; feedbackNote = ""
                    } else { error = model.errorMessage }
                }.frame(minHeight: 44)
            }.font(Theme.body(13, .medium))
            CaptureReportNote(note: $feedbackNote)
            Text("Correct anything below as usual. Pace keeps what it captured, your corrections and this note.")
                .font(Theme.body(13)).foregroundStyle(Theme.ink2)
        }
    }

    @ViewBuilder private var answerControl: some View {
        switch state {
        case .category:
            CategoryGrid(names: EntryRules.categoryChoices(for: .expense), selected: "", suggested: draft.suggestedCategory) {
                category = $0; answers.fields.insert(.category)
            }
        case .ambiguousAmount:
            VStack(spacing: 10) {
                ForEach(draft.amountCandidates, id: \.self) { candidate in
                    Button(candidate) {
                        if let value = WalletCaptureAdapter.parseAmount(candidate) {
                            PaceHaptics.selection(); setAmount(value); answers.fields.insert(.amount); answers.amountChecked = true
                        } else { editor = .amount }
                    }.buttonStyle(.bordered).frame(minHeight: 44)
                }
                Button("Other…") { editor = .amount }.frame(minHeight: 44)
            }
        case .amountMissing:
            VStack(alignment: .leading, spacing: 8) {
                MoneyText(minor: amountMinor, size: 34, rawDigits: amount.isEmpty ? "0" : amount)
                HStack { Spacer(); Button("Clear") { amount = "" }.frame(minHeight: 44) }
                KeypadView { amount = Keypad.apply($0, to: amount) }
            }
        case .merchantMissing:
            VStack(alignment: .leading, spacing: 12) {
                TextField("Merchant", text: $merchant).font(Theme.body(17)).focused($merchantFocused)
                    .submitLabel(.continue).onSubmit { advance() }.frame(minHeight: 44)
                ForEach(suggestions, id: \.self) { name in
                    Button(name) { merchant = name; advance() }.frame(minHeight: 44).buttonStyle(PaceRowButtonStyle())
                }
            }
        case .duplicate:
            if let match = draft.duplicateMatch {
                VStack(alignment: .leading, spacing: 18) {
                    comparison("Already in Pace", title: match.title, amount: match.amountMinor, instant: Instant(iso: match.occurredAt), source: match.captureSource)
                    comparison("This capture", title: draft.title, amount: draft.amountMinor, instant: captured, source: draft.source)
                }
            }
        case .unusuallyLarge:
            Button("Change amount") { editor = .amount }.frame(minHeight: 44)
        case .mayHaveFailed, .checkOnce: EmptyView()
        case .dateUnclear:
            VStack(alignment: .leading, spacing: 12) {
                Button(DateText.context(captured, source: nil, zone: zone, today: model.today).replacingOccurrences(of: "Added manually · ", with: "") + ", " + captureTime) {
                    PaceHaptics.selection(); chosenInstant = captured; date = zone.local(captured).time.date; answers.fields.insert(.date)
                }.buttonStyle(.bordered).frame(minHeight: 44)
                Button("Choose date…") { editor = .date }.frame(minHeight: 44)
            }
        }
    }
    private var captureTime: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_MY"); f.timeZone = TimeZone(identifier: zone.identifier); f.timeStyle = .short
        return f.string(from: captured.date)
    }
    private var suggestions: [String] { (try? model.database.writer.read { try Queries.merchantSuggestions($0, text: merchant) }) ?? [] }
    private func comparison(_ label: String, title: String, amount: Int?, instant: Instant?, source: CaptureSource?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.body(12, .semibold)).foregroundStyle(Theme.ink2)
            Text(title).font(Theme.body(15, .semibold)).lineLimit(2)
            Text(amount.map(model.money.string) ?? "—").font(Theme.body(16, .semibold)).monospacedDigit()
            if let instant { Text(DateText.context(instant, source: source, zone: zone, today: model.today)).font(Theme.body(13)).foregroundStyle(Theme.ink2) }
        }
    }

    private var actions: some View {
        PinnedBar {
            if let teaching { MemoryCheckbox(remember: $remember, consequence: teaching.consequence(categoryName: category)) }
            if state == .merchantMissing {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Don't know where?").font(Theme.body(13)).foregroundStyle(Theme.ink2)
                    Button("Save without a merchant") {
                        merchant = ""; answers.fields.insert(.merchant); answers.fields.insert(.category)
                        category = draft.categoryName ?? "Other"; merchantFocused = false
                        if state == .checkOnce { confirm() }
                    }.font(Theme.body(15, .semibold)).frame(minHeight: 44).accessibilityIdentifier("save-without-merchant")
                }
            }
            if dynamicType.isAccessibilitySize || state == .duplicate || state == .unusuallyLarge || state == .mayHaveFailed {
                VStack(spacing: 8) { primary; discardButton }
            } else {
                HStack(spacing: 10) { discardButton; primary }
            }
        }
    }
    private var primaryLabel: String {
        switch state {
        case .duplicate: return "Keep anyway"
        case .unusuallyLarge: return "Yes, save \(model.money.string(amountMinor))"
        case .mayHaveFailed: return "It went through"
        case .checkOnce: return "\(!changed && !reported ? "Looks right · " : "")Save · \(model.money.string(amountMinor))"
        case .amountMissing, .merchantMissing:
            var next = answers
            next.fields.insert(state == .amountMissing ? .amount : .merchant)
            if state == .amountMissing { next.amountChecked = true }
            return draft.reviewState(answers: next) == .checkOnce ? "Save · \(model.money.string(amountMinor))" : "Continue"
        default: return "Continue"
        }
    }
    private var canAdvance: Bool {
        guard feedbackNote.count <= 1_000 else { return false }
        switch state {
        case .amountMissing: return Keypad.isValid(amount)
        case .merchantMissing: return !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && merchant.count <= 200
        case .ambiguousAmount, .category, .dateUnclear: return false
        case .checkOnce, .unusuallyLarge: return valid
        case .duplicate, .mayHaveFailed: return true
        }
    }
    private var primary: some View {
        Button(primaryLabel) { advance() }.buttonStyle(PrimaryButtonStyle()).disabled(!canAdvance)
            .accessibilityIdentifier("confirm-capture-draft")
    }
    private var discardButton: some View {
        Button(state == .duplicate ? "Discard duplicate" : "Discard") { discard() }
            .font(Theme.body(15, .semibold)).foregroundStyle(Theme.ink2)
            .padding(.horizontal, 14).padding(.vertical, 14).frame(minHeight: 50)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.boundary, lineWidth: 0.5))
            .buttonStyle(PaceRowButtonStyle()).accessibilityIdentifier("discard-capture-draft")
    }
    private func advance() {
        guard canAdvance else { return }
        switch state {
        case .duplicate: answers.keepDuplicate = true
        case .amountMissing: answers.fields.insert(.amount); answers.amountChecked = true; if state == .checkOnce { confirm() }
        case .merchantMissing: answers.fields.insert(.merchant); merchantFocused = false; if state == .checkOnce { confirm() }
        case .unusuallyLarge: answers.amountChecked = true; if state == .checkOnce { confirm() }
        case .mayHaveFailed: answers.fields.insert(.status); if state == .checkOnce { confirm() }
        case .checkOnce: confirm()
        default: break
        }
    }

    @ViewBuilder private func fieldEditor(_ field: Editor) -> some View {
        NavigationStack {
            Group {
                switch field {
                case .amount:
                    VStack(alignment: .leading, spacing: 12) {
                        MoneyText(minor: amountMinor, size: 40, rawDigits: amount.isEmpty ? "0" : amount)
                        HStack { Spacer(); Button("Clear") { amount = "" }.frame(minHeight: 44) }
                        Spacer(minLength: 8)
                        KeypadView { amount = Keypad.apply($0, to: amount) }
                    }.padding(20)
                    .safeAreaInset(edge: .bottom) { PinnedBar { Button("Done") { answers.fields.insert(.amount); answers.amountChecked = true; editor = nil }.buttonStyle(PrimaryButtonStyle()).disabled(!Keypad.isValid(amount)) } }
                case .merchant:
                    MerchantEditor(merchant: $merchant) {
                        if !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { answers.fields.insert(.merchant) }
                        editor = nil
                    }
                case .category:
                    ScrollView { CategoryGrid(names: EntryRules.categoryChoices(for: .expense), selected: category) { category = $0; answers.fields.insert(.category); editor = nil }.padding(20) }
                case .date:
                    DatePicker("Date", selection: Binding(get: { DateText.date(date) }, set: { date = DateText.local($0) }), displayedComponents: .date)
                        .datePickerStyle(.graphical).environment(\.calendar, DateText.utcCalendar).environment(\.timeZone, TimeZone(identifier: "UTC")!)
                        .padding(20)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") {
                            chosenInstant = zone.instant(for: LocalDateTime(date: date, secondOfDay: 12 * 3600), fold: 0)
                            answers.fields.insert(.date); editor = nil
                        } } }
                case .note:
                    TextField("Add note", text: $note, axis: .vertical).font(Theme.body(16)).lineLimit(4...12).padding(20)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editor = nil } } }
                }
            }.frame(maxHeight: .infinity, alignment: .top).background(Theme.background)
            .navigationTitle(field.rawValue.capitalized).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { editor = nil } } }
        }.presentationDetents([.large]).presentationBackground(Theme.background)
    }
    private func load() {
        guard !loaded else { return }
        if let minor = draft.amountMinor { setAmount(minor) }
        // Ambiguous candidates intentionally have no selected value.
        if state == .ambiguousAmount { amount = "" }
        merchant = draft.merchant ?? ""; category = draft.categoryName ?? "Other"
        date = zone.local(Instant(iso: draft.occurredAt) ?? captured).time.date
        reported = draft.feedbackIssue?.explicitlyReportedIssue ?? false
        feedbackNote = draft.feedbackIssue?.userFeedbackNote ?? ""
        loaded = true; merchantFocused = state == .merchantMissing; onStateChange(state)
    }
    private func setAmount(_ value: Int) { amount = model.money.digits(value).replacingOccurrences(of: ",", with: "") }
    private func report() {
        if model.setCaptureFeedbackIssue(draft.id, .init(explicitlyReportedIssue: true, userFeedbackNote: feedbackNote), quiet: true) {
            reported = true; PaceHaptics.undo()
        } else { error = model.errorMessage }
    }
    private func persistReport() -> Bool {
        guard feedbackNote.count <= 1_000 else { error = "Keep the note to 1,000 characters."; return false }
        guard draft.feedbackIssue != nil else { return true }
        if model.setCaptureFeedbackIssue(draft.id, .init(explicitlyReportedIssue: reported, userFeedbackNote: feedbackNote), quiet: true) { return true }
        error = model.errorMessage; return false
    }
    private func confirm() {
        guard valid, persistReport() else { return }
        if model.confirmCapture(draft.id, amount: amountMinor, merchant: merchant, categoryID: categoryID,
            remember: remember, occurredAt: chosenInstant, note: note.isEmpty ? nil : .some(note)) { onConfirmed() }
        else { error = model.errorMessage }
    }
    private func discard() {
        if persistReport(), model.discardCapture(draft.id) { onConfirmed() }
        else { error = model.errorMessage }
    }
}
