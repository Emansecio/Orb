import Foundation
import Observation

/// One line of Ajustes → Navegador: a component of the Orb's browser, and what can be done with it now.
struct BrowserComponentRow: Equatable, Identifiable, Sendable {
    enum Phase: Equatable, Sendable {
        /// The Mac has not been looked at yet: nothing is said and nothing can be done until it has.
        case checking
        case notInstalled
        /// Ready to use. `managed`: the app installed it (it can remove and update it); otherwise it was found on the Mac.
        case installed(managed: Bool)
        case installing(BrowserInstallProgress)
        case failed(String)

        /// Which case this is, ignoring the payload: what the row animates on (the progress ticks must not).
        enum Kind: Equatable { case checking, notInstalled, installed, installing, failed }
        var kind: Kind {
            switch self {
            case .checking: .checking
            case .notInstalled: .notInstalled
            case .installed: .installed
            case .installing: .installing
            case .failed: .failed
            }
        }
    }

    var component: BrowserComponent
    var phase: Phase
    /// "agent-browser 0.39.1", what the app installed.
    var versionText: String?
    /// What the browser row says the Mac uses ("Google Chrome 155").
    var found: String?
    /// A newer release of this component exists.
    var updateAvailable = false
    /// Another component is being installed: one install at a time.
    var isBlocked = false

    var id: String { component.rawValue }

    /// The name of the row.
    var title: String {
        switch component {
        case .agentBrowser: "agent-browser"
        case .chrome: "Navegador"
        }
    }

    /// What the component is, one line under the name.
    var summary: String {
        switch component {
        case .agentBrowser: "A ferramenta que dirige o navegador dos Orbs (15 MB)."
        case .chrome: "Usa o Google Chrome ou o Brave que já estão neste Mac. Sem eles, o Orb baixa o Chrome for Testing (cerca de 180 MB) como reserva."
        }
    }

    var canInstall: Bool {
        guard !isBlocked else { return false }
        switch phase {
        case .notInstalled, .failed: return true
        case .checking, .installed, .installing: return false
        }
    }

    /// What the app put there can go (a browser found on the Mac is not the app's to remove).
    var canRemove: Bool {
        guard !isBlocked, case .installed = phase else { return false }
        return versionText != nil
    }

    var canUpdate: Bool {
        guard !isBlocked, updateAvailable else { return false }
        if case .installed = phase { return versionText != nil }
        return false
    }

    var isInstalling: Bool { if case .installing = phase { true } else { false } }

    /// The line under the summary: what it is doing or has.
    var statusText: String {
        switch phase {
        case .checking: "Conferindo…"
        case .notInstalled: component == .chrome ? "Nenhum navegador encontrado" : "Não instalado"
        case .installed:
            switch component {
            case .agentBrowser: "Instalado" + (versionText.map { " · \($0)" } ?? "")
            case .chrome: "Usando \(found ?? "o navegador do Mac")" + (versionText.map { " · reserva do Orb guardada (\($0))" } ?? "")
            }
        case .installing(let progress): progress.text
        case .failed(let message): message
        }
    }
}

/// What Ajustes → Navegador shows and does: what is installed and with what version, the install in progress (one at a time),
/// its cancellation, the removal, and the look for newer releases (at most once a day). The work is `BrowserInstaller`'s.
@MainActor @Observable
final class BrowserSetup {
    private(set) var rows: [BrowserComponentRow] = []
    /// The component being installed, updated or removed now.
    private(set) var working: BrowserComponent?
    private(set) var updates: Set<BrowserComponent> = []

    @ObservationIgnored let installer: BrowserInstaller
    @ObservationIgnored private let status: @Sendable () async -> BrowserStatus
    @ObservationIgnored private let closeBrowsers: @Sendable () async -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var progress: BrowserInstallProgress?
    @ObservationIgnored private var failures: [BrowserComponent: String] = [:]

    init(installer: BrowserInstaller, status: @escaping @Sendable () async -> BrowserStatus,
         closeBrowsers: @escaping @Sendable () async -> Void = {}) {
        self.installer = installer
        self.status = status
        self.closeBrowsers = closeBrowsers
        // Until the first look, every row is "checking", never "not installed" with an Install button that would be wrong.
        rows = BrowserComponent.allCases.map { BrowserComponentRow(component: $0, phase: .checking) }
    }

    func row(_ component: BrowserComponent) -> BrowserComponentRow? { rows.first { $0.component == component } }

    // MARK: Reading

