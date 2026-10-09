import Foundation
import CryptoKit
import Network
import os

/// What every OAuth sign-in of the app shares: PKCE and the random values around it, and the loopback listener that
/// receives the redirect (ChatGPT's sign-in and the connectors' logins, see `MCPAuth`).
enum OAuthLoopback {
    static func randomToken() -> String {
        base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    /// The PKCE `S256` challenge of a verifier.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect's query string.
/// Tries the preferred ports in order (ChatGPT's conventional 1455 by default), then, unless told otherwise, any free port
/// (the docs allow the port to vary).
final class LoopbackCallback: Sendable {
    private let listener: NWListener
    private let result: AsyncStream<[String: String]>
    private let continuation: AsyncStream<[String: String]>.Continuation
    let port: UInt16

    /// Opens the listener. `exactPortOnly`: a server that compares the redirect to the letter cannot be sent anywhere else, so no
    /// other port is tried.
    static func open(path: String, preferredPorts: [UInt16] = [1455], exactPortOnly: Bool = false) async throws -> LoopbackCallback {
        var listener: NWListener?
        for port in preferredPorts where listener == nil { listener = await bind(port) }
        if listener == nil && !exactPortOnly { listener = await bind(nil) }
        guard let listener, listener.port != nil else { throw ToolError("Não foi possível abrir a porta local para o login.") }
        return LoopbackCallback(listener: listener, path: path)
    }

    private init(listener: NWListener, path: String) {
        (result, continuation) = AsyncStream.makeStream(of: [String: String].self)
        let bound = listener.port?.rawValue ?? 0
        self.listener = listener
        port = bound
        let continuation = continuation
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let page = "<html><body style=\"font-family:-apple-system;background:#070707;color:#fcfcfc;text-align:center;padding-top:80px\"><h2>Pronto!</h2><p>Pode voltar para o app.</p></body></html>"
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                guard let components = URLComponents(string: target), components.path == path else { return }
                var query: [String: String] = [:]
                for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
                continuation.yield(query)
            }
        }
    }

    /// A listener on 127.0.0.1 that reached `.ready` (nil port = any free port). Waiting does not hold a thread: a thread blocked
    /// here would be one the listener's own callbacks may need.
    private static func bind(_ port: UInt16?) async -> NWListener? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        let settled = OSAllocatedUnfairLock(initialState: false)
        let isReady = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            /// The first word wins: a state change after the answer, or the margin below, is ignored.
            @Sendable func settle(_ ready: Bool) {
                guard !settled.withLock({ let done = $0; $0 = true; return done }) else { return }
                continuation.resume(returning: ready)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: settle(true)
                case .failed, .cancelled: settle(false)
                default: break
                }
            }
            // A handler must exist before start; the real one is installed right after.
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: .global())
            // Ready in milliseconds; the margin is for a Mac under load (it only ever waits that long when binding fails).
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { settle(false) }
        }
        listener.stateUpdateHandler = nil
        guard isReady else { listener.cancel(); return nil }
        return listener
    }

    func wait(timeout: Duration) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { [result] in
                for await query in result { return query }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ToolError("O login demorou demais; tente de novo.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    func stop() {
        listener.cancel()
        continuation.finish()
    }
}
