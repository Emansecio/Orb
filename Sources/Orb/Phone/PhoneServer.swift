import Foundation
import Network

/// One phone on the line. Lives on the main actor like the server: a phone or two send a few frames a second, and what they
/// ask for is main-actor state anyway.
@MainActor
final class PhoneConnection {
    let id = UUID()
    let connection: NWConnection
    let peer: String
    let since = Date.now
    var device = ""
    var isAuthorized = false
    /// The chat this phone follows (`open`), and a count bumped each time it changes, so an observation armed for the
    /// previous chat does nothing when it fires.
    var openBot: UUID?
    var chatEpoch = 0
    var chatPending = false
    var lastChat: Data?
    var lastStream: Data?
    var lastBots: Data?
    /// Frames handed to the network and not yet sent: a phone on a bad line that stops reading is dropped instead of
    /// piling up chat snapshots in memory.
    var inFlight = 0

    init(connection: NWConnection, peer: String) {
        self.connection = connection
        self.peer = peer
    }
}

/// The phone's WebSocket server (docs/CELULAR.md): accepts only Tailscale and loopback peers, checks the token of the first
/// frame and hands every later frame to `handle`. What a frame does is the owner's business (`PhoneAccess`).
@MainActor
final class PhoneServer {
    enum State: Equatable {
        case starting, listening, failed(String)
    }

    static let helloTimeout: Duration = .seconds(10)
    static let maxInFlight = 64

    private(set) var state = State.starting
    private(set) var connections: [UUID: PhoneConnection] = [:]
    var authorized: [PhoneConnection] { connections.values.filter(\.isAuthorized).sorted { $0.since < $1.since } }

    private let token: () -> String?
    private let macName: String
    private let allows: (NWEndpoint) -> Bool
    private var listener: NWListener?
    private var limiter = PhoneFailureLimiter()

    var onState: (State) -> Void = { _ in }
    var onAuthorized: (PhoneConnection) -> Void = { _ in }
    var onClosed: (PhoneConnection) -> Void = { _ in }
    var handle: (PhoneConnection, PhoneWire.Incoming) -> Void = { _, _ in }

    init(token: @escaping () -> String?, macName: String, allows: @escaping (NWEndpoint) -> Bool = PhonePeer.isAllowed) {
        self.token = token
        self.macName = macName
        self.allows = allows
    }

    /// The port it listens on once `listening` (the asked one, or the one the system picked for port 0).
    var port: UInt16? { listener?.port?.rawValue }

    func start(port: UInt16) {
        let parameters = NWParameters.tcp
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        // Above `maxFrame` the frame is still read whole and answered with `too_large`; far above it the socket gives up.
        socket.maximumMessageSize = PhoneWire.maxFrame * 4
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        parameters.allowLocalEndpointReuse = true // a quick relaunch finds the port still in TIME_WAIT
        guard let endpointPort = NWEndpoint.Port(rawValue: port), let listener = try? NWListener(using: parameters, on: endpointPort) else {
            setState(.failed("Não foi possível abrir a porta \(port)."))
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.setState(.listening)
                case .failed(let error):
                    self?.setState(.failed(Self.describe(error, port: port)))
                    self?.listener?.cancel()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { close(connection) }
    }

    /// Drops every phone (a new token was made: the old one opens nothing anymore).
    func dropAll() {
        for connection in connections.values { close(connection) }
    }

    func send(_ frame: some Encodable, to connection: PhoneConnection, then: (@MainActor () -> Void)? = nil) {
        send(PhoneWire.encode(frame), to: connection, then: then)
    }

    /// `then` runs once the frame left (or failed to).
    func send(_ data: Data, to connection: PhoneConnection, then: (@MainActor () -> Void)? = nil) {
        guard connections[connection.id] != nil else { return }
        guard connection.inFlight < Self.maxInFlight else {
            close(connection)
            return
        }
        connection.inFlight += 1
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                connection.inFlight -= 1
                if error != nil { self?.close(connection) }
                then?()
            }
        })
    }

    func close(_ connection: PhoneConnection) {
        guard connections.removeValue(forKey: connection.id) != nil else { return }
        connection.connection.cancel()
        onClosed(connection)
    }

    // MARK: Inside

    private func setState(_ state: State) {
        guard self.state != state else { return }
        self.state = state
        onState(state)
    }

    private static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE { return "A porta \(port) já está em uso por outro app." }
        return "O acesso pelo celular parou: \(error.localizedDescription)"
    }

    private func accept(_ raw: NWConnection) {
        let peer = PhonePeer.key(raw.endpoint)
        guard allows(raw.endpoint), !limiter.isBlocked(peer) else {
            raw.cancel()
            return
        }
        let connection = PhoneConnection(connection: raw, peer: peer)
        connections[connection.id] = connection
        raw.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.close(connection)
                default: break
                }
            }
        }
        raw.start(queue: .main)
        receive(connection)
        Task { [weak self] in
            try? await Task.sleep(for: Self.helloTimeout)
            guard let self, !connection.isAuthorized, self.connections[connection.id] != nil else { return }
            self.close(connection)
        }
    }

    private func receive(_ connection: PhoneConnection) {
        connection.connection.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self, self.connections[connection.id] != nil else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if error != nil || metadata?.opcode == .close {
                    self.close(connection)
                    return
                }
                if metadata?.opcode == .text, let data { self.received(data, from: connection) }
                if self.connections[connection.id] != nil { self.receive(connection) }
            }
        }
    }

    private func received(_ data: Data, from connection: PhoneConnection) {
        switch PhoneWire.parse(data) {
        case .failure(.tooLarge):
            send(PhoneWire.Failure(code: .tooLarge, message: "Mensagem grande demais."), to: connection)
        case .failure(.malformed):
            send(PhoneWire.Failure(code: .badRequest, message: "Pedido que o Orb não entendeu."), to: connection)
        case .success(let frame):
            if connection.isAuthorized {
                if case .hello = frame { return } // already in
                handle(connection, frame)
            } else if case .hello(let given, let device, _) = frame, let expected = token(), PhonePairing.matches(given, expected) {
                connection.isAuthorized = true
                connection.device = device.isEmpty ? "Celular" : device
                send(PhoneWire.Welcome(mac: macName), to: connection)
                onAuthorized(connection)
            } else {
                limiter.record(connection.peer)
                // The error goes out first; the socket closes right after it.
                send(PhoneWire.Failure(code: .unauthorized, message: "Este celular não está pareado com este Mac."), to: connection) { [weak self] in
                    self?.close(connection)
                }
            }
        }
    }
}
