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
    static let canvas = Color(hex: 0x070707)        // conversation
    static let surface = Color(hex: 0x181818)       // cards, composer
    static let surfaceFocused = Color(hex: 0x1D1D1D) // surface 2 % lighter: the composer while it has the focus
    static let raised = Color(hex: 0x222222)        // code blocks, chips
    static let agentBubble = Color(hex: 0x262626)
    static let userBubble = Color(hex: 0x5A5A5A)

    // Ink
    static let ink = Color(hex: 0xFCFCFC)
    static let secondary = Color(hex: 0xFCFCFC, opacity: 0.74)
    static let muted = Color(hex: 0xFCFCFC, opacity: 0.6)
    /// Quietest ink that still reads as text: about 5.3:1 on `canvas` and 4.9:1 on `chrome` (AA for 11-12 pt).
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

    // Semantic
    static let accent = Color(hex: 0x1084FE)
    static let accentText = Color(hex: 0x459FFE)
    static let ok = Color(hex: 0x00C972)
    static let danger = Color(hex: 0xFF263C)
    static let warn = Color(hex: 0xFF9800)

    // The welcome screen's stage light (the indigo palette's glow, and a cool floor under the Orbs).
    static let stageGlow = Color(hex: 0x6E5CFF)
    static let stageFloor = Color(hex: 0x86DFFF)

    static let conversationFont = Font.system(size: 14)
    /// 22 pt line height at 14 pt.
    static let conversationLineSpacing: CGFloat = 5
}


// MARK: Surfaces

struct CardBackground: ViewModifier {
    var radius: CGFloat = 12
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
    func card(radius: CGFloat = 12, fill: Color = Palette.surface, stroke: Color = Palette.line,
              lineWidth: CGFloat = 1) -> some View {
        modifier(CardBackground(radius: radius, fill: fill, stroke: stroke, lineWidth: lineWidth))
    }

    /// Sweeping highlight across dim text, used for "working" states (steady text under Reduce Motion).
    /// `keepsColors`: for text whose runs have colors of their own (some translucent): they stay as they are
    /// and the band brightens them, instead of the text being redrawn in the shimmer's colors.
    func shimmer(active: Bool = true, keepsColors: Bool = false) -> some View {
        modifier(Shimmer(active: active, keepsColors: keepsColors))
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
    let keepsColors: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && reduceMotion {
            content.foregroundStyle(Palette.muted)
        } else if active && keepsColors {
            // The text stays as it is; the band is only a highlight over it, masked by the text, so the
            // translucent runs gain alpha under the band (as when the text was drawn a second time over itself).
            content.overlay { ShimmerBand(fillsBackground: false).mask { content.foregroundStyle(.white) } }
        } else if active {
            // The text is laid out once, invisibly (it keeps the size and the accessibility label), and
            // drawn through a Core Animation band that sweeps across it: nothing in SwiftUI changes per frame.
            content
                .opacity(0)
                .overlay { ShimmerBand().mask { content.foregroundStyle(.white) } }
        } else {
            content
        }
    }
}

/// Dim fill with a bright band sweeping across it, animated by Core Animation (the render server does the
/// work; the app's main thread does none). Used as the fill of the text it is masked with. The sweep stops
/// while the window is hidden or occluded.
private struct ShimmerBand: NSViewRepresentable {
    /// Dim fill under the band (the text takes its color from it), or only the band.
    var fillsBackground = true

    func makeNSView(context: Context) -> ShimmerBandView { ShimmerBandView(fillsBackground: fillsBackground) }
    func updateNSView(_ view: ShimmerBandView, context: Context) {}
}

final class ShimmerBandView: NSView {
    private let band = CAGradientLayer()
    private var sweptWidth: CGFloat = 0
    private static let animationKey = "sweep"
    /// For tests: whether the band is moving.
    var isSweeping: Bool { band.animation(forKey: Self.animationKey) != nil }

    init(fillsBackground: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        if fillsBackground { layer?.backgroundColor = NSColor(Palette.hint).cgColor }
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
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(updateSweep),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: newWindow)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSweep()
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
        guard visible, bounds.width > 0 else {
            band.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard band.animation(forKey: Self.animationKey) == nil else { return }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = bounds.width * ShimmerSweep.from
        sweep.toValue = bounds.width * ShimmerSweep.to
        sweep.duration = ShimmerSweep.duration
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        // The sweep follows one clock for every band, so a new one (the text changed width) picks up where the
        // last was instead of restarting at the left.
        sweep.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: ShimmerSweep.duration)
        band.add(sweep, forKey: Self.animationKey)
    }
}

// MARK: Buttons

/// White pill — the primary action.
struct PrimaryPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.onInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Palette.ink.opacity(configuration.isPressed ? 0.8 : (isEnabled ? 1 : 0.3)), in: .capsule)
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
            .padding(.vertical, 11)
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

/// Subtle filled pill — secondary action.
struct SecondaryPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.1), in: .capsule)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Round icon button with a circular hover fill: `side` wide (28 in the composer, 32 in the sidebar), the symbol at `fontSize`.
struct CircleGhostStyle: ButtonStyle {
    let side: CGFloat
    let fontSize: CGFloat
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize))
            .frame(width: side, height: side)
            .hoverFill(configuration.isPressed || isHovering, pressed: configuration.isPressed, in: .circle,
                       color: Palette.ghostSelected)
            .contentShape(.circle)
            .onHover { isHovering = $0 }
    }
}

/// Text-only ghost button with hover fill (in fast, out slow: `hoverFill`).
struct GhostStyle: ButtonStyle {
    /// A color for the label instead of the usual gray (red for a destructive action).
    var tint: Color?
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint ?? Palette.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .hoverFill(configuration.isPressed || isHovering, pressed: configuration.isPressed, in: .capsule,
                       color: Palette.ghostSelected)
            .onHover { isHovering = $0 }
    }
}
