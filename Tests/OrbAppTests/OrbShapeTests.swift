import Foundation
import CoreGraphics
import Testing
@testable import Orb

/// Body shapes ("Formato"), the eyes' size and the look-change key: saved looks keep loading, a shape without art draws as
/// the circle, and the gradient map that recolors the greyscale shapes is well formed for every palette.
struct OrbShapeTests {
    private let catalog = OrbCatalog.shared
    /// A copy of the catalog's folder layout with `shape/seixo.png` present and the shape table carrying a face offset.
    private let folder = TempFolder("OrbShapes", creating: true)

    private func catalogWithArt() throws -> OrbCatalog {
        let source = try #require(catalog.root)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("options.json"))) as? [String: Any])
        var shapes = try #require(json["shape"] as? [[String: Any]])
        let index = try #require(shapes.firstIndex { $0["id"] as? String == "seixo" })
        shapes[index]["face"] = [0.02, 0.05]
        let wild = try #require(shapes.firstIndex { $0["id"] as? String == "gota" })
        shapes[wild]["face"] = [3, -3]
        json["shape"] = shapes
        try FileManager.default.createDirectory(at: folder.appending("shape"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: folder.appending("options.json"))
        // Only the file names are read when the catalog is built.
        try Data().write(to: folder.appending("shape/seixo.png"))
        return OrbCatalog(root: folder.url)
    }

    // MARK: Saved looks

    @Test func looksSavedBeforeShapesLoadAsCircles() throws {
        let old = try JSONDecoder().decode(OrbConfig.self, from: Data(#"{"color":"rosa","eyes":"ovais"}"#.utf8))
        #expect(old.shape == "circulo" && old.eyeScale == 1)
        #expect(old.layers().first?.path == "body/rosa")
        #expect(old.layers().first?.recolor == nil)
        let new = try JSONDecoder().decode(OrbConfig.self, from: Data(#"{"color":"rosa","shape":"nuvem","eyeScale":1.25}"#.utf8))
        #expect(new.shape == "nuvem" && new.eyeScale == 1.25)
        #expect(try JSONDecoder().decode(OrbConfig.self, from: JSONEncoder().encode(new)) == new)
    }

    @Test func anUnknownShapeDrawsAsTheCircleButStaysSaved() throws {
        let config = try JSONDecoder().decode(OrbConfig.self, from: Data(#"{"color":"menta","shape":"estrela"}"#.utf8))
        #expect(!catalog.knows(config))
        #expect(config.migrated(in: catalog).shape == "circulo")
        #expect(config.layers().first == OrbLayer(kind: .body, path: "body/menta"))
        #expect(config.shape == "estrela")
        #expect(config.faceOffset == .zero)
    }

    @Test func theCatalogOffersTheEightShapesInOrder() {
        #expect(catalog.options(.shape).map(\.id) == ["circulo", "seixo", "almofada", "capsula", "triangulo", "hexagono", "nuvem", "gota"])
        #expect(catalog.label(.shape, "capsula") == "Cápsula")
        #expect(OrbCategory.shape.label == "Formato")
    }

    @Test func theSummaryNamesAShapeOnlyWhenItIsNotTheCircle() {
        var config = OrbConfig()
        #expect(!config.summary.contains("formato"))
        config.shape = "nuvem"
        #expect(config.summary == "Índigo, formato Nuvem, olhos Pílulas")
    }

    // MARK: Layers

    @Test func aShapeWithArtDrawsItsGreyscaleImageRecoloredAndWithoutArtTheCircle() throws {
        let withArt = try catalogWithArt()
        var look = OrbConfig(color: "menta")
        look.shape = "seixo"
        let body = try #require(look.layers(in: withArt).first)
        #expect(body.kind == .body && body.path == "shape/seixo" && body.recolor == "menta")
        // The same look in a catalog without that art (the real one for now) draws the palette's own body.
        look.shape = "gota"
        #expect(look.layers(in: withArt).first == OrbLayer(kind: .body, path: "body/menta"))
        // A palette change keeps the image and changes only the recolor, so the plain decode is reused.
        look.shape = "seixo"
        look.color = "rosa"
        let other = try #require(look.layers(in: withArt).first)
        #expect(other.path == body.path && other.recolor == "rosa" && other.id != body.id)
        // The circle never uses shape art.
        look.shape = "circulo"
        #expect(look.layers(in: withArt).first?.path == "body/rosa")
    }

    @Test func aRecoloredLayerHasItsOwnCacheKey() {
        let plain = OrbLayer(kind: .body, path: "body/indigo")
        let recolored = OrbLayer(kind: .body, path: "body/indigo", recolor: "indigo")
        #expect(plain.id != recolored.id && plain != recolored)
        // Same path, different palette: not found under the other's key (nothing is cached here, so both are nil).
        #expect(OrbImages.cached(recolored, pixels: 97) == nil)
    }

    @Test func faceOffsetsComeFromTheTableAndStayInside() throws {
        let withArt = try catalogWithArt()
        #expect(withArt.faceOffset(for: "seixo") == CGSize(width: 0.02, height: 0.05))
        #expect(withArt.faceOffset(for: "circulo") == .zero)
        #expect(withArt.faceOffset(for: "inexistente") == .zero)
        // A typo (3, -3) cannot throw the face out of the frame.
        #expect(withArt.faceOffset(for: "gota") == CGSize(width: 0.2, height: -0.2))
        // The shipped table: the circle's face stays where the layers were drawn; the others only move down, a little.
        #expect(catalog.faceOffset(for: "circulo") == .zero)
        #expect(catalog.options(.shape).allSatisfy {
            let offset = catalog.faceOffset(for: $0.id)
            return offset.width == 0 && (0...0.2).contains(offset.height)
        })
        #expect(catalog.faceOffset(for: "triangulo").height > 0)
    }

    // MARK: Eyes' size

    @Test func theEyesSizeIsDrawnWithinItsRange() {
        var look = OrbConfig()
        #expect(look.drawnEyeScale == 1)
        look.eyeScale = 0.1
        #expect(look.drawnEyeScale == 0.8)
        look.eyeScale = 9
        #expect(look.drawnEyeScale == 1.4)
        look.eyeScale = 1.15
        #expect(abs(look.drawnEyeScale - 1.15) < 1e-9)
        // The saved value is not rewritten by drawing.
        look.eyeScale = 9
        #expect(look.eyeScale == 9)
    }

    @Test func theEyesSizeAndTheTemperamentDoNotCountAsAChangeOfLook() {
        let base = OrbConfig(color: "menta", eyes: "ovais")
        var scaled = base
        scaled.eyeScale = 1.3
        scaled.temperament = .timido
        #expect(scaled.appearance == base.appearance)
        var recolored = base
        recolored.color = "rosa"
        #expect(recolored.appearance != base.appearance)
        var reshaped = base
        reshaped.shape = "nuvem"
        #expect(reshaped.appearance != base.appearance)
    }

    // MARK: Sortear

    @Test func randomLooksAlwaysHaveAKnownShape() {
        var rng = SeededRandom(seed: 7)
        for _ in 0..<400 {
            let look = OrbConfig.random(using: &rng)
            #expect(catalog.ids(.shape).contains(look.shape))
            #expect(look.eyeScale == 1)
        }
    }

    // MARK: Gradient map

    @Test func theGradientMapHitsItsStopsExactly() {
        // A plain table, so the interpolation is checked apart from the tuned numbers.
        let stops = [OrbRecolor.Stop(luminance: 0, deep: 0.25), OrbRecolor.Stop(luminance: 0.55, core: 1),
                     OrbRecolor.Stop(luminance: 1, rim: 1)]
        let hex = { (shift: UInt32, value: UInt32) in UInt8((value >> shift) & 0xFF) }
        for palette in catalog.palettes {
            let lut = OrbRecolor.lut(for: palette, stops: stops)
            #expect(lut.count == 256)
            #expect(lut[255].r == hex(16, palette.hexes[0]) && lut[255].g == hex(8, palette.hexes[0]) && lut[255].b == hex(0, palette.hexes[0]), "\(palette.id)")
            let core = lut[Int((0.55 * 255).rounded())]
            #expect(abs(Int(core.r) - Int(hex(16, palette.hexes[1]))) <= 3 && abs(Int(core.b) - Int(hex(0, palette.hexes[1]))) <= 3, "\(palette.id)")
        }
    }

    @Test func theShippedGradientRunsFromShadeToLitFur() {
        let brightness = { (c: (r: UInt8, g: UInt8, b: UInt8)) in 0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b) }
        let hex = { (shift: UInt32, value: UInt32) in UInt8((value >> shift) & 0xFF) }
        for palette in catalog.palettes {
            let lut = OrbRecolor.lut(for: palette)
            let deep = (r: hex(16, palette.hexes[2]), g: hex(8, palette.hexes[2]), b: hex(0, palette.hexes[2]))
            // The bottom is much darker than the deep color, and the lit tips are brighter than the shade.
            #expect(brightness(lut[0]) < brightness(deep) * 0.6, "\(palette.id)")
            #expect(brightness(lut[230]) > brightness(lut[100]), "\(palette.id)")
        }
    }

    @Test func theGradientMapNeverGetsDarkerWhereTheRenderGetsLighter() {
        // Brightness (not each channel: the hue moves between stops) must not fall by more than rounding as luminance rises
        // up to the core; past it the palette decides, so only the first stops are held to this.
        for palette in catalog.palettes {
            let lut = OrbRecolor.lut(for: palette)
            let brightness = { (c: (r: UInt8, g: UInt8, b: UInt8)) in 0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b) }
            for index in 1...Int(0.30 * 255) {
                #expect(brightness(lut[index]) >= brightness(lut[index - 1]) - 1.5, "\(palette.id) \(index)")
            }
        }
    }

    @Test func recoloringKeepsAlphaAndMapsLuminance() throws {
        // A 3 x 1 image: opaque dark grey, half-transparent light grey (premultiplied), and nothing.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: 3, height: 1, bitsPerComponent: 8, bytesPerRow: 12, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let raw = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let pixels: [UInt8] = [40, 40, 40, 255, 100, 100, 100, 128, 0, 0, 0, 0]
        for (i, v) in pixels.enumerated() { raw[i] = v }
        let image = try #require(context.makeImage())
        let palette = catalog.palette("indigo")
        let out = try #require(OrbRecolor.apply(to: image, palette: palette))
        let result = try #require(CGContext(data: nil, width: 3, height: 1, bitsPerComponent: 8, bytesPerRow: 12, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        result.draw(out, in: CGRect(x: 0, y: 0, width: 3, height: 1))
        let got = try #require(result.data).assumingMemoryBound(to: UInt8.self)
        let lut = OrbRecolor.lut(for: palette)
        // Opaque: exactly the table's color for luminance 40.
        #expect(got[3] == 255 && got[0] == lut[40].r && got[1] == lut[40].g && got[2] == lut[40].b)
        // Half transparent: alpha kept, color premultiplied again (luminance 100 / 128 * 255 = 199).
        #expect(got[7] == 128)
        let light = lut[199]
        #expect(abs(Int(got[4]) - Int(light.r) * 128 / 255) <= 1 && abs(Int(got[6]) - Int(light.b) * 128 / 255) <= 1)
        // Nothing stays nothing.
        #expect(got[8] == 0 && got[9] == 0 && got[10] == 0 && got[11] == 0)
    }

    @Test func aProposalMayChooseAShapeAndAnUnknownOneIsLeftOut() {
        let chosen = OrbProposal.look(from: .object(["shape": .string("nuvem")]))
        #expect(chosen.shape == "nuvem")
        let unknown = OrbProposal.look(from: .object(["shape": .string("<script>")]))
        #expect(catalog.ids(.shape).contains(unknown.shape))
        #expect(OrbProposeTool.looks.contains("shape"))
    }
}
