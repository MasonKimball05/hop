import CoreGraphics
import Vision

/// Reads text in an image, on this Mac, with Vision.
enum TextRecognition {
    /// The lines of text, top to bottom. `fast` is for watch mode's frequent checks;
    /// the accurate pass is for text you're going to use.
    static func lines(in image: CGImage, fast: Bool) async -> [String] {
        await Task.detached {
            // The older request: on macOS 26 the newer RecognizeTextRequest at .fast
            // finds no text at all. This one reads a window in about 20 ms at .fast.
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = fast ? .fast : .accurate
            request.usesLanguageCorrection = !fast
            if !fast { request.automaticallyDetectsLanguage = true }
            try? VNImageRequestHandler(cgImage: image).perform([request])
            return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        }.value
    }
}
