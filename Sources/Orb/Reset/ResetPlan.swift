import Foundation

// "Redefinir o Orb": takes the app back to its first use. This file decides what goes (pure, so it is tested);
// `ResetExecutor` does it; `AppModel.resetEverything` stops the app first and quits after.

/// What the user chose in the "Redefinir o Orb?" sheet.
struct ResetOptions: Equatable, Sendable {
    enum Memories: Equatable, Sendable {
        /// Each Orb's memory goes to Memórias guardadas (with its profile), the ones already there stay.
        case keep
        /// The memories go too, the kept ones included. There is no undoing it.
        case erase
    }

    var memories = Memories.keep
    /// Also forget the keys and sign-ins the app keeps and the setup of the providers (Ajustes → Modelos).
    var leavesProviders = false
}

/// What the reset removes and what it leaves, decided from the app's state before it is stopped.
struct ResetPlan: Sendable {
    struct Orb: Sendable {
        var id: UUID
        var name: String
        var profile: KeptProfile
    }

    var options: ResetOptions
    /// The Orbs being reset: whose memory folder is kept under their name, with their profile.
    var orbs: [Orb]
    /// Accounts the app keeps in its Keychain service that must go: the connectors' secrets and, when the providers
    /// go too, their keys and the ChatGPT sign-in. Never Claude Code's own login (the app has no item of it).
    var secretAccounts: [String]
    /// What stays of `state.json` when the providers stay: their setup, the default model and what was learned of
    /// their models. nil when they go: no `state.json` is left, and the next launch is a first one.
    var survivors: Survivors?

    struct Survivors: Sendable {
        var providers: [ProviderAccount]
        var defaultModel: String
        var learnedContexts: [String: LearnedContext]
    }

    static func make(bots: [Bot], connectors: [MCPServerConfig], providers: [ProviderAccount], defaultModel: String,
                     learnedContexts: [String: LearnedContext], options: ResetOptions) -> ResetPlan {
        var accounts = Set<String>()
        for connector in connectors {
            accounts.insert(ConnectorSecrets.oauthAccount(id: connector.id)) // the login, if it has one
            for name in ConnectorSecrets.secretNames(of: connector) {
                accounts.insert(ConnectorSecrets.account(id: connector.id, name: name))
            }
        }
        if options.leavesProviders { accounts.formUnion(providerAccounts) }
        return ResetPlan(options: options,
                         orbs: bots.map { Orb(id: $0.id, name: $0.name, profile: KeptProfile($0)) },
                         secretAccounts: accounts.sorted(),
                         survivors: options.leavesProviders ? nil
                             : Survivors(providers: providers, defaultModel: defaultModel, learnedContexts: learnedContexts))
    }

    /// The Keychain accounts of the providers: one per provider (`Keychain.get(kind.rawValue)`; ChatGPT's holds the
    /// sign-in). Claude Code has none: its login belongs to its own CLI, which Orb never touches.
    static var providerAccounts: [String] {
        ProviderKind.allCases.filter { $0 != .claudeCode }.map(\.rawValue)
    }
}

/// What the "Redefinir o Orb?" sheet says will go, as counts. Pure: the words are tested.
struct ResetSummary: Equatable, Sendable {
    var orbs: Int
    /// nil until the files are counted.
    var conversations: Int?
    var routines: Int
    var connectors: Int
    var skills: Int
    /// The folder the Orbs work in as shown ("~/Orbs").
    var folder: String
    /// Whether the user's profile (text or photo) is filled in: it goes too.
    var profile = false

    /// "Some: 3 Orbs, 42 conversas, 5 rotinas, 2 conectores, 4 skills, o seu perfil, o histórico de uso e os ajustes." What is zero
    /// is left out; the settings always go back to their defaults, so the sentence is never empty.
    var goes: String {
        let conversationPart: String? = if let conversations { DeleteOrbSummary.counted(conversations, "conversa", "conversas") } else { "as conversas" }
        let parts = [DeleteOrbSummary.counted(orbs, "Orb", "Orbs"),
                     conversationPart,
                     DeleteOrbSummary.counted(routines, "rotina", "rotinas"),
                     DeleteOrbSummary.counted(connectors, "conector", "conectores"),
                     DeleteOrbSummary.counted(skills, "skill", "skills")].compactMap { $0 } + (profile ? ["o seu perfil"] : []) + ["o histórico de uso", "os ajustes"]
        return "Some: " + DeleteOrbSummary.list(parts) + "."
    }

