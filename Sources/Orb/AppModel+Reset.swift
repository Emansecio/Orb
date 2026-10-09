import Foundation
import os

// "Redefinir o Orb": the app back to its first use. The sheet asks (`ResetOrbSheet`), `ResetPlan` decides what goes,
// `AppModel.stopForReset` stops the app, `ResetExecutor` removes the data off the main thread and the app quits and
// opens again (`AppRelaunch`).

/// Preferences that ignore every call (tests, and a model that is not the running app).
struct IgnoredPreferences: ResettablePreferences {
    func removeAll(keeping isKept: (String) -> Bool) {}
}

/// What the reset needs from outside the app model. The default is the running app; `inert` is for a model that
/// is not (tests): it touches no preferences, looks at no OpenBot folder and does not quit.
struct ResetEnvironment {
    var arguments = CommandLine.arguments
    var home = FileManager.default.homeDirectoryForCurrentUser
    /// ~/Library/Application Support/Orb: the only data folder a reset runs on without it looking like the app's data.
    var standardFolder = URL.applicationSupportDirectory.appending(path: "Orb")
    var preferences: any ResettablePreferences = DomainPreferences.app
    var legacyFolder: URL? = URL.applicationSupportDirectory.appending(path: LegacyMigration.oldFolder)
    /// How long a turn that does not stop holds the reset.
    var waitForTurns = Duration.seconds(3)
    /// How long saving the last conversation stretches (Guardar as memórias) holds it.
    var waitForMemories = Duration.seconds(5)
    /// Tells the user what the reset could not remove (only called when something was left), just before quitting.
    var warn: @MainActor (ResetReport) -> Void = { ResetWarning.present($0) }
    /// The last step: quit (and open the app again).
    var finish: @MainActor () -> Void = { AppRelaunch.finish() }

    static var inert: ResetEnvironment {
        var environment = ResetEnvironment()
        environment.preferences = IgnoredPreferences()
        environment.legacyFolder = nil
        environment.waitForTurns = .milliseconds(200)
        environment.warn = { _ in }
        environment.finish = {}
        return environment
    }
}

enum ResetOutcome: Equatable, Sendable {
    /// Done (the report says what could not be removed, if anything: the user is told before the app quits).
    case done(ResetReport)
    case refused(ResetGuard.Refusal)
    case alreadyRunning
}

extension AppModel {
    /// What the "Redefinir o Orb?" sheet says will go, from what the app holds now (the conversation files are
    /// counted by the caller, off the main thread: see `ResetSummary.conversationCount`).
    func resetSummary(conversations: Int?) -> ResetSummary {
        ResetSummary(orbs: bots.count, conversations: conversations, routines: routines.count, connectors: connectors.count,
                     skills: skills.filter { $0.source != Skill.builtInSource }.count,
                     folder: OrbFolder.display(OrbFolder.defaultBase), profile: !profile.isEmpty)
    }

    /// Takes the app back to its first use and quits (see the comments above). Never in a developer mode
    /// (`--snapshot`…): those run on made-up data. Returns when everything is removed; the app is quitting by then.
    @discardableResult
    func resetEverything(_ options: ResetOptions) async -> ResetOutcome {
        guard !isResetting else { return .alreadyRunning }
        let environment = resetEnvironment
        let workFolders = bots.filter { !$0.workingDirectory.isEmpty }.map(\.workingURL)
        if let refusal = ResetGuard.refusal(arguments: environment.arguments, dataFolder: store.directory, home: environment.home,
                                            standardFolder: environment.standardFolder, workFolders: workFolders) {
            return .refused(refusal)
        }
        // Before anything else: from here the state and the conversations are not saved, so no write of the old state
        // can follow the clean-up (and the window takes no new message or Orb: `isResetting`).
        isResetting = true
        store.sealWrites()
        usageLog.close()
        let plan = ResetPlan.make(bots: bots, connectors: connectors, providers: providers, defaultModel: defaultModel,
                                  learnedContexts: learnedContexts, options: options)
        await stopForReset(wait: environment.waitForTurns)
        // What each Orb learned since its last session page goes into its memory before the memory moves; then the
        // banks are sealed, so a late task cannot bring a folder back after it moved. "Apagar tudo" saves nothing.
        if options.memories == .keep { await saveLastStretches(wait: environment.waitForMemories) }
        memory.seal()

        let executor = ResetExecutor(directory: store.directory, vault: secretVault, preferences: environment.preferences,
                                     legacyFolder: environment.legacyFolder)
        let store = store, jobs = jobs
        let report = await Task.detached(priority: .userInitiated) {
            store.flush() // the write that was running when the folder was sealed is over
            jobs.killAllNow() // the Orbs' background processes, and their logs
            return executor.run(plan)
        }.value
        // Last, and again: a preference an open window wrote meanwhile does not survive the reset.
        environment.preferences.removeAll(keeping: ResetGuard.keepsPreference)
        if !report.isComplete { environment.warn(report) }
        environment.finish()
        return .done(report)
    }

    /// The conversation after the last saved stretch of every Orb becomes a session page in its memory (as in
    /// `deleteBot(keepMemory:)`), so a memory kept by the reset holds what the Orb learned since. Waits for the pages
    /// to be written, at most `wait`; a turn that has not ended (`pendingStretch` finds nothing) saves nothing.
    func saveLastStretches(wait: Duration) async {
        var pending: [(bank: MemoryBank, stretch: [TranscriptItem])] = []
        for bot in bots {
            if let stretch = session(bot.id).pendingStretch() { pending.append((memory.bank(for: bot.id), stretch)) }
        }
        guard !pending.isEmpty else { return }
        let finished = OSAllocatedUnfairLock(initialState: false)
        let pages = pending
        Task.detached(priority: .userInitiated) {
            for (bank, stretch) in pages {
                if let page = SessionSummary.page(from: stretch) { await bank.saveSession(page) }
            }
            finished.withLock { $0 = true }
        }
        let deadline = ContinuousClock.now + wait
        while !finished.withLock({ $0 }), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
    }
}
