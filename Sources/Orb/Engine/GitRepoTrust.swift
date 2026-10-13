import Foundation

/// Whether reading a git repository with `git status`, `git diff`, `git log -p`… is safe to wave through.
///
/// Those commands look like reads, but git runs programs named in the repository's own configuration while it does them:
/// `core.fsmonitor`, `diff.external`, `diff.<driver>.textconv`, `filter.<name>.clean`, `gpg.program` (with
/// `log.showSignature`), a `post-index-change` hook, files pulled in by `[include]`. A folder that was downloaded or
/// unzipped can bring a `.git/config` that does so, and the line would run code even in "Só leitura". So before the
/// read-only exemption is applied to a git line, the configuration of the repository the command will run in is looked
/// at, textually and without running anything. Doubt (a config that cannot be read, a huge one, a setting that can
/// start a program) means "not safe": the line then goes through the ordinary rules and asks.
enum GitRepoTrust {
    /// Largest `config` file that is read; anything bigger is not trusted.
    static let maxConfigBytes = 256 * 1024
    /// Most entries looked at under `modules/` (submodules); more than that is not trusted.
    private static let maxModuleEntries = 500

    /// The folders `git` may run in for `arguments` (the words after `git`): `directories`, moved by a leading `-C dir`.
    /// Nil when `-C` points somewhere the text does not show.
    static func workingDirectories(arguments: [String], directories: [URL], home: URL) -> [URL]? {
        guard arguments.first == "-C", arguments.count >= 2 else { return directories }
        return DangerousCommand.directory(afterCD: arguments[1], from: directories, home: home)
    }

    /// True when no repository is found above `directory` (git fails by itself then) or the one found has nothing in its
    /// configuration, hooks or submodules that could run a program.
    static func isSafeToRead(directory: URL) -> Bool {
        let fileManager = FileManager.default
        var folder = directory.standardizedFileURL
        var found: (root: URL, gitDir: URL)?
        while true {
            let dotGit = folder.appending(path: ".git")
            var isFolder: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isFolder) {
                if isFolder.boolValue {
                    found = (folder, dotGit)
                } else {
                    // A worktree or submodule: the file says `gitdir: <path>`, relative to the folder holding it.
                    guard let text = readSmallFile(dotGit), text.count <= 4096,
                          let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") })
                    else { return false }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    guard !path.isEmpty else { return false }
                    found = (folder, resolve(path, from: folder))
                }
                break
            }
            // A bare repository: the folder is the git directory itself.
            var isHead: ObjCBool = false, isObjects: ObjCBool = false
            if fileManager.fileExists(atPath: folder.appending(path: "HEAD").path, isDirectory: &isHead), !isHead.boolValue,
               fileManager.fileExists(atPath: folder.appending(path: "objects").path, isDirectory: &isObjects), isObjects.boolValue,
               fileManager.fileExists(atPath: folder.appending(path: "refs").path) {
                found = (folder, folder)
                break
            }
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            if parent.path == folder.path { break }
            folder = parent
        }
        guard let (root, gitDir) = found else { return true }

