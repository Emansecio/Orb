import Foundation

// What the chat shows of an attachment: how a message's attachments split and lay out, and what a file card says of
// one file. Plain values, no views, so the tests can read them (the views are in `AttachmentViews`).

/// A file the Orb created or changed while working, kept on the tool call that did it (`ToolCall.files`).
struct ProducedFile: Codable, Hashable, Sendable {
    /// The full path, as the tool resolved it.
    var path: String
    /// The file did not exist before ("novo"); otherwise it was changed ("alterado").
    var created: Bool
}

enum AttachmentLayout {
    /// The width of the pictures' grid.
    static let gridWidth: CGFloat = 232
    /// At most this many files show as cards; a line says how many more.
    static let fileLimit = 4

    /// How the pictures of a message are laid out: columns of `cell`-sized tiles, `visible` of them (the last one says
    /// "+N" when `overflow` pictures do not fit).
    struct GridPlan: Equatable {
        var columns: Int
        var cell: CGSize
        var spacing: CGFloat
        var visible: Int
        var overflow: Int
    }

    /// One picture is wide, two are squares side by side, three or more fill three columns, nine at most.
    static func grid(count: Int) -> GridPlan {
        switch count {
        case ...0: GridPlan(columns: 1, cell: .zero, spacing: 0, visible: 0, overflow: 0)
        case 1: GridPlan(columns: 1, cell: CGSize(width: gridWidth, height: 160), spacing: 4, visible: 1, overflow: 0)
        case 2: GridPlan(columns: 2, cell: CGSize(width: 114, height: 114), spacing: 4, visible: 2, overflow: 0)
        default: GridPlan(columns: 3, cell: CGSize(width: 74, height: 74), spacing: 4, visible: min(count, 9), overflow: max(count - 9, 0))
        }
    }

    /// A message's attachments by how the chat shows them: pictures in a grid and the rest as file cards. A name
    /// without a path (older conversations) cannot be shown as a picture.
    static func split(_ paths: [String]) -> (images: [String], files: [String]) {
        var images: [String] = []
        var files: [String] = []
        for path in paths {
            if path.hasPrefix("/"), ImageProcessing.isImageFile(URL(fileURLWithPath: path)) {
                images.append(path)
            } else {
                files.append(path)
            }
        }
        return (images, files)
    }
}

/// What a file card says of a file. `quick` knows it without touching the disk; `load` adds the size and whether the
/// file is still there.
struct AttachmentInfo: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ok
        /// The file is gone (a conversation can outlive it).
        case missing
        /// Older conversations kept only the file name: there is nothing to open.
        case legacy
    }

    var name: String
    /// "PDF"; empty when the name has none.
    var ext: String
    var size: Int?
    /// An SF Symbol for the type of file.
    var symbol: String
    var state: State

    /// The card's second line: "PDF · 2,1 MB", or why there is nothing to open.
    var caption: String {
        switch state {
        case .missing: "Arquivo não está mais aqui"
        case .legacy: "Anexo antigo · sem local salvo"
        case .ok: [ext.isEmpty ? nil : ext, AttachmentKind.size(size)].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// From the name alone.
    static func quick(path: String) -> AttachmentInfo {
        let url = URL(fileURLWithPath: path)
        return AttachmentInfo(name: url.lastPathComponent, ext: url.pathExtension.uppercased(), size: nil,
                              symbol: AttachmentKind.symbol(for: url), state: path.hasPrefix("/") ? .ok : .legacy)
    }

    /// What is known already (the card of a row that scrolls back into view is born complete), else `quick`.
    static func cachedOrQuick(_ path: String) -> AttachmentInfo {
        cache.object(forKey: path as NSString)?.info ?? quick(path: path)
    }

    /// Reads the size and looks for the file, off the main thread. A file already found is not read again (the cache
    /// serves it); one that was missing is looked for again, as it may have been written since.
    static func load(path: String) async -> AttachmentInfo {
        if let cached = cache.object(forKey: path as NSString)?.info, cached.state == .ok { return cached }
        let info = await Task.detached { read(path) }.value
        cache.setObject(Box(info), forKey: path as NSString)
        return info
    }

    static func read(_ path: String) -> AttachmentInfo {
        var info = quick(path: path)
        guard info.state == .ok else { return info }
        let values = try? URL(fileURLWithPath: path).resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values?.isRegularFile == true {
            info.size = values?.fileSize
        } else {
            info.state = .missing
        }
        return info
    }

    private final class Box: Sendable {
        let info: AttachmentInfo
        init(_ info: AttachmentInfo) { self.info = info }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 500
        return cache
    }()
}
