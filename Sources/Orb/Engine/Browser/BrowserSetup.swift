import Foundation
import Observation

/// One line of Ajustes → Navegador: an engine, and what can be done with it now.
struct BrowserEngineRow: Equatable, Identifiable, Sendable {
    enum Phase: Equatable, Sendable {
        case notInstalled
        /// Ready to use. `managed`: the app installed it (it can remove and update it); otherwise it was found on the Mac.
        case installed(managed: Bool)
        case installing(BrowserInstallProgress)
        case failed(String)
    }

    var engine: BrowserEngineKind
    var phase: Phase
    /// "agent-browser 0.39.0 · Chrome 155.0.8059.39", what is installed.
    var versionText: String?
    /// A newer release of something this engine uses exists.
    var updateAvailable = false
    /// Another engine is being installed: one install at a time (they share `agent-browser`).
    var isBlocked = false

    var id: String { engine.rawValue }

    var canInstall: Bool {
        guard !isBlocked else { return false }
        switch phase {
        case .notInstalled, .failed: return true
        case .installed, .installing: return false
        }
    }

    var canRemove: Bool {
        guard !isBlocked else { return false }
        if case .installed(let managed) = phase { return managed }
        return false
    }

    var canUpdate: Bool {
        guard !isBlocked, updateAvailable else { return false }
        if case .installed(true) = phase { return true }
        return false
    }

    var isInstalling: Bool { if case .installing = phase { true } else { false } }

    /// The line under the name: what it is doing or has.
    var statusText: String {
        switch phase {
        case .notInstalled: "Não instalado"
        case .installed(let managed):
            managed ? "Instalado" + (versionText.map { " · \($0)" } ?? "") : "Instalado fora do Orb" + (versionText.map { " · \($0)" } ?? "")
        case .installing(let progress): progress.text
        case .failed(let message): message
        }
    }
}

/// What Ajustes → Navegador shows and does: which engines are installed and with what version, the install in progress (one at a
/// time), its cancellation, the removal, and the look for newer releases (at most once a day). The work is `BrowserInstaller`'s.
@MainActor @Observable
final class BrowserSetup {
    private(set) var rows: [BrowserEngineRow] = []
    /// The engine being installed, updated or removed now.
    private(set) var working: BrowserEngineKind?
    private(set) var updates: Set<BrowserComponent> = []
    private(set) var lastCheck: Date?

    @ObservationIgnored let installer: BrowserInstaller
    @ObservationIgnored private let status: @Sendable (BrowserEngineKind) async -> BrowserEngineStatus
    @ObservationIgnored private let closeBrowsers: @Sendable (BrowserEngineKind) async -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var progress: BrowserInstallProgress?
    @ObservationIgnored private var failures: [BrowserEngineKind: String] = [:]

    /// The engines shown, in order: the ones a person installs (`simple` has nothing to install).
    static let engines: [BrowserEngineKind] = [.chrome, .obscura, .cloak]

    init(installer: BrowserInstaller, status: @escaping @Sendable (BrowserEngineKind) async -> BrowserEngineStatus,
         closeBrowsers: @escaping @Sendable (BrowserEngineKind) async -> Void = { _ in }) {
        self.installer = installer
        self.status = status
        self.closeBrowsers = closeBrowsers
        rows = Self.engines.map { BrowserEngineRow(engine: $0, phase: .notInstalled) }
    }

    var isBusy: Bool { working != nil }

    func row(_ engine: BrowserEngineKind) -> BrowserEngineRow? { rows.first { $0.engine == engine } }

    // MARK: Reading

    /// Looks at the Mac again and rebuilds the rows.
    func refresh() async {
        let engines = Self.engines
        var found: [BrowserEngineKind: BrowserEngineStatus] = [:]
        for engine in engines { found[engine] = await status(engine) }
        let installer = installer
        let (records, installed) = await Task.detached { () -> (InstalledRecords, [BrowserComponent: Bool]) in
            var installed: [BrowserComponent: Bool] = [:]
            for component in BrowserComponent.allCases { installed[component] = installer.isInstalled(component) }
            return (installer.records(), installed)
        }.value
        rebuild(statuses: found, records: records, installed: installed)
    }

