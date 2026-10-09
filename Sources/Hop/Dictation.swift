import AVFoundation
import Speech

/// Speech to text for asking out loud, on this Mac (Apple's on-device recognizer when
/// the language has one), so the audio isn't sent anywhere. Asks for microphone and
/// speech recognition permission the first time.
@MainActor
final class Dictation {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private let recognizer = SFSpeechRecognizer()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isListening: Bool { engine != nil }

    /// Starts listening; `heard` gets the whole transcript so far each time it changes.
    func start(heard: @escaping @MainActor (String) -> Void) async throws(Failure) {
        guard await Self.allowed() else {
            throw Failure(errorDescription: "Hop needs Microphone and Speech Recognition permission to listen. Allow Hop in System Settings \u{25B8} Privacy & Security, then try again.")
        }
        guard let recognizer, recognizer.isAvailable else {
            throw Failure(errorDescription: "Speech recognition isn\u{2019}t available for your language right now.")
        }
        stop()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // The tap runs on an audio thread; the request takes buffers from any thread.
        nonisolated(unsafe) let feed = request
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            feed.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure(errorDescription: "Couldn\u{2019}t start the microphone: \(error.localizedDescription)")
        }
        self.engine = engine
        self.request = request
        task = recognizer.recognitionTask(with: request) { result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in heard(text) }
        }
    }

    /// Stops listening. The last words can still arrive through `heard` just after.
    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        request?.endAudio()
        request = nil
        task?.finish()
        task = nil
    }

    private static func allowed() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        return speech && microphone
    }
}
