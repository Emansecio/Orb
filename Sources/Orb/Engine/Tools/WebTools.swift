import Foundation
import os

struct WebFetchTool: AgentTool {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    /// The most one call returns (`max_chars` can ask for up to this), and what it returns by default. Both stay under
    /// `ToolOutputCap.limit`: longer pages are read in pieces with `offset`, which the note at the end spells out.
    static let maxCharacters = ToolOutputBudget.pageCharacters
    static let defaultCharacters = ToolOutputBudget.webPageDefault
    /// Pages larger than this are cut (keeps memory bounded on huge downloads).
    static let maxBytes = 5_000_000
    /// PDFs are often bigger and cannot be opened when cut (the index sits at the end), so they get more room.
    static let maxPDFBytes = 25_000_000
    /// Largest file `save_to` will download.
    static let maxDownloadBytes = 100_000_000
    /// How many passages `find` returns.
    static let maxFindMatches = 8
    /// The longest a page is read for: the request's own timeout only covers silence between packets, so an endless
    /// stream (server-sent events, a radio) with the odd keep-alive would hold the turn forever.
    static let readDeadline = Duration.seconds(30)

    let session: URLSession
    /// Bytes read from a PDF response before cutting it; a parameter so tests need not serve 25 MB.
    let pdfLimit: Int
    /// Converted pages, so that reading a long one in pieces downloads it once.
    let cache: WebPageCache
    /// How long the body is read for before what arrived is used; a parameter so tests need not wait 30 s.
    let readDeadline: Duration

    init(session: URLSession = .shared, pdfLimit: Int = WebFetchTool.maxPDFBytes, cache: WebPageCache = .shared,
         readDeadline: Duration = WebFetchTool.readDeadline) {
        self.session = session
        self.pdfLimit = pdfLimit
        self.cache = cache
        self.readDeadline = readDeadline
    }

    let spec = ToolSpec(
        name: "web_fetch",
        description: """
        Fetch a web page over http(s) as readable light Markdown (main content; links as "text (url)") with the final \
        URL and title. JSON, XML and text come back as is, PDFs as text, \
        images as a picture; no JavaScript. Returns 12,000 characters (`max_chars` up to 24,000); the closing note gives \
        the `offset` to continue; `find` locates a word in a long page. To keep a \
        file (image, archive, PDF…) pass `save_to`.
        """,
        parameters: .schema([
            "url": .property("string"),
            "offset": .property("integer", "First character, to continue a long page (default 0)."),
            "max_chars": .property("integer"),
            "find": .property("string", "Instead of the page, up to 8 passages around this text, each with its offset."),
            "save_to": .property("string", "Download to this path instead (up to 100 MB; replaces a file)."),
        ], required: ["url"]))

    var kind: ToolCall.Kind { .browser }
    var capability: Capability? { .browser }
    /// A request can carry data out in its URL, so fetching asks first (unless "Sempre permitir"); saving to a
    /// file also writes to disk. Both stay sensitive.
    func risk(_ arguments: JSONValue) -> ToolRisk { .sensitive }

    func summary(_ arguments: JSONValue) -> (title: String, detail: String) {
        let address = arguments["url"]?.string ?? ""
        guard let destination = arguments.nonEmptyString("save_to") else { return ("Lendo página", address) }
        return ("Baixando arquivo", address + "\n→ " + destination)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        try await perform(arguments, context: context, wantsImage: false).text
    }

    /// A picture at the address reaches the model as a picture when it can look at one.
    func runWithImages(_ arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        try await perform(arguments, context: context, wantsImage: context.acceptsImages && context.imageStore != nil && context.botID != nil)
    }

