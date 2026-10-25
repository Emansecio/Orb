import SwiftUI
import AppKit

// Dark, monochrome theme: near-black neutrals, soft white ink at stepped opacities,
// hairline white strokes, one blue accent. Bots keep their own colorful orbs.

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: opacity))
    }
}

enum Palette {
    // Surfaces (dark tokens: base / subtle / elevated)
    static let chrome = Color(hex: 0x111111)        // sidebar, details pane
    /// The conversation's background as hex, so the text-contrast math (`OrbInk`) uses the same number.
    static let canvasHex: UInt32 = 0x070707
    static let canvas = Color(hex: canvasHex)       // conversation
    static let surface = Color(hex: 0x181818)       // cards, composer
    static let surfaceFocused = Color(hex: 0x1D1D1D) // surface 2 % lighter: the composer while it has the focus
    static let raised = Color(hex: 0x222222)        // code blocks, chips
    /// The person's message. An Orb's reply has no bubble: its words sit on `canvas`, beside its avatar.
    static let userBubble = Color(hex: 0x323232)
    /// A `raised` fill under the pointer (an attachment's card).
    static let raisedHover = Color(hex: 0x262626)

    // Ink
    static let ink = Color(hex: 0xFCFCFC)
    static let secondary = Color(hex: 0xFCFCFC, opacity: 0.74)
    static let muted = Color(hex: 0xFCFCFC, opacity: 0.6)
    /// Quietest ink that still reads as text: about 5.6:1 on `canvas` and on `chrome` (AA for 11-12 pt).
    /// Use it for details, durations, placeholders and section titles.
    static let faint = Color(hex: 0xFCFCFC, opacity: 0.52)
    /// Decorative only (icons that repeat a label, hover hints, dim fills): about 3:1, below what text needs.
    static let hint = Color(hex: 0xFCFCFC, opacity: 0.36)
    static let onInk = Color(hex: 0x141414)          // text on white pills

    // Strokes and fills
    static let line = Color(hex: 0xFCFCFC, opacity: 0.1)
    static let lineStrong = Color(hex: 0xFCFCFC, opacity: 0.15)
    static let ghostHover = Color.white.opacity(0.05)
    static let ghostSelected = Color.white.opacity(0.09)
    /// The resting fill of a small chip or round badge.
    static let chipFill = Color.white.opacity(0.06)
    /// A round icon button under the pointer, and pressed: lighter than `ghostSelected`, which on the canvas (#070707)
    /// reads as almost nothing around a 24 pt symbol.
    static let ghostCircleHover = Color.white.opacity(0.14)
    static let ghostCirclePressed = Color.white.opacity(0.22)

    // Semantic
    static let accent = Color(hex: 0x1084FE)
    static let accentText = Color(hex: 0x459FFE)
    static let ok = Color(hex: 0x00C972)
    /// Red: something ran and failed (a command, a run, a connection, a login), or an action that destroys.
    static let danger = Color(hex: 0xFF263C)
    /// Orange: nothing failed, but it needs you or deserves care (an approval waiting, a sign-in, a risky setting).
    static let warn = Color(hex: 0xFF9800)
    // What a search in the conversation marks: the text it found, and the wash that fades behind the message it brought into view.
    static let findMatch = Color(hex: 0xFF9800, opacity: 0.4)
    static let findWash = Color(hex: 0x1084FE, opacity: 0.16)

    // The welcome screen's stage light (the indigo palette's glow, and a cool floor under the Orbs).
    static let stageGlow = Color(hex: 0x6E5CFF)
    static let stageFloor = Color(hex: 0x86DFFF)

    static let conversationFont = Font.system(size: 14)
    /// 22 pt line height at 14 pt.
    static let conversationLineSpacing: CGFloat = 5
    /// What the Orb says along its work, between the action lines: a step below an answer.
    static let narrationFont = Font.system(size: 13)
    static let narrationLineSpacing: CGFloat = 4
}

/// The small regular sizes the interface repeats, named by role (not `caption`/`body`, which are the system's own styles).
/// Fixed sizes for now: they do not follow the system text size.
enum Typography {
    /// Details, durations, counters and captions.
    static let small = Font.system(size: 11)
    /// Labels, buttons and secondary lines.
    static let label = Font.system(size: 12)
    /// Running text in cards and rows.
    static let text = Font.system(size: 13)
}


