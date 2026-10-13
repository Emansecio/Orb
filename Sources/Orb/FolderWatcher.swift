import CoreServices
import Foundation
import os

/// Tells when something changes under a folder (FSEvents), so the panel's "Arquivos" list follows the folder while it
/// is on screen: a file the Orb (or anyone) writes, renames or deletes shows up without waiting for the end of the turn.
/// Changes the list never shows are left out (inside `.git`, except its index, which says what git sees as changed, and
/// in the folders the scan skips), so a build churning in `.build` does not keep reading the folder again.
enum FolderWatcher {
    /// One element per burst of changes (FSEvents gathers them over `latency`); only the newest waits while the reader is
    /// busy. Ends with the task that reads it. Nothing for the home folder, which is not scanned, or one that cannot be watched.
    static func changes(in folder: URL, latency: TimeInterval = 1,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let path = realPath(folder)
            guard path != realPath(home),
                  let stream = Stream(folder: path, latency: latency, changed: { continuation.yield() }) else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in stream.stop() }
        }
    }

    /// The path as FSEvents reports it. Not `resolvingSymlinksInPath`, which drops the `/private` that FSEvents keeps
    /// (`/var/folders/…` is reported as `/private/var/folders/…`), so no change would match the folder.
    static func realPath(_ url: URL) -> String {
        url.standardizedFileURL.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return url.standardizedFileURL.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// Whether a change at `path` (as FSEvents reports it: resolved, absolute) can change the list of `folder`.
    static func matters(_ path: String, in folder: String) -> Bool {
        let folder = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        guard path == folder || path.hasPrefix(folder + "/") else { return false }
        let parts = path.dropFirst(folder.count).split(separator: "/").map(String.init)
        if let git = parts.firstIndex(of: ".git") { return Array(parts[(git + 1)...]) == ["index"] }
        return !parts.contains { WorkspaceSnapshot.skippedFolders.contains($0) || $0 == ".DS_Store" }
    }

    /// The FSEvents stream, alive until `stop` (the `AsyncStream`'s termination holds it).
    private final class Stream: Sendable {
        let folder: String
        let changed: @Sendable () -> Void
        private let ref = OSAllocatedUnfairLock<FSEventStreamRef?>(uncheckedState: nil)
        private let queue = DispatchQueue(label: "Orb.FolderWatcher", qos: .utility)

        init?(folder: String, latency: TimeInterval, changed: @escaping @Sendable () -> Void) {
            self.folder = folder
            self.changed = changed
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
                guard let info else { return }
                let stream = Unmanaged<Stream>.fromOpaque(info).takeUnretainedValue()
                let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
                if list.contains(where: { FolderWatcher.matters($0, in: stream.folder) }) { stream.changed() }
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
            guard let created = FSEventStreamCreate(nil, callback, &context, [folder] as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return nil
            }
            ref.withLockUnchecked { $0 = created }
        }

        /// Stops the stream once; no callback comes after it.
        func stop() {
            guard let created = ref.withLockUnchecked({ state -> FSEventStreamRef? in defer { state = nil }; return state }) else { return }
            FSEventStreamStop(created)
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
        }
    }
}
