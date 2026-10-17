import Foundation

/// What a Chromium profile keeps only to load pages faster again (HTTP and code caches, shader and GPU caches, the Cache Storage and
/// script cache of service workers). It grows without bound (one profile of the app measured 412 MB, almost all of it Cache Storage)
/// and none of it is a login: cookies, saved logins, local storage, IndexedDB and the preferences are not in this list and are never
/// touched. Only done while the Orb's browser is not running.
enum BrowserProfileCache {
    /// Folders to empty, relative to the profile folder (`<orb>/chrome`).
    static let folders = [
        "Default/Cache", "Default/Code Cache", "Default/GPUCache", "Default/DawnGraphiteCache", "Default/DawnWebGPUCache",
        "Default/Service Worker/CacheStorage", "Default/Service Worker/ScriptCache", "Default/Shared Dictionary/cache",
        "Default/Media Cache", "GrShaderCache", "ShaderCache", "GraphiteDawnCache", "GPUPersistentCache", "component_crx_cache",
        "extensions_crx_cache",
    ]

    /// How often a profile is cleaned.
    static let interval: TimeInterval = 7 * 24 * 3600
    /// A profile with less than this in those folders is not worth the trouble (and the next page load rebuilding it).
    static let worthIt: Int64 = 20_000_000

    /// The note of when the Orb's profile was last cleaned, next to the profile (not inside it: the browser owns that folder).
    static func stamp(for profile: URL) -> URL { profile.deletingLastPathComponent().appending(path: "limpeza-de-cache") }

    static func lastCleaned(profile: URL) -> Date? {
        (try? String(contentsOf: stamp(for: profile), encoding: .utf8)).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map { Date(timeIntervalSince1970: $0) }
    }

    static func due(profile: URL, now: Date = .now) -> Bool {
        guard let last = lastCleaned(profile: profile) else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// The size of what `clean` would remove.
    static func size(profile: URL) -> Int64 {
        folders.reduce(0) { $0 + folderSize(profile.appending(path: $1)) }
    }

    /// Empties the cache folders and returns the bytes freed. Nothing else in the profile is touched. The folders themselves are
    /// removed (the browser makes them again).
    @discardableResult
    static func clean(profile: URL, now: Date = .now) -> Int64 {
        let fileManager = FileManager.default
        var freed: Int64 = 0
        for folder in folders {
            let url = profile.appending(path: folder)
            // A folder that is a link would send the removal somewhere else: only real folders inside the profile.
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  values.isSymbolicLink != true, values.isDirectory == true else { continue }
            let bytes = folderSize(url)
            if (try? fileManager.removeItem(at: url)) != nil { freed += bytes }
        }
        try? String(now.timeIntervalSince1970).write(to: stamp(for: profile), atomically: true, encoding: .utf8)
        return freed
    }

    /// Cleans when a week has passed since the last time and there is enough to remove; the day is noted either way.
    @discardableResult
    static func cleanIfDue(profile: URL, now: Date = .now, worth: Int64 = worthIt) -> Int64 {
        guard FileManager.default.fileExists(atPath: profile.path), due(profile: profile, now: now) else { return 0 }
        guard size(profile: profile) >= worth else {
            try? String(now.timeIntervalSince1970).write(to: stamp(for: profile), atomically: true, encoding: .utf8)
            return 0
        }
        return clean(profile: profile, now: now)
    }

    private static func folderSize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
