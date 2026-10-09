import Foundation

/// How Claude Code's tools server reaches the app for `schedule`. The server is a child process and the routines live
/// in the app, so a call becomes a file: the server drops `<id>.json` in the mailbox folder and waits for the app's
/// `<id>.reply`. The app wakes on the folder changing (no polling on its side) and answers with the same code the
/// native engine runs, so both engines agree on limits, names and results.
enum ScheduleMailbox {
    static let flag = "--schedule-mailbox"
    static let orbFlag = "--orb"

    /// The server's end: a handler bound to one Orb. It gives up after `timeout` (the app is not running, or stuck).
    static func client(directory: URL, orb: UUID, timeout: Duration = .seconds(20)) -> ScheduleHandler {
        { arguments in
            let id = UUID().uuidString
            let reply = directory.appending(path: id + ".reply")
            defer { try? FileManager.default.removeItem(at: reply) }
            let request = JSONValue.object(["orb": .string(orb.uuidString), "arguments": arguments])
            do { try Data(request.jsonString.utf8).write(to: directory.appending(path: id + ".json"), options: .atomic) }
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

    /// The app's end: answers the requests that arrive in the folder with `handle` (the Orb, the tool's arguments).
    @MainActor
    final class Server {
        let directory: URL
        private let handle: (UUID, JSONValue) throws -> String
        private var watcher: DispatchSourceFileSystemObject?

        init(directory: URL, handle: @escaping (UUID, JSONValue) throws -> String) {
            self.directory = directory
            self.handle = handle
        }

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

        /// Reads each request, runs it and writes the reply. A file that does not parse yet (still being written) stays.
        func answerPending() {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), let request = JSONValue.parse(String(decoding: data, as: UTF8.self)),
                      let orb = request["orb"]?.string.flatMap(UUID.init(uuidString:)) else { continue }
                try? FileManager.default.removeItem(at: file)
                let answer: JSONValue
                do { answer = .object(["text": .string(try handle(orb, request["arguments"] ?? .null))]) }
                catch { answer = .object(["error": .string(error.localizedDescription)]) }
                try? Data(answer.jsonString.utf8).write(to: file.deletingPathExtension().appendingPathExtension("reply"), options: .atomic)
            }
        }
    }
}
