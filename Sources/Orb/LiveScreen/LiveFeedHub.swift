import Foundation

/// Opens and closes the live streams of the Orbs' browsers (docs/TELA-AO-VIVO.md). A view that shows an Orb's page
/// acquires it while it is on screen and releases it when it leaves; the hub connects only while someone acquired it,
/// one stream at a time, and lets go of everything on release. Nothing it receives is written anywhere.
///
/// The hub itself only decides (who streams, when it stops, what the views may see) and only on the main actor; reading the
/// socket, parsing and decoding happen in a `LiveStreamRunner` task off it, and a frame costs the main thread one delivery.
@MainActor
final class LiveFeedHub {
    /// How long a stream stays open after the last view of its Orb left, so a row scrolled away and back does not reconnect.
    static let graceAfterRelease = Duration.seconds(3)
    /// How many finished uses keep their last picture, in the whole app.
    static let lastScreenLimit = 10

    private struct Hold {
        var normal = 0
        var wide = 0
        var total: Int { normal + wide }
    }

    private struct Connection {
        let botID: UUID
        let token: UUID
        let task: Task<Void, Never>
        let inbox: LiveInbox
    }

    private struct LastScreen {
        let itemID: UUID
        let botID: UUID
        /// The JPEG as it came from the browser, never a bitmap.
        let jpeg: Data
    }

    private let source: any LiveBrowserSource
    private let transport: any LiveTransport
    private let clock: any LiveClock
    private let decoder: LiveFrameDecoder

    private var stores: [UUID: LiveFrameStore] = [:]
    private var protections: [UUID: LiveProtection] = [:]
    private var holds: [UUID: Hold] = [:]
    /// The Orbs that acquired, the latest last: the one in view is the one that streams.
    private var recency: [UUID] = []
    private var graceTasks: [UUID: Task<Void, Never>] = [:]
    /// The Orbs whose stream gave up: they are tried again only when a view asks again (`acquire`), never in a loop.
    private var failed: Set<UUID> = []
    private var connection: Connection?
    private var pointerHandlerInstalled = false
    /// The newest unprotected frame of each Orb, compressed: what `endUse` keeps.
    private var newestJPEG: [UUID: Data] = [:]
    /// Least recently used first.
    private var lastScreens: [LastScreen] = []

    /// Frames decoded since launch (tests and the measurements say "none while nobody looks").
    private(set) var framesProcessed = 0

    convenience init(browsers: BrowserHub) {
        self.init(source: BrowserHubLiveSource(browsers: browsers))
    }

    init(source: any LiveBrowserSource, transport: any LiveTransport = URLSessionLiveTransport(),
         clock: any LiveClock = SystemLiveClock(), decoder: @escaping LiveFrameDecoder = LiveJPEG.decode) {
        self.source = source
        self.transport = transport
        self.clock = clock
        self.decoder = decoder
    }

    /// The store the views of this Orb read (made when first asked for).
    func store(_ botID: UUID) -> LiveFrameStore {
        if let store = stores[botID] { return store }
        let store = LiveFrameStore(botID: botID)
        stores[botID] = store
        return store
    }

    // MARK: Views come and go

    /// A view that shows this Orb's page appeared; `wide` is the larger view in the panel. Both kinds share the one connection
    /// (the stream has a single size), so `wide` only counts as one more reference.
    func acquire(_ botID: UUID, wide: Bool = false) {
        if wide { holds[botID, default: Hold()].wide += 1 } else { holds[botID, default: Hold()].normal += 1 }
        graceTasks.removeValue(forKey: botID)?.cancel()
        failed.remove(botID)
        recency.removeAll { $0 == botID }
        recency.append(botID)
        _ = store(botID)
        reconcile()
    }

