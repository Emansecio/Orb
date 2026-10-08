import SwiftUI
import Observation

/// What identifies an Orb on screen: enough for a sidebar row, a message avatar or a title. A small `Equatable`
/// value, so views that only show these do not depend on the whole `Bot` (permissions, folder, memory…).
struct BotLook: Equatable, Sendable {
    var id: UUID
    var name: String
    var role: String
    var orb: OrbConfig

    init(_ bot: Bot) {
        id = bot.id
        name = bot.name
        role = bot.role
        orb = bot.orb
    }
}

/// One Orb as the views see it: its settings and everything that changes while the app runs (what it is doing,
/// whether it waits for you, how many messages you have not read, its memory).
///
/// Views read the object of the Orb they show and nothing else, so an event in one Orb (a tool call, a status,
/// the end of a turn) re-renders only what shows that Orb, never another Orb's row, composer or inspector. The
/// dictionary of these objects lives in `AppModel` and is not observed: it changes only when an Orb is added
/// or deleted, and `AppModel.botIDs` says so. This is the seed of the per-Orb session the app model will be
/// split into; the transcript can join it later.
///
/// The properties views read are `private(set)` and assigned only when the value differs: writing an
/// `@Observable` property notifies its readers, and for a collection even a write that changes nothing does.
/// `AppModel` is the only writer.
@MainActor
@Observable
final class BotLive {
    let id: UUID

    // MARK: What views read

    /// The Orb's settings (a mirror of `AppModel.bots`, which stays the persisted source).
    private(set) var bot: Bot
    /// The parts of `bot` that rows, titles and avatars show, and the two the composer's menus show. Each is
    /// assigned only when it changes, so changing, say, the folder re-renders none of them.
    private(set) var look: BotLook
    private(set) var permission: PermissionState
    private(set) var modelID: String
    /// The line under the Orb's name while a turn runs; nil exactly when no turn runs.
    private(set) var status: String?
    /// `status != nil`, kept apart so the composer does not re-render with every new status line.
    private(set) var isWorking = false
    /// When the running turn began (nil exactly when none runs); the working line counts from it.
    private(set) var workingSince: Date?
    /// What the Orb's avatar does (expression, gaze and motion follow this).
    private(set) var activity = OrbActivity.idle
    /// An approval card is open: the Orb is stopped until you answer.
    private(set) var needsYou = false
    /// Incremented when a prompt is sent; Orbs jump when it changes.
    private(set) var poke = 0
    /// Messages from turns that ended while you were elsewhere. Saved with the app's state.
    private(set) var unread = 0
    /// What the inspector's memory section shows, refreshed after changes.
    private(set) var memory = MemorySnapshot()

    // MARK: What the activity follows

    // Inputs of `activity`, written by the model as a turn goes. Views read the result, not these, so each one
    // is ignored by observation and any change recomputes the observed values (which notify only if they differ).

    /// What the current tool does.
    @ObservationIgnored var runningTool: ToolCall.Kind? { didSet { refresh() } }
    /// Reply text is arriving right now (changes when a burst of text starts or ends, not per token).
    @ObservationIgnored var isSpeaking = false { didSet { refresh() } }
    /// Just received a prompt (a short "listening" beat before thinking).
    @ObservationIgnored var isListening = false { didSet { refresh() } }
    /// Just finished a turn; the Orb celebrates for a moment.
    @ObservationIgnored var isCelebrating = false { didSet { refresh() } }
    /// The last turn was interrupted or failed (a brief "error" expression).
    @ObservationIgnored var hasFailed = false { didSet { refresh() } }
    @ObservationIgnored private(set) var isAwaitingApproval = false

    init(_ bot: Bot) {
        id = bot.id
        self.bot = bot
        look = BotLook(bot)
        permission = PermissionState(mode: bot.permissionMode, rules: bot.permissionRules)
        modelID = bot.model
    }

    // MARK: Writes (each does nothing when the value is the same)

    func update(_ bot: Bot) {
        guard bot != self.bot else { return }
        self.bot = bot
        assign(\.look, to: BotLook(bot))
        assign(\.permission, to: PermissionState(mode: bot.permissionMode, rules: bot.permissionRules))
        assign(\.modelID, to: bot.model)
    }

    func setStatus(_ text: String?) {
        guard text != status else { return }
        status = text
        assign(\.workingSince, to: text == nil ? nil : (workingSince ?? .now))
        refresh()
    }

    /// Moves the start of the running turn (tests and review snapshots show a turn that has gone on a while).
    func backdateWork(to date: Date) {
        if isWorking { workingSince = date }
    }

    func setAwaitingApproval(_ isWaiting: Bool) {
        guard isWaiting != isAwaitingApproval else { return }
        isAwaitingApproval = isWaiting
        refresh()
    }

    func setUnread(_ count: Int) { assign(\.unread, to: count) }

    func setMemory(_ snapshot: MemorySnapshot) { assign(\.memory, to: snapshot) }

    func poked() { poke += 1 }

    private func refresh() {
        assign(\.needsYou, to: isAwaitingApproval)
        assign(\.isWorking, to: status != nil)
        assign(\.activity, to: Self.activity(awaitingApproval: isAwaitingApproval, failed: hasFailed, celebrating: isCelebrating,
                                              isWorking: status != nil, tool: runningTool, speaking: isSpeaking,
                                              listening: isListening))
    }

    /// What the Orb does, most urgent first: waiting for you, the error and happy beats, then (while a turn
    /// runs) its tool, its speech, the listening beat or plain thinking. Idle when nothing runs.
    nonisolated static func activity(awaitingApproval: Bool, failed: Bool, celebrating: Bool, isWorking: Bool,
                                     tool: ToolCall.Kind?, speaking: Bool, listening: Bool) -> OrbActivity {
        if awaitingApproval { return .waiting }
        if failed { return .error }
        if celebrating { return .happy }
        guard isWorking else { return .idle }
        if let tool {
            switch tool {
            case .shell: return .typing
            case .browser, .computer: return .browsing
            case .file: return .reading
            case .search: return .searching
            case .connector, .memory: return .thinking
            }
        }
        if speaking { return .speaking }
        return listening ? .listening : .thinking
    }
}

// MARK: - Writing observable state only when it changes

/// Marks the two observable types (`AppModel`, `BotLive`) that write through the helpers below, so they do not
/// spread to every `@Observable` type in the app.
@MainActor
protocol WritesOnlyChanges: AnyObject {}

extension BotLive: WritesOnlyChanges {}
extension AppModel: WritesOnlyChanges {}

extension WritesOnlyChanges {
    /// Writes `value` only when it differs from what is there. An `@Observable` property notifies its readers
    /// on every write that goes through `_modify` (a dictionary or set changed in place, `+=`), even when
    /// nothing changes, and each notification is a re-render. Reading first costs nothing.
    func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Self, Value>, to value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// `dictionary[key] = value` (or removal, with nil), skipped when it would change nothing.
    func writeIfChanged<Key: Hashable, Value: Equatable>(_ value: Value?, at key: Key,
                                                in keyPath: ReferenceWritableKeyPath<Self, [Key: Value]>) {
        if self[keyPath: keyPath][key] != value { self[keyPath: keyPath][key] = value }
    }
}
