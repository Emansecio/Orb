import Foundation
import Observation
import SwiftUI
import AppKit
import CryptoKit

/// "Acessar pelo celular" (Ajustes → Celular, docs/CELULAR.md): runs the phone server while it is on, keeps each paired
/// phone up to date with the list of Orbs and the chat it follows, and turns what the phone asks into what the menu bar
/// panel already does (send or queue a message, answer a card, stop a turn).
@MainActor @Observable
final class PhoneAccess {
    static let enabledKey = "phoneAccess"
    static let keepAwakeKey = "phoneKeepsMacAwake"
    static let tokenAccount = "phone-access-token"
    static let botsThrottle: Duration = .milliseconds(300)
    static let chatThrottle: Duration = .milliseconds(150)

    enum Status: Equatable {
        case off, starting, listening, failed(String)
    }

    struct Device: Identifiable, Equatable {
        var id: UUID
        var name: String
        var since: Date
    }

    private(set) var status = Status.off
    private(set) var devices: [Device] = []
    /// This Mac's Tailscale address, looked up when the access starts and when Ajustes → Celular appears.
    private(set) var address: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var server: PhoneServer?
    @ObservationIgnored private(set) var token: String?
    @ObservationIgnored private var botsArmed = false
    @ObservationIgnored private var botsPending = false
    @ObservationIgnored private var avatarHashes: [OrbConfig: String] = [:]
    @ObservationIgnored private var avatarImages: [String: String] = [:]
    @ObservationIgnored private var awake: (any NSObjectProtocol)?

    init(model: AppModel?) {
        self.model = model
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// The link the QR code shows; nil while the access is off or Tailscale has no address on this Mac.
    var pairingLink: String? {
        guard status == .listening, let address, let token else { return nil }
        return PhonePairing.link(host: address, port: PhoneWire.port, token: token, mac: Self.macName)
    }

    static var macName: String { Host.current().localizedName ?? "Mac" }

    // MARK: On and off

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        on ? start() : stop()
    }

    /// At launch, when the user left it on.
    func restore() {
        if isEnabled { start() }
    }

    /// The port the server listens on once `listening` (tests start it on port 0, which the system picks).
    var port: UInt16? { server?.port }

    func start(port: UInt16 = PhoneWire.port) {
        guard server == nil else { return }
        token = Self.storedToken()
        let server = PhoneServer(token: { [weak self] in self?.token }, macName: Self.macName)
        server.onState = { [weak self] state in self?.serverChanged(state) }
        server.onAuthorized = { [weak self] connection in self?.authorized(connection) }
        server.onClosed = { [weak self] _ in self?.refreshDevices() }
        server.handle = { [weak self] connection, frame in self?.handle(frame, from: connection) }
        self.server = server
        refreshAddress()
        status = .starting
        server.start(port: port)
        syncAwake()
    }

    func stop() {
        server?.stop()
        server = nil
        status = .off
        devices = []
        syncAwake()
    }

    /// "Gerar novo código": phones paired with the old one are dropped and must read the new QR code.
    func renewToken() {
        let fresh = PhonePairing.newToken()
        Keychain.set(fresh, account: Self.tokenAccount)
        token = fresh
        server?.dropAll()
    }

    /// Only while the access is on: off, there is no code to show.
    func refreshAddress() {
        guard server != nil else { return }
        let found = PhonePeer.tailscaleAddress()
        if address != found { address = found }
    }

