import Foundation

/// One tool of a connector, as the engine runs it (named `<server>__<tool>`). The model never sees these specs: it reaches
/// them through `connector_tools` and `connector_call` (see `ConnectorGateway`), which the engine turns into this tool
/// before the permission policy looks at the call. Running one starts the server if it is off.
struct MCPTool: AgentTool {
    let serverName: String
    let toolName: String
    let spec: ToolSpec
    let annotations: MCPToolAnnotations
    /// The connector this tool belongs to, and the manager that runs it.
    let serverID: UUID
    let manager: MCPManager

    init(serverName: String, remote: ToolSpec, serverID: UUID, manager: MCPManager, annotations: MCPToolAnnotations = .none) {
        self.serverName = serverName
        toolName = remote.name
        self.serverID = serverID
        self.manager = manager
        self.annotations = annotations
        let description = remote.description.isEmpty ? remote.name : remote.description
        spec = ToolSpec(name: Self.modelName(server: serverName, tool: remote.name),
                        description: "[\(serverName)] \(description)", parameters: remote.parameters)
    }

    /// `<server>__<tool>` restricted to `[a-zA-Z0-9_-]` and 64 characters, as model APIs require.
    static func modelName(server: String, tool: String) -> String {
        let scalars = "\(server)__\(tool)".unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
                ? Character(scalar) : "_"
        }
        return String(scalars.prefix(64))
    }

    var kind: ToolCall.Kind { .connector }
    var capability: Capability? { .connectors }

    /// Third-party code: confirm according to the bot's permission mode, unless the server declares the tool
    /// read-only and closed-world (it only reads what the server itself holds). A tool that declares itself
    /// destructive stays sensitive, whatever else it claims.
    func risk(_ arguments: JSONValue) -> ToolRisk {
        annotations.readOnly == true && annotations.openWorld != true && annotations.destructive != true ? .safe : .sensitive
    }

    /// A tool the server marks destructive, or that by its name sends, publishes or deletes without being declared
    /// read-only (`PermissionPolicy.connectorDanger`), asks even in "Automático" and is never covered by "Sempre permitir".
    func danger(_ arguments: JSONValue) -> String? {
        PermissionPolicy.connectorDanger(toolName: toolName, annotations: annotations)
    }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let args = arguments == .object([:]) || arguments == .null ? "" : " " + arguments.jsonString
        return ("Usando \(serverName)", String((toolName + args).prefix(300)))
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        try await manager.call(serverID, tool: toolName, arguments: arguments)
    }

    func connectingNote(_ arguments: JSONValue) async -> String? {
        await manager.isRunning(serverID) ? nil : "Conectando a \(serverName)…"
    }

    func prepare(_ arguments: JSONValue) async throws {
        try await manager.ensureStarted(serverID)
    }
}

// MARK: - Manager

extension MCPServerConfig {
    /// The config without what only decides who may use it: two configs that agree here run the same server.
    var runtimeIdentity: MCPServerConfig {
        var copy = self
        copy.orbIDs = nil
        copy.secretKeys = []
        copy.summary = nil
        return copy
    }

    /// Whether `other` is the same server, switched on or off.
    func runsSameServer(as other: MCPServerConfig) -> Bool {
        var mine = runtimeIdentity, theirs = other.runtimeIdentity
        mine.isEnabled = true
        theirs.isEnabled = true
        return mine == theirs
    }
}

enum MCPStatus: Sendable, Equatable {
    /// Off until an Orb needs it, with the number of tools it offered the last time it ran (nil: it never has).
    case idle(toolCount: Int?)
    case starting
    /// Connected, running now.
    case ready(toolCount: Int)
    case failed(String)
    /// Needs a login: nil the first time, or the sentence to show when the login it had stopped working.
    case needsSignIn(String?)
    /// Logged in, but the server wants more permission (the scopes it named, for "Permitir mais").
    case needsMorePermission(String?)
    /// Switched off by the user.
    case stopped
}

