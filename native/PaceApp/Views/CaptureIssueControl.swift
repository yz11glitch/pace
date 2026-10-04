import PaceStore
import SwiftUI
import UIKit

struct CaptureReportNote: View {
    @Binding var note: String
    var prompt = "What went wrong? (optional)"
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(prompt, text: $note, axis: .vertical)
                .font(Theme.body(15)).lineLimit(1...6)
                .accessibilityIdentifier("capture-issue-note")
            Theme.hair.frame(height: 1)
            if note.count >= 900 {
                Text("\(note.count.formatted()) / 1,000")
                    .font(Theme.body(12)).foregroundStyle(note.count > 1_000 ? Theme.warn : Theme.ink2)
                    .accessibilityIdentifier("capture-note-count")
            }
        }
    }
}

struct CaptureProblemSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let transactionID: String
    let issue: CaptureFeedbackIssue
    let onSaved: (CaptureFeedbackIssue) -> Void
    @State private var note = ""
    @State private var error: String?
    @State private var detent = PresentationDetent.medium
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Pace keeps your note with this capture's details on this iPhone, to help improve capture. Any corrections you make are recorded too.")
                        .font(Theme.body(15)).foregroundStyle(Theme.ink2)
                    CaptureReportNote(note: $note, prompt: "What was wrong? (optional)").focused($focused)
                    if let error { Text(error).foregroundStyle(Theme.warn) }
                    if issue.explicitlyReportedIssue {
                        Button("Remove report", role: .destructive) { save(.init(explicitlyReportedIssue: false)) }
                            .frame(minHeight: 44)
                    }
                }.padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Report a capture problem").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                PinnedBar {
                    Button(issue.explicitlyReportedIssue ? "Save report" : "Report problem") {
                        save(.init(explicitlyReportedIssue: true, userFeedbackNote: note))
                    }
                    .buttonStyle(PrimaryButtonStyle()).disabled(note.count > 1_000)
                    .accessibilityIdentifier("save-capture-report")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackground(Theme.background)
        .onAppear { note = issue.userFeedbackNote ?? "" }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in detent = .large }
    }
    private func save(_ value: CaptureFeedbackIssue) {
        if model.setCaptureFeedbackIssue(transactionID, value) { onSaved(value); dismiss() }
        else { error = model.errorMessage }
    }
}

struct MerchantEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var merchant: String
    let done: () -> Void
    @FocusState private var focused: Bool
    private var suggestions: [String] {
        (try? model.database.writer.read { try Queries.merchantSuggestions($0, text: merchant) }) ?? []
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Merchant", text: $merchant)
                    .font(Theme.body(17, .medium)).focused($focused).submitLabel(.done).onSubmit(done)
                    .frame(minHeight: 44).accessibilityIdentifier("merchant-editor")
                ForEach(suggestions, id: \.self) { name in
                    Button { merchant = name; done() } label: {
                        Text(name).font(Theme.body(15)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(PaceRowButtonStyle())
                }
            }.padding(20)
        }
        .background(Theme.background)
        .navigationTitle("Merchant").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
        .onAppear { focused = true }
    }
}
