import PaceCore
import PaceStore
import SwiftUI

struct EntrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let openedAt: Date

    @State private var path: [Stage] = []
    @State private var amount = ""
    @State private var type = TransactionType.expense
    @State private var category = "Other"
    @State private var categoryChosen = false
    @State private var note = ""
    @State private var date: LocalDate?
    @State private var linkSalary = false
    @State private var saved: Executed?
    @State private var saving = false
    @State private var discard = false
    @State private var requestID = UUID().uuidString.lowercased()

    enum Stage: Hashable { case details, note, result }
    private var amountMinor: Int { Keypad.amountMinor(amount) }
    private var dirty: Bool { !amount.isEmpty || !note.isEmpty || date != nil || type != .expense }

    var body: some View {
        NavigationStack(path: $path) {
            amountStage
                .navigationDestination(for: Stage.self) { stage in
                    switch stage {
                    case .details: detailsStage
                    case .note: noteStage
                    case .result: resultStage
                    }
                }
        }
        .tint(Theme.accent)
        .background(Theme.card)
        .interactiveDismissDisabled(dirty && saved == nil)
        .confirmationDialog("Discard this transaction?", isPresented: $discard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .sensoryFeedback(.success, trigger: saved?.actionID)
    }

    private var amountStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            TypePicker(type: $type)
                .padding(.top, 16)
            Text(helperText).font(Theme.body(13)).foregroundStyle(Theme.ink2)
                .frame(height: 36, alignment: .topLeading)
            Spacer(minLength: 8)
            MoneyText(minor: amountMinor, size: 52, color: amount.isEmpty ? Theme.ink3 : Theme.ink,
                      rawDigits: amount.isEmpty ? "0" : amount)
                .accessibilityIdentifier("entry-amount")
            HStack {
                Spacer()
                Button("Clear") { amount = "" }
                    .disabled(amount.isEmpty)
                    .frame(minHeight: 44)
                    .font(Theme.body(14, .medium))
            }
            Spacer(minLength: 8)
            KeypadView { key in amount = Keypad.apply(key, to: amount) }
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
        .safeAreaInset(edge: .bottom) {
            Button("Continue") {
                linkSalary = type == .income && model.openSalaryOccurrence() != nil
                path.append(.details)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 50)
            .disabled(!Keypad.isValid(amount))
            .accessibilityIdentifier("entry-next")
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .navigationTitle("Add transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { closeButton } }
    }

    private var helperText: String {
        switch type {
        case .expense: ""
        case .income: "Extra income on top of monthly salary."
        case .refund: "Money returned from a purchase."
        case .contribution: "Money deliberately put aside."
        }
    }

    private var detailsStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button { path.removeLast() } label: {
                    HStack {
                        Text(type.label).font(Theme.body(15, .semibold))
                        Spacer()
                        MoneyText(minor: amountMinor, size: 24)
                        Image(systemName: "chevron.right").font(.footnote)
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Theme.hair.frame(height: 1) }
                }
                .buttonStyle(.plain)
                if type == .expense || type == .refund {
                    Text("Category").font(Theme.body(13, .semibold)).foregroundStyle(Theme.ink2)
                    CategoryGrid(names: EntryRules.categoryChoices(for: type), selected: category) { name in
                        category = name
                        categoryChosen = true
                    }
                } else if type == .income {
                    Text("Category · Income").font(Theme.body(15)).foregroundStyle(Theme.ink2)
                    if let occurrence = model.openSalaryOccurrence() {
                        Toggle(isOn: $linkSalary) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("This is my salary")
                                Text("Counts as the \(DateText.short(occurrence.date)) salary (\(model.money.string(occurrence.amountMinor)) expected)")
                                    .font(Theme.body(13)).foregroundStyle(Theme.ink2)
                            }
                        }
                        .accessibilityIdentifier("entry-salary-toggle")
                    }
                } else {
                    Text("Money put aside for savings, investing or a financial goal.")
                        .font(Theme.body(15)).foregroundStyle(Theme.ink2)
                }
                HStack(alignment: .top, spacing: 16) {
                    DateChip(date: Binding(get: { date ?? model.today }, set: { date = $0 }), today: model.today)
                    Button { path.append(.note) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Note").font(Theme.body(13, .medium)).foregroundStyle(Theme.ink2)
                            Text(note.isEmpty ? "Optional" : note)
                                .font(Theme.body(15, .medium)).foregroundStyle(Theme.ink)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .overlay(alignment: .bottom) { Theme.hair.frame(height: 1) }
                    }
                    .buttonStyle(.plain)
                }
                if let error = model.errorMessage {
                    Text(error).font(Theme.body(14)).foregroundStyle(Theme.warn)
                        .padding(12).background(Theme.warnWell)
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button("Save · \(model.money.string(amountMinor))") { save() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
                .disabled(saving)
                .frame(maxWidth: .infinity, minHeight: 50)
                .accessibilityIdentifier("entry-save")
                .padding(.horizontal, 20).padding(.bottom, 8)
        }
        .navigationTitle("Add transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { closeButton } }
        .onChange(of: note) {
            guard !categoryChosen else { return }
            let merchant = EntryRules.noteFields(note).merchant
            category = model.resolveMerchant(merchant).flatMap { model.categoryName($0.categoryID) } ?? "Other"
        }
    }

    private var noteStage: some View {
        NoteEditor(note: $note) { path.removeLast() }
    }

    private var resultStage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Saved", systemImage: "checkmark")
                .font(Theme.body(20, .semibold)).foregroundStyle(Theme.positive)
            MoneyText(minor: saved?.transaction.amountMinor ?? amountMinor, size: 40)
            Text("\(type.label) · \(saved?.transaction.categoryName ?? "Set aside") · \(DateText.short(saved?.transaction.localDate ?? model.today))")
                .font(Theme.body(15)).foregroundStyle(Theme.ink2)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .controlSize(.large).frame(maxWidth: .infinity)
            HStack {
                if let transaction = saved?.transaction {
                    Button("Edit") { router.edit(transaction) }
                }
                Spacer()
                if let id = saved?.actionID {
                    Button("Undo") { model.undo(id); dismiss() }
                }
            }
            .font(Theme.body(15, .semibold))
        }
        .padding(20)
        .navigationBarBackButtonHidden()
        .navigationTitle("Add transaction")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled && !voiceOver { dismiss() }
        }
    }

    private var closeButton: some View {
        Button(role: .cancel) {
            if dirty && saved == nil { discard = true } else { dismiss() }
        } label: { Image(systemName: "xmark") }
            .accessibilityLabel("Close")
    }

    private func save() {
        guard !saving, Keypad.isValid(amount) else { return }
        saving = true
        let day = date ?? model.today
        let fields = EntryRules.noteFields(note)
        let merchant = fields.merchant.isEmpty ? nil : fields.merchant
        let match = merchant.flatMap(model.resolveMerchant)
        let occurredAt = day == model.today ? model.now :
            model.zone.instant(for: LocalDateTime(date: day, secondOfDay: 12 * 3600), fold: 0)
        let occurrence = type == .income && linkSalary ? model.openSalaryOccurrence() : nil
        let categoryName = type == .contribution ? nil : type == .income ? "Income" : category
        let draft = TransactionDraft(
            type: type, amountMinor: amountMinor, occurredAt: occurredAt, tzIdentifier: model.zone.identifier,
            localDate: day, merchantID: match?.merchantID, merchantText: match?.displayName ?? merchant,
            categoryID: categoryName.flatMap(model.categoryID),
            note: fields.description.isEmpty ? nil : fields.description, source: .keypad,
            recurringRuleID: occurrence?.ruleID, occurrenceDate: occurrence?.date)
        if let result = model.saveEntry(draft, requestID: requestID) {
            saved = result
            model.recordEntryDuration(Date().timeIntervalSince(openedAt))
            path.append(.result)
        }
        saving = false
    }
}

