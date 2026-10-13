import Foundation

/// Tells whether a shell command line only looks: lists, prints, counts, asks git for its state. Such a line needs no
/// approval card in "Perguntar antes" and still runs in "Só leitura", like the dedicated read tools.
///
/// The test is deliberately narrow. Every command must be on a short list and used without any option that writes a
/// file or runs another program, nothing may be redirected, expanded or run in the background, and no word may point at
/// a private key or saved password (those always need the user's word, see `DangerousCommand.SensitiveFiles`). A
/// line that is not clearly read-only is simply not covered here and goes through the ordinary rules; this never
/// claims a command is safe in general.
enum ReadOnlyCommand {
    static func isReadOnly(_ line: ShellCommandLine, directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard line.isPlain, !line.segments.isEmpty else { return false }
        let sensitive = DangerousCommand.SensitiveFiles(home: home)
        // Every folder the shell may be in as the line goes on: where it started, and where each `cd` could have taken it
        // (a `cd` that fails leaves it where it was, so relative words are judged against all of them).
        var directories = [directory.standardizedFileURL]
        if sensitive.reason(for: directories[0].path + "/x", patterns: false) != nil { return false }
        for segment in line.segments {
            guard segment.separator != .background,
                  isReadOnly(segment.words, directories: directories, home: home, sensitive: sensitive) else { return false }
            // `git status` and `git diff` run the programs a repository's config names (`core.fsmonitor`, `diff.external`,
            // textconv, clean filters, hooks), so a read of a repository that sets one is not exempt. The folders are the
            // ones git may run in: the shell's, moved by `-C`; one the text does not show is never exempt.
            if segment.words.first == "git" {
                guard let gitDirectories = GitRepoTrust.workingDirectories(arguments: Array(segment.words.dropFirst()), directories: directories, home: home),
                      gitDirectories.allSatisfy(GitRepoTrust.isSafeToRead(directory:)) else { return false }
            }
            if segment.words.first == "cd" {
                guard segment.words.count == 2, let target = DangerousCommand.directory(afterCD: segment.words[1], from: directories, home: home)
                else { return false }
                directories += target
            }
        }
        return true
    }

    // MARK: Commands

    /// Commands that never write or run anything, whatever their options. They show names, sizes and dates only.
    private static let listing: Set<String> = [
        "pwd", "ls", "wc", "file", "stat", "du", "df", "which", "whoami", "id", "uname", "uptime", "sw_vers", "date", "basename",
        "dirname", "realpath", "readlink", "mdfind", "mdls", "pgrep", "ps", "echo", "type",
    ]
    /// Commands that print file contents: also refuse wildcards that could reach hidden or private files.
    private static let readers: Set<String> = [
        "cat", "head", "tail", "grep", "egrep", "fgrep", "sort", "uniq", "cut", "nl", "diff", "cmp", "shasum", "md5",
    ]
    private static let gitSubcommands: Set<String> = [
        "status", "log", "diff", "show", "rev-parse", "blame", "ls-files", "ls-tree", "describe", "shortlog", "cat-file", "merge-base",
        "name-rev", "diff-tree", "count-objects", "grep", "remote", "branch", "tag", "stash", "config", "reflog",
    ]
    /// Options of git (or any command) that write a result to a file or hand it to another program.
    private static let writingOptions = ["--output", "--open-files-in-pager", "--ext-diff", "--no-index", "--upload-pack", "--exec",
                                         "--pager", "--paginate", "-O"]

    /// Whether `word` is one of the long `names`, spelled out or abbreviated, with or without a value (`--out=x` for
    /// `--output`). getopt_long and git's parse-options accept any unique prefix, so comparing exact names is not enough.
    /// Deliberately wide: a prefix that merely could be the option is enough, since doubt only sends the line to the card.
    static func abbreviates(_ word: String, anyOf names: [String]) -> Bool {
        guard word.hasPrefix("--") else { return false }
        let name = word.prefix { $0 != "=" }
        return name.count > 2 && names.contains { $0.hasPrefix(name) }
    }

