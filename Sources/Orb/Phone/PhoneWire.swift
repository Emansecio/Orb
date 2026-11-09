import Foundation

// The phone's wire format (docs/CELULAR.md): JSON text frames over a WebSocket, each with a "type". Pure values, so the
// mapping from the app's state and the parsing of what the phone sends are tested without a socket.

enum PhoneWire {
    static let protocolVersion = 1
    static let port: UInt16 = 47821
    /// How many of a chat's last items a `chat` frame carries: enough to read back a few exchanges on a phone without
    /// sending a long history on every change.
    static let itemWindow = 80
    /// Biggest frame the phone may send (a message is at most `maxText` characters; JSON escaping can double it).
    static let maxFrame = 64 * 1024
    static let maxText = 20_000
    /// Long fields are cut before they go out: a phone shows a few lines of a command or a tool's detail, not a file.
    static let maxCommand = 2_000
    static let maxDetail = 300

    // MARK: Phone → Mac

    enum Incoming: Equatable {
        case hello(token: String, device: String, protocolVersion: Int)
        case open(bot: UUID)
        case close
        case send(bot: UUID, text: String, ref: String)
        case decide(bot: UUID, approval: UUID, decision: ApprovalDecision, reply: String?, note: String?)
        case stop(bot: UUID)
        case avatar(bot: UUID)
        case ping
    }

    enum ParseError: Error, Equatable {
        case tooLarge
        case malformed
    }

    private struct RawFrame: Decodable {
        var type: String
        var token: String?
        var device: String?
        var `protocol`: Int?
        var bot: String?
        var text: String?
        var ref: String?
        var approval: String?
        var decision: String?
        var reply: String?
        var note: String?
    }

    /// One frame from the phone. Unknown fields are ignored; a missing required one, a bad id or an unknown type is
    /// `malformed`. `review` is not a decision the phone can make (it only splits a grouped card on the Mac).
    static func parse(_ data: Data) -> Result<Incoming, ParseError> {
        guard data.count <= maxFrame else { return .failure(.tooLarge) }
        guard let raw = try? JSONDecoder().decode(RawFrame.self, from: data) else { return .failure(.malformed) }
        let bot = raw.bot.flatMap(UUID.init(uuidString:))
        switch raw.type {
        case "hello":
            guard let token = raw.token else { return .failure(.malformed) }
            return .success(.hello(token: token, device: String((raw.device ?? "").prefix(80)), protocolVersion: raw.protocol ?? 1))
        case "open":
            guard let bot else { return .failure(.malformed) }
            return .success(.open(bot: bot))
        case "close":
            return .success(.close)
        case "send":
            guard let bot, let text = raw.text else { return .failure(.malformed) }
            return .success(.send(bot: bot, text: text, ref: String((raw.ref ?? "").prefix(64))))
        case "decide":
            guard let bot, let approval = raw.approval.flatMap(UUID.init(uuidString:)),
                  let decision = raw.decision.flatMap(ApprovalDecision.init(rawValue:)), decision != .review else {
                return .failure(.malformed)
            }
            return .success(.decide(bot: bot, approval: approval, decision: decision, reply: raw.reply, note: raw.note))
        case "stop":
            guard let bot else { return .failure(.malformed) }
            return .success(.stop(bot: bot))
        case "avatar":
            guard let bot else { return .failure(.malformed) }
            return .success(.avatar(bot: bot))
        case "ping":
            return .success(.ping)
        default:
            return .failure(.malformed)
        }
    }

    // MARK: Mac → phone

    struct Welcome: Encodable {
        var type = "welcome"
        var mac: String
        var `protocol` = PhoneWire.protocolVersion
    }

    struct Bots: Encodable, Equatable {
        var type = "bots"
        var bots: [Bot]
    }

    struct Bot: Encodable, Equatable {
        struct Last: Encodable, Equatable {
            var text: String
            var date: Int64
        }

        var id: String
        var name: String
        var role: String
        var avatar: String
        var color: String
        var working: Bool
        var needsYou: Bool
        var status: String?
        var unread: Int
        var last: Last?
        /// The newest open card while `needsYou`, so a notification can show it and answer it without opening the chat.
        var card: Item?
    }

    struct Chat: Encodable, Equatable {
        var type = "chat"
        var bot: String
        var items: [Item]
        var working: Bool
        var status: String?
    }

    struct Stream: Encodable, Equatable {
        var type = "stream"
        var bot: String
        var item: String
        var text: String
    }

    struct Sent: Encodable {
        var type = "sent"
        var ref: String
        var ok: Bool
        var queued: Bool
        var note: String?
    }

    struct Avatar: Encodable {
        var type = "avatar"
        var bot: String
        var hash: String
        var png: String
    }