    /// That view left; the stream closes a few seconds later if nothing acquired it again.
    func release(_ botID: UUID, wide: Bool = false) {
        guard var hold = holds[botID] else { return }
        if wide { hold.wide = max(0, hold.wide - 1) } else { hold.normal = max(0, hold.normal - 1) }
        guard hold.total == 0 else {
            holds[botID] = hold
            return
        }
        holds[botID] = nil
        failed.remove(botID)
        if connection?.botID == botID {
            graceTasks[botID]?.cancel()
            graceTasks[botID] = Task { [clock] in
                do { try await clock.sleep(for: Self.graceAfterRelease) } catch { return }
                self.graceEnded(botID)
            }
        } else {
            // Not the one streaming: nothing to close, only its "paused" is over.
            if let store = stores[botID], store.phase == .paused { store.setPhase(.idle) }
            updatePointerHandler()
        }
    }

    private func graceEnded(_ botID: UUID) {
        graceTasks[botID] = nil
        guard holds[botID] == nil else { return }
        if connection?.botID == botID {
            stopConnection()
            stores[botID]?.setPhase(.idle)   // its last frame stays for the card to show dimmed
        }
        updatePointerHandler()
        reconcile()
    }

    /// The Orb was deleted: its stream and store go.
    func forget(_ botID: UUID) {
        let wasStreaming = connection?.botID == botID
        if wasStreaming { stopConnection() }
        graceTasks.removeValue(forKey: botID)?.cancel()
        holds[botID] = nil
        failed.remove(botID)
        recency.removeAll { $0 == botID }
        stores[botID]?.clear()
        stores[botID] = nil
        protections[botID] = nil
        newestJPEG[botID] = nil
        lastScreens.removeAll { $0.botID == botID }
        updatePointerHandler()
        if wasStreaming { reconcile() }
    }

    // MARK: Last screen

    /// The use of the browser (`BrowserViewItem`) of this Orb ended: its last picture is kept, compressed, as that item's.
    /// Never one of a protected page.
    func endUse(_ botID: UUID, itemID: UUID) {
        defer { newestJPEG[botID] = nil }
        guard protections[botID]?.isProtected != true, let jpeg = newestJPEG[botID] else { return }
        lastScreens.removeAll { $0.itemID == itemID }
        lastScreens.append(LastScreen(itemID: itemID, botID: botID, jpeg: jpeg))
        if lastScreens.count > Self.lastScreenLimit { lastScreens.removeFirst(lastScreens.count - Self.lastScreenLimit) }
    }

    /// The last picture of a finished use of the browser (`BrowserViewItem`), as JPEG, while it is still kept in memory.
    func lastScreen(of itemID: UUID) -> Data? {
        guard let index = lastScreens.firstIndex(where: { $0.itemID == itemID }) else { return nil }
        let entry = lastScreens.remove(at: index)
        lastScreens.append(entry)
        return entry.jpeg
    }

    // MARK: Protected pages

    /// A hand-off card ("needs you") is waiting for the person on this Orb, or is not any more.
    func setHandoffPending(_ botID: UUID, _ pending: Bool) {
        if protection(botID).setHandoff(pending) { applyProtection(botID) }
    }

    private func protection(_ botID: UUID) -> LiveProtection {
        if let protection = protections[botID] { return protection }
        let protection = LiveProtection()
        protections[botID] = protection
        return protection
    }

    /// Carries the protection to the store: the frame goes, nothing more is shown or kept. When the page is free again, the stream
    /// is opened anew so that its replayed frame fills the card (the stream only sends when the page changes).
    private func applyProtection(_ botID: UUID) {
        guard let protection = protections[botID] else { return }
        let isProtected = protection.isProtected
        if isProtected { newestJPEG[botID] = nil }
        guard let store = stores[botID] else { return }
        let was = store.isProtected
        store.setProtected(isProtected)
        if was, !isProtected, connection?.botID == botID { startConnection(botID) }
    }

    /// Asks again whether the page is protected (an action is about to happen), without holding the main actor.
    private func recheckProtection(_ botID: UUID) {
        guard let protection = protections[botID] else { return }
        Task.detached { [source, weak self] in
            if protection.refresh({ source.pageLooksSensitive(botID: botID) }) { await self?.applyProtection(botID) }
        }
    }

