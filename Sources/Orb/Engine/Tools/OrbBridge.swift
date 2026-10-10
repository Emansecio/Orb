import Foundation

/// How Claude Code's tools server reaches the app for the tools that live in it (`orbs`, `orb_draft`): a mailbox folder like
/// `ScheduleMailbox`'s, `ponte/<id>.json` for a call and `ponte/<id>.reply` for the answer. The server is a child process and
/// the Orbs live in the app, so a call becomes a file. The call's `id` (the file's name) is the message id of the request:
/// a call repeated with the same id is a repeat, not a new request.
///
/// Call: `{"v":1,"id":"<uuid>","tool":"orbs","orb":"<Orb's UUID>","arguments":{…}}`; answer: `{"text":"…"}` or `{"error":"…"}`.
/// The client deletes the answer once read, the app deletes the call before it handles it, and the folder is recreated (0700)
/// and swept when the app starts listening: nothing is left behind.
enum OrbBridge {
    static let flag = "--bridge"
    /// The Orb a call speaks for (shared with `ScheduleMailbox`).
    static let orbFlag = ScheduleMailbox.orbFlag
    static let version = 1
    /// The tools that go through the mailbox (`orb_propose` does not: the engine opens its card itself).
    static let tools: Set<String> = ["orbs", "orb_draft"]
    /// The server's wait for the app's answer (`orbs` answers at once).
    static let timeout = Duration.seconds(20)

    /// The server's end: a handler bound to one Orb and one tool. It gives up after `timeout` (the app is not running, or stuck).
    static func client(directory: URL, orb: UUID, tool: String, timeout: Duration = OrbBridge.timeout) -> BridgeHandler {
        { arguments in
            let id = UUID().uuidString
            let reply = directory.appending(path: id + ".reply")
            defer { try? FileManager.default.removeItem(at: reply) }
            let call = JSONValue.object(["v": .number(Double(version)), "id": .string(id), "tool": .string(tool),
                                         "orb": .string(orb.uuidString), "arguments": arguments])
            do { try Data(call.jsonString.utf8).write(to: directory.appending(path: id + ".json"), options: .atomic) }
            catch { throw ToolError("Não consegui falar com o app. Ele está aberto?") }
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if let data = try? Data(contentsOf: reply), let answer = JSONValue.parse(String(decoding: data, as: UTF8.self)) {
                    if let error = answer["error"]?.string { throw ToolError(error) }
                    return answer["text"]?.string ?? ""
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw ToolError("O Orb não respondeu a tempo. Confira se o app está aberto.")
        }
    }

    /// The app's end: answers the calls that arrive in the folder with `handle` (the Orb, the tool, its arguments and the call's
    /// id, which is the file's name).
    @MainActor
    final class Server {
        let directory: URL
        private let handle: (UUID, String, JSONValue, UUID) async throws -> String
        private var watcher: DispatchSourceFileSystemObject?
        /// Calls under way (the file is gone, the answer is not written yet).
        private var answering = 0

        init(directory: URL, handle: @escaping (UUID, String, JSONValue, UUID) async throws -> String) {
            self.directory = directory
            self.handle = handle
        }

        var isListening: Bool { watcher != nil }

        /// Starts listening (once). What an earlier run left in the folder is swept first: nobody waits for it now.
        func start() {
            guard watcher == nil else { return }
            let manager = FileManager.default
            try? manager.removeItem(at: directory)
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.answerPending() } }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
        }

        func stop() {
            watcher?.cancel()
            watcher = nil
        }

        /// Reads each call, runs it and writes the answer. A file that does not parse yet (still being written) stays.
        func answerPending() {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), let call = JSONValue.parse(String(decoding: data, as: UTF8.self)),
                      let orb = call["orb"]?.string.flatMap(UUID.init(uuidString:)) else { continue }
                try? FileManager.default.removeItem(at: file) // before it is handled: it is never handled twice
                let callID = call["id"]?.string.flatMap(UUID.init(uuidString:)) ?? UUID(uuidString: file.deletingPathExtension().lastPathComponent) ?? UUID()
                let target = file.deletingPathExtension().appendingPathExtension("reply")
                guard (call["v"]?.int ?? Self.versionAssumed) <= OrbBridge.version else {
                    Self.write(.object(["error": .string("Versão da ponte não suportada: atualize o Orb.")]), to: target)
                    continue
                }
                guard let tool = call["tool"]?.string, OrbBridge.tools.contains(tool) else {
                    Self.write(.object(["error": .string("Ferramenta desconhecida.")]), to: target)
                    continue
                }
                let arguments = call["arguments"] ?? .null
                answering += 1
                Task { [handle] in
                    let answer: JSONValue
                    do { answer = .object(["text": .string(try await handle(orb, tool, arguments, callID))]) }
                    catch { answer = .object(["error": .string(error.localizedDescription)]) }
                    Self.write(answer, to: target)
                    self.answering -= 1
                }
            }
        }

        private static let versionAssumed = 1

        private static func write(_ answer: JSONValue, to url: URL) {
            try? Data(answer.jsonString.utf8).write(to: url, options: .atomic)
        }
    }
}
