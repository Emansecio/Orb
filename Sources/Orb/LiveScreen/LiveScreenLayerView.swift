import AppKit
import CoreImage
import SwiftUI

/// The picture of the Orb's page: a layer-backed `NSView` whose layer's `contents` the frames swap in, so a new frame
/// redraws this view and nothing else (no SwiftUI body runs per frame). It registers with the `LiveFrameStore` when it is
/// on screen (a visible window, scrolled into view) and `acquire`s the stream then; leaving the screen, hiding or
/// minimizing the window and leaving the hierarchy `release` it. The Orb's pointer is a layer over the picture.
@MainActor
final class LiveScreenLayerView: NSView {
    private let hub: LiveFeedHub
    private let store: LiveFrameStore
    private let botID: UUID
    private let wide: Bool
    /// The picture is shown whole (the window), not cropped to fill (the card).
    private let fits: Bool

    private let pageLayer = CALayer()
    private let cursorLayer = CALayer()
    private let arrowLayer = CAShapeLayer()
    private let dotLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()

    private var frameToken: UUID?
    private var isAcquired = false
    private var wasWanted = false
    private var shown: LiveFrame?
    private var isPointerPlaced = false
    private weak var clipView: NSClipView?

    /// Frames are drawn. Off for a page the person must not see (the picture is let go, not only covered).
    var showsPage = true {
        didSet {
            guard showsPage != oldValue else { return }
            if showsPage { if let last = store.lastFrame, frameToken != nil { show(last) } } else { clearPage() }
            updatePointerVisibility()
        }
    }
    /// The picture is blurred by Core Animation (the person's "Privado"); if the filter cannot be made, it is not drawn.
    var isBlurred = false {
        didSet {
            guard isBlurred != oldValue else { return }
            updateBlur()
            updatePointerVisibility()
        }
    }
    /// The last picture is shown dimmed (a broken stream or a paused one holds what it had).
    var isDimmed = false {
        didSet {
            guard isDimmed != oldValue, let shown else { return }
            apply(shown)
        }
    }
    var showsPointer = true {
        didSet { if showsPointer != oldValue { updatePointerVisibility() } }
    }
    var pointerColor: NSColor {
        didSet { if pointerColor != oldValue { paintPointer() } }
    }
    /// The person has the browser (the window only): clicks, the wheel and keys go to the page.
    var isInteractive = false {
        didSet {
            guard isInteractive != oldValue else { return }
            if !isInteractive, window?.firstResponder === self { window?.makeFirstResponder(nil) }
            // Taken over with a button: the keys go to the page at once, without a first click on it (which the page would get).
            if isInteractive { window?.makeFirstResponder(self) }
            updateTrackingAreas()
            if let shown { apply(shown) }
        }
    }

    /// For tests: a window that is never on screen answers "visible" (nil: the real answer).
    var visibilityForTests: Bool?
    /// For tests.
    var isShowingFrame: Bool { pageLayer.contents != nil }
    var isStreamAcquired: Bool { isAcquired }
    var isObservingFrames: Bool { frameToken != nil }
    var isPointerVisible: Bool { !cursorLayer.isHidden }
    var pageOpacity: Float { pageLayer.opacity }
    var hasBlurFilter: Bool { pageLayer.filters?.isEmpty == false }

    static let dimmedOpacity: Float = 0.45

