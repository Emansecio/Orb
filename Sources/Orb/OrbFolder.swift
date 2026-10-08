import AppKit
import Foundation

// MARK: - An Orb's own folder

/// Where an Orb lives on disk. A new Orb gets a folder of its own, `~/Orbs/<Name>/`, so it has a home base that is
/// not the whole home folder: inside it, "Perguntar antes" lets it write without asking (see
/// `PermissionPolicy.ownFolder`). Nothing here confines the Orb to the folder.
enum OrbFolder {
    /// `~/Orbs`. Tests pass a temporary base instead; nothing in the tests may create this one.
    static var defaultBase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Orbs", directoryHint: .isDirectory)
    }

    /// Longest folder name we create, in UTF-8 bytes (the file system allows 255, and a " 12" suffix may follow).
    private static let nameByteLimit = 200

    /// The Orb's name as a folder name: no "/" or ":" (Finder shows one as the other), no control characters, no
    /// leading dots (the folder would be hidden), one space between words. Emoji and accents stay.
    static func folderName(for name: String) -> String {
        var cleaned = ""
        for scalar in name.unicodeScalars {
            switch scalar {
            case "/", ":", "\\": cleaned.unicodeScalars.append("-")
            case _ where CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{7F}": cleaned.unicodeScalars.append(" ")
            default: cleaned.unicodeScalars.append(scalar)
            }
        }
        var words = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let first = words.first, first == "." || first.isWhitespace { words.removeFirst() }
        while words.utf8.count > nameByteLimit { words.removeLast() }
        let result = words.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "Orb" : result
    }

    /// The folder a new Orb called `name` would get in `base`: "Name", or "Name 2", "Name 3"… when taken.
    /// Nothing is created.
    static func availableURL(for name: String, in base: URL, manager: FileManager = .default) -> URL {
        let stem = folderName(for: name)
        for number in 1...999 {
            let candidate = base.appending(path: number == 1 ? stem : "\(stem) \(number)", directoryHint: .isDirectory)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return base.appending(path: "\(stem) \(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    /// Creates `base` if needed, then a folder for `name` in it that did not exist before (so two Orbs created
    /// together never share one). Returns the created folder.
    static func create(for name: String, in base: URL, manager: FileManager = .default) throws -> URL {
        do {
            try manager.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            throw OrbFolderError(path: base.path, reason: error)
        }
        // Creating without intermediates fails when the folder exists, which is how a name taken meanwhile shows up.
        var attempt = 0
        while attempt < 20 {
            attempt += 1
            let candidate = availableURL(for: name, in: base, manager: manager)
            do {
                try manager.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw OrbFolderError(path: candidate.path, reason: error)
            }
        }
        throw OrbFolderError(path: base.path, reason: nil)
    }

    /// How `Bot.workingDirectory` stores a chosen folder: the absolute path, like the folder picker does.
    static func storedPath(_ url: URL) -> String { url.standardizedFileURL.path }

    // MARK: State

    enum State: Equatable, Sendable {
        /// The folder is gone (deleted, renamed, or on a disk that is not connected).
        case missing
        /// The home folder (the default of old Orbs) or something that contains it: no place of its own.
        case noOwnFolder
        case ownFolder
    }

    /// Reads the disk: call it off the main thread when the folder may be on a slow volume.
    static func state(of folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> State {
        guard folder.isExistingDirectory else { return .missing }
        return PermissionPolicy.ownFolder(folder, home: home) == nil ? .noOwnFolder : .ownFolder
    }

    /// What the panel and the sheet show for a path: the home folder written as "~".
    static func display(_ url: URL, home: String = NSHomeDirectory()) -> String {
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Opening

    @MainActor
    static func showInFinder(_ folder: URL) {
        NSWorkspace.shared.open(folder)
    }

    /// A new Terminal window in the folder. Handing the folder to Terminal.app needs no AppleScript and no
    /// automation permission.
    @MainActor
    static func openInTerminal(_ folder: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            NSWorkspace.shared.open(folder)
            return
        }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// A folder that could not be created, in words for the user.
struct OrbFolderError: LocalizedError {
    var path: String
    var reason: Error?

    var errorDescription: String? {
        // Cocoa's messages end with a period already; callers add their own punctuation.
        let detail = reason.map { reason -> String in
            let text = (reason as NSError).localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
            return text.isEmpty ? "" : ": \(text)"
        } ?? ""
        return "Não consegui criar a pasta \(OrbFolder.display(URL(fileURLWithPath: path)))\(detail)"
    }
}

/// Where a new Orb will work, as chosen in the creation sheet.
enum OrbFolderChoice: Equatable, Sendable {
    /// `~/Orbs/<Name>/`, created with the Orb.
    case own
    /// No folder of its own: the home folder, as Orbs had before.
    case home
    /// A folder the user picked; it is not created or changed.
    case existing(URL)
}

// MARK: - AppModel

extension AppModel {
    /// Puts the Orb in a folder of its own, `~/Orbs/<Name>/`, and works there from now on.
    func createOwnFolder(for botID: UUID, base: URL = OrbFolder.defaultBase) throws {
        guard let bot = bot(botID) else { return }
        let folder = try OrbFolder.create(for: bot.name, in: base)
        update(botID) { $0.workingDirectory = OrbFolder.storedPath(folder) }
    }

    /// Makes the folder the Orb works in again after it went missing.
    func recreateFolder(of botID: UUID) throws {
        guard let bot = bot(botID), !bot.workingDirectory.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: bot.workingURL, withIntermediateDirectories: true)
        } catch {
            throw OrbFolderError(path: bot.workingURL.path, reason: error)
        }
    }

    /// Back to the home folder. The Orb's folder and what is in it are left alone.
    func useHomeFolder(of botID: UUID) {
        update(botID) { $0.workingDirectory = "" }
    }

    func chooseFolder(_ folder: URL, for botID: UUID) {
        update(botID) { $0.workingDirectory = OrbFolder.storedPath(folder) }
    }

    /// Renames the Orb. Its folder stays where it is. A name with only blanks is refused (false).
    @discardableResult
    func rename(_ botID: UUID, to name: String) -> Bool {
        let name = Self.clippedName(name)
        guard !name.isEmpty, bot(botID) != nil else { return false }
        update(botID) { $0.name = name }
        return true
    }

    /// The role may be empty: the Orb then shows no subtitle.
    func setRole(_ botID: UUID, to role: String) {
        let role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        update(botID) { $0.role = role }
    }

    static let nameLimit = 60

    static func clippedName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Recent and changed files

/// A file the Orb's panel lists: changed according to git, or recently modified.
struct WorkspaceFile: Identifiable, Equatable, Sendable {
    enum Marker: String, Sendable {
        case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "??", conflict = "!"

        /// For `git status --porcelain=v1`'s two-letter code.
        init(code: String) {
            let letters = Array(code)
            let x = letters.first ?? " ", y = letters.dropFirst().first ?? " "
            if code == "??" {
                self = .untracked
            } else if x == "U" || y == "U" || code == "AA" || code == "DD" {
                self = .conflict
            } else if x == "D" || y == "D" {
                self = .deleted
            } else if x == "A" {
                self = .added
            } else if x == "R" || x == "C" {
                self = .renamed
            } else {
                self = .modified
            }
        }

        var help: String {
            switch self {
            case .modified: "Alterado"
            case .added: "Adicionado"
            case .deleted: "Apagado"
            case .renamed: "Renomeado"
            case .untracked: "Novo, fora do git"
            case .conflict: "Em conflito"
            }
        }
    }

    /// Relative to the Orb's folder.
    var path: String
    var url: URL
    var marker: Marker?
    var modified: Date?

    var id: String { path }
}

/// The "Arquivos" list of the panel, built from the snapshot the turns already use (`WorkspaceSnapshots`), so the
/// folder is scanned once for both.
enum WorkspaceFiles {
    static let limit = 8

    struct Listing: Equatable, Sendable {
        var folder: OrbFolder.State
        /// What the snapshot could read; `.home` and `.missing` have no files to show.
        var snapshot: WorkspaceSnapshot.State
        var files: [WorkspaceFile] = []
    }

    /// Reads the folder's state and files (off the main thread). `refresh` drops the cached snapshot first: after a
    /// turn, or when the user asks.
    static func load(botID: UUID, folder: URL, refresh: Bool, snapshots: WorkspaceSnapshots = .shared,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> Listing {
        if refresh { await snapshots.invalidate(botID) }
        let snapshot = await snapshots.snapshot(for: botID, folder: folder)
        let state = OrbFolder.state(of: folder, home: home)
        return Listing(folder: state, snapshot: snapshot.state, files: list(from: snapshot, folder: folder))
    }

    /// Changed files first (newest first; deleted ones last), then recently modified ones that are not among them.
    static func list(from snapshot: WorkspaceSnapshot, folder: URL, limit: Int = limit) -> [WorkspaceFile] {
        guard snapshot.state == .scanned else { return [] }
        let folder = folder.standardizedFileURL
        var changed = changedFiles(snapshot.git, folder: folder)
        // Stable: files with the same date (or none) keep git's order.
        changed = changed.enumerated().sorted { left, right in
            let (a, b) = (left.element, right.element)
            if (a.marker == .deleted) != (b.marker == .deleted) { return b.marker == .deleted }
            switch (a.modified, b.modified) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.offset < right.offset
            }
        }.map(\.element)

        var result = Array(changed.prefix(limit))
        let known = Set(changed.map(\.path))
        for recent in snapshot.recentFiles where result.count < limit && !known.contains(recent.path) {
            result.append(WorkspaceFile(path: recent.path, url: folder.appending(path: recent.path), marker: nil,
                                        modified: recent.modified))
        }
        return result
    }

    /// Limitation: `WorkspaceSnapshot` keeps only the first `changeLimit` lines of `git status`, relative to the
    /// repository root. When the Orb's folder is a subfolder of a repository with many changes elsewhere, those
    /// lines may all be outside it and no changed file is listed (recent files still are).
    private static func changedFiles(_ git: WorkspaceSnapshot.Git?, folder: URL) -> [WorkspaceFile] {
        guard let git, !git.changes.isEmpty, let root = repositoryRoot(of: folder) else { return [] }
        var files: [WorkspaceFile] = []
        for line in git.changes {
            guard let change = parseStatusLine(line) else { continue }
            // `git status --porcelain` paths start at the repository's root, which may be above the Orb's folder.
            let url = root.appending(path: change.path).standardizedFileURL
            guard let relative = relativePath(of: url, in: folder), !relative.isEmpty else { continue }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            files.append(WorkspaceFile(path: relative + (change.path.hasSuffix("/") ? "/" : ""), url: url,
                                       marker: WorkspaceFile.Marker(code: change.code), modified: modified))
        }
        return files
    }

    private static func relativePath(of url: URL, in folder: URL) -> String? {
        let parts = url.pathComponents, base = folder.pathComponents
        guard parts.count > base.count, parts.starts(with: base) else { return nil }
        return parts.dropFirst(base.count).joined(separator: "/")
    }

    /// The nearest folder at or above `folder` that holds a `.git`.
    static func repositoryRoot(of folder: URL) -> URL? {
        var directory = folder.standardizedFileURL
        for _ in 0..<24 {
            if FileManager.default.fileExists(atPath: directory.appending(path: ".git").path) { return directory }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
        return nil
    }

    /// One line of `git status --porcelain=v1`: "XY path", or "XY old -> new" for a rename. Paths with unusual
    /// characters come quoted, C style.
    static func parseStatusLine(_ line: String) -> (code: String, path: String)? {
        guard line.count > 3 else { return nil }
        let code = String(line.prefix(2))
        var rest = String(line.dropFirst(3))
        if code.contains("R") || code.contains("C"), let arrow = rest.range(of: " -> ", options: .backwards) {
            rest = String(rest[arrow.upperBound...])
        }
        let path = rest.hasPrefix("\"") ? unquote(rest) : rest
        return path.isEmpty ? nil : (code, path)
    }

    /// Reverses git's C-style quoting: `\"`, `\\`, `\t`, `\n` and octal bytes (UTF-8 of non-ASCII names).
    static func unquote(_ quoted: String) -> String {
        var bytes: [UInt8] = []
        let source = Array(quoted.utf8)
        var index = 1 // after the opening quote
        while index < source.count {
            let byte = source[index]
            if byte == UInt8(ascii: "\"") { break }
            guard byte == UInt8(ascii: "\\"), index + 1 < source.count else {
                bytes.append(byte)
                index += 1
                continue
            }
            let next = source[index + 1]
            if (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(next) {
                var value = 0, digits = 0
                while digits < 3, index + 1 + digits < source.count,
                      (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(source[index + 1 + digits]) {
                    value = value * 8 + Int(source[index + 1 + digits] - UInt8(ascii: "0"))
                    digits += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                index += 1 + digits
                continue
            }
            switch next {
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "r"): bytes.append(13)
            default: bytes.append(next)
            }
            index += 2
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
