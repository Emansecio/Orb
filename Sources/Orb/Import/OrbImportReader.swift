import Foundation

/// Why something could not be read, in the words the panel shows.
enum ImportFailure: Error, Equatable, LocalizedError, Sendable {
    case unrecognized, chatGPTHistory, pngCard, tooLarge, notACard

    var errorDescription: String? {
        switch self {
        case .unrecognized: "Não reconheci este formato. Cole a resposta inteira do assistente ou escolha um arquivo .md, .json ou .txt."
        case .chatGPTHistory: "Este é o histórico de conversas do ChatGPT. Ele não traz o GPT nem a memória: use o prompt acima no ChatGPT."
        case .pngCard: "Cartão em PNG ainda não: exporte o cartão como JSON."
        case .tooLarge: "Arquivo grande demais (máximo 1 MB)."
        case .notACard: "Este JSON não é um cartão de personagem (falta o nome ou o texto do personagem)."
        }
    }
}

/// An assistant found on this Mac ("Neste Mac"): read only when the person asks.
struct LocalAssistant: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let url: URL
    let display: String
}

/// Reads what another assistant knew into an `OrbImport`, as tolerantly as it can and without any UI: the "Cartão do
/// Orb" the prompt asks for, Character Card JSON (V1, V2, V3), the files of a Hermes or OpenClaw folder (a closed list
/// of names, no links followed) and plain text. Whatever it does not understand it ignores. Pure file and text work:
/// callers keep it off the main thread.
enum OrbImportReader {
    // MARK: Text

    /// `asInstructions` settles free text the preview asked about; nil guesses from how it starts.
    static func read(text: String, asInstructions: Bool? = nil) throws -> OrbImport {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= ImportLimits.bytes else { throw ImportFailure.tooLarge }
        guard trimmed.contains(where: \.isLetter), !trimmed.contains("\0") else { throw ImportFailure.unrecognized }
        let bare = unfenced(trimmed)
        if bare.hasPrefix("{") || bare.hasPrefix("["), let found = try readJSON(bare) { return found }
        let start = MemoryText.fold(String(trimmed.prefix(2_000)))
        if ["<!doctype", "<html", "<body"].contains(where: start.contains) { throw ImportFailure.unrecognized }
        return readCard(trimmed) ?? readFreeText(trimmed, asInstructions: asInstructions)
    }