    init(hub: LiveFeedHub, botID: UUID, wide: Bool, fits: Bool = false, pointerColor: NSColor) {
        self.hub = hub
        self.store = hub.store(botID)
        self.botID = botID
        self.wide = wide
        self.fits = fits
        self.pointerColor = pointerColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        pageLayer.contentsGravity = fits ? .resizeAspect : .resizeAspectFill
        pageLayer.masksToBounds = true
        layer?.addSublayer(pageLayer)
        buildPointer()
        layer?.addSublayer(ringLayer)
        layer?.addSublayer(cursorLayer)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // A picture to look at lets every click through to the card or the window around it; the page the person drives takes them.
    override func hitTest(_ point: NSPoint) -> NSView? { isInteractive ? super.hitTest(point) : nil }

    // MARK: Pointer layers

    /// The arrow and the dot are drawn once; only the whole `cursorLayer` moves. The tip of the arrow is the anchor.
    private func buildPointer() {
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        cursorLayer.anchorPoint = CGPoint(x: 1.0 / 24, y: 23.0 / 24)
        cursorLayer.isHidden = true
        let arrow = CGMutablePath()
        let points = [(1, 23), (1, 8), (5, 12), (8, 5), (11, 6), (8, 13), (14, 13)].map { CGPoint(x: $0.0, y: $0.1) }
        arrow.addLines(between: points)
        arrow.closeSubpath()
        arrowLayer.path = arrow
        arrowLayer.fillColor = NSColor.white.cgColor
        arrowLayer.strokeColor = NSColor(white: 0.07, alpha: 1).cgColor
        arrowLayer.lineWidth = 1.2
        arrowLayer.lineJoin = .round
        dotLayer.path = CGPath(ellipseIn: CGRect(x: 11, y: 3, width: 10, height: 10), transform: nil)
        dotLayer.strokeColor = NSColor.white.cgColor
        dotLayer.lineWidth = 1.5
        for shape in [arrowLayer, dotLayer] {
            shape.shadowOpacity = 0.35
            shape.shadowRadius = 1.5
            shape.shadowOffset = CGSize(width: 0, height: -1)
            cursorLayer.addSublayer(shape)
        }
        ringLayer.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
        ringLayer.path = CGPath(ellipseIn: ringLayer.bounds, transform: nil)
        ringLayer.fillColor = nil
        ringLayer.lineWidth = 2
        ringLayer.opacity = 0
        paintPointer()
    }

    private func paintPointer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.fillColor = pointerColor.cgColor
        ringLayer.strokeColor = pointerColor.cgColor
        CATransaction.commit()
    }

    private func updatePointerVisibility() {
        let visible = showsPointer && showsPage && !isBlurred && isPointerPlaced
        if !visible { stopPulse() }
        guard cursorLayer.isHidden == visible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = !visible
        CATransaction.commit()
    }

    // MARK: Frames

    private func show(_ frame: LiveFrame) {
        guard showsPage else { return }
        shown = frame
        apply(frame)
    }

    private func apply(_ frame: LiveFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.contents = (isBlurred && !canBlur) ? nil : frame.image
        // The replayed frame is dimmed until a new one comes, except for the person driving: it is the page they are using.
        pageLayer.opacity = (frame.isStale && !isInteractive) || isDimmed ? Self.dimmedOpacity : 1
        CATransaction.commit()
    }

    private func clearPage() {
        shown = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.contents = nil
        CATransaction.commit()
    }

    private var blurRadius: Double { wide ? 24 : 10 }
    private var canBlur = true

