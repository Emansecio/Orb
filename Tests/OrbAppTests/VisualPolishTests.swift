import AppKit
import SwiftUI
import Testing
@testable import Orb

@Suite(.serialized) @MainActor
struct VisualPolishTests {
    let root = TempFolder("OrbVisualPolish")

    @Test func choosingAGroupDoesNotKeepIdleAvatarsRenderingForever() async throws {
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
        await waitUntil("idle choices to settle", timeout: .seconds(12)) {
            let shown = avatars(in: host)
            return !shown.isEmpty && shown.allSatisfy { !$0.isRunning }
        }
    }
}
