import AppKit
import CryptoKit
import WebKit

/// What `RichRenderer` draws.
struct RichRequest: Hashable, Sendable {
    enum Kind: String, Sendable {
        case diagram, math
        /// A ```html or ```page fence, without scripts (`PageSandbox`).
        case page
    }

    var kind: Kind
    var source: String

    /// The name of the drawing on disk: the source, what drew it and its look. A new `RichRenderer.version` leaves the old
    /// ones to be trimmed.
    var key: String {
        let digest = SHA256.hash(data: Data("\(RichRenderer.version)\n\(kind.rawValue)\n\(source)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum RichOutcome: Equatable, Sendable {
    /// A PNG on disk, and its size in points.
    case image(URL, CGSize)
    /// Why it stays code, in the reader's words or the drawing library's.
    case failed(String)
}

/// Draws diagrams and formulas in one hidden `WKWebView`, away from the chat: a row only ever shows the picture, so no web view
/// enters the lazy list and nothing of WebKit starts for a conversation without them. One drawing at a time, each with a
/// deadline. The page reaches nothing outside the app's own files (`PageSandbox.blockedRequests`), and is closed once idle.
/// The pictures live in a folder that can be deleted: the conversation keeps only its text.
@MainActor
final class RichRenderer {
    static let shared = RichRenderer()

    /// Bump when what the page draws changes: the libraries, `render.js` or the colors.
    nonisolated static let version = "1"
    /// Pictures are made at this scale, for Retina screens and the enlarged view.
    nonisolated static let scale: CGFloat = 3
    /// The most pixels a side of a picture takes; past it the scale gives way.
    nonisolated static let maxPixels: CGFloat = 4_096
    private static let deadline: Duration = .seconds(12)
    private static let idle: Duration = .seconds(60)
    private nonisolated static let diskLimit = 64 * 1024 * 1024
    private static let keptOutcomes = 200
    private static let trimEvery = 32

    /// Where the page is: the app's resources, or the sources when run from a build.
    nonisolated static var resources: URL? {
        [Bundle.main.resourceURL?.appendingPathComponent("Rich"),
         URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Rich")]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("render.html").path) }
    }

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Orb/rich", directoryHint: .isDirectory)
    }

    private var outcomes: [RichRequest: RichOutcome] = [:]
    private var running: [RichRequest: Task<RichOutcome, Never>] = [:]
    private var lastInLine: Task<Void, Never>?
    private var page: WKWebView?
    private var closing: Task<Void, Never>?
    private var drawnSinceTrim = 0

    /// What is already known, for a row that comes back into view.
    func known(_ request: RichRequest) -> RichOutcome? { outcomes[request] }

    func draw(_ request: RichRequest) async -> RichOutcome {
        if let known = outcomes[request] { return known }
        if let task = running[request] { return await task.value }
        let previous = lastInLine
        let task = Task<RichOutcome, Never> { [weak self] in
            await previous?.value
            guard let self else { return .failed("App encerrando") }
            return await self.produce(request)
        }
        running[request] = task
        lastInLine = Task { _ = await task.value }
        let outcome = await task.value
        running[request] = nil
        if outcomes.count >= Self.keptOutcomes { outcomes.removeAll() }
        outcomes[request] = outcome
        return outcome
    }

    private func produce(_ request: RichRequest) async -> RichOutcome {
        let key = request.key
        if let stored = await Task.detached(priority: .utility, operation: { RichDisk.read(key) }).value { return stored }
        closing?.cancel()
        let drawn: Drawn
        switch request.kind {
        case .diagram, .math: drawn = await drawInPage(request)
        case .page: drawn = await PageSandbox.draw(html: request.source)
        }
        scheduleClose()
        switch drawn {
        case .timedOut:
            return .failed("Demorou demais para desenhar")
        case .notNow(let reason):
            return .failed(reason)
        case .failed(let reason):
            await Task.detached(priority: .utility) { RichDisk.write(key, failure: reason) }.value
            return .failed(reason)
        case .image(let png, let size):
            let url = await Task.detached(priority: .utility) { RichDisk.write(key, png: png, size: size) }.value
            trimNow()
            return url.map { .image($0, size) } ?? .failed("Não consegui guardar o desenho")
        }
    }

    enum Drawn: Sendable {
        case image(Data, CGSize)
        /// The source itself fails: kept on disk, so it is not drawn again.
        case failed(String)
        /// This time only (the app's resources, a snapshot, the web process): the next launch tries again.
        case notNow(String)
        case timedOut
    }

    private func drawInPage(_ request: RichRequest) async -> Drawn {
        guard let view = await readyPage() else { return .notNow("Recursos de desenho ausentes") }
        let scale = Self.scale
        let result: Measured? = await PageSandbox.withDeadline(Self.deadline) { done in
            view.callAsyncJavaScript("return await window.orbRender(kind, source, scale);",
                                     arguments: ["kind": request.kind.rawValue, "source": request.source, "scale": Double(scale)],
                                     in: nil, in: .page) { done(Measured($0)) }
        }
        guard let result else {
            // Whatever hung is still running in there: the next drawing gets a new page.
            closePage()
            return .timedOut
        }
        switch result {
        case .failed(let reason): return .failed(reason)
        case .lost:
            closePage()
            return .notNow("Não consegui desenhar")
        case .size(let size): return await PageSandbox.picture(of: view, size: size, scale: scale) ?? .notNow("Não consegui capturar o desenho")
        }
    }

    /// What `orbRender` answered.
    private enum Measured: Sendable {
        case size(CGSize)
        case failed(String)
        /// The page did not answer: nothing was learned about the source.
        case lost

        init(_ result: Result<Any, Error>) {
            guard case .success(let value) = result, let box = value as? [String: Any] else {
                self = .lost
                return
            }
            if let error = box["error"] as? String {
                self = .failed(error)
            } else if let width = (box["width"] as? NSNumber)?.doubleValue, let height = (box["height"] as? NSNumber)?.doubleValue,
                      width > 0, height > 0 {
                self = .size(CGSize(width: width, height: height))
            } else {
                self = .failed("O desenho saiu vazio")
            }
        }
    }

    private func readyPage() async -> WKWebView? {
        if let page { return page }
        guard let resources = Self.resources else { return nil }
        guard let view = await PageSandbox.makeView(javaScript: true) else { return nil }
        let loaded = await PageSandbox.load(view, deadline: Self.deadline) {
            view.loadFileURL(resources.appendingPathComponent("render.html"), allowingReadAccessTo: resources)
        }
        guard loaded else { return nil }
        page = view
        return view
    }

    private func closePage() {
        page?.stopLoading()
        page = nil
    }

    private func scheduleClose() {
        closing?.cancel()
        closing = Task { [weak self] in
            try? await Task.sleep(for: Self.idle)
            guard !Task.isCancelled else { return }
            self?.closePage()
        }
    }

    /// At the first drawing, then every so often: a long session of pictures must not outgrow the limit until a restart.
    private func trimNow() {
        defer { drawnSinceTrim += 1 }
        guard drawnSinceTrim % Self.trimEvery == 0 else { return }
        Task.detached(priority: .background) { RichDisk.trim(limit: Self.diskLimit) }
    }

    #if DEBUG
    /// Forgets what is kept in memory, for tests.
    func forget() { outcomes.removeAll() }
    #endif
}

/// The folder of pictures. Every file in it can go at any time: it is drawn again.
nonisolated enum RichDisk {
    private struct Entry: Codable {
        var width: Double?
        var height: Double?
        var error: String?
    }

    private static func entry(_ key: String) -> URL { RichRenderer.folder.appending(path: key + ".json") }
    private static func picture(_ key: String) -> URL { RichRenderer.folder.appending(path: key + ".png") }

    static func read(_ key: String) -> RichOutcome? {
        guard let data = try? Data(contentsOf: entry(key)), let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        if let error = entry.error { return .failed(error) }
        guard let width = entry.width, let height = entry.height, FileManager.default.fileExists(atPath: picture(key).path) else { return nil }
        return .image(picture(key), CGSize(width: width, height: height))
    }

    @discardableResult
    static func write(_ key: String, png: Data, size: CGSize) -> URL? {
        guard (try? FileManager.default.createDirectory(at: RichRenderer.folder, withIntermediateDirectories: true)) != nil,
              (try? png.write(to: picture(key), options: .atomic)) != nil,
              let data = try? JSONEncoder().encode(Entry(width: size.width, height: size.height)),
              (try? data.write(to: entry(key), options: .atomic)) != nil else { return nil }
        return picture(key)
    }

    static func write(_ key: String, failure: String) {
        guard (try? FileManager.default.createDirectory(at: RichRenderer.folder, withIntermediateDirectories: true)) != nil,
              let data = try? JSONEncoder().encode(Entry(error: failure)) else { return }
        try? data.write(to: entry(key), options: .atomic)
    }

    /// The oldest go first, until the folder holds `limit` bytes.
    static func trim(limit: Int, folder: URL = RichRenderer.folder) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let sized = files.compactMap { url -> (url: URL, date: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let date = values.contentModificationDate,
                  let size = values.fileSize else { return nil }
            return (url, date, size)
        }.sorted { $0.date < $1.date }
        var total = sized.reduce(0) { $0 + $1.size }
        for file in sized where total > limit {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }
}