    private func updateBlur() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isBlurred {
            let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            canBlur = blur != nil
            pageLayer.filters = blur.map { [$0] }
            layerUsesCoreImageFilters = true
        } else {
            canBlur = true
            pageLayer.filters = nil
            layerUsesCoreImageFilters = false
        }
        CATransaction.commit()
        needsLayout = true
        if let shown { apply(shown) }
    }

    // MARK: The pointer follows the Orb

    private func movePointer(_ pointer: LivePointer) {
        guard showsPointer, showsPage, !isBlurred, let shown, bounds.width > 0,
              let top = LiveCursor.point(of: pointer.rect, viewport: shown.viewport, scroll: shown.scroll,
                                         imageSize: CGSize(width: shown.image.width, height: shown.image.height),
                                         layerSize: bounds.size, fits: fits) else { return }
        let target = CGPoint(x: top.x, y: bounds.height - top.y)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let from = cursorLayer.presentation()?.position ?? cursorLayer.position
        let wasPlaced = isPointerPlaced && !cursorLayer.isHidden
        isPointerPlaced = true
        stopPulse()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = false
        cursorLayer.position = target
        ringLayer.position = target
        CATransaction.commit()
        if !wasPlaced || reduceMotion {
            // First sight, or Reduce Motion: it appears where it is going (a fade, no sliding, no ring).
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = wasPlaced ? 0.4 : 0
            fade.toValue = 1
            fade.duration = Motion.fadeDuration
            cursorLayer.add(fade, forKey: "fade")
            schedulePulse()
            return
        }
        // With the motion setting on, the tool waits `LiveMotion.travel` for the cursor to arrive, so the slide lasts the same and
        // the press (below) happens when the click does. Off, it is the quick slide of before and no wait.
        let animated = LiveMotion.isOn()
        let slide = CABasicAnimation(keyPath: "position")
        slide.fromValue = NSValue(point: from)
        slide.toValue = NSValue(point: target)
        slide.duration = animated ? LiveMotion.travelSeconds : 0.25
        slide.timingFunction = animated ? CAMediaTimingFunction(name: .easeInEaseOut) : CAMediaTimingFunction(controlPoints: 0.3, 0.7, 0.2, 1)
        cursorLayer.add(slide, forKey: "slide")
        if pointer.kind == .click { ripple(after: animated ? slide.duration : 0) }
        if animated {
            if pointer.kind == .click { press(after: slide.duration) }
            schedulePulse()
        }
    }

    /// The ring of a click: grows from a third of its size to a third more and fades, in 0.3 s, starting `delay` from now.
    private func ripple(after delay: CFTimeInterval) {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1.3
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.3
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if delay > 0 { group.beginTime = CACurrentMediaTime() + delay }
        ringLayer.add(group, forKey: "ripple")
    }

    /// The cursor presses down when it arrives: a quick dip of its size about the tip of the arrow, and back.
    private func press(after delay: CFTimeInterval) {
        let dip = CABasicAnimation(keyPath: "transform.scale")
        dip.fromValue = 1
        dip.toValue = 0.8
        dip.duration = 0.08
        dip.autoreverses = true
        dip.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dip.beginTime = CACurrentMediaTime() + delay
        cursorLayer.add(dip, forKey: "press")
    }

    // MARK: The pulse of a thinking Orb

    /// Between two actions of an Orb that is working, a cursor that rests starts to pulse softly (a repeating opacity animation
    /// that Core Animation runs on its own: no timer ticks, no redraws). Any action, leaving the screen, hiding the pointer and Reduce
    /// Motion stop it.
    private var pulseTask: Task<Void, Never>?
    /// How long the cursor rests before it pulses (a test shortens it).
    var pulseDelay = LiveMotion.idleBeforePulse
    /// For tests (an animation of a layer nobody sees is dropped by Core Animation, so its presence says nothing there).
    private(set) var isPulsing = false

    private func schedulePulse() {
        pulseTask?.cancel()
        guard LiveMotion.isOn(), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let delay = pulseDelay
        pulseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.isAcquired, !self.cursorLayer.isHidden else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.45
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.cursorLayer.add(pulse, forKey: "pulse")
            self.isPulsing = true
        }
    }

    private func stopPulse() {
        pulseTask?.cancel()
        pulseTask = nil
        cursorLayer.removeAnimation(forKey: "pulse")
        isPulsing = false
    }

    // MARK: On screen or not

    /// Whether the picture should be fed: in a window that is on screen, not hidden, and scrolled into view.
    nonisolated static func wantsFeed(hasWindow: Bool, windowVisible: Bool, viewHidden: Bool, inView: Bool) -> Bool {
        hasWindow && windowVisible && !viewHidden && inView
    }

    /// Review snapshots draw in a window nobody sees: there, every window counts as on screen.
    nonisolated(unsafe) static var countsOffscreenWindows = false

    private var isOnScreen: Bool {
        if let visibilityForTests { return visibilityForTests && window != nil }
        guard let window else { return false }
        if Self.countsOffscreenWindows { return true }
        let inView = clipView.map { OrbVisibility.isVisible(orb: convert(bounds, to: $0), in: $0.bounds, margin: 20) } ?? true
        return Self.wantsFeed(hasWindow: true, windowVisible: window.isVisible && window.occlusionState.contains(.visible),
                              viewHidden: isHiddenOrHasHiddenAncestor, inView: inView)
    }

    /// Registers and acquires while on screen; lets go of both otherwise. Cheap when nothing changed (it runs on scrolling).
    @objc func refresh() {
        let wanted = isOnScreen
        guard wanted != wasWanted else { return }
        wasWanted = wanted
        if wanted {
            if frameToken == nil {
                frameToken = store.observeFrames { [weak self] frame in self?.show(frame) }
                pointerToken = store.observePointer { [weak self] pointer in self?.movePointer(pointer) }
            }
            if !isAcquired {
                isAcquired = true
                hub.acquire(botID, wide: wide)
            }
        } else {
            letGo()
        }
    }

    /// Stops listening and gives the feed back (what `refresh` does when the view leaves the screen).
    private func letGo() {
        unregister()
        if isAcquired {
            isAcquired = false
            hub.release(botID, wide: wide)
        }
    }

    private var pointerToken: UUID?
    /// When the last hover went to the page (`mouseMoved`), so they go at a steady pace.
    var lastMoveSent: TimeInterval = 0
    /// The dead key or composition the Mac is holding, not yet typed (`NSTextInputClient`, below).
    var markedText = ""
    /// Keys whose down went through the input context (a dead key and the letter it composed): their key up stays here too.
    var composedKeys: Set<UInt16> = []

    private func unregister() {
        stopPulse()
        if let frameToken { store.removeObserver(frameToken) }
        if let pointerToken { store.removeObserver(pointerToken) }
        frameToken = nil
        pointerToken = nil
    }

    /// Called when SwiftUI takes the view away: everything is let go at once.
    func detach() {
        wasWanted = false
        letGo()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let newWindow {
            center.addObserver(self, selector: #selector(refresh), name: NSWindow.didChangeOcclusionStateNotification, object: newWindow)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScrolling()
        if let scale = window?.backingScaleFactor { pageLayer.contentsScale = scale }
        refresh()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeScrolling()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refresh()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor { pageLayer.contentsScale = scale }
    }

    /// The scroll view this lives in (the chat): a card scrolled out of sight stops being fed, like the shimmer.
    private func observeScrolling() {
        let clip = window == nil ? nil : enclosingScrollView?.contentView
        guard clip !== clipView else { return }
        let center = NotificationCenter.default
        if let clipView { center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView) }
        clipView = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: clip)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Blurred, the picture reaches past the edges, so the blur does not fade out toward them.
        let reach = isBlurred ? blurRadius * 2 : 0
        pageLayer.frame = bounds.insetBy(dx: -reach, dy: -reach)
        CATransaction.commit()
        // On entering the window it had no size yet, so it was not "in view": a chat that does not scroll would never feed it.
        refresh()
    }
}

