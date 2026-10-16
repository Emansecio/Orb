import Foundation
import Testing
@testable import Orb

/// An app with a few Orbs, a group of them and the group runtime over a `FakeDelegationService`: what the group tests play in.
/// The folder goes when the world does.
@MainActor
final class GroupWorld {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbGroups-\(UUID().uuidString)")
    let model: AppModel
    let fake = FakeDelegationService()
    let hub: GroupHub
    let bots: [Bot]
    /// The banners the runtime asked for (title, body, group).
    private(set) var notices: [(title: String, body: String, group: UUID)] = []
    private(set) var group: OrbGroup?

    var store: Store { Store(directory: root) }
    var atlas: Bot { bots[0] }
    var pesquisador: Bot { bots[1] }
    var revisor: Bot { bots[2] }

    /// `names` are the Orbs (the first three of any list are Atlas, Pesquisador and Revisor by default); with `group` the first
    /// `members` of them are made a group named "Lançamento", the first as orchestrator.
    init(names: [String] = ["Atlas", "Pesquisador", "Revisor"], members: Int? = nil, makesGroup: Bool = true,
         policy: GroupPolicy = GroupPolicy()) {
        var state = AppState(bots: names.map { Bot(name: $0, role: "Papel de \($0)", orb: OrbConfig()) })
        state.bots = state.bots.map { bot in
            var bot = bot
            bot.workingDirectory = FileManager.default.temporaryDirectory.path
            return bot
        }
        let store = Store(directory: root)
        store.save(state)
        store.flush()
        model = AppModel(store: store, runsBackgroundWork: false)
        bots = model.bots
        hub = GroupHub(model: model, delegation: fake)
        hub.settle = .zero
        hub.isAppActive = { false }
        model.groupHub = hub
        for bot in bots { fake.names[bot.id] = bot.name }
        hub.postNotice = { [weak self] title, body, id in self?.notices.append((title, body, id)) }
        if makesGroup {
            let ids = bots.prefix(members ?? bots.count).map(\.id)
            group = model.createGroup(name: "Lançamento", members: ids, policy: policy)
        }
    }

    deinit { removeTestFolder(root) }

    var groupID: UUID { group!.id }
    var session: GroupSession { model.groupSession(groupID)! }
    var live: GroupLive { model.groupLive(groupID) }
    var items: [TranscriptItem] { session.items }

    /// The thread's posts of members (name, kind, text), in order.
    var posts: [(from: String, to: String?, kind: OrbMessageItem.Kind, text: String)] {
        items.compactMap { item in
            guard case .orbMessage(let message) = item.kind, message.direction == .post else { return nil }
            return (message.from.name, message.to?.name, message.kind, message.text)
        }
    }

    var events: [OrbEvent] {
        items.compactMap { if case .event(let event) = $0.kind { event } else { nil } }
    }

    var pauses: [GroupPauseItem] {
        items.compactMap { if case .groupPause(let pause) = $0.kind { pause } else { nil } }
    }

    /// The last request the person's messages made.
    var lastGroupTurn: DelegationRequest { fake.groupTurns.last! }

    /// Returns when the request is over (the closing line is in the thread).
    func waitForFinish() async {
        await waitUntil("the group's request to end") { self.hub.run(self.groupID) == nil }
    }
}
