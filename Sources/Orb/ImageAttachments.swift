import Foundation
import ImageIO
import UniformTypeIdentifiers

// Pictures the Orb is shown: the user's attachments and what tools return (screenshots). A picture is decoded,
// shrunk and saved once, when it is attached; the conversation keeps only its path (`ImageAttachment`), and the
// bytes are read again each time a request is built.

// MARK: - Errors

enum ImageAttachmentError: LocalizedError, Equatable {
    case tooLarge(name: String, bytes: Int)
    case unreadable(name: String)
    case notSaved(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let name, let bytes):
            let megabytes = (Double(bytes) / 1_048_576 * 10).rounded() / 10
            return "A imagem “\(name)” tem \(megabytes.formatted(.number.precision(.fractionLength(0...1)))) MB; o limite é "
                + "\(ImageProcessing.maxOriginalBytes / 1_048_576) MB. Reduza a imagem e tente de novo."
        case .unreadable(let name):
            return "Não consegui abrir “\(name)” como imagem. Os formatos aceitos são PNG, JPEG, HEIC, GIF, WebP e TIFF."
        case .notSaved(let detail):
            return "Não consegui guardar a imagem: \(detail)"
        }
    }
}

// MARK: - Decoding and shrinking

enum ImageProcessing {
    /// Longest side sent to a model; larger pictures are scaled down (providers shrink them anyway, and the
    /// request would only get heavier).
    static let maxSide = 1568
    static let maxOriginalBytes = 20 * 1_048_576
    static let jpegQuality = 0.85
    /// A picture with transparency stays PNG when that is no bigger than this; otherwise it becomes JPEG on white.
    static let pngKeepLimit = 1_000_000

    struct Prepared: Equatable {
        var data: Data
        var mediaType: String
        var fileExtension: String
        var width: Int
        var height: Int
    }

    /// Whether `url` names a picture ImageIO can read (SVG and PDF are files, not pictures, for this purpose).
    static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return false }
        return readable.contains { type.conforms(to: $0) }
    }

    private static let readable: [UTType] = {
        let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return identifiers.compactMap { UTType($0) }.filter { $0 != .image }
    }()

    /// The picture as it is sent: first frame, EXIF rotation applied, long side at most `maxSide`, JPEG at 0.85
    /// (PNG when it has real transparency and stays small).
    /// `enforcingLimit: false` is for pictures the app made itself (a screenshot of a large display), which are
    /// shrunk like any other but not refused for their size.
    static func prepare(_ original: Data, name: String, enforcingLimit: Bool = true) throws -> Prepared {
        guard !enforcingLimit || original.count <= maxOriginalBytes else { throw ImageAttachmentError.tooLarge(name: name, bytes: original.count) }
        guard let source = CGImageSourceCreateWithData(original as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw ImageAttachmentError.unreadable(name: name)
        }
        // The thumbnail call scales and applies the orientation in one pass; asking for the picture's own size
        // keeps a small one from being enlarged.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxSide, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageAttachmentError.unreadable(name: name)
        }

        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        if hasAlpha, hasTransparentPixels(image), let png = encode(image, as: .png, quality: nil), png.count <= pngKeepLimit {
            return Prepared(data: png, mediaType: "image/png", fileExtension: "png", width: image.width, height: image.height)
        }
        // JPEG has no alpha: transparent areas are flattened onto white instead of turning black.
        let flat = hasAlpha ? (flattened(image) ?? image) : image
        guard let jpeg = encode(flat, as: .jpeg, quality: jpegQuality) else { throw ImageAttachmentError.unreadable(name: name) }
        return Prepared(data: jpeg, mediaType: "image/jpeg", fileExtension: "jpg", width: flat.width, height: flat.height)
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func rgbaContext(width: Int, height: Int, alpha: CGImageAlphaInfo) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: alpha.rawValue)
    }

    /// True when some pixel is not fully opaque (many screenshots carry an alpha channel that is all 255).
    static func hasTransparentPixels(_ image: CGImage) -> Bool {
        guard let context = rgbaContext(width: image.width, height: image.height, alpha: .premultipliedLast),
              let base = context.data else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<context.height {
            let line = bytes + row * context.bytesPerRow
            for column in 0..<context.width where line[column * 4 + 3] < 255 { return true }
        }
        return false
    }

    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = rgbaContext(width: image.width, height: image.height, alpha: .noneSkipLast) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}

// MARK: - Store

