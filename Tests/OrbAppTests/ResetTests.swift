import Foundation
import Testing
@testable import Orb

/// "Redefinir o Orb": what the plan and the executor remove, what they leave, and that nothing writes the old state
/// back. Everything happens in a temporary folder with a dictionary for the Keychain and a suite of its own for the
/// preferences: the real data, the real Keychain and the real preferences are never involved.
@Suite(.serialized) final class ResetTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbReset-\(UUID().uuidString)")
    let suite = "orb.tests.reset.\(UUID().uuidString)"
    var data: URL { root.appending(path: "Application Support/Orb") }
    var orbsFolder: URL { root.appending(path: "Orbs/Atlas") }
    var legacy: URL { root.appending(path: "Application Support/OpenBot") }
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    var preferences: DomainPreferences { DomainPreferences(defaults: defaults, domain: suite) }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ path: String, in folder: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (folder ?? data).appending(path: path).path)
    }

    private func read(_ path: String, in folder: URL? = nil) -> String? {
        try? String(contentsOf: (folder ?? data).appending(path: path), encoding: .utf8)
    }

    private let atlas = Bot(name: "Atlas", role: "Cuida da agenda", orb: OrbConfig(color: "rosa"), permissionMode: .bypass)
    private let luna = Bot(name: "Luna", role: "Escreve comigo", orb: OrbConfig(color: "menta"))
    private let connectorID = UUID()

    private var connector: MCPServerConfig {
        var config = MCPServerConfig(name: "GitHub", command: "npx")
        config.id = connectorID
        config.environment = ["GITHUB_TOKEN": "@keychain", "LANG": "pt_BR"]
        config.headers = ["Authorization": "@keychain"]
        return config
    }

    /// An app's folder as a user of a while has it, and what the app keeps outside it.
    private func put(_ value: String, _ account: String, in vault: MemoryVault) { _ = vault.set(value, account: account) }

    private func seed(vault: MemoryVault) throws {
        try write("{}", to: data.appending(path: "state.json"))
        try write("{}", to: data.appending(path: "state.json.corrupt-20260101-000000"))
        try write("{}", to: data.appending(path: "conversations/\(atlas.id.uuidString).json"))
        try write("{}", to: data.appending(path: "conversations/\(atlas.id.uuidString).meta.json"))
        try write("{}", to: data.appending(path: "conversations/\(atlas.id.uuidString)/\(UUID().uuidString).json"))
        try write("{}", to: data.appending(path: "conversations/\(atlas.id.uuidString)/index.json"))
        try write("{}", to: data.appending(path: "conversations/\(atlas.id.uuidString)/routine-\(UUID().uuidString).json"))
        try write("x", to: data.appending(path: "anexos/\(atlas.id.uuidString)/foto.jpg"))
        try write("x", to: data.appending(path: "saidas/\(atlas.id.uuidString)/saida.txt"))
        try write("{}", to: data.appending(path: "conectores/\(connectorID.uuidString).json"))
        try write("{}", to: data.appending(path: "uso/2026-10.json"))
        try write("---\ntipo: identidade\n---\n## Como funcionar\n- Seja direto.", to: data.appending(path: "memoria/\(atlas.id.uuidString)/nucleo/identidade.md"))
        try write("---\ntipo: fato\n---\nGosta de café.", to: data.appending(path: "memoria/\(atlas.id.uuidString)/fatos/cafe.md"))
        try write("lixo", to: data.appending(path: "memoria/\(atlas.id.uuidString)/index.sqlite"))
        try write("---\ntipo: fato\n---\nMora em SP.", to: data.appending(path: "memoria/\(luna.id.uuidString)/fatos/sp.md"))
        try write("---\ntipo: fato\n---\nAntigo.", to: data.appending(path: "memoria/_guardadas/Velho – 2026-01-02 03.04/fatos/antigo.md"))
        try write("", to: data.appending(path: LegacyMigration.marker))
        // What the Orbs made, and what is not the app's.
        try write("minhas notas", to: orbsFolder.appending(path: "notas.txt"))
        try write("{\"bots\":[]}", to: legacy.appending(path: "state.json"))
        try write("outro app", to: root.appending(path: "Application Support/OutroApp/dados.json"))

        put("sk-aaa", "openai", in: vault)
        put("sk-bbb", "anthropic", in: vault)
        put("{\"token\":1}", "chatgpt", in: vault)
        put("ghp-1", ConnectorSecrets.account(id: connectorID, name: "GITHUB_TOKEN"), in: vault)
        put("Bearer 2", ConnectorSecrets.account(id: connectorID, name: "Authorization"), in: vault)
        put("de outro item", "outro.item", in: vault)

        let defaults = defaults
        defaults.set(false, forKey: "notifyWhenDone")
        defaults.set("models", forKey: "settingsTab")
        defaults.set(["openai"], forKey: LegacyKeychainLedger.key)
    }

    private var providers: [ProviderAccount] {
        var openai = ProviderAccount(kind: .openai)
        openai.models = [ProviderModel(id: "gpt-x", name: "GPT X", format: .chat)]
        return [openai, ProviderAccount(kind: .claudeCode)]
    }

    private func plan(_ options: ResetOptions) -> ResetPlan {
        ResetPlan.make(bots: [atlas, luna], connectors: [connector], providers: providers, defaultModel: "openai/gpt-x",
                       learnedContexts: ["openai/gpt-x": LearnedContext(tokens: 8_000, date: .now)], options: options)
    }

    private func executor(_ vault: MemoryVault, legacyFolder: URL? = nil) -> ResetExecutor {
        ResetExecutor(directory: data, vault: vault, preferences: preferences, legacyFolder: legacyFolder)
    }

    // MARK: The plan

    @Test func theSecretsToRemoveAreTheConnectorsOwnAndTheProvidersOnlyWhenTheyGo() {
        let staying = plan(ResetOptions(memories: .keep, leavesProviders: false))
        #expect(staying.secretAccounts == [ConnectorSecrets.account(id: connectorID, name: "Authorization"),
                                            ConnectorSecrets.account(id: connectorID, name: "GITHUB_TOKEN")].sorted())
        #expect(staying.survivors?.defaultModel == "openai/gpt-x")
        #expect(staying.survivors?.providers == providers)

        let leaving = plan(ResetOptions(memories: .erase, leavesProviders: true))
        #expect(Set(leaving.secretAccounts).isSuperset(of: ["openai", "anthropic", "chatgpt", "custom", "xai"]))
        #expect(!leaving.secretAccounts.contains("claudeCode")) // its login belongs to the CLI
        #expect(leaving.survivors == nil)
        #expect(leaving.orbs.map(\.name) == ["Atlas", "Luna"])
    }

    @Test func theProfileInThePlanHoldsNoPermissions() throws {
        let profile = try #require(plan(ResetOptions()).orbs.first?.profile)
        #expect(profile == KeptProfile(name: "Atlas", role: "Cuida da agenda", orb: OrbConfig(color: "rosa")))
    }

    @Test func theSummaryNamesWhatGoesAndLeavesOutWhatIsZero() {
        let full = ResetSummary(orbs: 3, conversations: 42, routines: 5, connectors: 2, skills: 4, folder: "~/Orbs")
        #expect(full.goes == "Some: 3 Orbs, 42 conversas, 5 rotinas, 2 conectores, 4 skills, o histórico de uso e os ajustes.")
        #expect(full.stays == "Fica: a pasta ~/Orbs com os arquivos dos Orbs e, se você quiser, as memórias.")
        let small = ResetSummary(orbs: 1, conversations: 1, routines: 0, connectors: 0, skills: 0, folder: "~/Orbs")
        #expect(small.goes == "Some: 1 Orb, 1 conversa, o histórico de uso e os ajustes.")
        #expect(ResetSummary(orbs: 1, conversations: 0, routines: 1, connectors: 1, skills: 1, folder: "~").goes
            == "Some: 1 Orb, 1 rotina, 1 conector, 1 skill, o histórico de uso e os ajustes.")
        #expect(ResetSummary(orbs: 0, conversations: 0, routines: 0, connectors: 0, skills: 0, folder: "~").goes == "Some: o histórico de uso e os ajustes.")
        #expect(ResetSummary(orbs: 2, conversations: nil, routines: 0, connectors: 0, skills: 0, folder: "~").goes
            == "Some: 2 Orbs, as conversas, o histórico de uso e os ajustes.")
    }

    @Test func conversationsAreCountedByTheirFilesNotTheNotesBesideThem() throws {
        try seed(vault: MemoryVault())
        // Atlas: the current one, an archived one and a routine's; the notes (`.meta.json`, `index.json`) do not count.
        #expect(ResetSummary.conversationCount(in: data) == 3)
    }

    // MARK: The executor

    @Test func keepingTheMemoriesAndTheProvidersRemovesTheRestAndTouchesNothingOutside() throws {
        let vault = MemoryVault()
        try seed(vault: vault)
        let outsideBefore = try FileManager.default.subpathsOfDirectory(atPath: root.appending(path: "Orbs").path)

        let report = executor(vault).run(plan(ResetOptions(memories: .keep, leavesProviders: false)), now: Date(timeIntervalSince1970: 1_790_000_000))

        #expect(report.isComplete && report.keptMemories == 2)
        // Gone: the conversations (current, archived, routines'), the attachments, the outputs, the old copies.
        for gone in ["conversations", "anexos", "saidas", "conectores", "uso", "state.json.corrupt-20260101-000000",
                     "memoria/\(atlas.id.uuidString)", "memoria/\(luna.id.uuidString)"] {
            #expect(!exists(gone), "\(gone) should be gone")
        }
        // Kept: the marker of the OpenBot copy, the earlier kept memory and the two new ones, each with its profile.
        #expect(exists(LegacyMigration.marker))
        #expect(exists("memoria/_guardadas/Velho – 2026-01-02 03.04/fatos/antigo.md"))
        let kept = KeptMemories.list(in: data.appending(path: "memoria"))
        #expect(Set(kept.map(\.name)) == ["Atlas", "Luna", "Velho"])
        #expect(kept.first { $0.name == "Atlas" }?.profile == KeptProfile(name: "Atlas", role: "Cuida da agenda", orb: OrbConfig(color: "rosa")))
        #expect(kept.first { $0.name == "Luna" }?.pageCount == 1)
        #expect(read("memoria/_guardadas/\(kept.first { $0.name == "Atlas" }!.id)/fatos/cafe.md")?.contains("café") == true)
        // The state of a first use, with the providers' setup.
        let state = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: data.appending(path: "state.json")))
        #expect(state.providers == providers && state.defaultModel == "openai/gpt-x")
        #expect(state.learnedContexts["openai/gpt-x"]?.tokens == 8_000)
        #expect(state.bots.isEmpty && state.routines.isEmpty && state.connectors.isEmpty) // the welcome comes next
        // Keychain: the connector's secrets go; the keys and the sign-in stay; an item that is not ours is not touched.
        #expect(vault.accounts == ["openai", "anthropic", "chatgpt", "outro.item"])
        // Preferences: back to the default, but for the note of which Keychain accounts came over from OpenBot.
        #expect(defaults.object(forKey: "notifyWhenDone") == nil && defaults.object(forKey: "settingsTab") == nil)
        #expect(defaults.object(forKey: LegacyKeychainLedger.key) as? [String] == ["openai"])
        // Outside the data folder: not one file changed.
        #expect(try FileManager.default.subpathsOfDirectory(atPath: root.appending(path: "Orbs").path) == outsideBefore)
        #expect(read("notas.txt", in: orbsFolder) == "minhas notas")
        #expect(read("state.json", in: legacy) == "{\"bots\":[]}")
        #expect(read("dados.json", in: root.appending(path: "Application Support/OutroApp")) == "outro app")
    }

    @Test func erasingEverythingAndLeavingTheProvidersLeavesOnlyTheMarker() throws {
        let vault = MemoryVault()
        try seed(vault: vault)

        let report = executor(vault).run(plan(ResetOptions(memories: .erase, leavesProviders: true)))

        #expect(report.isComplete && report.keptMemories == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path) == [LegacyMigration.marker])
        #expect(vault.accounts == ["outro.item"]) // keys, the ChatGPT sign-in and the connectors' secrets are all gone
        #expect(read("notas.txt", in: orbsFolder) == "minhas notas") // what the Orbs made is never deleted
    }

    @Test func theMigrationMarkerStaysSoNothingIsCopiedBackFromOpenBot() throws {
        let vault = MemoryVault()
        try seed(vault: vault)

        _ = executor(vault).run(plan(ResetOptions(memories: .erase, leavesProviders: true)))

        #expect(exists(LegacyMigration.marker))
        // And the launch that follows does not copy OpenBot's folder over the new one.
        #expect(!LegacyMigration.run(into: data, from: legacy, oldPreferences: ["notifyWhenDone": false], into: preferencesStore()))
        #expect(!exists("state.json"))
    }

    @Test func onlyWhatTheAppWroteIsRemovedFromTheDataFolder() throws {
        let vault = MemoryVault()
        try seed(vault: vault)
        try write("meu", to: data.appending(path: "notas-minhas.txt"))
        try write("meu", to: data.appending(path: "Outra pasta/dentro.txt"))
        try write("", to: data.appending(path: ".migrado-qualquer"))

        _ = executor(vault).run(plan(ResetOptions(memories: .erase, leavesProviders: true)))

        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: data.path))
            == [LegacyMigration.marker, "notas-minhas.txt", "Outra pasta", ".migrado-qualquer"])
        #expect(read("dentro.txt", in: data.appending(path: "Outra pasta")) == "meu")
    }

    /// The Keychain's own paths (`Keychain.lookup`, `Keychain.write`) on a dictionary: the vault the app uses, without
    /// the real Keychain. OpenBot's old items are in the same dictionary, under their service.
    private final class FakeKeychain: KeychainItems, SecretVault, @unchecked Sendable {
        var stored: [String: String] = [:]
        var reads: [String] = []
        var ledger: LegacyKeychainLedger
        init(ledger: LegacyKeychainLedger) { self.ledger = ledger }
        private func key(_ account: String, _ service: String) -> String { "\(service)/\(account)" }
        func read(_ account: String, service: String) -> String? {
            reads.append(key(account, service))
            return stored[key(account, service)]
        }
        func replace(_ value: String, account: String, service: String) -> Bool {
            stored[key(account, service)] = value.isEmpty ? nil : value
            return true
        }
        func get(_ account: String) -> String? { Keychain.lookup(account, service: Keychain.service, items: self, ledger: ledger) }
        func set(_ value: String, account: String) -> Bool {
            Keychain.write(value, account: account, service: Keychain.service, items: self, ledger: ledger)
        }
        func remove(_ account: String) { _ = set("", account: account) }
    }

    @Test func leavingTheProvidersDoesNotBringTheKeysBackFromOpenBot() throws {
        try seed(vault: MemoryVault())
        let keychain = FakeKeychain(ledger: LegacyKeychainLedger(preferences: defaults))
        // Orb's own keys, and OpenBot's old items (one of them never copied, because the key was never used).
        keychain.stored = ["\(Keychain.service)/openai": "sk-aaa", "\(Keychain.service)/chatgpt": "login",
                           "\(Keychain.legacyService)/openai": "sk-aaa", "\(Keychain.legacyService)/anthropic": "sk-velha",
                           "\(Keychain.legacyService)/chatgpt": "login-velho"]
        defaults.removeObject(forKey: LegacyKeychainLedger.key)
        let executor = ResetExecutor(directory: data, vault: keychain, preferences: preferences, legacyFolder: nil)

        _ = executor.run(plan(ResetOptions(memories: .keep, leavesProviders: true)))
        keychain.reads = []

        // The next launch: every account is gone and none is copied from the backup.
        for account in ["openai", "anthropic", "chatgpt"] { #expect(keychain.get(account) == nil, "\(account) came back") }
        #expect(!keychain.reads.contains { $0.hasPrefix(Keychain.legacyService) })
        #expect(keychain.stored.keys.filter { $0.hasPrefix(Keychain.service) }.isEmpty)
        // The backup itself is left as it was, and the note of what was dealt with survived the preferences' reset.
        #expect(keychain.stored["\(Keychain.legacyService)/anthropic"] == "sk-velha")
        let ledger = LegacyKeychainLedger(preferences: defaults)
        #expect(["openai", "anthropic", "chatgpt"].allSatisfy(ledger.handled))
        #expect(defaults.object(forKey: "settingsTab") == nil)
    }

    @Test func keepingTheProvidersLeavesTheirKeysAndTheNoteAlone() throws {
        try seed(vault: MemoryVault())
        let keychain = FakeKeychain(ledger: LegacyKeychainLedger(preferences: defaults))
        keychain.stored = ["\(Keychain.service)/openai": "sk-aaa", "\(Keychain.legacyService)/anthropic": "sk-velha"]
        let executor = ResetExecutor(directory: data, vault: keychain, preferences: preferences, legacyFolder: nil)

        _ = executor.run(plan(ResetOptions(memories: .keep, leavesProviders: false)))

        #expect(keychain.get("openai") == "sk-aaa")
        #expect(keychain.get("anthropic") == "sk-velha") // not copied yet: still comes over when it is first used
        let ledger = LegacyKeychainLedger(preferences: defaults)
        #expect(ledger.handled("openai") && ledger.handled("anthropic")) // the note from before is still there
    }

    @Test func aMissingMarkerIsMadeWhenOpenBotsDataIsStillThere() throws {
        let vault = MemoryVault()
        try seed(vault: vault)
        try FileManager.default.removeItem(at: data.appending(path: LegacyMigration.marker))

        _ = executor(vault, legacyFolder: legacy).run(plan(ResetOptions(memories: .erase, leavesProviders: true)))

        #expect(exists(LegacyMigration.marker))
        #expect(!LegacyMigration.run(into: data, from: legacy, oldPreferences: [:], into: preferencesStore()))
        #expect(!exists("state.json"))
    }

    @Test func noMarkerIsInventedWhenThereIsNothingToMigrate() throws {
        let vault = MemoryVault()
        try seed(vault: vault)
        try FileManager.default.removeItem(at: data.appending(path: LegacyMigration.marker))
        try FileManager.default.removeItem(at: legacy)

        _ = executor(vault, legacyFolder: legacy).run(plan(ResetOptions(memories: .erase, leavesProviders: true)))

        #expect(!exists(LegacyMigration.marker))
    }

    @Test func aMemoryOfNoOrbInThePlanIsKeptAsOrb() throws {
        let vault = MemoryVault()
        try seed(vault: vault)
        let stray = UUID()
        try write("---\ntipo: fato\n---\nSolta.", to: data.appending(path: "memoria/\(stray.uuidString)/fatos/solta.md"))
        try write("solto", to: data.appending(path: "memoria/arquivo-solto.txt"))

        let report = executor(vault).run(plan(ResetOptions(memories: .keep)))

        #expect(report.keptMemories == 3)
        #expect(KeptMemories.list(in: data.appending(path: "memoria")).filter { $0.name == "Orb" }.count == 1)
        #expect(!exists("memoria/arquivo-solto.txt"))
    }

    @Test func aFailureOnOneStepDoesNotStopTheOthers() throws {
        let vault = MemoryVault()
        try seed(vault: vault)
        // `_guardadas` is a file here, so no memory can move into it.
        try FileManager.default.removeItem(at: data.appending(path: "memoria/_guardadas"))
        try write("não sou uma pasta", to: data.appending(path: "memoria/_guardadas"))

        let report = executor(vault).run(plan(ResetOptions(memories: .keep, leavesProviders: true)))

        #expect(!report.isComplete && report.keptMemories == 0)
        #expect(report.failures.contains("memoria/\(atlas.id.uuidString)") && report.failures.contains("memoria/\(luna.id.uuidString)"))
        #expect(exists("memoria/\(atlas.id.uuidString)/fatos/cafe.md")) // a memory that could not be kept is not deleted
        #expect(!exists("conversations") && !exists("anexos") && !exists("state.json"))
        #expect(vault.accounts == ["outro.item"])
        #expect(defaults.object(forKey: "settingsTab") == nil)
    }

    /// Holds the data folder's writer queue until the returned function is called (sync, so a semaphore is fine).
    private func parkWriter() -> () -> Void {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        WriterQueues.queue(for: data).async { started.signal(); release.wait() }
        started.wait()
        return { release.signal() }
    }

    private func preferencesStore() -> DictionaryPreferences { DictionaryPreferences() }

    // MARK: Never in a developer mode, never on a folder that is not the app's

    @Test func developerModesRefuse() {
        for flag in DevRun.flags {
            #expect(ResetGuard.refusal(arguments: ["Orb", flag, "saida.png"], dataFolder: data, standardFolder: data) == .developerRun)
        }
        #expect(ResetGuard.refusal(arguments: ["Orb"], dataFolder: data, standardFolder: data) == nil)
    }

    @Test func aFolderThatCannotBeTheAppsIsRefused() {
        let home = URL(fileURLWithPath: "/Users/alguem")
        let standard = home.appending(path: "Library/Application Support/Orb")
        func refusal(_ folder: URL, work: [URL] = []) -> ResetGuard.Refusal? {
            ResetGuard.refusal(arguments: ["Orb"], dataFolder: folder, home: home, standardFolder: standard, workFolders: work)
        }
        #expect(refusal(URL(fileURLWithPath: "/")) == .unsafeFolder)
        #expect(refusal(URL(fileURLWithPath: "/Users")) == .unsafeFolder)
        #expect(refusal(home) == .unsafeFolder)
        #expect(refusal(standard) == nil)
    }

    @Test func theFoldersTheOrbsWorkInAreNeverADataFolder() throws {
        // The data folder is `ORB_DATA_DIR` here (not the standard one), as in the review's cases: even with a
        // `state.json` in it, a folder of the Orbs' own files is refused.
        let home = root.appending(path: "casa")
        let standard = home.appending(path: "Library/Application Support/Orb")
        func refusal(_ folder: URL, work: [URL] = []) throws -> ResetGuard.Refusal? {
            try write("{}", to: folder.appending(path: "state.json"))
            return ResetGuard.refusal(arguments: ["Orb"], dataFolder: folder, home: home, standardFolder: standard, workFolders: work)
        }
        #expect(try refusal(home.appending(path: "Orbs")) == .unsafeFolder)
        #expect(try refusal(home.appending(path: "Orbs/Atlas")) == .unsafeFolder)
        #expect(try refusal(home.appending(path: "Orbs/Atlas/dados")) == .unsafeFolder)
        let projects = home.appending(path: "Projetos/orb-do-lucas")
        #expect(try refusal(projects.appending(path: "dados"), work: [projects]) == .unsafeFolder)
        #expect(try refusal(projects, work: [projects]) == .unsafeFolder)
        // A folder around ~/Orbs.
        #expect(ResetGuard.refusal(arguments: ["Orb"], dataFolder: home.deletingLastPathComponent(), home: home, standardFolder: standard)
            == .unsafeFolder)
        // An Orb working in the home folder does not make the standard folder (inside it) unsafe.
        #expect(ResetGuard.refusal(arguments: ["Orb"], dataFolder: standard, home: home, standardFolder: standard, workFolders: [home]) == nil)
    }

    @Test func aFolderThatDoesNotLookLikeTheOrbsDataIsRefused() throws {
        let home = root.appending(path: "casa")
        let standard = home.appending(path: "Library/Application Support/Orb")
        func refusal(_ folder: URL) -> ResetGuard.Refusal? {
            ResetGuard.refusal(arguments: ["Orb"], dataFolder: folder, home: home, standardFolder: standard)
        }
        // Some folder with files that are not the app's, and an external disk.
        try write("meu", to: home.appending(path: "Documents/contrato.pdf"))
        try write("meu", to: root.appending(path: "Volumes/Externo/foto.jpg"))
        #expect(refusal(home.appending(path: "Documents")) == .notAppData)
        #expect(refusal(root.appending(path: "Volumes/Externo")) == .notAppData)
        // A folder given with `ORB_DATA_DIR` that has the app's state is fine; so is the standard one, even before it has one.
        try write("{}", to: root.appending(path: "dados-de-teste/state.json"))
        #expect(refusal(root.appending(path: "dados-de-teste")) == nil)
        #expect(refusal(standard) == nil)
    }

    @Test func theRelaunchWaitsForTheAppToEndAndOpensTheBundleAgain() {
        let command = AppRelaunch.command(pid: 4242, bundle: URL(fileURLWithPath: "/Applications/Orb.app"))
        #expect(command.executable.path == "/bin/sh")
        #expect(command.arguments.suffix(2) == ["4242", "/Applications/Orb.app"])
        #expect(AppRelaunch.bundleURL() == nil) // the test runner is not an app
    }

    /// Runs the relaunch script with `open` replaced by `echo` and the wait cut short, to see what it would open.
    private func relaunchOutput(pid: Int32, tries: Int) throws -> String {
        let script = AppRelaunch.script.replacingOccurrences(of: "/usr/bin/open", with: "/bin/echo opened")
            .replacingOccurrences(of: "-lt 100", with: "-lt \(tries)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(pid), "/Applications/Orb.app"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func theRelaunchOpensTheAppOnlyOnceTheOldProcessIsGone() throws {
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        // The old process has ended: the app opens (once, without -n, so a hand-opened instance is not doubled).
        #expect(try relaunchOutput(pid: finished.processIdentifier, tries: 5) == "opened /Applications/Orb.app")
        #expect(!AppRelaunch.script.contains("open -n") && !AppRelaunch.script.contains(" -n "))
        // The old process is still there when the wait ends (this test's own): nothing is opened.
        #expect(try relaunchOutput(pid: ProcessInfo.processInfo.processIdentifier, tries: 2) == "")
    }

    // MARK: The app

    @MainActor private func appModel(vault: MemoryVault, arguments: [String] = ["Orb"], unsavedStretch: Bool = false) throws -> (AppModel, Flag) {
        var state = AppState.initial
        state.bots = [atlas, luna]
        state.connectors = [connector]
        state.providers = providers
        state.defaultModel = "openai/gpt-x"
        state.routines = [Routine(name: "Resumo", botID: atlas.id, prompt: "resuma", schedule: .everyHours(1))]
        try seed(vault: vault)
        let store = Store(directory: data)
        store.save(state)
        if unsavedStretch { // Atlas talked after its last session page
            store.save(Conversation(items: [TranscriptItem(.user(text: "Lembre que prefiro reuniões às terças", attachments: []))],
                                    messages: [.user("Lembre que prefiro reuniões às terças")]), for: atlas.id)
        }
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false, secretVault: vault)
        let finished = Flag()
        model.resetEnvironment.arguments = arguments
        model.resetEnvironment.preferences = preferences
        model.resetEnvironment.legacyFolder = legacy
        model.resetEnvironment.home = root
        model.resetEnvironment.standardFolder = data
        model.resetEnvironment.finish = { finished.raise() }
        return (model, finished)
    }

    @Test @MainActor func resettingTheAppStopsItWipesTheDataAndQuits() async throws {
        let vault = MemoryVault()
        let (model, finished) = try appModel(vault: vault)

        let outcome = await model.resetEverything(ResetOptions(memories: .keep, leavesProviders: false))

        guard case .done(let report) = outcome else { Issue.record("the reset did not run: \(outcome)"); return }
        #expect(report.isComplete)
        #expect(finished.isRaised) // the last step: quit, and open the app again
        #expect(model.isResetting)
        #expect(!exists("conversations") && !exists("anexos") && !exists("saidas"))
        #expect(KeptMemories.count(in: data.appending(path: "memoria")) == 3) // Velho, Atlas and Luna
        #expect(vault.get(ConnectorSecrets.account(id: connectorID, name: "GITHUB_TOKEN")) == nil)
        #expect(vault.get("openai") == "sk-aaa")
        #expect(model.routines.isEmpty && model.queuedRoutines.isEmpty)
    }

    @Test @MainActor func keepingTheMemoriesSavesTheLastStretchOfTheConversationFirst() async throws {
        let (model, _) = try appModel(vault: MemoryVault(), unsavedStretch: true)

        let outcome = await model.resetEverything(ResetOptions(memories: .keep, leavesProviders: false))

        guard case .done(let report) = outcome else { Issue.record("the reset did not run: \(outcome)"); return }
        #expect(report.isComplete)
        let kept = try #require(KeptMemories.list(in: data.appending(path: "memoria")).first { $0.name == "Atlas" })
        let pages = try FileManager.default.contentsOfDirectory(atPath: kept.url.appending(path: "sessoes").path)
        #expect(pages.count == 1)
        let page = try String(contentsOf: kept.url.appending(path: "sessoes/\(pages[0])"), encoding: .utf8)
        #expect(page.contains("reuniões às terças"))
        // The folder that was kept is the one the page went into: the old place has nothing left.
        #expect(!exists("memoria/\(atlas.id.uuidString)"))
    }

    @Test @MainActor func erasingEverythingSavesNoStretchAndKeepsNothing() async throws {
        let (model, _) = try appModel(vault: MemoryVault(), unsavedStretch: true)

        _ = await model.resetEverything(ResetOptions(memories: .erase, leavesProviders: false))

        #expect(!exists("memoria"))
        #expect(KeptMemories.count(in: data.appending(path: "memoria")) == 0)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: data.path)) == [LegacyMigration.marker, "state.json"])
    }

    @Test @MainActor func nothingIsSentOrAdoptedWhileTheResetRuns() async throws {
        let (model, _) = try appModel(vault: MemoryVault())
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        model.clientOverride = { StuckModel() }
        model.isResetting = true

        #expect(!model.send("oi", to: atlas.id))
        #expect(model.turns[atlas.id] == nil)
        let kept = try #require(KeptMemories.list(in: data.appending(path: "memoria")).first)
        let bot = model.createBot(name: "Nova", role: "", orb: OrbConfig(), model: "", mode: .ask, folder: .home, adopting: kept)
        #expect(exists("memoria/_guardadas/\(kept.id)/fatos/antigo.md")) // the kept memory is where it was
        #expect(!exists("memoria/\(bot.id.uuidString)"))
    }

    @Test @MainActor func nothingWritesTheOldStateBackAfterTheCleanUp() async throws {
        let (model, _) = try appModel(vault: MemoryVault())
        // A write is still waiting in the writer's queue when the reset begins.
        let release = parkWriter()
        var old = AppState.initial
        old.bots = [Bot(name: "Antigo", role: "", orb: OrbConfig())]
        model.store.save(old)
        model.store.save(Conversation(items: [TranscriptItem(.user(text: "oi", attachments: []))], messages: [.user("oi")]), for: atlas.id)

        let reset = Task { await model.resetEverything(ResetOptions(memories: .erase, leavesProviders: true)) }
        await waitUntil("the reset to begin") { model.isResetting }
        release()
        _ = await reset.value

        // What the app does as it quits, and what anything still running might try.
        model.saveNow()
        model.update(atlas.id) { $0.name = "Depois" }
        model.store.save(old)
        model.store.save(Conversation(items: [TranscriptItem(.user(text: "de novo", attachments: []))], messages: [.user("de novo")]), for: luna.id)
        model.store.flush()
        try await Task.sleep(for: .milliseconds(450)) // longer than the delay of a scheduled save

        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path) == [LegacyMigration.marker])
    }

    @Test @MainActor func aDeveloperModeNeverResetsAnything() async throws {
        let vault = MemoryVault()
        let (model, finished) = try appModel(vault: vault, arguments: ["Orb", "--snapshot", "settings-general", "saida.png"])

        let outcome = await model.resetEverything(ResetOptions(memories: .erase, leavesProviders: true))

        #expect(outcome == .refused(.developerRun))
        #expect(!model.isResetting && !finished.isRaised)
        #expect(exists("state.json") && exists("memoria/\(atlas.id.uuidString)/fatos/cafe.md"))
        #expect(vault.get("openai") == "sk-aaa" && defaults.object(forKey: "settingsTab") as? String == "models")
    }

    @Test @MainActor func aSecondResetWhileOneRunsIsIgnored() async throws {
        let (model, _) = try appModel(vault: MemoryVault())
        model.isResetting = true
        #expect(await model.resetEverything(ResetOptions()) == .alreadyRunning)
        #expect(exists("state.json"))
    }

    @Test @MainActor func aRunningTurnIsStoppedBeforeTheDataGoes() async throws {
        let (model, _) = try appModel(vault: MemoryVault())
        let model_ = model
        model_.providers = [ProviderAccount(kind: .custom)]
        model_.defaultModel = "custom/modelo"
        let stuck = StuckModel()
        model_.clientOverride = { stuck }
        #expect(model_.send("oi", to: atlas.id))
        await waitUntil("the model to be called") { await stuck.calls >= 1 }
        #expect(model_.isWorking(atlas.id))

        let outcome = await model_.resetEverything(ResetOptions(memories: .erase, leavesProviders: true))

        guard case .done = outcome else { Issue.record("the reset did not run: \(outcome)"); return }
        #expect(model_.turns[atlas.id] == nil && !model_.isWorking(atlas.id))
        await waitUntil("the model's call to be cancelled") { await stuck.wasCancelled }
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path) == [LegacyMigration.marker])
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

/// Preferences in a dictionary (what `LegacyMigration.run` writes to).
private final class DictionaryPreferences: PreferenceStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// A model that never answers, and notes when its call is cancelled.
private actor StuckState {
    var calls = 0
    var wasCancelled = false
    func called() { calls += 1 }
    func cancelled() { wasCancelled = true }
}

private struct StuckModel: LLMClient {
    let state = StuckState()
    var calls: Int { get async { await state.calls } }
    var wasCancelled: Bool { get async { await state.wasCancelled } }

    func stream(model: String, messages: [ChatMessage], tools: [ToolSpec], toolChoice: ToolChoice) -> AsyncThrowingStream<LLMEvent, Error> {
        let state = state
        return AsyncThrowingStream { continuation in
            let task = Task {
                await state.called()
                try? await Task.sleep(for: .seconds(600))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await state.cancelled() }
            }
        }
    }
}
