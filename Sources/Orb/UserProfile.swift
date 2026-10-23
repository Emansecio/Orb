import Foundation

// The user's own profile ("Você" in Ajustes → Geral): one for all the Orbs, kept in `state.json`. Its text reaches the
// Orbs through the memory brief (`MemoryBank.brief(profile:)`), never through `SystemPrompt`; the photo never leaves
// the Mac.

struct UserProfile: Codable, Equatable, Sendable {
    static let nameLimit = 60
    static let nicknameLimit = 40
    static let aboutLimit = 400

    var name = ""
    /// How the Orbs should address the user ("Como te chamar").
    var nickname = ""
    var about = ""
    /// File name inside `perfil/` of the data folder; empty when there is no photo.
    var photo = ""

    /// Nothing the Orbs would read: the photo stays on the Mac, so it does not count.
    var hasText: Bool { [name, nickname, about].contains { !MemoryText.flatten($0).isEmpty } }

    /// Whether anything at all is filled in (text or photo).
    var isEmpty: Bool { !hasText && photo.isEmpty }

    /// What the Orbs call the user: the nickname, else the name.
    var callName: String? { [nickname, name].lazy.map { MemoryText.flatten($0) }.first { !$0.isEmpty } }

    /// What the avatar shows when there is no photo: the first letter of `callName`.
    var initial: String? { callName?.first.map { String($0).uppercased() } }

    /// The section of the Orbs' memory brief: empty (and costing nothing) while there is no text. In English like
    /// the rest of the prompt; flattened to plain lines (no fake sections) and without secrets, and cut to the limits
    /// again here, so it stays around 750 characters at its longest.
    var promptSection: String {
        let name = Self.line(name, Self.nameLimit), nickname = Self.line(nickname, Self.nicknameLimit)
        let about = Self.line(about, Self.aboutLimit)
        guard !name.isEmpty || !nickname.isEmpty || !about.isEmpty else { return "" }
        var lines = ["## About the user (their profile in Ajustes)"]
        var who: [String] = []
        if !name.isEmpty { who.append("Name: \(name).") }
        if !nickname.isEmpty, nickname.caseInsensitiveCompare(name) != .orderedSame { who.append("Call them: \(nickname).") }
        if !who.isEmpty { lines.append(who.joined(separator: " ")) }
        if !about.isEmpty { lines.append(about) }
        lines.append((name.isEmpty && nickname.isEmpty ? "" : "Use the name naturally (a greeting, not every message). ")
            + "Do not ask what this already says; your identity and preferences below win on how to work.")
        return lines.joined(separator: "\n")
    }

    private static func line(_ text: String, _ limit: Int) -> String {
        MemoryText.flatten(MemorySanitizer.scrub(String(text.prefix(limit * 2)))).prefix(limit).trimmingCharacters(in: .whitespaces)
    }
}

extension UserProfile {
    /// A field of the wrong type loses only itself, never the file (`DecodeLoss` keeps a copy of it).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            do { return try c.decodeIfPresent(String.self, forKey: key) ?? "" } catch { DecodeLoss.record(); return "" }
        }
        self.init(name: text(.name), nickname: text(.nickname), about: text(.about), photo: text(.photo))
    }
}

/// The user's photo: `<data folder>/perfil/foto-<8 hex>.jpg|png`, shrunk to a square. Each photo has its own name
/// (`Thumbnails` caches by path), and the one it replaces is deleted.
struct ProfilePhoto: Sendable {
    static let folderName = "perfil"
    static let side = 256

    let directory: URL

    init(dataFolder: URL) {
        directory = dataFolder.appending(path: Self.folderName)
    }

    func url(for fileName: String) -> URL { directory.appending(path: fileName) }

    /// Reads, crops to a square, shrinks and saves the picture at `source`; returns the new file's name. Throws
    /// `ImageAttachmentError` (too big, not a picture, not saved). Not for the main thread.
    func add(fileAt source: URL) throws -> String {
        let name = source.lastPathComponent
        // Only files of this Mac: a link dragged from a browser must never be downloaded here.
        guard source.isFileURL else { throw ImageAttachmentError.unreadable(name: name) }
        // Looked at before reading, so a huge file is never loaded.
        if let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > ImageProcessing.maxOriginalBytes {
            throw ImageAttachmentError.tooLarge(name: name, bytes: size)
        }
        guard let data = try? Data(contentsOf: source) else { throw ImageAttachmentError.unreadable(name: name) }
        let prepared = try ImageProcessing.prepare(data, name: name, maxSide: Self.side, square: true)
        let fileName = "foto-\(UUID().uuidString.prefix(8).lowercased()).\(prepared.fileExtension)"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try prepared.data.write(to: url(for: fileName), options: .atomic)
        } catch {
            throw ImageAttachmentError.notSaved(error.localizedDescription)
        }
        return fileName
    }

    /// Deletes a photo; a name that is not a plain file name of this folder is ignored.
    func remove(_ fileName: String) {
        guard !fileName.isEmpty, fileName == (fileName as NSString).lastPathComponent else { return }
        try? FileManager.default.removeItem(at: url(for: fileName))
    }
}