    /// While the access is on, the Mac does not go to sleep on its own (the display still does), unless the user turned
    /// that off: a sleeping Mac answers no phone.
    func syncAwake() {
        let wanted = server != nil && (UserDefaults.standard.object(forKey: Self.keepAwakeKey) as? Bool ?? true)
        if wanted, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Acesso pelo celular ligado")
        } else if !wanted, let token = awake {
            ProcessInfo.processInfo.endActivity(token)
            awake = nil
        }
    }

    private static func storedToken() -> String {
        if let saved = Keychain.get(tokenAccount), PhonePairing.isValidToken(saved) { return saved }
        let fresh = PhonePairing.newToken()
        Keychain.set(fresh, account: tokenAccount)
        return fresh
    }

    private func serverChanged(_ state: PhoneServer.State) {
        switch state {
        case .starting: status = .starting
        case .listening: status = .listening
        case .failed(let message):
            status = .failed(message)
            server?.stop()
            server = nil
            syncAwake()
        }
    }

    private func refreshDevices() {
        let now = (server?.authorized ?? []).map { Device(id: $0.id, name: $0.device, since: $0.since) }
        if devices != now { devices = now }
    }

    private func authorized(_ connection: PhoneConnection) {
        refreshDevices()
        guard let model else { return }
        let frame = PhoneWire.encode(Self.botsFrame(model, hash: avatarHash))
        connection.lastBots = frame
        server?.send(frame, to: connection)
        armBots()
    }

    // MARK: What the phone asks

    private func handle(_ frame: PhoneWire.Incoming, from connection: PhoneConnection) {
        guard let model, let server else { return }
        switch frame {
        case .hello:
            break
        case .ping:
            server.send(PhoneWire.Pong(), to: connection)
        case .open(let bot):
            guard model.bot(bot) != nil else { return unknown(bot, to: connection) }
            connection.openBot = bot
            connection.chatEpoch += 1
            connection.lastChat = nil
            connection.lastStream = nil
            let epoch = connection.chatEpoch
            watchChat(connection)
            // An Orb whose conversation is on disk only is read off the main thread, then shown.
            if model.sessions[bot]?.isUnloaded == true {
                Task { [weak self] in
                    await model.loadedConversation(bot)
                    guard connection.chatEpoch == epoch else { return }
                    self?.watchChat(connection)
                }
            }
        case .close:
            connection.openBot = nil
            connection.chatEpoch += 1
        case .send(let bot, let text, let ref):
            guard model.bot(bot) != nil else { return unknown(bot, to: connection) }
            Task { [weak self] in
                guard let self else { return }
                let (ok, queued, note) = await self.send(text, to: bot, model: model)
                server.send(PhoneWire.Sent(ref: ref, ok: ok, queued: queued, note: note), to: connection)
            }
        case .decide(let bot, let approval, let decision, let reply, let note):
            guard model.bot(bot) != nil else { return unknown(bot, to: connection) }
            // The phone names the card by its line in the chat (`Item.id`); the card's own id is accepted too.
            let request = Self.pendingCards(model, bot: bot).lazy.compactMap { item -> ApprovalRequest? in
                guard case .approval(let request) = item.kind, item.id == approval || request.id == approval else { return nil }
                return request
            }.first
            guard let request else { return } // answered elsewhere
            guard PhoneWire.Item.Approval.allows(decision, on: request, reply: reply) else {
                return server.send(PhoneWire.Failure(code: .badRequest, message: "Responda a este pedido no Mac."), to: connection)
            }
            model.decide(decision, note: note, reply: reply, approvalID: request.id, botID: bot)
        case .stop(let bot):
            guard model.bot(bot) != nil else { return unknown(bot, to: connection) }
            if model.isWorking(bot) { model.stopTurn(bot) }
        case .avatar(let bot):
            guard let config = model.bot(bot)?.orb else { return unknown(bot, to: connection) }
            let hash = avatarHash(config)
            Task { [weak self] in
                guard let png = await self?.avatarPNG(config, hash: hash) else { return }
                self?.server?.send(PhoneWire.Avatar(bot: bot.uuidString, hash: hash, png: png), to: connection)
            }
        }
    }

    private func unknown(_ bot: UUID, to connection: PhoneConnection) {
        server?.send(PhoneWire.Failure(code: .unknownBot, message: "Esse Orb não existe mais."), to: connection)
    }

    /// The menu bar panel's send (`QuickAskView.send`), for a message from the phone: the composer's draft and attachments
    /// on the Mac stay where they are.
    private func send(_ raw: String, to bot: UUID, model: AppModel) async -> (ok: Bool, queued: Bool, note: String?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (false, false, nil) }
        guard text.count <= PhoneWire.maxText else { return (false, false, "Mensagem longa demais para mandar pelo celular.") }
        let name = model.liveBot(bot)?.look.name ?? "O Orb"
        guard model.hasCheckedConnections || model.hasUsableModel(bot) else { return (false, false, QuickAskSend.checkingNote) }
        switch QuickAskSend.action(isWorking: model.isWorking(bot), canSteer: model.canQueueOutsideComposer(bot),
                                   isReady: model.hasUsableModel(bot) || model.isProviderReady, hasText: true,
                                   orbHasModel: model.hasUsableModel(bot)) {
        case .nothing: return (false, false, QuickAskSend.noModelNote(name: name))
        case .blocked: return (false, false, QuickAskSend.blockedNote(name: name))
        case .noModel: return (false, false, QuickAskSend.noModelNote(name: name))
        case .queue:
            let queued = model.queueOutsideComposer(text, to: bot)
            return (queued, queued, queued ? nil : QuickAskSend.blockedNote(name: name))
        case .send:
            if model.sessions[bot]?.isUnloaded == true {
                await model.loadedConversation(bot)
                model.ensureLoaded(bot)
            }
            let sent = model.send(text, to: bot)
            return (sent, false, sent ? nil : QuickAskSend.blockedNote(name: name))
        }
    }

    // MARK: Keeping the phones up to date

    /// Sends the list of Orbs to every phone whose copy differs, and watches what it was made of for the next change.
    /// Not armed while no phone is in: an idle access costs nothing.
    private func armBots() {
        guard !botsArmed, let model, let server, !server.authorized.isEmpty else { return }
        botsArmed = true
        let frame = withObservationTracking {
            Self.botsFrame(model, hash: avatarHash)
        } onChange: { [weak self] in
            Task { @MainActor in self?.botsChanged() }
        }
        let data = PhoneWire.encode(frame)
        for connection in server.authorized where connection.lastBots != data {
            connection.lastBots = data
            server.send(data, to: connection)
        }
    }

    private func botsChanged() {
        botsArmed = false
        guard !botsPending else { return }
        botsPending = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.botsThrottle)
            self?.botsPending = false
            self?.armBots()
        }
    }

    /// The chat a phone follows: a `chat` frame when its items changed, a `stream` frame when the reply being written grew.
    private func watchChat(_ connection: PhoneConnection) {
        guard let model, let server, let bot = connection.openBot, server.connections[connection.id] != nil else { return }
        let epoch = connection.chatEpoch
        let (chat, stream) = withObservationTracking {
            Self.chatFrames(model, bot: bot)
        } onChange: { [weak self] in
            Task { @MainActor in self?.chatChanged(connection, epoch: epoch) }
        }
        let chatData = PhoneWire.encode(chat)
        if connection.lastChat != chatData {
            connection.lastChat = chatData
            server.send(chatData, to: connection)
        }
        // The phone is reading this chat (it sends `close` when it goes to the background): what arrives is not unread.
        model.setUnread(0, for: bot)
        if let stream {
            let streamData = PhoneWire.encode(stream)
            if connection.lastStream != streamData {
                connection.lastStream = streamData
                server.send(streamData, to: connection)
            }
        } else {
            connection.lastStream = nil
        }
    }

    private func chatChanged(_ connection: PhoneConnection, epoch: Int) {
        guard connection.chatEpoch == epoch, !connection.chatPending else { return }
        connection.chatPending = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.chatThrottle)
            connection.chatPending = false
            guard connection.chatEpoch == epoch else { return }
            self?.watchChat(connection)
        }
    }

    static func botsFrame(_ model: AppModel, hash: (OrbConfig) -> String) -> PhoneWire.Bots {
        PhoneWire.Bots(bots: model.sidebarBotIDs.compactMap { id in
            guard let live = model.liveBot(id) else { return nil }
            let look = live.look
            let palette = OrbCatalog.shared.palette(look.orb.color)
            return PhoneWire.Bot(
                id: id.uuidString, name: look.name, role: look.role, avatar: hash(look.orb),
                color: String(format: "#%06X", palette.hexes.count > 1 ? palette.hexes[1] : 0x4A34F2),
                working: live.isWorking, needsYou: live.needsYou,
                status: live.isWorking ? (live.work?.phrase ?? live.status) : nil,
                unread: live.unread,
                last: live.lastReply.map { PhoneWire.Bot.Last(text: $0.text, date: PhoneWire.millis($0.date)) },
                // Only looked for while the Orb waits for you: the conversation is not walked for every Orb at each change.
                card: live.needsYou ? pendingCards(model, bot: id).last.map(PhoneWire.Item.init) : nil)
        })
    }

    /// The last `itemWindow` items of the chat, plus any card still open further up or in a routine's own conversation
    /// (the phone must be able to answer it), and the reply being written.
    static func chatFrames(_ model: AppModel, bot: UUID) -> (PhoneWire.Chat, PhoneWire.Stream?) {
        let items = model.orbTranscript(bot).items
        var window = items.suffix(PhoneWire.itemWindow).map(PhoneWire.Item.init)
        let shown = Set(window.map(\.id))
        for item in pendingCards(model, bot: bot) where !shown.contains(item.id.uuidString) {
            window.append(PhoneWire.Item(item))
        }
        let live = model.live(bot)
        let chat = PhoneWire.Chat(bot: bot.uuidString, items: window, working: live.isWorking,
                                  status: live.isWorking ? (live.work?.phrase ?? live.status) : nil)
        guard let streaming = items.last(where: { if case .bot(_, true) = $0.kind { true } else { false } }),
              let text = model.liveText(for: streaming.id, of: bot) else { return (chat, nil) }
        _ = text.closed // read for the observation: `text` itself is not observed
        _ = text.tail
        return (chat, PhoneWire.Stream(bot: bot.uuidString, item: streaming.id.uuidString, text: text.text))
    }

    /// The open cards of an Orb as lines of its conversation: the chat's, or a running routine's (`pendingApprovals`).
    static func pendingCards(_ model: AppModel, bot: UUID) -> [TranscriptItem] {
        (model.sessions[bot]?.conversation?.items ?? model.transcript(bot)).filter { item in
            if case .approval(let request) = item.kind { request.decision == nil } else { false }
        }
    }

    // MARK: Avatars

    private static let avatarVersion = 2

    private func avatarHash(_ config: OrbConfig) -> String {
        if let known = avatarHashes[config] { return known }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // The phone keeps an avatar by hash for good. Bump `avatarVersion` when the drawing changes, so phones
        // download again (version 1 sent empty images: the layers were not decoded yet).
        let digest = SHA256.hash(data: Data("\(Self.avatarVersion)".utf8) + ((try? encoder.encode(config)) ?? Data()))
        let hash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        avatarHashes[config] = hash
        return hash
    }

    /// The Orb at rest, 256 × 256 px, as base64 PNG. Made once per look.
    private func avatarPNG(_ config: OrbConfig, hash: String) async -> String? {
        if let known = avatarImages[hash] { return known }
        // The static orb decodes its layers in the background and draws nothing until they arrive, and
        // ImageRenderer draws once: decode them first, at the exact pixel size the canvas will ask for.
        let size: CGFloat = 128, scale: CGFloat = 2
        let pixels = OrbGeometry.imageSide(for: size, scale: scale) * scale
        let decoded = await OrbImages.load(config.layers(for: .idle), pixels: pixels)
        guard !decoded.contains(where: { $0 == nil }) else { return nil }
        if let known = avatarImages[hash] { return known } // another request made it meanwhile
        let renderer = ImageRenderer(content: OrbView(config: config, size: size, animated: false)
            .frame(width: size, height: size)
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, scale))
        renderer.scale = scale
        // An orb-less image (layers dropped from the cache in between) is not kept: the phone caches by hash for good.
        guard let image = renderer.cgImage, Self.showsTheOrb(image),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        let encoded = png.base64EncodedString()
        avatarImages[hash] = encoded
        return encoded
    }

    /// Whether `image` shows the orb's body: its center is opaque. Without its layers the canvas still draws the
    /// ground shadow, so "some pixels" is not enough.
    nonisolated static func showsTheOrb(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn && pixels[((height / 2) * width + width / 2) * 4 + 3] > 200
    }
}

#if DEBUG || ORB_DEV_TOOLS
extension PhoneAccess {
    /// For `--snapshot settings-phone`: the access as it looks listening, with made-up values and no socket.
    func showPreview(address: String?, devices: [Device]) {
        status = .listening
        self.address = address
        token = "previewpreviewpreviewpreviewpreviewpreview1"
        self.devices = devices
    }
}

/// `Orb --snapshot settings-phone | settings-phone-no-tailscale out.png`: Ajustes → Celular with the access on, a QR code and
/// one phone connected, or with Tailscale missing. Turned on only in this process (the argument domain is never saved).
@MainActor
enum PhoneSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        guard screen == "settings-phone" || screen == "settings-phone-no-tailscale" else { return nil }
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[PhoneAccess.enabledKey] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let devices = [PhoneAccess.Device(id: UUID(), name: "Pixel 9", since: .now.addingTimeInterval(-600))]
        model.phone.showPreview(address: screen == "settings-phone" ? "100.101.102.103" : nil, devices: screen == "settings-phone" ? devices : [])
        return AnyView(PhoneSettings()
            .frame(width: 640, height: SettingsTab.phone.height)
            .background(Palette.chrome)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }
}
#endif
