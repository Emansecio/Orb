import Darwin
import Foundation
import Testing
@testable import Orb

// The real thing: the app's own binary started as `Orb --tools-mcp`, the way Claude Code starts it. Stopping a turn there
// must not leave the server stuck in a long call.

/// Where the executables of this package were built (next to the test bundle).
final class ProductAnchor {}

enum BuiltProduct {
    static func url(_ name: String, file: String = #filePath) -> URL? {
        let manager = FileManager.default
        var candidates = [Bundle(for: ProductAnchor.self).bundleURL.deletingLastPathComponent().appending(path: name)]
        var root = URL(fileURLWithPath: file).deletingLastPathComponent()
        while root.path != "/", !manager.fileExists(atPath: root.appending(path: "Package.swift").path) { root = root.deletingLastPathComponent() }
        candidates.append(root.appending(path: ".build/debug/\(name)"))
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }
}

/// A child process with its stdout read line by line.
final class ChildProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var read: [String] = []
    private var buffer = Data()

    init(_ executable: URL, _ arguments: [String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            lock.withLock {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    read.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
        }
        try process.run()
    }

    var lines: [String] { lock.withLock { read } }
    var replies: [JSONValue] { lines.compactMap(JSONValue.parse) }
    func reply(id: Double) -> JSONValue? { replies.first { $0["id"] == .number(id) } }

    func send(_ value: JSONValue) {
        try? input.fileHandleForWriting.write(contentsOf: Data((value.jsonString + "\n").utf8))
    }

    func sendLine(_ line: String) {
        try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func closeInput() { try? input.fileHandleForWriting.close() }
    func terminate() { kill(process.processIdentifier, SIGTERM) }

    /// The exit status, or nil if it did not exit within `timeout` (the process is then killed).
    func exit(within timeout: Duration) async -> Int32? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        guard !process.isRunning else {
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        return process.terminationStatus
    }

    func waitForReply(_ id: Double, timeout: Duration = .seconds(10)) async -> JSONValue? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let found = reply(id: id) { return found }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return reply(id: id)
    }

    deinit { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct MCPProcessTests {
    private func start() throws -> ChildProcess? {
        guard let binary = BuiltProduct.url("Orb") else {
            Issue.record("the Orb executable was not found next to the tests")
            return nil
        }
        let memory = FileManager.default.temporaryDirectory.appending(path: "OrbMCPProcess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        return try ChildProcess(binary, [OrbToolsMCPServer.flag, memory.path, OrbToolsMCPServer.macFlag, OrbToolsMCPServer.noAccessibilityFlag])
    }

    private func handshake(_ child: ChildProcess) async -> Bool {
        child.send(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
                            "params": .object(["protocolVersion": .string("2025-06-18")])]))
        return await child.waitForReply(1) != nil
    }

    private func slowCall(_ child: ChildProcess, id: Double) {
        child.send(.object(["jsonrpc": .string("2.0"), "id": .number(id), "method": .string("tools/call"),
                            "params": .object(["name": .string("applescript"), "arguments": .object(["script": .string("delay 20")])])]))
    }

    private func ping(_ child: ChildProcess, id: Double) {
        child.send(.object(["jsonrpc": .string("2.0"), "id": .number(id), "method": .string("ping")]))
    }

    @Test func aPingIsAnsweredWhileALongCallIsRunning() async throws {
        guard let child = try start() else { return }
        #expect(await handshake(child))
        slowCall(child, id: 2)
        try await Task.sleep(for: .milliseconds(300))
        ping(child, id: 3)
        #expect(await child.waitForReply(3, timeout: .seconds(3)) != nil, "the server was not stuck in the call")
        #expect(child.reply(id: 2) == nil)
        child.closeInput()
        #expect(await child.exit(within: .seconds(5)) == 0)
    }

    @Test func closingStdinInTheMiddleOfACallExitsAtOnce() async throws {
        guard let child = try start() else { return }
        #expect(await handshake(child))
        slowCall(child, id: 2)
        try await Task.sleep(for: .milliseconds(300))
        let begin = ContinuousClock.now
        child.closeInput()
        #expect(await child.exit(within: .seconds(5)) == 0)
        #expect(begin.duration(to: .now) < .seconds(3))
        #expect(child.reply(id: 2) == nil, "a cancelled call is not answered")
    }

    @Test func sigtermInTheMiddleOfACallExitsCleanly() async throws {
        guard let child = try start() else { return }
        #expect(await handshake(child))
        slowCall(child, id: 2)
        try await Task.sleep(for: .milliseconds(300))
        let begin = ContinuousClock.now
        child.terminate()
        #expect(await child.exit(within: .seconds(5)) == 0, "exit(0), not killed by the signal")
        #expect(begin.duration(to: .now) < .seconds(3))
    }

    @Test func aCancelledNotificationEndsTheCallWithoutAReplyAndTheServerKeepsServing() async throws {
        guard let child = try start() else { return }
        #expect(await handshake(child))
        slowCall(child, id: 2)
        try await Task.sleep(for: .milliseconds(300))
        child.send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
                            "params": .object(["requestId": .number(2)])]))
        try await Task.sleep(for: .milliseconds(500))
        ping(child, id: 4)
        #expect(await child.waitForReply(4, timeout: .seconds(3)) != nil)
        #expect(child.reply(id: 2) == nil)
        child.closeInput()
        #expect(await child.exit(within: .seconds(5)) == 0)
    }
}
