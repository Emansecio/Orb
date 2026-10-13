import Foundation
import os
import Testing
@testable import Orb

/// The loopback listener against real local connections: only the real redirect ends the wait.
struct OAuthLoopbackTests {
    private static let path = "/auth/callback"

    private func open() async throws -> LoopbackCallback {
        try await LoopbackCallback.open(path: Self.path, state: "certo", preferredPorts: [])
    }

    /// Requests an address on the listener and returns the status and the page.
    @discardableResult
    private func get(_ callback: LoopbackCallback, _ target: String) async throws -> (status: Int, page: String) {
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(callback.port)\(target)")!)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    /// Whether the wait ended within the time (a short wait, since waiting forever is exactly what is being checked).
    private func ends(_ waiting: Task<[String: String], Error>, within milliseconds: Int) async -> Bool {
        let done = OSAllocatedUnfairLock(initialState: false)
        let watcher = Task { _ = await waiting.result; done.withLock { $0 = true } }
        try? await Task.sleep(for: .milliseconds(milliseconds))
        let finished = done.withLock { $0 }
        if !finished { watcher.cancel() }
        return finished
    }

    @Test func aWrongStateDoesNotEndTheLogin() async throws {
        let callback = try await open()
        defer { callback.stop() }
        let waiting = Task { try await callback.wait(timeout: .seconds(30)) }
        let wrong = try await get(callback, "\(Self.path)?code=roubado&state=errado")
        let missing = try await get(callback, "\(Self.path)?code=roubado")
        #expect(wrong.status == 400 && missing.status == 400)
        #expect(!wrong.page.contains("Pronto!"))
        #expect(await ends(waiting, within: 400) == false)
        // The real redirect still gets through afterwards.
        try await get(callback, "\(Self.path)?code=abc&state=certo")
        let query = try await waiting.value
        #expect(query["code"] == "abc")
        #expect(query["state"] == "certo")
    }

    @Test func anotherPathDoesNotEndTheLogin() async throws {
        let callback = try await open()
        defer { callback.stop() }
        let waiting = Task { try await callback.wait(timeout: .seconds(30)) }
        let favicon = try await get(callback, "/favicon.ico")
        let near = try await get(callback, "/auth/callback2?code=x&state=certo")
        #expect(favicon.status == 404 && near.status == 404)
        #expect(await ends(waiting, within: 400) == false)
        try await get(callback, "\(Self.path)?code=abc&state=certo")
        #expect(try await waiting.value["code"] == "abc")
    }

    @Test func theRightStateWithACodeCompletes() async throws {
        let callback = try await open()
        defer { callback.stop() }
        let waiting = Task { try await callback.wait(timeout: .seconds(30)) }
        let reply = try await get(callback, "\(Self.path)?code=abc&state=certo")
        #expect(reply.status == 200 && reply.page.contains("Pronto!"))
        #expect(try await waiting.value["code"] == "abc")
    }

    @Test func theRightStateWithAnErrorFailsAndTheErrorArrives() async throws {
        let callback = try await open()
        defer { callback.stop() }
        let waiting = Task { try await callback.wait(timeout: .seconds(30)) }
        let reply = try await get(callback, "\(Self.path)?error=access_denied&error_description=negado&state=certo")
        #expect(!reply.page.contains("Pronto!"))
        #expect(reply.page.contains("Login não concluído"))
        let query = try await waiting.value
        #expect(query["error"] == "access_denied" && query["error_description"] == "negado")
        #expect(query["code"] == nil)
    }

    @Test func aMatchingStateWithNeitherCodeNorErrorIsIgnored() async throws {
        let callback = try await open()
        defer { callback.stop() }
        let waiting = Task { try await callback.wait(timeout: .seconds(30)) }
        let reply = try await get(callback, "\(Self.path)?state=certo")
        #expect(reply.status == 400)
        #expect(await ends(waiting, within: 300) == false)
        waiting.cancel()
    }
}
