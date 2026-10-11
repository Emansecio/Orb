import Foundation

// The text of the files attached to a message goes with it, so any Orb reads a PDF, a Word document, a spreadsheet
// or a CSV it was handed, with its file tools or without them. What does not fit (or cannot be read here: a zip, a
// binary) is left to the tools, and the message says so.

enum AttachmentText {
    /// What one file may put in a message: a page of `read_file`, so what is cut continues where a read would.
    static let perFile = DocumentReader.maxCharacters
    /// What all the files of one message may put in it together.
    static let total = 3 * DocumentReader.maxCharacters
    /// Text files above this are not opened here (the tools page through them).
    static let maxTextBytes = 20_000_000
    /// Documents above this are not converted here.
    static let maxDocumentBytes = 100_000_000

    /// Where the contents start in a stored message: what reads the user's words back (`TurnPrompt.userWords`) stops here.
    static let contentsMarker = "\n\n<attached_file "

    /// What a file gave: its text (whole or cut), or why there is none.
    enum Extracted: Equatable, Sendable {
        case text(String, kind: String)
        /// Not a kind read here, or too large to open: the tools can.
        case unread
        case failed(String)
    }

    /// The text of the file at `url`, read now (call it off the main thread: a long PDF takes a moment).
    static func extract(_ url: URL) -> Extracted {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let isDocument = DocumentReader.isPDF(url) || DocumentReader.isDocument(url) || OfficeReader.isOffice(url)
        guard size <= (isDocument ? maxDocumentBytes : maxTextBytes) else { return .unread }
        do {
            if DocumentReader.isPDF(url) {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                return .text(try DocumentReader.pdfText(data, pages: nil), kind: "PDF")
            }
            if DocumentReader.isDocument(url) {
                return .text(try DocumentReader.documentText(at: url), kind: "documento .\(url.pathExtension.lowercased()) convertido em texto")
            }
            if OfficeReader.isOffice(url) {
                return .text(try OfficeReader.text(at: url), kind: "documento .\(url.pathExtension.lowercased()) convertido em texto")
            }
            guard !ImageProcessing.isImageFile(url), !DocumentReader.isImage(url) else { return .unread }
            // Only as much as could be sent (UTF-8 at most 4 bytes a character), so a long log is not read whole; a
            // read cut short ends at its last whole line, never inside a character.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = try handle.read(upToCount: perFile * 4) ?? Data()
            let isPartial = data.count < size
            if isPartial, let newline = data.lastIndex(of: 0x0A) { data = data[..<newline] }
            guard let file = TextFile.decode(data) else { return .unread }
            return .text(isPartial ? file.text + "\n" + cutMark : file.text, kind: "texto")
        } catch let error as ToolError {
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Ends a text read only in part (the cut itself is placed by `block`).
    private static let cutMark = "\u{1}cut"

    /// The part of a stored message after the user's words: the list of files, then each one's text. `texts` has what
    /// was read for each file (missing: not read yet, left to the tools). `room`: what the contents may take altogether.
    static func block(for urls: [URL], texts: [URL: Extracted], room: Int = total) -> String {
        guard !urls.isEmpty else { return "" }
        var output = "\n\nAttached files (each one's text is below; read with your tools whatever was cut or left out):\n"
            + urls.map { "- \($0.path)" }.joined(separator: "\n")
        var left = max(0, room)
        for url in urls {
            var body: String
            var kindLabel: String?
            switch texts[url] {
            case .text(var text, let kind)?:
                let wasCut = text.hasSuffix(cutMark)
                if wasCut { text.removeLast(cutMark.count + 1) }
                let fits = min(perFile, left)
                if text.isEmpty {
                    body = "(empty)"
                    kindLabel = kind
                } else if fits < 200 {
                    body = "(not included: no room left in this message; read it with your tools)"
                } else if text.count > fits || wasCut {
                    let kept = String(text.prefix(fits))
                    let rest = DocumentReader.isPDF(url) ? "read_file with `pages`"
                        : "read_file, offset=\(max(1, TextFile.lines(of: kept).count))"
                    body = kept + "\n[... cut here; read the rest with \(rest)]"
                    left -= kept.count
                    kindLabel = kind + ", cut"
                } else {
                    body = text
                    left -= text.count
                    kindLabel = kind
                }
            case .failed(let reason)?:
                body = "(could not be read here: \(reason))"
            case .unread?, nil:
                body = "(not read here: read it with your tools)"
            }
            let kindAttribute = kindLabel.map { " kind=\"\($0)\"" } ?? ""
            output += contentsMarker + "path=\"\(url.path)\"\(kindAttribute)>\n" + body + "\n</attached_file>"
        }
        return output
    }

    /// What a block takes in a message before it is read: what is known, and a page for each file still being read.
    static func estimate(for urls: [URL], texts: [URL: Extracted], room: Int = total) -> Int {
        let known = urls.reduce(0) { sum, url in
            switch texts[url] {
            case .text(let text, _)?: sum + min(text.count, perFile)
            case nil: sum + perFile
            default: sum + 100
            }
        }
        return min(known, max(0, room)) + urls.count * 200
    }

    /// The room for attachments in a request whose history budget is `historyCharacters`: a third of it at most, so a
    /// small local model still has room for the conversation.
    static func room(historyCharacters: Int) -> Int {
        min(total, max(4_000, historyCharacters / 3))
    }
}

/// The text of the files attached in the composer, read in the background as they are attached, so the message that
/// takes them goes at once. A file changed since (size or date) is read again.
@MainActor
final class AttachmentTextCache {
    private struct Key: Hashable {
        let path: String
        let size: Int
        let modified: Date?

        init(_ url: URL) {
            // From the disk each time: a `URL` keeps the resource values it read once, and the file may have changed since.
            path = url.standardizedFileURL.path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
            modified = attributes?[.modificationDate] as? Date
        }
    }

    /// Files whose text is kept: older ones are read again if they are sent after all.
    static let capacity = 24

    private var done: [Key: AttachmentText.Extracted] = [:]
    private var order: [Key] = []
    private var reading: [Key: Task<AttachmentText.Extracted, Never>] = [:]

    /// Starts reading `url` if it is not read yet.
    func prepare(_ url: URL) {
        _ = task(for: Key(url))
    }

    /// What is already read, without waiting.
    func cached(_ urls: [URL]) -> [URL: AttachmentText.Extracted] {
        var found: [URL: AttachmentText.Extracted] = [:]
        for url in urls { if let text = done[Key(url)] { found[url] = text } }
        return found
    }

    /// The text of each file, waiting for what is still being read.
    func texts(_ urls: [URL]) async -> [URL: AttachmentText.Extracted] {
        var found: [URL: AttachmentText.Extracted] = [:]
        for url in urls {
            let key = Key(url)
            if let text = done[key] {
                found[url] = text
            } else {
                let text = await task(for: key, url: url).value
                keep(text, for: key)
                found[url] = text
            }
        }
        return found
    }

    private func task(for key: Key, url: URL? = nil) -> Task<AttachmentText.Extracted, Never> {
        if let text = done[key] { return Task { text } }
        if let running = reading[key] { return running }
        let file = url ?? URL(fileURLWithPath: key.path)
        let running = Task.detached(priority: .userInitiated) { AttachmentText.extract(file) }
        reading[key] = running
        Task { keep(await running.value, for: key) }
        return running
    }

    private func keep(_ text: AttachmentText.Extracted, for key: Key) {
        reading[key] = nil
        done[key] = text
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > Self.capacity { done[order.removeFirst()] = nil }
    }
}
