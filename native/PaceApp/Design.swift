import PaceCore
import PaceStore
import SwiftUI
import UIKit

/// Pace's content money, kept separate from the system font used for chrome.
struct MoneyText: View {
    let minor: Int
    var size: CGFloat = 52
    var sign: String = ""
    var color: Color = Theme.ink
    var rawDigits: String? = nil

    private let money = MoneyFormat()

    var body: some View {
        let digits = rawDigits ?? money.digits(abs(minor))
        ViewThatFits(in: .horizontal) {
            amount(digits, size: size)
            amount(digits, size: min(size, 44))
            amount(digits, size: min(size, 36))
            amount(digits, size: min(size, 28))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(sign)RM").font(.custom(Theme.bodyFont, fixedSize: 16).weight(.semibold)).foregroundStyle(Theme.ink2)
                Text(digits).font(.custom(Theme.displayFont, fixedSize: 28)).monospacedDigit().foregroundStyle(color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(sign == "−" ? "minus " : sign == "+" ? "plus " : sign == "↑" ? "set aside " : "")\(money.spoken(abs(minor)))")
    }

    private func amount(_ digits: String, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(sign)RM")
                .font(.custom(Theme.bodyFont, fixedSize: max(14, size * 0.35)).weight(.semibold))
                .foregroundStyle(Theme.ink2)
            Text(digits)
                .font(.custom(Theme.displayFont, fixedSize: size))
                .monospacedDigit()
                .foregroundStyle(color)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

enum CategorySymbol {
    static func name(_ category: String?) -> String {
        switch category {
        case "Food & Drink": "fork.knife"
        case "Groceries": "basket"
        case "Transport": "bus"
        case "Shopping": "bag"
        case "Bills & Utilities": "doc.text"
        case "Health": "cross.case"
        case "Entertainment": "ticket"
        case "Education": "book"
        case "Services": "wrench.and.screwdriver"
        case "Travel": "suitcase"
        case "Gifts & Donations": "gift"
        case "Income": "arrow.down.to.line"
        case "Set aside": "arrow.up.to.line"
        default: "ellipsis"
        }
    }
}

/// Immediate native-style press response, without moving ledger content.
struct PaceRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Theme.surface2.opacity(0.7) : Color.clear)
    }
}

struct FieldRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let label: String
    let value: String
    var placeholder = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if dynamicType.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(label).foregroundStyle(Theme.ink2)
                        Text(value).foregroundStyle(placeholder ? Theme.ink3 : Theme.ink).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                } else {
                    Text(label).foregroundStyle(Theme.ink2).fixedSize()
                    Spacer(minLength: 12)
                    Text(value).foregroundStyle(placeholder ? Theme.ink3 : Theme.ink)
                        .multilineTextAlignment(.trailing).lineLimit(2)
                }
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.ink3)
            }
            .font(Theme.body(15, .medium))
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Theme.hair.frame(height: 1) }
        }
        .buttonStyle(PaceRowButtonStyle())
    }
}

struct TransactionHeader<Amount: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let title: String
    var fallback = false
    let context: String
    @ViewBuilder let amount: () -> Amount
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.body(20, .semibold, relativeTo: .title3))
                .foregroundStyle(fallback ? Theme.ink2 : Theme.ink)
                .lineLimit(dynamicType.isAccessibilitySize ? 4 : 3)
                .fixedSize(horizontal: false, vertical: true)
            amount()
            Text(context).font(Theme.body(13, .medium, relativeTo: .footnote))
                .foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PinnedBar<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Theme.background)
            .overlay(alignment: .top) { Theme.hair.frame(height: 1) }
    }
}

/// SwiftUI blocks a dirty sheet's dismissal; UIKit supplies the attempted-swipe
/// callback so Close and swipe-down offer the same native discard decision.
struct SheetDismissGuard: UIViewControllerRepresentable {
    let blocked: Bool
    let onAttempt: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> Observer {
        let observer = Observer()
        observer.appeared = { [weak coordinator = context.coordinator, weak observer] in
            if let observer { coordinator?.attach(to: observer) }
        }
        return observer
    }
    func updateUIViewController(_ controller: Observer, context: Context) {
        context.coordinator.blocked = blocked
        context.coordinator.onAttempt = onAttempt
        DispatchQueue.main.async { [weak controller, weak coordinator = context.coordinator] in
            if let controller { coordinator?.attach(to: controller) }
        }
    }
    static func dismantleUIViewController(_ controller: Observer, coordinator: Coordinator) { coordinator.detach() }
    final class Observer: UIViewController {
        var appeared: (() -> Void)?
        override func viewDidLoad() { super.viewDidLoad(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); appeared?() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); appeared?() }
    }
    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var blocked = false
        var onAttempt: (() -> Void)?
        private weak var presentation: UIPresentationController?
        private var previous: (any UIAdaptivePresentationControllerDelegate)?
        func attach(to observer: UIViewController) {
            guard blocked else { detach(); return }
            // NavigationStack can put the observer in a child hosting controller.
            // Find the presented controller that actually contains its view;
            // a nested report sheet must not inherit Edit's dirty guard.
            var controller = observer.view.window?.rootViewController
            var owner: UIViewController?
            while let current = controller {
                if current.presentingViewController != nil, observer.view.isDescendant(of: current.view) { owner = current }
                controller = current.presentedViewController
            }
            if let presentation = owner?.presentationController, presentation.delegate !== self {
                self.presentation = presentation
                previous = presentation.delegate
                presentation.delegate = self
            }
        }
        func detach() {
            if presentation?.delegate === self { presentation?.delegate = previous }
            presentation = nil; previous = nil
        }
        func presentationControllerShouldDismiss(_ controller: UIPresentationController) -> Bool { !blocked }
        func presentationControllerDidAttemptToDismiss(_ controller: UIPresentationController) { if blocked { onAttempt?() } }
        func presentationControllerWillDismiss(_ controller: UIPresentationController) { previous?.presentationControllerWillDismiss?(controller) }
        func presentationControllerDidDismiss(_ controller: UIPresentationController) { previous?.presentationControllerDidDismiss?(controller) }
    }
}

struct MemoryCheckbox: View {
    @Binding var remember: Bool
    let consequence: String
    var body: some View {
        Button { remember.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: remember ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21)).accessibilityHidden(true)
                Text(consequence).font(Theme.body(13, .medium, relativeTo: .footnote))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(PaceRowButtonStyle())
        .accessibilityLabel(consequence).accessibilityValue(remember ? "On" : "Off")
        .accessibilityIdentifier("remember-consequence")
        .sensoryFeedback(.selection, trigger: remember)
    }
}

struct QuestionBlock: View {
    let question: String
    let evidence: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(question, systemImage: "circle.dashed")
                .font(Theme.body(17, .semibold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let evidence {
                Text(evidence).font(Theme.body(13, .medium, relativeTo: .footnote)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.body(15, .semibold))
            .foregroundStyle(enabled ? Theme.onAccent : Theme.ink3)
            .padding(.horizontal, 14).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 12).fill(enabled ? Theme.accent : Theme.surface2))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension DateText {
    static func context(_ instant: Instant, source: CaptureSource?, zone: Zone, today: LocalDate) -> String {
        let local = zone.local(instant).time.date
        let day = local == today ? "Today" : local == today.adding(days: -1) ? "Yesterday" : DateText.day(local)
        guard let source else { return "Added manually · \(day)" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_MY")
        formatter.timeZone = TimeZone(identifier: zone.identifier)
        formatter.timeStyle = .short
        return "Captured with \(source.label) · \(day), \(formatter.string(from: instant.date))"
    }
}