/// Shadows under floating cards.
enum Shadow {
    /// Black under a popover, a picker or a floating card.
    static let popover = Color.black.opacity(0.35)
}

// MARK: Spacing

/// The one spacing scale: sheets, cards, forms and action rows take their paddings and gaps from here, so the same
/// distance always looks the same and a footer lines up with the body above it.
enum Spacing {
    /// 2 / 4 / 8 / 12 / 16 / 20 / 24: the steps between icons and labels, rows, cards and sections.
    static let hairline: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24

    /// The sheet's side padding: the body, the header and the footer all use it, so the buttons' right edge is the
    /// content's right edge.
    static let sheetEdge: CGFloat = xl
    static let sheetHeaderTop: CGFloat = 18
    static let sheetHeaderBottom: CGFloat = m
    /// Vertical padding of a sheet's footer (above and below the buttons).
    static let footerVertical: CGFloat = 14
    /// Between two buttons of one row, and between a hint and the buttons.
    static let controlGap: CGFloat = s
    /// Inside a card, and between the parts of a card.
    static let cardPadding: CGFloat = l
    /// Between cards of a grid or a list.
    static let cardSpacing: CGFloat = 14
    /// Between the sections of a page.
    static let section: CGFloat = xxl
    /// A page's outer margin.
    static let page: CGFloat = xxl
    /// The text-only ghost button's side padding: a ghost button at the start of a row hangs this far outside, so its
    /// label (not its invisible hover shape) lines up with the content above.
    static let ghostInset: CGFloat = 12
    /// The width every row icon takes next to its label (a symbol of any width), so the labels line up.
    static let iconColumn: CGFloat = 16
    /// The widest a page's content grows (the lists of skills and connectors, the routines, the gallery).
    static let pageWidth: CGFloat = 980
}

extension View {
    /// A page's content column: centered, no wider than `Spacing.pageWidth`, with the page margin around it, the same
    /// on every page that scrolls.
    func pageColumn() -> some View {
        frame(maxWidth: Spacing.pageWidth).frame(maxWidth: .infinity).padding(Spacing.page)
    }
}

/// The corner radii shared by cards, fields and hover shapes. Other values (1-7, 9, 18) are one-off shapes and stay
/// literal where they are drawn.
enum Radius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 10
    /// The default of `card(radius:)`.
    static let card: CGFloat = 12
    static let large: CGFloat = 14
    /// The person's message, sent or waiting in the queue, in every chat.
    static let bubble: CGFloat = 16
    /// The composer's card.
    static let composer: CGFloat = 20
}

/// Heights of the buttons, so a primary, a secondary and a ghost button in one row are the same height.
enum ControlHeight {
    static let regular: CGFloat = 30
    static let compact: CGFloat = 24
    static let hero: CGFloat = 44
}

// MARK: Surfaces

struct CardBackground: ViewModifier {
    var radius: CGFloat = Radius.card
    var fill: Color = Palette.surface
    var stroke: Color = Palette.line
    var lineWidth: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .background(fill, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(stroke, lineWidth: lineWidth))
    }
}

extension View {
    func card(radius: CGFloat = Radius.card, fill: Color = Palette.surface, stroke: Color = Palette.line,
              lineWidth: CGFloat = 1) -> some View {
        modifier(CardBackground(radius: radius, fill: fill, stroke: stroke, lineWidth: lineWidth))
    }

    /// Sweeping highlight across dim text, used for "working" states (steady text under Reduce Motion).
    /// `pulses`: the text also breathes, softly (a command is running).
    func shimmer(active: Bool = true, pulses: Bool = false) -> some View {
        modifier(Shimmer(active: active, pulses: pulses))
    }

    /// Animates what changes along with `value` (rows appearing, states settling) with the app's one
    /// content curve; instant under Reduce Motion.
    func animateChanges(of value: some Equatable) -> some View {
        modifier(ContentAnimation(value: value))
    }
}

private struct ContentAnimation<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : Motion.content, value: value)
    }
}

/// The sweep of the shimmer, in fractions of the text width: a band `bandWidth` wide travels from `from` to
/// `to` (its leading edge) every `duration` seconds.
enum ShimmerSweep {
    static let bandWidth: CGFloat = 0.45
    static let from: CGFloat = -0.6
    static let to: CGFloat = 1.1
    static let duration: CFTimeInterval = 1.6
}