    /// Looks at the Mac again and rebuilds the rows.
    func refresh() async {
        let found = await status()
        let installer = installer
        let (records, installed) = await Task.detached { () -> (InstalledRecords, [BrowserComponent: Bool]) in
            installer.removeLegacyEngines()
            var installed: [BrowserComponent: Bool] = [:]
            for component in BrowserComponent.allCases { installed[component] = installer.isInstalled(component) }
            return (installer.records(), installed)
        }.value
        rebuild(status: found, records: records, installed: installed)
    }

    private func rebuild(status: BrowserStatus, records: InstalledRecords, installed: [BrowserComponent: Bool]) {
        rows = BrowserComponent.allCases.map { component in
            var row = BrowserComponentRow(component: component, phase: .notInstalled)
            let ready: Bool
            switch component {
            case .agentBrowser:
                ready = status.agentBrowser != nil
            case .chrome:
                ready = status.program != nil
                row.found = status.program?.label
            }
            if working == component, let progress {
                row.phase = .installing(progress)
            } else if working == component {
                row.phase = .installing(BrowserInstallProgress(component: component, phase: .preparing))
            } else if let failure = failures[component] {
                row.phase = .failed(failure)
            } else if ready {
                row.phase = .installed(managed: installed[component] == true)
            }
            row.versionText = Self.versionText(for: component, records: records, installed: installed)
            row.updateAvailable = installed[component] == true && updates.contains(component)
            row.isBlocked = working != nil && working != component
            return row
        }
    }

    /// "agent-browser 0.39.1" from what the installer wrote down.
    nonisolated static func versionText(for component: BrowserComponent, records: InstalledRecords, installed: [BrowserComponent: Bool]) -> String? {
        guard installed[component] == true, let record = records[component.rawValue] else { return nil }
        return "\(component.name == "Chrome" ? "Chrome for Testing" : component.name) \(record.version)"
    }

    // MARK: Doing

    /// Installs what the row is missing. The browser fallback needs `agent-browser`, so that comes along when it is not there.
    func install(_ component: BrowserComponent) {
        let needed: [BrowserComponent] = component == .chrome && !installer.isInstalled(.agentBrowser) ? [.agentBrowser, .chrome] : [component]
        run(component, components: needed)
    }

    /// Installs again what has a newer release.
    func update(_ component: BrowserComponent) {
        guard updates.contains(component) else { return }
        run(component, components: [component])
    }

    private func run(_ component: BrowserComponent, components: [BrowserComponent]) {
        guard working == nil else { return }
        working = component
        failures[component] = nil
        progress = BrowserInstallProgress(component: components.first ?? component, phase: .preparing, steps: max(components.count, 1))
        showWorking()
        let installer = installer, closeBrowsers = closeBrowsers
        let sink: @Sendable (BrowserInstallProgress) -> Void = { [weak self] update in
            Task { @MainActor in self?.receive(update, for: component) }
        }
        let replacing = components.contains { installer.isInstalled($0) }
        task = Task { [weak self] in
            do {
                // A browser that is running holds the files that are about to be replaced.
                if replacing { await closeBrowsers() }
                try await installer.install(components, progress: sink)
            } catch is CancellationError {
                // The person stopped it: nothing to say.
            } catch {
                self?.failures[component] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self?.finishWork()
        }
    }

    /// The rows say at once that this component is working and the others wait, before anything is read again.
    private func showWorking() {
        guard let component = working else { return }
        for index in rows.indices {
            if rows[index].component == component {
                rows[index].phase = .installing(progress ?? BrowserInstallProgress(component: component, phase: .preparing))
            } else {
                rows[index].isBlocked = true
            }
        }
    }

    private func receive(_ update: BrowserInstallProgress, for component: BrowserComponent) {
        guard working == component else { return }
        progress = update
        if let index = rows.firstIndex(where: { $0.component == component }) { rows[index].phase = .installing(update) }
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

    /// Removes the component's files. The logins the Orbs kept stay: they are in the Orbs' own folders.
    func remove(_ component: BrowserComponent) {
        guard working == nil else { return }
        working = component
        failures[component] = nil
        let installer = installer, closeBrowsers = closeBrowsers
        showWorking()
        task = Task { [weak self] in
            await closeBrowsers()
            do {
                try await Task.detached { try installer.uninstall(component) }.value
            } catch {
                self?.failures[component] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self?.finishWork()
        }
    }

    // MARK: Updates

    /// Asks for the newest releases, at most once a day (`force` asks now). Failing quietly: the row simply has no update button.
    func checkForUpdates(force: Bool = false) async {
        let installer = installer
        guard let check = try? await installer.checkForUpdates(force: force) else { return }
        let found = installer.updatable(check)
        guard found != updates else { return }
        updates = found
        await refresh()
    }
}
