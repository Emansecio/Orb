import Foundation

/// Where a connector that runs on this Mac stands: what the card and the "Conectar" sheet say.
enum LocalConnectorState: Equatable, Sendable {
    /// macOS has never been asked.
    case needsPermission
    /// The person said no (only Ajustes do Sistema changes that).
    case denied
    /// Allowed, but there is no Google account on this Mac to read.
    case noAccount
    case ready
    /// Mail is closed, so macOS cannot say whether the permission is there; "Conectar" opens it and finds out.
    case unchecked
    /// Cannot work here, and why (a restriction of the Mac, an app run without its Info.plist).
    case unavailable(String)

    /// Whether the card should ask for attention. An unchecked state is not a problem.
    var needsAttention: Bool {
        switch self {
        case .needsPermission, .denied, .noAccount, .unavailable: true
        case .ready, .unchecked: false
        }
    }

    /// One line for the card: what to do.
    var message: String {
        switch self {
        case .needsPermission: "Falta dar permissão ao Orb."
        case .denied: "O Orb está sem permissão. Libere em Ajustes do Sistema → Privacidade e Segurança."
        case .noAccount: "Não achei uma conta Google neste Mac. Adicione em Contas de Internet."
        case .ready, .unchecked: ""
        case .unavailable(let reason): reason
        }
    }
}

/// Checks and asks for what the local connectors need. `state` never shows a dialog; `connect` is what the person's click
/// starts, and shows the macOS one when the permission was never answered. With a fake environment nothing touches macOS.
struct LocalConnectorSetup: Sendable {
    var environment: LocalConnectorEnvironment

    /// `anyAccount`: the person chose to use Google Agenda although no account is named Google (see `MCPServerConfig.anyAccount`).
    func state(of kind: LocalConnectorKind, anyAccount: Bool = false) async -> LocalConnectorState {
        switch kind {
        case .agenda, .lembretes:
            return await calendarState(kind, access: environment.calendar.access(kind == .agenda ? .events : .reminders), anyAccount: anyAccount)
        case .gmail:
            return await mailState(await environment.mail.automation())
        }
    }

    /// Asks macOS for what the connector needs (a dialog the first time), then says where it stands.
    func connect(_ kind: LocalConnectorKind, anyAccount: Bool = false) async -> LocalConnectorState {
        switch kind {
        case .agenda, .lembretes:
            return await calendarState(kind, access: await environment.calendar.requestAccess(kind == .agenda ? .events : .reminders), anyAccount: anyAccount)
        case .gmail:
            return await mailState(await environment.mail.requestAutomation())
        }
    }

    private func calendarState(_ kind: LocalConnectorKind, access: CalendarAccess, anyAccount: Bool) async -> LocalConnectorState {
        switch access {
        case .notDetermined: return .needsPermission
        case .denied: return .denied
        case .restricted: return .unavailable("O macOS não deixa o Orb usar \(kind == .agenda ? "a Agenda" : "os Lembretes") neste Mac.")
        case .unsupported: return .unavailable("Abra o Orb pelo app (scripts/bundle.sh): sem ele o macOS não pode pedir a permissão.")
        case .granted: break
        }
        // Reminders need no Google account. Events do: the calendar of the account is what the connector is for.
        guard kind == .agenda else { return .ready }
        do {
            // A Workspace account is named by its address, so the name alone cannot tell it from any other: "Conectar assim
            // mesmo" is the person saying which one it is, and the card believes it from then on.
            return try await environment.calendar.calendars().contains(where: \.isGoogle) || anyAccount ? .ready : .noAccount
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private func mailState(_ status: MacPermissionStatus) async -> LocalConnectorState {
        switch status {
        case .notDetermined: return .needsPermission
        case .denied, .notGranted: return .denied
        case .appNotRunning, .unknown: return .unchecked
        case .granted: break
        }
        do {
            return try await GmailConnector(backend: environment.mail).googleAccounts(named: nil, all: true).isEmpty ? .noAccount : .ready
        } catch {
            // No Google account is not a failure of Mail: the connector says so itself, and so does the card.
            if (error as? ToolError)?.message.hasPrefix("O Mail não tem uma conta Google") == true { return .noAccount }
            return .unavailable(error.localizedDescription)
        }
    }

    /// Opens Ajustes do Sistema → Contas de Internet, where the Google account is added.
    static let internetAccountsURL = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!
}