// MARK: - The person's input

extension LiveScreenLayerView {
    override var acceptsFirstResponder: Bool { isInteractive }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isInteractive }

    /// Where an event is on the page, in its CSS pixels; nil off the picture or before the first one.
    private func pagePoint(of event: NSEvent, clamped: Bool = false) -> CGPoint? {
        guard let shown else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        return LiveInput.pagePoint(CGPoint(x: local.x, y: bounds.height - local.y), layerSize: bounds.size,
                                   imageSize: CGSize(width: shown.image.width, height: shown.image.height), viewport: shown.viewport,
                                   clamped: clamped)
    }

    private func sendMouse(_ kind: LiveInput.MouseEvent, _ event: NSEvent, button: LiveInput.MouseButton, clickCount: Int = 0) {
        // A release off the picture is clamped to its edge: dropping it would leave the page's button pressed.
        guard isInteractive, let point = pagePoint(of: event, clamped: kind == .released) else { return }
        hub.send(LiveInput.mouse(kind, at: point, button: button, clickCount: clickCount, modifiers: event.modifierFlags), to: botID)
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        sendMouse(.pressed, event, button: .left, clickCount: event.clickCount)
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractive else { return super.mouseUp(with: event) }
        sendMouse(.released, event, button: .left, clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractive else { return super.mouseDragged(with: event) }
        sendMouse(.moved, event, button: .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isInteractive else { return super.rightMouseDown(with: event) }
        window?.makeFirstResponder(self)
        sendMouse(.pressed, event, button: .right, clickCount: event.clickCount)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isInteractive else { return super.rightMouseUp(with: event) }
        sendMouse(.released, event, button: .right, clickCount: event.clickCount)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isInteractive else { return super.mouseMoved(with: event) }
        // Hovering opens menus and shows tips on the page; at most about 30 moves a second go out.
        let now = event.timestamp
        guard now - lastMoveSent >= 1.0 / 30 else { return }
        lastMoveSent = now
        sendMouse(.moved, event, button: .none)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isInteractive, let shown, let point = pagePoint(of: event) else { return super.scrollWheel(with: event) }
        let perPoint = LiveInput.pagePixelsPerPoint(layerSize: bounds.size, imageSize: CGSize(width: shown.image.width, height: shown.image.height),
                                                    viewport: shown.viewport)
        let delta = LiveInput.wheelDelta(scrollingDeltaX: event.scrollingDeltaX, scrollingDeltaY: event.scrollingDeltaY,
                                         precise: event.hasPreciseScrollingDeltas, pixelsPerPoint: perPoint)
        guard delta.dx != 0 || delta.dy != 0 else { return }
        hub.send(LiveInput.mouse(.wheel, at: point, button: .none, modifiers: event.modifierFlags, delta: delta), to: botID)
    }

    override func keyDown(with event: NSEvent) {
        // A dead key (no characters of its own) and the key after it go through the input context, so "´" + "a" is "á" and
        // `insertText` sends the result. Every other key keeps its key down and up: pages read them (shortcuts, games).
        if isInteractive, LiveInput.usesTextInput(keyCode: event.keyCode, modifiers: event.modifierFlags),
           hasMarkedText() || event.characters?.isEmpty == true {
            composedKeys.insert(event.keyCode)
            if inputContext?.handleEvent(event) != true { super.keyDown(with: event) }
            return
        }
        guard isInteractive,
              let message = LiveInput.key(down: true, keyCode: event.keyCode, characters: event.characters, modifiers: event.modifierFlags)
        else { return super.keyDown(with: event) }
        hub.send(message, to: botID)
    }

    override func keyUp(with event: NSEvent) {
        // The text of a composed key went out whole on key down (see `insertText`); a lone key up would carry the uncomposed key.
        if composedKeys.remove(event.keyCode) != nil { return }
        guard isInteractive,
              let message = LiveInput.key(down: false, keyCode: event.keyCode, characters: event.characters, modifiers: event.modifierFlags)
        else { return super.keyUp(with: event) }
        hub.send(message, to: botID)
    }

    /// ⌘V (Editar → Colar) while the page has the keyboard: the text goes in whole.
    @objc func paste(_ sender: Any?) {
        guard isInteractive, let text = NSPasteboard.general.string(forType: .string) else { return }
        for message in LiveInput.text(text) { hub.send(message, to: botID) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        guard isInteractive else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
}

/// Text input for the page: the Mac composes dead keys and accents, and the result is typed into the page as it is pasted.
extension LiveScreenLayerView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = ""
        guard isInteractive else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        for message in LiveInput.text(text) { hub.send(message, to: botID) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    func unmarkText() { markedText = "" }
    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func markedRange() -> NSRange { markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count) }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    /// Commands of the text system (Delete, arrows…): those keys go by name, so nothing is left to do here.
    override func doCommand(by selector: Selector) {}
}

extension Motion {
    /// `Motion.fade` in seconds, for the layers (Core Animation takes a duration, not an `Animation`).
    static let fadeDuration: CFTimeInterval = 0.15
}

/// The picture in a SwiftUI layout. Nothing here is read per frame: the view takes frames from the store by itself.
struct LiveScreenSurface: NSViewRepresentable {
    let hub: LiveFeedHub
    let botID: UUID
    var wide = false
    /// Shown whole, not cropped (the window).
    var fits = false
    /// The person has the browser: input goes to the page (the window only).
    var isInteractive = false
    var showsPage = true
    var isBlurred = false
    var isDimmed = false
    var showsPointer = true
    var pointerColor: NSColor

    func makeNSView(context: Context) -> LiveScreenLayerView {
        let view = LiveScreenLayerView(hub: hub, botID: botID, wide: wide, fits: fits, pointerColor: pointerColor)
        configure(view)
        return view
    }

    func updateNSView(_ view: LiveScreenLayerView, context: Context) { configure(view) }

    static func dismantleNSView(_ view: LiveScreenLayerView, coordinator: ()) { view.detach() }

    private func configure(_ view: LiveScreenLayerView) {
        view.pointerColor = pointerColor
        view.showsPage = showsPage
        view.isBlurred = isBlurred
        view.isDimmed = isDimmed
        view.showsPointer = showsPointer
        view.isInteractive = isInteractive
    }
}
