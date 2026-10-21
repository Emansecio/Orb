import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Orb

// The live screen's feed (docs/TELA-AO-VIVO.md): who streams, when it stops, what is thrown away before it costs anything, what
// is kept. No network and no sleeping: a fake socket per connection, a fake browser, and a clock the test moves by hand.

// MARK: - Fakes

struct LiveDropped: Error {}

final class FakeLiveSocket: LiveSocket {
    let port: Int
    let maxFps: Int
    private let stream: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let closed = LockedBox(false)

    init(port: Int, maxFps: Int) {
        self.port = port
        self.maxFps = maxFps
        (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self, throwing: Error.self)
    }

    func messages() -> AsyncThrowingStream<String, Error> { stream }
    func close() {
        closed.value = true
        continuation.finish()
    }

    var isClosed: Bool { closed.value }
    func send(_ text: String) { continuation.yield(text) }
    /// The connection breaks by itself.
    func drop() { continuation.finish(throwing: LiveDropped()) }
}

final class FakeLiveTransport: LiveTransport {
    private let opened = LockedBox<[FakeLiveSocket]>([])
    var sockets: [FakeLiveSocket] { opened.value }
    func open(port: Int, maxFps: Int) -> any LiveSocket {
        let socket = FakeLiveSocket(port: port, maxFps: maxFps)
        opened.append(socket)
        return socket
    }
}

final class FakeLiveSource: LiveBrowserSource {
    private struct State {
        var generations: [UUID: Int] = [:]
        var ports: [UUID: Int] = [:]
        var sensitive = false
        var handler: (@Sendable (UUID, LivePointer) -> Void)?
        var handlerOnly: UUID?
        var handlerSets = 0
    }
    private let state = LockedBox(State())

    func setBrowser(_ botID: UUID, generation: Int = 1, port: Int = 4001) {
        state.withLock { $0.generations[botID] = generation; $0.ports[botID] = port }
    }
    func removeBrowser(_ botID: UUID) {
        state.withLock { $0.generations[botID] = nil; $0.ports[botID] = nil }
    }
    func setSensitive(_ sensitive: Bool) { state.withLock { $0.sensitive = sensitive } }
    var handler: (@Sendable (UUID, LivePointer) -> Void)? { state.withLock { $0.handler } }
    var pointerOnly: UUID? { state.withLock { $0.handlerOnly } }

    func generation(botID: UUID) -> Int? { state.withLock { $0.generations[botID] } }
    func streamPort(botID: UUID) async throws -> Int? { state.withLock { $0.ports[botID] } }
    func pageLooksSensitive(botID: UUID) -> Bool { state.withLock { $0.sensitive } }
    func setPointerHandler(_ handler: (@Sendable (UUID, LivePointer) -> Void)?, only botID: UUID?) {
        state.withLock { $0.handler = handler; $0.handlerOnly = botID; $0.handlerSets += 1 }
    }
}

