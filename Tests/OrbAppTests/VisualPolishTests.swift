import AppKit
import SwiftUI
import Testing
@testable import Orb

/// Part of `OrbDriverTests` so it runs serialized with it: its window puts avatars on screen, and those tests count
/// the orbs of the one shared driver (in a suite of its own the two ran side by side and those counts went wrong).
extension OrbDriverTests {
    @Test func choosingAGroupDoesNotKeepIdleAvatarsRenderingForever() async throws {
        let root = TempFolder("OrbVisualPolish")
        _ = NSApplication.shared
        try #require(NSScreen.main != nil)
        let previous = OrbView.animateInactive
        OrbView.animateInactive = true
        let model = AppModel(store: Store(directory: root.url), runsBackgroundWork: false)
        let host = NSHostingView(rootView: NewGroupSheet().environment(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.contentView = NSView()
            window.orderOut(nil)
            OrbView.animateInactive = previous
        }
        func avatars(in view: NSView) -> [OrbAnimationView] {
            (view as? OrbAnimationView).map { [$0] } ?? view.subviews.flatMap(avatars)
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            await waitUntil("the group picker's initial animation") { avatars(in: host).contains(where: \.isRunning) }
        }
        let settled = await waitUntil("idle choices to settle", timeout: .seconds(12)) {
            let shown = avatars(in: host)
            return !shown.isEmpty && shown.allSatisfy { !$0.isRunning }
        }
        if !settled {
            // It fails only on the CI, and settles in ~6 s here: say what each avatar was doing, to find out why.
            let states = avatars(in: host).map { "live \($0.live) running \($0.isRunning) steps \($0.steps) fps \($0.frameRate)" }
            Issue.record("""
                \(states.count) avatars: \(states.joined(separator: "; ")); reduce motion \
                \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion); screen \(NSScreen.main?.frame ?? .zero) \
                @\(NSScreen.main?.backingScaleFactor ?? 0)x; window visible \(window.occlusionState.contains(.visible))
                """)
        }
    }
}
