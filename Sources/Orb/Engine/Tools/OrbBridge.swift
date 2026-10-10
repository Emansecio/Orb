import Foundation

/// How Claude Code's tools server reaches the app for the tools that live in it (`orbs`, `orb_draft`): a mailbox folder like
/// `ScheduleMailbox`'s, `ponte/<id>.json` for a call and `ponte/<id>.reply` for the answer. This is the skeleton the packages
/// build on: the constants and the two ends' signatures, doing nothing yet.
enum OrbBridge {
    static let flag = "--bridge"
    /// The Orb a call speaks for (shared with `ScheduleMailbox`).
    static let orbFlag = ScheduleMailbox.orbFlag
    static let version = 1
    /// The tools that go through the mailbox (`orb_propose` does not: the engine opens its card itself).
    static let tools: Set<String> = ["orbs", "orb_draft"]
    /// The server's wait for the app's answer.
    static let timeout = Duration.seconds(20)

    /// The server's end: a handler bound to one Orb and one tool.
    static func client(directory: URL, orb: UUID, tool: String, timeout: Duration = OrbBridge.timeout) -> BridgeHandler {
        { _ in throw ToolError("Falar com outros Orbs não está disponível agora.") }
    }

    /// The app's end: answers the calls that arrive in the folder with `handle` (the Orb, the tool, its arguments and the call's
    /// id, which is the file's name).
    @MainActor
    final class Server {
        let directory: URL
        private let handle: (UUID, String, JSONValue, UUID) async throws -> String

        init(directory: URL, handle: @escaping (UUID, String, JSONValue, UUID) async throws -> String) {
            self.directory = directory
            self.handle = handle
        }

        /// Starts listening (once). Nothing listens yet.
        func start() {}

        func stop() {}
    }
}
