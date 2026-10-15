#if DEBUG || ORB_DEV_TOOLS
import AppKit

/// A measure of how long changing Orbs takes, for tuning it: `ORB_DATA_DIR=<a copy> ORB_BENCH_SWITCH=<rounds> Orb` opens the
/// window, goes through the Orbs by itself (`rounds` times), prints how long each change kept the main thread before the
/// first frame of the new chat was on screen, and quits. Only with `ORB_DATA_DIR`: never on the user's own data.
@MainActor
enum SwitchBench {
    static func runIfAsked(_ model: AppModel) async {
        let environment = ProcessInfo.processInfo.environment
        guard let rounds = Int(environment["ORB_BENCH_SWITCH"] ?? ""), rounds > 0,
              !(environment["ORB_DATA_DIR"] ?? "").isEmpty else { return }
        try? await Task.sleep(for: .seconds(4)) // the window settles, the first chat loads
        var times: [Double] = []
        var unfocused = 0
        // `ORB_BENCH_COLD=1`: every other conversation is let go before each change, as after five idle minutes.
        let cold = environment["ORB_BENCH_COLD"] == "1"
        if cold { model.conversationKeepAlive = .zero }
        for round in 1...rounds {
            for bot in model.bots {
                if cold { await model.unloadIdleConversations() }
                let start = ContinuousClock.now
                model.selection = .bot(bot.id)
                await afterNextFrame()
                // A conversation read from disk: until it is on screen.
                while model.isLoadingConversation(bot.id) { await afterNextFrame() }
                let elapsed = (ContinuousClock.now - start) / .milliseconds(1)
                if round > 1 || rounds == 1 { times.append(elapsed) }
                try? await Task.sleep(for: .milliseconds(900)) // the cross-fade ends, as when a person switches
                // The new Orb's field has the keys, as after a click on it in the sidebar.
                // (The window's own first responder: the measuring app is not the active one, so it has no key window.)
                let typing = NSApp.windows.contains { $0.isVisible && $0.firstResponder is NSTextView }
                if !typing { unfocused += 1 }
                FileHandle.standardError.write(Data(String(format: "switch round %d %@ %.1f ms%@\n", round, bot.name, elapsed,
                                                           typing ? "" : " (the field has no focus)").utf8))
            }
        }
        let sorted = times.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let worst = sorted.last ?? 0
        FileHandle.standardError.write(Data(String(format: "switch median %.1f ms, worst %.1f ms (%d changes, %d without focus)\n",
                                                   median, worst, sorted.count, unfocused).utf8))
        NSApp.terminate(nil)
    }

    /// Resumes once the main run loop is about to wait: after the frame the change produced has been committed (the
    /// observer runs after Core Animation's own, which commits the frame at the same moment).
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
}

#endif
