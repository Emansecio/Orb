#if DEBUG || ORB_DEV_TOOLS
import AppKit

/// A measure of how smooth the chat scrolls: `ORB_DATA_DIR=<a copy> ORB_BENCH_SCROLL=<rounds> Orb --bench-scroll` selects the Orb
/// with the longest conversation, and in each round starts at its end, scrolls up `ORB_BENCH_SCROLL_DISTANCE` points (40.000 by
/// default) at `ORB_BENCH_SCROLL_SPEED` points a second (8.000) and back down, moving the scroll view's clip view on every
/// display-link tick. It prints for each pass the frame rate, the worst gap between frames, the frames above 16,7 and 25 ms, the
/// hitch time (ms of frames missed per second of scrolling) and the main thread's busiest run-loop turn, and at the end the text
/// views alive in the chat. The first pass up is the cold one (the rows are made then); the others go over rows already made.
/// `ORB_BENCH_SCROLL_OPEN=1` opens every run of actions first; `ORB_BENCH_SCROLL_UNFOLD=1` shows what a compaction folded (a
/// compacted chat lists only what came after it). `ORB_BENCH_SCROLL_WIDTH=1` also opens and closes the right panel
/// once the chat has been scrolled, with every row made (each text is measured again at the new width).
/// `ORB_BENCH_SCROLL_EVENTS=<n>` then plays `n` actions of the Orb at the end of the chat (`measureEvents`).
/// The scroll is programmatic: it measures making, laying out and drawing rows, not the scroll phases (`BottomFollowing`).
/// Like `PanelsBench`, the window runs off screen in an accessory app, so it never takes the focus. Only with `ORB_DATA_DIR`;
/// `--bench-scroll` is a developer mode (no Keychain, no real data).
@MainActor
enum ScrollBench {
    /// Whether the bench was asked for (the app then starts as an accessory and keeps its window off screen).
    static var isAsked: Bool {
        let environment = ProcessInfo.processInfo.environment
        return Int(environment["ORB_BENCH_SCROLL"] ?? "") ?? 0 > 0 && !(environment["ORB_DATA_DIR"] ?? "").isEmpty
            && CommandLine.arguments.contains("--bench-scroll")
    }

    static func runIfAsked(_ model: AppModel) async {
        guard isAsked, let rounds = Int(ProcessInfo.processInfo.environment["ORB_BENCH_SCROLL"] ?? "") else { return }
        let environment = ProcessInfo.processInfo.environment
        let distance = Double(environment["ORB_BENCH_SCROLL_DISTANCE"] ?? "") ?? 40_000
        let speed = Double(environment["ORB_BENCH_SCROLL_SPEED"] ?? "") ?? 8_000
        if environment["ORB_BENCH_SCROLL_OPEN"] == "1" { ToolGroupRow.opensInSnapshots = true }
        let unfolds = environment["ORB_BENCH_SCROLL_UNFOLD"] == "1"
        if unfolds { CompactedFoldLine.opensInBench = true }
        try? await Task.sleep(for: .seconds(4))
        PanelsBench.hideWindows()
        // What a compaction folded is not in the list (until its line opens it): the chat measured is the one that shows the most
        // (with `ORB_BENCH_SCROLL_UNFOLD=1`, every item).
        var counts: [(bot: Bot, items: Int, shown: Int)] = []
        for bot in model.bots {
            model.selection = .bot(bot.id)
            try? await Task.sleep(for: .milliseconds(300))
            while model.isLoadingConversation(bot.id) { try? await Task.sleep(for: .milliseconds(100)) }
            let transcript = model.orbTranscript(bot.id)
            counts.append((bot, transcript.items.count, transcript.items.count - (unfolds ? 0 : transcript.fold.count)))
        }
        say("conversations (items, shown after the compaction fold): " + counts.map { "\($0.items)/\($0.shown)" }.joined(separator: ", "))
        // `ORB_BENCH_SCROLL_LONGEST=1`: the chat with the most items instead, folded or not.
        let longest = environment["ORB_BENCH_SCROLL_LONGEST"] == "1"
        guard let (target, _, items) = counts.max(by: { longest ? $0.items < $1.items : $0.shown < $1.shown }) else {
            return finish("bench: no Orb")
        }
        model.selection = .bot(target.id)
        try? await Task.sleep(for: .seconds(2))
        guard let scroll = chatScrollView(), let document = scroll.documentView else { return finish("bench: no chat scroll view") }
        say(String(format: "shown items %d, document %.0f pt, visible %.0f pt, distance %.0f pt at %.0f pt/s", items,
                   document.frame.height, scroll.contentView.bounds.height, distance, speed))
        var results: [String: [Run]] = [:]
        for round in 1...rounds {
            moveToEnd(scroll)
            try? await Task.sleep(for: .milliseconds(500))
            let up = await drive(scroll, by: -distance, speed: speed)
            try? await Task.sleep(for: .milliseconds(500))
            let down = await drive(scroll, by: distance, speed: speed)
            let upName = round == 1 ? "up (cold)" : "up"
            results[upName, default: []].append(up)
            results["down", default: []].append(down)
            say(String(format: "round %d %@: %@", round, upName, up.summary))
            say(String(format: "round %d down: %@", round, down.summary))
        }
        for name in ["up (cold)", "up", "down"] {
            guard let runs = results[name], !runs.isEmpty else { continue }
            say("TOTAL \(name): " + Run(merging: runs).summary)
        }
        say("text views alive: \(textViews(in: document))")
        if let events = Int(environment["ORB_BENCH_SCROLL_EVENTS"] ?? ""), events > 0 {
            moveToEnd(scroll)
            try? await Task.sleep(for: .milliseconds(500))
            await measureEvents(model.orbTranscript(target.id), count: events, on: scroll)
        }
        if environment["ORB_BENCH_SCROLL_WIDTH"] == "1" {
            moveToEnd(scroll)
            try? await Task.sleep(for: .milliseconds(500))
            let open = await measure(for: .milliseconds(600)) { model.setInspector(!model.showInspector) }
            try? await Task.sleep(for: .milliseconds(500))
            let close = await measure(for: .milliseconds(600)) { model.setInspector(!model.showInspector) }
            say("TOTAL panel after scrolling, first: " + open.summary)
            say("TOTAL panel after scrolling, second: " + close.summary)
        }
        NSApp.terminate(nil)
    }