/// Owns the connectors' servers. Nothing starts with the app: `sync` only registers the configs, a server starts the first
/// time something needs it (`ensureStarted`, `call`) and a sweeper stops the ones nobody has used for `idleLimit`, so a
/// connector costs nothing until an Orb reaches for it. What each one offered is kept as a `ConnectorCatalog`.
actor MCPManager {
    private struct Entry {
        var config: MCPServerConfig
        var connection: MCPConnection?
        var status: MCPStatus
        var catalog: ConnectorCatalog?
        /// The start under way, which every caller that needs the server meanwhile waits for.
        var starting: Task<MCPConnection, Error>?
        var lastUsed: ContinuousClock.Instant
        /// Calls (and starts for them) in flight: a server is never stopped for being idle while one is.
        var calls = 0
        /// The server refused a call for lack of scope and the person has not granted it yet: the card keeps asking for
        /// "Permitir mais" whatever else happens to the server (it restarts fine with the token it has).
        var asksMoreScope = false
        var missingScope: String?
        /// Which registration this is: a call that ends after the connector was edited (and registered again) must not
        /// count against the new entry.
        let token = UUID()
    }

    private var entries: [UUID: Entry] = [:]
    private let store: Store?
    private let shell: ShellEnvironment
    /// The logins of the remote connectors, and the network they use (tests put a fake one).
    private let auth: MCPAuth?
    private let session: URLSession?
    private let idleLimit: Duration
    private let sweepInterval: Duration
    /// How long a call may take (a local connector may ask for more: see `LocalConnector.callTimeout`).
    private let callTimeout: Duration
    private var locals: LocalConnectorEnvironment?
    private var sweeper: Task<Void, Never>?
    private var observer: (@Sendable ([UUID: MCPStatus]) -> Void)?

    /// `store`: where the catalogs are kept (nil: only in memory, as in tests). `idleLimit`: how long a server may sit
    /// unused; `sweepInterval`: how often that is checked.
    init(store: Store? = nil, shell: ShellEnvironment = .shared, idleLimit: Duration = .seconds(600), sweepInterval: Duration = .seconds(60),
         locals: LocalConnectorEnvironment? = nil, auth: MCPAuth? = nil, session: URLSession? = nil, callTimeout: Duration = .seconds(60)) {
        self.store = store
        self.shell = shell
        self.auth = auth
        self.session = session
        self.locals = locals
        self.idleLimit = idleLimit
        self.sweepInterval = sweepInterval
        self.callTimeout = callTimeout
    }

    /// What the app's own connectors talk to (tests and snapshots put fakes here; nil is the Mac itself).
    func setLocals(_ environment: LocalConnectorEnvironment?) { locals = environment }

    /// `handler` hears every status as it changes (all connectors, so the screen only copies it).
    func observe(_ handler: @escaping @Sendable ([UUID: MCPStatus]) -> Void) {
        observer = handler
        handler(statuses())
    }

    // MARK: Registering

    /// Registers the connectors, without starting any. Stops (and forgets) the removed ones and the edited ones, stops the
    /// ones switched off, and notices a server that died.
    func sync(_ configs: [MCPServerConfig]) async {
        let wanted = Dictionary(configs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, entry) in entries {
            guard let config = wanted[id] else {
                await drop(id, forgetCatalog: true)
                continue
            }
            guard config.runsSameServer(as: entry.config) else {
                await drop(id, forgetCatalog: true)
                continue
            }
            entries[id]?.config = config // who may use it does not change how it runs
            if !config.isEnabled {
                await stopServer(id, becoming: .stopped)
            } else if case .stopped = entry.status {
                becomeIdle(id)
            } else if let connection = entry.connection, entry.starting == nil, await !connection.isRunning {
                entries[id]?.connection = nil
                becomeIdle(id)
            }
        }
        for config in configs where entries[config.id] == nil {
            let catalog = store?.readConnectorCatalog(config.id) // also when off, so switching it on knows its tools
            // A connector made to sign in, with no login yet, asks for it rather than saying it is ready.
            var needsLogin = false
            if let auth, config.oauth != nil, config.canSignIn { needsLogin = await !auth.isSignedIn(config.id) }
            entries[config.id] = Entry(config: config, status: !config.isEnabled ? .stopped : needsLogin ? .needsSignIn(nil) : .idle(toolCount: catalog?.tools.count),
                                       catalog: catalog, lastUsed: .now)
        }
        publish()
    }

    private func idleStatus(of id: UUID) -> MCPStatus {
        if let entry = entries[id], entry.asksMoreScope { return .needsMorePermission(entry.missingScope) }
        return .idle(toolCount: entries[id]?.catalog?.tools.count)
    }

    /// What the card says of a server that is up: ready, unless a permission is still waiting to be granted.
    private func runningStatus(of id: UUID, toolCount: Int) -> MCPStatus {
        if let entry = entries[id], entry.asksMoreScope { return .needsMorePermission(entry.missingScope) }
        return .ready(toolCount: toolCount)
    }

    /// Back to "off, starts when needed". The status is read before `entries` is written: doing both in one statement
    /// is an overlapping access.
    private func becomeIdle(_ id: UUID) {
        let status = idleStatus(of: id)
        entries[id]?.status = status
    }

    /// Stops the server and forgets the entry (it is registered again by the next `sync` if still wanted).
    private func drop(_ id: UUID, forgetCatalog: Bool) async {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if forgetCatalog { store?.deleteConnectorCatalog(id) }
        entry.starting?.cancel()
        await entry.connection?.stop()
    }

    private func stopServer(_ id: UUID, becoming status: MCPStatus) async {
        guard let connection = entries[id]?.connection else {
            entries[id]?.status = status
            return
        }
        entries[id]?.connection = nil
        entries[id]?.starting = nil
        entries[id]?.status = status
        await connection.stop()
    }

    // MARK: Starting

    /// The running connection of the connector, starting its server first when it is off. Concurrent callers share one
    /// start. Throws when the connector is unknown or off, or when the server does not come up (its status then says why).
    @discardableResult
    func ensureStarted(_ id: UUID) async throws -> MCPConnection {
        while true {
            guard let entry = entries[id] else { throw ToolError("Esse conector não existe mais.") }
            guard entry.config.isEnabled else { throw ToolError("O conector \(entry.config.name) está desligado.") }
            if let starting = entry.starting { return try await starting.value }
            if let connection = entry.connection {
                if await connection.isRunning {
                    entries[id]?.lastUsed = .now
                    return connection
                }
                // It died since the last use (a crash, an expired session): start it again.
                if entries[id]?.connection === connection { entries[id]?.connection = nil }
                continue
            }
            let connection = MCPConnection(config: entry.config, shell: shell, locals: locals,
                                           token: auth?.tokenProvider(for: entry.config), session: session)
            let previously = entry.status
            let task = Task { try await self.start(id, connection, previously: previously) }
            entries[id]?.connection = connection
            entries[id]?.starting = task
            entries[id]?.status = .starting
            publish()
            return try await task.value
        }
    }

    /// `previously`: what the card said before this attempt (a login that ended keeps saying so until there is a new one).
    private func start(_ id: UUID, _ connection: MCPConnection, previously: MCPStatus) async throws -> MCPConnection {
        // Weak: the handlers live in the connection, which would otherwise keep itself alive.
        await connection.setHandlers(
            toolsChanged: { [weak self, weak connection] in
                guard let connection else { return }
                await self?.refreshCatalog(id, from: connection)
            },
            closed: { [weak self, weak connection] in
                guard let connection else { return }
                await self?.closed(id, connection)
            })
        do {
            let specs = try await connection.start()
            guard entries[id]?.connection === connection else {
                await connection.stop() // removed, edited or switched off while it started
                throw ToolError("O conector foi alterado enquanto conectava.")
            }
            let catalog = ConnectorCatalog(handshake: await connection.handshake, specs: specs, annotations: await connection.toolAnnotations)
            entries[id]?.catalog = catalog
            entries[id]?.starting = nil
            let running = runningStatus(of: id, toolCount: specs.count) // read before `entries` is written
            entries[id]?.status = running
            entries[id]?.lastUsed = .now
            store?.saveConnectorCatalog(catalog, for: id)
            startSweeper()
            publish()
            return connection
        } catch {
            let required = error as? MCPAuthRequired
            // Read before `entries` is written: both in one statement is an overlapping access.
            let failure = required.map { status(for: $0, of: id, previously: previously) } ?? .failed(error.localizedDescription)
            if entries[id]?.connection === connection {
                entries[id]?.connection = nil
                entries[id]?.starting = nil
                entries[id]?.status = failure
                publish()
            }
            throw required.map { explained($0, of: id) } ?? error
        }
    }

    /// The server ended by itself (a crash, an expired session): it is off again, and starts on the next use.
    private func closed(_ id: UUID, _ connection: MCPConnection) {
        guard entries[id]?.connection === connection, entries[id]?.starting == nil else { return }
        entries[id]?.connection = nil
        becomeIdle(id)
        publish()
    }

    /// Lists the tools again (the server said they changed, or the user asks for a test) and keeps the new catalog.
    /// Returns how many tools there are.
    @discardableResult
    func refreshCatalog(_ id: UUID, from connection: MCPConnection) async -> Int? {
        guard entries[id]?.connection === connection, let specs = try? await connection.listTools(),
              entries[id]?.connection === connection else { return nil }
        let catalog = ConnectorCatalog(handshake: await connection.handshake, specs: specs, annotations: await connection.toolAnnotations)
        entries[id]?.catalog = catalog
        switch entries[id]?.status {
        case .ready?, .needsMorePermission?:
            let running = runningStatus(of: id, toolCount: specs.count)
            entries[id]?.status = running
        default: break
        }
        store?.saveConnectorCatalog(catalog, for: id)
        publish()
        return specs.count
    }

    /// "Testar conexão": starts the server if it is off, lists its tools again and returns how many there are.
    func test(_ id: UUID) async throws -> Int {
        let token = beginCall(id)
        defer { endCall(id, token) }
        let connection = try await ensureStarted(id)
        if let count = await refreshCatalog(id, from: connection) { return count }
        throw ToolError("O conector \(entries[id]?.config.name ?? "") não listou as ferramentas.")
    }

    // MARK: Using

    /// Calls `tool` of the connector, starting its server first when it is off.
    func call(_ id: UUID, tool: String, arguments: JSONValue, timeout: Duration? = nil) async throws -> String {
        let token = beginCall(id)
        defer { endCall(id, token) }
        let connection = try await ensureStarted(id)
        let timeout = timeout ?? deadline(of: id)
        do {
            do {
                return try await connection.call(tool, arguments: arguments, timeout: timeout)
            } catch is MCPSessionExpired {
                // The server dropped the session before the request reached it: a new session takes it, once.
                return try await ensureStarted(id).call(tool, arguments: arguments, timeout: timeout)
            }
        } catch let required as MCPAuthRequired {
            // The login ended (or falls short) in the middle of the use: the server stops, the card asks, the model is told once.
            if required.reason == .moreScope {
                entries[id]?.asksMoreScope = true
                entries[id]?.missingScope = required.challenge.scope
            }
            await stopServer(id, becoming: status(for: required, of: id))
            publish()
            throw explained(required, of: id)
        }
    }

    /// How long a call to the connector may take: the app's own connectors run scripts and may need more than a server does.
    private func deadline(of id: UUID) -> Duration {
        guard let config = entries[id]?.config, let local = (locals ?? .live).connector(for: config) else { return callTimeout }
        return max(callTimeout, local.callTimeout)
    }

    /// What the card says when the server asks for a login.
    private func status(for required: MCPAuthRequired, of id: UUID, previously: MCPStatus? = nil) -> MCPStatus {
        let name = entries[id]?.config.name ?? "conector"
        switch required.reason {
        case .signIn:
            if case .needsSignIn(let message?)? = previously { return .needsSignIn(message) }
            return .needsSignIn(nil)
        case .expired: return .needsSignIn("A sessão do \(name) expirou. Entre de novo.")
        case .moreScope: return .needsMorePermission(required.challenge.scope)
        }
    }

    /// What the model reads when a tool could not run for lack of a login: it cannot sign in, so it is told whom to ask.
    private func explained(_ required: MCPAuthRequired, of id: UUID) -> ToolError {
        let name = entries[id]?.config.name ?? "O conector"
        switch required.reason {
        case .signIn: return ToolError("\(name) precisa de login. Peça para a pessoa clicar em Entrar em Conectores.")
        case .expired: return ToolError("A sessão do \(name) expirou. Peça para a pessoa clicar em Entrar de novo em Conectores.")
        case .moreScope: return ToolError("\(name) pediu mais permissão. Peça para a pessoa clicar em Permitir mais em Conectores.")
        }
    }

    /// The person granted the permission the server asked for: the card stops asking and the server starts clean.
    func scopeGranted(_ id: UUID) async {
        guard let entry = entries[id], entry.asksMoreScope else { return }
        entries[id]?.asksMoreScope = false
        entries[id]?.missingScope = nil
        if case .needsMorePermission = entry.status {
            let idle = idleStatus(of: id)
            await stopServer(id, becoming: idle)
        }
        publish()
    }

    /// The login of a connector ended where the manager did not see it (a Claude Code turn renewing the token): the card says so.
    func loginEnded(_ id: UUID, reason: MCPAuthRequired.Reason) async {
        guard let entry = entries[id], entry.config.isEnabled else { return }
        let required = MCPAuthRequired(reason: reason, challenge: MCPChallenge())
        let status = status(for: required, of: id, previously: entry.status)
        guard status != entry.status else { return }
        await stopServer(id, becoming: status)
        publish()
    }

    /// The person signed out: the server stops and the card asks for a login again.
    func signedOut(_ id: UUID) async {
        guard entries[id] != nil else { return }
        entries[id]?.asksMoreScope = false
        entries[id]?.missingScope = nil
        await stopServer(id, becoming: .needsSignIn(nil))
        publish()
    }

    /// Counts a call in flight; the token tells `endCall` which registration it was.
    private func beginCall(_ id: UUID) -> UUID? {
        entries[id]?.calls += 1
        return entries[id]?.token
    }

    private func endCall(_ id: UUID, _ token: UUID?) {
        guard let token, entries[id]?.token == token else { return }
        entries[id]?.calls -= 1
        entries[id]?.lastUsed = .now
    }

    /// What the connector offered the last time it ran; nil if it never has.
    func catalog(_ id: UUID) -> ConnectorCatalog? { entries[id]?.catalog }

    func isRunning(_ id: UUID) -> Bool { entries[id]?.connection != nil }

    func status() -> [UUID: MCPStatus] { statuses() }

    private func statuses() -> [UUID: MCPStatus] { entries.mapValues(\.status) }

    private func publish() { observer?(statuses()) }

    // MARK: Stopping the idle

    private func startSweeper() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self, sweepInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: sweepInterval)
                guard let self, await self.sweep() else { return }
            }
        }
    }

    /// Stops the servers nobody has used for `idleLimit` (never one with a call in flight). False once none is left
    /// running, which ends the sweeper (the next start begins it again).
    private func sweep() async -> Bool {
        for id in Array(entries.keys) {
            guard let entry = entries[id], entry.connection != nil, entry.starting == nil, entry.calls == 0,
                  ContinuousClock.now - entry.lastUsed >= idleLimit else { continue }
            let idle = idleStatus(of: id)
            await stopServer(id, becoming: idle)
        }
        publish()
        if entries.values.contains(where: { $0.connection != nil }) { return true }
        sweeper = nil
        return false
    }
}