/// The pictures kept for the Orbs: `<data folder>/anexos/<orb id>/<uuid>.jpg|png`. They stay as long as the Orb
/// does (the conversation points at them) and go with it.
struct ImageStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The store inside the app's data folder (`Store.directory`).
    init(dataFolder: URL) {
        self.init(directory: dataFolder.appending(path: "anexos"))
    }

    func folder(for botID: UUID) -> URL { directory.appending(path: botID.uuidString) }

    /// Reads, shrinks and saves the picture at `url`. Throws `ImageAttachmentError` (too big, not a picture).
    /// `enforcingLimit: false` skips the size limit meant for what the user attaches (see `ImageProcessing.prepare`).
    func add(fileAt url: URL, botID: UUID, enforcingLimit: Bool = true) throws -> ImageAttachment {
        let name = url.lastPathComponent
        // Looked at before reading, so a huge file is never loaded.
        if enforcingLimit, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > ImageProcessing.maxOriginalBytes {
            throw ImageAttachmentError.tooLarge(name: name, bytes: size)
        }
        guard let data = try? Data(contentsOf: url) else { throw ImageAttachmentError.unreadable(name: name) }
        return try add(data, name: name, botID: botID, enforcingLimit: enforcingLimit)
    }

    /// Same for bytes already in memory (a picture pasted from the clipboard, a screenshot).
    func add(_ data: Data, name: String, botID: UUID, enforcingLimit: Bool = true) throws -> ImageAttachment {
        let prepared = try ImageProcessing.prepare(data, name: name, enforcingLimit: enforcingLimit)
        let folder = folder(for: botID)
        let file = folder.appending(path: "\(UUID().uuidString).\(prepared.fileExtension)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try prepared.data.write(to: file, options: .atomic)
        } catch {
            throw ImageAttachmentError.notSaved(error.localizedDescription)
        }
        return ImageAttachment(path: file.path, mediaType: prepared.mediaType, width: prepared.width, height: prepared.height)
    }

    /// `add(fileAt:)` off the caller's thread (decoding a large photo takes a moment).
    func attach(fileAt url: URL, botID: UUID, enforcingLimit: Bool = true) async throws -> ImageAttachment {
        try await Task.detached { try self.add(fileAt: url, botID: botID, enforcingLimit: enforcingLimit) }.value
    }

    func attach(_ data: Data, name: String, botID: UUID) async throws -> ImageAttachment {
        try await Task.detached { try self.add(data, name: name, botID: botID) }.value
    }

    /// Deletes a saved picture (one attached and then removed before sending). Files outside the store are never touched.
    func remove(_ image: ImageAttachment) {
        let file = URL(fileURLWithPath: image.path).standardizedFileURL
        guard file.path.hasPrefix(directory.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Deletes every picture of an Orb (when the Orb is deleted).
    func deleteAll(for botID: UUID) {
        try? FileManager.default.removeItem(at: folder(for: botID))
    }
}

// MARK: - On the wire

enum ImageWire {
    /// The text and picture data of a message as the clients send them. A picture whose file is gone becomes a
    /// line of text, so a deleted file never fails the whole request.
    static func payload(of message: ChatMessage) -> (text: String, images: [(mediaType: String, base64: String)]) {
        var text = message.content
        var images: [(mediaType: String, base64: String)] = []
        for image in message.images {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: image.path)), !data.isEmpty {
                images.append((image.mediaType, data.base64EncodedString()))
            } else {
                text += (text.isEmpty ? "" : "\n") + "[imagem indisponível: \(image.path)]"
            }
        }
        return (text, images)
    }

    static func dataURL(mediaType: String, base64: String) -> String { "data:\(mediaType);base64,\(base64)" }
}

extension ChatMessage {
    /// The message with its pictures replaced by one line of text each (`note` says what to write for a picture).
    func replacingImages(with note: (ImageAttachment) -> String) -> ChatMessage {
        guard !images.isEmpty else { return self }
        var copy = self
        copy.content += (content.isEmpty ? "" : "\n") + images.map(note).joined(separator: "\n")
        copy.images = []
        return copy
    }
}

extension [ChatMessage] {
    /// For a model that cannot see pictures (or answered that it cannot): they become their paths.
    func strippingImages() -> [ChatMessage] {
        map { $0.replacingImages { "[imagem: \($0.path) — este modelo não aceita imagens]" } }
    }

    /// For formats whose tool messages carry text only (chat completions, Responses): the pictures a tool returned
    /// go in a user message of their own after the run of tool messages they belong to (the API wants the results
    /// of one assistant turn together).
    func movingToolImagesToUserMessages() -> [ChatMessage] {
        guard contains(where: { $0.role == .tool && !$0.images.isEmpty }) else { return self }
        var names: [String: String] = [:]
        var result: [ChatMessage] = []
        var pending: [ChatMessage] = []
        for var message in self {
            if message.role != .tool {
                result += pending
                pending = []
            }
            if message.role == .assistant {
                for call in message.toolCalls { names[call.id] = call.name }
            }
            if message.role == .tool, !message.images.isEmpty {
                let name = message.toolCallID.flatMap { names[$0] } ?? "tool"
                pending.append(.user("Image returned by the previous tool call (\(name)).", images: message.images))
                message.images = []
            }
            result.append(message)
        }
        return result + pending
    }
}

// MARK: - A model that does not take pictures

enum ImageRejection {
    static let notice = "Este modelo não vê imagens; mandei só o caminho do arquivo."

    /// Wording of "this model cannot take pictures". A bare "image" is not enough: a 400 about one picture being too
    /// big, or a gateway echoing the message, says "image" too and must not mark the model as blind.
    private static let phrases = ["image_url", "image input", "image content", "images are not", "image is not supported",
                                  "images is not", "support image", "supports image", "support for image", "accept image",
                                  "accepts image", "vision", "multimodal", "multi-modal"]

    /// The provider refused the request because of the pictures in it (a model without vision answers with an HTTP
    /// 400 or an error event that mentions images, vision or multimodal input).
    static func matches(_ error: Error) -> Bool {
        let message: String
        switch error {
        case LLMError.http(let status, let text, _) where [400, 404, 415, 422].contains(status): message = text
        case LLMError.invalidResponse(let text): message = text
        case LLMError.stream(_, let text): message = text
        default: return false
        }
        let text = message.lowercased()
        return phrases.contains { text.contains($0) }
    }
}
