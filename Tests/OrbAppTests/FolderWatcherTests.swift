import Foundation
import os
import Testing
@testable import Orb

/// The panel's "Arquivos" list follows the Orb's folder while it is open (`FolderWatcher`), leaving out what it never shows.
@Suite final class FolderWatcherTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "OrbFolderWatcher-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    @Test func onlyChangesTheListCanShowCount() {
        let root = "/Users/x/projeto"
        #expect(FolderWatcher.matters("/Users/x/projeto/notas.md", in: root))
        #expect(FolderWatcher.matters("/Users/x/projeto/docs/a/b.md", in: root + "/"))
        #expect(FolderWatcher.matters("/Users/x/projeto/.git/index", in: root)) // what git sees as changed
        #expect(!FolderWatcher.matters("/Users/x/projeto/.git/objects/ab/cdef", in: root))
        #expect(!FolderWatcher.matters("/Users/x/projeto/node_modules/pacote/index.js", in: root))
        #expect(!FolderWatcher.matters("/Users/x/projeto/.DS_Store", in: root))
        #expect(!FolderWatcher.matters("/Users/x/projeto-2/notas.md", in: root)) // a sibling with the same prefix
    }

    @Test func aFileWrittenInTheFolderIsSeen() async throws {
        let seen = OSAllocatedUnfairLock(initialState: false)
        let changes = FolderWatcher.changes(in: folder, latency: 0.1)
        let reader = Task {
            for await _ in changes {
                seen.withLock { $0 = true }
                return
            }
        }
        // The stream starts "since now": keep writing until it reports, so a slow start does not miss the change.
        for attempt in 0..<40 where !seen.withLock({ $0 }) {
            try "\(attempt)".write(to: folder.appending(path: "nota-\(attempt).md"), atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(250))
        }
        reader.cancel()
        #expect(seen.withLock { $0 })
    }

    @Test func theFolderIsComparedAsFSEventsReportsIt() {
        // The temporary folder is under /var, a link to /private/var: FSEvents reports the second.
        #expect(FolderWatcher.realPath(URL(filePath: "/var")) == "/private/var")
    }

    @Test func theHomeFolderIsNotWatched() async {
        var count = 0
        for await _ in FolderWatcher.changes(in: folder, home: folder) { count += 1 }
        #expect(count == 0) // the stream ends at once
    }
}
