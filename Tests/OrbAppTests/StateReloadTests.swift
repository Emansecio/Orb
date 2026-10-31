import Foundation
import Testing
@testable import Orb

/// `state.json` read again while the app runs: by hand ("Recarregar ajustes do disco", `reloadStateFromDisk`) or by
/// the file watcher (`checkStateFile`), which ignores the app's own writes — their `FileFingerprint` is kept by the
/// save's callback — and reloads only what was written from outside.
@Suite(.serialized) final class StateReloadTests {
    let folder = TempFolder("OrbStateReload", creating: true, sealing: "state.json")

    @MainActor private func model(over state: AppState = .initial) -> AppModel {
        let store = Store(directory: folder.url)
        store.save(state)
        store.flush()
        return AppModel(store: store, runsBackgroundWork: false)
    }

    private var stateURL: URL { Store(directory: folder.url).stateURL }

    private func write(_ state: AppState) throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    // MARK: First use vs. an existing file

    @Test func firstUseSeedsTheBuiltInSkillsAndAnExistingFileDoesNot() throws {
        #expect(AppState.firstUse.skills.count == Skill.starters.count
                && AppState.firstUse.skills.allSatisfy { $0.source == Skill.builtInSource })
        // A file that exists without `skills` (one from before they existed, or emptied by hand) is not a first use.
        let decoded = try JSONDecoder().decode(AppState.self, from: Data(#"{"bots":[]}"#.utf8))
        #expect(decoded.skills.isEmpty)
    }

    @Test @MainActor func aFileWithoutSkillsGivesTheAppNone() {
        var state = AppState.initial
        state.skills = []
        let model = model(over: state)
        #expect(model.skills.isEmpty)
    }

    // MARK: Scopes

    @Test func aSkillWithoutAScopeInTheFileGetsEveryOrbTheFileHas() throws {
        var state = AppState.initial
        state.bots.append(Bot(name: "Lia", role: "", orb: OrbConfig()))
        let atlas = state.bots[0].id, lia = state.bots[1].id
        state.skills = [Skill(slug: "antiga", name: "Antiga", summary: "", instructions: "x", orbIDs: [UUID()])]
        // The file of a build before skills were scoped has no `orbIDs` key at all.
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        (json["skills"] as? [[String: Any]])?.forEach { #expect($0["orbIDs"] != nil) }
        var skills = try #require(json["skills"] as? [[String: Any]])
        for index in skills.indices { skills[index].removeValue(forKey: "orbIDs") }
        json["skills"] = skills

        let decoded = try JSONDecoder().decode(AppState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.skills.map(\.slug) == ["antiga"] && decoded.skills[0].orbIDs == [atlas, lia])
        #expect(decoded.skills[0].isAvailable(to: atlas) && decoded.skills[0].isAvailable(to: lia))
    }

    @Test @MainActor func aNewOrbJoinsTheBuiltInSkillsScope() {
        let state = AppState.firstUse
        #expect(state.skills.allSatisfy { $0.orbIDs.isEmpty }) // no Orb exists yet
        let store = Store(directory: folder.url)
        store.save(state)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        let bot = model.createBot(name: "Atlas", role: "", orb: OrbConfig(), model: "", mode: .ask, folder: .home)
        #expect(model.skills.count == Skill.starters.count && model.skills.allSatisfy { $0.orbIDs == [bot.id] })
        #expect(model.skills(for: bot.id).count == Skill.starters.count)
    }

    @Test @MainActor func aDeletedOrbLeavesTheSkillsScopes() {
        let model = model()
        let atlas = model.bots[0].id
        let lia = model.createBot(name: "Lia", role: "", orb: OrbConfig(), model: "", mode: .ask, folder: .home).id
        model.skills = [Skill(slug: "ambas", name: "Ambas", summary: "", instructions: "x", orbIDs: [atlas, lia]),
                        Skill(slug: "dela", name: "Dela", summary: "", instructions: "x", orbIDs: [lia])]
        model.deleteBot(lia)
        #expect(model.skills[0].orbIDs == [atlas])
        // Scoped to nobody, it stays as it is — its instructions are kept, and it can be scoped again by hand.
        #expect(model.skills[1].orbIDs.isEmpty && !model.skills[1].isAvailable(to: atlas))
    }

    // MARK: Reading the file again

    @Test @MainActor func theFileReadAgainReplacesWhatIsInMemory() async throws {
        let model = model()
        let atlas = model.bots[0].id
        var edited = AppState.initial
        let rex = Bot(name: "Rex", role: "", orb: OrbConfig())
        edited.bots = [model.bots[0], rex]
        edited.skills = [Skill(slug: "externa", name: "Externa", summary: "", instructions: "x", orbIDs: [atlas])]
        edited.routines = [Routine(name: "Rotina", botID: rex.id, prompt: "x", schedule: .everyHours(24))]
        edited.unread = [atlas.uuidString: 3]
        try write(edited)

        model.reloadStateFromDisk()

        #expect(await waitUntil("the file's state applied") { model.bots.map(\.name) == ["Atlas", "Rex"] })
        #expect(model.skills.map(\.slug) == ["externa"]) // the built-ins are the file's problem now, not the app's
        #expect(model.routines.map(\.name) == ["Rotina"])
        #expect(model.live(atlas).unread == 3)
        #expect(model.session(rex.id).isUnloaded) // its conversation is read when needed, like every other Orb's
        #expect(model.skills(for: rex.id).isEmpty && model.skills(for: atlas).map(\.slug) == ["externa"])
    }

    @Test @MainActor func anOrbTheFileNoLongerHasLeavesTheSelectionAndTheSessions() async throws {
        let model = model()
        let atlas = model.bots[0].id
        model.selection = .bot(atlas)
        var edited = AppState.initial
        edited.bots = [Bot(name: "Rex", role: "", orb: OrbConfig())]
        try write(edited)

        model.reloadStateFromDisk()

        #expect(await waitUntil("the file's state applied") { model.bots.map(\.name) == ["Rex"] })
        #expect(model.selection == .bot(edited.bots[0].id)) // the selected Orb is gone: back to the top of the sidebar
        #expect(model.sessions[atlas] == nil)
        #expect(model.lastSelectedBotID == edited.bots[0].id) // the Orb it fell back to is the one the user is on now
    }

    @Test @MainActor func theAppsOwnWriteIsNotReadAgain() async {
        let model = model()
        model.skills.append(Skill(slug: "minha", name: "Minha", summary: "", instructions: "x", orbIDs: [model.bots[0].id]))
        model.saveNow()
        let store = Store(directory: folder.url)
        store.flush()
        // The launch fingerprint is already a value: wait for the one of the file the save just wrote.
        #expect(await waitUntil("the save's fingerprint") {
            model.lastSavedStateFingerprint != nil && model.lastSavedStateFingerprint == FileFingerprint(of: stateURL)
        })

        // Between the save landing and the (cancelled) debounce, the file is the app's own: nothing to read again.
        model.skills.append(Skill(slug: "marcador", name: "Marcador", summary: "", instructions: "x", orbIDs: [model.bots[0].id]))
        model.checkStateFile()
        #expect(model.skills.map(\.slug).contains("marcador"))
        try? await Task.sleep(for: .milliseconds(600)) // the debounced save lands: still the app's own write
        model.checkStateFile()
        #expect(model.skills.map(\.slug).contains("marcador"))
    }

