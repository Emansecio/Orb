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
        /// The Orb's model reads the text over (`DictationReview`); Esc keeps it as it was dictated.
        case reviewing
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
    /// Reads the dictated text over once the microphone closes (nil: no review); nil back keeps the text as it is.
    @ObservationIgnored private var review: (@MainActor (String) async -> String?)?
    /// The closing under way (settling the last words, then the review): a second `finish` waits for it instead of
    /// returning early, so a message sent with ↩ meanwhile goes with the final text.
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private var reviewTask: Task<String?, Never>?
    /// The closing waiting for the review: resumed by its answer, by Esc or typing, or by the time limit, whichever
    /// comes first (a call that hangs never holds the message).
    @ObservationIgnored private var reviewWait: CheckedContinuation<String?, Never>?

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
    /// `write` replaces it, `fail` shows why dictation could not start, `review` reads the text over at the end.
    func start(for botID: UUID, vocabulary: [String], draft: String, write: @escaping (UUID, String) -> Void,
               fail: @escaping (UUID, String) -> Void, review: (@MainActor (String) async -> String?)? = nil) {
        if self.botID != nil { cancel() }
        guard #available(macOS 26, *) else { return }
        self.botID = botID
        self.write = write
        self.fail = fail
        self.review = review
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

    /// Closes the microphone, waits for the last words and for the review; the final text is in the field when this
    /// returns. Called again meanwhile, it waits for the same closing.
    func finish() async {
        if let closing { return await closing.value }
        guard botID != nil, #available(macOS 26, *), let capture = capture as? SpeechCapture else { return }
        starting?.cancel()
        phase = .finishing
        level = 0
        let closing = Task { @MainActor [weak self] in
            await capture.finish()
            guard let self, self.capture === capture else { return }
            await self.reviewText()
            guard self.capture === capture else { return }
            self.end()
        }
        self.closing = closing
        await closing.value
    }

    /// Esc while the text is being read over: it stays as dictated, and the closing ends now.
    func skipReview() {
        guard phase == .reviewing, let reviewTask else { return }
        settleReview(reviewTask, with: nil)
    }

    /// The model reads the dictated words over; what comes back takes their place (what was typed before stays).
    private func reviewText() async {
        let spoken = text.whole.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let review, let botID, DictationReview.isWorthReviewing(spoken) else { return }
        phase = .reviewing
        let task = Task { @MainActor in await review(spoken) }
        reviewTask = task
        let revised = await withCheckedContinuation { wait in
            reviewWait = wait
            Task { @MainActor in self.settleReview(task, with: await task.value) }
            Task { @MainActor in
                try? await Task.sleep(for: DictationReview.timeLimit)
                self.settleReview(task, with: nil)
            }
        }
        guard let revised, self.botID == botID, revised != spoken else { return }
        let draft = DictationText.draft(base: base, spoken: revised)
        written = draft
        write(botID, draft)
    }

    /// The review's answer (nil: keep the text as dictated) to the closing that waits for it, once; a review given up
    /// on is cancelled.
    private func settleReview(_ task: Task<String?, Never>, with revised: String?) {
        guard reviewTask == task, let wait = reviewWait else { return }
        reviewTask = nil
        reviewWait = nil
        if revised == nil { task.cancel() }
        wait.resume(returning: revised)
    }

    /// Stops at once: what is in the field stays as it is.
    func cancel() {
        guard botID != nil else { return }
        starting?.cancel()
        if let reviewTask { settleReview(reviewTask, with: nil) }
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
        guard self.capture === capture, self.phase != .finishing, self.phase != .reviewing else { return }
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
        level = Self.envelope(level, toward: loudness)
    }

    /// The button's halo follows the voice as a meter's needle does: it rises most of the way to a louder buffer at
    /// once, and falls back a quarter of the way per buffer (about ten a second), so it breathes instead of flickering
    /// between syllables.
    nonisolated static func envelope(_ level: Float, toward loudness: Float) -> Float {
        level + (loudness - level) * (loudness > level ? 0.6 : 0.25)
    }

    private func end() {
        capture = nil
        starting = nil
        closing = nil
        if let reviewTask { settleReview(reviewTask, with: nil) }
        review = nil
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