private struct Shimmer: ViewModifier {
    let active: Bool
    let pulses: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && reduceMotion {
            content.foregroundStyle(Palette.muted)
        } else if active {
            // The text is laid out once, invisibly (it keeps the size and the accessibility label), and
            // drawn through a Core Animation band that sweeps across it: nothing in SwiftUI changes per frame.
            content
                .opacity(0)
                .overlay { ShimmerBand(pulses: pulses).mask { content.foregroundStyle(.white) } }
        } else {
            content
        }
    }
}

/// Dim fill with a bright band sweeping across it, animated by Core Animation (the render server does the
/// work; the app's main thread does none). Used as the fill of the text it is masked with. The sweep stops
/// while the window is hidden or occluded.
private struct ShimmerBand: NSViewRepresentable {
    var pulses = false

    func makeNSView(context: Context) -> ShimmerBandView { ShimmerBandView(fillsBackground: true, pulses: pulses) }
    func updateNSView(_ view: ShimmerBandView, context: Context) { view.pulses = pulses }
}

final class ShimmerBandView: NSView {
    private let band = CAGradientLayer()
    private var sweptWidth: CGFloat = 0
    private static let animationKey = "sweep"
    private static let pulseKey = "pulse"
    /// For tests: whether the band is moving.
    var isSweeping: Bool { band.animation(forKey: Self.animationKey) != nil }
    /// For tests: whether the text breathes.
    var isPulsing: Bool { layer?.animation(forKey: Self.pulseKey) != nil }
    /// The whole text breathes (opacity, done by Core Animation), on top of the sweep.
    var pulses = false {
        didSet {
            guard pulses != oldValue else { return }
            paintFill()
            updateSweep()
        }
    }
    private let fillsBackground: Bool
    private weak var clipView: NSClipView?

    init(fillsBackground: Bool, pulses: Bool = false) {
        self.pulses = pulses
        self.fillsBackground = fillsBackground
        super.init(frame: .zero)
        wantsLayer = true
        paintFill()
        let ink = NSColor(Palette.ink)
        band.colors = [ink.withAlphaComponent(0).cgColor, ink.cgColor, ink.withAlphaComponent(0).cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(band)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.bounds = CGRect(x: 0, y: 0, width: bounds.width * ShimmerSweep.bandWidth, height: bounds.height)
        // The model value is the sweep's start (band out of sight): what a snapshot, which cannot show the
        // animation, draws.
        band.position = CGPoint(x: bounds.width * ShimmerSweep.from, y: bounds.height / 2)
        CATransaction.commit()
        // A new width needs a new sweep; the same width keeps the one running (layout passes are frequent).
        if bounds.width != sweptWidth {
            sweptWidth = bounds.width
            band.removeAnimation(forKey: Self.animationKey)
        }
        updateSweep()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        center.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        if let newWindow {
            center.addObserver(self, selector: #selector(updateSweep),
                               name: NSWindow.didChangeOcclusionStateNotification, object: newWindow)
            // An inactive app shows nothing moving (as the Orbs do): the band and the breath stop and come back with it.
            center.addObserver(self, selector: #selector(updateSweep), name: NSApplication.didBecomeActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(updateSweep), name: NSApplication.didResignActiveNotification, object: nil)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScrolling()
        updateSweep()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeScrolling()
    }

    /// The scroll view this band lives in (the transcript): a band scrolled out of sight stops, and comes back as it
    /// scrolls into view again.
    private func observeScrolling() {
        let clip = window == nil ? nil : enclosingScrollView?.contentView
        guard clip !== clipView else { return }
        let center = NotificationCenter.default
        if let clipView {
            center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView)
        }
        clipView = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(updateSweep), name: NSView.boundsDidChangeNotification, object: clip)
    }

    /// Inside the visible part of its scroll view (a margin of one screen-line keeps it running just past the edge).
    private var isInView: Bool {
        guard let clipView else { return true }
        return OrbVisibility.isVisible(orb: convert(bounds, to: clipView), in: clipView.bounds, margin: 20)
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateSweep()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateSweep()
    }

    @objc private func updateSweep() {
        let visible = window.map { !isHiddenOrHasHiddenAncestor && (OrbView.animateInactive || $0.occlusionState.contains(.visible)) } ?? false
        guard visible, NSApp.isActive || OrbView.animateInactive, isInView, bounds.width > 0 else {
            band.removeAnimation(forKey: Self.animationKey)
            layer?.removeAnimation(forKey: Self.pulseKey)
            return
        }
        updatePulse()
        guard band.animation(forKey: Self.animationKey) == nil else { return }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = bounds.width * ShimmerSweep.from
        sweep.toValue = bounds.width * ShimmerSweep.to
        sweep.duration = ShimmerSweep.duration
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        // A slow sweep of a band of light needs no more than 30 frames a second (24 is already smooth).
        sweep.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        // The sweep follows one clock for every band, so a new one (the text changed width) picks up where the
        // last was instead of restarting at the left.
        sweep.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: ShimmerSweep.duration)
        band.add(sweep, forKey: Self.animationKey)
    }