/// A clock that only moves when the test says so.
final class ManualLiveClock: LiveClock {
    private struct Waiter: Sendable {
        let continuation: CheckedContinuation<Void, Error>
        let duration: Duration
    }
    private let waiters = LockedBox<[UUID: Waiter]>([:])

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.withLock { $0[id] = Waiter(continuation: continuation, duration: duration) }
                if Task.isCancelled, let waiter = waiters.withLock({ $0.removeValue(forKey: id) }) {
                    waiter.continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            if let waiter = waiters.withLock({ $0.removeValue(forKey: id) }) {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }

    var sleepers: [Duration] { waiters.withLock { $0.values.map(\.duration) } }

    /// Everything that waits wakes up.
    func advance() {
        let all = waiters.withLock { waiters -> [Waiter] in
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        for waiter in all { waiter.continuation.resume() }
    }
}

/// The decoder the hub is given in the tests: the real one, watched, and able to hold the first frame until the test lets go.
final class DecoderProbe: @unchecked Sendable {
    private let widths = LockedBox<[Int]>([])
    private let gate = DispatchSemaphore(value: 0)
    private let holdsFirst: Bool
    private let started = LockedBox(0)

    init(holdsFirst: Bool = false) { self.holdsFirst = holdsFirst }

    var decoder: LiveFrameDecoder {
        { [self] raw in
            let call = started.withLock { count -> Int in count += 1; return count }
            if holdsFirst, call == 1 { gate.wait() }
            let decoded = LiveJPEG.decode(raw)
            if let decoded { widths.append(decoded.frame.image.width) }
            return decoded
        }
    }

    var calls: Int { started.value }
    var decodedWidths: [Int] { widths.value }
    func letGo() { gate.signal() }
}

enum LiveTestJPEG {
    /// A real JPEG; its width tells which frame it is.
    static func make(width: Int, height: Int = 8) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func frameMessage(_ jpeg: Data, seq: Int = 1) -> String {
        """
        {"type":"frame","data":"\(jpeg.base64EncodedString())","seq":\(seq),"metadata":{"deviceWidth":800,"deviceHeight":500,\
        "offsetTop":0,"pageScaleFactor":1,"scrollOffsetX":0,"scrollOffsetY":120,"timestamp":1760000000.5}}
        """
    }

    static func urlMessage(_ url: String) -> String { #"{"type":"url","url":"\#(url)"}"# }
}

/// Polls (a few milliseconds apart) until the condition holds: what runs off the main actor has no other way to be waited for.
@MainActor
func liveUntil(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(4))
    }
    return true
}

@MainActor
final class FrameLog {
    private(set) var frames: [LiveFrame] = []
    func record(_ frame: LiveFrame) { frames.append(frame) }
}

@MainActor
final class LiveRig {
    let source = FakeLiveSource()
    let transport = FakeLiveTransport()
    let clock = ManualLiveClock()
    let probe: DecoderProbe
    let hub: LiveFeedHub

    init(holdsFirstFrame: Bool = false) {
        probe = DecoderProbe(holdsFirst: holdsFirstFrame)
        hub = LiveFeedHub(source: source, transport: transport, clock: clock, decoder: probe.decoder)
    }

    /// An Orb with a browser, optionally with its views already acquired and the socket open.
    func orb(generation: Int = 1, port: Int = 4001) -> UUID {
        let id = UUID()
        source.setBrowser(id, generation: generation, port: port)
        return id
    }

    func opened(_ count: Int) async -> Bool { await liveUntil { transport.sockets.count >= count } }

    func log(_ botID: UUID) -> FrameLog {
        let log = FrameLog()
        _ = hub.store(botID).observeFrames { log.record($0) }
        return log
    }
}

// MARK: - Tests

@MainActor
struct LiveFeedHubTests {
    @Test func nothingIsProcessedOrOpenedWithoutAnAcquire() async {
        let rig = LiveRig()
        let bot = rig.orb()
        _ = rig.hub.store(bot)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.hub.framesProcessed == 0)
        #expect(rig.transport.sockets.isEmpty)
        #expect(rig.source.handler == nil)
        #expect(rig.clock.sleepers.isEmpty)
        #expect(rig.hub.store(bot).phase == .idle)
    }