    /// Whether a group of short options (`-iO`, `-nr`) holds one of `letters`. Operands and long options are not groups.
    private static func hasShortOption(_ words: [String], _ letters: String) -> Bool {
        words.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains { letters.contains($0) } }
    }

    private static func isReadOnly(_ words: [String], directories: [URL], home: URL, sensitive: DangerousCommand.SensitiveFiles) -> Bool {
        guard let name = words.first, !name.contains("/") else { return false }
        let arguments = Array(words.dropFirst())
        // A variable or a `<` could stand for anything: `FLAG=--output=x git diff`, `cat <~/.ssh/id_rsa`.
        guard !words.contains(where: { $0.contains("$") || $0.hasPrefix("<") || $0.hasPrefix(">") || $0.contains("<(") }),
              !isAssignment(name) else { return false }
        // The words are read literally here, but zsh expands more than that: glob qualifiers (`*(e:'cmd':)` runs `cmd`),
        // `=(cmd)`, `=cmd` and braces (`{.,}ssh`) all turn into something else. Any such word, quoted or not, goes to the card.
        guard !words.contains(where: { $0.hasPrefix("=") || $0.contains(where: { "(){}".contains($0) }) }) else { return false }
        // What prints a file's contents must not be pointed at a secret; listing a folder or a file's size shows none.
        if !listing.contains(name), name != "find" {
            for word in arguments where word.contains("/") || word.hasPrefix(".") || word.hasPrefix("~") || !word.hasPrefix("-") {
                if sensitive.reason(forShellWord: word, directories: directories, home: home, patterns: true) != nil { return false }
            }
        }

        switch name {
        case "cd":
            // Followed by the caller, which needs exactly one target. A wildcard would be matched by the shell, not by us.
            return arguments.count == 1 && !arguments[0].contains(where: { "*?[".contains($0) })
        case "date":
            return !arguments.contains { $0.hasPrefix("-s") || $0 == "--set" }
        case "command":
            // Only the lookup (`command -v node`); otherwise it runs what follows.
            return arguments.count > 1 && (arguments[0] == "-v" || arguments[0] == "-V")
        case "printf":
            // `printf -v name` assigns a shell variable.
            return !arguments.contains { $0.hasPrefix("-v") }
        case "ps":
            // `ps eww`, `ps -E` and (on macOS) `ps -e` print the environment of every process, tokens included.
            return !arguments.contains { $0.range(of: #"^-?[A-Za-z]+$"#, options: .regularExpression) != nil && $0.contains(where: { "eE".contains($0) }) }
        case "file":
            // `file -C` compiles a magic file, writing next to it.
            return !arguments.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("C") }
        case _ where listing.contains(name):
            return true
        case _ where readers.contains(name):
            if name == "diff", diffMayReadFolder(arguments, directories: directories, home: home) { return false }
            return readerIsSafe(name, arguments)
        case "find":
            let writes = ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"]
            return !arguments.contains(where: writes.contains)
        case "git":
            return gitIsReadOnly(arguments)
        default:
            return false
        }
    }

    private static func readerIsSafe(_ name: String, _ arguments: [String]) -> Bool {
        // Every word, also after a `--`: it can be the value of the option before it (`sort -T -- -o x`), and an option after it.
        let options = arguments.filter { $0.hasPrefix("-") && $0.count > 1 }
        func shortCluster(_ letters: String) -> Bool { hasShortOption(options, letters) }
        func long(_ names: [String]) -> Bool { options.contains { abbreviates($0, anyOf: names) } }
        switch name {
        case "grep", "egrep", "fgrep":
            // Recursion would walk into folders this check never looked at.
            if shortCluster("rRd") || long(["--recursive", "--directories", "--dereference-recursive"]) { return false }
        case "sort":
            if shortCluster("o") || long(["--output", "--compress-program"]) { return false }
        case "uniq":
            // A second operand is where uniq writes, and a lone `-` (the input) counts as one.
            var literal = false, operands = 0
            for word in arguments {
                if !literal, word == "--" { literal = true; continue }
                if literal || !word.hasPrefix("-") || word == "-" { operands += 1 }
            }
            if operands > 1 { return false }
        case "diff":
            // `-r` walks folders, `-l` and `--paginate` hand the result to `pr`, `--to-file` and `--from-file` compare
            // a file with every operand (a folder among them).
            if shortCluster("rl") || long(["--recursive", "--paginate", "--to-file", "--from-file"]) { return false }
        case "shasum", "md5":
            // `-c` reads the list of files to check from a file.
            if shortCluster("c") || long(["--check"]) { return false }
        default:
            break
        }
        // A wildcard in what is printed could match `.ssh` or `.env` files; plain relative names are judged by the loop above.
        for word in arguments where word.contains(where: { "*?[{".contains($0) }) && !word.hasPrefix("-") {
            let components = word.split(separator: "/", omittingEmptySubsequences: false)
            if word.hasPrefix("/") || word.hasPrefix("~") || components.contains("..") || components.contains(where: { $0.hasPrefix(".") }) {
                return false
            }
        }
        return true
    }

    /// `diff a.txt dir` compares with `dir/a.txt`, so an operand that is a folder (or may be one: a wildcard, `~user`, the
    /// home folder) reads a file of another name, `.netrc` or `.npmrc` among them, that no word shows.
    private static func diffMayReadFolder(_ arguments: [String], directories: [URL], home: URL) -> Bool {
        let homePaths = Set([home.standardizedFileURL.path, home.standardizedFileURL.resolvingSymlinksInPath().path])
        var literal = false
        for word in arguments {
            if !literal, word == "--" { literal = true; continue }
            if !literal, word.hasPrefix("-") { continue }
            if word == "-" { continue }
            if word.contains(where: { "*?[".contains($0) }) { return true }
            guard let urls = DangerousCommand.directory(afterCD: word, from: directories, home: home) else { return true }
            for url in urls {
                var isFolder: ObjCBool = false
                if homePaths.contains(url.path) || (FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue) {
                    return true
                }
            }
        }
        return false
    }

    private static func gitIsReadOnly(_ arguments: [String]) -> Bool {
        var rest = arguments[...]
        // `git -C dir status` is the one global option worth allowing; `-c` could set a pager or a hook.
        if rest.first == "-C", rest.count >= 2 { rest = rest.dropFirst(2) }
        guard let sub = rest.first, gitSubcommands.contains(sub) else { return false }
        let tail = Array(rest.dropFirst())
        if tail.contains(where: { word in writingOptions.contains { $0 == "-O" ? word.hasPrefix("-O") : abbreviates(word, anyOf: [$0]) } }) {
            return false
        }
        let options = tail.prefix { $0 != "--" }.filter { $0.hasPrefix("-") }
        // `git grep -iOcmd` is `-O` too: the pager runs through `sh -c`. Also after a `--` that is the value of `-e`.
        if sub == "grep", hasShortOption(tail.filter { $0.hasPrefix("-") }, "O") { return false }
        switch sub {
        case "remote":
            // Never `remote show <url>`: it asks that address over the network, a way to send data out.
            return tail.allSatisfy { $0 == "-v" || $0 == "--verbose" }
        case "branch":
            // Bare, or listing flags only; a name or -d/-m/-c would change something.
            let listing: Set<String> = ["-a", "-r", "-v", "-vv", "--all", "--remotes", "--verbose", "--list", "--show-current", "--merged", "--no-merged"]
            return tail.allSatisfy { listing.contains($0) || (!$0.hasPrefix("-") && options.contains("--list")) }
        case "tag":
            // A pure listing: no option that deletes, forces, signs or annotates (`--list -d v1` deletes), and a name only
            // as the pattern of `-l`/`--list` or the value of an option that implies listing; otherwise the name is a new tag.
            let changing = ["--delete", "--force", "--annotate", "--sign", "--local-user", "--message", "--file", "--edit"]
            if hasShortOption(Array(tail), "dfasuFme") || tail.contains(where: { abbreviates($0, anyOf: changing) }) { return false }
            let operands = tail.filter { !$0.hasPrefix("-") }
            let listsByName = tail.contains { $0 == "-l" || $0 == "--list" }
            let implies = tail.contains { ["--contains", "--no-contains", "--points-at", "--merged", "--no-merged"].contains($0) || $0.hasPrefix("-n") }
            return operands.isEmpty || listsByName || implies
        case "stash":
            return tail.first == "list" || tail.first == "show"
        case "config":
            // Never read-only: even a plain read (`--list`, `--get-regexp`, `--show-origin`) prints remote URLs with tokens in them.
            return false
        case "reflog":
            return tail.isEmpty || tail.first == "show" || tail.first?.hasPrefix("-") == true
        default:
            return true
        }
    }

    private static func isAssignment(_ word: String) -> Bool {
        word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
    }
}
