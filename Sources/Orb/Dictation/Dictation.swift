import AVFoundation
import Foundation

/// Dictating into one Orb's composer: the microphone button opens it, a second click closes it (what was said stays in
/// the field to be read and sent), ↩ closes it and sends at once, and typing in the field closes it (the typing wins).
/// One dictation at a time, for one Orb.
@MainActor
@Observable
final class Dictation {
    enum Phase: Equatable {
        case idle
        /// Asking for the microphone, opening it.
        case starting
        /// The language's model is being downloaded (once per Mac).
        case downloading
        case listening
        /// The microphone is closed; the last words are being settled.
        case finishing
    }

    private(set) var botID: UUID?
    private(set) var phase: Phase = .idle
    /// How loud the microphone is now (0...1), for the button's ring.
    private(set) var level: Float = 0

    @ObservationIgnored private var capture: AnyObject?
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var text = DictationText()
    /// What was in the field when the microphone opened.
    @ObservationIgnored private var base = ""
    /// The last draft the dictation wrote: a draft that is something else was typed over it.
    @ObservationIgnored private var written: String?
    @ObservationIgnored private var write: (UUID, String) -> Void = { _, _ in }
    @ObservationIgnored private var fail: (UUID, String) -> Void = { _, _ in }

    /// The Mac can dictate here: the recognizer is macOS 26's, and the app must say why it wants the microphone (the
    /// development build, without an Info.plist, would be killed by the system for asking).
    static var isSupported: Bool {
        if showsInSnapshots { return true }
        guard #available(macOS 26, *) else { return false }
        return Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }

    /// Review snapshots draw the button in a build that cannot dictate.
    static var showsInSnapshots = false

    /// For review snapshots: the button and the hint as they are in `phase`, without a microphone.
    func pose(_ phase: Phase, level: Float = 0, for botID: UUID) {
        self.botID = phase == .idle ? nil : botID
        self.phase = phase
        self.level = level
    }

    static let deniedMessage = "O Orb não tem acesso ao microfone. Libere em Ajustes do Sistema → Privacidade e Segurança → Microfone."

    func isActive(for botID: UUID) -> Bool { self.botID == botID && phase != .idle }

    /// Opens the microphone for `botID` (closing another Orb's dictation, keeping its text). `draft` reads the field,
    /// `write` replaces it, `fail` shows why dictation could not start.
    func start(for botID: UUID, vocabulary: [String], draft: String, write: @escaping (UUID, String) -> Void,
               fail: @escaping (UUID, String) -> Void) {
        if self.botID != nil { cancel() }
        guard #available(macOS 26, *) else { return }
        self.botID = botID
        self.write = write
        self.fail = fail
        base = draft
        written = draft
        text = DictationText()
        phase = .starting
        let capture = SpeechCapture()
        self.capture = capture
        starting = Task { [weak self] in
            do {
                guard await Self.microphoneAllowed() else { throw DictationError(Self.deniedMessage) }
                guard let locale = await SpeechCapture.locale() else { throw SpeechCapture.Failure.noLanguage }
                try await capture.start(locale: locale, vocabulary: vocabulary,
                                        downloading: { [weak self] in self?.moved(capture, to: .downloading) },
                                        heard: { [weak self] piece, isFinal, isExact, end in
                                            self?.heard(piece, isFinal: isFinal, isExact: isExact, end: end, from: capture)
                                        },
                                        level: { [weak self] loudness in self?.heard(loudness, from: capture) })
                // Stopped while the microphone was opening: it closes now instead of staying open for nobody.
                guard let self, self.capture === capture, self.phase != .finishing else { return await capture.cancel() }
                self.moved(capture, to: .listening)
            } catch is CancellationError {
                await capture.cancel()
            } catch {
                guard let self, self.capture === capture else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.end()
                self.fail(botID, message)
                await capture.cancel()
            }
        }
    }

    /// Closes the microphone and waits for the last words; they are in the field when this returns.
    func finish() async {
        guard botID != nil, phase != .finishing, #available(macOS 26, *), let capture = capture as? SpeechCapture else { return }
        starting?.cancel()
        phase = .finishing
        level = 0
        await capture.finish()
        guard self.capture === capture else { return }
        end()
    }

    /// Stops at once: what is in the field stays as it is.
    func cancel() {
        guard botID != nil else { return }
        starting?.cancel()
        if #available(macOS 26, *), let capture = capture as? SpeechCapture { Task { await capture.cancel() } }
        end()
    }

    /// The field of `botID` changed by typing: a dictation into it gives way, so the typing is not written over.
    func draftEdited(_ draft: String, for botID: UUID) {
        guard isActive(for: botID), draft != written else { return }
        cancel()
    }

    // MARK: From the recognizer

    private func moved(_ capture: AnyObject, to phase: Phase) {
        guard self.capture === capture, self.phase != .finishing else { return }
        self.phase = phase
    }

    private func heard(_ piece: String, isFinal: Bool, isExact: Bool, end: Double, from capture: AnyObject) {
        guard self.capture === capture, let botID else { return }
        text.take(piece, isFinal: isFinal, isExact: isExact, end: end)
        let draft = DictationText.draft(base: base, spoken: text.whole)
        guard draft != written else { return }
        written = draft
        write(botID, draft)
    }

    private func heard(_ loudness: Float, from capture: AnyObject) {
        guard self.capture === capture, phase == .listening else { return }
        level = loudness
    }

    private func end() {
        capture = nil
        starting = nil
        botID = nil
        phase = .idle
        level = 0
        written = nil
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}

private struct DictationError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
