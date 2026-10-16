import Foundation

/// The built-in tools offered to the model. Each family lists its own tools next to them (`fileTools` in
/// FileTools.swift, `shellTools` in ShellTool.swift, …), so adding a tool touches only its family's file.
enum ToolBox {
    static let all: [any AgentTool] = shellTools + fileTools + webTools + searchTools + browseTools + macTools + memoryTools + scheduleTools + planTools

    /// The tools that read or act on another app's interface through Accessibility. Without that permission both
    /// only fail with instructions, so they are not offered (their descriptions are about 950 tokens in every request).
    static let accessibilityToolNames: Set<String> = ["ui_read", "ui_act"]

    /// The tools an Orb with these capabilities is offered. `accessibilityGranted` is whether macOS trusts the app
    /// for Accessibility; when it does not, `ui_read` and `ui_act` stay out of the list (it only changes when the
    /// permission does, which is rare, so the provider's cache of the tool list is not disturbed). `browser`: the `browse_*`
    /// tools come only with an installed engine (`.browser`); `web_fetch` and `web_search` come with "Navegar na web" alone.
    static func offered(for capabilities: Set<Capability>, accessibilityGranted: Bool,
                        browser: BrowserAvailability = .fetchOnly, multi: MultiOrbOffering = MultiOrbOffering()) -> [any AgentTool] {
        let base = all.filter { tool in
            guard tool.isOffered(for: capabilities) else { return false }
            if browseToolNames.contains(tool.spec.name), browser != .browser { return false }
            return accessibilityGranted || !accessibilityToolNames.contains(tool.spec.name)
        }
        return base + (multi.askUser ? [AskUserTool()] : []) + multiOrbTools.filter { tool in
            switch tool.spec.name {
            case "orbs": multi.orbs
            case OrbProposeTool.name: multi.propose
            case GroupCreateTool.name: multi.groupCreate
            case "group_remember": multi.groupMemory
            case "group_recall": multi.groupMemory || multi.groupRecall
            default: false
            }
        }
    }

    /// Said in the system prompt in place of the two tools, when they are held back, so a request to drive another
    /// app gets the way to allow it instead of a made-up workaround.
    static let accessibilityUnavailableNote = "Controlling other apps' interfaces (ui_read, ui_act) is off: Orb is not allowed in "
        + "Ajustes do Sistema → Privacidade e Segurança → Acessibilidade. If the task needs it, tell the user to allow it there; "
        + "meanwhile use AppleScript or Shortcuts."
}

/// How much text one call of a tool that pages returns. Those tools say how to continue (`offset`, `pages`), so a
/// page that fits under `ToolOutputCap.limit` reaches the model whole; one above would lose its middle to the cap
/// without the model being told which part to ask for.
enum ToolOutputBudget {
    /// A page of `read_file`, a PDF, a listing or a search: about 6,700 tokens.
    static let pageCharacters = 24_000
    /// What `web_fetch` returns when `max_chars` is not given: about 3,300 tokens. Most pages answer in their first
    /// screens; `offset` continues for the rest.
    static let webPageDefault = 12_000

    /// The lines that fit in `budget` characters (newlines counted), and how many were left out. The first line is
    /// always kept, so a single huge line cannot empty the result.
    static func fit(_ lines: [String], budget: Int = pageCharacters) -> (kept: [String], omitted: Int) {
        var used = 0
        var kept = 0
        for line in lines {
            let cost = line.count + 1
            if used + cost > budget, kept > 0 { break }
            used += cost
            kept += 1
        }
        return (Array(lines.prefix(kept)), lines.count - kept)
    }
}

// MARK: - Helpers shared by the tools

extension JSONValue {
    /// String argument, nil when missing or empty.
    func nonEmptyString(_ key: String) -> String? {
        guard let value = self[key]?.string, !value.isEmpty else { return nil }
        return value
    }

    func requiredString(_ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = allowEmpty ? self[key]?.string : nonEmptyString(key) else {
            throw ToolError("Faltou o argumento \"\(key)\".")
        }
        return value
    }

    /// Numeric argument; models sometimes send numbers as strings ("120"), so those count too.
    private func numeric(_ key: String) -> Double? {
        switch self[key] {
        case .number(let number)?: number
        case .string(let text)?: Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// Integer argument clamped to `range` (also safe for huge or fractional numbers); accepts "120" as well as 120.
    func integer(_ key: String, default value: Int, in range: ClosedRange<Int>) -> Int {
        guard let number = numeric(key), number.isFinite else { return value }
        // Compared as Doubles before converting: Double(Int.max) rounds up to 2^63, which Int(_:) would trap on.
        if number >= Double(range.upperBound) { return range.upperBound }
        if number <= Double(range.lowerBound) { return range.lowerBound }
        return Int(number)
    }

    /// Boolean argument; accepts `true`/`false` as well as the strings "true", "false", "yes", "sim", "1", "0".
    func flag(_ key: String, default value: Bool = false) -> Bool {
        switch self[key] {
        case .bool(let flag)?: return flag
        case .number(let number)?: return number != 0
        case .string(let text)?:
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "sim", "1": return true
            case "false", "no", "não", "nao", "0": return false
            default: return value
            }
        default: return value
        }
    }
}

/// Runs blocking work (folder walks, regular expressions, document parsing) off the cooperative thread pool,
/// and cancels it when the calling task is cancelled so Stop reaches it.
func runDetached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated) { try work() }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}

