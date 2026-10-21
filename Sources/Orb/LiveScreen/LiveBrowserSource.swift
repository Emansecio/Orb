import Foundation

/// The real `LiveBrowserSource`: the app's `BrowserHub`.
struct BrowserHubLiveSource: LiveBrowserSource {
    let browsers: BrowserHub

    func generation(botID: UUID) -> Int? {
        browsers.existingSession(botID: botID)?.driver.generation
    }

    func streamPort(botID: UUID) async throws -> Int? {
        guard let session = browsers.existingSession(botID: botID) else { return nil }
        return try await session.exclusive { try await session.driver.streamPort() }
    }

    func pageLooksSensitive(botID: UUID) -> Bool {
        browsers.pageLooksSensitive(botID: botID)
    }

    func setPointerHandler(_ handler: (@Sendable (UUID, LivePointer) -> Void)?) {
        browsers.setPointerHandler(handler)
    }
}

/// The real transport: a `URLSessionWebSocketTask` to the stream on 127.0.0.1. An ephemeral session per connection, so nothing
/// is cached or kept (cookies, disk) and closing it lets go of everything.
struct URLSessionLiveTransport: LiveTransport {
    func open(port: Int, maxFps: Int) -> any LiveSocket {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "maxFps", value: String(maxFps))]
        return URLSessionLiveSocket(url: components.url!)
    }
}

final class URLSessionLiveSocket: LiveSocket, @unchecked Sendable {
    /// A frame is a JPEG in base64 inside JSON: over URLSession's default 1 MB only on a huge page, but not worth a drop.
    private static let maximumMessageSize = 8 * 1024 * 1024

    let url: URL
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        self.url = url
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = Self.maximumMessageSize
    }

    func messages() -> AsyncThrowingStream<String, Error> {
        let task = task
        return AsyncThrowingStream { continuation in
            let reader = Task.detached(priority: .userInitiated) {
                task.resume()
                do {
                    while !Task.isCancelled {
                        if case .string(let text) = try await task.receive() { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                reader.cancel()
                self?.close()
            }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
