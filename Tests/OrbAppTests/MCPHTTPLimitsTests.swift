import Foundation
import os
import Testing
@testable import Orb

/// Answers by host and method with canned replies, so no server or network is involved.
private final class LimitsProtocol: URLProtocol {
    struct Reply: Sendable {
        var status = 200
        var mime = "application/json"
        var body = Data()
    }

    static let replies = OSAllocatedUnfairLock<[String: Reply]>(initialState: [:])

    static func session(_ replies: [String: Reply]) -> URLSession {
        self.replies.withLock { $0.merge(replies) { $1 } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LimitsProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = "\(request.url?.host() ?? "") \(request.httpMethod ?? "")"
        guard let url = request.url, let reply = Self.replies.withLock({ $0[key] }),
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": reply.mime]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// A reply from a remote connector has a ceiling, as the output of a local one does.
struct MCPHTTPLimitsTests {
    private let call = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(7), "method": .string("tools/call")])
    private let initialize = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize")])

    private func transport(_ host: String, _ replies: [String: LimitsProtocol.Reply], limit: Int = 16_384) throws -> HTTPTransport {
        let config = MCPServerConfig(name: "Remoto", url: "https://\(host)/mcp", headers: [:])
        return try HTTPTransport(config: config, session: LimitsProtocol.session(replies), maxMessageBytes: limit)
    }

    @Test func aJSONReplyPastTheCeilingIsRefused() async throws {
        let body = Data(#"{"jsonrpc":"2.0","id":7,"result":{"text":""#.utf8) + Data(repeating: 0x61, count: 40_000)
        let remote = try transport("json-grande.test", ["json-grande.test POST": .init(body: body)])
        await remote.open(receive: { _ in }, closed: { _ in })
        await #expect(throws: ToolError("O conector Remoto mandou uma resposta grande demais.")) { try await remote.send(call) }
    }

    @Test func anEventPastTheCeilingIsRefused() async throws {
        let body = Data("data: ".utf8) + Data(repeating: 0x61, count: 40_000)   // no newline in sight
        let remote = try transport("sse-grande.test", ["sse-grande.test POST": .init(mime: "text/event-stream", body: body)])
        await remote.open(receive: { _ in }, closed: { _ in })
        await #expect(throws: ToolError("O conector Remoto mandou uma resposta grande demais.")) { try await remote.send(call) }
    }

    @Test func manySmallDataLinesOfOneEventAddUp() async throws {
        let line = Data(("data: " + String(repeating: "a", count: 1_000) + "\n").utf8)
        var body = Data()
        for _ in 0..<40 { body += line }
        let remote = try transport("linhas.test", ["linhas.test POST": .init(mime: "text/event-stream", body: body)])
        await remote.open(receive: { _ in }, closed: { _ in })
        await #expect(throws: ToolError("O conector Remoto mandou uma resposta grande demais.")) { try await remote.send(call) }
    }

    @Test func emptyDataLinesAreNotFree() async throws {
        // Each "data:" line adds an element without adding a byte of text: the count has to include the joining newline.
        let body = Data(String(repeating: "data:\n", count: 20_000).utf8)
        let remote = try transport("vazias.test", ["vazias.test POST": .init(mime: "text/event-stream", body: body)])
        await remote.open(receive: { _ in }, closed: { _ in })
        await #expect(throws: ToolError("O conector Remoto mandou uma resposta grande demais.")) { try await remote.send(call) }
    }

    @Test func aReplyWithinTheCeilingStillWorks() async throws {
        let body = Data(#"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#.utf8)
        let remote = try transport("pequena.test", ["pequena.test POST": .init(body: body)])
        let received = OSAllocatedUnfairLock<[JSONValue]>(initialState: [])
        await remote.open(receive: { message in received.withLock { $0.append(message) } }, closed: { _ in })
        try await remote.send(call)
        #expect(received.withLock { $0.count } == 1)
    }

    @Test func aLegacyStreamPastTheCeilingClosesTheConnector() async throws {
        let stream = Data("event: endpoint\ndata: /mensagens\n\n".utf8) + Data("data: ".utf8) + Data(repeating: 0x61, count: 40_000)
        let remote = try transport("legado.test", [
            "legado.test POST": .init(status: 405),
            "legado.test GET": .init(mime: "text/event-stream", body: stream),
        ])
        let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
        await remote.open(receive: { _ in }, closed: { error in failure.withLock { $0 = (error as? ToolError)?.message } })
        // The POSTs to the announced endpoint answer 405 too; only the stream matters here.
        _ = try? await remote.send(initialize)
        try await waitUntil("the stream to be dropped") { failure.withLock { $0 } != nil }
        #expect(failure.withLock { $0 } == "O conector Remoto mandou uma resposta grande demais.")
    }
}
