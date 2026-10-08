import Foundation

/// The built-in tools offered to the model.
enum ToolBox {
    static let all: [any AgentTool] = [
        RunCommandTool(), ReadFileTool(), WriteFileTool(), ListDirectoryTool(), SearchFilesTool(),
        WebFetchTool(), OpenTool(), AppleScriptTool(), RememberTool(), RecallTool(),
    ]
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

    /// Integer argument clamped to `range` (also safe for huge or fractional numbers).
    func integer(_ key: String, default value: Int, in range: ClosedRange<Int>) -> Int {
        guard let number = self[key]?.number, number.isFinite else { return value }
        return Int(min(max(number, Double(range.lowerBound)), Double(range.upperBound)))
    }
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
    var isExistingDirectory: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
