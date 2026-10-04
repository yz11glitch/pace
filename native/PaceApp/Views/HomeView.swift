import PaceCore
import PaceStore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let home = model.home {
                    header(home).padding(.bottom, 8)
                    if let plan = home.plan {
                        spending(plan, anchor: home.profile?.paydayAnchor ?? 1)
                        savings(plan)
                    } else {
                        openSpending(home)
                        setup
                    }
                    if model.captureAttention.total > 0 {
                        CaptureAttentionRow().padding(.top, 28)
                    }
                    recent.padding(.top, 32)
                } else if let error = model.errorMessage {
                    Text("Pace couldn't read your data").font(Theme.body(15, .semibold))
                    Text(error).font(Theme.body(13)).foregroundStyle(Theme.ink2)
                    Button("Retry") { model.refresh() }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .contentMargins(.horizontal, dynamicType.isAccessibilitySize ? 16 : 20, for: .scrollContent)
        .clipped()
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ home: HomeSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text("Spent this cycle")
                Spacer(minLength: 8)
                Text(DateText.range(home.cycle))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Spent this cycle")
                Text(DateText.range(home.cycle))
            }
        }.font(Theme.body(13, .semibold, relativeTo: .footnote)).foregroundStyle(Theme.ink2)
            .accessibilityIdentifier("home-cycle")
    }

    private func spending(_ plan: CyclePlan, anchor: Int) -> some View {
        let envelope = plan.discretionaryEnvelopeMinor
        let spent = plan.actual.spending
        let remainingDays = "\(plan.daysLeftIncludingToday) \(plan.daysLeftIncludingToday == 1 ? "day" : "days") remaining"
        return VStack(alignment: .leading, spacing: 0) {
            MoneyText(minor: abs(spent), size: dynamicType.isAccessibilitySize ? 60 : 52, sign: spent < 0 ? "−" : "")
                .accessibilityIdentifier("home-spent")
            if spent < 0 {
                Text("Refunds exceed spending this cycle").font(Theme.body(14)).foregroundStyle(Theme.ink2).padding(.top, 4)
            }
            if envelope > 0 {
                PaceRuler(fill: Double(spent) / Double(envelope),
                          marker: Double(plan.daysElapsed) / Double(plan.cycle.days))
                    .padding(.top, 20)
                    .accessibilityLabel("Spending ruler")
                    .accessibilityValue("\(model.money.spoken(spent)) of \(model.money.spoken(envelope)), day \(plan.daysElapsed) of \(plan.cycle.days)")
                Text(plan.leftMinor < 0 ? "\(model.money.string(-plan.leftMinor)) over your \(model.money.string(envelope)) plan" : "\(model.money.string(plan.leftMinor)) left of \(model.money.string(envelope))")
                    .font(Theme.body(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(plan.leftMinor < 0 ? Theme.warn : Theme.ink)
                    .padding(.top, 12)
                    .accessibilityIdentifier("home-left")
                Text(plan.daysLeftIncludingToday == 1 ? "Last day of this cycle" : plan.leftMinor < 0 ? "\(plan.daysLeftIncludingToday) days left in this cycle" : "\(model.money.string(plan.leftPerDayMinor)) a day for \(plan.daysLeftIncludingToday) days")
                    .font(Theme.body(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(Theme.ink2)
                    .padding(.top, 4)
                    .accessibilityIdentifier("home-left-per-day")
            } else {
                Text("No spending budget this cycle · \(remainingDays)")
                    .font(Theme.body(15)).foregroundStyle(Theme.ink2).padding(.top, 16)
            }
            if plan.expectedIncomeMinor > 0 {
                Text("Includes \(model.money.string(plan.expectedIncomeMinor)) salary not received yet")
                    .font(Theme.body(13, .medium, relativeTo: .footnote)).foregroundStyle(Theme.ink2).padding(.top, 4)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func openSpending(_ home: HomeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MoneyText(minor: abs(home.actual.spending), size: dynamicType.isAccessibilitySize ? 60 : 52, sign: home.actual.spending < 0 ? "−" : "")
                .accessibilityIdentifier("home-spent")
            if home.actual.spending < 0 { Text("Refunds exceed spending this cycle").font(Theme.body(14)).foregroundStyle(Theme.ink2) }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Theme.hair).frame(height: 1).padding(.bottom, 16)
            Text("See your monthly plan").font(Theme.body(20, .semibold)).foregroundStyle(Theme.ink)
            Text("Add your payday, salary and a savings target to see your pace.")
                .font(Theme.body(15)).foregroundStyle(Theme.ink2)
            Button("Set up Pace ›") { router.showYou() }
                .font(Theme.body(15, .semibold)).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("setup-button")
        }
        .padding(.top, 24)
    }

    @ViewBuilder private func savings(_ plan: CyclePlan) -> some View {
        if plan.savingsTargetMinor > 0 {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Theme.hair).frame(height: 1).padding(.bottom, 16)
                SavingsLine(plan: plan)
            }.padding(.top, 24)
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent").font(Theme.body(15, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button("See all") { router.showHistory() }
                    .font(Theme.body(13, .semibold)).foregroundStyle(Theme.accent)
            }
            .padding(.bottom, 8)
            if model.recent.isEmpty {
                Text("Nothing yet. Capture with Back Tap, Apple Pay or +.")
                    .font(Theme.body(15)).foregroundStyle(Theme.ink2)
            } else {
                ForEach(Array(model.recent.prefix(3))) { transaction in
                    Button { router.edit(transaction) } label: {
                        TransactionRow(transaction: transaction, showCaptureTime: true)
                    }
                    .buttonStyle(PaceRowButtonStyle())
                    Rectangle().fill(Theme.hair).frame(height: 1).padding(.leading, 36)
                }
            }
        }
    }
}

struct PaceRuler: View {
    let fill: Double
    let marker: Double
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let portion = min(1, max(0, fill))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.hair).frame(height: 3)
                RoundedRectangle(cornerRadius: 1).fill(fill > 1 ? Theme.warn : Theme.brand)
                    .frame(width: width * portion, height: 3)
                Circle().fill(fill > 1 ? Theme.warn : Theme.brand)
                    .frame(width: 7, height: 7)
                    .offset(x: max(0, min(width - 7, width * portion - 3.5)))
                Rectangle().fill(Theme.ink).frame(width: 1.5, height: 12)
                    .offset(x: max(0, min(width - 1.5, width * marker - 0.75)))
            }
        }
        .frame(height: 12)
    }
}

