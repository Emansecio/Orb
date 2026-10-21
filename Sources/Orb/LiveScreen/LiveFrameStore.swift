import CoreGraphics
import Foundation
import Observation

// The live screen of an Orb's browser (docs/TELA-AO-VIVO.md): what the views read. Two speeds on purpose. What changes
// rarely (connected or not, the page's host, protected, private) is observed by SwiftUI; the frames and the pointer,
// which change up to ten times a second, never are: they go straight to the views that registered for them (an NSView
// that swaps its layer's contents), so a frame redraws the thumbnail and nothing else — not the list, not the row, not
// the sidebar.

/// One picture of the page, decoded off the main thread.
struct LiveFrame: @unchecked Sendable {
    let image: CGImage
    /// The page's viewport in CSS pixels, and how far it is scrolled: what turns a box on the page into a point on the image.
    let viewport: CGSize
    let scroll: CGPoint
    /// When the browser painted it.
    let timestamp: Date
    /// The frame the stream replays when one connects: old, so the card shows it dimmed until a new one comes.
    let isStale: Bool
}

/// Where the Orb is about to act on the page, in the page's CSS pixels.
struct LivePointer: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case click, type, hover }
    let rect: CGRect
    let kind: Kind
}

@MainActor @Observable
final class LiveFrameStore {
    enum Phase: Sendable, Equatable {
        /// No stream: the card shows nothing live (or the last frame, dimmed).
        case idle
        case connecting
        case live
        /// Another Orb's screen is the one streaming now (one at a time).
        case paused
        /// The browser went away or the stream broke.
        case failed
    }

    let botID: UUID
    private(set) var phase = Phase.idle
    /// The page's address as the stream last said it.
    private(set) var url: String?
    /// The page needs the person or shows a secret: nothing of it is shown, and nothing of it is kept.
    private(set) var isProtected = false
    /// Hidden by the person ("Privado"), for this run of the app.
    var isPrivate = false

    @ObservationIgnored private(set) var lastFrame: LiveFrame?
    @ObservationIgnored private var frameObservers: [UUID: (LiveFrame) -> Void] = [:]
    @ObservationIgnored private var pointerObservers: [UUID: (LivePointer) -> Void] = [:]

    init(botID: UUID) { self.botID = botID }

    // MARK: Views

    /// Calls `observer` with every new frame (and at once with the last one, if any); the token removes it.
    func observeFrames(_ observer: @escaping (LiveFrame) -> Void) -> UUID {
        let token = UUID()
        frameObservers[token] = observer
        if let lastFrame { observer(lastFrame) }
        return token
    }

    func observePointer(_ observer: @escaping (LivePointer) -> Void) -> UUID {
        let token = UUID()
        pointerObservers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID) {
        frameObservers[token] = nil
        pointerObservers[token] = nil
    }

    // MARK: The feed (`LiveFeedHub`) writes; each write does nothing when the value is the same

    func setPhase(_ phase: Phase) { if self.phase != phase { self.phase = phase } }
    func setURL(_ url: String?) { if self.url != url { self.url = url } }
    func setProtected(_ isProtected: Bool) {
        guard self.isProtected != isProtected else { return }
        self.isProtected = isProtected
        if isProtected { lastFrame = nil }
    }

    func deliver(_ frame: LiveFrame) {
        guard !isProtected else { return }
        lastFrame = frame
        for observer in frameObservers.values { observer(frame) }
    }

    func point(_ pointer: LivePointer) {
        for observer in pointerObservers.values { observer(pointer) }
    }

    /// The stream ended: the frame is let go.
    func clear() {
        lastFrame = nil
        setPhase(.idle)
    }
}
