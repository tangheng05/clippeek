import Foundation
import Vision

/// Reads the text in an image on this Mac; nothing leaves it.
public enum TextRecognition {
    /// Lines in reading order, or nil when there's no text.
    public static func text(in image: Data) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: image) else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
