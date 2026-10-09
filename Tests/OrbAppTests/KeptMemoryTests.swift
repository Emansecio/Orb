import Foundation
import Testing
@testable import Orb

/// A kept memory carries a small profile of its Orb (`perfil.json`), and a new Orb can start from it: the folder moves
/// to be the new Orb's memory.
@Suite(.serialized) final class KeptMemoryTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbKept-\(UUID().uuidString)")
    var memoryRoot: URL { root.appending(path: "memoria") }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// A memory with an identity, a preference and a fact, made by the bank itself.
    private static func makeMemory(_ id: UUID, library: MemoryLibrary) async {
        let bank = library.bank(for: id)
        await bank.ensureIdentity(notes: "Seja direto.", interview: true)
        _ = await bank.remember("Prefere ser chamado de Thiago.", kind: .preferencia)
        _ = await bank.remember("Gosta de café sem açúcar.", kind: .fato)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @MainActor private func model() -> AppModel {
        AppModel(store: Store(directory: root.appending(path: "dados")), runsBackgroundWork: false)
    }

    // MARK: The profile

    @Test func theProfileHoldsOnlyWhoTheOrbWas() throws {
        let profile = KeptProfile(name: "Atlas", role: "Cuida da agenda", orb: OrbConfig(color: "rosa", eyes: "ovais", hair: "coque"))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        #expect(Set(object.keys) == ["version", "name", "role", "orb"]) // no permissions, mode, folder or secrets
        #expect(try JSONDecoder().decode(KeptProfile.self, from: JSONEncoder().encode(profile)) == profile)
    }

    @Test func keepingAMemoryWritesTheProfileInsideTheFolder() async throws {
        let library = MemoryLibrary(root: memoryRoot)
        let id = UUID()
        await Self.makeMemory(id, library: library)
        let profile = KeptProfile(name: "Atlas", role: "Cuida da agenda", orb: OrbConfig(color: "rosa", eyes: "ovais", hair: "coque"))

        let kept = try #require(library.keep(id, name: "Atlas", profile: profile, now: date(2026, 10, 8, 12, 30)))

        #expect(kept.deletingLastPathComponent().lastPathComponent == "_guardadas")
        #expect(kept.lastPathComponent == "Atlas – 2026-10-08 12.30")
        #expect(!FileManager.default.fileExists(atPath: library.directory(for: id).path))
        #expect(KeptMemories.profile(in: kept) == profile)
        #expect(FileManager.default.fileExists(atPath: kept.appending(path: "nucleo/identidade.md").path))
    }

    @Test @MainActor func deletingAnOrbAndKeepingItsMemoryKeepsItsProfileButNotItsPermissions() async throws {
        let model = model()
        let bot = model.createBot(name: "Luna", role: "Escreve comigo", orb: OrbConfig(color: "menta", eyes: "felizes"), model: "",
                                  mode: .bypass, folder: .home)
        model.update(bot.id) { $0.permissionRules = [PermissionRule(family: .memory)] }
        await model.memory.bank(for: bot.id).ensureIdentity(notes: "Seja gentil.", interview: false)

        model.deleteBot(bot.id, keepMemory: true)
        #expect(await waitUntil("the memory kept") { !KeptMemories.list(in: model.memory.root).isEmpty })

        let kept = try #require(KeptMemories.list(in: model.memory.root).first)
        #expect(kept.profile == KeptProfile(name: "Luna", role: "Escreve comigo", orb: OrbConfig(color: "menta", eyes: "felizes")))
        let text = try String(contentsOf: kept.url.appending(path: KeptProfile.fileName), encoding: .utf8)
        #expect(!text.contains("bypass") && !text.contains("permission"))
    }

    // MARK: Listing

    @Test func keptMemoriesListNewestFirstWithNameDateAndPages() throws {
        let kept = KeptMemories.folder(in: memoryRoot)
        try write("---\ntipo: fato\n---\nUm.", to: kept.appending(path: "Luna – 2026-10-08 12.30/fatos/um.md"))
        try write("---\ntipo: fato\n---\nDois.", to: kept.appending(path: "Luna – 2026-10-08 12.30/fatos/dois.md"))
        try write("---\ntipo: sessao\n---\nArquivada.", to: kept.appending(path: "Luna – 2026-10-08 12.30/_arquivo/sessoes/x.md"))
        try write("{}", to: kept.appending(path: "Atlas – 2026-10-09 09.15 (2)/fatos/a.md"))
        // Made by hand, without a date in its name: the folder's own date counts.
        let byHand = kept.appending(path: "feita à mão")
        try FileManager.default.createDirectory(at: byHand, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: date(2025, 1, 2)], ofItemAtPath: byHand.path)

        let list = KeptMemories.list(in: memoryRoot)

        #expect(list.map(\.name) == ["Atlas", "Luna", "feita à mão"])
        #expect(list[0].date == date(2026, 10, 9, 9, 15))
        #expect(list[1].date == date(2026, 10, 8, 12, 30))
        #expect(list[2].date == date(2025, 1, 2))
        #expect(list.map(\.pageCount) == [1, 2, 0]) // the archive of compacted sessions is not a memory
        #expect(list.allSatisfy { $0.profile == nil }) // folders from before profiles: the name comes from the folder
        #expect(KeptMemories.count(in: memoryRoot) == 3)
        #expect(list[1].menuTitle == "Luna · 08/10/2026 · 2 lembranças")
    }

    @Test func noKeptMemoriesIsAnEmptyList() {
        #expect(KeptMemories.list(in: memoryRoot).isEmpty)
        #expect(KeptMemories.count(in: memoryRoot) == 0)
    }

    // MARK: Starting from one

    @Test @MainActor func aNewOrbStartedFromAKeptMemoryTakesItsFolderAndCanRecallIt() async throws {
        let model = model()
        let library = model.memory
        let oldID = UUID()
        await Self.makeMemory(oldID, library: library)
        let profile = KeptProfile(name: "Atlas", role: "Cuida da agenda", orb: OrbConfig(color: "rosa"))
        library.keep(oldID, name: "Atlas", profile: profile, now: date(2026, 10, 8))
        let kept = try #require(KeptMemories.list(in: library.root).first)
        // What the old index knew is of no use to the new Orb: it is rebuilt from the pages.
        try write("lixo", to: kept.url.appending(path: "index.sqlite"))

        let bot = model.createBot(name: "Atlas", role: "Cuida da agenda", orb: profile.orb, model: "", mode: .ask, folder: .home,
                                  adopting: kept)

        #expect(KeptMemories.list(in: library.root).isEmpty) // it left the kept ones
        #expect(!FileManager.default.fileExists(atPath: kept.url.path))
        #expect(FileManager.default.fileExists(atPath: library.directory(for: bot.id).appending(path: "nucleo/identidade.md").path))
        #expect(!FileManager.default.fileExists(atPath: library.directory(for: bot.id).appending(path: KeptProfile.fileName).path))
        let bank = library.bank(for: bot.id)
        #expect(await waitUntil("the memory to be searchable") { await !bank.recall("café").isEmpty })
        // It has an identity and a preference: the first conversation does not interview again.
        #expect(await !bank.snapshot().interviewPending)
        #expect(await bank.snapshot().identity.contains("Seja direto"))
        // It greets as someone who already knows you.
        #expect(model.transcript(bot.id).last?.kind == .greeting(OrbGreeting.text(name: "Atlas", temperament: profile.orb.temperament, returning: true)))
    }

    @Test @MainActor func startingFromAFolderWithNothingLearnedStillInterviewsWhenAsked() async throws {
        let model = model()
        try write("---\ntipo: sessao\ntitulo: Conversa\n---\nFalamos do tempo.",
                  to: KeptMemories.folder(in: model.memory.root).appending(path: "Velho – 2026-01-02 03.04/sessoes/a.md"))
        let kept = try #require(KeptMemories.list(in: model.memory.root).first)
        let bot = model.createBot(name: "Velho", role: "", orb: OrbConfig(), model: "", mode: .ask, folder: .home, adopting: kept)

        let bank = model.memory.bank(for: bot.id)
        #expect(await waitUntil("the identity") { await bank.identity() != nil })
        #expect(await bank.snapshot().interviewPending) // no identity or preferences came with it
        #expect(await !bank.recall("tempo").isEmpty)
    }

    @Test @MainActor func whatYouWriteForTheNewOrbIsAddedToTheKeptIdentity() async throws {
        let model = model()
        let oldID = UUID()
        await Self.makeMemory(oldID, library: model.memory)
        model.memory.keep(oldID, name: "Atlas", profile: nil, now: date(2026, 10, 8))
        let kept = try #require(KeptMemories.list(in: model.memory.root).first)

        let bot = model.createBot(name: "Atlas", role: "", orb: OrbConfig(), model: "", mode: .ask, identity: "Responda em português.",
                                  folder: .home, adopting: kept)

        let bank = model.memory.bank(for: bot.id)
        #expect(await waitUntil("the identity notes") { await bank.snapshot().identity.contains("Responda em português") })
        #expect(await bank.snapshot().identity.contains("Seja direto"))
    }

    @Test @MainActor func aKeptMemoryThatCannotBeMovedLeavesTheOrbWithAMemoryOfItsOwn() async {
        let model = model()
        let gone = KeptMemory(id: "Fantasma – 2026-10-08 12.00", url: KeptMemories.folder(in: model.memory.root).appending(path: "Fantasma"),
                              name: "Fantasma", date: .now, pageCount: 0, profile: nil)

        let bot = model.createBot(name: "Novo", role: "", orb: OrbConfig(), model: "", mode: .ask, folder: .home, adopting: gone)

        let bank = model.memory.bank(for: bot.id)
        #expect(await waitUntil("a memory of its own") { await bank.identity() != nil })
        #expect(await bank.snapshot().interviewPending)
        let notice = model.transcript(bot.id).contains { item in
            if case .notice(let text) = item.kind { text.contains("Não foi possível usar a memória guardada") } else { false }
        }
        #expect(notice)
        // The memory did not come along: the greeting is the one of a new Orb, after the notice.
        #expect(model.transcript(bot.id).last?.kind == .greeting(OrbGreeting.text(name: "Novo", temperament: .equilibrado, returning: false)))
    }
}
