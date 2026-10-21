import CoreGraphics
import Foundation
import ImageIO
import os

// The receiving half of the live screen (docs/TELA-AO-VIVO.md, sections 4 and 5): one WebSocket to the browser's stream, read
// and parsed off the main thread, frames decoded off it too, the late ones dropped. `LiveFeedHub` (main) decides who streams
// and when; this file does the work and tells the hub through a `LiveStreamSink`. Nothing here writes anything anywhere.

// MARK: - Seams (the real ones are in LiveBrowserSource.swift; the tests bring fakes)

/// What the hub needs to know about an Orb's browser.
protocol LiveBrowserSource: Sendable {
    /// The launch the Orb's browser is on (`BrowserDriver.generation`); nil when it has no browser session any more.
    func generation(botID: UUID) -> Int?
    /// The local port of the stream of that browser, read on every connection; nil when it has none (yet).
    func streamPort(botID: UUID) async throws -> Int?
    /// The page needs the person or shows a secret (a login, a code, a captcha, a password field).
    func pageLooksSensitive(botID: UUID) -> Bool
    /// Told about every place the Orb is about to act on, from any thread; nil stops the telling (nobody is looking).
    func setPointerHandler(_ handler: (@Sendable (UUID, LivePointer) -> Void)?)
}

/// One open connection to a stream.
protocol LiveSocket: Sendable {
    /// The text messages, until the connection ends (finished) or breaks (throws). Meant to be read once.
    func messages() -> AsyncThrowingStream<String, Error>
    /// Closes now; safe from any thread and more than once.
    func close()
}

protocol LiveTransport: Sendable {
    /// Starts connecting to the stream on this local port. The stream has one size for everybody (agent-browser 0.39 takes
    /// no width or quality per client), so the panel's larger view shares the connection of the card's.
    func open(port: Int, maxFps: Int) -> any LiveSocket
}

/// Only for waiting (the grace before a release closes the stream, the pause between reconnections), so tests do not sleep.
protocol LiveClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct SystemLiveClock: LiveClock {
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// What the receiving task tells the hub; every call lands on the main actor, in the order they were made.
struct LiveStreamSink: Sendable {
    let phase: @MainActor @Sendable (LiveFrameStore.Phase) -> Void
    let url: @MainActor @Sendable (String?) -> Void
    /// One decoded frame at a time: the receiving side waits for it to be taken, so nothing piles up on the main actor.
    let frame: @MainActor @Sendable (LiveDecodedFrame) -> Void
    let protectionChanged: @MainActor @Sendable () -> Void
}

// MARK: - Frames

/// A frame as it came, still base64: it is decoded only if it is still the newest when the decoder is free.
struct LiveRawFrame: Sendable {
    let base64: String
    let viewport: CGSize
    let scroll: CGPoint
    let timestamp: Date
    let isStale: Bool
}

struct LiveDecodedFrame: Sendable {
    let frame: LiveFrame
    /// The JPEG as it came (what the "last screen" keeps), never the bitmap.
    let jpeg: Data
}

typealias LiveFrameDecoder = @Sendable (LiveRawFrame) -> LiveDecodedFrame?

enum LiveJPEG {
    /// base64 -> Data -> CGImage, decoded right here (`ShouldCacheImmediately`) so drawing it later costs the main thread nothing.
    static func decode(_ raw: LiveRawFrame) -> LiveDecodedFrame? {
        guard let jpeg = Data(base64Encoded: raw.base64),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let viewport = raw.viewport.width > 0 && raw.viewport.height > 0
            ? raw.viewport : CGSize(width: image.width, height: image.height)
        let frame = LiveFrame(image: image, viewport: viewport, scroll: raw.scroll, timestamp: raw.timestamp, isStale: raw.isStale)
        return LiveDecodedFrame(frame: frame, jpeg: jpeg)
    }
}

/// The place between the receiving loop and the decoder: one frame waiting at most, a newer one replaces it (a late frame is
/// not worth decoding), and one decoder running at most. So 1 decoding + 1 waiting, however fast the stream is.
final class LiveInbox: Sendable {
    private struct State {
        var pending: LiveRawFrame?
        var draining = false
        var closed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Leaves a frame; true when the caller has to start the decoder (none is running).
    func submit(_ frame: LiveRawFrame) -> Bool {
        state.withLock { state in
            guard !state.closed else { return false }
            state.pending = frame
            if state.draining { return false }
            state.draining = true
            return true
        }
    }