    // MARK: Who streams

    /// One stream at a time: the Orb acquired last. Another Orb's takes over from the one open, which is paused (it keeps its
    /// last frame); an Orb whose views left keeps its stream until its grace ends.
    private func reconcile() {
        updatePointerHandler()
        guard let wanted = recency.last(where: { !failed.contains($0) && (holds[$0]?.total ?? 0) > 0 }) else { return }
        if connection?.botID == wanted { return }
        if let old = connection {
            stopConnection()
            graceTasks.removeValue(forKey: old.botID)?.cancel()
            stores[old.botID]?.setPhase((holds[old.botID]?.total ?? 0) > 0 ? .paused : .idle)
        }
        startConnection(wanted)
    }

    private func startConnection(_ botID: UUID) {
        stopConnection()
        let store = store(botID)
        store.setPhase(.connecting)
        let token = UUID()
        let inbox = LiveInbox()
        let protection = protection(botID)
        let sink = LiveStreamSink(
            phase: { [weak self] phase in self?.streamPhase(phase, botID: botID, token: token) },
            url: { [weak self] url in
                guard let self, self.connection?.token == token else { return }
                self.stores[botID]?.setURL(url)
            },
            frame: { [weak self] decoded in self?.streamFrame(decoded, botID: botID, token: token) },
            protectionChanged: { [weak self] in self?.applyProtection(botID) })
        let runner = LiveStreamRunner(botID: botID, source: source, transport: transport,
                                      clock: clock, protection: protection, inbox: inbox, decoder: decoder, sink: sink)
        let task = Task.detached(priority: .userInitiated) { await runner.run() }
        connection = Connection(botID: botID, token: token, task: task, inbox: inbox)
        applyProtection(botID)   // an already protected Orb opens with its frame down
    }

    /// Closes the open stream: the receiving task is cancelled (which closes its socket) and the inbox stops the decoder.
    private func stopConnection() {
        guard let connection else { return }
        connection.inbox.close()
        connection.task.cancel()
        self.connection = nil
    }

    private func streamPhase(_ phase: LiveFrameStore.Phase, botID: UUID, token: UUID) {
        guard connection?.token == token else { return }
        stores[botID]?.setPhase(phase)
        if phase == .failed {
            stopConnection()
            failed.insert(botID)
            reconcile()
        }
    }

    private func streamFrame(_ decoded: LiveDecodedFrame, botID: UUID, token: UUID) {
        guard connection?.token == token, protections[botID]?.isProtected != true, let store = stores[botID] else { return }
        framesProcessed += 1
        store.deliver(decoded.frame)
        newestJPEG[botID] = decoded.jpeg
    }

    // MARK: The Orb's pointer

    /// The browser tells where it is about to act only while someone could see it.
    private func updatePointerHandler() {
        let needed = !holds.isEmpty || connection != nil
        guard needed != pointerHandlerInstalled else { return }
        pointerHandlerInstalled = needed
        if needed {
            source.setPointerHandler { [weak self] botID, pointer in
                Task { @MainActor in self?.pointerArrived(botID, pointer) }
            }
        } else {
            source.setPointerHandler(nil)
        }
    }

    private func pointerArrived(_ botID: UUID, _ pointer: LivePointer) {
        guard connection?.botID == botID, let store = stores[botID] else { return }
        // The box is in the viewport's CSS pixels, scroll already taken off: it is only cut at the viewport's edge, and
        // ignored when it is all outside.
        var pointer = pointer
        if let viewport = store.lastFrame?.viewport {
            let visible = pointer.rect.intersection(CGRect(origin: .zero, size: viewport))
            if visible.isNull { return }
            pointer = LivePointer(rect: visible, kind: pointer.kind)
        }
        store.point(pointer)
        recheckProtection(botID)   // an action is what changes the page
    }
}
