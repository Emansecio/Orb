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
    static let raised = Color(hex: 0x222222)        // code blocks, chips
    static let agentBubble = Color(hex: 0x262626)
    static let userBubble = Color(hex: 0x5A5A5A)

    // Ink
    static let ink = Color(hex: 0xFCFCFC)
    static let secondary = Color(hex: 0xFCFCFC, opacity: 0.74)
    static let muted = Color(hex: 0xFCFCFC, opacity: 0.6)
    static let faint = Color(hex: 0xFCFCFC, opacity: 0.36)
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
    func shimmer(active: Bool = true) -> some View {
        modifier(Shimmer(active: active))
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
        content.animation(reduceMotion ? nil : .smooth(duration: 0.25), value: value)
    }
}

private struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        if active && reduceMotion {
            content.foregroundStyle(Palette.muted)
        } else if active {
            content
                .foregroundStyle(Palette.faint)
                .overlay {
                    content
                        .foregroundStyle(Palette.ink)
                        .mask {
                            GeometryReader { geometry in
                                LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: geometry.size.width * 0.45)
                                    .offset(x: phase * geometry.size.width)
                            }
                        }
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1.1 }
                }
        } else {
            content
        }
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

/// Subtle filled pill — secondary action.
struct SecondaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.1), in: .capsule)
    }
}

/// Text-only ghost button with hover fill.
struct GhostStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(configuration.isPressed || isHovering ? Palette.ghostSelected : .clear, in: .capsule)
            .onHover { isHovering = $0 }
    }
}
