import PaceCore
import PaceStore
import PhotosUI
import SwiftUI
import UIKit

#if DEBUG
/// Internal diagnostics for the Wallet probe. Raw strings are local to the device and
/// shown only here; the consumer Capture settings do not expose trust machinery.
struct CaptureLabView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [CaptureLogEntry] = []
    @State private var paths: [CapturePathState] = []
    @State private var ceiling = 50_000
    @State private var pinnedStage: CaptureStage?
    @State private var screenshotStage: CaptureStage?
    @State private var ocrFixtureResult = "not run"
    @State private var selectedScreenshot: PhotosPickerItem?
    @State private var dryRunStatus = "Select a screenshot to inspect it without creating a capture."
    @State private var dryRunFixture: ScreenshotFixture?
    @State private var dryRunResult: ScreenshotFieldResolution?
    @State private var dryRunDecision = "not run"
    @State private var dryRunOCRMS: Int?
    @State private var feedbackSummary: IntentionalCaptureFeedbackExport.Summary?
    @State private var feedbackExportFile: FeedbackExportFile?
    @State private var feedbackExportError: String?
    private var settings: UserDefaults? {
        UserDefaults(suiteName: "group.\(Bundle.main.bundleIdentifier ?? "")")
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Apple Pay test policy") {
                    Picker("Stage override", selection: $pinnedStage) {
                        Text("Managed by Pace").tag(CaptureStage?.none)
                        Text("Observe").tag(CaptureStage?.some(.observe))
                        Text("Assisted").tag(CaptureStage?.some(.assisted))
                        Text("Automatic").tag(CaptureStage?.some(.automatic))
                    }
                    .onChange(of: pinnedStage) { _, value in
                        if let value { settings?.set(value.rawValue, forKey: "pace.capture.applePayStage") }
                        else { settings?.removeObject(forKey: "pace.capture.applePayStage") }
                    }
                    Stepper("Cold-start ceiling · \(MoneyFormat(locale: .malaysia).string(ceiling))",
                            value: $ceiling, in: 0...1_000_000, step: 5_000)
                    .onChange(of: ceiling) { _, value in settings?.set(value, forKey: "pace.capture.testingCeilingMinor") }
                }
                Section("Screenshot test policy") {
                    Picker("Screenshot stage override", selection: $screenshotStage) {
                        Text("Managed by Pace").tag(CaptureStage?.none)
                        Text("Observe · draft only").tag(CaptureStage?.some(.observe))
                        Text("Assisted").tag(CaptureStage?.some(.assisted))
                        Text("Automatic").tag(CaptureStage?.some(.automatic))
                    }
                    .onChange(of: screenshotStage) { _, value in
                        if let value { settings?.set(value.rawValue, forKey: "pace.capture.screenshotStage") }
                        else { settings?.removeObject(forKey: "pace.capture.screenshotStage") }
                    }
                    Text("Pin Observe before testing an old confirmation screen. It preserves a draft without adding a confirmed transaction.")
                        .font(.caption)
                    Text("Intentional Back Tap uses capture time for the ledger. Screenshot dates are diagnostic only.")
                        .font(.caption)
                    Button("Run Vision OCR fixture") {
                        ocrFixtureResult = "running"
                        Task {
                            do {
                                let image = ScreenshotOCRService.fixtureImage()
                                let ocr = try await ScreenshotOCRService.recognize(image)
                                let fixtureAt = Instant(Date())
                                let result = ScreenshotFieldResolver().resolve(ocr.lines,
                                    capturedAt: fixtureAt, timeZone: "Asia/Kuala_Lumpur")
                                let fixtureRequest = ScreenshotIntentionalCapture.request(lines: ocr.lines,
                                    resolution: result, imageHash: ocr.imageHash, capturedAt: fixtureAt,
                                    timeZone: "Asia/Kuala_Lumpur")
                                var fixturePolicy = CaptureTrustPolicy(); fixturePolicy.stage = .assisted
                                let fixtureDecision = CaptureTrustDecision.decide(fixtureRequest,
                                    merchant: CaptureMerchant(name: fixtureRequest.merchant),
                                    history: CaptureHistory(), duplicateMatchID: nil, policy: fixturePolicy)
                                let blankRejected: Bool
                                do { _ = try await ScreenshotOCRService.recognize(Data()); blankRejected = false }
                                catch { blankRejected = true }
                                let malformedRejected: Bool
                                do { _ = try await ScreenshotOCRService.recognize(Data([0, 1, 2, 3])); malformedRejected = false }
                                catch { malformedRejected = true }
                                let amount = result.amount.value.map { MoneyFormat(locale: .malaysia).string($0.minorUnits) } ?? "missing"
                                ocrFixtureResult = [
                                    "\(ocr.lines.count) lines",
                                    "amount \(result.amount.kind.rawValue): \(amount) [\(result.amount.rule)] \(candidateDisplay(result.amount.candidates))",
                                    "merchant \(result.merchant.kind.rawValue): \(result.merchant.value ?? "missing") [\(result.merchant.rule)] \(candidateDisplay(result.merchant.candidates))",
                                    "date \(result.date.kind.rawValue): \(result.date.occurredAt?.isoUTC ?? "none") [\(result.date.rule)] \(candidateDisplay(result.date.candidates))",
                                    "reference \(result.reference.kind.rawValue): \(result.reference.value ?? "none") [\(result.reference.rule)] \(candidateDisplay(result.reference.candidates))",
                                    "M1 \(result.noTransactionEvidence ? "no row" : fixtureDecision.disposition.rawValue) (without history or duplicate lookup)",
                                    "blank \(blankRejected ? "rejected" : "accepted")",
                                    "malformed \(malformedRejected ? "rejected" : "accepted")"
                                ].joined(separator: " · ")
                            } catch { ocrFixtureResult = "failed: \(error.localizedDescription)" }
                        }
                    }
                    Text("OCR fixture: \(ocrFixtureResult)")
                        .accessibilityIdentifier("ocr-fixture-result")
                }
                Section("Screenshot dry run") {
                    PhotosPicker(selection: $selectedScreenshot, matching: .images) {
                        Text("Interpret image (dry run)")
                    }
                    .onChange(of: selectedScreenshot) { _, item in
                        guard let item else { return }
                        Task { await interpretDryRun(item) }
                    }
                    Text(dryRunStatus).font(.caption)
                        .accessibilityIdentifier("screenshot-dry-run-status")
                    if let result = dryRunResult, let fixture = dryRunFixture {
                        LabeledContent("Amount", value: "\(result.amount.kind.rawValue) · \(result.amount.rule) · \(result.amount.value.map { String($0.minorUnits) } ?? "none")")
                        LabeledContent("Amount candidates", value: candidateDisplay(result.amount.candidates))
                        LabeledContent("Merchant", value: "\(result.merchant.kind.rawValue) · \(result.merchant.rule) · \(result.merchant.value ?? "none")")
                        LabeledContent("Merchant candidates", value: candidateDisplay(result.merchant.candidates))
                        LabeledContent("Date", value: "\(result.date.kind.rawValue) · \(result.date.rule) · \(result.date.occurredAt?.isoUTC ?? "none") · \(result.date.trust.rawValue)")
                        LabeledContent("Ledger timestamp", value: "\(fixture.capturedAt) · intentional Back Tap capture time")
                        LabeledContent("Date candidates", value: candidateDisplay(result.date.candidates))
                        LabeledContent("Reference", value: "\(result.reference.kind.rawValue) · \(result.reference.rule) · \(result.reference.value ?? "none")")
                        LabeledContent("Reference candidates", value: candidateDisplay(result.reference.candidates))
                        LabeledContent("M1 dry run", value: dryRunDecision)
                        LabeledContent("Vision OCR", value: "\(dryRunOCRMS ?? 0) ms")
                        Text("All OCR observations · \(fixture.lines.count)").font(.caption)
                        Text(ScreenshotObservationDiagnostics.display(fixture.lines))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy fixture JSON") { copyFixture(fixture) }
                    }
                }
                Section("Experiments") {
                    NavigationLink("Apple FM categorizer benchmark") { CategorizerBenchView() }
                    NavigationLink("Apple FM screenshot benchmark") { ScreenshotFMBenchView() }
                    NavigationLink("Apple FM representation A/B probe") { ScreenshotFMRepresentationProbeView() }
                    NavigationLink("Apple FM single-decision probe") { ScreenshotFMSingleDecisionProbeView() }
                }
                Section("Paths and evidence") {
                    ForEach(paths, id: \.path) { path in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(path.path) · \(path.stage.rawValue)")
                            Text("Captures \(path.captures) · reviewed \(path.reviewed) · amount errors \(path.amountErrors) · merchant errors \(path.merchantErrors)")
                                .font(.caption)
                            if let reason = path.lastChangeReason { Text(reason).font(.caption) }
                        }
                    }
                }
                Section("Capture Feedback") {
                    Text("\(feedbackSummary?.totalCaptures ?? 0) captures · \(feedbackSummary?.corrected ?? 0) corrected")
                    Text("Back Tap \(feedbackSummary?.byCaptureSource["intentionalBackTap"]?.total ?? 0) · Apple Pay \(feedbackSummary?.byCaptureSource["applePay"]?.total ?? 0)")
                        .font(.caption).foregroundStyle(Theme.ink3)
                    Button("Export Capture Feedback") { exportFeedback() }
                        .accessibilityIdentifier("export-capture-feedback")
                    if let feedbackExportError { Text(feedbackExportError).foregroundStyle(Theme.warn) }
                }
                Section("Decision log") {
                    ForEach(entries) { entry in
                        DisclosureGroup {
                            LabeledContent("Received", value: entry.rawFields ?? "{}")
                            if entry.source == "screenshot" {
                                if diagnostic(entry, "parser") == "intentional_fm" {
                                    Button("Copy production Back Tap trace") {
                                        UIPasteboard.general.string = productionTrace(entry)
                                    }
                                    Text(productionTrace(entry))
                                        .font(.system(.caption2, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                LabeledContent("OCR", value: diagnostic(entry, "ocrStatus"))
                                LabeledContent("Payment screen", value: diagnostic(entry, "paymentScreen"))
                                LabeledContent("Provider / parser", value: "\(diagnostic(entry, "provider")) / \(diagnostic(entry, "parser"))")
                                LabeledContent("OCR evidence", value: diagnostic(entry, "ocrRelevantLines"))
                                Text("All OCR observations · \(diagnostic(entry, "ocrObservationCount")) · truncated: \(diagnostic(entry, "ocrObservationsTruncated"))")
                                    .font(.caption)
                                Text(observationDisplay(entry))
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                if let fixture = fixture(entry) {
                                    Button("Copy fixture JSON") { copyFixture(fixture) }
                                }
                                LabeledContent("Amount candidate", value: diagnostic(entry, "amountCandidate"))
                                LabeledContent("Amount provenance", value: diagnostic(entry, "amountProvenance"))
                                LabeledContent("Merchant candidate", value: diagnostic(entry, "merchantCandidate"))
                                LabeledContent("Merchant provenance", value: diagnostic(entry, "merchantProvenance"))
                                LabeledContent("Reference candidate", value: diagnostic(entry, "referenceCandidate"))
                                LabeledContent("Displayed transaction time", value: diagnostic(entry, "displayedTransactionTime"))
                                LabeledContent("Ledger timestamp source", value: "intentional Back Tap capture time")
                                LabeledContent("Screenshot date evidence", value: diagnostic(entry, "dateFinal") + " · diagnostic only")
                                LabeledContent("Date provenance", value: "\(diagnostic(entry, "dateProvenance")) · \(diagnostic(entry, "dateTrust"))")
                                ForEach(["amount", "merchant", "date", "reference"], id: \.self) { field in
                                    LabeledContent(field.capitalized + " resolution", value: "\(diagnostic(entry, field + "Resolution")) · \(diagnostic(entry, field + "Rule")) · \(diagnostic(entry, field + "Final"))")
                                    LabeledContent(field.capitalized + " candidates", value: diagnostic(entry, field + "Candidates"))
                                }
                                LabeledContent("Image received", value: diagnostic(entry, "imageReceivedMS") + " ms")
                                LabeledContent("Normalization", value: diagnostic(entry, "normalizationMS") + " ms")
                                LabeledContent("Vision OCR", value: diagnostic(entry, "ocrMS") + " ms")
                                LabeledContent("Interpretation", value: diagnostic(entry, "interpretationMS") + " ms")
                            }
                            LabeledContent("Normalized", value: entry.fields)
                            LabeledContent("Final amount", value: normalized(entry, "amountMinor"))
                            LabeledContent("Final merchant", value: normalized(entry, "merchant"))
                            LabeledContent("Final category", value: normalized(entry, "categoryID"))
                            LabeledContent("M1 outcome", value: entry.outcome)
                            LabeledContent("Actual review reason", value: entry.reason)
                            LabeledContent("Memory", value: entry.merchantResolution ?? "none")
                            LabeledContent("Duplicate", value: entry.duplicateMatchID ?? "none")
                            LabeledContent("Anomaly", value: entry.anomaly ?? "[]")
                            LabeledContent("Corrections", value: entry.feedback.isEmpty ? "none" : entry.feedback)
                            LabeledContent("Stage", value: entry.stage)
                            LabeledContent("Execution", value: entry.executionContext ?? "unknown")
                            LabeledContent("Elapsed", value: entry.elapsedMS.map { "\($0) ms" } ?? "unknown")
                            LabeledContent("Intent began", value: entry.intentStartedAt ?? "unknown")
                            LabeledContent("Database open", value: entry.databaseOpenMS.map { "\($0) ms" } ?? "unknown")
                            LabeledContent("Notification", value: entry.notificationStatus ?? "not attempted")
                            LabeledContent("Notification time", value: entry.notificationScheduledAt ?? "unknown")
                        } label: {
                            VStack(alignment: .leading) {
                                Text("\(entry.outcome.uppercased()) · \(entry.source)")
                                Text(entry.reason).font(.caption)
                                Text(entry.time).font(.caption2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Capture Lab")
            .toolbar { Button("Refresh") { refresh() } }
            .sheet(item: $feedbackExportFile) { file in
                FeedbackShareSheet(url: file.url)
            }
        }
        .onAppear {
            ceiling = settings?.object(forKey: "pace.capture.testingCeilingMinor") as? Int ?? 50_000
            pinnedStage = settings?.string(forKey: "pace.capture.applePayStage").flatMap(CaptureStage.init(rawValue:))
            screenshotStage = settings?.string(forKey: "pace.capture.screenshotStage").flatMap(CaptureStage.init(rawValue:))
            refresh()
        }
    }

    private func refresh() {
        let processor = CaptureProcessor(database: model.database)
        entries = (try? processor.recentLog()) ?? []
        paths = (try? processor.pathStates()) ?? []
        feedbackSummary = try? processor.intentionalCaptureFeedback().summary
    }

    private func normalized(_ entry: CaptureLogEntry, _ key: String) -> String {
        let fields = (try? JSONDecoder().decode([String: String].self, from: Data(entry.fields.utf8))) ?? [:]
        return fields[key] ?? "none"
    }

    private func exportFeedback() {
        do {
            let bundle = Bundle.main
            let result = try CaptureProcessor(database: model.database).intentionalCaptureFeedback(
                appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                buildVersion: bundle.infoDictionary?["CFBundleVersion"] as? String)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("pace-capture-feedback.json")
            try result.jsonData().write(to: file, options: .atomic)
            feedbackSummary = result.summary
            feedbackExportError = nil
            feedbackExportFile = FeedbackExportFile(url: file)
        } catch { feedbackExportError = error.localizedDescription }
    }

    private func diagnostic(_ entry: CaptureLogEntry, _ key: String) -> String {
        guard let raw = entry.rawFields?.data(using: .utf8),
              let fields = try? JSONDecoder().decode([String: String].self, from: raw) else { return "not retained" }
        return fields[key] ?? "none"
    }

    private func productionTrace(_ entry: CaptureLogEntry) -> String {
        let normalized = (try? JSONDecoder().decode([String: String].self, from: Data(entry.fields.utf8))) ?? [:]
        func field(_ key: String) -> String { normalized[key] ?? "none" }
        let ocrText = fixture(entry)?.lines.enumerated().map { index, line in
            "\(index + 1). [\(String(format: "%.2f", line.confidence))] \(line.text)"
        }.joined(separator: "\n") ?? diagnostic(entry, "ocrRelevantLines")
        return [
            "Pace production Back Tap trace · \(entry.time)",
            "Outcome: \(entry.outcome) · \(entry.reason)",
            "Screenshot: received=\(diagnostic(entry, "screenshotReceived")) bytes=\(diagnostic(entry, "imageByteCount")) original=\(diagnostic(entry, "originalImageSize")) normalized=\(diagnostic(entry, "imageSize"))",
            "Vision: status=\(diagnostic(entry, "ocrStatus")) observations=\(diagnostic(entry, "ocrObservationCount")) truncated=\(diagnostic(entry, "ocrObservationsTruncated"))",
            "Resolver: \(diagnostic(entry, "resolverMS"))ms",
            "OCR text:\n\(ocrText)",
            "OCR money candidates: \(diagnostic(entry, "amountCandidates"))",
            "FM: availability=\(diagnostic(entry, "modelAvailability"))",
            "Money call: attempted=\(diagnostic(entry, "moneyFMAttempted")) selected=\(diagnostic(entry, "moneyFMSelected")) error=\(diagnostic(entry, "moneyFMError")) latency=\(diagnostic(entry, "moneyFMMS"))ms",
            "Money grounding: exactOCR=\(diagnostic(entry, "amountExactOCRSupport")) semanticOCR=\(diagnostic(entry, "amountSemanticOCRSupport")) grounded=\(diagnostic(entry, "amountGroundedText")) currency=\(diagnostic(entry, "amountCurrency")) parsedMinor=\(diagnostic(entry, "amountParsedMinor")) reason=\(diagnostic(entry, "amountGrounding"))",
            "Merchant call: attempted=\(diagnostic(entry, "merchantFMAttempted")) selected=\(diagnostic(entry, "merchantFMSelected")) error=\(diagnostic(entry, "merchantFMError")) latency=\(diagnostic(entry, "merchantFMMS"))ms",
            "Merchant grounding: exactOCR=\(diagnostic(entry, "merchantExactOCRSupport")) grounded=\(diagnostic(entry, "merchantGroundedText")) normalizedKey=\(diagnostic(entry, "merchantNormalizedKey")) reason=\(diagnostic(entry, "merchantGroundingReason")) fallback=\(diagnostic(entry, "merchantFallbackCandidate")) source=\(diagnostic(entry, "merchantSelectionSource"))",
            "Category: memory=\(diagnostic(entry, "categoryMemoryLookup")) FM attempted=\(diagnostic(entry, "categoryFMAttempted")) returned=\(diagnostic(entry, "categoryFMReturned")) error=\(diagnostic(entry, "categoryFMError")) validation=\(diagnostic(entry, "categoryValidation")) final=\(field("categoryID")) source=\(diagnostic(entry, "categorySource")) memoryModified=\(diagnostic(entry, "categoryMemoryModified"))",
            "M1 input: amount=\(diagnostic(entry, "amountM1Minor")) merchant=\(diagnostic(entry, "merchantM1Text")) amountTrust=\(field("amountTrust")) merchantTrust=\(field("merchantTrust"))",
            "M1 decision: outcome=\(entry.outcome) reason=\(entry.reason) unresolved=\(field("unresolved")) stage=\(entry.stage) anomaly=\(entry.anomaly ?? "[]")",
            "Merchant memory: resolution=\(entry.merchantResolution ?? "none") canonical=\(field("merchant")) category=\(field("categoryID"))",
            "Database: intent=\(diagnostic(entry, "intentDatabasePath")) lab=\(model.database.url?.path ?? "in memory")",
            "Execution: \(entry.executionContext ?? "unknown") · elapsed=\(entry.elapsedMS.map(String.init) ?? "unknown")ms"
        ].joined(separator: "\n")
    }

    private func fixture(_ entry: CaptureLogEntry) -> ScreenshotFixture? {
        let value = diagnostic(entry, "ocrFixtureJSON")
        return try? JSONDecoder().decode(ScreenshotFixture.self, from: Data(value.utf8))
    }

    private func observationDisplay(_ entry: CaptureLogEntry) -> String {
        if let fixture = fixture(entry) { return ScreenshotObservationDiagnostics.display(fixture.lines) }
        return diagnostic(entry, "ocrObservations") // Older Debug entries used the coarse text dump.
    }

    private func copyFixture(_ fixture: ScreenshotFixture) {
        UIPasteboard.general.string = try? fixture.json()
    }

    private func candidateDisplay(_ candidates: [CandidateTrace]) -> String {
        candidates.map { "\($0.id)·\($0.value)·\($0.rejected ?? "viable")" }.joined(separator: " | ")
    }

    @MainActor
    private func interpretDryRun(_ item: PhotosPickerItem) async {
        dryRunStatus = "Running Vision OCR and interpretation…"
        dryRunFixture = nil
        dryRunResult = nil
        dryRunOCRMS = nil
        defer { selectedScreenshot = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                dryRunStatus = "Could not load the selected image."
                return
            }
            let capturedAt = Instant(Date())
            let zone = TimeZone.current.identifier
            let ocr = try await ScreenshotOCRService.recognize(data)
            let result = ScreenshotFieldResolver().resolve(ocr.lines, capturedAt: capturedAt, timeZone: zone)
            let request = ScreenshotIntentionalCapture.request(lines: ocr.lines, resolution: result,
                imageHash: ocr.imageHash, capturedAt: capturedAt, timeZone: zone)
            var policy = CaptureTrustPolicy(); policy.stage = .assisted
            let decision = CaptureTrustDecision.decide(request,
                merchant: CaptureMerchant(name: request.merchant), history: CaptureHistory(),
                duplicateMatchID: nil, policy: policy)
            let fixture = ScreenshotFixture(capturedAt: capturedAt, timeZone: zone,
                lines: Array(ocr.lines.prefix(ScreenshotObservationDiagnostics.displayLimit)))
            dryRunFixture = fixture
            dryRunResult = result
            dryRunDecision = result.noTransactionEvidence ? "no payment; no row" :
                "\(decision.disposition.rawValue) · \(decision.reason) (without history or duplicate lookup)"
            dryRunOCRMS = ocr.ocrMS
            dryRunStatus = "Dry run complete · \(ocr.lines.count) Vision observations" +
                (ocr.lines.count > fixture.lines.count ? " · fixture truncated at 120" : "") +
                " · no capture created"
        } catch {
            dryRunStatus = "Dry run failed: \(error.localizedDescription)"
        }
    }
}

private struct FeedbackExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct FeedbackShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
