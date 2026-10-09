#if DEBUG || ORB_DEV_TOOLS
import SwiftUI
import AppKit
import QuartzCore
import Darwin

/// Dev aid, in debug builds and in release builds made with `-Xswiftc -DORB_DEV_TOOLS` (measure in release):
/// `ORB_ANIMATE_INACTIVE=1 Orb --render-orbs bench <count> [working|typing|waiting|error] [all] [seconds]` hosts live orbs in an
/// invisible window (never activates the app or takes focus), lets them settle for 3 s, then prints the process's
/// CPU time, the main thread's CPU time and instructions retired (`proc_pid_rusage`, reproducible even on a busy
/// machine) over `seconds` (default 20), plus the shared link's ticks and the orbs' frames per second, and exits.
/// `working`: the first orb (96 pt) is thinking; `typing`: it runs a terminal command (the busiest activity); `waiting`:
/// it asks for approval; `error`: it failed (a still orb after its "no"); the rest are idle, unless `all` is there too: then every orb does it (the sidebar rows of Orbs that work are 30 pt).
///
/// With the display asleep (or the session locked) display links never fire, so the bench then stands in for
/// `OrbDriver`: a 240 Hz timer ticks at the rate `OrbLinkRate` picks for the running orbs and steps them in one
/// transaction, exactly like the shared link (same code path and pacing, minus the WindowServer).
@MainActor
enum OrbBench {
    /// The same looks in every build being compared (hair, accessories and a plain one).
    static let looks: [OrbConfig] = [
        OrbConfig(color: "indigo", eyes: "pilulas", mouth: "sorriso", accessories: ["oculos-redondos"]),
        OrbConfig(color: "rosa", eyes: "ovais", cheeks: "blush", hair: "tufinho", accessories: ["laco"]),
        OrbConfig(color: "menta", eyes: "felizes", mouth: "sorriso", cheeks: "sardas", hair: "cachos"),
        OrbConfig(color: "perola", eyes: "pilulas", cheeks: "blush", hair: "franja"),
    ]

    static func run(arguments: [String]) {
        let count = arguments.first.flatMap(Int.init) ?? 1
        let busy: OrbActivity? = ["working": .thinking, "typing": .typing, "waiting": .waiting, "error": .error]
            .first { arguments.contains($0.key) }?.value
        let everyone = arguments.contains("all")
        let seconds = arguments.compactMap(Double.init).dropFirst().first ?? 20
        // Sizes as the app shows them: the chat's empty state, the panel, then sidebar rows.
        let sizes: [CGFloat] = [96, 60] + Array(repeating: 30, count: max(0, count - 2))
        let orbs = (0..<count).map { index in
            (config: looks[index % looks.count], size: sizes[index], activity: index == 0 || everyone ? busy ?? .idle : .idle)
        }
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.fixed(110)), count: 6), spacing: 16) {
            ForEach(Array(orbs.enumerated()), id: \.offset) { _, orb in
                OrbView(config: orb.config, activity: orb.activity, size: orb.size, followsPointer: false)
                    .frame(width: 110, height: 120)
            }
        }
        .padding(20)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 760, height: 480), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: grid.preferredColorScheme(.dark))
        window.orderFrontRegardless()

        let emulated = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        let driver = emulated ? Driver(window: window) : nil
        let main = mach_thread_self()
        Task {
            driver?.start()
            try? await Task.sleep(for: .seconds(3))
            let start = Sample(main: main), ticks = driver?.ticks ?? 0, frames = Self.frames(in: window), draws = Self.draws(in: window)
            try? await Task.sleep(for: .seconds(seconds))
            let end = Sample(main: main)
            let elapsed = end.wall - start.wall
            let tickRate = Double((driver?.ticks ?? 0) - ticks) / elapsed
            let frameRate = Double(Self.frames(in: window) - frames) / elapsed
            let drawRate = Double(Self.draws(in: window) - draws) / elapsed
            let instructions = Double(end.instructions - start.instructions) / elapsed
            print(String(format: "orbs=%d atividade=%@%@ link=%@ s=%.1f cpu=%.2f%% main=%.2f%% instr/s=%.2fM ticks/s=%.1f frames/s=%.1f draws/s=%.1f",
                         count, busy?.rawValue ?? "idle", everyone ? "(todos)" : "", emulated ? "emulado" : "real", elapsed,
                         (end.cpu - start.cpu) / elapsed * 100, (end.mainCPU - start.mainCPU) / elapsed * 100,
                         instructions / 1e6, tickRate, frameRate, drawRate))
            DevRun.finish()
        }
    }

    /// Times the orbs drew so far.
    private static func draws(in window: NSWindow) -> Int {
        Driver.orbViews(in: window.contentView).reduce(0) { $0 + $1.draws }
    }

    /// Frames the orbs stepped so far (read once per sample, not per frame).
    private static func frames(in window: NSWindow) -> Int {
        Driver.orbViews(in: window.contentView).reduce(0) { total, orb in
            total + orb.steps
        }
    }

    /// Stands in for the display: ticks like `OrbDriver` and steps every running orb.
    @MainActor
    private final class Driver {
        private let window: NSWindow
        private var orbs: [OrbAnimationView] = []
        private var timer: Timer?
        private var nextTick = 0.0
        private(set) var ticks = 0

        init(window: NSWindow) { self.window = window }

        func start() {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 240, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.fire() }
            }
        }

        private func fire() {
            if orbs.isEmpty { orbs = Self.orbViews(in: window.contentView) }
            let running = orbs.filter(\.isRunning)
            guard !running.isEmpty else { return }
            let now = CACurrentMediaTime()
            let rate = Double(OrbLinkRate.rate(forOrbsAt: running.map(\.frameRate)))
            guard now >= nextTick - 0.002 else { return }
            nextTick = max(nextTick + 1 / rate, now + 0.5 / rate)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for orb in running { orb.stepIfDue(at: now) }
            CATransaction.commit()
            ticks += 1
        }

        static func orbViews(in view: NSView?) -> [OrbAnimationView] {
            guard let view else { return [] }
            if let orb = view as? OrbAnimationView { return [orb] }
            return view.subviews.flatMap { orbViews(in: $0) }
        }
    }

    private struct Sample {
        let wall: Double, cpu: Double, mainCPU: Double, instructions: UInt64

        init(main: mach_port_t) {
            wall = ProcessInfo.processInfo.systemUptime
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
            }
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let ticks = Double(usage.ri_user_time + usage.ri_system_time)
            cpu = ok == 0 ? ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9 : 0
            instructions = ok == 0 ? usage.ri_instructions : 0
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    thread_info(main, thread_flavor_t(THREAD_BASIC_INFO), $0, &size)
                }
            }
            mainCPU = result == KERN_SUCCESS
                ? Double(info.user_time.seconds + info.system_time.seconds)
                    + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
                : 0
        }
    }
}
#endif
