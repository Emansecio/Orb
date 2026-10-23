import Foundation

/// Spots commands and writes that can destroy data or the system, so "Automático" still asks before running
/// them (and "Sempre permitir" never covers them). It reads the command words of each shell command, not any
/// text that mentions them: `grep -rn halt`, `echo 'reboot later'` and `man sudo` are fine. Deliberately
/// conservative about what it recognizes, and it never claims a command is safe.
enum DangerousCommand {
    /// Where a command runs, to tell clearing build output inside the Orb's own folder from `rm -rf` elsewhere.
    struct Scope: Sendable {
        /// The Orb's folder (never the home folder or one that contains it).
        var workspace: URL
        /// Where relative paths in the command resolve.
        var directory: URL
    }

    /// Why the shell command is dangerous, or nil if nothing recognized matches. `directory` is where the command really runs
    /// (the home folder when nil and the scope names none): relative paths resolve from it even when the Orb has no folder of its
    /// own, so `cat .aws/credentials` is seen as the secret it is while the Orb works in the home folder.
    static func reason(for command: String, in scope: Scope? = nil, directory: URL? = nil,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        check(command, scope: scope, directory: directory, home: home, depth: 0)
    }

    /// Why running this AppleScript or JavaScript for Automation is dangerous, or nil.
    /// `language` is the one the script is written in; when nil, both readings are tried and the first reason wins.
    static func reason(forAppleScript script: String, language: AppleScript.Language? = nil, in scope: Scope? = nil, directory: URL? = nil,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        checkScript(script, language: language, scope: scope, directory: directory, home: home, depth: 0)
    }

    /// Why writing to this file is dangerous (shell startup files, SSH keys, login items), or nil. Symbolic
    /// links are followed by the caller.
    static func reason(forWritingTo url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        // The Mac's usual file systems ignore case, and a file that does not exist yet keeps the case it was written
        // with: `~/.ZPROFILE` is the file zsh opens for `.zprofile`.
        let path = url.standardizedFileURL.path.lowercased()
        let homePaths = Set([home.standardizedFileURL.path, home.standardizedFileURL.resolvingSymlinksInPath().path].map { $0.lowercased() })
        for homePath in homePaths {
            for name in startupFiles where path == homePath + "/" + name {
                return "muda um arquivo que o Terminal lê ao abrir, e roda em toda sessão"
            }
            if path.hasPrefix(homePath + "/.ssh/") || path == homePath + "/.ssh" {
                return "mexe nas chaves e na configuração do SSH"
            }
            if path.hasPrefix(homePath + "/library/launchagents/") {
                return "cria ou muda um programa que abre sozinho ao entrar no Mac"
            }
        }
        for folder in ["/library/launchagents/", "/library/launchdaemons/", "/etc/", "/private/etc/"] where path.hasPrefix(folder) {
            return "muda a configuração do sistema"
        }
        return nil
    }

    /// The files that hold secrets. Compares paths as text (no file system access), so a walk over thousands of
    /// files can ask it for each one.
    struct SensitiveFiles: Sendable {
        private let homes: [String]

        init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
            homes = Array(Set([home.standardizedFileURL.path, home.standardizedFileURL.resolvingSymlinksInPath().path]))
        }

        static let message = "lê chaves, senhas ou credenciais guardadas neste Mac"

        private static let folders = [".ssh", ".gnupg", ".aws", ".kube", "library/keychains", ".config/gcloud", ".azure", ".config/op",
                                       "library/cookies"]
        private static let files = [
            ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".config/gh/hosts.yml", ".docker/config.json",
            // Shell history keeps pasted tokens and passwords.
            ".zsh_history", ".bash_history",
            // Tokens of other tools' logins and package registries.
            ".codex/auth.json", ".claude/.credentials.json", ".terraform.d/credentials.tfrc.json", ".cargo/credentials",
            ".cargo/credentials.toml", ".gem/credentials", ".m2/settings.xml", ".yarnrc.yml", ".pgpass", ".my.cnf", ".config/hub",
        ]
        /// Browser profiles hold saved passwords and session cookies, but also plenty of harmless files: only these
        /// files, wherever they sit under the profile folder.
        private static let browserData: [(folder: String, names: Set<String>)] = [
            ("library/application support/google/chrome", ["cookies", "login data", "login data for account", "web data"]),
            ("library/application support/bravesoftware/brave-browser", ["cookies", "login data", "login data for account", "web data"]),
            ("library/application support/microsoft edge", ["cookies", "login data", "login data for account", "web data"]),
            ("library/application support/arc/user data", ["cookies", "login data", "login data for account", "web data"]),
            ("library/application support/firefox/profiles", ["logins.json", "key4.db", "cookies.sqlite"]),
        ]
        /// Inside a secrets folder these are not secret.
        private static let harmless = ["known_hosts", "known_hosts.old", "config"]
        private static let secretExtensions: Set<String> = ["pem", "p12", "pfx", "key", "keychain", "keychain-db", "kdbx"]
        private static let envExamples: Set<String> = [".env.example", ".env.sample", ".env.template", ".env.dist", ".env.defaults"]