    /// "Fica: a pasta ~/Orbs com os arquivos dos Orbs e, se você quiser, as memórias."
    var stays: String { "Fica: a pasta \(folder) com os arquivos dos Orbs e, se você quiser, as memórias." }

    /// The conversation files in the data folder: each Orb's current one, the archived ones and the routines'. Reads
    /// names only, so it is cheap, but still not for the main thread.
    static func conversationCount(in dataFolder: URL, files: FileManager = .default) -> Int {
        let folder = dataFolder.appending(path: "conversations")
        var total = 0
        for url in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                total += ((try? files.contentsOfDirectory(atPath: url.path)) ?? []).filter(isConversationFile).count
            } else if isConversationFile(name) {
                total += 1
            }
        }
        return total
    }

    /// `<id>.json` and `routine-<id>.json`, not the notes beside them (`.meta.json`, `index.json`) or copies set aside.
    private static func isConversationFile(_ name: String) -> Bool {
        guard name.hasSuffix(".json"), !name.hasSuffix(".meta.json"), name != "index.json" else { return false }
        return true
    }
}

/// What a reset removes, what it never removes, and when it refuses to run.
enum ResetGuard {
    enum Refusal: Error, Equatable {
        /// `--snapshot`, `--render-orbs`, `--render-icon`: made-up data, and never the user's.
        case developerRun
        /// A folder that cannot be the app's data folder (the root, the home folder, or one with the Orbs' own files).
        case unsafeFolder
        /// A folder given with `ORB_DATA_DIR` that does not look like the app's data (no `state.json`).
        case notAppData
    }

    /// The only things a reset removes from the data folder: what the app itself writes there. Anything else in the
    /// folder (a stranger's file, the migration marker) stays, so a folder chosen by mistake loses nothing it does
    /// not own.
    static let ownedFolders: Set<String> = ["conversations", "memoria", "anexos", "saidas", "conectores", "uso", ProfilePhoto.folderName]

    /// Whether the entry `name` of the data folder is the app's own (`state.json`, its set-aside copies, the unsent
    /// drafts and the folders above).
    static func removes(entry name: String) -> Bool {
        name == "state.json" || name.hasPrefix("state.json.") || name == Store.draftsFileName || ownedFolders.contains(name)
    }

    /// Preferences that survive a reset: the note of which Keychain accounts were already dealt with, so a key the
    /// reset removed is not copied back from OpenBot's old item (`LegacyKeychainLedger`). The marker that OpenBot's
    /// folder was copied (`LegacyMigration.marker`) is not in `removes(entry:)`, so it stays too.
    static func keepsPreference(_ key: String) -> Bool { key == LegacyKeychainLedger.key }

    /// Whether the reset may run on `dataFolder`. The app's own folder (`standardFolder`) is always fine. Any other
    /// (`ORB_DATA_DIR`) must not be, lie inside or surround the folders the Orbs work in (`~/Orbs`, and `workFolders`:
    /// the ones the Orbs were given, which hold files that are never deleted) and must look like the app's data.
    static func refusal(arguments: [String] = CommandLine.arguments, dataFolder: URL,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        standardFolder: URL = URL.applicationSupportDirectory.appending(path: "Orb"),
                        workFolders: [URL] = [], files: FileManager = .default) -> Refusal? {
        if DevRun.isActive(arguments: arguments) { return .developerRun }
        let folder = resolved(dataFolder), home = resolved(home)
        if folder.pathComponents.count < 3 || folder == home || isInside(home, folder) { return .unsafeFolder }
        guard folder != resolved(standardFolder) else { return nil }
        // A work folder that is the home folder (or around it) is the "no folder of its own" case, not a place for files.
        for work in (workFolders + [home.appending(path: "Orbs")]).map(resolved)
        where work != home && !isInside(home, work) && (isInside(folder, work) || isInside(work, folder)) {
            return .unsafeFolder
        }
        if !files.fileExists(atPath: folder.appending(path: "state.json").path) { return .notAppData }
        return nil
    }

    private static func resolved(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

    /// `url` is `folder` or lies inside it.
    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        url == folder || url.path.hasPrefix(folder.path.hasSuffix("/") ? folder.path : folder.path + "/")
    }
}
