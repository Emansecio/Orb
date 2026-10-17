import Foundation

// What the app installs for the Orbs' browsers, where it puts it, and what it tells the person while it works. The installer
// itself is `BrowserInstaller`; the settings screen talks to it through `BrowserSetup`.

/// One thing that can be installed: `agent-browser` (the command line that drives the browser) and, only for a Mac with no Chrome
/// or Brave, the Chrome for Testing it falls back to.
enum BrowserComponent: String, CaseIterable, Codable, Sendable, Identifiable {
    case agentBrowser, chrome

    var id: String { rawValue }

    /// "agent-browser", "Chrome".
    var name: String {
        switch self {
        case .agentBrowser: "agent-browser"
        case .chrome: "Chrome"
        }
    }
}

/// Where everything the installer puts on the Mac goes, all inside `<data folder>/navegador` (next to the Orbs' profiles):
///
///     bin/agent-browser
///     chrome/chrome-<version>/Google Chrome for Testing.app (only when the Mac has no Chrome or Brave)
///     instalados.json (what is installed, and which version), atualizacoes.json (the last look for newer releases),
///     agent-browser.json (the empty config every command is told to read), sessoes/<session>.launch (how each browser was launched),
///     lancadores/ (the one-line scripts that start Chrome with the user agent of a real one)
struct BrowserInstallLayout: Sendable, Equatable {
    var root: URL

    var binDirectory: URL { root.appending(path: "bin", directoryHint: .isDirectory) }
    var agentBrowser: URL { binDirectory.appending(path: "agent-browser") }
    /// Holds `chrome-<version>` folders, as `agent-browser install` names them.
    var chromeDirectory: URL { root.appending(path: "chrome", directoryHint: .isDirectory) }
    var recordsFile: URL { root.appending(path: "instalados.json") }
    var updatesFile: URL { root.appending(path: "atualizacoes.json") }

    /// Where an install works until it is whole; its folder is moved into place only at the end.
    static let workPrefix = ".instalando-"

    func workFolder(_ id: UUID = UUID()) -> URL { root.appending(path: Self.workPrefix + id.uuidString, directoryHint: .isDirectory) }
}

/// What the installer wrote down about a component it installed.
struct InstalledComponent: Codable, Equatable, Sendable {
    var version: String
    var installedAt: Date
    /// Where it was downloaded from (a release asset, a package index), when it was.
    var source: String?
    /// The SHA-256 the download was checked against; nil when the release publishes none (and nothing was checked).
    var sha256: String?
    /// Something worth showing next to the version: "Chrome for Testing", say.
    var detail: String?
    /// Whether the download matched a checksum (true), or there was none to match (false, shown in Ajustes). Nil for what has no
    /// such download (Chrome verifies its own package) and for records written before this was told.
    var verified: Bool?
}

typealias InstalledRecords = [String: InstalledComponent]

/// The newest release of each component, as of `checkedAt` (see `BrowserInstaller.checkForUpdates`).
struct BrowserUpdateCheck: Codable, Equatable, Sendable {
    var checkedAt: Date
    var latest: [String: String]

    /// A look is made at most once a day.
    static let interval: TimeInterval = 24 * 3600

    func isDue(now: Date = .now) -> Bool { now.timeIntervalSince(checkedAt) >= Self.interval || checkedAt > now }
}

// MARK: - Progress

/// How far an install is, for the line and the bar of the settings row.
struct BrowserInstallProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case preparing, resolving, downloading, verifying, extracting, installing, checking, finishing
    }

    var component: BrowserComponent
    var phase: Phase
    /// Bytes received and expected, in the phases that know them (a download).
    var received: Int64 = 0
    var total: Int64?
    /// This component is number `step` of `steps` of what the engine needs.
    var step = 1
    var steps = 1
    /// The version being installed, once known.
    var version: String?

    /// 0...1 of the component, nil while it cannot be told.
    var componentFraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(max(Double(received) / Double(total), 0), 1)
    }

    /// 0...1 of the whole install: the finished components plus the part of this one, nil while this one cannot be told.
    var fraction: Double? {
        guard let part = componentFraction else { return nil }
        return (Double(step - 1) + part) / Double(max(steps, 1))
    }

    /// "Baixando o Chrome… 42 de 184 MB" (Portuguese, for the row).
    var text: String {
        let name = component.name
        let prefix = steps > 1 ? "\(step)/\(steps) · " : ""
        switch phase {
        case .preparing: return prefix + "Preparando…"
        case .resolving: return prefix + "Procurando a versão mais nova do \(name)…"
        case .downloading:
            guard let total, total > 0 else { return prefix + "Baixando o \(name)… \(Self.megabytes(received))" }
            return prefix + "Baixando o \(name)… \(Self.megabytes(received, of: total))"
        case .verifying: return prefix + "Conferindo o \(name)…"
        case .extracting: return prefix + "Abrindo o pacote do \(name)…"
        case .installing: return prefix + "Instalando o \(name)…"
        case .checking: return prefix + "Testando o \(name)…"
        case .finishing: return prefix + "Terminando…"
        }
    }

    /// "42 de 184 MB" (or "42 MB" without a total).
    static func megabytes(_ bytes: Int64, of total: Int64? = nil) -> String {
        func mb(_ value: Int64) -> Int { Int((Double(value) / 1_000_000).rounded()) }
        if let total { return "\(mb(bytes)) de \(mb(total)) MB" }
        return "\(mb(bytes)) MB"
    }
}

// MARK: - Errors

