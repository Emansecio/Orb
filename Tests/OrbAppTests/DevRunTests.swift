import Foundation
import Testing
@testable import Orb

/// `--snapshot` and `--render-*` draw made-up data and exit: they never touch the user's data folder or Keychain.
@Suite struct DevRunTests {
    let support = URL(fileURLWithPath: "/Users/x/Library/Application Support")
    let temporary = URL(fileURLWithPath: "/var/tmp")

    private func folder(_ arguments: [String], environment: [String: String] = [:]) -> DevRun.DataFolder {
        DevRun.dataFolder(environment: environment, arguments: ["Orb"] + arguments, support: support, temporary: temporary, token: "T")
    }

    @Test func aNormalLaunchUsesTheUsersFolder() {
        #expect(folder([]) == .standard(support.appending(path: "Orb")))
        #expect(folder([]).allowsLegacyMigration)
    }

    @Test func everyDeveloperModeGetsAFreshTemporaryFolder() {
        for arguments in [["--snapshot", "conversations", "out.png"], ["--snapshot", "app", "out.png"],
                          ["--render-orbs", "out.png"], ["--render-icon", "out.png"]] {
            let location = folder(arguments)
            #expect(location == .temporary(temporary.appending(path: "orb-render-T")))
            #expect(!location.allowsLegacyMigration)
            #expect(!location.url.path.hasPrefix(support.path))
        }
    }

    @Test func eachProcessGetsItsOwnTemporaryFolder() {
        let first = DevRun.dataFolder(environment: [:], arguments: ["--snapshot", "a", "b"], support: support, temporary: temporary)
        let second = DevRun.dataFolder(environment: [:], arguments: ["--snapshot", "a", "b"], support: support, temporary: temporary)
        #expect(first != second)
    }

    @Test func anExplicitDataDirWinsInEveryMode() {
        let environment = ["ORB_DATA_DIR": "/tmp/orb-teste"]
        let custom = DevRun.DataFolder.custom(URL(fileURLWithPath: "/tmp/orb-teste"))
        #expect(folder([], environment: environment) == custom)
        #expect(folder(["--snapshot", "conversations", "o.png"], environment: environment) == custom)
        #expect(folder(["--render-icon", "o.png"], environment: environment) == custom)
        #expect(!custom.allowsLegacyMigration)
    }

    @Test func anEmptyDataDirDoesNotCountAsSet() {
        #expect(folder(["--snapshot", "app", "o.png"], environment: ["ORB_DATA_DIR": ""]) == .temporary(temporary.appending(path: "orb-render-T")))
        #expect(folder([], environment: ["ORB_DATA_DIR": ""]) == .standard(support.appending(path: "Orb")))
    }

    @Test func theKeychainIsOutOfReachOnlyInDeveloperModes() {
        #expect(DevRun.allowsKeychain(arguments: ["Orb"]))
        for flag in DevRun.flags { #expect(!DevRun.allowsKeychain(arguments: ["Orb", flag, "x"])) }
        // Even with an explicit data folder: the secrets are never read or written by these modes.
        #expect(!DevRun.allowsKeychain(arguments: ["Orb", "--snapshot", "app", "o.png"]))
    }

    @Test func theTestRunnerIsNotADeveloperMode() {
        #expect(!DevRun.isActive)
        #expect(DevRun.allowsKeychain(arguments: CommandLine.arguments))
    }

    /// A developer mode leaves nothing behind in the temp directory; a custom or the user's own folder is never removed.
    @Test func finishingRemovesOnlyTheTemporaryFolder() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "orb-devrun-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let kinds: [(DevRun.DataFolder, Bool)] = [
            (.temporary(base.appending(path: "t")), false), (.custom(base.appending(path: "c")), true),
            (.standard(base.appending(path: "s")), true)]
        for (kind, survives) in kinds {
            try FileManager.default.createDirectory(at: kind.url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: kind.url.appending(path: "state.json"))
            DevRun.removeTemporaryFolder(kind)
            #expect(FileManager.default.fileExists(atPath: kind.url.path) == survives, "\(kind)")
        }
    }
}
