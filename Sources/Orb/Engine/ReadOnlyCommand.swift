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
        "dirname", "realpath", "readlink", "mdfind", "mdls", "pgrep", "ps", "echo",
    ]
    /// Commands that print file contents: also refuse wildcards that could reach hidden or private files.
    private static let readers: Set<String> = ["cat", "head", "tail", "grep", "egrep", "fgrep", "sort", "uniq", "cut", "nl"]
    private static let gitSubcommands: Set<String> = [
        "status", "log", "diff", "show", "rev-parse", "blame", "ls-files", "ls-tree", "describe", "shortlog", "cat-file", "merge-base",
        "name-rev", "diff-tree", "count-objects", "grep", "remote", "branch", "tag", "stash", "config", "reflog",
    ]
    /// Options of git (or any command) that write a result to a file or hand it to another program.
    private static let writingOptions = ["--output", "--open-files-in-pager", "--ext-diff", "--no-index", "--upload-pack", "--exec",
                                         "--pager", "--paginate", "-O"]

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
        case "ps":
            // `ps eww`, `ps -E` and (on macOS) `ps -e` print the environment of every process, tokens included.
            return !arguments.contains { $0.range(of: #"^-?[A-Za-z]+$"#, options: .regularExpression) != nil && $0.contains(where: { "eE".contains($0) }) }
        case "file":
            // `file -C` compiles a magic file, writing next to it.
            return !arguments.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("C") }
        case _ where listing.contains(name):
            return true
        case _ where readers.contains(name):
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
        let options = arguments.prefix { $0 != "--" }.filter { $0.hasPrefix("-") && $0.count > 1 }
        func shortCluster(_ letters: String) -> Bool { options.contains { !$0.hasPrefix("--") && $0.dropFirst().contains { letters.contains($0) } } }
        switch name {
        case "grep", "egrep", "fgrep":
            // Recursion would walk into folders this check never looked at.
            let recursive = options.contains(where: { $0.hasPrefix("--recursive") || $0.hasPrefix("--directories") || $0.hasPrefix("--dereference-recursive") })
            if shortCluster("rRd") || recursive { return false }
        case "sort":
            if shortCluster("o") || options.contains(where: { $0.hasPrefix("--output") || $0.hasPrefix("--compress-program") }) { return false }
        case "uniq":
            // A second file operand is where uniq writes.
            let operands = arguments.filter { !$0.hasPrefix("-") }
            if operands.count > 1 { return false }
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

    private static func gitIsReadOnly(_ arguments: [String]) -> Bool {
        var rest = arguments[...]
        // `git -C dir status` is the one global option worth allowing; `-c` could set a pager or a hook.
        if rest.first == "-C", rest.count >= 2 { rest = rest.dropFirst(2) }
        guard let sub = rest.first, gitSubcommands.contains(sub) else { return false }
        let tail = Array(rest.dropFirst())
        if tail.contains(where: { word in writingOptions.contains { word == $0 || word.hasPrefix($0 + "=") || ($0 == "-O" && word.hasPrefix("-O")) } }) {
            return false
        }
        let options = tail.prefix { $0 != "--" }.filter { $0.hasPrefix("-") }
        switch sub {
        case "remote":
            // Never `remote show <url>`: it asks that address over the network, a way to send data out.
            return tail.allSatisfy { $0 == "-v" || $0 == "--verbose" }
        case "branch":
            // Bare, or listing flags only; a name or -d/-m/-c would change something.
            let listing: Set<String> = ["-a", "-r", "-v", "-vv", "--all", "--remotes", "--verbose", "--list", "--show-current", "--merged", "--no-merged"]
            return tail.allSatisfy { listing.contains($0) || (!$0.hasPrefix("-") && options.contains("--list")) }
        case "tag":
            return tail.isEmpty || options.contains("--list") || options.contains("-l") && tail.allSatisfy { $0 != "-d" && $0 != "-f" }
        case "stash":
            return tail.first == "list" || tail.first == "show"
        case "config":
            // The reading option comes first (after scopes): `git config k v --get` is still a write of `k`.
            let scopes: Set<String> = ["--show-origin", "--local", "--global", "--system"]
            var rest = tail[...]
            while let first = rest.first, scopes.contains(first) { rest = rest.dropFirst() }
            guard let reading = rest.first else { return false }
            rest = rest.dropFirst()
            var operands = 0
            for word in rest where !scopes.contains(word) {
                if word.hasPrefix("-") { return false }
                operands += 1
            }
            switch reading {
            case "--list", "-l": return operands == 0
            case "--get", "--get-all", "--get-regexp": return (1...2).contains(operands)
            default: return false
            }
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