struct SavingsLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicType
    let plan: CyclePlan
    private var saved: Int { plan.actual.contributions }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) { label; status }
            } else {
                HStack(alignment: .firstTextBaseline) { label; Spacer(minLength: 8); status }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) { savedFigure; targetFigure }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 4) { savedFigure; targetFigure }
            }.padding(.top, 6)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.hair)
                    RoundedRectangle(cornerRadius: 1).fill(Theme.ink)
                        .frame(width: geometry.size.width * min(1, max(0, Double(saved) / Double(plan.savingsTargetMinor))))
                }
            }
            .frame(height: 3)
            .padding(.top, 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Set aside \(model.money.spoken(saved)) of \(model.money.spoken(plan.savingsTargetMinor)) this cycle. \(statusText)")
    }
    private var savedFigure: some View {
        Text(model.money.string(saved)).font(Theme.body(20, .semibold, relativeTo: .title3))
            .foregroundStyle(Theme.ink).monospacedDigit().fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("home-set-aside")
    }
    private var targetFigure: some View {
        Text("of \(model.money.string(plan.savingsTargetMinor))").font(Theme.body(15, .medium))
            .foregroundStyle(Theme.ink2).monospacedDigit().fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("home-savings-target")
    }
    private var label: some View {
        Text("Set aside this cycle").font(Theme.body(13, .semibold, relativeTo: .footnote)).foregroundStyle(Theme.ink2)
    }
    private var status: some View {
        HStack(spacing: 2) {
            if saved >= plan.savingsTargetMinor {
                Label("Target reached", systemImage: "checkmark")
                    .foregroundStyle(Theme.positive)
            } else {
                Text(statusText).foregroundStyle(saved == 0 ? Theme.ink2 : Theme.ink)
            }
        }
        .font(Theme.body(13, .semibold, relativeTo: .footnote))
    }
    private var statusText: String {
        saved >= plan.savingsTargetMinor ? "Target reached" :
        saved == 0 ? "Nothing yet" : "\(model.money.string(max(0, plan.remainingToSetAsideMinor))) to go"
    }
}