    private func perform(_ arguments: JSONValue, context: ToolContext, wantsImage: Bool) async throws -> ToolResult {
        let address = try arguments.requiredString("url")
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
            throw ToolError("Endereço inválido: use uma URL http:// ou https://.")
        }
        let destination = arguments.nonEmptyString("save_to")
        if destination != nil, !context.canSaveFiles {
            throw ToolError("save_to grava um arquivo no Mac, e \"\(Capability.terminal.label)\" está desligado neste Orb. Leia a página sem save_to, ou peça ao usuário para ligar essa chave no painel do Orb.")
        }
        // A page read in pieces is downloaded once: the pieces after the first (and a search in it) come from memory.
        let find = arguments.nonEmptyString("find")
        if destination == nil, arguments.integer("offset", default: 0, in: 0...Int.max) > 0 || find != nil,
           let entry = await cache.entry(for: url.absoluteString) {
            return ToolResult(text: entry.render(arguments: arguments, find: find))
        }
        do {
            return try await fetch(url, destination: destination, arguments: arguments, context: context, find: find, wantsImage: wantsImage)
        } catch let error as URLError where error.code != .cancelled {
            throw Self.explain(error, url: url)
        }
    }

    private func fetch(_ url: URL, destination: String?, arguments: JSONValue, context: ToolContext, find: String?, wantsImage: Bool) async throws -> ToolResult {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        let finalURL = response.url ?? url
        // The status is known from the headers alone; do not download an error page's body to find out.
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
            throw ToolError(Self.statusMessage(status, url: finalURL))
        }

        if let destination {
            // Said up front when the server announces a size, instead of after 100 MB.
            if response.expectedContentLength > Int64(Self.maxDownloadBytes) {
                throw ToolError(Self.tooLargeMessage)
            }
            let target = context.url(for: destination)
            let size = try await Self.download(bytes, to: target)
            return ToolResult(text: "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(response.mimeType ?? "tipo desconhecido")) de \(finalURL.absoluteString) salvos em \(WriteFileTool.location(target, target.resolvingLinkChain))")
        }

        let mimeType = (response.mimeType ?? "").lowercased()
        var header = "URL: \(finalURL.absoluteString)"
        // A type that can only be saved (audio, video, an archive…) is answered from the headers: an endless stream of
        // one would otherwise be read up to the limit just to say it is not text.
        if !Self.isReadable(mimeType, wantsImage: wantsImage) {
            let size = response.expectedContentLength > 0
                ? ByteCountFormatter.string(fromByteCount: response.expectedContentLength, countStyle: .file) + " " : ""
            return ToolResult(text: header + "\nConteúdo \(mimeType) de \(size)(não é texto). Use save_to para baixá-lo.")
        }
        let limit = mimeType.contains("pdf") ? pdfLimit : Self.maxBytes
        let (data, cutByTime) = try await Self.read(bytes, limit: limit, deadline: readDeadline)
        let cut = data.count >= limit

        var text: String
        if mimeType.contains("pdf") || data.starts(with: Array("%PDF".utf8)) {
            do {
                text = try await runDetached { [data] in try DocumentReader.allPDFText(data) }
            } catch let error as ToolError where cut {
                throw ToolError("\(error.message) A resposta passa de \(limit / 1_000_000) MB e foi lida só em parte, o que costuma impedir a abertura de um PDF. Baixe com save_to e leia com read_file (use pages para escolher as páginas).")
            }
        } else if mimeType.contains("html") {
            let charset = response.textEncodingName
            let page = try await runDetached { [data] in
                HTMLText.convert(WebText.decode(data, headerCharset: charset, sniffMeta: true), baseURL: finalURL)
            }
            if let title = page.title, !title.isEmpty { header += "\nTítulo: \(title)" }
            if page.hasSiteLinks, let origin = Self.origin(of: finalURL) { header += "\nLinks começando com / são deste site (\(origin))." }
            text = page.text
            if page.needsJavaScript { text += (text.isEmpty ? "" : "\n\n") + HTMLText.javaScriptNote }
        } else if mimeType.hasPrefix("text/") || mimeType.contains("json") || mimeType.contains("xml") || mimeType.contains("javascript") {
            text = WebText.decode(data, headerCharset: response.textEncodingName, sniffMeta: mimeType.contains("xml"))
        } else if wantsImage, mimeType.hasPrefix("image/"), mimeType != "image/svg+xml", !cut,
                  let store = context.imageStore, let botID = context.botID,
                  let image = try? await store.attach(data, name: url.lastPathComponent.isEmpty ? "imagem" : url.lastPathComponent, botID: botID) {
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            return ToolResult(text: header + "\nImagem \(mimeType) de \(size), anexada para você ver.", images: [image])
        } else {
            let bytes = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            return ToolResult(text: header + "\nConteúdo \(mimeType.isEmpty ? "de tipo desconhecido" : mimeType) de \(cut ? "mais de " : "")\(bytes) (não é texto). Use save_to para baixá-lo.")
        }

        if cutByTime { header += "\n[a resposta não terminou em \(max(1, readDeadline.components.seconds)) s; o texto é só o que chegou até lá]" }
        let entry = WebPageCache.Entry(header: header, text: text, truncatedDownload: cut ? limit : nil)
        await cache.store(entry, for: url.absoluteString)
        return ToolResult(text: entry.render(arguments: arguments, find: find))
    }

    // MARK: Reading

    /// Whether a body of this type is worth reading: text, a PDF, a picture the model can see, or a type the server
    /// did not say (a PDF is told apart by its first bytes).
    static func isReadable(_ mimeType: String, wantsImage: Bool) -> Bool {
        mimeType.isEmpty || mimeType == "application/octet-stream" || mimeType.hasPrefix("text/") || mimeType.contains("pdf")
            || mimeType.contains("html") || mimeType.contains("json") || mimeType.contains("xml") || mimeType.contains("javascript")
            || (wantsImage && mimeType.hasPrefix("image/"))
    }

    /// The body, up to `limit` bytes or until `deadline`, whichever comes first (`timedOut` then). A read that fails
    /// partway still throws; cancelling the turn does too.
    static func read(_ bytes: URLSession.AsyncBytes, limit: Int, deadline: Duration) async throws -> (data: Data, timedOut: Bool) {
        enum Outcome { case finished, timedOut, failed(any Error) }
        let received = OSAllocatedUnfairLock(initialState: Data())
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                var chunk = Data()
                var total = 0
                // What arrived is handed over in pieces (a lock per byte is wasteful) and once more on the way out.
                func hand() {
                    let piece = chunk
                    received.withLock { $0.append(piece) }
                    chunk.removeAll(keepingCapacity: true)
                }
                defer { hand() }
                do {
                    for try await byte in bytes {
                        chunk.append(byte)
                        total += 1
                        if total >= limit { break }
                        if chunk.count >= 16_384 { hand() }
                    }
                    return .finished
                } catch {
                    return .failed(error)
                }
            }
            group.addTask { (try? await Task.sleep(for: deadline)) == nil ? .finished : .timedOut }
            let first = await group.next() ?? .finished
            group.cancelAll()
            return first
        }
        if case .failed(let error) = outcome { throw error }
        try Task.checkCancellation()
        let data = received.withLock { $0 }
        if case .timedOut = outcome { return (data, true) }
        return (data, false)
    }

    // MARK: Pages

    /// `max_chars` characters from `offset`, with a note on where to continue. A page is cut at the last line
    /// break (or space) near its end, not in the middle of a word or an address, and the note says where it really stopped.
    static func page(of text: String, arguments: JSONValue, truncatedDownload: Int?) -> String {
        let total = text.count
        let offset = arguments.integer("offset", default: 0, in: 0...Int.max)
        let length = arguments.integer("max_chars", default: defaultCharacters, in: 1...maxCharacters)
        if total == 0 { return "(sem texto)" }
        guard offset < total else { return "O texto tem só \(total) caracteres; offset=\(offset) está além do fim." }
        let start = text.index(text.startIndex, offsetBy: offset)
        var end = text.index(start, offsetBy: min(length, total - offset))
        if end < text.endIndex { end = softEnd(of: text, from: start, to: end) }
        let shown = text.distance(from: start, to: end)
        var result = String(text[start..<end])
        if offset > 0 || end < text.endIndex {
            result = "[caracteres \(offset + 1)–\(offset + shown) de \(total)]\n" + result
        }
        if end < text.endIndex {
            result += "\n[... mais \(total - offset - shown) caracteres; use offset=\(offset + shown) para continuar ...]"
        } else if let limit = truncatedDownload {
            result += "\n[... a resposta passa de \(limit / 1_000_000) MB; o resto não foi lido ...]"
        }
        return result
    }

    /// Moves the end of a piece back to the last line break in its final quarter (else the last space), so the next
    /// piece starts at a line. The piece never becomes empty.
    private static func softEnd(of text: String, from start: String.Index, to end: String.Index) -> String.Index {
        let window = max(text.distance(from: start, to: end) / 4, 1)
        let floor = text.index(end, offsetBy: -window)
        let tail = text[floor..<end]
        if let newline = tail.lastIndex(of: "\n") { return text.index(after: newline) }
        if let space = tail.lastIndex(of: " ") { return text.index(after: space) }
        return end
    }

    /// Up to `maxFindMatches` passages around `query` (any case), each with the offset to read from.
    static func passages(of query: String, in text: String) -> String {
        var found: [(offset: Int, passage: String)] = []
        var total = 0
        var searchStart = text.startIndex
        var counted = 0
        var countedIndex = text.startIndex
        while let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
            total += 1
            if found.count < maxFindMatches {
                counted += text.distance(from: countedIndex, to: range.lowerBound)
                countedIndex = range.lowerBound
                let from = text.index(range.lowerBound, offsetBy: -120, limitedBy: text.startIndex) ?? text.startIndex
                let to = text.index(range.upperBound, offsetBy: 180, limitedBy: text.endIndex) ?? text.endIndex
                let passage = text[from..<to].split(whereSeparator: \.isNewline).joined(separator: " ")
                found.append((max(counted - 120, 0), (from > text.startIndex ? "…" : "") + passage + (to < text.endIndex ? "…" : "")))
            }
            // The next match is looked for after this passage, so one paragraph does not fill the list.
            searchStart = text.index(range.upperBound, offsetBy: 180, limitedBy: text.endIndex) ?? text.endIndex
        }
        guard !found.isEmpty else { return "Nenhuma ocorrência de “\(query)” nesta página (\(text.count) caracteres)." }
        let lines = found.map { "• offset=\($0.offset): \($0.passage)" }
        return "Trechos com “\(query)” (\(found.count)\(total > found.count ? "+" : "")); leia um deles com offset:\n" + lines.joined(separator: "\n")
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host() else { return nil }
        return scheme + "://" + host + (url.port.map { ":\($0)" } ?? "")
    }

    // MARK: Errors

    static let tooLargeMessage = "O arquivo passa de \(maxDownloadBytes / 1_000_000) MB, o limite do save_to. Se o Orb tiver o Terminal, baixe com run_command (curl -L -o); senão, peça ao usuário para baixar."

    /// What an HTTP error status means for the model, with the address that answered it.
    static func statusMessage(_ status: Int, url: URL) -> String {
        let hint: String
        switch status {
        case 401, 403:
            hint = "O site exige login ou bloqueia leitores automáticos. Se o usuário já está logado nessa página, tente browser_tab (\"Controlar apps do Mac\"); senão, procure outra fonte."
        case 404, 410:
            hint = "A página não existe ou mudou de endereço; confira a URL."
        case 429:
            hint = "Muitas requisições a este site; espere um pouco antes de tentar de novo."
        case 500...599:
            hint = "Erro no servidor do site; tente de novo mais tarde ou use outra fonte."
        default:
            hint = ""
        }
        return "O site respondeu HTTP \(status) para \(url.absoluteString)." + (hint.isEmpty ? "" : " " + hint)
    }

    /// A network failure in Portuguese, with the host and what to do about it.
    static func explain(_ error: URLError, url: URL) -> ToolError {
        let host = url.host() ?? url.absoluteString
        switch error.code {
        case .appTransportSecurityRequiresSecureConnection:
            return ToolError("O macOS bloqueou \(host) por usar http:// sem criptografia. Tente o mesmo endereço com https://.")
        case .cannotFindHost, .dnsLookupFailed:
            return ToolError("O endereço \(host) não existe ou não foi encontrado; confira a grafia da URL.")
        case .timedOut:
            return ToolError("\(host) não respondeu a tempo (20 s). O site pode estar fora do ar ou lento; tente de novo mais tarde.")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
            return ToolError("O certificado de segurança de \(host) é inválido (vencido, autoassinado ou de outro site). O Orb não contorna isso: avise o usuário ou use outra fonte.")
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return ToolError("O Mac está sem conexão com a internet.")
        case .networkConnectionLost, .cannotConnectToHost:
            return ToolError("Não consegui conectar a \(host) (conexão recusada ou interrompida); tente de novo mais tarde.")
        case .unsupportedURL, .badURL:
            return ToolError("Endereço inválido: use uma URL http:// ou https://.")
        case .httpTooManyRedirects, .redirectToNonExistentLocation:
            return ToolError("\(host) redirecionou em círculos ou para um endereço que não existe.")
        default:
            return ToolError("Falha de rede ao acessar \(host): \(error.localizedDescription)")
        }
    }

    // MARK: Download

    /// Streams the body to a temporary file next to `target` and moves it into place, so a failed or oversized
    /// download never leaves a half-written file behind. Returns the size in bytes.
    private static func download(_ bytes: URLSession.AsyncBytes, to target: URL) async throws -> Int {
        let destination = target.resolvingLinkChain
        guard !destination.isExistingDirectory else { throw ToolError("\(destination.path) é uma pasta; informe o nome do arquivo em save_to.") }
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appending(path: ".orb-download-\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: nil) else { throw ToolError("Não consegui gravar em \(destination.path).") }
        var completed = false
        defer { if !completed { try? manager.removeItem(at: temporary) } }

        let handle = try FileHandle(forWritingTo: temporary)
        var buffer = Data()
        var total = 0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 65_536 {
                    total += buffer.count
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if total + buffer.count > maxDownloadBytes {
                    throw ToolError(tooLargeMessage)
                }
            }
            total += buffer.count
            try handle.write(contentsOf: buffer)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
        completed = true
        return total
    }
}

