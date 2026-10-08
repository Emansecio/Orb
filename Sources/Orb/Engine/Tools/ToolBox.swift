import Foundation

/// The built-in tools offered to the model. Each family lists its own tools next to them (`fileTools` in
/// FileTools.swift, `shellTools` in ShellTool.swift, …), so adding a tool touches only its family's file.
enum ToolBox {
    static let all: [any AgentTool] = shellTools + fileTools + webTools + macTools + memoryTools
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

    var isExistingDirectory: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