        /// `patterns`: also judge by the file's own name (`.env`, `*.pem`, `id_rsa`), which only makes sense for a file
        /// that is being opened, not for any word of a shell command.
        func reason(for path: String, patterns: Bool = true) -> String? {
            let name = (path as NSString).lastPathComponent.lowercased()
            // The Mac's usual file systems ignore case: `~/.SSH/ID_RSA` is the same file.
            for home in homes where path.hasPrefix(home + "/") {
                let relative = String(path.dropFirst(home.count + 1)).lowercased()
                if Self.files.contains(relative) { return Self.message }
                for data in Self.browserData where relative.hasPrefix(data.folder + "/") && data.names.contains(name) { return Self.message }
                for folder in Self.folders where relative == folder || relative.hasPrefix(folder + "/") {
                    // Public keys, `known_hosts` and the SSH and AWS `config` files hold no secrets.
                    if folder == ".ssh", name.hasSuffix(".pub") || Self.harmless.contains(name) { return nil }
                    if folder == ".aws", name == "config" { return nil }
                    return Self.message
                }
            }
            guard patterns else { return nil }
            if name == ".env" || (name.hasPrefix(".env.") && !Self.envExamples.contains(name)) { return Self.message }
            if let dot = name.lastIndex(of: "."), Self.secretExtensions.contains(String(name[name.index(after: dot)...])) {
                return Self.message
            }
            if ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains(name) { return Self.message }
            return nil
        }

