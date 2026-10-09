import AppKit
import Foundation
import Testing
@testable import Orb

/// The app icon is drawn by the app (`AppIcon`): the grid, the sizes, the small variant, and the gel shader against the art.
@Suite @MainActor struct AppIconTests {
    /// Premultiplied RGBA bytes of an image, redrawn into sRGB.
    private func bytes(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    private func pixel(_ data: [UInt8], width: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }

    @Test func theCanvasKeepsTheMacOSMarginAndTheTileIsSolid() {
        let image = AppIcon.image(pixels: 1024)
        let data = bytes(image)
        #expect(pixel(data, width: 1024, x: 0, y: 0).a == 0)
        #expect(pixel(data, width: 1024, x: 1023, y: 1023).a == 0)
        #expect(pixel(data, width: 1024, x: 512, y: 150).a == 255)
        #expect(pixel(data, width: 1024, x: 140, y: 512).a == 255)
        // The squircle's corner is cut: the tile's own corner point is empty, the margin below it holds only shadow.
        #expect(pixel(data, width: 1024, x: 104, y: 104).a < 40)
        // The shadow falls inside the 100 px margin, below the tile and not above it.
        let below = pixel(data, width: 1024, x: 512, y: 940).a, above = pixel(data, width: 1024, x: 512, y: 90).a
        #expect(below > 0 && below < 120)
        #expect(above < below)
        #expect(pixel(data, width: 1024, x: 512, y: 1020).a == 0)
    }

    @Test func itDrawsEverySizeTheBundleNeeds() {
        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            let image = AppIcon.image(pixels: pixels)
            #expect(image.width == pixels && image.height == pixels)
        }
    }

    @Test func theSmallVariantStillShowsTheFace() {
        // At 16 px (the small variant, no smile) the pixel of an eye is lighter than the body next to it.
        let data = bytes(AppIcon.image(pixels: 16))
        func brightness(_ x: Int, _ y: Int) -> Int { let p = pixel(data, width: 16, x: x, y: y); return p.r + p.g + p.b }
        // Eyes sit at x = 512 ± 0.151·1.12·640 ≈ ±108 of 1024, y = 500 - 320 + 0.42·640 ≈ 449 of 1024.
        let eyeX = Int((512.0 - 108) / 64), eyeY = Int(449.0 / 64)
        #expect(brightness(eyeX, eyeY) > brightness(8, 10) + 40)
        // And the icon is not a flat square: the middle of the tile is the opaque Orb.
        #expect(pixel(data, width: 16, x: 8, y: 8).a == 255)
    }

    @Test func thePathWritesAPNGOfTheRightSize() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "orb-icon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        AppIcon.render(to: url, pixels: 128)
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        #expect(rep.pixelsWide == 128 && rep.pixelsHigh == 128)
    }

    @Test func theGelShaderMatchesTheArtOfTheBrandOrb() throws {
        // Same frame as art/orbgen: 640 px, centered, x radius 168.5 px.
        let hexes = OrbCatalog.shared.palette("indigo").hexes
        let mine = GelShader(hexes: hexes).pixels(side: 640, center: 320, scale: 168.5)
        let art = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Orb/Resources/Orbs/body/indigo.png")
        let source = try #require(CGImageSourceCreateWithURL(art as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 640)
        let reference = bytes(image)
        var total = 0, count = 0
        for i in stride(from: 0, to: mine.count, by: 4) where mine[i + 3] > 0 || reference[i + 3] > 0 {
            for channel in 0..<4 { total += abs(Int(mine[i + channel]) - Int(reference[i + channel])) }
            count += 4
        }
        #expect(count > 0)
        #expect(Double(total) / Double(count) < 3)
    }
}
