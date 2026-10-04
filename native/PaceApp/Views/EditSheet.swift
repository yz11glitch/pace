import PaceCore
import PaceStore
import SwiftUI

struct EditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let transaction: StoredTransaction
    var openAtCategory = false
    @State private var path: [Field] = []
    @State private var amount = ""
    @State private var type = TransactionType.expense
    @State private var category = "Other"
    @State private var categoryChosen = false
    @State private var merchant = ""
    @State private var note = ""
    @State private var date = LocalDate(iso: "2026-01-01")!
    @State private var loaded = false
    @State private var discard = false
    @State private var confirmDelete = false
    @State private var feedbackIssue: CaptureFeedbackIssue?
    @State private var reporting = false
    @State private var remember = true
    enum Field: Hashable { case amount, category, merchant, note, date }
    private var amountMinor: Int { Keypad.amountMinor(amount) }
    private var valid: Bool { Keypad.isValid(amount) && merchant.count <= 200 && note.count <= 1_000 }
    private var dirty: Bool { changes != TransactionChanges() }
    private var teaching: MerchantTeaching? { MerchantTeaching.edit(current: transaction, changes: changes) }
    private var presented: StoredTransaction {
        var value = transaction
        value.merchantText = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        value.note = note
        value.categoryName = category
        value.type = type
        return value
    }
    private var context: String {
        let instant = changes.occurredAt ?? transaction.occurredAt
        return DateText.context(instant, source: transaction.captureSource,
            zone: Zone(identifier: transaction.tzIdentifier) ?? model.zone, today: model.today)
            + (feedbackIssue?.explicitlyReportedIssue == true ? " · Problem reported" : "")
    }

    var body: some View {
        NavigationStack(path: $path) {
            summary.navigationDestination(for: Field.self) { field in
                switch field {
                case .amount: amountEditor
                case .category: categoryEditor
                case .merchant: MerchantEditor(merchant: $merchant) { path.removeLast() }
                case .note: noteEditor
                case .date: dateEditor
                }
            }
        }
        .tint(Theme.ink).background(Theme.background)
        .interactiveDismissDisabled(dirty)
        .background(SheetDismissGuard(blocked: dirty) { discard = true })
        .alert("Discard changes?", isPresented: $discard) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .confirmationDialog("Delete this transaction?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.delete(transaction.id); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $reporting) {
            if let feedbackIssue {
                CaptureProblemSheet(transactionID: transaction.id, issue: feedbackIssue) { self.feedbackIssue = $0 }
            }
        }
        .overlay(alignment: .top) {
            if !reporting { ToastView().padding(.top, 44) }
        }
        .onAppear(perform: load)
    }

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TransactionHeader(title: presented.title, fallback: !presented.hasMerchant, context: context) {
                    Button { path.append(.amount) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            if type == .refund { Text("Refund").font(Theme.body(13)).foregroundStyle(Theme.positive) }
                            MoneyText(minor: amountMinor, size: 34, sign: type == .expense ? "−" : type == .contribution ? "↑" : "+", color: Theme.tint(for: type))
                        }
                    }.buttonStyle(PaceRowButtonStyle()).accessibilityIdentifier("edit-amount-row")
                }.padding(.bottom, 24)
                Theme.hair.frame(height: 1)
                if type == .expense || type == .refund {
                    FieldRow(label: "Category", value: category) { path.append(.category) }
                }
                FieldRow(label: "Merchant", value: merchant.isEmpty ? "Add merchant" : merchant, placeholder: merchant.isEmpty) { path.append(.merchant) }
                FieldRow(label: "Date", value: DateText.long(date)) { path.append(.date) }
                FieldRow(label: "Note", value: note.isEmpty ? "Add note" : note, placeholder: note.isEmpty) { path.append(.note) }
                Button("Delete transaction", role: .destructive) { confirmDelete = true }
                    .font(Theme.body(15)).foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading).padding(.top, 28)
                if let error = model.errorMessage { Text(error).font(Theme.body(13)).foregroundStyle(Theme.warn) }
            }.padding(20)
        }
        .background(Theme.background)
        .navigationTitle("Edit transaction").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { if dirty { discard = true } else { dismiss() } } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if feedbackIssue != nil {
                        Button(feedbackIssue?.explicitlyReportedIssue == true ? "Edit problem report" : "Report a capture problem", systemImage: "flag") { reporting = true }
                    }
                    Button("Delete transaction", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("More actions").accessibilityIdentifier("edit-more")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if dirty {
                PinnedBar {
                    if let teaching { MemoryCheckbox(remember: $remember, consequence: teaching.consequence(categoryName: category)) }
                    Button("Save changes") {
                        if model.update(transaction.id, changes, remember: remember) { dismiss() }
                    }.buttonStyle(PrimaryButtonStyle()).disabled(!valid).accessibilityIdentifier("edit-save")
                }
            }
        }
    }

    private var amountEditor: some View {
        VStack(alignment: .leading) {
            TypePicker(type: $type)
            Spacer(minLength: 8)
            MoneyText(minor: amountMinor, size: 52, rawDigits: amount.isEmpty ? "0" : amount)
            HStack { Spacer(); Button("Clear") { amount = "" }.disabled(amount.isEmpty).frame(minHeight: 44) }
            Spacer(minLength: 8)
            KeypadView { amount = Keypad.apply($0, to: amount) }
        }.padding(20).background(Theme.background)
        .navigationTitle("Amount & type").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { PinnedBar { Button("Done") { path.removeLast() }.buttonStyle(PrimaryButtonStyle()).disabled(!Keypad.isValid(amount)) } }
    }
    private var categoryEditor: some View {
        ScrollView {
            CategoryGrid(names: EntryRules.categoryChoices(for: type), selected: category) {
                category = $0; categoryChosen = true; path.removeLast()
            }.padding(20)
        }.background(Theme.background).navigationTitle("Category").navigationBarTitleDisplayMode(.inline)
    }
    private var noteEditor: some View {
        TextField("Add note", text: $note, axis: .vertical).font(Theme.body(16)).lineLimit(4...12)
            .padding(20).frame(maxHeight: .infinity, alignment: .top).background(Theme.background)
            .navigationTitle("Note").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { path.removeLast() } } }
    }
    private var dateEditor: some View {
        DatePicker("Date", selection: Binding(get: { DateText.date(date) }, set: { date = DateText.local($0) }), displayedComponents: .date)
            .datePickerStyle(.graphical).environment(\.calendar, DateText.utcCalendar)
            .environment(\.timeZone, TimeZone(identifier: "UTC")!).environment(\.locale, Locale(identifier: "en_MY"))
            .padding(20).frame(maxHeight: .infinity, alignment: .top).background(Theme.background)
            .navigationTitle("Date").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { path.removeLast() } } }
    }
    private func load() {
        guard !loaded else { return }
        amount = model.money.digits(transaction.amountMinor).replacingOccurrences(of: ",", with: "")
        type = transaction.type; category = transaction.categoryName ?? "Other"
        merchant = transaction.merchantText ?? ""; note = transaction.note ?? ""; date = transaction.localDate
        feedbackIssue = try? CaptureFeedbackIssueStore.state(model.database, transactionID: transaction.id)
        loaded = true
        if openAtCategory { path = [.category] }
    }

    private var changes: TransactionChanges {
        var result = TransactionChanges()
        if amountMinor != transaction.amountMinor { result.amountMinor = amountMinor }
        if type != transaction.type { result.type = type }
        let nextCategory = EntryRules.category(for: type, selected: category, remembered: transaction.categoryName)
        if nextCategory != transaction.categoryName || (transaction.categoryPending && categoryChosen) {
            result.categoryID = .some(nextCategory.flatMap(model.categoryID))
        }
        let trimmedMerchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMerchant != (transaction.merchantText ?? "") { result.merchantText = .some(trimmedMerchant.isEmpty ? nil : trimmedMerchant) }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNote != (transaction.note ?? "") { result.note = .some(trimmedNote.isEmpty ? nil : trimmedNote) }
        if date != transaction.localDate {
            result.localDate = date
            result.occurredAt = Zone(identifier: transaction.tzIdentifier)?.instant(
                for: LocalDateTime(date: date, secondOfDay: 12 * 3600), fold: 0)
        }
        return result
    }
}
