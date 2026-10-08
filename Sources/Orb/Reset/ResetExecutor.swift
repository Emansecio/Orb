import Foundation

/// The preferences of the app (UserDefaults), as the reset sees them: everything goes back to the default except
/// what `keeping` says to leave. Tests use a suite of their own.
protocol ResettablePreferences: Sendable {
    func removeAll(keeping isKept: (String) -> Bool)
}

/// The keys the app itself saved in its preferences domain. Keys of the system (the global domain) are not in it, so
/// they are never touched.
struct DomainPreferences: ResettablePreferences, @unchecked Sendable { // UserDefaults is thread-safe
    var defaults: UserDefaults
    var domain: String

    /// The app's own preferences.
    static var app: DomainPreferences {
        DomainPreferences(defaults: .standard, domain: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
    }

    func removeAll(keeping isKept: (String) -> Bool) {
        for key in (defaults.persistentDomain(forName: domain) ?? [:]).keys where !isKept(key) {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
    }
}

/// What a reset did, to say it and to test it.
struct ResetReport: Equatable, Sendable {
    /// Orb memories moved to Memórias guardadas.
    var keptMemories = 0
    /// What could not be removed or moved (nothing else is skipped because of it).
    var failures: [String] = []

    var isComplete: Bool { failures.isEmpty }
}

/// Carries out a `ResetPlan` on the data folder, the Keychain items and the preferences, all handed in. It touches
/// nothing else: not the folders the Orbs work in (`~/Orbs`), not OpenBot's folder, not Claude Code's login.
///
/// Blocking file work: it runs off the main thread (`AppModel.resetEverything`). The app has already stopped
/// everything that could write and sealed the writers; the executor does not need them.
struct ResetExecutor {
    var directory: URL
    var vault: any SecretVault
    var preferences: any ResettablePreferences
    /// OpenBot's old folder: if it holds data and the marker that it was copied is missing, the marker is made, so
    /// that a launch right after the reset does not copy it back.
    var legacyFolder: URL?
    var files = FileManager.default

    /// Keeps the memories (when asked), removes what the app wrote in the data folder (`ResetGuard.removes`: nothing
    /// else, so the migration markers and any file that is not the app's stay), deletes the secrets, takes the preferences back to the default and leaves the new `state.json` (only when the providers
    /// stay). Each step goes on if another failed: what is left says so in the report.
    func run(_ plan: ResetPlan, now: Date = .now) -> ResetReport {
        var report = ResetReport()
        let entries = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []

        // The memories first: what is to be kept is safe before anything is removed.
        let memories = directory.appending(path: "memoria", directoryHint: .isDirectory)
        if plan.options.memories == .keep {
            keepMemories(in: memories, plan: plan, now: now, report: &report)
        }
        for url in entries where ResetGuard.removes(entry: url.lastPathComponent) {
            if url.lastPathComponent == memories.lastPathComponent && plan.options.memories == .keep { continue }
            remove(url, report: &report)
        }
        if plan.options.memories == .keep { removeLeftovers(of: memories, report: &report) }

        for account in plan.secretAccounts { vault.remove(account) }
        preferences.removeAll(keeping: ResetGuard.keepsPreference)
        writeSurvivors(plan.survivors, report: &report)
        markLegacyAsMigrated()
        return report
    }

    // MARK: Memories

    /// Every Orb's memory folder (`memoria/<id>`) goes to `_guardadas` under the Orb's name, with its profile. A
    /// folder that belongs to no Orb of the plan (left by one that no longer exists) is kept too, as "Orb". A folder that
    /// cannot be moved is left where it is.
    private func keepMemories(in memories: URL, plan: ResetPlan, now: Date, report: inout ResetReport) {
        let orbs = Dictionary(plan.orbs.map { ($0.id.uuidString.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let folders = (try? files.contentsOfDirectory(at: memories, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = folder.lastPathComponent
            guard name != KeptMemories.folderName,
                  (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  UUID(uuidString: name) != nil else { continue }
            let orb = orbs[name.lowercased()]
            if KeptMemories.keep(folder, name: orb?.name ?? "Orb", profile: orb?.profile, in: memories, now: now, files: files) != nil {
                report.keptMemories += 1
            } else {
                report.failures.append("memoria/\(name)")
            }
        }
    }

    /// What is in `memoria/` besides the kept memories (stray files, a folder that could not be moved is not touched).
    private func removeLeftovers(of memories: URL, report: inout ResetReport) {
        for url in (try? files.contentsOfDirectory(at: memories, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            if name == KeptMemories.folderName || report.failures.contains("memoria/\(name)") { continue }
            remove(url, report: &report)
        }
    }

    // MARK: Files

    private func remove(_ url: URL, report: inout ResetReport) {
        do { try files.removeItem(at: url) } catch { report.failures.append(url.lastPathComponent) }
    }

    /// The `state.json` of a first use that keeps the providers' setup (the Orb starts as it does without a file).
    private func writeSurvivors(_ survivors: ResetPlan.Survivors?, report: inout ResetReport) {
        guard let survivors else { return }
        var state = AppState.initial
        state.providers = survivors.providers
        state.defaultModel = survivors.defaultModel
        state.learnedContexts = survivors.learnedContexts
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: directory.appending(path: "state.json"), options: .atomic)
        } catch {
            report.failures.append("state.json")
        }
    }

    private func markLegacyAsMigrated() {
        let marker = directory.appending(path: LegacyMigration.marker)
        guard let legacyFolder, !files.fileExists(atPath: marker.path),
              files.fileExists(atPath: legacyFolder.appending(path: "state.json").path) else { return }
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        files.createFile(atPath: marker.path, contents: nil)
    }
}