struct TypePicker: View {
    @Binding var type: TransactionType
    private var primary: Int { type == .expense ? 0 : type == .contribution ? 2 : 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Type", selection: Binding(get: { primary }, set: { type = $0 == 0 ? .expense : $0 == 1 ? .income : .contribution })) {
                Text("Spent").tag(0)
                Text("Earned").tag(1)
                Text("Set aside").tag(2)
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            HStack {
                if type == .income || type == .refund {
                    Button {
                        type = type == .refund ? .income : .refund
                    } label: {
                        Label("Refund", systemImage: type == .refund ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(type == .refund ? .isSelected : [])
                }
                Spacer()
            }
            .frame(height: 44)
        }
    }
}

struct KeypadView: View {
    let onKey: (Keypad.Key) -> Void
    private let rows: [[Keypad.Key]] = [
        [.digit(1), .digit(2), .digit(3)], [.digit(4), .digit(5), .digit(6)],
        [.digit(7), .digit(8), .digit(9)], [.point, .digit(0), .delete]
    ]
    var body: some View {
        Grid(horizontalSpacing: 7, verticalSpacing: 7) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row], id: \.self) { key in
                        Button { onKey(key) } label: {
                            Group {
                                switch key {
                                case let .digit(value): Text(String(value))
                                case .point: Text(".")
                                case .delete: Image(systemName: "delete.left")
                                }
                            }
                            .font(Theme.body(26, .medium, relativeTo: .title2))
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .foregroundStyle(Theme.ink)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PaceRowButtonStyle())
                        .accessibilityLabel(key == .point ? "decimal point" : key == .delete ? "delete" : identifier(key).replacingOccurrences(of: "key-", with: ""))
                        .accessibilityIdentifier(identifier(key))
                    }
                }
            }
        }
    }
    private func identifier(_ key: Keypad.Key) -> String {
        switch key {
        case let .digit(value): "key-\(value)"
        case .point: "key-point"
        case .delete: "key-delete"
        }
    }
}

