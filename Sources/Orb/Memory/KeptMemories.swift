import Foundation

/// Who an Orb was, saved beside its kept memory (`perfil.json`): enough to start a new Orb from that memory. Only
/// what makes the Orb recognizable (name, role, look): never its permissions, mode, folder or anything secret.
struct KeptProfile: Codable, Equatable, Sendable {
    var version = 1
    var name: String
    var role: String
    var orb: OrbConfig

    static let fileName = "perfil.json"
}

extension KeptProfile {
    init(_ bot: Bot) { self.init(name: bot.name, role: bot.role, orb: bot.orb) }
}

/// The name, role and look of the new-Orb sheet before a kept memory filled them in.
struct StartSnapshot: Equatable, Sendable {
    var name: String
    var role: String
    var orb: OrbConfig
}

/// A memory kept from an Orb that was deleted or reset (a folder in `memoria/_guardadas/`), as the "Começar de" menu
/// of the new-Orb sheet and Ajustes list it.
struct KeptMemory: Identifiable, Equatable, Sendable {
    /// The folder's name (unique inside `_guardadas`).
    var id: String
    var url: URL
    /// The Orb's name: from the profile, or, for folders kept before profiles existed, from the folder's name.
    var name: String
    /// When it was kept.
    var date: Date
    /// How many memories (pages) it holds.
    var pageCount: Int
    /// nil for a folder without `perfil.json` (or one that cannot be read).
    var profile: KeptProfile?

    /// "Atlas · 8 de out. · 12 lembranças": what the menu shows (the day is written as on the welcome screen).
    var menuTitle: String {
        let count = pageCount == 1 ? "1 lembrança" : "\(pageCount) lembranças"
        return "\(name) · \(Self.shortDay.string(from: date)) · \(count)"
    }

    /// "12 lembranças" (or "1 lembrança").
    var countText: String { pageCount == 1 ? "1 lembrança" : "\(pageCount) lembranças" }

    /// "Cuida da minha agenda · 8 de out. · 12 lembranças": the line under the name on the welcome screen. Without a
    /// role (or a profile) it is only the day and the count.
    var shortDetail: String {
        let role = profile?.role.trimmingCharacters(in: .whitespaces) ?? ""
        let parts = [role, Self.shortDay.string(from: date), countText].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    /// "Continuar com a memória de Nina, 12 lembranças, 8 de outubro": what VoiceOver says for the row.
    var spokenSummary: String {
        "Continuar com a memória de \(name), \(countText), \(Self.longDay.string(from: date))"
    }

    /// What choosing this memory in "Começar de" fills in: the Orb's name and, when the folder has a profile, its role
    /// and look (a folder from before profiles gives only the name; what is not given stays as it is).
    func fill(name: inout String, role: inout String, orb: inout OrbConfig) {
        name = self.name
        guard let profile else { return }
        role = profile.role
        orb = profile.orb
    }

    /// Takes back what `fill` gave, field by field: what is still as the memory gave it goes back to `before`, and
    /// what the person has typed or changed since stays. So choosing "Nenhuma (Orb novo)" after a memory leaves no
    /// trace of it.
    func unfill(name: inout String, role: inout String, orb: inout OrbConfig, before: StartSnapshot) {
        var gaveName = before.name, gaveRole = before.role, gaveOrb = before.orb
        fill(name: &gaveName, role: &gaveRole, orb: &gaveOrb)
        if name == gaveName { name = before.name }
        if role == gaveRole { role = before.role }
        if orb == gaveOrb { orb = before.orb }
    }

    /// The gray line under the "Começar de" card once a memory is chosen.
    var startingNote: String {
        profile == nil ? "O nome veio da memória. Dá para mudar."
            : "Nome, papel e aparência vieram da memória. Dá para mudar."
    }

    private static func dayFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = format
        return formatter
    }

    private static let shortDay = dayFormatter("d 'de' MMM")
    private static let longDay = dayFormatter("d 'de' MMMM")
}

/// The folder of kept memories and what goes in and out of it. Plain file work with no state, so it can run on any
/// thread (callers keep it off the main one) and be tested in a temporary folder.
enum KeptMemories {
    static let folderName = "_guardadas"
    private static let separator = " – "
    private static let dateFormat = "yyyy-MM-dd HH.mm"

    /// `memoria/_guardadas` for the memory folder `root` (`memoria/`).
    static func folder(in root: URL) -> URL { root.appending(path: folderName, directoryHint: .isDirectory) }

    private static func formatter() -> DateFormatter {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = dateFormat
        return format
    }

