import AppKit
import Foundation
import Testing
@testable import Orb

/// The app icon is drawn by the app (`AppIcon`): the grid, the sizes, the ring and the small variant without it.
@Suite @MainActor struct AppIconTests {
    /// The full-size icon, drawn once for the tests that read it.
    private static let full = AppIcon.image(pixels: 1024)

    /// Premultiplied RGBA bytes of an image, redrawn into sRGB.
    nonisolated private func bytes(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    nonisolated private func pixel(_ data: [UInt8], width: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }

    @Test func theCanvasKeepsTheMacOSMarginAndTheTileIsSolid() {
        let data = bytes(Self.full)
        #expect(pixel(data, width: 1024, x: 0, y: 0).a == 0)
        #expect(pixel(data, width: 1024, x: 1023, y: 1023).a == 0)
        #expect(pixel(data, width: 1024, x: 512, y: 110).a == 255)
        #expect(pixel(data, width: 1024, x: 110, y: 512).a == 255)
        // The squircle's corner is cut: the tile's own corner point is empty, the margin below it holds only shadow.
        #expect(pixel(data, width: 1024, x: 104, y: 104).a < 40)
        // The shadow falls inside the 100 px margin, below the tile and not above it.
        let below = pixel(data, width: 1024, x: 512, y: 940).a, above = pixel(data, width: 1024, x: 512, y: 90).a
        #expect(below > 0 && below < 120)
        #expect(above < below)
        #expect(pixel(data, width: 1024, x: 512, y: 1020).a == 0)
    }

    @Test func theTileIsGraphiteTheOrbIndigoAndTheRingCrossesIt() {
        let data = bytes(Self.full)
        func brightness(_ x: Int, _ y: Int) -> Int { let p = pixel(data, width: 1024, x: x, y: y); return p.r + p.g + p.b }
        // A dark tile, flat to its corners: no glass, no glow.
        for (x, y) in [(170, 170), (854, 170), (170, 854), (854, 854)] { #expect(brightness(x, y) < 3 * 30, "(\(x), \(y))") }
        // The Orb (500 wide, at the center) is indigo, the same at its top and bottom: flat, no gel.
        let top = pixel(data, width: 1024, x: 512, y: 300), bottom = pixel(data, width: 1024, x: 512, y: 720)
        #expect(top.b > 200 && top.r < 100)
        #expect(top.r == bottom.r && top.g == bottom.g && top.b == bottom.b)
        // The front of the ring, outside the Orb on the lower left, is white; at its left end it has turned toward the
        // back's grey, gradually: lighter than the tile, darker than the front.
        let front = brightness(252, 671), end = brightness(192, 632)
        #expect(front > 3 * 240)
        #expect(end > 3 * 100 && end < front - 3 * 40)
    }

    @Test func itDrawsEverySizeTheBundleNeeds() {
        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            let image = pixels == 1024 ? Self.full : AppIcon.image(pixels: pixels)
            #expect(image.width == pixels && image.height == pixels)
        }
    }

    @Test func theSmallVariantStillShowsTheFace() {
        // At 16 px (the Orb alone, 600 wide at (512, 516)) the pixel of an eye is lighter than the body next to it.
        let data = bytes(AppIcon.image(pixels: 16))
        func brightness(_ x: Int, _ y: Int) -> Int { let p = pixel(data, width: 16, x: x, y: y); return p.r + p.g + p.b }
        // Eyes sit at x = 512 ± 0.155·600 ≈ ±93 of 1024, y = 516 - 0.07·600 ≈ 474 of 1024.
        let eyeX = Int((512.0 - 93) / 64), eyeY = Int(474.0 / 64)
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
}