    /// The text inside a code fence that wraps all of it (a JSON card copied from a chat); other text as it is.
    private static func unfenced(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 3, lines[0].hasPrefix("```"), lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```" else { return text }
        return lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Files and folders

    private static let singleFiles: Set<String> = ["SOUL.md", "IDENTITY.md", "USER.md", "MEMORY.md", "AGENTS.md"]

    static func read(file url: URL) throws -> OrbImport {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { return try read(folder: url) }
        if url.lastPathComponent == "conversations.json" { throw ImportFailure.chatGPTHistory }
        guard (values?.fileSize ?? 0) <= ImportLimits.bytes else { throw ImportFailure.tooLarge }
        guard let data = try? Data(contentsOf: url) else { throw ImportFailure.unrecognized }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { throw ImportFailure.pngCard }
        guard let text = String(data: data, encoding: .utf8) else { throw ImportFailure.unrecognized }
        if singleFiles.contains(url.lastPathComponent), let found = try? build(Contents(files: [url.lastPathComponent: text]),
                                                                              source: "Arquivo \(url.lastPathComponent)") {
            return found
        }
        return try read(text: text)
    }

    /// A Hermes (`~/.hermes`) or OpenClaw (`~/.openclaw/workspace`) folder, or a copy of one. Only these are opened:
    /// SOUL.md, IDENTITY.md, USER.md, MEMORY.md, AGENTS.md (at the top or in `memories/`) and `skills/**/SKILL.md`.
    /// A link, or a file whose real path leaves the folder, is skipped.
    static func read(folder: URL) throws -> OrbImport {
        var reader = FolderReader(root: folder.resolvingSymlinksInPath())
        if reader.hasFolder("workspace"), reader.text("SOUL.md") == nil, reader.text("MEMORY.md") == nil { // ~/.openclaw
            reader = FolderReader(root: reader.root.appending(path: "workspace", directoryHint: .isDirectory).resolvingSymlinksInPath())
        }
        var contents = Contents()
        for name in singleFiles {
            for place in name == "USER.md" || name == "MEMORY.md" ? [name, "memories/" + name] : [name] where contents.files[name] == nil {
                contents.files[name] = reader.text(place)
            }
        }
        contents.bundled = bundledNames(manifest: reader.text("skills/.bundled_manifest"), hub: reader.text("skills/.hub/lock.json"))
        contents.skills = reader.skills(skipping: contents.bundled)
        let isOpenClaw = reader.root.lastPathComponent == "workspace" || contents.files["IDENTITY.md"] != nil
        return try build(contents, source: isOpenClaw ? "OpenClaw" : "Hermes")
    }

    /// The assistants whose folders exist under `home`. Nothing in a developer run (it never reads the real Mac).
    static func detectLocal(home: URL = FileManager.default.homeDirectoryForCurrentUser, devRun: Bool = false) -> [LocalAssistant] {
        guard !devRun else { return [] }
        return [("Hermes", ".hermes"), ("OpenClaw", ".openclaw/workspace")].compactMap { name, path in
            let url = home.appending(path: path, directoryHint: .isDirectory)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
            return LocalAssistant(name: name, url: url, display: "~/" + path)
        }
    }

    private struct Contents {
        var files: [String: String] = [:]
        var skills: [(directory: String, text: String)] = []
        /// Skills that came with the app or from a hub: not the person's own.
        var bundled: Set<String> = []
    }

    private static func build(_ contents: Contents, source: String) throws -> OrbImport {
        var found = OrbImport(source: source)
        let files = contents.files
        if let soul = files["SOUL.md"] { found.identity = identity(from: soul) }
        for line in (files["IDENTITY.md"] ?? "").components(separatedBy: .newlines) {
            guard let (key, value) = field(line) else { continue }
            if key == "name" || key == "nome" { found.name = ImportSanitizer.line(value, limit: 40) }
            if ["role", "papel", "vibe"].contains(key) { found.role = ImportSanitizer.line(value, limit: 120) }
        }
        for file in ["USER.md", "MEMORY.md"] {
            found.facts += items(entries(files[file] ?? "", byParagraph: true))
        }
        found.facts = Array(found.facts.prefix(ImportLimits.listed))
        if let agents = files["AGENTS.md"] {
            let body = ImportSanitizer.block(agents, limit: MemoryBank.maximumLength)
            if !body.isEmpty { found.procedures = [ImportItem(body, title: "Regras de operação (AGENTS.md)")] }
        }
        found.skills = limitSkills(contents.skills.compactMap { directory, text in
            let (fields, body) = SkillCatalog.parse(text)
            guard !contents.bundled.contains(fields["name"] ?? "") else { return nil }
            return skill(title: fields["name"] ?? directory, summary: fields["description"] ?? "", body: body)
        })
        guard !found.isEmpty || !found.name.isEmpty else { throw ImportFailure.unrecognized }
        return found
    }

    /// The skills that came with the app (`skills/.bundled_manifest`, `name:hash` per line) or from a hub
    /// (`skills/.hub/lock.json`): not the person's own, so not imported.
    private static func bundledNames(manifest: String?, hub: String?) -> Set<String> {
        var names = Set((manifest ?? "").components(separatedBy: .newlines).compactMap { $0.split(separator: ":").first.map(String.init) })
        if let data = hub?.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let installed = json["installed"] as? [String: Any] {
            names.formUnion(installed.keys)
        }
        return names
    }

    /// Reads a folder with a closed list of names: never `.env`, `auth.json`, `config.yaml`, `sessions/`, `logs/`,
    /// `cron/`, a diary or a database. Links are not followed and the real path must stay inside the folder.
    private struct FolderReader {
        let root: URL
        var remaining = ImportLimits.bytes

        func hasFolder(_ name: String) -> Bool {
            let values = try? root.appending(path: name, directoryHint: .isDirectory).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }

        mutating func text(_ relative: String) -> String? { text(at: root.appending(path: relative)) }

        mutating func text(at url: URL) -> String? {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isSymbolicLink != true, values.isRegularFile == true,
                  let size = values.fileSize, size <= ImportLimits.fileBytes, size <= remaining,
                  url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                  let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
            remaining -= size
            return text
        }

        /// The `SKILL.md` of each folder under `skills/` (three levels at most, the first twenty), by the folder's name;
        /// the ones in `skip` are left out before they are read.
        mutating func skills(skipping skip: Set<String>) -> [(directory: String, text: String)] {
            var found: [(directory: String, text: String)] = []
            visit(root.appending(path: "skills", directoryHint: .isDirectory), depth: 0, skip: skip, into: &found)
            return found
        }

        private mutating func visit(_ folder: URL, depth: Int, skip: Set<String>, into found: inout [(directory: String, text: String)]) {
            guard depth <= 3, found.count < ImportLimits.listedSkills else { return }
            if depth > 0, FileManager.default.fileExists(atPath: folder.appending(path: "SKILL.md").path) {
                if !skip.contains(folder.lastPathComponent), let text = text(at: folder.appending(path: "SKILL.md")) {
                    found.append((folder.lastPathComponent, text))
                }
                return
            }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true { visit(child, depth: depth + 1, skip: skip, into: &found) }
            }
        }
    }
}
