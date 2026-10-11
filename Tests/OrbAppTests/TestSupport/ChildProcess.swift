import Darwin
import Foundation
@testable import Orb

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
