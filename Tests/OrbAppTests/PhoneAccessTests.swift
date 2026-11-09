import AppKit
import Foundation
import Network
import Testing
@testable import Orb

// The phone access (docs/CELULAR.md): who may connect, the token, the frames the phone sends, how the app's items look on
// the phone, and a phone talking to a real server over loopback.

@Suite struct PhonePeerTests {
    @Test func tailscaleAndLoopbackOnly() {
        #expect(PhonePeer.isAllowed(bytes: [100, 64, 0, 1]))
        #expect(PhonePeer.isAllowed(bytes: [100, 127, 255, 255]))
        #expect(PhonePeer.isAllowed(bytes: [127, 0, 0, 1]))
        #expect(!PhonePeer.isAllowed(bytes: [100, 128, 0, 1]))
        #expect(!PhonePeer.isAllowed(bytes: [100, 63, 255, 255]))
        #expect(!PhonePeer.isAllowed(bytes: [192, 168, 0, 10]))
        #expect(!PhonePeer.isAllowed(bytes: [10, 0, 0, 2]))
        #expect(!PhonePeer.isAllowed(bytes: []))
    }

    @Test func ipv6() {
        let loopback = [UInt8](repeating: 0, count: 15) + [1]
        let mapped = { (v4: [UInt8]) in [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF] + v4 }
        #expect(PhonePeer.isAllowed(bytes: loopback))
        #expect(PhonePeer.isAllowed(bytes: mapped([100, 100, 1, 1])))
        #expect(!PhonePeer.isAllowed(bytes: mapped([192, 168, 1, 1])))
        #expect(PhonePeer.isAllowed(bytes: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0] + [UInt8](repeating: 7, count: 10)))
        #expect(!PhonePeer.isAllowed(bytes: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE1] + [UInt8](repeating: 7, count: 10)))
        #expect(!PhonePeer.isAllowed(bytes: [0xFE, 0x80] + [UInt8](repeating: 0, count: 14)))
    }

    @Test func endpoints() {
        #expect(PhonePeer.isAllowed(.hostPort(host: "100.101.102.103", port: 1)))
        #expect(PhonePeer.isAllowed(.hostPort(host: "::1", port: 1)))
        #expect(!PhonePeer.isAllowed(.hostPort(host: "192.168.0.4", port: 1)))
        #expect(!PhonePeer.isAllowed(.hostPort(host: .name("example.com", nil), port: 1)))
    }
}

@Suite struct PhonePairingTests {
    @Test func tokens() {
        let a = PhonePairing.newToken(), b = PhonePairing.newToken()
        #expect(a.count == 43 && PhonePairing.isValidToken(a))
        #expect(a != b)
        #expect(!PhonePairing.isValidToken(String(a.dropLast())))
        #expect(!PhonePairing.isValidToken(String(a.dropLast()) + "+"))
        #expect(!PhonePairing.isValidToken(""))
    }

    @Test func matching() {
        let token = PhonePairing.newToken()
        #expect(PhonePairing.matches(token, token))
        #expect(!PhonePairing.matches(String(token.dropLast()) + (token.last == "A" ? "B" : "A"), token))
        #expect(!PhonePairing.matches(String(token.dropLast()), token))
        #expect(!PhonePairing.matches(token + "x", token))
        #expect(!PhonePairing.matches("", token))
    }

    @Test func linkEncodesEveryValue() throws {
        let link = PhonePairing.link(host: "100.1.2.3", port: 47821, token: "abc_-9", mac: "Mac + iPad & cia")
        #expect(link == "orb://parear?host=100.1.2.3&port=47821&token=abc_-9&mac=Mac%20%2B%20iPad%20%26%20cia")
        let items = try #require(URLComponents(string: link)?.queryItems)
        #expect(items.first { $0.name == "mac" }?.value == "Mac + iPad & cia")
    }