        // The shared directory of a linked worktree holds the main `config`, the hooks and the submodules.
        var directories = [gitDir]
        if fileManager.fileExists(atPath: gitDir.appending(path: "commondir").path) {
            guard let text = readSmallFile(gitDir.appending(path: "commondir")) else { return false }
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return false }
            let common = resolve(path, from: gitDir)
            if common.path != gitDir.path { directories.append(common) }
        }

        for directory in directories {
            guard isSafeDirectory(directory, root: root) else { return false }
            let modules = directory.appending(path: "modules")
            guard fileManager.fileExists(atPath: modules.path) else { continue }
            guard let enumerator = fileManager.enumerator(at: modules, includingPropertiesForKeys: nil) else { return false }
            var seen = 0
            for case let url as URL in enumerator {
                seen += 1
                if seen > maxModuleEntries { return false }
                guard url.lastPathComponent == "config" else { continue }
                guard isSafeDirectory(url.deletingLastPathComponent(), root: root) else { return false }
            }
        }
        return true
    }

    /// One git directory: its `config` files and its `hooks`. Only files that exist are looked at; one that exists but
    /// cannot be read is not trusted.
    private static func isSafeDirectory(_ directory: URL, root: URL) -> Bool {
        let fileManager = FileManager.default
        for name in ["config", "config.worktree"] {
            let url = directory.appending(path: name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard let text = readSmallFile(url), isSafe(config: text, gitDir: directory, root: root) else { return false }
        }
        // `git status` rewrites the index and then runs this hook.
        if fileManager.isExecutableFile(atPath: directory.appending(path: "hooks/post-index-change").path) { return false }
        return true
    }

    private static func readSmallFile(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= maxConfigBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func resolve(_ path: String, from base: URL) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appending(path: path)).standardizedFileURL
    }

    // MARK: Configuration text

    private static let booleans: Set<String> = ["true", "false", "yes", "no", "on", "off", "1", "0", ""]
    private static let programKeys: Set<String> = [
        "textconv", "command", "external", "program", "helper", "hookspath", "sshcommand", "askpass", "editor", "pager",
        "alternaterefscommand", "packobjectshook",
    ]
    private static let programSuffixes = ["command", "program", "helper", "editor", "pager", "hook", "hookspath"]

    /// Whether the text of a git `config` file sets nothing that makes git run a program or read another file of
    /// settings. `gitDir` is where a relative `core.worktree` is resolved from, `root` the folder that holds the worktree.
    static func isSafe(config text: String, gitDir: URL, root: URL) -> Bool {
        var section = ""
        for line in logicalLines(text) {
            var rest = Substring(line.trimmingCharacters(in: .whitespaces))
            if rest.isEmpty || rest.hasPrefix("#") || rest.hasPrefix(";") { continue }
            if rest.hasPrefix("[") {
                guard let close = headerEnd(rest) else { return false }
                let header = rest[rest.index(after: rest.startIndex)..<close]
                section = String(header.prefix { !$0.isWhitespace && $0 != "\"" && $0 != "." }).lowercased()
                if ["include", "includeif", "filter", "pager"].contains(section) { return false }
                rest = Substring(rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces))
                if rest.isEmpty || rest.hasPrefix("#") || rest.hasPrefix(";") { continue }
            }
            let key = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" }).lowercased()
            guard !key.isEmpty else { continue }
            let tail = rest.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            let value = tail.hasPrefix("=") ? unquoted(String(tail.dropFirst())) : nil
            // `color.pager` only says whether to colour what goes to the pager.
            if section != "color", programKeys.contains(key) || programSuffixes.contains(where: key.hasSuffix) { return false }
            if section == "core" {
                if key == "fsmonitor", let value, !booleans.contains(value.lowercased()) { return false }
                if key == "worktree" {
                    guard let value, !value.isEmpty, isInside(resolve(value, from: gitDir), root: root) else { return false }
                }
            }
        }
        return true
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        for candidate in [url.path, canonical(url)] {
            for base in [root.path, canonical(root)] {
                if candidate == base || candidate.hasPrefix(base + "/") { return true }
            }
        }
        return false
    }

    /// The path with symbolic links resolved as far as it exists (the rest, a folder that is not there yet, is kept as it
    /// is) and macOS's `/private` prefix of `/var` and friends dropped, so two spellings of one place compare equal.
    private static func canonical(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var path = ([existing.resolvingSymlinksInPath().path] + rest).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
        for prefix in ["/private/var", "/private/tmp", "/private/etc"] where path == prefix || path.hasPrefix(prefix + "/") {
            path = String(path.dropFirst("/private".count))
        }
        return path
    }

    /// The lines of the file, a trailing backslash joining the next one.
    private static func logicalLines(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            let slashes = line.reversed().prefix { $0 == "\\" }.count
            if slashes % 2 == 1 {
                current += line.dropLast()
            } else {
                result.append(current + line)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The index of the `]` that closes a `[section "sub"]` header, skipping one inside quotes.
    private static func headerEnd(_ line: Substring) -> Substring.Index? {
        var quoted = false, escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true }
            else if character == "\"" { quoted.toggle() }
            else if character == "]", !quoted { return index }
        }
        return nil
    }

    /// A value without its quotes and trailing comment (`# …` or `; …` outside quotes), trimmed.
    private static func unquoted(_ raw: String) -> String {
        var result = "", quoted = false, escaped = false
        for character in raw {
            if escaped { result.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if !quoted, character == "#" || character == ";" { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