    /// The decoder's next frame; nil (and the decoder stops) when none waits or the inbox was closed.
    func take() -> LiveRawFrame? {
        state.withLock { state in
            if !state.closed, let frame = state.pending {
                state.pending = nil
                return frame
            }
            state.pending = nil
            state.draining = false
            return nil
        }
    }

    var isClosed: Bool { state.withLock { $0.closed } }

    func close() {
        state.withLock { state in
            state.closed = true
            state.pending = nil
        }
    }
}

// MARK: - Protected pages

/// Whether an Orb's page is one nothing of may be shown or kept: it needs the person (hand-off card pending) or it looks like
/// a login, a code, a captcha or a password field. Readable from any thread, so frames can be thrown away before they are decoded.
final class LiveProtection: Sendable {
    private struct State {
        var sensitive = false
        var addressSensitive = false
        var handoff = false
        var issued = 0
        var applied = 0
        var protected: Bool { sensitive || addressSensitive || handoff }
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isProtected: Bool { state.withLock { $0.protected } }

    /// Asks the browser side; true when that changed whether the page is protected. Two checks at once cannot undo each other:
    /// the one asked later wins, even if it answers first.
    func refresh(_ check: () -> Bool) -> Bool {
        let ticket = state.withLock { state -> Int in
            state.issued += 1
            return state.issued
        }
        let answer = check()
        return state.withLock { state in
            guard ticket > state.applied else { return false }
            state.applied = ticket
            let before = state.protected
            state.sensitive = answer
            return before != state.protected
        }
    }

    /// The address the stream reported, judged by itself (the same rule as the hand-off card's).
    func setAddress(_ url: String) -> Bool {
        let sensitive = BrowserHandoff.reason(url: url, title: "") != nil
        return state.withLock { state in
            let before = state.protected
            state.addressSensitive = sensitive
            return before != state.protected
        }
    }

    /// A hand-off card is waiting for the person.
    func setHandoff(_ pending: Bool) -> Bool {
        state.withLock { state in
            let before = state.protected
            state.handoff = pending
            return before != state.protected
        }
    }
}

// MARK: - What the stream says

/// One JSON message of the stream. Every field but the kind is read on its own, so one odd field does not lose the frame.
struct LiveWireMessage {
    let type: String
    var data: String?
    var viewport = CGSize.zero
    var scroll = CGPoint.zero
    var timestamp: Date?
    var url: String?

    static func parse(_ text: String) -> LiveWireMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        var message = LiveWireMessage(type: type)
        switch type {
        case "frame":
            message.data = object["data"] as? String
            let metadata = object["metadata"] as? [String: Any] ?? [:]
            message.viewport = CGSize(width: number(metadata["deviceWidth"]), height: number(metadata["deviceHeight"]))
            message.scroll = CGPoint(x: number(metadata["scrollOffsetX"]), y: number(metadata["scrollOffsetY"]))
            var stamp = number(metadata["timestamp"])
            if stamp > 1e11 { stamp /= 1000 }   // milliseconds
            if stamp > 1e9 { message.timestamp = Date(timeIntervalSince1970: stamp) }
        case "status":
            message.viewport = CGSize(width: number(object["viewportWidth"]), height: number(object["viewportHeight"]))
        case "url":
            message.url = object["url"] as? String
        default:
            break
        }
        return message
    }

    private static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
}

// MARK: - The connection

/// One run of a stream for one Orb: connects, reads, parses, hands frames to the decoder, and reconnects when the connection
/// drops (at once with the new port if the browser was launched again, otherwise after a growing pause, a few times). It lives in
/// a detached task that the hub cancels; cancelling closes the socket.
struct LiveStreamRunner: Sendable {
    let botID: UUID
    let source: any LiveBrowserSource
    let transport: any LiveTransport
    let clock: any LiveClock
    let protection: LiveProtection
    let inbox: LiveInbox
    let decoder: LiveFrameDecoder
    let sink: LiveStreamSink

