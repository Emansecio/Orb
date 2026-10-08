import AppKit
import QuartzCore
import Testing
@testable import Orb

/// Where the live orb puts its layers when it is rebuilt: the body (placed only then) and the loose layers (hair and
/// hats, rotated only when their swing changes), with real views in a real window. Part of `OrbDriverTests` so it runs
/// serialized with it: every orb on a screen shares one driver, and those tests count its orbs.
extension OrbDriverTests {
    private func placementWindow(_ content: NSView) -> NSWindow {
        _ = NSApplication.shared
        OrbView.animateInactive = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        window.orderFrontRegardless()
        return window
    }

    private func closePlacement(_ window: NSWindow) {
        window.contentView = NSView()
        window.orderOut(nil)
    }

    private func layers(_ view: OrbAnimationView, _ kind: OrbLayer.Kind) -> [CALayer] {
        view.placedLayersForTesting.filter { $0.layer.kind == kind }.map(\.view)
    }

    @Test func theBodyIsPlacedAgainWhenTheSizeChanges() async throws {
        try #require(NSScreen.main != nil)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let view = OrbAnimationView(frame: NSRect(x: 40, y: 40, width: 120, height: 120))
        let look = OrbConfig(hair: "franja")
        view.configure(config: look, activity: .idle, size: 33, followsPointer: false, interactive: false, live: false)
        content.addSubview(view)
        let win = placementWindow(content)
        defer { closePlacement(win) }
        let scale = win.backingScaleFactor
        for size: CGFloat in [33, 71] {
            view.configure(config: look, activity: .idle, size: size, followsPointer: false, interactive: false, live: false)
            let side = OrbGeometry.imageSide(for: size, scale: scale)
            await waitUntil("layers at \(size) pt") { layers(view, .body).first?.bounds.width == side }
            let body = try #require(layers(view, .body).first)
            #expect(body.position == CGPoint(x: side / 2, y: side / 2), "\(size) pt")
        }
    }

    @Test func aSelectedOrbGlancesOnlyWhileLiveAndThenSettles() async throws {
        try #require(NSScreen.main != nil)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let view = OrbAnimationView(frame: NSRect(x: 40, y: 40, width: 60, height: 60))
        view.configure(config: OrbConfig(), activity: .idle, size: 30, followsPointer: false, interactive: false, live: false)
        content.addSubview(view)
        let win = placementWindow(content)
        defer { closePlacement(win) }
        view.glanceNow()
        #expect(!view.isGlancing) // a paused orb would replay a stale glance when it wakes up
        view.configure(config: OrbConfig(), activity: .idle, size: 30, followsPointer: false, interactive: false, live: true)
        view.glanceNow()
        #expect(view.isGlancing && view.frameRate >= 30)
        var time = CACurrentMediaTime()
        for _ in 0..<30 {
            time += 1.0 / 30
            view.stepIfDue(at: time)
        }
        #expect(!view.isGlancing)
    }

    @Test func looseLayersHangFromTheCrownAndSwingTogetherAfterARebuild() async throws {
        try #require(NSScreen.main != nil)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let view = OrbAnimationView(frame: NSRect(x: 40, y: 40, width: 120, height: 120))
        let tail = OrbConfig(hair: "rabo-de-cavalo")
        view.configure(config: tail, activity: .happy, size: 64, followsPointer: false, interactive: false, live: true)
        content.addSubview(view)
        let win = placementWindow(content)
        defer { closePlacement(win) }
        await waitUntil("the hair placed") { !layers(view, .hair).isEmpty }
        // Hop for a while, so the hair swings.
        var time = CACurrentMediaTime()
        for _ in 0..<45 {
            time += 1.0 / 30
            view.stepIfDue(at: time)
        }
        // A bow joins the loose layers: a rebuild in the middle of the swing.
        view.configure(config: OrbConfig(hair: "rabo-de-cavalo", accessories: ["laco"]), activity: .happy, size: 64,
                       followsPointer: false, interactive: false, live: true)
        await waitUntil("the bow placed") { !layers(view, .accessory).isEmpty }
        time += 1.0 / 30
        view.stepIfDue(at: time)
        let loose = view.placedLayersForTesting.filter { $0.layer.isLoose }.map(\.view)
        #expect(loose.count == 3)   // hair, its shine, the bow
        let crown = 1 - OrbGeometry.crownLine
        #expect(loose.allSatisfy { abs($0.anchorPoint.y - crown) < 1e-9 && $0.anchorPoint.x == 0.5 })
        let first = try #require(loose.first).transform
        #expect(loose.allSatisfy { CATransform3DEqualToTransform($0.transform, first) })
        // The rest of the face doesn't swing.
        #expect(layers(view, .eyes).allSatisfy { $0.anchorPoint.y == 1 - OrbGeometry.eyeLine })
    }
}