    /// The folder name for a memory kept at `now`: "<name> – <aaaa-mm-dd hh.mm>".
    static func folderName(for name: String, at now: Date) -> String {
        namePrefix(for: name) + formatter().string(from: now)
    }

    /// "<name> – ", the start of every folder kept for an Orb called `name` (slashes and colons cannot be in a folder name).
    static func namePrefix(for name: String) -> String {
        let safe = String(name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(60))
        return (safe.isEmpty ? "Orb" : safe) + separator
    }

    /// Moves `source` (an Orb's memory folder) to `_guardadas/<name> – <date>` under `root`, with `profile` written
    /// into it first so the two travel together. A name already taken gets " (2)", " (3)"…. Returns where it went,
    /// nil when there is nothing to move or the move failed.
    @discardableResult
    static func keep(_ source: URL, name: String, profile: KeptProfile?, in root: URL, now: Date = .now,
                     files: FileManager = .default) -> URL? {
        guard files.fileExists(atPath: source.path) else { return nil }
        if let profile { write(profile, into: source) }
        let kept = folder(in: root)
        try? files.createDirectory(at: kept, withIntermediateDirectories: true)
        let base = folderName(for: name, at: now)
        var target = kept.appending(path: base, directoryHint: .isDirectory), suffix = 2
        while files.fileExists(atPath: target.path) {
            target = kept.appending(path: "\(base) (\(suffix))", directoryHint: .isDirectory)
            suffix += 1
        }
        return (try? files.moveItem(at: source, to: target)) != nil ? target : nil
    }

    static func write(_ profile: KeptProfile, into folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(profile) else { return }
        try? data.write(to: folder.appending(path: KeptProfile.fileName), options: .atomic)
    }

    static func profile(in folder: URL) -> KeptProfile? {
        guard let data = try? Data(contentsOf: folder.appending(path: KeptProfile.fileName)) else { return nil }
        return try? JSONDecoder().decode(KeptProfile.self, from: data)
    }

    /// The kept memories under `root`, newest first. Reads the folder names, the profiles and counts the pages, so
    /// not for the main thread.
    static func list(in root: URL, files: FileManager = .default) -> [KeptMemory] {
        let folder = folder(in: root)
        let urls = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> KeptMemory? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let profile = profile(in: url)
            let parsed = parse(folderName: url.lastPathComponent)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return KeptMemory(id: url.lastPathComponent, url: url, name: profile?.name ?? parsed.name,
                              date: parsed.date ?? modified ?? .distantPast, pageCount: pageCount(in: url, files: files),
                              profile: profile)
        }
        .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    /// How many kept memories there are (the folders only: Ajustes does not need more).
    static func count(in root: URL, files: FileManager = .default) -> Int {
        let urls = (try? files.contentsOfDirectory(at: folder(in: root), includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.count
    }

    /// "Atlas – 2026-10-08 12.30" (optionally followed by " (2)") → the name and the date. A name without the date
    /// (a folder made by hand) is the whole name.
    static func parse(folderName: String) -> (name: String, date: Date?) {
        guard let range = folderName.range(of: separator, options: .backwards) else { return (folderName, nil) }
        var stamp = String(folderName[range.upperBound...])
        if let paren = stamp.range(of: #" \(\d+\)$"#, options: .regularExpression) { stamp.removeSubrange(paren) }
        guard let date = formatter().date(from: stamp) else { return (folderName, nil) }
        return (String(folderName[..<range.lowerBound]), date)
    }

    /// The pages of a memory folder: every `.md` in the folders of the kinds (the archive of compacted sessions and
    /// the profile are not memories).
    static func pageCount(in folder: URL, files: FileManager = .default) -> Int {
        Set(MemoryKind.allCases.map(\.folder)).reduce(0) { total, name in
            let pages = (try? files.contentsOfDirectory(at: folder.appending(path: name), includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])) ?? []
            return total + pages.filter { $0.pathExtension == "md" }.count
        }
    }

    /// Moves a kept memory to be the memory of a new Orb (`target` is `memoria/<id>`). The folder leaves
    /// `_guardadas`; the search index goes (it is rebuilt from the pages, so what it knew about the old Orb does not
    /// matter) and so does the profile, which has been used, and what belonged to the old Orb's skills (proposals waiting for
    /// its user, the copy of its skills). Throws when the folder cannot be moved.
    static func adopt(_ kept: URL, into target: URL, files: FileManager = .default) throws {
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: kept, to: target)
        for name in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm", KeptProfile.fileName, MemoryBank.proposalsFolder, MemoryBank.skillsFile] {
            try? files.removeItem(at: target.appending(path: name))
        }
    }
}
