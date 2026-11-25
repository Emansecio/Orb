import Foundation
import Security
import Testing
@testable import Orb

/// The order of the Keychain steps, on closures: these never touch the real Keychain.
struct KeychainStoreTests {
    @Test func anExistingItemIsUpdatedInPlaceWithoutAddingOrDeleting() {
        var calls: [String] = []
        let stored = SystemKeychainItems.store(update: { calls.append("update"); return errSecSuccess },
                                               add: { calls.append("add"); return errSecSuccess })
        #expect(stored && calls == ["update"])
    }

    @Test func aMissingItemIsAdded() {
        var calls: [String] = []
        let stored = SystemKeychainItems.store(update: { calls.append("update"); return errSecItemNotFound },
                                               add: { calls.append("add"); return errSecSuccess })
        #expect(stored && calls == ["update", "add"])
    }

    @Test func aFailedUpdateDoesNotAddAndReportsFailure() {
        var calls: [String] = []
        let stored = SystemKeychainItems.store(update: { calls.append("update"); return errSecInteractionNotAllowed },
                                               add: { calls.append("add"); return errSecSuccess })
        #expect(!stored && calls == ["update"])
    }

    @Test func aFailedAddReportsFailure() {
        let stored = SystemKeychainItems.store(update: { errSecItemNotFound }, add: { errSecAuthFailed })
        #expect(!stored)
    }

    @Test func anItemCreatedInTheMeantimeIsUpdated() {
        var updates = 0
        let stored = SystemKeychainItems.store(update: { updates += 1; return updates == 1 ? errSecItemNotFound : errSecSuccess },
                                               add: { errSecDuplicateItem })
        #expect(stored && updates == 2)
    }
}

// MARK: - StableKeychainHelperTests

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

    @Test func aHelperThatNeverAnswersIsGivenUpOn() throws {
        let fake = try helper("sleep 30")
        let started = Date()
        #expect(fake.call(operation: "read", account: "test", service: "app.orb.mac", timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(started) < 10)
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
