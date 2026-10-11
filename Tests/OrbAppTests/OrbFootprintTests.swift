import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Orb

struct OrbFootprintTests {
    private static let orbs = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/Orb/Resources/Orbs")

    /// What an image covers, measured as the table was: alpha over 0.08, in fractions of the Orb's size.
    private static func measure(_ url: URL) throws -> CGRect? {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drawn)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where Double(pixels[(y * width + x) * 4 + 3]) / 255 > 0.08 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let unit = Double(width) / OrbGeometry.imageScale, margin = (OrbGeometry.imageScale - 1) / 2 * unit
        func fraction(_ pixel: Int) -> Double { (Double(pixel) - margin) / unit }
        return CGRect(x: fraction(minX), y: fraction(minY), width: fraction(maxX + 1) - fraction(minX),
                      height: fraction(maxY + 1) - fraction(minY))
    }

    /// Every hair and accessory image is in the table, as it measures (a new or redrawn one needs its line).
    @Test func theTableMatchesTheImages() throws {
        var seen = Set<String>()
        for folder in ["hair", "accessories"] {
            let files = try FileManager.default.contentsOfDirectory(at: Self.orbs.appending(path: folder), includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "png" && !file.lastPathComponent.contains("-brilho") {
                let key = "\(folder)/\(file.deletingPathExtension().lastPathComponent)"
                seen.insert(key)
                let listed = try #require(OrbFootprint.reach[key], "\(key) is missing from OrbFootprint.reach")
                let measured = try #require(try Self.measure(file))
                for (a, b) in [(listed.minX, measured.minX), (listed.minY, measured.minY), (listed.maxX, measured.maxX), (listed.maxY, measured.maxY)] {
                    #expect(abs(a - b) < 0.01, "\(key): \(listed) vs \(measured)")
                }
            }
        }
        #expect(Set(OrbFootprint.reach.keys) == seen)
    }

    @Test func aPlainOrbKeepsItsSize() {
        let fit = OrbFootprint.fit(OrbConfig(color: "cereja"))
        #expect(fit.scale == 1)
        #expect(fit.offset == .zero)
        // Glasses and a small cap stay within the allowance too.
        var glasses = OrbConfig(color: "cereja")
        glasses.accessories = ["oculos-redondos"]
        #expect(OrbFootprint.fit(glasses).scale == 1)
    }

    @Test func aBigHairShrinksAndCentersTheLook() {
        var afro = OrbConfig(color: "cereja")
        afro.hair = "black-power"
        let extent = OrbFootprint.extent(of: afro)
        #expect(extent.minY < -0.3 && extent.minX < -0.2 && extent.maxX > 1.2)
        let fit = OrbFootprint.fit(afro)
        #expect(fit.scale < 0.75 && fit.scale > 0.65)
        // The whole look, scaled and moved, lands inside the box (within the allowance).
        let slack = (OrbFootprint.allowance - 1) / 2 + 0.001
        let center = CGPoint(x: 0.5 + fit.offset.width, y: 0.5 + fit.offset.height)
        let origin = CGPoint(x: center.x - fit.scale / 2, y: center.y - fit.scale / 2)
        let placed = CGRect(x: origin.x + extent.minX * fit.scale, y: origin.y + extent.minY * fit.scale,
                            width: extent.width * fit.scale, height: extent.height * fit.scale)
        #expect(placed.minX >= -slack && placed.maxX <= 1 + slack)
        #expect(placed.minY >= -slack && placed.maxY <= 1 + slack)
        // The hair is on top, so the Orb itself goes down.
        #expect(fit.offset.height > 0)
    }

    @Test func aTallHatCounts() {
        var hat = OrbConfig(color: "cereja")
        hat.accessories = ["cartola"]
        #expect(OrbFootprint.fit(hat).scale < 1)
        #expect(OrbFootprint.fit(hat).offset.height > 0)
    }
}
