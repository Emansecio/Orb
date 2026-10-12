import AVFoundation
import os
import Speech

// Dictation into the composer with the Mac's own speech recognition (SpeechAnalyzer, macOS 26): on the Mac, free, no
// audio leaves it. The model for the language is downloaded by the system once, the first time.

/// What the microphone has given so far: the words that will not change, then the ones still being guessed (they are
/// replaced as more is heard). Pure, so the tests can read it.
struct DictationText: Equatable, Sendable {
    var settled = ""
    var guessing = ""

    var whole: String { Self.joined(settled, guessing) }

    mutating func take(_ text: String, isFinal: Bool) {
        if isFinal {
            settled = Self.joined(settled, text)
            guessing = ""
        } else {
            guessing = text
        }
    }

    /// Two pieces with one space between them (none when either side already has one, or is empty).
    static func joined(_ first: String, _ second: String) -> String {
        guard let last = first.last, let next = second.first else { return first + second }
        return last.isWhitespace || next.isWhitespace ? first + second : first + " " + second
    }

    /// The draft while dictating: what was in the field when the microphone opened, then what was said.
    static func draft(base: String, spoken: String) -> String {
        joined(base, spoken.drop { $0.isWhitespace }.description)
    }
}

/// The microphone and the recognizer of one dictation. Start once, then finish (waits for the last words) or cancel.
@available(macOS 26, *)
final class SpeechCapture: @unchecked Sendable {
    enum Failure: LocalizedError {
        case noLanguage, noMicrophone

        var errorDescription: String? {
            switch self {
            case .noLanguage: "O reconhecimento de fala do Mac não tem o idioma do sistema."
            case .noMicrophone: "Nenhum microfone disponível."
            }
        }
    }

    private let audio = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var reader: Task<Void, Never>?
    private var isTapped = false

    /// The system's language as the recognizer has it (pt-BR for a Mac in Portuguese), nil when it has none like it.
    static func locale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
    }

    /// Opens the microphone and starts recognizing. `downloading` is called when the language's model must be fetched
    /// first (once per Mac); `heard` gets each piece of text, `level` how loud the microphone is (0...1).
    func start(locale: Locale, vocabulary: [String], downloading: @escaping @MainActor @Sendable () -> Void,
               heard: @escaping @MainActor @Sendable (String, Bool) -> Void,
               level: @escaping @MainActor @Sendable (Float) -> Void) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await downloading()
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try? await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw Failure.noLanguage }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        reader = Task {
            do {
                for try await result in transcriber.results { await heard(String(result.text.characters), result.isFinal) }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
        try Task.checkCancellation()

        let node = audio.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0,
              let converter = AVAudioConverter(from: micFormat, to: format) else { throw Failure.noMicrophone }
        node.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            let loudness = Self.loudness(of: buffer)
            Task { @MainActor in level(loudness) }
            if let converted = Self.convert(buffer, with: converter, to: format) { continuation.yield(AnalyzerInput(buffer: converted)) }
        }
        isTapped = true
        audio.prepare()
        try audio.start()
    }

    /// Closes the microphone and waits (at most `limit`) for the recognizer to settle the last words: ↩ while dictating
    /// sends right after this, so a recognizer that does not answer never holds the message.
    func finish(within limit: Duration = .seconds(3)) async {
        closeMicrophone()
        input?.finish()
        let analyzer = analyzer, reader = reader
        let once = OSAllocatedUnfairLock(initialState: false)
        let settled = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let resume: @Sendable (Bool) -> Void = { value in
                if once.withLock({ taken in defer { taken = true }; return !taken }) { done.resume(returning: value) }
            }
            Task {
                try? await analyzer?.finalizeAndFinishThroughEndOfInput()
                await reader?.value
                resume(true)
            }
            Task {
                try? await Task.sleep(for: limit)
                resume(false)
            }
        }
        if !settled { await cancel() }
    }

    /// Stops at once: what was not settled is dropped.
    func cancel() async {
        closeMicrophone()
        input?.finish()
        reader?.cancel()
        await analyzer?.cancelAndFinishNow()
    }

    private func closeMicrophone() {
        guard isTapped else { return }
        isTapped = false
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
    }

    /// The microphone's buffer in the recognizer's format (another rate and sample type).
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    /// How loud a buffer is, 0...1 (its RMS on a scale where speech sits around the middle).
    static func loudness(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return min(1, rms * 8)
    }
}
