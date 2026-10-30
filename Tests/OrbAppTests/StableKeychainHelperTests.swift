import Foundation
import Testing
@testable import Orb

/// Fake helpers never touch the Keychain; these check the private pipe and failure handling.
struct StableKeychainHelperTests {
    private let folder = TempFolder("OrbKeychainHelper", creating: true)

    private func helper(_ body: String) throws -> StableKeychainHelper {
        let url = folder.appending("helper")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return StableKeychainHelper(executable: url)
    }

    @Test func requestUsesStdinNotArgumentsAndDecodesTheResponse() throws {
        let fake = try helper("[ \"$#\" -eq 0 ] || exit 1; cat >/dev/null; printf '%s' '{\"ok\":true,\"value\":\"teste\"}'")
        let reply = fake.call(operation: "replace", account: "test", service: "app.orb.mac", value: "segredo de teste")
        #expect(reply?.ok == true && reply?.value == "teste")
    }

    @Test func aFailedHelperNeverPretendsTheOperationWorked() throws {
        let fake = try helper("cat >/dev/null; exit 1")
        #expect(fake.call(operation: "read", account: "test", service: "app.orb.mac")?.ok != true)
    }

    @Test func aHelperThatExitsBeforeReadingCannotKillTheOrb() throws {
        let fake = try helper("exit 1")
        #expect(fake.call(operation: "replace", account: "test", service: "app.orb.mac", value: String(repeating: "x", count: 1_000_000))?.ok != true)
    }
}