    @Test func acquireConnectsAndFramesReachTheObserver() async throws {
        let rig = LiveRig()
        let bot = rig.orb(port: 4321)
        let log = rig.log(bot)
        rig.hub.acquire(bot)
        #expect(rig.hub.store(bot).phase == .connecting)
        #expect(await rig.opened(1))
        let socket = try #require(rig.transport.sockets.first)
        #expect(socket.port == 4321)
        #expect(socket.maxFps == 10)
        socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 40)))
        #expect(await liveUntil { log.frames.count == 1 })
        let frame = try #require(log.frames.first)
        #expect(frame.image.width == 40)
        #expect(frame.viewport == CGSize(width: 800, height: 500))
        #expect(frame.scroll == CGPoint(x: 0, y: 120))
        #expect(rig.hub.framesProcessed == 1)
        #expect(rig.hub.store(bot).phase == .live)
        socket.send(LiveTestJPEG.urlMessage("https://loja.example/carrinho"))
        #expect(await liveUntil { rig.hub.store(bot).url == "https://loja.example/carrinho" })
    }

    @Test func onlyTheFirstAcquireConnects() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        rig.hub.acquire(bot)
        rig.hub.acquire(bot, wide: true)
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.transport.sockets.count == 1)
        // Two of the three views leave: the stream stays while one is left.
        rig.hub.release(bot)
        rig.hub.release(bot, wide: true)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(rig.clock.sleepers.isEmpty)
        #expect(!rig.transport.sockets[0].isClosed)
    }

    @Test func releaseClosesTheStreamThreeSecondsLater() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        let socket = rig.transport.sockets[0]
        rig.hub.release(bot)
        #expect(await liveUntil { rig.clock.sleepers == [.seconds(3)] })
        #expect(!socket.isClosed)
        rig.clock.advance()
        #expect(await liveUntil { socket.isClosed })
        #expect(rig.hub.store(bot).phase == .idle)
        #expect(await liveUntil { rig.source.handler == nil })
    }

    @Test func anAcquireInsideTheGraceKeepsTheStream() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        rig.hub.release(bot)
        #expect(await liveUntil { rig.clock.sleepers.count == 1 })
        rig.hub.acquire(bot)
        #expect(await liveUntil { rig.clock.sleepers.isEmpty })   // the grace was cancelled
        rig.clock.advance()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(!rig.transport.sockets[0].isClosed)
        #expect(rig.transport.sockets.count == 1)
    }

    @Test func anotherOrbPausesTheFirstAndResumesItAfter() async throws {
        let rig = LiveRig()
        let first = rig.orb(port: 4001)
        let second = rig.orb(port: 4002)
        let firstLog = rig.log(first)
        rig.hub.acquire(first)
        #expect(await rig.opened(1))
        rig.transport.sockets[0].send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 30)))
        #expect(await liveUntil { firstLog.frames.count == 1 })

        rig.hub.acquire(second)
        #expect(await rig.opened(2))
        #expect(await liveUntil { rig.transport.sockets[0].isClosed })
        #expect(rig.transport.sockets[1].port == 4002)
        #expect(rig.hub.store(first).phase == .paused)
        #expect(rig.hub.store(first).lastFrame?.image.width == 30)   // it keeps its last frame
        #expect(rig.hub.store(second).phase == .connecting)

        // The second Orb's views leave and its grace ends: the first one, still looked at, streams again.
        rig.hub.release(second)
        #expect(await liveUntil { rig.clock.sleepers.count == 1 })
        rig.clock.advance()
        #expect(await rig.opened(3))
        #expect(rig.transport.sockets[2].port == 4001)
        #expect(rig.transport.sockets[1].isClosed)
        #expect(rig.hub.store(second).phase == .idle)
    }

    @Test func theFirstFrameAfterConnectingIsOldAndTheNextIsNot() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        let log = rig.log(bot)
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        let socket = rig.transport.sockets[0]
        socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 20), seq: 1))
        #expect(await liveUntil { log.frames.count == 1 })
        socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 21), seq: 2))
        #expect(await liveUntil { log.frames.count == 2 })
        #expect(log.frames[0].isStale)
        #expect(!log.frames[1].isStale)
    }

    @Test func lateFramesAreDroppedAndTheNewestIsTheOneDelivered() async throws {
        let rig = LiveRig(holdsFirstFrame: true)
        let bot = rig.orb()
        let log = rig.log(bot)
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        let socket = rig.transport.sockets[0]
        socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 10), seq: 1))
        #expect(await liveUntil { rig.probe.calls == 1 })   // the decoder is busy with it
        for index in 1...10 {
            socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 10 + index), seq: 1 + index))
        }
        // Messages are read in order: once this address is seen, the ten frames before it have been through the inbox.
        socket.send(LiveTestJPEG.urlMessage("https://loja.example/fim"))
        #expect(await liveUntil { rig.hub.store(bot).url == "https://loja.example/fim" })
        rig.probe.letGo()
        #expect(await liveUntil { log.frames.count == 2 })
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.probe.decodedWidths == [10, 20])   // one being decoded + the newest of the waiting; nine dropped
        #expect(log.frames.map { $0.image.width } == [10, 20])
        #expect(rig.hub.framesProcessed == 2)
    }

    @Test func aNewLaunchOfTheBrowserReconnectsOnTheNewPort() async throws {
        let rig = LiveRig()
        let bot = rig.orb(generation: 1, port: 5001)
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        rig.transport.sockets[0].send(LiveTestJPEG.urlMessage("https://a.example/"))
        #expect(await liveUntil { rig.hub.store(bot).phase == .live })
        rig.source.setBrowser(bot, generation: 2, port: 5002)
        rig.transport.sockets[0].drop()
        #expect(await rig.opened(2))   // at once: no clock involved
        #expect(rig.transport.sockets[1].port == 5002)
        #expect(rig.clock.sleepers.isEmpty)
        #expect(rig.hub.store(bot).phase != .failed)
    }

    @Test func aVanishedSessionFails() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        rig.source.removeBrowser(bot)
        rig.transport.sockets[0].drop()
        #expect(await liveUntil { rig.hub.store(bot).phase == .failed })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.transport.sockets.count == 1)   // no storm of attempts

        // An Orb that has no browser at all waits for one like for a port, then fails, without opening anything.
        let none = UUID()
        rig.hub.acquire(none)
        for _ in 1...3 {
            #expect(await liveUntil { rig.clock.sleepers.count == 1 })
            rig.clock.advance()
        }
        #expect(await liveUntil { rig.hub.store(none).phase == .failed })
        #expect(rig.clock.sleepers.isEmpty)
        #expect(rig.transport.sockets.count == 1)
    }

    @Test func aCardThatCameBeforeTheBrowserOpenedConnectsWhenItDoes() async throws {
        let rig = LiveRig()
        // The card comes at the Orb's first browser tool, which is still opening the browser.
        let early = UUID()
        rig.hub.acquire(early)
        #expect(await liveUntil { rig.clock.sleepers.count == 1 })
        #expect(rig.hub.store(early).phase == .connecting)
        rig.source.setBrowser(early)
        rig.clock.advance()
        #expect(await rig.opened(1))

    }

    @Test func aStreamThatGaveUpIsAskedAgainByTheOrbsNextAction() async throws {
        let rig = LiveRig()
        let late = UUID()
        rig.hub.acquire(late)
        for _ in 1...3 {
            #expect(await liveUntil { rig.clock.sleepers.count == 1 })
            rig.clock.advance()
        }
        #expect(await liveUntil { rig.hub.store(late).phase == .failed })
        rig.source.setBrowser(late)
        rig.hub.browserActed(late)
        #expect(await rig.opened(1))
        rig.hub.browserActed(late)   // not failed: nothing more
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.transport.sockets.count == 1)
    }

    @Test func aDropWithoutARelaunchRetriesAFewTimesWithPausesAndThenFails() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        rig.hub.acquire(bot)
        for attempt in 1...3 {
            #expect(await rig.opened(attempt))
            rig.transport.sockets[attempt - 1].drop()
            #expect(await liveUntil { rig.clock.sleepers.count == 1 })
            #expect(rig.transport.sockets.count == attempt)   // waits before trying again
            rig.clock.advance()
        }
        #expect(await rig.opened(4))
        rig.transport.sockets[3].drop()
        #expect(await liveUntil { rig.hub.store(bot).phase == .failed })
        #expect(rig.clock.sleepers.isEmpty)
        #expect(rig.transport.sockets.count == 4)
    }

    @Test func aProtectedPageThrowsFramesAwayBeforeDecodingThem() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        rig.source.setSensitive(true)
        let log = rig.log(bot)
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        #expect(rig.hub.store(bot).isProtected)
        let jpeg = LiveTestJPEG.make(width: 33)
        rig.transport.sockets[0].send(LiveTestJPEG.frameMessage(jpeg))
        rig.transport.sockets[0].send(LiveTestJPEG.frameMessage(jpeg, seq: 2))
        rig.transport.sockets[0].send(LiveTestJPEG.urlMessage("https://banco.example/inicio"))
        #expect(await liveUntil { rig.hub.store(bot).url == "https://banco.example/inicio" })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.probe.calls == 0)
        #expect(rig.hub.framesProcessed == 0)
        #expect(log.frames.isEmpty)
        #expect(rig.hub.store(bot).lastFrame == nil)
        // Nothing of it reaches the last-screen cache.
        let item = UUID()
        rig.hub.endUse(bot, itemID: item)
        #expect(rig.hub.lastScreen(of: item) == nil)
    }

    @Test func aLoginAddressProtectsFromThenOnAndDropsTheLastFrame() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        let log = rig.log(bot)
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        let socket = rig.transport.sockets[0]
        socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 25)))
        #expect(await liveUntil { log.frames.count == 1 })
        socket.send(LiveTestJPEG.urlMessage("https://conta.example/login"))
        #expect(await liveUntil { rig.hub.store(bot).isProtected })
        #expect(rig.hub.store(bot).lastFrame == nil)
        let decodedBefore = rig.probe.calls
        socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 26), seq: 2))
        socket.send(LiveTestJPEG.urlMessage("https://conta.example/login?x=1"))
        #expect(await liveUntil { rig.hub.store(bot).url == "https://conta.example/login?x=1" })
        #expect(rig.probe.calls == decodedBefore)
        // The frame from before the login was not kept either.
        let item = UUID()
        rig.hub.endUse(bot, itemID: item)
        #expect(rig.hub.lastScreen(of: item) == nil)
    }

    @Test func aPendingHandoffProtectsAndWhenOverTheStreamIsOpenedAnew() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        rig.transport.sockets[0].send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 25)))
        #expect(await liveUntil { rig.hub.store(bot).lastFrame != nil })
        rig.hub.setHandoffPending(bot, true)
        #expect(rig.hub.store(bot).isProtected)
        #expect(rig.hub.store(bot).lastFrame == nil)
        rig.transport.sockets[0].send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 27), seq: 2))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.hub.store(bot).lastFrame == nil)

        rig.hub.setHandoffPending(bot, false)
        #expect(!rig.hub.store(bot).isProtected)
        #expect(await rig.opened(2))   // the replayed frame fills the card again
        #expect(await liveUntil { rig.transport.sockets[0].isClosed })
        rig.transport.sockets[1].send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 28)))
        #expect(await liveUntil { rig.hub.store(bot).lastFrame?.image.width == 28 })
    }

    @Test func theLastScreenKeepsTenJPEGsInTheWholeApp() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        let socket = rig.transport.sockets[0]
        var items: [UUID] = []
        var jpegs: [Data] = []
        for index in 0..<12 {
            rig.hub.beginUse(bot)
            let jpeg = LiveTestJPEG.make(width: 16 + index)
            socket.send(LiveTestJPEG.frameMessage(jpeg, seq: index))
            #expect(await liveUntil { rig.hub.framesProcessed >= 1 && rig.hub.store(bot).lastFrame?.image.width == 16 + index })
            let item = UUID()
            rig.hub.endUse(bot, itemID: item)
            items.append(item)
            jpegs.append(jpeg)
        }
        #expect(items.prefix(2).allSatisfy { rig.hub.lastScreen(of: $0) == nil })
        for index in 2..<12 {
            // The bytes that came, not a bitmap.
            #expect(rig.hub.lastScreen(of: items[index]) == jpegs[index])
        }
    }

    @Test func framesAfterAUseEndedAndHiddenOnesAreNoUsesLastScreen() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        let socket = rig.transport.sockets[0]
        rig.hub.beginUse(bot)
        socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 20), seq: 1))
        #expect(await liveUntil { rig.hub.store(bot).lastFrame?.image.width == 20 })
        let first = UUID()
        rig.hub.endUse(bot, itemID: first)
        #expect(rig.hub.hasLastScreen(of: first))

        // The seconds the stream stays open after the use: what comes then is not the next use's last screen.
        socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 21), seq: 2))
        #expect(await liveUntil { rig.hub.store(bot).lastFrame?.image.width == 21 })
        rig.hub.beginUse(bot)
        let second = UUID()
        rig.hub.endUse(bot, itemID: second)
        #expect(!rig.hub.hasLastScreen(of: second))

        // "Privado" on: the page is not kept either.
        rig.hub.beginUse(bot)
        socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 22), seq: 3))
        #expect(await liveUntil { rig.hub.store(bot).lastFrame?.image.width == 22 })
        rig.hub.store(bot).isPrivate = true
        let third = UUID()
        rig.hub.endUse(bot, itemID: third)
        #expect(!rig.hub.hasLastScreen(of: third))
    }

    @Test func lookingWhetherALastScreenIsKeptDoesNotMakeItRecent() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        let socket = rig.transport.sockets[0]
        var items: [UUID] = []
        for index in 0..<11 {
            rig.hub.beginUse(bot)
            socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 16 + index), seq: index))
            #expect(await liveUntil { rig.hub.store(bot).lastFrame?.image.width == 16 + index })
            items.append(UUID())
            rig.hub.endUse(bot, itemID: items[index])
            if index == 0 { #expect(rig.hub.hasLastScreen(of: items[0])) }   // a line scrolled past asks this
        }
        #expect(!rig.hub.hasLastScreen(of: items[0]), "still the oldest: the eleventh pushed it out")
        #expect(rig.hub.hasLastScreen(of: items[1]))
    }

    @Test func theBrowserTellsThePointerOnlyOfTheOrbThatStreams() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        #expect(rig.source.pointerOnly == nil)
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        #expect(rig.source.pointerOnly == bot)
        let other = rig.orb(port: 4002)
        rig.hub.acquire(other)
        #expect(await rig.opened(2))
        #expect(rig.source.pointerOnly == other)
    }

    @Test func readingALastScreenKeepsItAndAUseWithoutAFrameKeepsNothing() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        let socket = rig.transport.sockets[0]
        var items: [UUID] = []
        for index in 0..<10 {
            rig.hub.beginUse(bot)
            socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 16 + index), seq: index))
            #expect(await liveUntil { rig.hub.store(bot).lastFrame?.image.width == 16 + index })
            items.append(UUID())
            rig.hub.endUse(bot, itemID: items[index])
        }
        #expect(rig.hub.lastScreen(of: items[0]) != nil)   // the oldest, used again, is now the newest
        rig.hub.beginUse(bot)
        socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 50), seq: 99))
        #expect(await liveUntil { rig.hub.store(bot).lastFrame?.image.width == 50 })
        rig.hub.endUse(bot, itemID: UUID())
        #expect(rig.hub.lastScreen(of: items[0]) != nil)
        #expect(rig.hub.lastScreen(of: items[1]) == nil)

        let empty = UUID()
        rig.hub.endUse(bot, itemID: empty)   // no frame since the last use
        #expect(rig.hub.lastScreen(of: empty) == nil)
    }

    @Test func forgetClosesEverythingAndLetsGoOfTheStore() async throws {
        let rig = LiveRig()
        let first = rig.orb(port: 4001)
        let second = rig.orb(port: 4002)
        rig.hub.acquire(first)
        #expect(await rig.opened(1))
        rig.transport.sockets[0].send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 22)))
        #expect(await liveUntil { rig.hub.store(first).lastFrame != nil })
        let item = UUID()
        rig.hub.endUse(first, itemID: item)
        let oldStore = rig.hub.store(first)
        rig.hub.acquire(second)   // the first is paused
        #expect(await rig.opened(2))
        #expect(await liveUntil { rig.transport.sockets[0].isClosed })

        rig.hub.forget(second)
        #expect(await liveUntil { rig.transport.sockets[1].isClosed })
        #expect(rig.hub.store(second).phase == .idle)   // a fresh store
        // The first Orb was still looked at: it streams again, then goes too.
        #expect(await rig.opened(3))
        rig.hub.forget(first)
        #expect(await liveUntil { rig.transport.sockets[2].isClosed })
        #expect(rig.hub.store(first) !== oldStore)
        #expect(rig.hub.lastScreen(of: item) == nil)
        #expect(await liveUntil { rig.source.handler == nil })
        #expect(rig.clock.sleepers.isEmpty)
    }

    @Test func theOrbsPointerGoesOnlyToTheOrbThatStreams() async throws {
        let rig = LiveRig()
        let streaming = rig.orb()
        let other = rig.orb()
        var seen: [LivePointer] = []
        var otherSeen: [LivePointer] = []
        _ = rig.hub.store(streaming).observePointer { seen.append($0) }
        _ = rig.hub.store(other).observePointer { otherSeen.append($0) }
        rig.hub.acquire(streaming)
        #expect(await rig.opened(1))
        let handler = try #require(rig.source.handler)
        let pointer = LivePointer(rect: CGRect(x: 10, y: 20, width: 30, height: 40), kind: .click)
        handler(other, pointer)
        handler(streaming, pointer)
        #expect(await liveUntil { seen.count == 1 })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(seen == [pointer])
        #expect(otherSeen.isEmpty)
    }

    @Test func theViewportIsTheStatusOneAndAPointerIsCutAtItsEdge() async throws {
        let rig = LiveRig()
        let bot = rig.orb()
        var seen: [LivePointer] = []
        _ = rig.hub.store(bot).observePointer { seen.append($0) }
        let log = rig.log(bot)
        rig.hub.acquire(bot)
        #expect(await rig.opened(1))
        let socket = rig.transport.sockets[0]
        socket.send(#"{"type":"status","connected":true,"screencasting":true,"viewportWidth":1000,"viewportHeight":633}"#)
        socket.send(LiveTestJPEG.frameMessage(LiveTestJPEG.make(width: 48)))   // its metadata says 800 x 500
        #expect(await liveUntil { log.frames.count == 1 })
        #expect(log.frames[0].viewport == CGSize(width: 1000, height: 633))
        #expect(log.frames[0].scroll == CGPoint(x: 0, y: 120))

        let handler = try #require(rig.source.handler)
        handler(bot, LivePointer(rect: CGRect(x: 950, y: 600, width: 100, height: 100), kind: .click))   // half outside
        handler(bot, LivePointer(rect: CGRect(x: 1200, y: 10, width: 50, height: 50), kind: .click))     // all outside
        handler(bot, LivePointer(rect: CGRect(x: 10, y: 10, width: 20, height: 20), kind: .hover))
        #expect(await liveUntil { seen.count == 2 })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(seen == [LivePointer(rect: CGRect(x: 950, y: 600, width: 50, height: 33), kind: .click),
                         LivePointer(rect: CGRect(x: 10, y: 10, width: 20, height: 20), kind: .hover)])
    }

    @Test func theRealTransportAsksForTheLocalStreamWithTheFrameRateCap() throws {
        let socket = URLSessionLiveTransport().open(port: 51955, maxFps: 10)
        defer { socket.close() }
        let real = try #require(socket as? URLSessionLiveSocket)
        #expect(real.url.absoluteString == "ws://127.0.0.1:51955/?maxFps=10")
    }
}