    @Test func limiterBlocksAfterFiveInAMinute() {
        var limiter = PhoneFailureLimiter()
        let start = Date(timeIntervalSince1970: 1_000)
        for second in 0..<4 { limiter.record("a", at: start + Double(second)) }
        #expect(!limiter.isBlocked("a", at: start + 5))
        limiter.record("a", at: start + 5)
        #expect(limiter.isBlocked("a", at: start + 6))
        #expect(!limiter.isBlocked("b", at: start + 6))
        #expect(!limiter.isBlocked("a", at: start + 61))
    }
}

@Suite struct PhoneWireTests {
    private func parse(_ json: String) -> Result<PhoneWire.Incoming, PhoneWire.ParseError> { PhoneWire.parse(Data(json.utf8)) }

    @Test func frames() {
        let bot = UUID(), card = UUID()
        #expect(parse(#"{"type":"hello","token":"t","device":"Pixel","protocol":1,"extra":true}"#)
            == .success(.hello(token: "t", device: "Pixel", protocolVersion: 1)))
        #expect(parse(#"{"type":"open","bot":"\#(bot)"}"#) == .success(.open(bot: bot)))
        #expect(parse(#"{"type":"close"}"#) == .success(.close))
        #expect(parse(#"{"type":"send","bot":"\#(bot)","text":"oi","ref":"r1"}"#) == .success(.send(bot: bot, text: "oi", ref: "r1")))
        #expect(parse(#"{"type":"decide","bot":"\#(bot)","approval":"\#(card)","decision":"deny","note":"não"}"#)
            == .success(.decide(bot: bot, approval: card, decision: .deny, reply: nil, note: "não")))
        #expect(parse(#"{"type":"stop","bot":"\#(bot)"}"#) == .success(.stop(bot: bot)))
        #expect(parse(#"{"type":"avatar","bot":"\#(bot)"}"#) == .success(.avatar(bot: bot)))
        #expect(parse(#"{"type":"ping"}"#) == .success(.ping))
    }

    @Test func badFrames() {
        let bot = UUID()
        #expect(parse(#"{"type":"open"}"#) == .failure(.malformed))
        #expect(parse(#"{"type":"open","bot":"não é id"}"#) == .failure(.malformed))
        #expect(parse(#"{"type":"send","bot":"\#(bot)"}"#) == .failure(.malformed))
        #expect(parse(#"{"type":"hello"}"#) == .failure(.malformed))
        #expect(parse(#"{"type":"decide","bot":"\#(bot)","approval":"\#(UUID())","decision":"review"}"#) == .failure(.malformed))
        #expect(parse(#"{"type":"decide","bot":"\#(bot)","approval":"\#(UUID())","decision":"talvez"}"#) == .failure(.malformed))
        #expect(parse(#"{"type":"apagar_tudo"}"#) == .failure(.malformed))
        #expect(parse("[1,2]") == .failure(.malformed))
        #expect(parse("") == .failure(.malformed))
        let big = #"{"type":"send","bot":"\#(bot)","text":""# + String(repeating: "a", count: PhoneWire.maxFrame) + #""}"#
        #expect(parse(big) == .failure(.tooLarge))
    }

    @Test func helloKeepsADeviceNameShort() {
        guard case .success(.hello(_, let device, let version)) = parse(#"{"type":"hello","token":"t","device":"\#(String(repeating: "x", count: 200))"}"#) else {
            Issue.record("hello not read")
            return
        }
        #expect(device.count == 80)
        #expect(version == 1)
    }

    @Test func items() {
        let user = PhoneWire.Item(TranscriptItem(.user(text: "olha", attachments: ["/tmp/a/foto.png"])))
        #expect(user.kind == "user" && user.text == "olha\n📎 foto.png")
        let streaming = PhoneWire.Item(TranscriptItem(.bot(text: "Escrev", isStreaming: true)))
        #expect(streaming.kind == "bot" && streaming.streaming == true)
        #expect(PhoneWire.Item(TranscriptItem(.bot(text: "Feito", isStreaming: false))).streaming == nil)
        let call = ToolCall(kind: .shell, title: "Rodando no Terminal", detail: String(repeating: "l", count: 1_000), state: .failed)
        let tool = PhoneWire.Item(TranscriptItem(.tool(call)))
        #expect(tool.tool == .init(kind: "shell", title: "Rodando no Terminal", detail: String(repeating: "l", count: PhoneWire.maxDetail), state: "failed"))
        #expect(PhoneWire.Item(TranscriptItem(.greeting("Oi!"))).kind == "bot")
        #expect(PhoneWire.Item(TranscriptItem(.notice("Parado."))).kind == "notice")
    }

    @Test func cards() {
        let rule = PermissionRule.shell("brew")
        var permission = ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "brew upgrade", reason: "", suggestions: [rule])
        #expect(PhoneWire.Item.Approval(permission).kind == "permission")
        #expect(PhoneWire.Item.Approval(permission).canAlways)
        for decision: ApprovalDecision in [.once, .task, .always, .deny] {
            #expect(PhoneWire.Item.Approval.allows(decision, on: permission, reply: nil))
        }
        permission.items = [ApprovalItem(toolName: "run_command", title: "a", command: "ls"), ApprovalItem(toolName: "run_command", title: "b", command: "pwd")]
        let batch = PhoneWire.Item.Approval(permission)
        #expect(!batch.canAlways && batch.count == 2 && batch.command == "ls\npwd")
        #expect(!PhoneWire.Item.Approval.allows(.always, on: permission, reply: nil))

        var question = ApprovalRequest(toolName: "ask_user", title: "Pergunta", command: "", reason: "")
        question.question = OrbQuestion(text: "Qual cor?", options: ["Azul", "Verde"])
        #expect(PhoneWire.Item.Approval(question).kind == "question")
        #expect(PhoneWire.Item.Approval(question).question?.options == ["Azul", "Verde"])
        #expect(PhoneWire.Item.Approval.allows(.once, on: question, reply: "Azul"))
        #expect(!PhoneWire.Item.Approval.allows(.once, on: question, reply: "  "))
        #expect(!PhoneWire.Item.Approval.allows(.always, on: question, reply: "Azul"))
        #expect(PhoneWire.Item.Approval.allows(.deny, on: question, reply: nil))

        var handoff = ApprovalRequest(toolName: "browse_show", title: "Faça login", command: "", reason: "")
        handoff.isHandoff = true
        #expect(PhoneWire.Item.Approval(handoff).kind == "handoff")
        #expect(!PhoneWire.Item.Approval.allows(.once, on: handoff, reply: nil))
        #expect(PhoneWire.Item.Approval.allows(.deny, on: handoff, reply: nil))
    }
}