    /// The dim fill the text takes its color from; a running command's line is a step lighter (it breathes down from it).
    private func paintFill() {
        guard fillsBackground else { return }
        layer?.backgroundColor = NSColor(pulses ? Palette.muted : Palette.hint).cgColor
    }

    /// A slow breath, 1 → 0.55 → 1 in 2.4 s; out of step with the sweep, so the two do not beat together.
    private func updatePulse() {
        guard pulses else {
            layer?.removeAnimation(forKey: Self.pulseKey)
            return
        }
        guard let layer, layer.animation(forKey: Self.pulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.55
        pulse.duration = 1.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 24)
        layer.add(pulse, forKey: Self.pulseKey)
    }
}

// MARK: Buttons

// Which style for a secondary action: a pill (`SecondaryPillStyle`, and `chipButton()` for its small form) for an
// action that does something; `GhostStyle` for one that opens something (a sheet, a page, a list); a `Link` or the
// `.link` style only for an external address.

/// Measures of the pill buttons, which follow the control size: `.small` (the buttons inside cards and rows) is the
/// compact one.
struct PillMetrics {
    let font: Font
    let horizontal: CGFloat
    let height: CGFloat

    static func of(_ size: ControlSize) -> PillMetrics {
        switch size {
        case .mini, .small: PillMetrics(font: .system(size: 12, weight: .medium), horizontal: 11, height: ControlHeight.compact)
        default: PillMetrics(font: .system(size: 13, weight: .medium), horizontal: 14, height: ControlHeight.regular)
        }
    }
}

/// White pill: the primary action.
struct PrimaryPillStyle: ButtonStyle {
    /// Red with white text, for a primary action that destroys something (delete, reset, a risky command): white says
    /// "do this", red says "this cannot be taken back".
    var isDestructive = false
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let metrics = PillMetrics.of(controlSize)
        let pressed = configuration.isPressed
        let hovering = isHovering && isEnabled
        configuration.label
            .pillLabel()
            .font(metrics.font)
            .foregroundStyle(isDestructive ? Color.white : Palette.onInk)
            .padding(.horizontal, metrics.horizontal)
            .frame(minHeight: metrics.height)
            .background {
                // Under the pointer the pill eases a little toward the canvas, pressed a little more; only the fill moves.
                Capsule()
                    .fill(isDestructive ? Palette.danger : Palette.ink)
                    .opacity(pressed ? 0.8 : (!isEnabled ? 0.3 : (hovering ? 0.9 : 1)))
                    .animation(Motion.fill(visible: pressed || hovering, pressed: pressed), value: pressed || hovering)
            }
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
    }
}

/// The one big call to action of the welcome screen: a white pill with a soft indigo halo behind it. The halo grows
/// a little on hover (opacity only, so the render server does it); pressed, the pill shrinks to 0.97. Under Reduce
/// Motion the halo does not animate.
struct HeroPillStyle: ButtonStyle {
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Palette.onInk)
            .padding(.horizontal, 22)
            .frame(minHeight: ControlHeight.hero)
            .background {
                // The halo is the capsule's own shadow in the stage color; only its opacity changes with the hover.
                Capsule()
                    .fill(Palette.ink)
                    .shadow(color: Palette.stageGlow.opacity(isHovering ? 0.5 : 0.35), radius: 16, y: 4)
                    .animation(reduceMotion ? nil : Motion.hover(isHovering), value: isHovering)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
    }
}