    private static func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    private static func finish(_ text: String) {
        say(text)
        NSApp.terminate(nil)
    }

    /// The chat's scroll view: the tallest scrolling view of the window (as `SwitchBench` finds it).
    private static func chatScrollView() -> NSScrollView? {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        let all = NSApp.windows.filter { $0.canBecomeMain }.compactMap(\.contentView).flatMap(scrollViews)
        return all.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private static func textViews(in view: NSView) -> Int {
        (view is NSTextView ? 1 : 0) + view.subviews.reduce(0) { $0 + textViews(in: $1) }
    }

    /// How far the top of the visible area is from the top of the content, and setting it.
    private static func offset(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return 0 }
        let visible = scroll.contentView.bounds
        return document.isFlipped ? visible.minY : document.frame.height - visible.maxY
    }

    private static func setOffset(_ scroll: NSScrollView, _ offset: CGFloat) {
        guard let document = scroll.documentView else { return }
        let height = scroll.contentView.bounds.height
        let top = min(max(offset, 0), max(document.frame.height - height, 0))
        let y = document.isFlipped ? top : document.frame.height - height - top
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func moveToEnd(_ scroll: NSScrollView) {
        setOffset(scroll, .greatestFiniteMagnitude)
    }

    struct Run {
        var gaps: [Double] = []
        /// The display's frame time, from the link.
        var frame = 1000 / 120.0
        var busiest = 0.0
        var seconds = 0.0

        init() {}

        init(merging runs: [Run]) {
            gaps = runs.flatMap(\.gaps)
            frame = runs.first?.frame ?? frame
            busiest = runs.map(\.busiest).max() ?? 0
            seconds = runs.map(\.seconds).reduce(0, +)
        }

        var fps: Double { gaps.isEmpty ? 0 : 1000 / (gaps.reduce(0, +) / Double(gaps.count)) }
        /// Milliseconds of frames missed per second (a gap of two frames misses one).
        var hitchRatio: Double {
            guard seconds > 0 else { return 0 }
            return gaps.map { max(0, $0 - frame * 1.5) > 0 ? $0 - frame : 0 }.reduce(0, +) / seconds
        }

        private func share(above limit: Double) -> Double {
            gaps.isEmpty ? 0 : 100 * Double(gaps.filter { $0 > limit }.count) / Double(gaps.count)
        }

        var summary: String {
            String(format: "%d frames, %.1f fps, worst %.1f ms, %.1f%% above 16.7 ms, %.1f%% above 25 ms, hitches %.0f ms/s, busiest turn %.1f ms",
                   gaps.count, fps, gaps.max() ?? 0, share(above: 16.7), share(above: 25), hitchRatio, busiest)
        }
    }

    /// Scrolls `distance` points (negative: up) at `speed` points a second, one step per display-link tick, recording the
    /// ticks and the run-loop turns until the distance is covered or the content ends.
    private static func drive(_ scroll: NSScrollView, by distance: Double, speed: Double) async -> Run {
        let start = offset(scroll)
        let duration = abs(distance) / speed
        return await withCheckedContinuation { (continuation: CheckedContinuation<Run, Never>) in
            let recorder = Recorder()
            var began: CFTimeInterval?
            recorder.onTick = { link in
                let now = link.timestamp
                let elapsed = now - (began ?? now)
                if began == nil { began = now }
                let progress = min(elapsed / duration, 1)
                let wanted = start + distance * progress
                setOffset(scroll, wanted)
                // At the top or the end of the content there is nothing left to scroll.
                let reached = abs(offset(scroll) - wanted) > 1 && progress > 0.05
                if progress >= 1 || reached {
                    continuation.resume(returning: recorder.stop(seconds: elapsed))
                }
            }
            recorder.start(on: scroll)
        }
    }

    /// A turn of the Orb's at the end of the chat, without a model: `count` actions, each one a line that arrives and then
    /// changes (a copy of the chat's last action line, 75 ms apart), as the transcript shows them while the Orb works. Prints how
    /// long showing each change took (the transcript's own work) and until its frame was committed (the list's), and the
    /// frames meanwhile; the chat goes back to its own items at the end. Nothing is saved: only what the chat shows changes.
    private static func measureEvents(_ transcript: OrbTranscript, count: Int, on scroll: NSScrollView) async {
        let base = transcript.items
        guard let tool = base.last(where: { if case .tool = $0.kind { true } else { false } }) else {
            return say("events: no action line to copy")
        }
        var items = base
        var shows: [Double] = []
        var frames: [Double] = []
        let recorder = Recorder()
        recorder.start(on: scroll)
        let began = CACurrentMediaTime()
        for _ in 0..<count {
            var line = tool
            line.id = UUID()
            for arrives in [true, false] {
                line.date = .now
                if arrives { items.append(line) } else { items[items.count - 1] = line }
                let start = CACurrentMediaTime()
                transcript.show(items)
                shows.append((CACurrentMediaTime() - start) * 1000)
                await afterNextFrame()
                frames.append((CACurrentMediaTime() - start) * 1000)
                try? await Task.sleep(for: .milliseconds(75))
            }
        }
        let run = recorder.stop(seconds: CACurrentMediaTime() - began)
        transcript.show(base)
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "none" }
            return String(format: "median %.2f ms, p90 %.2f ms, worst %.2f ms", sorted[sorted.count / 2],
                          sorted[min(sorted.count - 1, sorted.count * 9 / 10)], sorted.last ?? 0)
        }
        say("TOTAL events (\(shows.count) changes on \(base.count) items): show \(stats(shows)); until the frame \(stats(frames))")
        say("TOTAL events frames: " + run.summary)
    }

    /// Resumes once the main run loop is about to wait: after the frame the change produced has been committed.
    private static func afterNextFrame() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { observer, _ in
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                continuation.resume()
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// Runs `action` and records the ticks and the run-loop turns for `span`.
    private static func measure(for span: Duration, action: () -> Void) async -> Run {
        guard let scroll = chatScrollView() else { return Run() }
        let recorder = Recorder()
        recorder.start(on: scroll)
        action()
        try? await Task.sleep(for: span)
        return recorder.stop(seconds: Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18)
    }

    @MainActor
    private final class Recorder: NSObject {
        var onTick: ((CADisplayLink) -> Void)?
        private var link: CADisplayLink?
        private var observer: CFRunLoopObserver?
        private var times: [CFTimeInterval] = []
        private var frame = 1 / 120.0
        private var turnStart: CFAbsoluteTime = 0
        private var busiest = 0.0
        private var stopped = false

        func start(on view: NSView) {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.afterWaiting, .beforeWaiting]).rawValue, true, 0) { [weak self] _, activity in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if activity == .afterWaiting { self.turnStart = CFAbsoluteTimeGetCurrent() }
                    else if self.turnStart > 0 { self.busiest = max(self.busiest, (CFAbsoluteTimeGetCurrent() - self.turnStart) * 1000) }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard !stopped else { return }
            times.append(link.timestamp)
            if link.targetTimestamp > link.timestamp { frame = link.targetTimestamp - link.timestamp }
            onTick?(link)
        }

        func stop(seconds: Double) -> Run {
            stopped = true
            onTick = nil
            link?.invalidate()
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            var run = Run()
            run.gaps = zip(times.dropFirst(), times).map { ($0.0 - $0.1) * 1000 }
            run.frame = frame * 1000
            run.busiest = busiest
            run.seconds = seconds
            return run
        }
    }
}
#endif