    private func rebuild(statuses: [BrowserEngineKind: BrowserEngineStatus], records: InstalledRecords, installed: [BrowserComponent: Bool]) {
        rows = Self.engines.map { engine in
            let ready = statuses[engine]?.isReady == true
            var row = BrowserEngineRow(engine: engine, phase: .notInstalled)
            let managed = engine.components.allSatisfy { installed[$0] == true }
            if working == engine, let progress {
                row.phase = .installing(progress)
            } else if working == engine {
                row.phase = .installing(BrowserInstallProgress(component: engine.browserComponent ?? .agentBrowser, phase: .preparing))
            } else if let failure = failures[engine] {
                row.phase = .failed(failure)
            } else if ready {
                row.phase = .installed(managed: managed)
            }
            row.versionText = Self.versionText(for: engine, records: records, installed: installed)
            row.updateAvailable = managed && !engine.components.filter(updates.contains).isEmpty
            row.isBlocked = working != nil && working != engine
            return row
        }
    }

    /// "agent-browser 0.39.0 · Chrome 155.0.8059.39" from what the installer wrote down.
    nonisolated static func versionText(for engine: BrowserEngineKind, records: InstalledRecords, installed: [BrowserComponent: Bool]) -> String? {
        let parts = engine.components.compactMap { component -> String? in
            guard installed[component] == true, let record = records[component.rawValue] else { return nil }
            // A download the release gave no checksum for is installed, but not as checked: Ajustes says so.
            return "\(component.name) \(record.version)" + (record.verified == false ? " (sem soma de verificação)" : "")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Doing

    /// Installs what the engine is missing.
    func install(_ engine: BrowserEngineKind) {
        run(engine, components: nil)
    }

    /// Installs again what has a newer release.
    func update(_ engine: BrowserEngineKind) {
        let components = engine.components.filter { updates.contains($0) }
        guard !components.isEmpty else { return }
        run(engine, components: components)
    }

    private func run(_ engine: BrowserEngineKind, components: [BrowserComponent]?) {
        guard working == nil else { return }
        working = engine
        failures[engine] = nil
        progress = BrowserInstallProgress(component: (components ?? engine.components).first ?? .agentBrowser, phase: .preparing,
                                          steps: max((components ?? engine.components).count, 1))
        showWorking()
        let installer = installer, closeBrowsers = closeBrowsers
        let sink: @Sendable (BrowserInstallProgress) -> Void = { [weak self] update in
            Task { @MainActor in self?.receive(update, for: engine) }
        }
        task = Task { [weak self] in
            do {
                // A browser of this engine that is running holds the files that are about to be replaced.
                if components != nil { await closeBrowsers(engine) }
                try await installer.install(engine, components: components, progress: sink)
            } catch is CancellationError {
                // The person stopped it: nothing to say.
            } catch {
                self?.failures[engine] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self?.finishWork()
        }
    }

    /// The rows say at once that this engine is working and the others wait, before anything is read again.
    private func showWorking() {
        guard let engine = working else { return }
        for index in rows.indices {
            if rows[index].engine == engine {
                rows[index].phase = .installing(progress ?? BrowserInstallProgress(component: engine.browserComponent ?? .agentBrowser, phase: .preparing))
            } else {
                rows[index].isBlocked = true
            }
        }
    }

    private func receive(_ update: BrowserInstallProgress, for engine: BrowserEngineKind) {
        guard working == engine else { return }
        progress = update
        if let index = rows.firstIndex(where: { $0.engine == engine }) { rows[index].phase = .installing(update) }
    }

    private func finishWork() {
        working = nil
        progress = nil
        task = nil
        Task {
            await refresh()
            await checkForUpdates(force: false)
        }
    }

    /// Stops the install in progress (what was half done is thrown away).
    func cancel() { task?.cancel() }

    /// Removes the engine's files; `removeProfiles` also deletes the logins the Orbs kept with it.
    func remove(_ engine: BrowserEngineKind, removeProfiles: Bool = false) {
        guard working == nil else { return }
        working = engine
        failures[engine] = nil
        let installer = installer, closeBrowsers = closeBrowsers
        showWorking()
        task = Task { [weak self] in
            await closeBrowsers(engine)
            do {
                try await Task.detached { try installer.uninstall(engine, removeProfiles: removeProfiles) }.value
            } catch {
                self?.failures[engine] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self?.finishWork()
        }
    }

    // MARK: Updates

    /// Asks for the newest releases, at most once a day (`force` asks now). Failing quietly: the row simply has no update button.
    func checkForUpdates(force: Bool = false) async {
        let installer = installer
        guard let check = try? await installer.checkForUpdates(force: force) else { return }
        lastCheck = check.checkedAt
        let found = installer.updatable(check)
        guard found != updates else { return }
        updates = found
        await refresh()
    }
}