/// Subtle filled pill: secondary action.
struct SecondaryPillStyle: ButtonStyle {
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let metrics = PillMetrics.of(controlSize)
        let pressed = configuration.isPressed
        configuration.label
            .pillLabel()
            .font(metrics.font)
            // A destructive one ("Remover todas") says it in red, on the same gray.
            .foregroundStyle(configuration.role == .destructive ? Palette.danger : Palette.ink)
            .padding(.horizontal, metrics.horizontal)
            .frame(minHeight: metrics.height)
            // Resting at 0.1 of white, 0.14 under the pointer, 0.18 pressed (`hoverFill` cross-fades them).
            .hoverFill(pressed || (isHovering && isEnabled), pressed: pressed, in: .capsule,
                       color: Color.white.opacity(pressed ? 0.18 : 0.14), resting: Color.white.opacity(0.1))
            .contentShape(.capsule)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
    }
}

/// Round icon button with a circular hover fill: `side` wide (28 in the composer, 32 in the sidebar), the symbol at `fontSize`.
/// Under the pointer the fill shows and the pointer is a hand; pressed, the fill darkens and the button gives a little.
struct CircleGhostStyle: ButtonStyle {
    let side: CGFloat
    let fontSize: CGFloat
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: fontSize))
            .frame(width: side, height: side)
            .hoverFill(pressed || (isHovering && isEnabled), pressed: pressed, in: .circle,
                       color: pressed ? Palette.ghostCirclePressed : Palette.ghostCircleHover)
            .scaleEffect(pressed && !reduceMotion ? 0.9 : 1)
            .animation(reduceMotion ? nil : Motion.press, value: pressed)
            .contentShape(.circle)
            .onHover { isHovering = $0 }
            .clickablePointer(isEnabled)
    }
}

extension View {
    /// The pointing hand over something that can be clicked. The system sets it and puts the arrow back, also when the
    /// view goes away under the pointer (macOS 15 and later; earlier systems keep the arrow).
    @ViewBuilder func clickablePointer(_ isOn: Bool = true) -> some View {
        if #available(macOS 15, *) { pointerStyle(isOn ? .link : nil) } else { self }
    }
}

/// A small text button that stays gray until the pointer is on it ("Personalizar…" under the Orb's name, "Dizer o que
/// fazer…" beside "Não permitir"): the row keeps its one color, the blue left to what leads elsewhere.
struct QuietTextStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Palette.secondary : isHovering ? Palette.ink : Palette.muted)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(Motion.hover(isHovering), value: isHovering)
    }
}

/// Text-only ghost button with hover fill (in fast, out slow: `hoverFill`).
struct GhostStyle: ButtonStyle {
    /// A color for the label instead of the usual gray. A button with the destructive role is red without it.
    var tint: Color?
    @State private var isHovering = false
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let metrics = PillMetrics.of(controlSize)
        configuration.label
            .pillLabel()
            .font(metrics.font)
            .foregroundStyle(tint ?? (configuration.role == .destructive ? Palette.danger : Palette.secondary))
            .padding(.horizontal, Spacing.ghostInset)
            .frame(minHeight: metrics.height)
            .hoverFill(configuration.isPressed || isHovering, pressed: configuration.isPressed, in: .capsule,
                       color: Palette.ghostSelected)
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// A pill's label is one line at its whole width: squeezed by its row, it broke a word letter by letter ("Rod / ar /
    /// ago / ra") instead of the row giving way. A row too narrow for its buttons picks a shorter form (`ViewThatFits`).
    fileprivate func pillLabel() -> some View { lineLimit(1).fixedSize(horizontal: true, vertical: false) }

    /// A ghost button that starts a row (the destructive one of a footer, the "Não permitir" of a card) hangs
    /// `Spacing.ghostInset` to the left of the row's edge, so its label, not its invisible hover shape, lines up with the
    /// content above. The mirror of it for one that ends a row is `hangsOnTrailingEdge()`.
    func hangsOnLeadingEdge() -> some View { padding(.leading, -Spacing.ghostInset) }
    func hangsOnTrailingEdge() -> some View { padding(.trailing, -Spacing.ghostInset) }
}

/// A button's icon in a fixed-width column, so a row of buttons whose symbols differ in width (a pencil, a speech
/// bubble, a play triangle) keeps its labels at the same distance from the edge.
struct FixedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.xs + Spacing.hairline) {
            configuration.icon.frame(width: Spacing.iconColumn)
            configuration.title
        }
    }
}
