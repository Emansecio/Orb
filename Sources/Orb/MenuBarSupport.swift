import SwiftUI
import AppKit
import Carbon.HIToolbox

// The Orb icon in the menu bar: it says whether an Orb is working or waiting for you, and an optional global
// shortcut (⌃⌥Espaço) opens the panel from any app.

/// The icon's pictures, one per state, made once. They are the brand Orb in one ink, drawn as vectors on an 18 pt square
/// (sharp at @1x and @2x), and all are template images: the menu bar tints them white or black as the wallpaper needs.
/// Idle is the Orb's outline with its face solid; working is the Orb filled, its face cut out of it; "waiting for you"
/// is the filled Orb with a solid dot on its rim (a cut-out, not an orange one, since a template cannot keep a color).
@MainActor
enum MenuBarIcon {
    /// The square of the icon, in points.
    static let side: CGFloat = 18

    /// The Orb: a 16 pt circle, centered.
    private static let center = CGPoint(x: 9, y: 9)
    private static let radius: CGFloat = 8
    private static let outlineWidth: CGFloat = 1.2
    private static let smileWidth: CGFloat = 0.9
    /// The badge: a dot on the upper-right rim, behind a clear ring that makes it its own mark.
    private static let badgeCenter = CGPoint(x: 14.8, y: 14.8)
    private static let badgeRadius: CGFloat = 2.8
    private static let badgeRing: CGFloat = 1.2

    private static var cache: [String: NSImage] = [:]

    static func image(for state: MenuBarState) -> NSImage {
        let key: String
        switch state {
        case .idle: key = "idle"
        case .working: key = "working"
        case .waiting: key = "waiting"
        }
        if let cached = cache[key] { return cached }
        let made = make(state)
        cache[key] = made
        return made
    }

    private static func make(_ state: MenuBarState) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            paint(state, in: context)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Only the alpha of the ink counts (the menu bar supplies the color), so it is drawn in black.
    private static func paint(_ state: MenuBarState, in context: CGContext) {
        let ink = CGColor(gray: 0, alpha: 1)
        let disk = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(ink)
        context.setStrokeColor(ink)
        context.setLineCap(.round)

        if state == .idle {
            context.setLineWidth(outlineWidth)
            context.strokeEllipse(in: disk.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2))
            context.addPath(eyes())
            context.fillPath()
            context.setLineWidth(smileWidth)
            context.addPath(smile())
            context.strokePath()
        } else {
            context.fillEllipse(in: disk)
            context.setBlendMode(.clear)
            context.addPath(eyes())
            context.fillPath()
            context.setLineWidth(smileWidth)
            context.addPath(smile())
            context.strokePath()
            context.setBlendMode(.normal)
        }

        if state.hasBadge {
            let dot = CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                             width: badgeRadius * 2, height: badgeRadius * 2)
            context.setBlendMode(.clear)
            context.fillEllipse(in: dot.insetBy(dx: -badgeRing, dy: -badgeRing))
            context.setBlendMode(.normal)
            context.fillEllipse(in: dot)
        }
    }

    /// The two pill eyes, in the proportions of `AppIcon`'s face at its small size (bigger eyes), above the center.
    private static func eyes() -> CGPath {
        let d = radius * 2
        let width = d * 0.081 * 1.3, height = d * 0.15 * 1.3
        let spread = d * 0.151 * 1.12
        let y = center.y + d * 0.08
        let path = CGMutablePath()
        for side in [-1.0, 1.0] as [CGFloat] {
            let rect = CGRect(x: center.x + side * spread - width / 2, y: y - height / 2, width: width, height: height)
            path.addRoundedRect(in: rect, cornerWidth: width / 2, cornerHeight: width / 2)
        }
        return path
    }

    /// The smile under the eyes: the same curve as `AppIcon`'s, its ends higher than its middle.
    private static func smile() -> CGPath {
        let d = radius * 2
        let width = d * 0.15 * 1.15
        let y = center.y - d * 0.085
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - width / 2, y: y + width * 0.12))
        path.addQuadCurve(to: CGPoint(x: center.x + width / 2, y: y + width * 0.12),
                          control: CGPoint(x: center.x, y: y - width * 0.42))
        return path
    }
}

/// The label of the menu bar item. Reads only the lists of working and waiting Orbs.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let state = model.menuBarState
        Image(nsImage: MenuBarIcon.image(for: state))
            .accessibilityLabel(state.accessibilityLabel)
            .help(Tip.menuBarItem)
    }
}

/// Opens or closes the menu bar panel from code. SwiftUI's `MenuBarExtra` has no call for it, so this clicks the
/// status item's own button, which needs no permission. Without it (a future system that names things differently)
/// the app comes forward instead.
@MainActor
enum MenuBarPanel {
    static func toggle() {
        if let button = statusButton() {
            button.performClick(nil)
        } else {
            NSApp.activate()
        }
    }

    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
            if let button = find(in: window.contentView) { return button }
        }
        return nil
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let found = find(in: sub) { return found } }
        return nil
    }
}

/// The optional global shortcut. Registered with Carbon's `RegisterEventHotKey`, which works from any app without
/// Accessibility or Input Monitoring permission. Off until the user turns it on (the menu "Orbs").
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    /// UserDefaults key of the on/off switch (a Settings row can bind to it with `@AppStorage`).
    static let defaultsKey = "quickAskGlobalShortcut"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.defaultsKey) }

    /// At launch: registers it when the user had turned it on. If another app took the keys meanwhile, the switch
    /// goes back to off, so the menu does not claim a shortcut that does nothing.
    func restore() {
        if isEnabled, !apply(true) { UserDefaults.standard.set(false, forKey: Self.defaultsKey) }
    }

    /// Turns the shortcut on or off. False when it was asked on and the system refused (another app has it).
    @discardableResult
    func apply(_ on: Bool) -> Bool {
        if on { return register() }
        unregister()
        return true
    }

    private func register() -> Bool {
        guard hotKey == nil else { return true }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in MenuBarPanel.toggle() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4F52_4258), id: 1) // 'ORBX'
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { hotKey = nil }
        return status == noErr
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    /// The binding for the switch that turns the shortcut on (`stored` is its `@AppStorage`). Another app may already
    /// hold the keys: then the switch stays off and the user is told.
    static func toggleBinding(_ stored: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { stored.wrappedValue },
            set: { wanted in
                let works = shared.apply(wanted)
                stored.wrappedValue = wanted && works
                if wanted && !works { showUnavailableAlert() }
            }
        )
    }

    static func showUnavailableAlert() {
        let alert = NSAlert()
        alert.messageText = "⌃⌥Espaço já é usado por outro app"
        alert.informativeText = "O atalho continua desligado. Feche o outro app ou mude o atalho dele e tente de novo."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
