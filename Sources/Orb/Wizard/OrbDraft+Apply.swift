import Foundation

/// The merge of one `orb_draft` call into the draft (pure, so it is tested without a model). What the call carries replaces
/// what the draft had, and what is refused comes back as a line for the model to read (`Report.rejected`) instead of failing
/// the call. The look is not the model's to choose: it is the person's, set in the sheet's editor, so a `look` in a call (an
/// older model, an older prompt) is ignored without a word.
extension OrbDraft {
    static let nameLimit = 60 // as `AppModel.nameLimit`
    static let roleLimit = 120
    static let instructionsLimit = 1_500

    /// The capabilities the assistant may offer: never `.connectors` (they need the person's own accounts).
    static let offeredCapabilities: [Capability] = [.terminal, .browser, .computerUse]
    /// The modes it may pick: never `.bypass`.
    static let offeredModes: [PermissionMode] = [.ask, .auto, .readOnly]

    /// Applies one call. A part is `changed` only when its value really differs, so the preview animates what moved.
    @discardableResult
    mutating func apply(_ arguments: JSONValue) -> Report {
        var report = Report()
        let before = self

        if let value = arguments["name"]?.string {
            let name = String(MemoryText.flatten(MemorySanitizer.scrub(value)).prefix(Self.nameLimit)).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { report.rejected.append("name: empty") } else { self.name = name }
        }
        if let value = arguments["role"]?.string {
            role = String(MemoryText.flatten(MemorySanitizer.scrub(value)).prefix(Self.roleLimit))
        }
        if let value = arguments["instructions"]?.string {
            instructions = Self.sanitizedInstructions(value)
        }
        if let listed = arguments["capabilities"]?.array {
            var kept: Set<Capability> = []
            for item in listed {
                let text = item.string ?? ""
                if let capability = Capability(rawValue: text), Self.offeredCapabilities.contains(capability) {
                    kept.insert(capability)
                } else {
                    report.rejected.append("capabilities '\(text)': use terminal, browser or computerUse")
                }
            }
            capabilities = kept
        }
        if let text = arguments["mode"]?.string {
            if let parsed = PermissionMode(rawValue: text), Self.offeredModes.contains(parsed) {
                mode = parsed
            } else {
                report.rejected.append("mode '\(text)': use ask, auto or readOnly")
            }
        }
        if arguments["ready"] != nil {
            if arguments.flag("ready") {
                if canCreate { ready = true } else { report.rejected.append("ready: the Orb still has no name") }
            } else {
                ready = false
            }
        }

        if name != before.name { report.changed.insert(.name) }
        if role != before.role { report.changed.insert(.role) }
        if instructions != before.instructions { report.changed.insert(.instructions) }
        if capabilities != before.capabilities { report.changed.insert(.capabilities) }
        if mode != before.mode { report.changed.insert(.mode) }
        revision += 1
        changed = report.changed
        return report
    }

    /// What the model reads back: the draft one line per field, then what was refused.
    func modelSummary(_ report: Report) -> String {
        let kept = Self.offeredCapabilities.filter(capabilities.contains).map(\.rawValue)
        var lines = [
            "name: \(name.isEmpty ? "(none yet)" : name)",
            "role: \(role.isEmpty ? "(none yet)" : role)",
            "instructions: \(instructions.isEmpty ? "(none yet)" : "\(instructions.count) chars")",
            "capabilities: \(kept.isEmpty ? "none" : kept.joined(separator: ", "))",
            "mode: \(mode.rawValue)",
            "ready: \(ready)",
        ]
        lines += report.rejected.map { "rejected: \($0)" }
        return lines.joined(separator: "\n")
    }

    // MARK: Pieces

    /// Secrets removed, control characters out, each line's spaces collapsed, line breaks kept (no runs of blank lines),
    /// at most `instructionsLimit` characters.
    static func sanitizedInstructions(_ text: String) -> String {
        var kept: [String] = []
        for raw in MemorySanitizer.scrub(text).components(separatedBy: .newlines) {
            let line = MemoryText.flatten(raw)
            if line.isEmpty, kept.last?.isEmpty ?? true { continue }
            kept.append(line)
        }
        return String(kept.joined(separator: "\n").prefix(instructionsLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
