import Foundation
import CryptoKit
@testable import Orb

/// A network that answers from tables, and writes down what was asked. `download` writes the bytes it has for the address.
final class FakeInstallNetwork: InstallNetwork, @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [String: Data] = [:]
    private var files: [String: Data] = [:]
    private var asked: [String] = []
    /// Runs before a download answers (to wait for a cancellation, or to fail).
    var beforeDownload: (@Sendable (URL) async throws -> Void)?
    var offline = false
    /// Answers every request for a document with this error (the GitHub limit, say).
    var failure: BrowserInstallError?

    var requests: [String] { lock.withLock { asked } }

    func serve(document address: String, _ text: String) { lock.withLock { documents[address] = Data(text.utf8) } }
    func serve(file address: String, _ data: Data) { lock.withLock { files[address] = data } }

    func data(from url: URL) async throws -> Data {
        lock.withLock { asked.append(url.absoluteString) }
        if offline { throw BrowserInstallError.noNetwork }
        if let failure { throw failure }
        guard let data = lock.withLock({ documents[url.absoluteString] }) else { throw BrowserInstallError.failed("arquivo", detail: "HTTP 404") }
        return data
    }

    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> String {
        lock.withLock { asked.append(url.absoluteString) }
        if offline { throw BrowserInstallError.noNetwork }
        try await beforeDownload?(url)
        guard let data = lock.withLock({ files[url.absoluteString] }) else { throw BrowserInstallError.failed("arquivo", detail: "HTTP 404") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        progress(Int64(data.count / 2), Int64(data.count))
        progress(Int64(data.count), Int64(data.count))
        return FakeInstallNetwork.sha256(data)
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The JSON GitHub answers for `releases/latest`.
    static func releaseJSON(tag: String, assets: [(name: String, data: Data, digest: Bool)]) -> String {
        let entries = assets.map { asset -> String in
            let digest = asset.digest ? "\"sha256:\(sha256(asset.data))\"" : "null"
            return #"{"name":"\#(asset.name)","size":\#(asset.data.count),"digest":\#(digest),"browser_download_url":"https://example.test/dl/\#(tag)/\#(asset.name)"}"#
        }
        return #"{"tag_name":"\#(tag)","assets":[\#(entries.joined(separator: ","))]}"#
    }

    static func assetURL(tag: String, _ name: String) -> String { "https://example.test/dl/\(tag)/\(name)" }
}

/// Runs programs for the installer from a handler (nothing is started), writing down every call. Anything the handler does not
/// answer is an unexpected program: `tar` is the exception, run for real, as the archives in the tests are real.
final class FakeInstallRunner: @unchecked Sendable {
    struct Call: Sendable { var executable: String; var arguments: [String]; var environment: [String: String] }
    typealias Handler = @Sendable (Call, @Sendable (String) -> Void) async throws -> ProcessOutput?

    private let lock = NSLock()
    private var recorded: [Call] = []
    var handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    var calls: [Call] { lock.withLock { recorded } }

    var runner: InstallCommandRunner {
        { [self] executable, arguments, environment, timeout, onOutput in
            let call = Call(executable: executable, arguments: arguments, environment: environment)
            lock.withLock { recorded.append(call) }
            try Task.checkCancellation()
            if let answer = try await handler(call, onOutput) { return answer }
            if executable == "/usr/bin/tar" { return try await BrowserInstaller.processRunner(executable, arguments, environment, timeout, onOutput) }
            return FakeInstallRunner.ok("")
        }
    }

    static func ok(_ text: String) -> ProcessOutput { ProcessOutput(status: 0, signal: nil, output: text, timedOut: false) }
    static func failed(_ text: String, status: Int32 = 1) -> ProcessOutput { ProcessOutput(status: status, signal: nil, output: text, timedOut: false) }

    /// A `.tar.gz` with the named files (each holding its name), made by `tar`.
    static func archive(_ names: [String], in folder: URL) throws -> Data {
        let content = folder.appending(path: "conteudo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        for name in names {
            let file = content.appending(path: name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: file)
        }
        let output = folder.appending(path: "pacote-\(UUID().uuidString).tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", output.path, "-C", content.path] + names.map { $0.split(separator: "/").first.map(String.init) ?? $0 }
        try process.run()
        process.waitUntilExit()
        return try Data(contentsOf: output)
    }
}
