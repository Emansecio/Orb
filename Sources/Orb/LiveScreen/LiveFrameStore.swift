import CoreGraphics
import Foundation
import Observation

// The live screen of an Orb's browser (docs/TELA-AO-VIVO.md): what the views read. Two speeds on purpose. What changes
// rarely (connected or not, the page's host, protected, private) is observed by SwiftUI; the frames and the pointer,
// which change up to sixty times a second, never are: they go straight to the views that registered for them (an NSView
// that swaps its layer's contents), so a frame redraws the thumbnail and nothing else — not the list, not the row, not
// the sidebar.

/// One picture of the page, decoded off the main thread.
struct LiveFrame: @unchecked Sendable {
    let image: CGImage
    /// The page's viewport in CSS pixels (the stream's `status`, not the frame metadata, whose height does not match the image) and how
    /// far it is scrolled. A box from `get box` is already in viewport pixels, scroll taken off: the point on the image is
    /// `box × image size / viewport`, without adding `scroll`.
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
    /// The person took the browser over in the live screen's window: their clicks and keys go to the page, the Orb's tools wait,
    /// and the window shows the page even when it is protected (the thumbnail never does).
    private(set) var isUserInControl = false
    /// The page's width over its height, as its pictures have it: the card in the chat gives the page that shape, so it is shown
    /// whole with no bars. Written only when the shape changes (a new viewport), never per frame.
    private(set) var pageAspect = LiveFrameStore.defaultAspect

    nonisolated static let defaultAspect: CGFloat = 1.6

    /// The shape the card takes for a picture of `width` x `height` pixels: the picture's own, within what a card in the chat can
    /// be (a phone-shaped viewport would make it taller than the window; the picture then fits inside, with bars).
    nonisolated static func aspect(width: Int, height: Int) -> CGFloat {
        guard width > 0, height > 0 else { return defaultAspect }
        return min(max(CGFloat(width) / CGFloat(height), 1.25), 2.2)
    }

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
        if isProtected, !isUserInControl { lastFrame = nil }
    }

    func setUserInControl(_ controls: Bool) {
        guard isUserInControl != controls else { return }
        isUserInControl = controls
        // Handed back on a protected page: what the person saw is not kept for anyone else.
        if !controls, isProtected { lastFrame = nil }
    }

    func deliver(_ frame: LiveFrame) {
        guard !isProtected || isUserInControl else { return }
        lastFrame = frame
        let aspect = Self.aspect(width: frame.image.width, height: frame.image.height)
        if abs(aspect - pageAspect) > 0.005 { pageAspect = aspect }
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
