import Foundation
import Testing
@testable import Orb

/// OpenBot's Keychain items are a backup: an account is copied from it once, and a key removed in Orb stays removed.
/// Everything here runs on a dictionary: these tests never touch the real Keychain or the standard preferences.
@Suite struct KeychainFallbackTests {
    private final class Items: KeychainItems, @unchecked Sendable {
        var stored: [String: String] = [:]
        var reads: [String] = []
        private func key(_ account: String, _ service: String) -> String { "\(service)/\(account)" }
        func read(_ account: String, service: String) -> String? {
            reads.append(key(account, service))
            return stored[key(account, service)]
        }
        func replace(_ value: String, account: String, service: String) -> Bool {
            stored[key(account, service)] = value.isEmpty ? nil : value
            return true
        }
        func has(_ account: String, in service: String) -> Bool { stored[key(account, service)] != nil }
    }

    private let own = Keychain.service, legacy = Keychain.legacyService

    private func setUp() -> (Items, FakePreferences, LegacyKeychainLedger) {
        let preferences = FakePreferences()
        return (Items(), preferences, LegacyKeychainLedger(preferences: preferences))
    }

    @Test func anOpenBotKeyIsCopiedOnceAndTheBackupStays() {
        let (items, _, ledger) = setUp()
        items.stored["\(legacy)/openai"] = "k"

        #expect(Keychain.lookup("openai", service: own, items: items, ledger: ledger) == "k")
        #expect(items.has("openai", in: own)) // copied over
        #expect(items.has("openai", in: legacy)) // the backup is not deleted
        #expect(ledger.handled("openai"))
    }

    @Test func aKeyRemovedInOrbDoesNotComeBackFromTheBackup() {
        let (items, _, ledger) = setUp()
        items.stored["\(legacy)/openai"] = "k"
        #expect(Keychain.lookup("openai", service: own, items: items, ledger: ledger) == "k")

        #expect(Keychain.write("", account: "openai", service: own, items: items, ledger: ledger))
        items.reads = []
        #expect(Keychain.lookup("openai", service: own, items: items, ledger: ledger) == nil)
        #expect(!items.has("openai", in: own))
        #expect(items.has("openai", in: legacy))
        #expect(!items.reads.contains("\(legacy)/openai")) // the old item is not even asked for
    }

    @Test func removingAKeyBeforeEverReadingItSettlesTheAccountToo() {
        let (items, _, ledger) = setUp()
        items.stored["\(legacy)/chatgpt"] = "login antigo"

        _ = Keychain.write("", account: "chatgpt", service: own, items: items, ledger: ledger)

        #expect(Keychain.lookup("chatgpt", service: own, items: items, ledger: ledger) == nil)
        #expect(items.has("chatgpt", in: legacy))
    }

    @Test func otherAccountsKeepFallingBackToTheirOwnBackup() {
        let (items, _, ledger) = setUp()
        items.stored["\(legacy)/openai"] = "a"
        items.stored["\(legacy)/anthropic"] = "b"
        _ = Keychain.write("", account: "openai", service: own, items: items, ledger: ledger)

        #expect(Keychain.lookup("openai", service: own, items: items, ledger: ledger) == nil)
        #expect(Keychain.lookup("anthropic", service: own, items: items, ledger: ledger) == "b")
    }

    @Test func theNoteSurvivesInThePreferences() {
        let (items, preferences, ledger) = setUp()
        _ = Keychain.write("novo", account: "openai", service: own, items: items, ledger: ledger)
        // A later launch builds a new ledger over the same preferences.
        #expect(LegacyKeychainLedger(preferences: preferences).handled("openai"))
        #expect(!LegacyKeychainLedger(preferences: preferences).handled("anthropic"))
    }

    @Test func withoutALedgerOpenBotIsNotConsulted() {
        // Tests and developer modes: no ledger, and not a single read of the old service.
        let items = Items()
        items.stored["\(legacy)/openai"] = "k"
        #expect(Keychain.lookup("openai", service: own, items: items, ledger: nil) == nil)
        #expect(!items.reads.contains("\(legacy)/openai"))
    }

    @Test func otherServicesNeverFallBack() {
        let (items, _, ledger) = setUp()
        items.stored["\(legacy)/openai"] = "k"
        #expect(Keychain.lookup("openai", service: "app.outro", items: items, ledger: ledger) == nil)
        #expect(Keychain.write("x", account: "openai", service: "app.outro", items: items, ledger: ledger))
        #expect(!ledger.handled("openai"))
    }

    @Test func aFailedCopyIsRetriedNextTime() {
        final class Locked: KeychainItems, @unchecked Sendable {
            func read(_ account: String, service: String) -> String? { service == Keychain.legacyService ? "k" : nil }
            func replace(_ value: String, account: String, service: String) -> Bool { false }
        }
        let preferences = FakePreferences()
        let ledger = LegacyKeychainLedger(preferences: preferences)
        #expect(Keychain.lookup("openai", service: own, items: Locked(), ledger: ledger) == "k") // it still works now
        #expect(!ledger.handled("openai"))
    }
}