    static let maxFps = 10
    /// The pauses before each retry of a connection that failed or dropped; after them, `failed`.
    static let retryDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]
    /// A connection that lasted this long was healthy: its drop starts the count of retries over.
    static let healthyAfter: Duration = .seconds(30)
    /// The sensitive check is repeated every so many frames besides the ones on each address and each action.
    static let checkEvery = 20

    private struct Run {
        var sawMessage = false
        var frames = 0
        var viewport = CGSize.zero
    }

    func run() async {
        var retries = 0
        var again = false
        while !Task.isCancelled {
            guard let generation = source.generation(botID: botID) else { return await fail() }
            if again { await sink.phase(.connecting) }   // the hub said it for the first attempt
            again = true
            await refreshSensitivity()   // before any frame, so the replayed one is judged too
            let port = (try? await source.streamPort(botID: botID)) ?? nil
            if Task.isCancelled { return }
            guard let port else {
                guard await pauseBeforeRetry(&retries) else { return }
                continue
            }

            let socket = transport.open(port: port, maxFps: Self.maxFps)
            let started = ContinuousClock.now
            var run = Run()
            await withTaskCancellationHandler {
                do {
                    for try await message in socket.messages() {
                        if Task.isCancelled { break }
                        await handle(message, &run)
                    }
                } catch {}
            } onCancel: {
                socket.close()
            }
            socket.close()
            if Task.isCancelled { return }

            // The connection ended without us asking.
            guard let now = source.generation(botID: botID) else { return await fail() }
            if now != generation {
                retries = 0   // the browser was launched again: its port is new, so try it at once
                continue
            }
            if started.duration(to: .now) > Self.healthyAfter { retries = 0 }
            guard await pauseBeforeRetry(&retries) else { return }
        }
    }

    private func fail() async {
        if !Task.isCancelled { await sink.phase(.failed) }
    }

    /// Waits the pause for the next retry; false when the retries are used up (it says `failed`) or this was cancelled.
    private func pauseBeforeRetry(_ retries: inout Int) async -> Bool {
        guard retries < Self.retryDelays.count else {
            await fail()
            return false
        }
        let delay = Self.retryDelays[retries]
        retries += 1
        do { try await clock.sleep(for: delay) } catch { return false }
        return !Task.isCancelled
    }

    private func refreshSensitivity() async {
        let changed = protection.refresh { source.pageLooksSensitive(botID: botID) }
        if changed, !Task.isCancelled { await sink.protectionChanged() }
    }

    private func handle(_ text: String, _ run: inout Run) async {
        if !run.sawMessage {
            run.sawMessage = true
            await sink.phase(.live)
        }
        // A protected page's frame is thrown away without even being parsed.
        if protection.isProtected, text.prefix(64).contains("\"frame\"") {
            run.frames += 1
            return
        }
        guard let message = LiveWireMessage.parse(text) else { return }
        switch message.type {
        case "frame":
            run.frames += 1
            if run.frames % Self.checkEvery == 0 { await refreshSensitivity() }
            guard !protection.isProtected, let base64 = message.data, !base64.isEmpty else { return }
            // The viewport is the `status` one: the frame metadata's deviceHeight does not match the image (measured, 720 vs 633).
            let viewport = run.viewport.width > 0 ? run.viewport : message.viewport
            let raw = LiveRawFrame(base64: base64, viewport: viewport, scroll: message.scroll,
                                   timestamp: message.timestamp ?? Date(),
                                   // The first one after connecting is the browser's cached copy of what it painted last.
                                   isStale: run.frames == 1)
            if inbox.submit(raw) { startDecoder() }
        case "status":
            if message.viewport.width > 0 { run.viewport = message.viewport }
        case "url":
            if let url = message.url {
                let changed = protection.setAddress(url)
                if changed { await sink.protectionChanged() }
                await refreshSensitivity()
                await sink.url(url)
            }
        default:
            break   // tabs and the like: the card does not show them
        }
    }

    /// Decodes what waits, newest only, one frame at a time, off the main actor.
    private func startDecoder() {
        let inbox = inbox, decoder = decoder, sink = sink, protection = protection
        Task.detached(priority: .utility) {
            while let raw = inbox.take() {
                guard !protection.isProtected, let decoded = decoder(raw), !inbox.isClosed else { continue }
                await sink.frame(decoded)
            }
        }
    }
}