/// A phone: a WebSocket to the server on loopback that reads frames as JSON objects.
final class PhoneClient: Sendable {
    private let task: URLSessionWebSocketTask

    init(port: UInt16) {
        task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/")!)
        task.resume()
    }

    func send(_ json: String) async throws {
        try await task.send(.string(json))
    }

    /// The next frame of `type`, skipping others; nil when the socket closed or nothing came in time.
    func next(_ type: String, timeout: Duration = .seconds(10)) async -> [String: Any]? {
        let task = self.task
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let message = try? await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message?.self) { group in
                group.addTask { try await task.receive() }
                group.addTask {
                    try await Task.sleep(until: deadline)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard case .string(let text)? = message,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
            if object["type"] as? String == type { return object }
        }
        return nil
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}

@Suite final class PhoneServerTests {
    @MainActor private func listening(_ server: PhoneServer) async throws -> UInt16 {
        server.start(port: 0)
        _ = await waitUntil("the server listening") { server.state == .listening }
        return try #require(server.port)
    }

    @Test @MainActor func aWrongTokenIsTurnedAway() async throws {
        let server = PhoneServer(token: { "segredo" }, macName: "Mac")
        defer { server.stop() }
        let phone = PhoneClient(port: try await listening(server))
        try await phone.send(#"{"type":"hello","token":"errado","device":"Pixel","protocol":1}"#)
        let error = await phone.next("error")
        #expect(error?["code"] as? String == "unauthorized")
        _ = await waitUntil("the socket closed") { server.connections.isEmpty }
        #expect(server.authorized.isEmpty)
    }

    @Test @MainActor func theRightTokenGetsInAndFramesReachTheOwner() async throws {
        let server = PhoneServer(token: { "segredo" }, macName: "Mac de teste")
        defer { server.stop() }
        var frames: [PhoneWire.Incoming] = []
        server.handle = { _, frame in frames.append(frame) }
        let phone = PhoneClient(port: try await listening(server))
        defer { phone.close() }
        try await phone.send(#"{"type":"ping"}"#) // before the hello: refused
        #expect(await phone.next("error")?["code"] as? String == "unauthorized")

        let second = PhoneClient(port: try #require(server.port))
        defer { second.close() }
        try await second.send(#"{"type":"hello","token":"segredo","device":"Pixel 9","protocol":1}"#)
        #expect(await second.next("welcome")?["mac"] as? String == "Mac de teste")
        #expect(server.authorized.map(\.device) == ["Pixel 9"])
        try await second.send(#"{"type":"nada"}"#)
        #expect(await second.next("error")?["code"] as? String == "bad_request")
        try await second.send(#"{"type":"send","bot":"\#(UUID())","text":""# + String(repeating: "a", count: PhoneWire.maxFrame) + #""}"#)
        #expect(await second.next("error")?["code"] as? String == "too_large")
        try await second.send(#"{"type":"close"}"#)
        _ = await waitUntil("the frame handed over") { frames == [.close] }
    }

    @Test @MainActor func aPeerOutsideTailscaleIsDropped() async throws {
        let server = PhoneServer(token: { "segredo" }, macName: "Mac", allows: { _ in false })
        defer { server.stop() }
        let phone = PhoneClient(port: try await listening(server))
        try? await phone.send(#"{"type":"hello","token":"segredo","device":"x","protocol":1}"#)
        #expect(await phone.next("welcome", timeout: .seconds(2)) == nil)
        #expect(server.connections.isEmpty)
    }
}

@Suite final class PhoneAccessFlowTests {
    private let root = TempFolder("OrbPhone", creating: true)

    init() { QuietNotifications.hold() }

    deinit { QuietNotifications.release() }

    @MainActor private func setUp(_ replies: [[LLMEvent]]) -> (AppModel, Bot, PhoneAccess) {
        Store(directory: root.url).save(AppState.initial)
        let model = AppModel(store: Store(directory: root.url), runsBackgroundWork: false)
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        let script = CallScript(replies, whenExhausted: .reply(ModelReply([.text("fim"), .finished(.done, nil)])))
        model.clientOverride = { CallScriptModel(script: script) }
        return (model, model.bots[0], PhoneAccess(model: model))
    }

    @MainActor private func connect(_ phone: PhoneAccess) async throws -> PhoneClient {
        phone.start(port: 0)
        _ = await waitUntil("the phone access listening") { phone.status == .listening }
        let client = PhoneClient(port: try #require(phone.port))
        try await client.send(#"{"type":"hello","token":"\#(try #require(phone.token))","device":"Pixel","protocol":1}"#)
        return client
    }

    private func items(_ chat: [String: Any]?) -> [[String: Any]] { chat?["items"] as? [[String: Any]] ?? [] }

    @Test @MainActor func aMessageFromThePhoneGetsTheReplyBack() async throws {
        let (model, atlas, phone) = setUp([[.text("Olá do Mac."), .finished(.done, nil)]])
        defer { phone.stop() }
        let client = try await connect(phone)
        defer { client.close() }
        let bots = await client.next("bots")?["bots"] as? [[String: Any]]
        #expect(bots?.first?["name"] as? String == atlas.name)
        #expect((bots?.first?["avatar"] as? String)?.count == 16)

        try await client.send(#"{"type":"open","bot":"\#(atlas.id)"}"#)
        #expect(await client.next("chat")?["bot"] as? String == atlas.id.uuidString)
        try await client.send(#"{"type":"send","bot":"\#(atlas.id)","text":"oi","ref":"r1"}"#)
        let sent = await client.next("sent")
        #expect(sent?["ref"] as? String == "r1" && sent?["ok"] as? Bool == true)
        var reply: [String: Any]?
        while reply == nil, let chat = await client.next("chat") {
            reply = items(chat).first { $0["kind"] as? String == "bot" && $0["text"] as? String == "Olá do Mac." }
        }
        #expect(reply != nil)
        #expect(model.transcript(atlas.id).contains { if case .user("oi", _) = $0.kind { true } else { false } })
        #expect(model.drafts[atlas.id] ?? "" == "") // the Mac's composer is left alone
        #expect(model.live(atlas.id).unread == 0) // read on the phone

        try await client.send(#"{"type":"avatar","bot":"\#(atlas.id)"}"#)
        let avatar = await client.next("avatar")
        let png = try #require(Data(base64Encoded: avatar?["png"] as? String ?? ""))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        // The orb itself, not an empty canvas drawn before its layers were decoded.
        let image = try #require(NSBitmapImageRep(data: png)?.cgImage)
        #expect(image.width == 256)
        #expect(PhoneAccess.showsTheOrb(image))
        try await client.send(#"{"type":"send","bot":"\#(UUID())","text":"oi","ref":"r2"}"#)
        #expect(await client.next("error")?["code"] as? String == "unknown_bot")
    }

    @Test @MainActor func aCardOnlyTheMacAnswersCanStillBeDeclined() async throws {
        let access = LLMEvent.toolCalls([ToolCallRequest(id: "c1", name: AccessTool.name,
                                                         arguments: #"{"reason":"Para rodar comandos.","capabilities":["terminal"]}"#)])
        let (model, atlas, phone) = setUp([[access, .finished(.toolUse, nil)], [.text("Tudo bem."), .finished(.done, nil)]])
        defer { phone.stop() }
        model.update(atlas.id) { $0.capabilities = [.browser] }
        let client = try await connect(phone)
        defer { client.close() }
        try await client.send(#"{"type":"open","bot":"\#(atlas.id)"}"#)
        try await client.send(#"{"type":"send","bot":"\#(atlas.id)","text":"roda um comando","ref":"r"}"#)
        var card: [String: Any]?
        while card == nil, let chat = await client.next("chat") {
            card = items(chat).first { ($0["approval"] as? [String: Any])?["kind"] as? String == "access" }
        }
        let id = try #require(card?["id"] as? String)
        // The list carries the card too, for a notification that answers it without opening the chat.
        var listed: [String: Any]?
        while listed == nil, let bots = await client.next("bots")?["bots"] as? [[String: Any]] {
            listed = bots.first { $0["id"] as? String == atlas.id.uuidString && $0["needsYou"] as? Bool == true }?["card"] as? [String: Any]
        }
        #expect(listed?["id"] as? String == id)
        try await client.send(#"{"type":"decide","bot":"\#(atlas.id)","approval":"\#(id)","decision":"once"}"#)
        #expect(await client.next("error")?["code"] as? String == "bad_request")
        #expect(model.pendingApprovals(of: atlas.id).count == 1)
        try await client.send(#"{"type":"decide","bot":"\#(atlas.id)","approval":"\#(id)","decision":"deny"}"#)
        _ = await waitUntil("the card declined") { model.pendingApprovals(of: atlas.id).isEmpty }
        #expect(model.bot(atlas.id)?.capabilities == [.browser])
    }
}