/// Why an install, a removal or a check did not work. Every message is Portuguese and says what the person can do.
enum BrowserInstallError: LocalizedError, Equatable, Sendable {
    case noNetwork
    case rateLimited
    case checksumMismatch(String)
    case diskFull(needed: Int64?)
    case unsupportedMac(String)
    case assetMissing(String)
    case needsAgentBrowser
    case broken(String, detail: String)
    /// The new version did not work in its place, and the one that was installed came back.
    case updateRolledBack(String, detail: String)
    case failed(String, detail: String)

    var errorDescription: String? {
        switch self {
        case .noNetwork:
            "Sem conexão com a internet. Confira a rede e tente de novo."
        case .rateLimited:
            "O GitHub limitou as consultas deste Mac por enquanto. Tente de novo em alguns minutos."
        case .checksumMismatch(let name):
            "O arquivo baixado do \(name) não confere com a soma de verificação publicada. Nada foi instalado. Tente de novo; se repetir, a rede pode estar alterando o arquivo."
        case .diskFull(let needed):
            if let needed {
                "Não há espaço em disco suficiente (precisa de uns \(BrowserInstallProgress.megabytes(needed)) livres). Libere espaço e tente de novo."
            } else {
                "O disco ficou sem espaço. Libere espaço e tente de novo."
            }
        case .unsupportedMac(let detail):
            "Este Mac não tem versão disponível: \(detail)."
        case .assetMissing(let name):
            "A versão mais nova do \(name) não publica o arquivo para este Mac. Tente de novo mais tarde."
        case .needsAgentBrowser:
            "Falta o agent-browser, que dirige os navegadores. Instale-o primeiro."
        case .broken(let name, let detail):
            "O \(name) foi instalado mas não abriu (\(detail)). Foi removido; tente instalar de novo."
        case .updateRolledBack(let name, let detail):
            "A versão nova do \(name) não abriu (\(detail)). A que estava instalada voltou e continua como estava."
        case .failed(let name, let detail):
            "Não foi possível instalar o \(name): \(detail)"
        }
    }
}

// MARK: - Platform

/// The Mac the installer picks files for.
struct BrowserPlatform: Sendable, Equatable {
    enum Architecture: String, Sendable { case arm64, x86_64 }

    var architecture: Architecture

    /// The hardware, not the slice the app runs as: an Intel build under Rosetta on an Apple silicon Mac still gets arm64 files.
    static var current: BrowserPlatform {
        var flag: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &flag, &size, nil, 0) == 0, flag == 1 { return BrowserPlatform(architecture: .arm64) }
        #if arch(arm64)
        return BrowserPlatform(architecture: .arm64)
        #else
        return BrowserPlatform(architecture: .x86_64)
        #endif
    }

    /// The `agent-browser` release file: `agent-browser-darwin-arm64` / `-darwin-x64`.
    var agentBrowserAsset: String { "agent-browser-darwin-" + (architecture == .arm64 ? "arm64" : "x64") }

    /// The `agent-browser` the app installs, pinned: the version it was tested with and the SHA-256 of each release file (the
    /// `digest` GitHub publishes for the asset, conferred against the downloaded file on 16/10/2026). A new version is a change in
    /// the app, with the new hashes; the install never takes "the latest".
    static let agentBrowserVersion = "0.39.1"
    /// About the size of the release file, for the progress bar and the free-space check.
    static let agentBrowserSize: Int64 = 17_500_000

    /// The pinned hash of each release file. A property so that tests can serve a file of their own.
    var pinnedHashes: [Architecture: String] = [
        .arm64: "cc18fac41d9dc9821918340a136e643286ea05544c4dd35671b796f1a874cdef",
        .x86_64: "339cb9aa6dfd404856cf938df34cd3b4779c61dfd57fc257be11b14fd1a885f9",
    ]

    var agentBrowserSHA256: String { pinnedHashes[architecture] ?? "" }

    var agentBrowserURL: URL {
        URL(string: "https://github.com/vercel-labs/agent-browser/releases/download/v\(Self.agentBrowserVersion)/\(agentBrowserAsset)")!
    }
}

// MARK: - Versions

enum BrowserVersion {
    /// "v0.39.0" -> "0.39.0".
    static func clean(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
    }

    /// The numbers of a version ("145.0.7632.109.2" -> [145, 0, 7632, 109, 2]); the rest is ignored.
    static func numbers(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// Whether `candidate` is a newer version than `installed`, compared number by number ("0.10.0" is newer than "0.9.0").
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let new = numbers(candidate), old = numbers(installed)
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0, b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// The last "145.0.7632.109"-looking run in a text ("Google Chrome for Testing 155.0.8059.39").
    static func find(in text: String) -> String? {
        let pattern = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)+"#)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern?.matches(in: text, range: range).last, let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}

/// Reads `42/184 MB` out of what `agent-browser install` prints as it downloads
/// ("  9/184 MB (5%)", "Download progress: 59% (82/140 MB)").
enum DownloadProgressLine {
    private static let progress = try? NSRegularExpression(pattern: #"(\d+)\s*/\s*(\d+)\s*MB"#)

    static func parse(_ text: String) -> (received: Int64, total: Int64)? {
        guard let regex = progress else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let first = Range(match.range(at: 1), in: text), let second = Range(match.range(at: 2), in: text),
              let received = Int64(text[first]), let total = Int64(text[second]), total > 0 else { return nil }
        return (received * 1_000_000, total * 1_000_000)
    }
}
