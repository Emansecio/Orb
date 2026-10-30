import SwiftUI
import ImageIO

/// A small preview of a picture file, for the composer and the transcript. A file that cannot be read (a conversation
/// can outlive it) shows a warning mark instead of the picture.
struct ImageThumbnail: View {
    let path: String
    var size: CGSize
    /// The side the cached copy is decoded for. The grid of the chat shows one copy at every size (`Thumbnails.gridSide`).
    var decodeSide: CGFloat
    @State private var image: NSImage?
    /// Nothing could be decoded: the file is gone or is not a picture.
    @State private var failed = false

    /// Starts with the picture when it is already decoded (it was seen, or warmed up), so a row that scrolls back
    /// into view or a bubble that comes in with its photo never shows the placeholder first.
    init(path: String, size: CGSize, decodeSide: CGFloat = Thumbnails.gridSide) {
        self.path = path
        self.size = size
        self.decodeSide = decodeSide
        _image = State(initialValue: Thumbnails.cached(path: path, side: decodeSide))
    }

    init(path: String, side: CGFloat = 56) {
        self.init(path: path, size: CGSize(width: side, height: side), decodeSide: side)
    }

    var body: some View {
        ZStack {
            Palette.raised
            // Gone once the picture is there (it would show through a dimmed one).
            Image(systemName: failed ? "photo.badge.exclamationmark" : "photo").foregroundStyle(Palette.faint)
                .opacity(image == nil ? 1 : 0)
            if let image {
                // Arrives over the placeholder by fading (opacity alone, so it also holds under Reduce Motion).
                Image(nsImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: image != nil)
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: Radius.medium))
        .overlay { RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Palette.line) }
        .task(id: DecodeKey(path: path, side: decodeSide)) {
            // Born from the cache with this very picture: nothing to decode, and no second pass over the body.
            // (Compared with the cached copy of `path`, so a view reused for another path still loads it.)
            if let image, image === Thumbnails.cached(path: path, side: decodeSide) { return }
            let decoded = await Thumbnails.image(at: path, side: decodeSide)
            guard !Task.isCancelled else { return } // the view shows another picture now
            image = decoded
            failed = decoded == nil
        }
    }

    private struct DecodeKey: Hashable {
        let path: String
        let side: CGFloat
    }
}

enum Thumbnails {
    /// The side of the copy the chat's pictures share: the grid shows it at every size and the composer warms it up,
    /// so a picture is decoded once and a sent message comes in with it already there.
    static let gridSide = AttachmentLayout.gridWidth

    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        // And by memory: a conversation full of photos keeps the most recent ~64 MB of decoded copies.
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    private static func key(_ path: String, _ side: CGFloat) -> NSString { "\(path)#\(Int(side))" as NSString }

    /// The decoded copy when there is one, without reading anything from disk.
    static func cached(path: String, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(path, side))
    }

    /// A reduced copy (the stored picture can be 1568 px wide), decoded once per path and size and off the main
    /// thread, so a long conversation full of pictures does not stall its first render.
    static func image(at path: String, side: CGFloat) async -> NSImage? {
        if let cached = cached(path: path, side: side) { return cached }
        return await loader.image(at: path, side: side)
    }

    private static let loader = Loader()

    /// A picture can appear in the composer, transcript and output strip together. They share one decode, and a
    /// photo-heavy conversation cannot start an unbounded number of ImageIO jobs at once.
    private actor Loader {
        private var pending: [String: Task<NSImage?, Never>] = [:]
        private let gate = AsyncGate(limit: 2)

        func image(at path: String, side: CGFloat) async -> NSImage? {
            let key = Thumbnails.key(path, side)
            if let image = cache.object(forKey: key) { return image }
            if let task = pending[key as String] { return await task.value }
            let task = Task.detached(priority: .userInitiated) { [gate] in
                try? await gate.run { decode(path: path, side: side) }
            }
            pending[key as String] = task
            let image = await task.value
            if let image { cache.setObject(image, forKey: key, cost: cost(of: image)) }
            pending[key as String] = nil
            return image
        }
    }

    /// The bytes of the decoded bitmap (4 per pixel).
    static func cost(of image: NSImage) -> Int {
        image.representations.first.map { $0.pixelsWide * $0.pixelsHigh * 4 } ?? 0
    }

    private static func decode(path: String, side: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(side * 2),
        ]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}
