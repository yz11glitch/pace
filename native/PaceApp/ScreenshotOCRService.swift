import CryptoKit
import Foundation
import PaceCore
import UIKit
import Vision

enum ScreenshotOCRError: Error { case emptyImage, imageTooLarge, invalidImage, normalizationFailed }

struct ScreenshotOCRResult: Sendable {
    let lines: [ScreenshotTextLine]
    let imageHash: String
    let imageSize: String
    let languages: [String]
    let normalizationMS: Int
    let ocrMS: Int
}

/// No screenshot file is created by Pace. Shortcuts' IntentFile is read into memory,
/// normalized there, recognized by on-device Vision, then released.
enum ScreenshotOCRService {
    static func recognize(_ imageData: Data) async throws -> ScreenshotOCRResult {
        guard !imageData.isEmpty else { throw ScreenshotOCRError.emptyImage }
        guard imageData.count <= 25_000_000 else { throw ScreenshotOCRError.imageTooLarge }
        let normalizationStart = Date()
        let (normalized, size) = try await MainActor.run { try normalize(imageData) }
        let normalizationMS = Int(Date().timeIntervalSince(normalizationStart) * 1_000)
        let digest = SHA256.hash(data: normalized).map { String(format: "%02x", $0) }.joined()
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // Preserve financial digits and reference IDs.
        let desired = [Locale.Language(identifier: "en-US"), Locale.Language(identifier: "ms-MY")]
        let supported = request.supportedRecognitionLanguages
        let selected = desired.filter { supported.contains($0) }
        if !selected.isEmpty { request.recognitionLanguages = selected }
        let ocrStart = Date()
        let observations = try await request.perform(on: normalized)
        let ocrMS = Int(Date().timeIntervalSince(ocrStart) * 1_000)
        let lines = observations.compactMap { observation -> ScreenshotTextLine? in
            let candidates = observation.topCandidates(3)
            guard let candidate = candidates.first else { return nil }
            let points = [observation.topLeft, observation.topRight,
                          observation.bottomLeft, observation.bottomRight]
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { return nil }
            return ScreenshotTextLine(candidate.string, confidence: Double(candidate.confidence),
                                      x: Double(minX), y: Double(1 - maxY),
                                      width: Double(maxX - minX), height: Double(maxY - minY),
                                      pass: "primary",
                                      alternates: ScreenshotObservationDiagnostics.alternates(
                                        from: candidates.map(\.string)))
        }
        return ScreenshotOCRResult(lines: lines, imageHash: digest, imageSize: size,
                                   languages: selected.map { String(describing: $0) },
                                   normalizationMS: normalizationMS, ocrMS: ocrMS)
    }

    @MainActor
    private static func normalize(_ data: Data) throws -> (Data, String) {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw ScreenshotOCRError.invalidImage
        }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 2_048 / longest)
        let size = CGSize(width: max(1, (image.size.width * scale).rounded()),
                          height: max(1, (image.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard !png.isEmpty else { throw ScreenshotOCRError.normalizationFailed }
        return (png, "\(Int(size.width))x\(Int(size.height))")
    }

    #if DEBUG
    /// Synthetic integration fixture for the on-device Vision path. It makes no claim
    /// about a bank or e-wallet provider's real confirmation screen.
    @MainActor
    static func fixtureImage() -> Data {
        let size = CGSize(width: 900, height: 700)
        return UIGraphicsImageRenderer(size: size).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 48, weight: .semibold),
                .foregroundColor: UIColor.black]
            for (index, line) in ["Payment successful", "RM 23.90", "Paid to ZUS COFFEE",
                                  "Reference: ABC123456"].enumerated() {
                (line as NSString).draw(at: CGPoint(x: 45, y: 90 + index * 120), withAttributes: attributes)
            }
        }
    }
    #endif
}
