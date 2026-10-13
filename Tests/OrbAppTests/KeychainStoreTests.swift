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