    @Test @MainActor func aChangeFromOutsideIsReadAndAPendingSaveDoesNotEatIt() async throws {
        let model = model()
        let atlas = model.bots[0].id
        model.skills.append(Skill(slug: "local", name: "Local", summary: "", instructions: "x", orbIDs: [atlas])) // a save in the air

        var edited = AppState.initial
        edited.skills = [Skill(slug: "externa", name: "Externa", summary: "", instructions: "x", orbIDs: [atlas])]
        try write(edited)
        model.checkStateFile()

        #expect(await waitUntil("the outside state applied") { model.skills.map(\.slug) == ["externa"] })
        try? await Task.sleep(for: .milliseconds(700)) // past the debounce: the pending write of the old state is dead
        let written = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: stateURL))
        #expect(written.skills.map(\.slug) == ["externa"])
    }

    // MARK: The watch

    @Test @MainActor func theWatchReadsAChangeFromOutsideButNotTheAppsOwn() async throws {
        let model = model()
        let atlas = model.bots[0].id
        model.startStateWatch()

        var edited = AppState.initial
        edited.skills = [Skill(slug: "externa", name: "Externa", summary: "", instructions: "x", orbIDs: [atlas])]
        try write(edited) // an atomic write: the watched file is replaced (rename+delete), the watch re-arms
        #expect(await waitUntil("the watch to reload") { model.skills.map(\.slug) == ["externa"] })

        // The app's own save lands (replace again): the fingerprint says it is ours, nothing is read back.
        model.skills.append(Skill(slug: "marcador", name: "Marcador", summary: "", instructions: "x", orbIDs: [atlas]))
        #expect(await waitUntil("the app's save to land") {
            FileFingerprint(of: stateURL) == model.lastSavedStateFingerprint && model.lastSavedStateFingerprint != nil
        })
        try? await Task.sleep(for: .milliseconds(600)) // the watch fired by then and found its own write
        #expect(model.skills.map(\.slug).contains("marcador"))

        // Gone, then back: the folder watch reports the file's return (the descriptor died with it).
        try FileManager.default.removeItem(at: stateURL)
        try? await Task.sleep(for: .milliseconds(700))
        edited.skills = [Skill(slug: "devolta", name: "Devolta", summary: "", instructions: "x", orbIDs: [atlas])]
        try write(edited)
        #expect(await waitUntil("the re-armed watch to reload") { model.skills.map(\.slug) == ["devolta"] })
    }
}
