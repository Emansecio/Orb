import Foundation
import Testing
@testable import Orb

/// What the "Atenção com seus dados" alert says: the Orb or the settings the file holds, not `<UUID>.json`.
@Suite final class StoreNoticeTextTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbNotices-\(UUID().uuidString)")

    deinit { removeTestFolder(root) }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [StoreNotice] = []
        func add(_ notice: StoreNotice) { lock.withLock { items.append(notice) } }
        var notices: [StoreNotice] { lock.withLock { items } }
    }

    private func put(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private let lia = Bot(name: "Lia", role: "x", orb: OrbConfig(), model: "", permissionMode: .ask)

    // MARK: Failed saves

    @Test func aFailedSaveOfAConversationNamesTheOrb() throws {
        try put("a file, not a folder", at: root.appending(path: "conversations")) // nothing can be written in it
        let failures = Collected()
        let store = Store(directory: root) { failures.add($0) }
        store.save(Conversation(items: [TranscriptItem(.user(text: "oi", attachments: []))], messages: [.user("oi")]), for: lia.id)
        store.flush()

        let notice = try #require(failures.notices.first)
        #expect(notice.message.contains("\(lia.id.uuidString).json")) // the store itself names the file…
        let shown = AppModel.described(notice, bots: [lia], routines: [])
        #expect(shown.message.hasPrefix("Não foi possível salvar a conversa de Lia: "))
        #expect(!shown.message.contains(".json")) // …and the user is not shown the file name
        #expect(shown.message.hasSuffix("As últimas mudanças podem não estar no disco."))
    }

    @Test func aFailedSaveOfTheSettingsSaysSo() throws {
        try put("a file, not a folder", at: root.appending(path: "data"))
        let failures = Collected()
        let store = Store(directory: root.appending(path: "data")) { failures.add($0) }
        store.save(AppState.initial)
        store.flush()

        let shown = AppModel.described(try #require(failures.notices.first), bots: [], routines: [])
        #expect(shown.message.hasPrefix("Não foi possível salvar os ajustes do app (Orbs, rotinas, provedores): "))
    }

    @Test func eachKindOfFileHasItsOwnWording() {
        let routine = Routine(name: "Resumo da manhã", botID: lia.id, prompt: "x", schedule: .everyHours(1))
        let folder = root.appending(path: "conversations/\(lia.id.uuidString)")
        func shown(_ file: URL, routines: [Routine] = [routine], bots: [Bot]? = nil) -> String {
            AppModel.described(StoreNotice(message: "Não foi possível salvar “\(file.lastPathComponent)”: x.", file: file),
                               bots: bots ?? [lia], routines: routines).message
        }
        #expect(shown(folder.appending(path: "routine-\(routine.id.uuidString).json")) == "Não foi possível salvar o histórico da rotina Resumo da manhã: x.")
        #expect(shown(folder.appending(path: "routine-\(UUID().uuidString).json")) == "Não foi possível salvar o histórico de uma rotina de Lia: x.")
        #expect(shown(folder.appending(path: "\(UUID().uuidString).json")) == "Não foi possível salvar uma conversa antiga de Lia: x.")
        #expect(shown(folder.appending(path: "index.json")) == "Não foi possível salvar a lista de conversas antigas de Lia: x.")
        // An Orb that is gone, or a file nobody knows: the name stays (better than a wrong guess).
        let stranger = root.appending(path: "conversations/\(UUID().uuidString).json")
        #expect(shown(stranger) == "Não foi possível salvar “\(stranger.lastPathComponent)”: x.")
        #expect(shown(root.appending(path: "outro.json")) == "Não foi possível salvar “outro.json”: x.")
    }

    @Test func theNoteBesideAConversationNeverAlarmsAnyone() throws {
        let failures = Collected()
        let store = Store(directory: root) { failures.add($0) }
        store.save(Conversation(items: [TranscriptItem(.user(text: "oi", attachments: []))], messages: [.user("oi")]), for: lia.id)
        store.flush()
        // The note is gone and something that is not a file sits in its place: it can't be made again.
        let note = root.appending(path: "conversations/\(lia.id.uuidString).meta.json")
        try? FileManager.default.removeItem(at: note)
        try FileManager.default.createDirectory(at: note, withIntermediateDirectories: true)

        _ = store.readConversation(lia.id)
        store.flush()
        #expect(failures.notices.isEmpty)
    }

    @Test func aConnectorsCatalogNeverAlarmsAnyoneEither() throws {
        let failures = Collected()
        let store = Store(directory: root) { failures.add($0) }
        // A folder where the file should go: it can't be written, and it is only a cache.
        let id = UUID()
        try FileManager.default.createDirectory(at: root.appending(path: "conectores/\(id.uuidString).json"), withIntermediateDirectories: true)
        store.saveConnectorCatalog(ConnectorCatalog(handshake: MCPHandshake(), specs: [], annotations: [:]), for: id)
        store.flush()
        #expect(failures.notices.isEmpty)
    }

    // MARK: Items that could not be read

    @Test @MainActor func lostItemsAgreeInNumberAndNameTheSettings() throws {
        func notice(unreadable: Int) throws -> String {
            let folder = root.appending(path: "n\(unreadable)")
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppState.initial)) as? [String: Any])
            var bots = try #require(json["bots"] as? [[String: Any]])
            bots += Array(repeating: ["name": "Sem id"], count: unreadable)
            json["bots"] = bots
            try put(String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self), at: folder.appending(path: "state.json"))
            let model = AppModel(store: Store(directory: folder), runsBackgroundWork: false)
            return try #require(model.dataNotices.first).message
        }
        let one = try notice(unreadable: 1), two = try notice(unreadable: 2)
        #expect(one.hasPrefix("Ao ler os ajustes do app (Orbs, rotinas, provedores), 1 item não pôde ser lido "
            + "(talvez de uma versão mais nova do Orb) e ficou de fora. O arquivo original foi guardado como “state.json.corrupt-"))
        #expect(two.hasPrefix("Ao ler os ajustes do app (Orbs, rotinas, provedores), 2 itens não puderam ser lidos "
            + "(talvez de uma versão mais nova do Orb) e ficaram de fora. O arquivo original foi guardado como “state.json.corrupt-"))
        #expect(!one.contains("(ns)"))
    }

    @Test @MainActor func anUnreadableStateSaysTheOrbStartedOverInLowercase() throws {
        try put("{ not json", at: root.appending(path: "state.json"))
        let model = AppModel(store: Store(directory: root), runsBackgroundWork: false)
        let message = try #require(model.dataNotices.first).message
        #expect(message.hasPrefix("Não foi possível ler os ajustes do app (Orbs, rotinas, provedores). O arquivo foi guardado, sem mudanças, como “state.json.corrupt-"))
        #expect(message.hasSuffix(", e o Orb começou do zero."))
        #expect(!message.contains(", e O"))
    }
}
