import Foundation

/// The developer modes of the executable that draw something and exit (`--snapshot`, `--render-orbs`,
/// `--render-icon`, `--bench-panels`, `--bench-scroll`). They fill the model with made-up data (the `conversations` snapshot even writes sample
/// conversations), so they must never see the user's real Orbs, conversations or secrets.
enum DevRun {
    /// The arguments that start one of these modes.
    static let flags = ["--snapshot", "--render-orbs", "--render-icon", "--bench-panels", "--bench-scroll"]

    /// Whether this process is one of the developer modes (decided once, from the real command line).
    static let isActive = isActive(arguments: CommandLine.arguments)

    static func isActive(arguments: [String]) -> Bool {
        arguments.contains { flags.contains($0) }
    }

    /// Where the data folder is.
    enum DataFolder: Equatable {
        /// `ORB_DATA_DIR`, set explicitly by whoever launched the process: used as is, in any mode.
        case custom(URL)
        /// A fresh temporary folder, only for a developer mode that was not given `ORB_DATA_DIR`.
        case temporary(URL)
        /// ~/Library/Application Support/Orb: the user's data.
        case standard(URL)

        var url: URL {
            switch self {
            case .custom(let url), .temporary(let url), .standard(let url): url
            }
        }

        /// Only the user's own folder may receive OpenBot's data.
        var allowsLegacyMigration: Bool {
            if case .standard = self { true } else { false }
        }
    }

    /// The decision, free of globals so it can be tested: `ORB_DATA_DIR` (when not empty) wins; otherwise a
    /// developer mode gets a new empty folder in `temporary`, and a normal launch the user's folder.
    static func dataFolder(environment: [String: String], arguments: [String], support: URL, temporary: URL,
                           token: String = UUID().uuidString) -> DataFolder {
        if let custom = environment["ORB_DATA_DIR"], !custom.isEmpty { return .custom(URL(fileURLWithPath: custom)) }
        if isActive(arguments: arguments) { return .temporary(temporary.appending(path: "orb-render-\(token)")) }
        return .standard(support.appending(path: "Orb"))
    }

    /// The decision for this process.
    static let currentDataFolder = dataFolder(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments,
                                              support: .applicationSupportDirectory, temporary: FileManager.default.temporaryDirectory)

    /// Ends a developer mode: its temporary data folder (made-up state, conversations, memory index) goes with it,
    /// so runs in a visual review don't pile up folders in the system's temp directory. A folder given through
    /// `ORB_DATA_DIR` or the user's own is never touched.
    static func finish(status: Int32 = 0) -> Never {
        removeTemporaryFolder(currentDataFolder)
        exit(status)
    }

    static func removeTemporaryFolder(_ folder: DataFolder) {
        guard case .temporary(let url) = folder else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The secrets (Keychain) are out of reach in these modes: not read, not written, not migrated from OpenBot.
    static func allowsKeychain(arguments: [String]) -> Bool { !isActive(arguments: arguments) }
}
