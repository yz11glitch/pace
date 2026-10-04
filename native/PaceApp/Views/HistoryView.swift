import PaceCore
import PaceStore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var search = ""
    @State private var searchIsVisible = false
    @State private var offset = 0
    @State private var filter = FlowFilter.all
    @State private var calendarMode = false
    @State private var selectedDay: LocalDate?
    @State private var days: [(LocalDate, [StoredTransaction])] = []
    @State private var searchGroups: [(Cycle, [StoredTransaction])] = []
    @State private var expandedCycles: Set<String> = []
    @State private var spendingDays: Set<LocalDate> = []
    @State private var visible: [StoredTransaction] = []

    enum FlowFilter: String, CaseIterable, Identifiable {
        case all = "All", spent = "Spent", earned = "Earned", setAside = "Set aside"
        var id: Self { self }
        func includes(_ type: TransactionType) -> Bool {
            switch self {
            case .all: true
            case .spent: type == .expense || type == .refund
            case .earned: type == .income
            case .setAside: type == .contribution
            }
        }
    }
    private var searching: Bool { searchIsVisible || !search.isEmpty }
    private var period: Cycle? { cycle(at: offset, calendar: calendarMode) }
    private var displayedDay: LocalDate { selectedDay ?? (period?.contains(model.today) == true ? model.today : period?.start ?? model.today) }

    var body: some View {
        Group {
            if searchIsVisible {
                content.searchable(text: $search, isPresented: $searchIsVisible, prompt: "Search all time")
            } else { content }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if !searching { periodControls.dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
            List {
                if searching {
                    searchResults
                } else {
                    Text(total).font(Theme.body(20, .semibold, relativeTo: .title3))
                        .foregroundStyle(filter == .earned ? Theme.positive : Theme.ink)
                        .monospacedDigit().listRowSeparator(.hidden).accessibilityIdentifier("history-total").listRowBackground(Theme.background)
                    if dynamicType.isAccessibilitySize, let period {
                        Text(DateText.range(period)).font(Theme.body(13, relativeTo: .footnote)).foregroundStyle(Theme.ink2).listRowSeparator(.hidden).listRowBackground(Theme.background)
                    }
                    if model.captureAttention.total > 0 { CaptureAttentionRow().listRowSeparator(.hidden).listRowBackground(Theme.background) }
                    if calendarMode, let period { calendar(period).listRowSeparator(.hidden).listRowBackground(Theme.background) }
                    if visible.isEmpty { emptyState }
                    ForEach(days, id: \.0) { day, transactions in
                        Section {
                            ForEach(transactions) { ledgerRow($0) }
                        } header: { dayHeader(day, transactions: transactions) }
                    }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(Theme.background)
            .environment(\.defaultMinListRowHeight, 58)
            .accessibilityIdentifier("history-list")
        }
        .background(Theme.background)
        .navigationTitle("History").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    if searching { search = ""; searchIsVisible = false }
                    else { searchIsVisible = true }
                } label: { Image(systemName: searching ? "xmark" : "magnifyingglass") }
                    .accessibilityLabel(searching ? "Close search" : "Search history").accessibilityIdentifier("history-search-button")
                if !searching {
                    Button { calendarMode.toggle(); offset = 0; selectedDay = nil; applyQuery() }
                        label: { Image(systemName: calendarMode ? "list.bullet" : "calendar") }
                        .accessibilityLabel(calendarMode ? "List view" : "Calendar view")
                }
            }
        }
        .onChange(of: search) { applyQuery() }
        .onChange(of: searchIsVisible) { applyQuery() }
        .onChange(of: offset) { selectedDay = nil; applyQuery() }
        .onChange(of: filter) { regroup() }
        .onChange(of: selectedDay) { regroup() }
        .onChange(of: model.history) { regroup() }
        .onAppear { applyQuery() }
    }
    private func cycle(at step: Int, calendar: Bool = false) -> Cycle? {
        guard let home = model.home else { return nil }
        let anchor = calendar ? 1 : home.profile?.paydayAnchor ?? 1
        var result = calendar ? Cycle.containing(home.today, anchorDay: 1) : home.cycle
        if step < 0 {
            for _ in 0..<(-step) { result = Cycle.containing(result.start.adding(days: -1), anchorDay: anchor) }
        }
        return result
    }
    private func periodLabel(_ cycle: Cycle, step: Int? = nil) -> String {
        let prefix = cycle == model.home?.cycle ? "This cycle" : step == -1 ? "Last cycle" : ""
        return [prefix, DateText.range(cycle)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var periodControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                Button { offset -= 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("Previous cycle")
                Spacer(minLength: 0)
                Menu {
                    ForEach(0..<12) { index in
                        if let cycle = cycle(at: -index, calendar: calendarMode) {
                            Button(periodLabel(cycle, step: -index)) { offset = -index }
                        }
                    }
                } label: {
                    Text(period.map {
                        calendarMode ? "\(DateText.months[$0.start.month - 1]) \($0.start.year)" :
                        dynamicType.isAccessibilitySize && offset >= -1 ? (offset == 0 ? "This cycle" : "Last cycle") : periodLabel($0, step: offset)
                    } ?? "")
                    .font(Theme.body(15, .semibold)).lineLimit(1).accessibilityIdentifier("history-period")
                }
                Spacer(minLength: 0)
                Button { offset += 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled(offset >= 0).accessibilityLabel("Next cycle")
            }
            if dynamicType.isAccessibilitySize {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    ForEach(FlowFilter.allCases) { value in
                        Button(value.rawValue) { filter = value }
                            .font(Theme.body(15, .medium)).frame(maxWidth: .infinity, minHeight: 44)
                            .background(filter == value ? Theme.surface2 : .clear)
                            .accessibilityAddTraits(filter == value ? .isSelected : [])
                    }
                }.accessibilityIdentifier("history-filter")
            } else {
                Picker("Flow", selection: $filter) { ForEach(FlowFilter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).accessibilityIdentifier("history-filter")
            }
        }.padding(.horizontal, 16).padding(.bottom, 12).background(Theme.background)
        .overlay(alignment: .bottom) { Theme.hair.frame(height: 1) }
    }
    private var total: String {
        let rows = visible.filter { offset != 0 || calendarMode || $0.localDate <= model.today }.map(\.ledgerRow)
        switch filter {
        case .all: return "\(visible.count) \(visible.count == 1 ? "transaction" : "transactions")"
        case .spent: return "\(model.money.string(Finance.spending(rows))) spent"
        case .earned: return "\(model.money.string(visible.reduce(0) { $0 + $1.amountMinor })) earned"
        case .setAside: return "\(model.money.string(visible.reduce(0) { $0 + $1.amountMinor })) set aside"
        }
    }
    @ViewBuilder private var emptyState: some View {
        let title = offset < 0 ? "Nothing in \(period.map(DateText.range) ?? "this cycle")" :
            filter == .all ? "Nothing yet" : "Nothing \(filter == .earned ? "earned" : filter == .setAside ? "set aside" : "spent") this cycle"
        ContentUnavailableView(title, systemImage: "list.bullet", description: Text("Capture with Back Tap, Apple Pay or +."))
            .listRowSeparator(.hidden).listRowBackground(Theme.background)
        if offset < 0 { Button("Go to this cycle") { offset = 0 }.listRowSeparator(.hidden) }
    }
    private func ledgerRow(_ transaction: StoredTransaction, searchResult: Bool = false) -> some View {
        Button { router.edit(transaction) } label: { TransactionRow(transaction: transaction, showDate: searchResult) }
            .buttonStyle(PaceRowButtonStyle()).listRowBackground(Theme.background)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { model.delete(transaction.id) } label: { Label("Delete", systemImage: "trash") }
            }
            .contextMenu {
                Button("Edit", systemImage: "pencil") { router.edit(transaction) }
                Button("Delete", systemImage: "trash", role: .destructive) { model.delete(transaction.id) }
            }
            .accessibilityAction(named: "Edit") { router.edit(transaction) }
            .accessibilityAction(named: "Delete") { model.delete(transaction.id) }
    }
    private func dayHeader(_ day: LocalDate, transactions: [StoredTransaction]) -> some View {
        let label = day == model.today ? "Today" : day == model.today.adding(days: -1) ? "Yesterday" : DateText.day(day)
        let figure = dayFigure(transactions)
        return Group {
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) { Text(label); if !figure.isEmpty { Text(figure) } }
            } else {
                HStack { Text(label); Spacer(); if !figure.isEmpty { Text(figure).monospacedDigit() } }
            }
        }.font(Theme.body(13, .semibold, relativeTo: .footnote)).foregroundStyle(Theme.ink2)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            .background(Theme.background).textCase(nil).accessibilityAddTraits(.isHeader)
    }
    private func dayFigure(_ transactions: [StoredTransaction]) -> String {
        let value = filter == .all || filter == .spent ? Finance.spending(transactions.map(\.ledgerRow)) : transactions.reduce(0) { $0 + $1.amountMinor }
        guard value != 0 else { return "" }
        switch filter {
        case .all, .spent: return value > 0 ? "− \(model.money.string(value))" : "+ \(model.money.string(-value)) refunded"
        case .earned: return "+ \(model.money.string(value))"
        case .setAside: return "↑ \(model.money.string(value))"
        }
    }
    @ViewBuilder private var searchResults: some View {
        if searchGroups.isEmpty {
            ContentUnavailableView(search.isEmpty ? "Search all time" : "No matches for “\(search)”", systemImage: "magnifyingglass",
                description: Text("Searched all time: merchant, note, category and amount."))
                .listRowBackground(Theme.background).listRowSeparator(.hidden)
            if !search.isEmpty { Button("Clear search") { search = "" }.listRowSeparator(.hidden) }
        }
        ForEach(searchGroups, id: \.0.start) { cycle, transactions in
            Section {
                ForEach(expandedCycles.contains(cycle.start.iso) ? transactions : Array(transactions.prefix(5))) { ledgerRow($0, searchResult: true) }
                if transactions.count > 5 && !expandedCycles.contains(cycle.start.iso) {
                    Button("Show all \(transactions.count)") { expandedCycles.insert(cycle.start.iso) }.listRowBackground(Theme.background)
                }
            } header: {
                Text("\(cycle == model.home?.cycle ? "This cycle" : DateText.range(cycle)) · \(transactions.count) \(transactions.count == 1 ? "result" : "results")")
                    .font(Theme.body(13, .semibold)).foregroundStyle(Theme.ink2).textCase(nil)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).background(Theme.background)
            }
        }
    }
    private func applyQuery() {
        guard let period else { return }
        model.historyQuery = searching ? HistoryQuery(text: search) : HistoryQuery(start: period.start, end: period.end)
        model.refresh(); regroup()
    }
    private func regroup() {
        visible = model.history.filter { filter.includes($0.type) && (!calendarMode || $0.localDate == displayedDay) }
        days = Dictionary(grouping: visible, by: \.localDate).sorted { $0.key > $1.key }
        spendingDays = Set(model.history.filter { $0.type == .expense || $0.type == .refund }.map(\.localDate))
        let anchor = model.home?.profile?.paydayAnchor ?? 1
        let groups = Dictionary(grouping: model.history) { Cycle.containing($0.localDate, anchorDay: anchor).start }
        searchGroups = groups.sorted { $0.key > $1.key }.map { (Cycle.containing($0.key, anchorDay: anchor), $0.value) }
    }
    private func calendar(_ month: Cycle) -> some View {
        let weekStart = FinancialLocale.malaysia.weekStart
        let cells = CalendarGrid.days(year: month.start.year, month: month.start.month, weekStart: weekStart)
        return VStack(spacing: 4) {
            HStack { ForEach(0..<7) { Text(DateText.weekdays[($0 + weekStart) % 7]).font(Theme.body(11, .medium)).frame(maxWidth: .infinity) } }
            ForEach(0..<(cells.count / 7), id: \.self) { week in
                HStack(spacing: 2) {
                    ForEach(0..<7) { column in
                        if let date = cells[week * 7 + column] {
                            Button { selectedDay = date } label: {
                                VStack(spacing: 4) {
                                    Text(String(date.day)).font(Theme.body(14, .medium))
                                    Circle().fill(spendingDays.contains(date) ? Theme.ink2 : .clear).frame(width: 4, height: 4)
                                }.frame(maxWidth: .infinity, minHeight: 44)
                                    .background(date == displayedDay ? Theme.surface2 : .clear)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(date == model.today ? Theme.ink : .clear))
                            }.buttonStyle(PaceRowButtonStyle()).accessibilityLabel("\(DateText.long(date))\(spendingDays.contains(date) ? ", has spending" : "")")
                        } else { Color.clear.frame(maxWidth: .infinity, minHeight: 44) }
                    }
                }
            }
        }.foregroundStyle(Theme.ink2)
    }
}
