import AppIntents
import Foundation
import PaceCore
import PaceStore
import UIKit
import UniformTypeIdentifiers
#if DEBUG
import FoundationModels
#endif

/// Shortcuts: Take Screenshot → Log Screenshot with Pace (Screenshot = Screenshot result).
/// The image is supplied by the user's Shortcut, never read from Wallet or Photos history.
struct LogScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Screenshot with Pace"
    static let description = IntentDescription("Read a payment confirmation screenshot on device and send its evidence to Pace.")
    static let supportedModes: IntentModes = .background
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Screenshot", supportedContentTypes: [.image]) var screenshot: IntentFile

    func perform() async throws -> some IntentResult {
        let began = Date()
        let imageData = screenshot.data
        let imageReceivedMS = Int(Date().timeIntervalSince(began) * 1_000)
        #if DEBUG
        let originalImageSize = UIImage(data: imageData)?.cgImage.map { "\($0.width)x\($0.height)" } ?? "unavailable"
        // Persisted parser label; Foundation Models is used for category only.
        var failureTrace = ["parser": "intentional_fm",
                            "screenshotReceived": imageData.isEmpty ? "no" : "yes",
                            "imageByteCount": String(imageData.count),
                            "originalImageSize": originalImageSize,
                            "imageReceivedMS": String(imageReceivedMS),
                            "ocrStatus": "not attempted",
                            "moneyFMAttempted": "no", "merchantFMAttempted": "no"]
        #endif
        let bundle = Bundle.main.bundleIdentifier ?? ""
        let database = try PaceDatabase(url: PaceDatabase.defaultURL(appGroup: "group.\(bundle)"))
        #if DEBUG
        failureTrace["intentDatabasePath"] = database.url?.path ?? "in memory"
        #endif
        let databaseOpenMS = Int(Date().timeIntervalSince(began) * 1_000)
        let processor = CaptureProcessor(database: database)
        let appState = await MainActor.run { () -> String in
            switch UIApplication.shared.applicationState {
            case .active: "foreground"
            case .background: "background"
            case .inactive: "inactive"
            @unknown default: "unknown"
            }
        }
        let context = "app_intent_\(appState)"
        #if DEBUG
        let retainDiagnostics = true
        #else
        let retainDiagnostics = false
        #endif
        var ocrCompleted = false
        do {
            let ocr = try await ScreenshotOCRService.recognize(imageData)
            ocrCompleted = true
            let interpretationStart = Date()
            let capturedAt = Instant(began)
            let zone = TimeZone.current.identifier
            #if DEBUG
            let modelAvailability = String(describing: SystemLanguageModel.default.availability)
            failureTrace["ocrStatus"] = "success"
            failureTrace["ocrObservationCount"] = String(ocr.lines.count)
            failureTrace["imageSize"] = ocr.imageSize
            failureTrace["modelAvailability"] = modelAvailability
            let earlyFixture = try? ScreenshotObservationDiagnostics.retainedFixture(
                capturedAt: capturedAt, timeZone: zone, lines: ocr.lines)
            failureTrace["ocrFixtureJSON"] = earlyFixture.flatMap { try? $0.fixture.json() } ?? ""
            failureTrace["ocrObservationsTruncated"] = earlyFixture?.truncated == true ? "yes" : "no"
            #endif
            let resolutionStart = Date()
            let resolution = ScreenshotFieldResolver().resolve(ocr.lines, capturedAt: capturedAt, timeZone: zone)
            let resolverMS = Int(Date().timeIntervalSince(resolutionStart) * 1_000)
            if resolution.noTransactionEvidence {
                #if DEBUG
                var noPaymentDiagnostics = failureTrace
                noPaymentDiagnostics["resolverMS"] = String(resolverMS)
                noPaymentDiagnostics["amountResolution"] = resolution.amount.kind.rawValue
                noPaymentDiagnostics["amountRule"] = resolution.amount.rule
                noPaymentDiagnostics["amountCandidates"] = resolution.amount.candidates.map {
                    "\($0.id)·\($0.value)·\($0.rejected ?? "viable")"
                }.joined(separator: " | ")
                noPaymentDiagnostics["amountFinal"] = "none"
                noPaymentDiagnostics["merchantResolution"] = resolution.merchant.kind.rawValue
                noPaymentDiagnostics["merchantRule"] = resolution.merchant.rule
                noPaymentDiagnostics["merchantCandidates"] = resolution.merchant.candidates.map {
                    "\($0.id)·\($0.value)·\($0.rejected ?? "viable")"
                }.joined(separator: " | ")
                noPaymentDiagnostics["merchantFinal"] = "none"
                noPaymentDiagnostics["dateResolution"] = resolution.date.kind.rawValue
                noPaymentDiagnostics["dateRule"] = resolution.date.rule
                noPaymentDiagnostics["dateCandidates"] = resolution.date.candidates.map {
                    "\($0.id)·\($0.value)·\($0.rejected ?? "viable")"
                }.joined(separator: " | ")
                noPaymentDiagnostics["dateFinal"] = resolution.date.occurredAt?.isoUTC ?? "none"
                noPaymentDiagnostics["referenceResolution"] = resolution.reference.kind.rawValue
                noPaymentDiagnostics["referenceRule"] = resolution.reference.rule
                noPaymentDiagnostics["referenceCandidates"] = resolution.reference.candidates.map {
                    "\($0.id)·\($0.value)·\($0.rejected ?? "viable")"
                }.joined(separator: " | ")
                noPaymentDiagnostics["referenceFinal"] = "none"
                #else
                let noPaymentDiagnostics = ["ocrStatus": "success"]
                #endif
                let logID = try processor.recordCaptureRejection(reason: "no payment found on screen",
                    fields: ["ocrStatus": "success"], diagnostics: noPaymentDiagnostics,
                    executionContext: context, retainDiagnostics: retainDiagnostics,
                    intentStartedAt: began, databaseOpenMS: databaseOpenMS)
                let notification = await CaptureNotifications.postNoPayment()
                try? processor.markOutcomeNotification(outcomeID: logID, status: notification, at: Date())
                return .result()
            }
            var input = ScreenshotIntentionalCapture.request(
                lines: ocr.lines, resolution: resolution, imageHash: ocr.imageHash,
                capturedAt: capturedAt, timeZone: zone)
            let category = try await processor.screenshotCategory(for: input,
                ocrText: ocr.lines.map(\.text)) { merchant, context in
                await ScreenshotCategoryService.suggest(merchant: merchant, ocrText: context)
            }
            input.categoryID = category.categoryID
            input.categoryTrust = .usable
            let feedbackEvidence = try IntentionalCaptureEvidence(lines: ocr.lines,
                capturedAt: capturedAt, timeZone: zone, resolver: resolution, category: category)
            let interpretationMS = Int(Date().timeIntervalSince(interpretationStart) * 1_000)
            // The Lab trace is Debug-only; the bounded structured feedback evidence
            // is retained locally in all builds. No screenshot bytes or path are kept.
            let retained = try? ScreenshotObservationDiagnostics.retainedFixture(
                capturedAt: capturedAt, timeZone: zone, lines: ocr.lines)
            let fixtureJSON = retained.flatMap { try? $0.fixture.json() } ?? ""
            var diagnostics = [
                "ocrStatus": "success", "parser": "intentional_fm",
                "ocrRelevantLines": ocr.lines.prefix(20).map(\.text).joined(separator: " | "),
                "ocrFixtureJSON": fixtureJSON,
                "ocrObservationCount": String(ocr.lines.count),
                "ocrObservationsTruncated": retained?.truncated == true ? "yes" : "no",
                "amountCandidates": input.amountCandidates.joined(separator: " | "),
                "amountCandidate": resolution.amount.selected?.value ?? "missing",
                "amountGrounding": resolution.amount.rule,
                "amountCurrency": resolution.amount.value?.currency ?? "missing",
                "amountProvenance": input.amountTrust.rawValue,
                "merchantCandidate": resolution.merchant.selected?.value ?? "missing",
                "merchantProvenance": input.merchantTrust.rawValue,
                "referenceCandidate": input.reference ?? "missing",
                "displayedTransactionTime": resolution.date.occurredAt?.isoUTC ?? "none",
                "ledgerTimestampSource": "intentional Back Tap capture time",
                "dateTrust": input.dateTrust.rawValue,
                "moneyFMError": "not called", "merchantFMError": "not called",
                "categoryMemoryLookup": category.memoryCategoryID ?? "none",
                "categoryFMAttempted": category.fmAttempted ? "yes" : "no",
                "categoryFMReturned": category.fmCategory ?? "none",
                "categoryValidation": category.validation,
                "categoryFMError": category.fmError ?? "none",
                "categorySource": category.source,
                "categoryMemoryModified": "no",
                "moneyFMMS": "0", "merchantFMMS": "0",
                "imageSize": ocr.imageSize, "ocrLanguages": ocr.languages.joined(separator: ","),
                "imageReceivedMS": String(imageReceivedMS),
                "normalizationMS": String(ocr.normalizationMS), "ocrMS": String(ocr.ocrMS),
                "resolverMS": String(resolverMS),
                "interpretationMS": String(interpretationMS)]
            #if DEBUG
            diagnostics.merge(failureTrace) { _, new in new }
            diagnostics["moneyFMAttempted"] = "no"
            diagnostics["merchantFMAttempted"] = "no"
            diagnostics["amountGroundedText"] = resolution.amount.selected?.value ?? "none"
            diagnostics["amountParsedMinor"] = resolution.amount.value.map { String($0.minorUnits) } ?? "none"
            diagnostics["amountM1Minor"] = input.amountMinor.map(String.init) ?? "none"
            diagnostics["merchantGroundedText"] = resolution.merchant.selected?.value ?? "none"
            diagnostics["merchantNormalizedKey"] = resolution.merchant.value.map(merchantKey) ?? "none"
            diagnostics["merchantGroundingReason"] = resolution.merchant.rule
            diagnostics["merchantM1Text"] = input.merchant ?? "none"
            diagnostics["merchantSelectionSource"] = input.rawFields["merchantSelectionSource"] ?? "none"
            diagnostics["merchantFallbackCandidate"] = input.rawFields["merchantFallbackCandidate"] ?? "none"
            func describe(_ candidates: [CandidateTrace]) -> String {
                candidates.map { "\($0.id)·\($0.value)·\($0.rejected ?? "viable")" }.joined(separator: " | ")
            }
            diagnostics["amountResolution"] = resolution.amount.kind.rawValue
            diagnostics["amountRule"] = resolution.amount.rule
            diagnostics["amountCandidates"] = describe(resolution.amount.candidates)
            diagnostics["amountFinal"] = input.amountMinor.map(String.init) ?? "none"
            diagnostics["merchantResolution"] = resolution.merchant.kind.rawValue
            diagnostics["merchantRule"] = resolution.merchant.rule
            diagnostics["merchantCandidates"] = describe(resolution.merchant.candidates)
            diagnostics["merchantFinal"] = input.merchant ?? "none"
            diagnostics["dateResolution"] = resolution.date.kind.rawValue
            diagnostics["dateRule"] = resolution.date.rule
            diagnostics["dateCandidates"] = describe(resolution.date.candidates)
            diagnostics["dateFinal"] = resolution.date.occurredAt?.isoUTC ?? "none"
            diagnostics["referenceResolution"] = resolution.reference.kind.rawValue
            diagnostics["referenceRule"] = resolution.reference.rule
            diagnostics["referenceCandidates"] = describe(resolution.reference.candidates)
            diagnostics["referenceFinal"] = input.reference ?? "none"
            #endif
            var policy = CaptureTrustPolicy()
            let settings = UserDefaults(suiteName: "group.\(bundle)")
            if let ceiling = settings?.object(forKey: "pace.capture.testingCeilingMinor") as? Int {
                policy.testingCeilingMinor = ceiling
            }
            if let stage = settings?.string(forKey: "pace.capture.screenshotStage").flatMap(CaptureStage.init(rawValue:)) {
                policy.pinnedStage = stage
            }
            let capture = try processor.process(input, policy: policy, executionContext: context,
                retainRawDiagnostics: retainDiagnostics, intentStartedAt: began,
                databaseOpenMS: databaseOpenMS, diagnostics: diagnostics,
                feedbackEvidence: feedbackEvidence)
            await CaptureNotifications.removeOldSavedNotifications()
            let notification: String
            switch capture.outcome {
            case .duplicate: notification = await CaptureNotifications.postDuplicate(capture)
            case .saved, .draft: notification = await CaptureNotifications.post(capture)
            case .blocked, .failed: notification = await CaptureNotifications.postCaptureFailure()
            }
            if let recordID = capture.recordID, capture.outcome == .saved || capture.outcome == .draft {
                try? processor.markNotification(recordID: recordID, status: notification, at: Date())
            } else if let recordID = capture.recordID, capture.outcome == .duplicate {
                try? processor.markReplayNotification(recordID: recordID, status: notification, at: Date())
            }
        } catch {
            let reason = "screenshot \(ocrCompleted ? "capture" : "OCR") failed: \(error.localizedDescription)"
            #if DEBUG
            failureTrace["ocrStatus"] = ocrCompleted ? "success" : "failed"
            failureTrace["error"] = String(error.localizedDescription.prefix(500))
            #endif
            let logID = try processor.recordCaptureRejection(reason: reason, outcome: .failed,
                fields: ["ocrStatus": ocrCompleted ? "success" : "failed"],
                diagnostics: {
                    #if DEBUG
                    return failureTrace
                    #else
                    return ["ocrStatus": ocrCompleted ? "success" : "failed"]
                    #endif
                }(),
                executionContext: context, retainDiagnostics: retainDiagnostics,
                intentStartedAt: began, databaseOpenMS: databaseOpenMS)
            let notification = ocrCompleted
                ? await CaptureNotifications.postCaptureFailure()
                : await CaptureNotifications.postOCRFailure()
            try? processor.markOutcomeNotification(outcomeID: logID, status: notification, at: Date())
        }
        return .result()
    }

}
