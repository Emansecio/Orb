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

    /// Why the shell command is dangerous, or nil if nothing recognized matches.
    static func reason(for command: String, in scope: Scope? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        check(command, scope: scope, home: home, depth: 0)
    }

    /// Why running this AppleScript or JavaScript for Automation is dangerous, or nil.
    static func reason(forAppleScript script: String, in scope: Scope? = nil,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        checkScript(script, scope: scope, home: home, depth: 0)
    }

    /// Why writing to this file is dangerous (shell startup files, SSH keys, login items), or nil. Symbolic
    /// links are followed by the caller.
    static func reason(forWritingTo url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = url.standardizedFileURL.path
        let homePaths = Set([home.standardizedFileURL.path, home.standardizedFileURL.resolvingSymlinksInPath().path])
        for homePath in homePaths {
            for name in startupFiles where path == homePath + "/" + name {
                return "muda um arquivo que o Terminal lê ao abrir, e roda em toda sessão"
            }
            if path.hasPrefix(homePath + "/.ssh/") || path == homePath + "/.ssh" {
                return "mexe nas chaves e na configuração do SSH"
            }
            if path.hasPrefix(homePath + "/Library/LaunchAgents/") {
                return "cria ou muda um programa que abre sozinho ao entrar no Mac"
            }
        }
        for folder in ["/Library/LaunchAgents/", "/Library/LaunchDaemons/", "/etc/"] where path.hasPrefix(folder) {
            return "muda a configuração do sistema"
        }
        return nil
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

    private static func check(_ command: String, scope: Scope?, home: URL, depth: Int) -> String? {
        guard depth < maxDepth else { return "usa comandos aninhados demais para conferir" }
        if command.range(of: #":\(\)\s*\{\s*:\|:&\s*\};:"#, options: .regularExpression) != nil { return "trava o sistema (fork bomb)" }
        if command.range(of: #">\s*/dev/(r?disk|sd)\w*"#, options: .regularExpression) != nil { return "grava direto num disco" }

        let line = ShellCommandLine.parse(command)
        for body in line.substitutions {
            if let reason = check(body, scope: scope, home: home, depth: depth + 1) { return reason }
        }
        var downloadInChain = false
        for segment in line.segments {
            if segment.separator != .pipe { downloadInChain = false }
            let command = effective(segment.words)
            if let command, shells.contains(command.name), segment.separator == .pipe, downloadInChain {
                return "baixa e executa um script da internet"
            }
            if let command, downloaders.contains(command.name) { downloadInChain = true }
            if let reason = checkWords(segment.words, scope: scope, home: home, depth: depth, viaXargs: false) { return reason }
        }
        return nil
    }

    private static func checkWords(_ words: [String], scope: Scope?, home: URL, depth: Int, viaXargs: Bool) -> String? {
        guard let command = effective(words) else { return nil }
        let args = Arguments(command.arguments)
        switch command.name {
        case "sudo", "doas":
            return "roda como administrador"
        case "rm":
            if viaXargs { return "apaga vários arquivos de uma vez (xargs rm)" }
            guard args.hasShort("rRf") || args.hasLong(["--recursive", "--force"]) else { return nil }
            if let scope, isBuildOutput(args.operands, in: scope) { return nil }
            return "apaga arquivos de forma recursiva ou forçada"
        case "find":
            if command.arguments.contains("-delete") { return "apaga os arquivos encontrados" }
            if let exec = command.arguments.firstIndex(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) }) {
                let inner = command.arguments[(exec + 1)...].prefix { $0 != ";" && $0 != "+" }
                return checkWords(Array(inner), scope: scope, home: home, depth: depth, viaXargs: true)
            }
            return nil
        case "xargs":
            guard let inner = xargsCommand(command.arguments) else { return nil }
            return checkWords(inner, scope: scope, home: home, depth: depth, viaXargs: true)
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
            let sub = command.arguments.first(where: { !$0.hasPrefix("-") })?.lowercased() ?? ""
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
            for word in command.arguments where !word.hasPrefix("-") {
                if let reason = checkScript(word, scope: scope, home: home, depth: depth + 1) { return reason }
            }
            return nil
        case "eval":
            return evalReason(command.arguments, scope: scope, home: home, depth: depth)
        case "source", ".":
            return command.arguments.contains(where: downloadsCode) ? "baixa e executa um script da internet" : nil
        case let name where shells.contains(name):
            return shellReason(command.arguments, scope: scope, home: home, depth: depth)
        case let name where name == "mkfs" || name.hasPrefix("mkfs.") || name.hasPrefix("newfs"):
            return "formata ou apaga um disco"
        default:
            return nil
        }
    }

    // MARK: Command words

    private static let wrappers: Set<String> = ["env", "nohup", "command", "exec", "builtin", "time", "nice", "caffeinate", "stdbuf", "ionice"]
    private static let keywords: Set<String> = ["if", "then", "else", "elif", "do", "while", "until", "!", "{", "(", "}", ")"]
    /// Options of each wrapper that take a value as the next word. Anything else starting with `-` is a flag
    /// (`env -i`, `caffeinate -i`), so the word after it is still the command.
    private static let wrapperValueOptions: [String: Set<String>] = [
        "env": ["-u", "-C", "-S"], "stdbuf": ["-i", "-o", "-e"], "nice": ["-n"], "caffeinate": ["-t"],
        "exec": ["-a"], "ionice": ["-c", "-n", "-p"],
    ]

    /// The command a list of words runs, after environment assignments and wrappers (`FOO=1 nohup rm …`).
    private static func effective(_ words: [String]) -> (name: String, arguments: [String])? {
        var rest = words[...]
        for _ in 0..<12 {
            guard let first = rest.first else { return nil }
            let word = first.trimmingCharacters(in: CharacterSet(charactersIn: "({"))
            if word.isEmpty || keywords.contains(word) || isAssignment(word) {
                rest = rest.dropFirst()
                continue
            }
            let name = word.contains("/") ? URL(fileURLWithPath: word).lastPathComponent : word
            guard wrappers.contains(name) else { return (name, Array(rest.dropFirst())) }
            rest = rest.dropFirst()
            if name == "command", rest.first.map({ $0 == "-v" || $0 == "-V" }) == true { return nil }
            let valueOptions = wrapperValueOptions[name] ?? []
            while let option = rest.first, option.hasPrefix("-") || isAssignment(option) {
                rest = rest.dropFirst(valueOptions.contains(option) ? 2 : 1)
            }
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

    private static func gitReason(_ arguments: [String]) -> String? {
        // Skip options before the subcommand (`git -C dir -c k=v push`).
        var rest = arguments[...]
        while let first = rest.first, first.hasPrefix("-") {
            rest = rest.dropFirst(["-C", "-c", "--git-dir", "--work-tree", "--namespace"].contains(first) ? 2 : 1)
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

    private static func shellReason(_ arguments: [String], scope: Scope?, home: URL, depth: Int) -> String? {
        if arguments.contains(where: downloadsCode) { return "baixa e executa um script da internet" }
        // `sh -c 'script'`, also `-lc` and `-ic`: the script is a command line of its own.
        guard let flag = arguments.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }),
              flag + 1 < arguments.count else { return nil }
        return check(arguments[flag + 1], scope: scope, home: home, depth: depth + 1)
    }

    private static func evalReason(_ arguments: [String], scope: Scope?, home: URL, depth: Int) -> String? {
        if arguments.contains(where: downloadsCode) { return "baixa e executa um script da internet" }
        return check(arguments.joined(separator: " "), scope: scope, home: home, depth: depth + 1)
    }

    /// `$(curl …)`, `<(curl …)` or backticks around a download: the output runs as code.
    private static func downloadsCode(_ word: String) -> Bool {
        guard word.hasPrefix("$(") || word.hasPrefix("<(") || word.hasPrefix("`") else { return false }
        return ShellCommandLine.parse(word).substitutions.contains { body in
            ShellCommandLine.parse(body).segments.contains { segment in
                effective(segment.words).map { downloaders.contains($0.name) } ?? false
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

    /// `rm -rf node_modules dist` inside the Orb's folder only clears what a build recreates.
    private static func isBuildOutput(_ operands: [String], in scope: Scope) -> Bool {
        guard !operands.isEmpty else { return false }
        let workspace = scope.workspace.standardizedFileURL.resolvingSymlinksInPath().path
        return operands.allSatisfy { operand in
            guard !operand.contains(where: { "*?[]{}$~`".contains($0) }) else { return false }
            let url = operand.hasPrefix("/") ? URL(fileURLWithPath: operand) : scope.directory.appending(path: operand)
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            return benignBuildFolders.contains(resolved.lastPathComponent.lowercased()) && resolved.path.hasPrefix(workspace + "/")
        }
    }

    // MARK: AppleScript

    private static let scriptRules: [(pattern: String, reason: String)] = [
        (#"\bempty\s+(the\s+)?trash\b|\bemptyTrash\b"#, "esvazia a Lixeira"),
        (#"\bdelete\s*\(?\s*(every|all)\b"#, "apaga tudo de uma vez"),
        (#"\bshut\s+down\b|\bshutDown\b"#, "desliga o Mac"),
        (#"\brestart\b"#, "reinicia o Mac"),
        (#"\blog\s*out\b|\blogOut\b"#, "encerra a sessão do usuário"),
        (#"\bwith\s+administrator\s+privileges\b"#, "roda como administrador"),
    ]

    private static func checkScript(_ script: String, scope: Scope?, home: URL, depth: Int) -> String? {
        guard depth < maxDepth else { return "usa scripts aninhados demais para conferir" }
        // `do shell script "…"` (and JXA's `doShellScript('…')`) runs shell text.
        let shellText = #"(?:do\s+shell\s+script|doShellScript\()\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)')"#
        if let regex = try? NSRegularExpression(pattern: shellText, options: [.caseInsensitive]) {
            let range = NSRange(script.startIndex..., in: script)
            for match in regex.matches(in: script, range: range) {
                for group in 1...2 {
                    guard let r = Range(match.range(at: group), in: script) else { continue }
                    let inner = script[r].replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                    if let reason = check(inner, scope: scope, home: home, depth: depth + 1) { return reason }
                }
            }
        }
        // The words of the script itself, not text inside its strings (`display dialog "restart later"`).
        let code = script.replacingOccurrences(of: #""(?:[^"\\]|\\.)*""#, with: "\"\"", options: .regularExpression)
        for rule in scriptRules where code.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return rule.reason
        }
        return nil
    }
}
