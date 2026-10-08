import SwiftUI
import ImageIO

/// A small preview of a picture file, for the composer and the transcript. Falls back to an icon when the file is
/// gone (a conversation can outlive the file it points at).
struct ImageThumbnail: View {
    let path: String
    var side: CGFloat = 56
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Palette.raised
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(Palette.faint)
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line) }
        .task(id: path) { image = await Thumbnails.image(at: path, side: side) }
    }
}

enum Thumbnails {
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    /// A reduced copy (the stored picture can be 1568 px wide), decoded once per path and size and off the main
    /// thread, so a long conversation full of pictures does not stall its first render.
    static func image(at path: String, side: CGFloat) async -> NSImage? {
        let key = "\(path)#\(Int(side))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached { decode(path: path, side: side) }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private static func decode(path: String, side: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(side * 2),
        ]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}