        /// The same for one word of a shell command (`~/.ssh/id_rsa`, `$HOME/.aws/credentials`, `../.ssh/id_rsa`,
        /// `--file=~/.netrc`), resolved the way the shell would from `directory`. Nil when the word is no path to a secret
        /// or cannot be resolved.
        func reason(forShellWord word: String, directories: [URL], home: URL, patterns: Bool = false) -> String? {
            var text = word
            if text.hasPrefix("--"), let equals = text.firstIndex(of: "=") { text = String(text[text.index(after: equals)...]) }
            if text.hasPrefix("${HOME}") { text = home.path + text.dropFirst(7) }
            else if text.hasPrefix("$HOME") { text = home.path + text.dropFirst(5) }
            else if text == "~" || text.hasPrefix("~/") { text = home.path + text.dropFirst(1) }
            guard !text.isEmpty, !text.contains("$") else { return nil }
            // A relative word means a different file in each folder the shell might be in.
            let urls = text.hasPrefix("/") ? [URL(fileURLWithPath: text)] : directories.map { $0.appending(path: text) }
            for url in urls {
                if let reason = reason(for: url.standardizedFileURL.path, patterns: patterns) { return reason }
                // A link to a secret is the secret.
                if let reason = reason(for: PermissionPolicy.resolved(url).path, patterns: patterns) { return reason }
            }
            return nil
        }
    }

    /// The folders `cd target` may leave the shell in, given where it may be before: `target` from each of them (a `cd`
    /// that fails leaves it where it was, so the caller keeps the old ones too). Nil for a target that cannot be told
    /// from the text (`cd -`, `cd $DIR`, `cd ~user`).
    static func directory(afterCD target: String, from directories: [URL], home: URL) -> [URL]? {
        guard !target.contains("$"), !target.contains("`"), target != "-", !(target.hasPrefix("~") && target != "~" && !target.hasPrefix("~/")) else {
            return nil
        }
        let expanded = target.hasPrefix("~") ? home.path + target.dropFirst() : target
        if expanded.hasPrefix("/") { return [URL(fileURLWithPath: expanded).standardizedFileURL] }
        return directories.map { $0.appending(path: expanded).standardizedFileURL }
    }

    private static let startupFiles = [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bash_profile", ".bashrc", ".bash_login", ".profile"]

    // MARK: Shell

    private static let maxDepth = 4
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
    private static let downloaders: Set<String> = ["curl", "wget"]
    private static let benignBuildFolders: Set<String> = ["node_modules", ".build", "dist", "deriveddata"]
    private static let rootLike: Set<String> = ["/", "/*", "~", "~/", "~/*", "$HOME", "$HOME/", "${HOME}", "${HOME}/", "$HOME/*"]
    private static let systemFolders: Set<String> = [
        "/users", "/system", "/library", "/usr", "/etc", "/var", "/bin", "/sbin", "/private", "/applications", "/opt",
    ]

    /// Where the shell may be as a line goes on: the folder it started in and, after each `cd`, the folders that `cd` could
    /// have led to (one that fails leaves it where it was, so the old ones stay). `known` turns false after a `cd` whose
    /// target cannot be told from the text (`cd $DIR`, `cd -`), and relative words then stand for any folder at all.
    private struct Place {
        var directories: [URL]
        var known = true

        /// Always starts in the folder the command really runs in: the scope's (the Orb's own folder) tunes only how
        /// tolerant `rm` is of build output, never whether relative paths to secrets resolve.
        init(_ scope: Scope?, directory: URL?, home: URL) {
            directories = [(scope?.directory ?? directory ?? home).standardizedFileURL]
        }

        /// A line of `cd x && cd ..` pairs would double the list at every step, so repeats are dropped and the list stops
        /// at `maxDirectories`; past it, relative words stand for any folder (`known` turns false), the safe side.
        static let maxDirectories = 32

        private mutating func add(_ more: [URL]) {
            var seen = Set(directories)
            for url in more where seen.insert(url).inserted {
                if directories.count >= Self.maxDirectories { known = false; return }
                directories.append(url)
            }
        }

        mutating func move(_ command: (name: String, arguments: [String]), home: URL) {
            switch command.name {
            case "cd", "chdir", "pushd":
                // Without a target `cd` goes home; `-P`, `-L` and `--` only change how the path is followed.
                let words = command.arguments.drop { $0.hasPrefix("-") && $0 != "-" }
                if let target = words.first {
                    if let moved = directory(afterCD: target, from: directories, home: home) { add(moved) } else { known = false }
                } else {
                    add([home.standardizedFileURL])
                }
            case "popd":
                known = false
            default:
                break
            }
        }
    }

    private static func check(_ command: String, scope: Scope?, directory: URL?, home: URL, depth: Int, place start: Place? = nil) -> String? {
        guard depth < maxDepth else { return "usa comandos aninhados demais para conferir" }
        if command.range(of: #":\(\)\s*\{\s*:\|:&\s*\};:"#, options: .regularExpression) != nil { return "trava o sistema (fork bomb)" }
        if command.range(of: #">\s*/dev/(r?disk|sd)\w*"#, options: .regularExpression) != nil { return "grava direto num disco" }

        let line = ShellCommandLine.parse(command)
        var place = start ?? Place(scope, directory: directory, home: home)
        var downloadInChain = false
        for segment in line.segments {
            if segment.separator != .pipe { downloadInChain = false }
            // A word like `()` makes the line read as a function definition too; the line as written still runs, so both count.
            let commands = readings(of: segment.words)
            if let reason = unverifiable(segment.words, commands) { return reason }
            if segment.separator == .pipe, downloadInChain, commands.contains(where: { shells.contains($0.name) }) {
                return "baixa e executa um script da internet"
            }
            if commands.contains(where: { downloaders.contains($0.name) }) { downloadInChain = true }
            if let reason = checkWords(segment.words, scope: scope, home: home, depth: depth, place: place, viaXargs: false) { return reason }
            for command in commands where !namesOnly.contains(command.name) {
                if let reason = secretReason(in: command.arguments, directories: place.directories, home: home) { return reason }
            }
            for command in commands { place.move(command, home: home) }
        }
        // A `$( )` runs where the shell is by then, after the `cd` of an earlier segment: `place` now holds every folder it may be in.
        for body in line.substitutions {
            if let reason = check(body, scope: scope, directory: directory, home: home, depth: depth + 1, place: place) { return reason }
        }
        return nil
    }

    /// Commands that only touch names, sizes and dates, so pointing them at `~/.ssh` shows no secret.
    private static let namesOnly: Set<String> = [
        "ls", "stat", "file", "du", "df", "wc", "find", "cd", "pwd", "mdfind", "mdls", "basename", "dirname", "realpath",
        "readlink", "which", "mkdir", "chmod", "chown", "touch", "test", "[",
    ]

    /// Any word of the command that is a path to a private key, saved password or token: what it prints or copies
    /// reaches the model whatever the command is.
    private static func secretReason(in words: [String], directories: [URL], home: URL) -> String? {
        let sensitive = SensitiveFiles(home: home)
        for word in words where !word.hasPrefix("-") || (word.hasPrefix("--") && word.contains("=")) {
            if let reason = sensitive.reason(forShellWord: word, directories: directories, home: home) { return reason }
        }
        return nil
    }

    private static func checkWords(_ words: [String], scope: Scope?, home: URL, depth: Int, place: Place, viaXargs: Bool) -> String? {
        for command in readings(of: words) {
            if let reason = checkCommand(command, scope: scope, home: home, depth: depth, place: place, viaXargs: viaXargs) { return reason }
        }
        return nil
    }

    private static func checkCommand(_ command: (name: String, arguments: [String]), scope: Scope?, home: URL, depth: Int, place: Place,
                                     viaXargs: Bool) -> String? {
        if command.name == tooManyPrefixes { return "usa prefixos demais para conferir o comando" }
        let args = Arguments(command.arguments)
        switch command.name {
        case "sudo", "doas":
            return "roda como administrador"
        case "rm", "unlink":
            if viaXargs { return "apaga vários arquivos de uma vez (xargs rm)" }
            // A lone `-f` only silences "no such file": it follows the rule of the plain `rm` below.
            if command.name == "rm", args.hasShort("rR") || args.hasLongAbbreviation("--recursive") {
                if let scope, isBuildOutput(args.operands, in: scope, place: place) { return nil }
                return "apaga arquivos de forma recursiva ou forçada"
            }
            // A plain `rm file` skips the Trash too: fine for what the Orb made in its own folder or in a temporary
            // one, a loss with no way back anywhere else.
            guard !args.operands.isEmpty, !args.operands.allSatisfy({ isDisposable($0, scope: scope, place: place, home: home) }) else { return nil }
            return "apaga arquivos de forma definitiva (sem passar pela Lixeira) fora da pasta do Orb"
        case "find":
            if command.arguments.contains("-delete") { return "apaga os arquivos encontrados" }
            // Every `-exec` runs its own command (`-exec echo {} \; -exec rm {} \;`), not only the first.
            for exec in command.arguments.indices where ["-exec", "-execdir", "-ok", "-okdir"].contains(command.arguments[exec]) {
                let inner = command.arguments[(exec + 1)...].prefix { $0 != ";" && $0 != "+" }
                if let reason = checkWords(Array(inner), scope: scope, home: home, depth: depth, place: place, viaXargs: true) { return reason }
            }
            return nil
        case "xargs":
            guard let inner = xargsCommand(command.arguments) else { return nil }
            return checkWords(inner, scope: scope, home: home, depth: depth, place: place, viaXargs: true)
        case "git":
            return gitReason(command.arguments)
        case "rsync":
            guard args.hasLongPrefix("--delete") || args.hasLong(["--del"]), let destination = args.operands.last,
                  isHomeOrRoot(destination, home: home) else { return nil }
            return "apaga no destino tudo que não está na origem, e o destino é a pasta pessoal ou a raiz"
        case "chmod", "chown", "chgrp":
            guard args.hasShort("R") || args.hasLong(["--recursive"]),
                  args.operands.contains(where: { isHomeOrRoot($0, home: home) || systemFolders.contains($0.lowercased()) }) else { return nil }
            return "muda permissões de tudo a partir da raiz ou da pasta pessoal"
        case "dd":
            return command.arguments.contains { $0.hasPrefix("of=/dev/") } ? "grava direto num disco" : nil
        case "diskutil":
            let verbs = command.arguments.filter { !$0.hasPrefix("-") }.map { $0.lowercased() }
            let sub = verbs.first ?? ""
            // `diskutil apfs deleteVolume|deleteContainer|eraseVolume` and `diskutil coreStorage delete` destroy volumes too.
            if sub == "apfs" || sub == "corestorage", let verb = verbs.dropFirst().first,
               verb.hasPrefix("delete") || verb.hasPrefix("erase") { return "formata ou apaga um disco" }
            return sub.hasPrefix("erase") || ["partitiondisk", "zerodisk", "secureerase", "reformat"].contains(sub)
                ? "formata ou apaga um disco" : nil
        case "shutdown", "reboot", "halt", "poweroff":
            return "desliga ou reinicia o Mac"
        case "killall", "pkill":
            return "encerra processos em massa"
        case "launchctl":
            let sub = command.arguments.first(where: { !$0.hasPrefix("-") }) ?? ""
            return ["unload", "bootout", "remove"].contains(sub) ? "desativa serviços do sistema" : nil
        case "csrutil":
            return "mexe na proteção do sistema"
        case "spctl":
            return command.arguments.contains("--master-disable") ? "mexe na proteção do sistema" : nil
        case "osascript":
            let language = osascriptLanguage(command.arguments)
            // The script is what follows `-e`, which may well begin with `--` (a comment); other words are script files.
            var afterScriptFlag = false, skipNext = false
            for word in command.arguments {
                defer { if word != "-e" { afterScriptFlag = false } }
                if skipNext { skipNext = false; continue }
                if word == "-e" { afterScriptFlag = true; continue }
                if word == "-l" || word == "-s" { skipNext = true; continue }
                guard afterScriptFlag || !word.hasPrefix("-") || word.contains(where: \.isWhitespace) else { continue }
                if let reason = checkScript(word, language: language, scope: scope, directory: place.directories.first, home: home, depth: depth + 1) { return reason }
            }
            return nil
        case "eval":
            return evalReason(command.arguments, scope: scope, home: home, depth: depth, place: place)
        case "source", ".":
            return command.arguments.contains(where: downloadsCode) ? "baixa e executa um script da internet" : nil
        case let name where shells.contains(name):
            return shellReason(command.arguments, scope: scope, home: home, depth: depth, place: place)
        case let name where name == "mkfs" || name.hasPrefix("mkfs.") || name.hasPrefix("newfs"):
            return "formata ou apaga um disco"
        default:
            return nil
        }
    }

    // MARK: Command words

    /// Programs that only run another command given in their arguments. The detector looks through them, and
    /// `PermissionPolicy` never offers a standing rule for one (it would cover whatever they wrap).
    static let wrappers: Set<String> = [
        "env", "nohup", "command", "exec", "builtin", "time", "nice", "caffeinate", "stdbuf", "ionice",
        // zsh's precommand modifiers (`noglob rm -rf *`, `- rm`), `arch -arm64 cmd`, `xcrun cmd` and `timeout 5 cmd`
        "noglob", "nocorrect", "-", "arch", "xcrun", "timeout", "gtimeout",
    ]
    private static let keywords: Set<String> = ["if", "then", "else", "elif", "do", "while", "until", "!", "{", "(", "}", ")"]
    /// Options of each wrapper that take a value as the next word. Anything else starting with `-` is a flag
    /// (`env -i`, `caffeinate -i`), so the word after it is still the command.
    private static let wrapperValueOptions: [String: Set<String>] = [
        "env": ["-u", "-C", "-P"], "stdbuf": ["-i", "-o", "-e"], "nice": ["-n"], "caffeinate": ["-t"],
        "exec": ["-a"], "ionice": ["-c", "-n", "-p"], "arch": ["-arch", "-e"], "xcrun": ["-sdk", "--sdk", "-toolchain", "--toolchain"],
        "timeout": ["-s", "-k", "--signal", "--kill-after"], "gtimeout": ["-s", "-k", "--signal", "--kill-after"],
    ]
    /// Plain words a wrapper takes before the command (the duration of `timeout 5 cmd`).
    private static let wrapperOperands: [String: Int] = ["timeout": 1, "gtimeout": 1]

    /// The commands a list of words may run: what it says read as a command, and, when it could also be a function
    /// definition, what its body runs. Both are judged, since a word such as `()` is not enough to tell them apart
    /// (`rm '()' ~/Documents/x` is an `rm`).
    private static func readings(of words: [String]) -> [(name: String, arguments: [String])] {
        var result: [(name: String, arguments: [String])] = []
        for definition in [false, true] {
            guard let command = effective(words, definition: definition),
                  !result.contains(where: { $0.name == command.name && $0.arguments == command.arguments }) else { continue }
            result.append(command)
        }
        return result
    }

    /// The command a list of words runs, after environment assignments and wrappers (`FOO=1 nohup rm …`). With
    /// `definition`, a function definition is skipped to reach its body.
    private static func effective(_ words: [String], definition: Bool = false) -> (name: String, arguments: [String])? {
        var rest = words[...]
        // Every assignment, keyword and wrapper takes a turn, so the allowance follows the length of the line.
        for _ in 0..<(words.count + 12) {
            guard let first = rest.first else { return nil }
            let word = first.trimmingCharacters(in: CharacterSet(charactersIn: "({"))
            if word.isEmpty || keywords.contains(word) || isAssignment(word) {
                rest = rest.dropFirst()
                continue
            }
            // A function definition (`f(){ rm -rf x; }`, `f () {`, `function f {`) runs its body only when called, but
            // the body is what the line is about: skip the name and look at what follows.
            if definition, word.hasSuffix("()") || word == "function" || rest.dropFirst().first?.hasPrefix("()") == true {
                rest = rest.dropFirst(word == "function" || !word.hasSuffix("()") ? 2 : 1)
                continue
            }
            // NSString, not URL: on old-SDK binaries URL(fileURLWithPath:) traps on an unparsable "http:" word.
            let name = word.contains("/") ? (word as NSString).lastPathComponent : word
            guard wrappers.contains(name) else { return (name, Array(rest.dropFirst())) }
            rest = rest.dropFirst()
            if name == "command", rest.first.map({ $0 == "-v" || $0 == "-V" }) == true { return nil }
            let valueOptions = wrapperValueOptions[name] ?? []
            while let option = rest.first, option.hasPrefix("-") && option != "-" || isAssignment(option) {
                // `env -S 'rm -rf x'` (also `-iS`, `-Sx`, `--split-string=x`) splits its value into the command to run.
                if name == "env", let split = splitString(option, next: rest.dropFirst().first) {
                    rest = split.consumed == 2 ? rest.dropFirst(2) : rest.dropFirst()
                    rest = split.words[...] + rest
                    break
                }
                rest = rest.dropFirst(valueOptions.contains(option) ? 2 : 1)
            }
            rest = rest.dropFirst(wrapperOperands[name] ?? 0)
        }
        // Words are left and the turns ran out: a command the detector never read must not pass as safe.
        return rest.isEmpty ? nil : (tooManyPrefixes, [])
    }

    /// Stands for a line with more prefixes than `effective` can unwrap; `checkCommand` turns it into a reason.
    private static let tooManyPrefixes = "\u{0}too-many-prefixes"

    /// The command words in an `env` option that carries them (`-S`), and how many words the option used.
    private static func splitString(_ option: String, next: String?) -> (words: [String], consumed: Int)? {
        // The value is split the way a shell does (quotes group words): `sh -c "rm -rf x"` is three words.
        splitStringValue(option, next: next).map { (ShellCommandLine.parse($0.value).segments.flatMap(\.words), $0.consumed) }
    }

    /// The raw value of an `env` option that carries a command line (`-S`, `-iS`, `-Sx`, `--split-string=x`).
    private static func splitStringValue(_ option: String, next: String?) -> (value: String, consumed: Int)? {
        if option.hasPrefix("--") {
            if option == "--split-string" { return next.map { ($0, 2) } }
            return option.hasPrefix("--split-string=") ? (String(option.dropFirst("--split-string=".count)), 1) : nil
        }
        // In a group of letters the `S` takes the rest of the word, or the next word; `u`, `C` and `P` take a value first.
        guard let index = option.dropFirst().firstIndex(where: { "SuCP".contains($0) }), option[index] == "S" else { return nil }
        let attached = String(option[option.index(after: index)...])
        return attached.isEmpty ? next.map { ($0, 2) } : (attached, 1)
    }

    /// Lines whose command the detector cannot read, so they count as dangerous: `env -S` has its own escapes and
    /// expansions (`rm\_-rf\_x`, `${SHELL} -c …`), and a shell named by a variable (`$SHELL -c 'rm -rf x'`) runs a
    /// command line it cannot see.
    private static func unverifiable(_ words: [String], _ commands: [(name: String, arguments: [String])]) -> String? {
        for (index, word) in words.enumerated() where (word as NSString).lastPathComponent == "env" {
            for (offset, option) in words.dropFirst(index + 1).enumerated() {
                guard option.hasPrefix("-"), option != "-" else { break }
                let next = words.dropFirst(index + 2 + offset).first
                if let value = splitStringValue(option, next: next)?.value, value.contains("\\") || value.contains("$") {
                    return "monta o comando com env -S de um jeito que não dá para conferir"
                }
            }
        }
        let runsALine = { (arguments: [String]) in arguments.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") } }
        if commands.contains(where: { $0.name.hasPrefix("$") && runsALine($0.arguments) }) {
            return "roda um shell que vem de uma variável, sem dar para conferir o comando"
        }
        return nil
    }

    private static func isAssignment(_ word: String) -> Bool {
        word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
    }

    private static func xargsCommand(_ arguments: [String]) -> [String]? {
        var rest = arguments[...]
        while let option = rest.first, option.hasPrefix("-") {
            let takesValue = ["-I", "-n", "-P", "-L", "-d", "-s", "-E", "-J", "-R", "-S"].contains(option)
            rest = rest.dropFirst(takesValue ? 2 : 1)
        }
        return rest.isEmpty ? nil : Array(rest)
    }

    /// The options and operands of one command, for `rm -v -rf x` or `rm --recursive --force x`.
    private struct Arguments {
        let words: [String]

        init(_ words: [String]) { self.words = words }

        private var options: [String] {
            Array(words.prefix { $0 != "--" }.filter { $0.hasPrefix("-") && $0.count > 1 })
        }

        /// Any short option cluster (`-rf`, `-v`) containing one of `letters`.
        func hasShort(_ letters: String) -> Bool {
            options.contains { !$0.hasPrefix("--") && $0.dropFirst().contains { letters.contains($0) } }
        }

        func hasLong(_ names: [String]) -> Bool {
            options.contains { option in names.contains { option == $0 || option.hasPrefix($0 + "=") } }
        }

        func hasLongPrefix(_ prefix: String) -> Bool { options.contains { $0.hasPrefix(prefix) } }

        /// A long option under any unambiguous shorter spelling (`--recur`), as GNU tools accept.
        func hasLongAbbreviation(_ name: String) -> Bool { options.contains { ReadOnlyCommand.abbreviates($0, anyOf: [name]) } }

        var operands: [String] {
            var result: [String] = []
            var literal = false
            for word in words {
                if !literal, word == "--" { literal = true; continue }
                if literal || !word.hasPrefix("-") || word.count == 1 { result.append(word) }
            }
            return result
        }
    }

    // MARK: Specific commands

    private static let gitProgramReason = "roda um programa definido na linha de comando do git"
    private static let programSettingNames: Set<String> = [
        "textconv", "command", "external", "program", "helper", "hookspath", "sshcommand", "askpass", "editor", "pager",
        "alternaterefscommand", "packobjectshook", "fsmonitor", "cmd",
    ]
    private static let programSettingSuffixes = ["command", "program", "helper", "editor", "pager", "hook", "hookspath"]

    /// Whether `name=value` (a `git -c` argument) or `name=ENVVAR` (`--config-env`, where the value cannot be seen) is a
    /// setting that makes git start a program: aliases that begin with `!`, pagers, editors, filters, drivers, helpers,
    /// hooks, `ssh` and `gpg` commands. Names are compared without regard to case.
    /// - Parameter runsProgramFromValue: true for `-c`, where the value is the text itself; false for `--config-env`, where
    ///   it names a variable, so only the name can be judged (and every alias counts).
    private static func configSetting(_ setting: String, runsProgramFromValue: Bool) -> Bool {
        let name = String(setting.prefix { $0 != "=" }).lowercased()
        let value: String? = setting.contains("=") ? String(setting.drop { $0 != "=" }.dropFirst()) : nil
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let section = parts.first, let last = parts.last, parts.count >= 2 else { return false }
        if section == "alias" { return !runsProgramFromValue || value?.hasPrefix("!") == true }
        if section == "color" { return false }
        if section == "pager" { return true }
        if section == "filter", ["clean", "smudge", "process"].contains(last) { return true }
        if section == "merge", last == "driver" { return true }
        if section == "protocol", last == "allow" { return true }
        if section == "core", last == "fsmonitor", runsProgramFromValue, let value {
            // A switch for the built-in monitor is not a program.
            return !["true", "false", "yes", "no", "on", "off", "1", "0", ""].contains(value.lowercased())
        }
        return programSettingNames.contains(last) || programSettingSuffixes.contains { last.hasSuffix($0) }
    }

    private static func gitReason(_ arguments: [String]) -> String? {
        // Skip options before the subcommand (`git -C dir -c k=v push`), but a setting that makes git run a program
        // (`-c alias.x='!rm -rf ~/x' x`, `-c core.pager=…`, `--exec-path=…`) is a command in disguise.
        var rest = arguments[...]
        while let first = rest.first, first.hasPrefix("-") {
            let value = rest.dropFirst().first
            if first == "-c", let value, configSetting(value, runsProgramFromValue: true) { return gitProgramReason }
            if first == "--config-env", let value, configSetting(value, runsProgramFromValue: false) { return gitProgramReason }
            if first.hasPrefix("--config-env="), configSetting(String(first.dropFirst("--config-env=".count)), runsProgramFromValue: false) {
                return gitProgramReason
            }
            if first.hasPrefix("--exec-path=") { return gitProgramReason }
            rest = rest.dropFirst(["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix", "--attr-source"].contains(first) ? 2 : 1)
        }
        guard let sub = rest.first else { return nil }
        let args = Arguments(Array(rest.dropFirst()))
        switch sub {
        case "push":
            if args.hasShort("f") || args.hasLongPrefix("--force") || args.hasLong(["--mirror"]) || args.operands.contains(where: { $0.hasPrefix("+") }) {
                return "sobrescreve o histórico remoto do git"
            }
        case "reset":
            if args.hasLong(["--hard"]) { return "descarta mudanças do git" }
        case "clean":
            if args.hasShort("f") || args.hasLong(["--force"]), !args.hasShort("n"), !args.hasLong(["--dry-run"]) {
                return "apaga arquivos não versionados"
            }
        case "checkout":
            if args.operands.contains(".") || args.hasShort("f") || args.hasLong(["--force"]) { return "descarta mudanças do git" }
        case "restore":
            let stagedOnly = args.hasLong(["--staged"]) && !args.hasLong(["--worktree"]) && !args.hasShort("W")
            if args.operands.contains("."), !stagedOnly { return "descarta mudanças do git" }
        case "branch":
            if args.hasShort("D") { return "apaga um branch mesmo sem ele ter sido mesclado" }
        default:
            break
        }
        return nil
    }

    /// The language `osascript` is told to use (`-l JavaScript`); AppleScript without `-l`, nil when it cannot be told.
    private static func osascriptLanguage(_ arguments: [String]) -> AppleScript.Language? {
        var value: String?
        for (i, word) in arguments.enumerated() {
            if word == "-l", i + 1 < arguments.count { value = arguments[i + 1] }
            else if word.hasPrefix("-l"), word.count > 2, !word.hasPrefix("--") { value = String(word.dropFirst(2)) }
        }
        guard let value else { return .applescript }
        switch value.lowercased() {
        case "javascript": return .javascript
        case "applescript": return .applescript
        default: return nil
        }
    }

    private static func shellReason(_ arguments: [String], scope: Scope?, home: URL, depth: Int, place: Place) -> String? {
        if arguments.contains(where: downloadsCode) { return "baixa e executa um script da internet" }
        // `sh -c 'script'`, also `-lc` and `-ic`: the script is a command line of its own.
        guard let flag = arguments.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }),
              flag + 1 < arguments.count else { return nil }
        return check(arguments[flag + 1], scope: scope, directory: nil, home: home, depth: depth + 1, place: place)
    }

    private static func evalReason(_ arguments: [String], scope: Scope?, home: URL, depth: Int, place: Place) -> String? {
        if arguments.contains(where: downloadsCode) { return "baixa e executa um script da internet" }
        return check(arguments.joined(separator: " "), scope: scope, directory: nil, home: home, depth: depth + 1, place: place)
    }

    /// `$(curl …)`, `<(curl …)` or backticks around a download: the output runs as code.
    private static func downloadsCode(_ word: String) -> Bool {
        guard word.hasPrefix("$(") || word.hasPrefix("<(") || word.hasPrefix("`") else { return false }
        return ShellCommandLine.parse(word).substitutions.contains { body in
            ShellCommandLine.parse(body).segments.contains { segment in
                readings(of: segment.words).contains { downloaders.contains($0.name) }
            }
        }
    }

    private static func isHomeOrRoot(_ operand: String, home: URL) -> Bool {
        if rootLike.contains(operand) { return true }
        var trimmed = operand
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        let homePaths = [home.standardizedFileURL.path, home.standardizedFileURL.resolvingSymlinksInPath().path]
        return homePaths.contains(trimmed) || homePaths.contains { $0 + "/*" == trimmed }
    }

    /// Temporary folders, where the Orb's scratch files live.
    private static let temporaryFolders = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]

    /// Whether deleting this operand loses nothing that belongs to the user: it is inside the Orb's own folder or in a
    /// temporary one. Anything that cannot be told from the text (`$VAR`, `$(…)`, `~user`) counts as not.
    private static func isDisposable(_ operand: String, scope: Scope?, place: Place, home: URL) -> Bool {
        guard !operand.contains(where: { "$`".contains($0) }), !operand.hasPrefix("~") || operand == "~" || operand.hasPrefix("~/") else {
            return false
        }
        let expanded = operand.hasPrefix("~") ? home.path + operand.dropFirst() : operand
        // A relative operand names a different file in each folder the shell may be in (after `cd ~/Documents && rm x`).
        let urls: [URL]
        if expanded.hasPrefix("/") {
            urls = [URL(fileURLWithPath: expanded)]
        } else if scope != nil, place.known {
            urls = place.directories.map { $0.appending(path: expanded) }
        } else {
            return false
        }
        return urls.allSatisfy { url in
            // A link in the way (`ws/escape -> ~/Documents`) must not make the outside look inside.
            let path = PermissionPolicy.resolved(url.standardizedFileURL).path
            if let scope {
                let workspace = PermissionPolicy.resolved(scope.workspace).path
                if path.hasPrefix(workspace + "/") { return true }
            }
            return temporaryFolders.contains { path.hasPrefix($0 + "/") }
        }
    }

    /// `rm -rf node_modules dist` inside the Orb's folder only clears what a build recreates.
    private static func isBuildOutput(_ operands: [String], in scope: Scope, place: Place) -> Bool {
        guard !operands.isEmpty else { return false }
        let workspace = scope.workspace.standardizedFileURL.resolvingSymlinksInPath().path
        return operands.allSatisfy { operand in
            guard !operand.contains(where: { "*?[]{}$~`".contains($0) }) else { return false }
            let urls: [URL]
            if operand.hasPrefix("/") { urls = [URL(fileURLWithPath: operand)] }
            else if place.known { urls = place.directories.map { $0.appending(path: operand) } }
            else { return false }
            return urls.allSatisfy { url in
                let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
                return benignBuildFolders.contains(resolved.lastPathComponent.lowercased()) && resolved.path.hasPrefix(workspace + "/")
            }
        }
    }

    // MARK: AppleScript

    private static let scriptRules: [(pattern: String, reason: String)] = [
        (#"\bempty\s+(the\s+)?trash\b|\bemptyTrash\b"#, "esvazia a Lixeira"),
        (#"\bdelete\s*\(?\s*(every|all)\b"#, "apaga tudo de uma vez"),
        // `delete notes of folder "X"`, `delete (messages of inbox …)`: a plural noun, then the container it comes from.
        (#"\bdelete\s*\(?\s*(?:the\s+)?\w+s\s+(?:of|in)\b"#, "apaga vários itens de uma vez"),
        (#"\bshut\s+down\b|\bshutDown\b"#, "desliga o Mac"),
        (#"\brestart\b"#, "reinicia o Mac"),
        (#"\blog\s*out\b|\blogOut\b"#, "encerra a sessão do usuário"),
        (#"\bwith\s+administrator\s+privileges\b"#, "roda como administrador"),
    ]

    /// `scriptRules` compiled once.
    private static let compiledScriptRules: [(regex: NSRegularExpression, reason: String)] = scriptRules.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])).map { ($0, rule.reason) }
    }

    /// Apps whose scripted `send` (or Return in their window) delivers something to other people and cannot be taken back.
    /// Matched against the whole text of a string literal (a name or a bundle id), so a longer sentence that mentions
    /// an app does not count.
    private static let messagingApps = #"^(?:mail|messages|mensagens|(?:microsoft )?outlook|whatsapp|telegram|slack|signal|discord|microsoft teams|com\.apple\.mail|com\.apple\.MobileSMS|com\.microsoft\.Outlook|net\.whatsapp\.WhatsApp|ru\.keepcoder\.Telegram|com\.tinyspeck\.slackmacgap)(?:\.app)?$"#

    /// A script split into what runs and what is only text: `code` has its comments removed and every string literal
    /// blanked to `""`; `strings` are the literals, unescaped, in order.
    private struct ScriptText {
        var code = ""
        var strings: [String] = []
    }

    /// Reads the script the way its language does. AppleScript has `"…"` strings and `--`, `#` and `(* *)` comments, so an
    /// apostrophe in it is just a character; JavaScript for Automation has `"…"`, `'…'` and `` `…` `` strings and `//` and
    /// `/* */` comments. Guessing the language from the text is not safe: a stray `app.` in a comment would flip it and
    /// an apostrophe could then hide the code that follows.
    private static func scan(_ script: String, javaScript: Bool) -> ScriptText {
        var result = ScriptText()
        let chars = Array(script)
        let quotes: Set<Character> = javaScript ? ["\"", "'", "`"] : ["\""]
        var index = 0
        while index < chars.count {
            let c = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            if quotes.contains(c) {
                var literal = ""
                index += 1
                while index < chars.count, chars[index] != c {
                    if chars[index] == "\\", index + 1 < chars.count {
                        let escaped = chars[index + 1]
                        if escaped == c || escaped == "\\" { literal.append(escaped) } else { literal.append("\\"); literal.append(escaped) }
                        index += 2
                    } else {
                        literal.append(chars[index])
                        index += 1
                    }
                }
                index += 1 // the closing quote (an unterminated string still counts as one)
                result.strings.append(literal)
                result.code += "\"\""
            } else if let opener = commentOpener(c, next, javaScript: javaScript) {
                if opener.block {
                    var depth = 1
                    index += 2
                    while index < chars.count, depth > 0 {
                        let a = chars[index], b: Character? = index + 1 < chars.count ? chars[index + 1] : nil
                        if !javaScript, a == "(", b == "*" { depth += 1; index += 2 }
                        else if a == opener.close.0, b == opener.close.1 { depth -= 1; index += 2 }
                        else { index += 1 }
                    }
                    result.code += " "
                } else {
                    while index < chars.count, chars[index] != "\n" { index += 1 }
                }
            } else {
                result.code.append(c)
                index += 1
            }
        }
        return result
    }

    private static func commentOpener(_ c: Character, _ next: Character?, javaScript: Bool) -> (block: Bool, close: (Character, Character))? {
        if javaScript {
            if c == "/", next == "/" { return (false, ("\n", "\n")) }
            if c == "/", next == "*" { return (true, ("*", "/")) }
        } else {
            if c == "(", next == "*" { return (true, ("*", ")")) }
            if c == "-", next == "-" { return (false, ("\n", "\n")) }
            if c == "#" { return (false, ("\n", "\n")) }
        }
        return nil
    }

    /// With the language known the script is read as that language; when it is not, as both, and the first reason wins.
    private static func checkScript(_ script: String, language: AppleScript.Language?, scope: Scope?, directory: URL?, home: URL, depth: Int) -> String? {
        guard let language else {
            return checkScript(script, javaScript: false, scope: scope, directory: directory, home: home, depth: depth)
                ?? checkScript(script, javaScript: true, scope: scope, directory: directory, home: home, depth: depth)
        }
        return checkScript(script, javaScript: language == .javascript, scope: scope, directory: directory, home: home, depth: depth)
    }

    private static func checkScript(_ script: String, javaScript: Bool, scope: Scope?, directory: URL?, home: URL, depth: Int) -> String? {
        guard depth < maxDepth else { return "usa scripts aninhados demais para conferir" }
        let text = scan(script, javaScript: javaScript)
        // `do shell script "…"` (and JXA's `doShellScript('…')`) runs shell text.
        let shellText = #"(?:do\s+shell\s+script|doShellScript\s*\()\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|`((?:[^`\\]|\\.)*)`)"#
        if let regex = try? NSRegularExpression(pattern: shellText, options: [.caseInsensitive]) {
            let range = NSRange(script.startIndex..., in: script)
            for match in regex.matches(in: script, range: range) {
                for group in 1...3 {
                    guard let r = Range(match.range(at: group), in: script) else { continue }
                    let inner = script[r].replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                    if let reason = check(inner, scope: scope, directory: directory, home: home, depth: depth + 1) { return reason }
                }
            }
        }
        // The words of the script itself, not text inside its strings or comments (`display dialog "restart later"`).
        let code = text.code
        // Shell text built from a variable or pieces (`do shell script c`, `("rm -rf " & "~")`) cannot be read as one
        // literal: judge the script's strings together and one by one.
        if code.range(of: #"(?:do\s+shell\s+script|doShellScript\s*\()\s*[^"\s]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            for piece in [text.strings.joined()] + text.strings {
                if let reason = check(piece, scope: scope, directory: directory, home: home, depth: depth + 1) { return "monta um comando de shell que \(reason)" }
            }
        }
        let codeRange = NSRange(code.startIndex..., in: code)
        for rule in compiledScriptRules where rule.regex.firstMatch(in: code, range: codeRange) != nil {
            return rule.reason
        }
        // Filtering with `whose` and then deleting removes everything that matches.
        if code.range(of: #"\bwhose\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
           code.range(of: #"\bdelete\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "apaga vários itens de uma vez"
        }
        let messaging = text.strings.contains { $0.range(of: messagingApps, options: [.regularExpression, .caseInsensitive]) != nil }
        if code.range(of: #"\.send\s*\("#, options: .regularExpression) != nil
            || (messaging && code.range(of: #"\bsend\b"#, options: [.regularExpression, .caseInsensitive]) != nil) {
            return "envia um e-mail ou mensagem, que não dá para desfazer"
        }
        // Return in the window of a chat app sends what is typed there.
        if messaging, code.range(of: #"\bkeystroke\s+(?:return|enter)\b|\bkey\s+code\s+(?:36|76)\b|\bASCII\s+character\s+(?:10|13)\b"#,
                                 options: [.regularExpression, .caseInsensitive]) != nil {
            return "envia uma mensagem (tecla Return)"
        }
        return nil
    }
}
