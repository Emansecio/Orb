import Foundation
import Network

/// A streaming endpoint on `127.0.0.1` that answers every request with `200 text/event-stream` and then writes `script`,
/// each piece after its pause, and then `forever` again and again until the client hangs up (a provider that only sends
/// keep-alives). For the provider's watch on a response that goes quiet (`ProviderTransport.contentTimeout`).
final class TrickleServer: @unchecked Sendable {
    struct Piece: Sendable {
        var after: Duration
        var text: String
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.orb.tests.trickle-server")
    private(set) var port: UInt16 = 0
    /// How many requests came in.
    let requests = LockedBox(0)

    init(script: [Piece], forever: Piece? = nil) async throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [requests] connection in
            connection.start(queue: DispatchQueue.global())
            requests.withLock { $0 += 1 }
            Self.serve(connection, script: script, forever: forever)
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedBox(false)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if !resumed.value { resumed.value = true; continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if !resumed.value { resumed.value = true; continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit { listener.cancel() }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    private static func serve(_ connection: NWConnection, script: [Piece], forever: Piece?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { _, _, _, _ in
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
            Task {
                guard await send(head, on: connection) else { return }
                for piece in script {
                    try? await Task.sleep(for: piece.after)
                    guard await send(piece.text, on: connection) else { return }
                }
                if let forever {
                    while true {
                        try? await Task.sleep(for: forever.after)
                        guard await send(forever.text, on: connection) else { return }
                    }
                }
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    /// False once the client is gone.
    private static func send(_ text: String, on connection: NWConnection) async -> Bool {
        guard connection.state == .ready else { return false }
        return await withCheckedContinuation { continuation in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
    }
}
