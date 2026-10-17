import Foundation
import Testing
@testable import Orb

/// The weekly cleaning of the caches of an Orb's browser profile: caches go, logins and cookies stay.
struct BrowserProfileCacheTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "OrbCache-\(UUID().uuidString)")

    private func write(_ path: String, bytes: Int = 1_000, in profile: URL) throws {
        let url = profile.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func exists(_ path: String, in profile: URL) -> Bool { FileManager.default.fileExists(atPath: profile.appending(path: path).path) }

    /// What a cleaning never touches: logins, cookies, storage of sites and of extensions, preferences.
    static let kept = ["Default/Cookies", "Default/Login Data", "Default/Local Storage/leveldb/000003.log", "Default/IndexedDB/https_x/1",
                       "Default/Preferences", "Default/Service Worker/Database/CURRENT", "Local State", "Default/Web Data",
                       "Default/Local Extension Settings/abc/000003.log", "Default/Sync Extension Settings/abc/LOG", "Default/Extension State/LOG",
                       "Default/Extensions/abc/1.0/manifest.json", "Default/Session Storage/LOG", "Default/Storage/ext/abc/def/LOG"]

    /// A profile folder (`<orb>/chrome`) with caches and with what must survive.
    private func makeProfile() throws -> URL {
        let profile = root.appending(path: UUID().uuidString).appending(path: "chrome")
        for cache in ["Default/Cache/data_0", "Default/Code Cache/js/index", "Default/GPUCache/data", "Default/Service Worker/CacheStorage/x/y",
                      "Default/Service Worker/ScriptCache/a", "GrShaderCache/b", "GPUPersistentCache/c"] {
            try write(cache, bytes: 5_000, in: profile)
        }
        for keep in Self.kept {
            try write(keep, in: profile)
        }
        return profile
    }

    @Test func cleaningRemovesTheCachesAndKeepsEveryLogin() throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(BrowserProfileCache.size(profile: profile) >= 35_000)
        let freed = BrowserProfileCache.clean(profile: profile)
        #expect(freed >= 35_000)
        for gone in ["Default/Cache", "Default/Code Cache", "Default/GPUCache", "Default/Service Worker/CacheStorage",
                     "Default/Service Worker/ScriptCache", "GrShaderCache", "GPUPersistentCache"] {
            #expect(!exists(gone, in: profile), "\(gone)")
        }
        for kept in Self.kept {
            #expect(exists(kept, in: profile), "\(kept)")
        }
        #expect(BrowserProfileCache.lastCleaned(profile: profile) != nil)
        #expect(BrowserProfileCache.size(profile: profile) == 0)
    }

    @Test func aLinkInsideTheProfileIsNeverFollowed() throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(count: 10).write(to: outside.appending(path: "precious"))
        try FileManager.default.removeItem(at: profile.appending(path: "GrShaderCache"))
        try FileManager.default.createSymbolicLink(at: profile.appending(path: "GrShaderCache"), withDestinationURL: outside)
        BrowserProfileCache.clean(profile: profile)
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: "precious").path))
    }

    @Test func itIsDueOnceAWeekAndOnlyWhenThereIsEnoughToRemove() throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        #expect(BrowserProfileCache.due(profile: profile, now: now))
        // Too little to be worth it: nothing is removed, but the day is noted so it is not looked at again for a week.
        #expect(BrowserProfileCache.cleanIfDue(profile: profile, now: now) == 0)
        #expect(exists("Default/Cache/data_0", in: profile))
        #expect(!BrowserProfileCache.due(profile: profile, now: now.addingTimeInterval(6 * 24 * 3600)))
        #expect(BrowserProfileCache.due(profile: profile, now: now.addingTimeInterval(8 * 24 * 3600)))
        // A week later, with the bar lowered, it cleans.
        let later = now.addingTimeInterval(8 * 24 * 3600)
        #expect(BrowserProfileCache.cleanIfDue(profile: profile, now: later, worth: 1_000) >= 35_000)
        #expect(!exists("Default/Cache", in: profile) && exists("Default/Cookies", in: profile))
        #expect(!BrowserProfileCache.due(profile: profile, now: later.addingTimeInterval(24 * 3600)))
    }

    @Test func aMissingProfileIsLeftAlone() {
        #expect(BrowserProfileCache.cleanIfDue(profile: root.appending(path: "nope/chrome"), worth: 0) == 0)
    }

    @Test func theHubDoesNotCleanWhileTheOrbsBrowserIsOpen() async throws {
        let profiles = root.appending(path: "navegador")
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = FakeBrowserSetup(profiles: profiles)
        let profile = try #require(setup.hub.profileFolder(botID: setup.botID))
        for cache in ["Default/Cache/data_0", "Default/Service Worker/CacheStorage/x"] { try write(cache, bytes: 5_000, in: profile) }
        try write("Default/Cookies", in: profile)

        _ = try await setup.hub.session(botID: setup.botID, mode: .background)
        #expect(await setup.hub.cleanCachesIfDue(botID: setup.botID, worth: 1) == 0)
        #expect(exists("Default/Cache/data_0", in: profile))

        await setup.hub.close(botID: setup.botID)
        let freed = await setup.hub.cleanCachesIfDue(botID: setup.botID, worth: 1)
        #expect(freed >= 10_000)
        #expect(!exists("Default/Cache", in: profile) && exists("Default/Cookies", in: profile))
        // Not again within the week.
        try write("Default/Cache/data_1", bytes: 5_000, in: profile)
        #expect(await setup.hub.cleanCachesIfDue(botID: setup.botID, worth: 1) == 0)
    }

    @Test func aProfileABrowserHasOpenIsNeverCleaned() throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: root) }
        // Chromium's lock names this very process: a browser that is running.
        let lock = profile.appending(path: "SingletonLock")
        try FileManager.default.createSymbolicLink(atPath: lock.path, withDestinationPath: "mac.local-\(ProcessInfo.processInfo.processIdentifier)")
        #expect(BrowserProfileCache.isInUse(profile: profile))
        #expect(BrowserProfileCache.cleanIfDue(profile: profile, worth: 1) == 0)
        #expect(exists("Default/Cache/data_0", in: profile) && BrowserProfileCache.lastCleaned(profile: profile) == nil)
        // A lock a crashed browser left names a process that is gone: the profile is free.
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createSymbolicLink(atPath: lock.path, withDestinationPath: "mac.local-999999")
        #expect(!BrowserProfileCache.isInUse(profile: profile))
        #expect(BrowserProfileCache.cleanIfDue(profile: profile, worth: 1) > 0)
    }
}
