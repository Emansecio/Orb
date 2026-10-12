import AVFoundation
import os
import Speech

// Dictation into the composer with the Mac's own speech recognition (SpeechAnalyzer, macOS 26): on the Mac, free, no
// audio leaves it. The model for the language is downloaded by the system once, the first time.

/// What the microphone has given so far. Two recognizers hear the same audio: a quick one, whose words show while they
/// are said, and an exact one, slower and better (punctuation, words it is surer of), whose text takes the place of the
/// quick one over the same stretch of audio as it comes: its draft at the end of each window it hears (about every
/// 11 s), its sentences seconds later. Pure, so the tests can read it.
struct DictationText: Equatable, Sendable {
    struct Sentence: Equatable, Sendable {
        var text: String
        /// Where in the audio it ends, in seconds.
        var end: Double
    }

    /// The exact recognizer's sentences: what stays.
    var settled: [Sentence] = []
    /// The exact recognizer's draft past its last sentence: already punctuated, it may still change.
    var exactDraft: Sentence?
    /// The quick recognizer's sentences past what the exact one has given.
    var quick: [Sentence] = []
    /// What the quick recognizer is still guessing, after its last sentence.
    var guessing = ""
    private var guessEnd = 0.0

    /// Sentences of the two recognizers end within this of each other over the same audio.
    static let slack = 0.3

    var whole: String {
        (settled.map(\.text) + [exactDraft?.text ?? ""] + quick.map(\.text) + [guessing]).reduce("") { Self.joined($0, $1) }
    }

    private var settledEnd: Double { settled.last?.end ?? -1 }
    /// Where in the audio the exact recognizer's text ends, sentences and draft.
    private var exactEnd: Double { max(settledEnd, exactDraft?.end ?? -1) }

    /// A piece from the quick recognizer (`isFinal`: a sentence it will not change) or a sentence from the exact one,
    /// with where it ends in the audio.
    mutating func take(_ text: String, isFinal: Bool, isExact: Bool = false, end: Double) {
        if isExact {
            if isFinal {
                settled.append(Sentence(text: text, end: end))
                if let draft = exactDraft {
                    exactDraft = draft.end <= end + Self.slack ? nil : Self.drafted(draft, after: text)
                }
            } else {
                exactDraft = Sentence(text: text, end: end)
            }
            quick.removeAll { $0.end <= end + Self.slack }
            if guessEnd <= end + Self.slack { guessing = "" }
        } else if isFinal {
            guessing = ""
            if end > exactEnd + Self.slack { quick.append(Sentence(text: text, end: end)) }
        } else {
            guessing = end > exactEnd + Self.slack ? text : ""
            guessEnd = end
        }
    }

    /// The exact draft past a sentence that was just settled out of its beginning: without that sentence (by its text,
    /// or by its count of words when the recognizer reworded it), until the next draft takes its place.
    static func drafted(_ draft: Sentence, after sentence: String) -> Sentence? {
        let settled = sentence.trimmingCharacters(in: .whitespaces)
        var rest: Substring
        if draft.text.hasPrefix(settled) {
            rest = draft.text.dropFirst(settled.count)
        } else {
            let words = settled.split(whereSeparator: \.isWhitespace).count
            rest = Substring(draft.text.split(whereSeparator: \.isWhitespace).dropFirst(words).joined(separator: " "))
        }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : Sentence(text: text, end: draft.end)
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
    private var analyzers: [SpeechAnalyzer] = []
    private var inputs: [AsyncStream<AnalyzerInput>.Continuation] = []
    private var readers: [Task<Void, Never>] = []
    private var isTapped = false

    /// The system's language as the recognizer has it (pt-BR for a Mac in Portuguese), nil when it has none like it.
    static func locale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
    }

    /// Opens the microphone and starts recognizing. `downloading` is called when the language's model must be fetched
    /// first (once per Mac); `heard` gets each piece of text (whether it is final, whether it is the exact recognizer's,
    /// and where it ends in the audio), `level` how loud the microphone is (0...1).
    func start(locale: Locale, vocabulary: [String], downloading: @escaping @MainActor @Sendable () -> Void,
               heard: @escaping @MainActor @Sendable (String, Bool, Bool, Double) -> Void,
               level: @escaping @MainActor @Sendable (Float) -> Void) async throws {
        // The quick one reports as the words are said (without `fastResults` it waits for the end of the speech); the
        // exact one its draft at the end of each window it hears (punctuated) and then its sentences, as good as the
        // recognizer gets. Each has its own analyzer: in one, the quick
        // mode would make both quick.
        let quick = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                                      attributeOptions: [])
        let exact = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [quick, exact]) {
            await downloading()
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [quick, exact]) else { throw Failure.noLanguage }
        var continuations: [AsyncStream<AnalyzerInput>.Continuation] = []
        for (transcriber, isExact) in [(quick, false), (exact, true)] {
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary
                try? await analyzer.setContext(context)
            }
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            analyzers.append(analyzer)
            continuations.append(continuation)
            readers.append(Task {
                do {
                    for try await result in transcriber.results {
                        await heard(String(result.text.characters), result.isFinal, isExact, result.range.end.seconds)
                    }
                } catch {}
            })
            try await analyzer.start(inputSequence: stream)
        }
        inputs = continuations
        recognizerFormat = format
        try Task.checkCancellation()
        guard listensToMicrophone else { return }

        let node = audio.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw Failure.noMicrophone }
        node.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            let loudness = Self.loudness(of: buffer)
            Task { @MainActor in level(loudness) }
            self?.feed(buffer)
        }
        isTapped = true
        audio.prepare()
        try audio.start()
    }

    /// False for the tests, which `feed` the audio themselves.
    var listensToMicrophone = true
    private var recognizerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    /// Hands audio (the microphone's, or a test's) to both recognizers, in their format.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let format = recognizerFormat else { return }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter, let converted = Self.convert(buffer, with: converter, to: format) else { return }
        for input in inputs { input.yield(AnalyzerInput(buffer: converted)) }
    }

    /// Closes the microphone and waits (at most `limit`) for the recognizer to settle the last words: ↩ while dictating
    /// sends right after this, so a recognizer that does not answer never holds the message.
    func finish(within limit: Duration = .seconds(3)) async {
        closeMicrophone()
        inputs.forEach { $0.finish() }
        let analyzers = analyzers, readers = readers
        let once = OSAllocatedUnfairLock(initialState: false)
        let settled = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let resume: @Sendable (Bool) -> Void = { value in
                if once.withLock({ taken in defer { taken = true }; return !taken }) { done.resume(returning: value) }
            }
            Task {
                for analyzer in analyzers { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
                for reader in readers { await reader.value }
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
        inputs.forEach { $0.finish() }
        readers.forEach { $0.cancel() }
        for analyzer in analyzers { await analyzer.cancelAndFinishNow() }
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