extension ToolContext {
    /// Resolves an absolute, `~` or working-directory-relative path.
    func url(for path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : workingDirectory.appending(path: expanded)
        return url.standardizedFileURL
    }
}

extension String {
    /// Keeps the first `limit` characters, noting how many were cut.
    func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        return prefix(limit) + "\n[... \(count - limit) caracteres omitidos ...]"
    }

    /// Keeps the first `limit` characters and ends with "…" when something was cut.
    func clipped(to limit: Int) -> String {
        count > limit ? String(prefix(limit)) + "…" : self
    }

    /// Levenshtein distance, or nil once it is past `limit` (names of very different length are rejected without the work).
    func editDistance(to other: String, limit: Int) -> Int? {
        let a = Array(self), b = Array(other)
        guard abs(a.count - b.count) <= limit else { return nil }
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            var best = row[0]
            for j in 1...b.count {
                let current = row[j]
                row[j] = Swift.min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
                best = Swift.min(best, row[j])
            }
            if best > limit { return nil }
        }
        return row[b.count] <= limit ? row[b.count] : nil
    }
}

extension URL {
    /// Follows symbolic links (also dangling ones) to the path that would really be written, so replacing a file
    /// that is a link (say a dotfile managed elsewhere) changes its target instead of swapping the link for a copy.
    var resolvingLinkChain: URL {
        var current = self
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else { break }
            current = (destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appending(path: destination)).standardizedFileURL
        }
        return current
    }

    /// Whether following the symbolic links from here never ends (`a -> b -> a`), which `resolvingLinkChain` gives up on.
    var isInLinkLoop: Bool {
        var current = self
        var seen: Set<String> = []
        for _ in 0..<64 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else { return false }
            current = (destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appending(path: destination)).standardizedFileURL
            if !seen.insert(current.path).inserted { return true }
        }
        return true
    }

    var isExistingDirectory: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Up to three paths that look like this missing one, for the "not found" error: the model mistypes a name, gets the
    /// case wrong or guesses the extension far more often than the file is really gone. Only the nearest folder that
    /// exists is read (one listing, no walk), compared with the first part of the path that is missing.
    var lookalikes: [String] {
        var folder = deletingLastPathComponent()
        var missing = lastPathComponent
        while !folder.isExistingDirectory, folder.path != "/" {
            missing = folder.lastPathComponent
            folder = folder.deletingLastPathComponent()
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let wanted = missing.lowercased()
        let stem = (wanted as NSString).deletingPathExtension
        // A short name is near too many others: one letter off at most, none below 3 letters.
        let typos = wanted.count >= 8 ? 2 : wanted.count >= 3 ? 1 : 0
        let scored = names.prefix(5_000).lazy.filter { !$0.hasPrefix(".") || missing.hasPrefix(".") }.compactMap { name -> (Int, String)? in
            let lower = name.lowercased()
            if lower == wanted { return (0, name) }
            if (lower as NSString).deletingPathExtension == stem, !stem.isEmpty { return (1, name) }
            guard typos > 0 else { return nil }
            return lower.editDistance(to: wanted, limit: typos).map { (1 + $0, name) }
        }
        return scored.sorted { $0 < $1 }.prefix(3).map { folder.appending(path: $0.1).path }
    }

    /// An ordinary file once links are followed: not a device, a pipe or a socket, which have no size and can block a read
    /// forever (a FIFO without a writer) or never end (`/dev/zero`).
    var isRegularFileResolved: Bool {
        (try? resolvingLinkChain.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    /// Throws when this is not an ordinary file; `ReadFileTool`, `EditFileTool` and `GrepTool` call it before opening anything.
    func requireRegularFile() throws {
        guard isRegularFileResolved else {
            throw ToolError("\(path) não é um arquivo comum (é um dispositivo, pipe ou socket); ler isso pode não terminar. "
                + "Use run_command com head -c se precisar mesmo.")
        }
    }
}

extension ToolError {
    /// "Arquivo não encontrado" with the lookalike paths (`URL.lookalikes`) and what to do next.
    static func notFound(_ message: String, _ url: URL, advice: String = "") -> ToolError {
        let near = url.lookalikes
        let hint = near.isEmpty ? "" : " Caminhos parecidos: " + near.joined(separator: ", ") + "."
        return ToolError("\(message): \(url.path).\(hint)" + (advice.isEmpty ? "" : " " + advice))
    }
}
