import Foundation

/// The built-in tools offered to the model. Each family lists its own tools next to them (`fileTools` in
/// FileTools.swift, `shellTools` in ShellTool.swift, …), so adding a tool touches only its family's file.
enum ToolBox {
    static let all: [any AgentTool] = shellTools + fileTools + webTools + macTools + memoryTools + scheduleTools

    /// The tools that read or act on another app's interface through Accessibility. Without that permission both
    /// only fail with instructions, so they are not offered (their descriptions are about 950 tokens in every request).
    static let accessibilityToolNames: Set<String> = ["ui_read", "ui_act"]

    /// The tools an Orb with these capabilities is offered. `accessibilityGranted` is whether macOS trusts the app
    /// for Accessibility; when it does not, `ui_read` and `ui_act` stay out of the list (it only changes when the
    /// permission does, which is rare, so the provider's cache of the tool list is not disturbed).
    static func offered(for capabilities: Set<Capability>, accessibilityGranted: Bool) -> [any AgentTool] {
        all.filter { tool in
            guard tool.isOffered(for: capabilities) else { return false }
            return accessibilityGranted || !accessibilityToolNames.contains(tool.spec.name)
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
}