    struct Pong: Encodable {
        var type = "pong"
    }

    struct Failure: Encodable {
        enum Code: String, Encodable {
            case unauthorized, badRequest = "bad_request", unknownBot = "unknown_bot", tooLarge = "too_large"
        }

        var type = "error"
        var code: Code
        var message: String
    }

    struct Item: Encodable, Equatable {
        struct Tool: Encodable, Equatable {
            var kind: String
            var title: String
            var detail: String
            var state: String
        }

        struct Approval: Encodable, Equatable {
            struct Question: Encodable, Equatable {
                var text: String
                var options: [String]
                var multiple: Bool
            }

            var kind: String
            var title: String
            var command: String
            var reason: String
            var decision: String?
            var dangerous: Bool
            var canAlways: Bool
            var count: Int
            var question: Question?
        }

        var id: String
        var date: Int64
        var kind: String
        var text: String
        var streaming: Bool?
        var tool: Tool?
        var approval: Approval?
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func encode(_ frame: some Encodable) -> Data {
        // Every frame is made of strings, numbers and booleans: encoding cannot fail.
        (try? JSONEncoder().encode(frame)) ?? Data("{}".utf8)
    }
}

// MARK: The app's items as the phone reads them

extension PhoneWire.Item {
    /// What one line of the chat becomes on the phone.
    init(_ item: TranscriptItem) {
        id = item.id.uuidString
        date = PhoneWire.millis(item.date)
        switch item.kind {
        case .user(let text, let attachments):
            kind = "user"
            let files = attachments.map { URL(fileURLWithPath: $0).lastPathComponent }
            self.text = files.isEmpty ? text : [text, "📎 " + files.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: "\n")
        case .bot(let text, let isStreaming):
            kind = "bot"
            self.text = text
            streaming = isStreaming ? true : nil
        case .greeting(let text):
            kind = "bot"
            self.text = text
        case .tool(let call):
            kind = "tool"
            text = call.intent ?? call.title
            tool = Tool(kind: call.kind.rawValue, title: call.title, detail: String(call.detail.prefix(PhoneWire.maxDetail)),
                        state: call.state.rawValue)
        case .approval(let request):
            kind = "approval"
            text = request.title
            approval = Approval(request)
        case .notice(let text):
            kind = "notice"
            self.text = text
        case .event(let event):
            kind = "event"
            text = event.sentence
        case .orbMessage(let message):
            kind = "orb"
            let who = message.direction == .received ? message.from.name : (message.to?.name ?? message.from.name)
            text = "\(who): \(message.text)"
        case .groupPause(let pause):
            kind = "notice"
            text = pause.state == .open ? "O grupo pausou ao chegar no limite. Continue ou encerre no Mac." : "O grupo pausou ao chegar no limite."
        case .browserView(let view):
            kind = "tool"
            let place = view.host.isEmpty ? "o navegador" : view.host
            text = "Usou o navegador em \(place)"
            let state = switch view.outcome {
            case .running: "running"
            case .done: "done"
            case .failed, .stopped: "failed"
            }
            tool = Tool(kind: ToolCall.Kind.browser.rawValue, title: text, detail: view.lastPath ?? "", state: state)
        }
    }
}

extension PhoneWire.Item.Approval {
    init(_ request: ApprovalRequest) {
        kind = request.isQuestion ? "question" : request.isHandoff ? "handoff" : request.isProposal ? "proposal"
            : request.isAccess ? "access" : "permission"
        title = request.title
        let command = request.isBatch ? request.items.map(\.command).joined(separator: "\n") : request.command
        self.command = String(command.prefix(PhoneWire.maxCommand))
        reason = request.reason
        decision = request.decision?.rawValue
        dangerous = request.isDangerous
        // "Sempre permitir" grants the card's rule; a grouped card offers several on the Mac, where they are chosen.
        canAlways = kind == "permission" && !request.suggestions.isEmpty && !request.isBatch
        count = max(1, request.items.count)
        question = request.question.map { Question(text: $0.text, options: $0.options, multiple: $0.multiple) }
    }

    /// What the phone may answer on this card (docs/CELULAR.md): a hand-off, a new Orb or more access are decided on the Mac.
    static func allows(_ decision: ApprovalDecision, on request: ApprovalRequest, reply: String?) -> Bool {
        if decision == .deny { return true }
        if request.isHandoff || request.isProposal || request.isAccess { return false }
        if request.isQuestion { return decision == .once && OrbQuestion.clean(reply) != nil }
        switch decision {
        case .once: return true
        case .task: return true
        case .always: return !request.suggestions.isEmpty && !request.isBatch
        case .deny, .review: return false
        }
    }
}