/// The last few pages `web_fetch` converted, for a few minutes: reading a long page in pieces (`offset`) or searching
/// it (`find`) does not download and convert it again for every piece, and the pieces stay consistent with each other.
actor WebPageCache {
    static let shared = WebPageCache()

    struct Entry: Sendable {
        var header: String
        var text: String
        var truncatedDownload: Int?
        var date = Date()

        /// What the model gets: the header, then the page from `offset`, or the passages around `find`.
        func render(arguments: JSONValue, find: String?) -> String {
            let body = find.map { WebFetchTool.passages(of: $0, in: text) }
                ?? WebFetchTool.page(of: text, arguments: arguments, truncatedDownload: truncatedDownload)
            return header + "\n\n" + body
        }
    }

    static let capacity = 8
    static let lifetime: TimeInterval = 600
    /// A page bigger than this is not kept (the cache must stay small).
    static let largestText = 3_000_000

    private var entries: [(address: String, entry: Entry)] = []

    func entry(for address: String, now: Date = Date()) -> Entry? {
        entries.removeAll { now.timeIntervalSince($0.entry.date) > Self.lifetime }
        guard let index = entries.firstIndex(where: { $0.address == address }) else { return nil }
        let found = entries.remove(at: index)
        entries.append(found)   // most recently used last
        return found.entry
    }

    func store(_ entry: Entry, for address: String) {
        entries.removeAll { $0.address == address }
        guard entry.text.utf8.count <= Self.largestText else { return }
        entries.append((address, entry))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    func clear() { entries.removeAll() }
}

extension ToolBox {
    static let webTools: [any AgentTool] = [WebFetchTool()]
}
