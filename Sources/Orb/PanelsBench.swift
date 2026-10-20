#if DEBUG || ORB_DEV_TOOLS
import AppKit
import SwiftUI

/// A measure of how smooth the side panels open and close: `ORB_DATA_DIR=<a copy> ORB_BENCH_PANELS=<rounds> Orb --bench-panels` selects the Orb with
/// the longest conversation, opens and closes the right panel (the inspector, as `AppModel.toggleInspector` does) and the sidebar
/// (the system's `toggleSidebar`, as the toolbar button does) `rounds` times, and prints for each one the frame rate of the animation
/// (display-link ticks in the first 0.4 s, where the panel moves), the worst gap between frames, the frames above 25 ms and the main thread's busiest run-loop turn. The window
/// runs off screen as an accessory app (like `--snapshot`), so it never takes the focus. Only with `ORB_DATA_DIR`; `--bench-panels` is a developer mode (no Keychain, no real data).
/// `ORB_NO_SIZING_TRIM=1` turns `ColumnSizing` off (the "before" of its fix). `ORB_BENCH_EMPTY=1` measures with an empty conversation selected instead, to tell the chat's cost from the rest.
@MainActor
enum PanelsBench {
    /// Whether the bench was asked for (the app then starts as an accessory and keeps its window off screen).
    static var isAsked: Bool {
        let environment = ProcessInfo.processInfo.environment
        return Int(environment["ORB_BENCH_PANELS"] ?? "") ?? 0 > 0 && !(environment["ORB_DATA_DIR"] ?? "").isEmpty
            && CommandLine.arguments.contains("--bench-panels")
    }

    /// Keeps the main window out of sight until the bench is over.
    static func hideWindows() {
        for window in NSApp.windows where window.frame.origin.x > -20_000 && window.canBecomeMain {
            window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000)) // the system pulls it back to a sliver of the screen,
            window.alphaValue = 0 // so it is also made transparent
        }
    }

    static func runIfAsked(_ model: AppModel) async {
        guard isAsked, let rounds = Int(ProcessInfo.processInfo.environment["ORB_BENCH_PANELS"] ?? "") else { return }
        let environment = ProcessInfo.processInfo.environment
        try? await Task.sleep(for: .seconds(4))
        hideWindows()
        let empty = environment["ORB_BENCH_EMPTY"] == "1"
        var counts: [(Bot, Int)] = []
        for bot in model.bots {
            model.selection = .bot(bot.id)
            try? await Task.sleep(for: .milliseconds(300))
            while model.isLoadingConversation(bot.id) { try? await Task.sleep(for: .milliseconds(100)) }
            counts.append((bot, model.transcript(bot.id).count))
        }
        let target = empty ? counts.min { $0.1 < $1.1 }?.0 : counts.max { $0.1 < $1.1 }?.0
        if let target { model.selection = .bot(target.id) }
        let items = counts.first { $0.0.id == target?.id }?.1 ?? 0
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }), let view = window.contentView else {
            FileHandle.standardError.write(Data("bench: no window\n".utf8))
            NSApp.terminate(nil)
            return
        }
        say("screens \(NSScreen.screens.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" }), window screen \(window.screen == nil ? "none" : "some")")
        say("window \(Int(window.frame.width))x\(Int(window.frame.height)) at \(Int(window.frame.origin.x)), visible \(window.isVisible), items \(items)")
        var results: [String: [Run]] = [:]
        for round in 1...rounds {
            for (name, action) in [("inspector close", { model.setInspector(false) }), ("inspector open", { model.setInspector(true) }),
                                   ("sidebar close", { toggleSidebar() }), ("sidebar open", { toggleSidebar() })] as [(String, () -> Void)] {
                let run = await measure(view: view, action: action)
                if round > 1 || rounds == 1 { results[name, default: []].append(run) }
                say(String(format: "round %d %@: %@", round, name, run.summary))
                if environment["ORB_BENCH_GAPS"] == "1" { say("  gaps " + run.gaps.map { String(format: "%.0f", $0) }.joined(separator: " ")) }
            }
        }
        for name in ["inspector close", "inspector open", "sidebar close", "sidebar open"] {
            guard let runs = results[name], !runs.isEmpty else { continue }
            let gaps = runs.flatMap(\.gaps)
            let fps = runs.map(\.fps).reduce(0, +) / Double(runs.count)
            let slow = gaps.isEmpty ? 0 : 100 * Double(gaps.filter { $0 > 25 }.count) / Double(gaps.count)
            say(String(format: "TOTAL %@: %.1f fps, worst frame %.1f ms, %.0f%% of frames above 25 ms, busiest turn %.1f ms (%d frames)",
                       name, fps, gaps.max() ?? 0, slow, runs.map(\.busiest).max() ?? 0, gaps.count))
        }
        NSApp.terminate(nil)
    }

    private static func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    /// The toolbar button's action. The app is not the active one, so there is no key window to route it through; the window's
    /// split view controller (the delegate of its split view) is sent `toggleSidebar` directly, which is what the button does.
    private static func toggleSidebar() {
        func splitViews(in view: NSView) -> [NSSplitView] {
            ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splitViews)
        }
        let views = NSApp.windows.filter { $0.canBecomeMain }.compactMap(\.contentView).flatMap(splitViews)
        if let controller = views.lazy.compactMap({ $0.delegate as? NSSplitViewController }).first {
            controller.toggleSidebar(nil)
        } else {
            say("sidebar: no split view controller (\(views.count) split views, delegates \(views.map { String(describing: type(of: $0.delegate)) }))")
        }
    }

    struct Run {
        var gaps: [Double] = []
        var busiest = 0.0
        var fps: Double { gaps.isEmpty ? 0 : 1000 / (gaps.reduce(0, +) / Double(gaps.count)) }
        var summary: String {
            String(format: "%d frames, %.1f fps, worst %.1f ms, %d above 25 ms, busiest turn %.1f ms", gaps.count, fps, gaps.max() ?? 0,
                   gaps.filter { $0 > 25 }.count, busiest)
        }
    }

    /// Runs `action` and records the display-link ticks and the run-loop turns until the animation (about 0.5 s) is over.
    private static func measure(view: NSView, action: () -> Void) async -> Run {
        let ticker = Ticker()
        let link = view.displayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        var turnStart: CFAbsoluteTime = 0
        let box = Box()
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.afterWaiting, .beforeWaiting]).rawValue, true, 0) { _, activity in
            if activity == .afterWaiting { turnStart = CFAbsoluteTimeGetCurrent() }
            else if turnStart > 0 { box.busiest = max(box.busiest, (CFAbsoluteTimeGetCurrent() - turnStart) * 1000) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let started = CACurrentMediaTime()
        action()
        try? await Task.sleep(for: .milliseconds(900))
        link.invalidate()
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        // Only the ticks of the animation (the panel's curve takes about 0.3 s): after it the link idles at the display's rate.
        var run = Run()
        run.gaps = zip(ticker.times.dropFirst(), ticker.times).filter { $0.0 - started < 0.4 }.map { ($0.0 - $0.1) * 1000 }
        run.busiest = box.busiest
        return run
    }

    private final class Box { var busiest = 0.0 }

    private final class Ticker: NSObject {
        var times: [CFTimeInterval] = []
        @objc func tick(_ link: CADisplayLink) { times.append(link.timestamp) }
    }
}
#endif