struct CategoryGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let names: [String]
    let selected: String
    var suggested: String? = nil
    let onSelect: (String) -> Void
    private var count: Int { dynamicType >= .xxLarge ? 2 : 3 }
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: count), spacing: 8) {
            ForEach(names, id: \.self) { name in
                Button { PaceHaptics.selection(); onSelect(name) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: CategorySymbol.name(name)).font(.system(size: 22))
                        Text(name).font(Theme.body(12, .medium, relativeTo: .caption)).multilineTextAlignment(.center)
                        if name == suggested { Text("Suggested").font(Theme.body(11, .medium, relativeTo: .caption2)).foregroundStyle(Theme.ink2) }
                    }
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, minHeight: dynamicType.isAccessibilitySize ? 52 : 70)
                    .background(RoundedRectangle(cornerRadius: 6).fill(name == selected ? Theme.surface2 : Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(name == selected ? Theme.ink : Theme.hair, lineWidth: name == selected ? 1.5 : 0.5))
                }
                .buttonStyle(PaceRowButtonStyle())
                .accessibilityIdentifier("category-\(name)")
                .accessibilityAddTraits(name == selected ? .isSelected : [])
            }
        }
    }
}

struct NoteEditor: View {
    @Binding var note: String
    let done: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Merchant or note", text: $note, axis: .vertical)
            .font(Theme.body(16, .medium))
            .lineLimit(4...12)
            .padding(20)
            .frame(maxHeight: .infinity, alignment: .top)
            .focused($focused)
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
            .onAppear { focused = true }
    }
}

struct DateChip: View {
    @Binding var date: LocalDate
    let today: LocalDate
    var body: some View {
        DatePicker("Date", selection: Binding(get: { DateText.date(date) }, set: { date = DateText.local($0) }),
                   in: ...DateText.date(today.adding(days: 366)), displayedComponents: .date)
            .datePickerStyle(.compact)
            .environment(\.calendar, DateText.utcCalendar)
            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
            .environment(\.locale, Locale(identifier: "en_MY"))
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }
}
