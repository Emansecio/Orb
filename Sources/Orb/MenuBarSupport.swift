import SwiftUI
import AppKit
import Carbon.HIToolbox

// The Orb icon in the menu bar: it says whether an Orb is working or waiting for you, and an optional global
// shortcut (⌃⌥Espaço) opens the panel from any app.

/// The icon's pictures, one per state, made once. All are template images the menu bar tints itself (white or black
/// as the wallpaper needs); "waiting for you" adds a solid dot instead of a color.
@MainActor
enum MenuBarIcon {
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
        let name = state == .idle ? "circle.hexagongrid" : "circle.hexagongrid.fill"
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            ?? NSImage(size: NSSize(width: 18, height: 18))
        guard state.hasBadge else {
            base.isTemplate = true
            return base
        }
        // A template image is tinted by the menu bar itself (white or black as the wallpaper needs), which a hand-colored
        // image cannot follow. So the "waiting for you" badge is a solid dot cut out of the symbol, not an orange one.
        // The dot sits mostly outside the glyph, behind a wide clear ring, so it reads as its own mark and not as one more
        // circle of the symbol.
        let diameter: CGFloat = 8, ring: CGFloat = 2.6
        let glyph = base.size
        let size = NSSize(width: glyph.width + 4, height: glyph.height + 3)
        let picture = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: 0, width: glyph.width, height: glyph.height))
            let dot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: dot.insetBy(dx: -ring, dy: -ring)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        picture.isTemplate = true
        return picture
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
