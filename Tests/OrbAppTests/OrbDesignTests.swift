import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import Orb

/// The redesigned art and motion: saved Orbs keep loading, every combination finds its images, hair follows the
/// body, and the one-shot reactions calm down.
struct OrbDesignTests {
    private let catalog = OrbCatalog.shared

    // MARK: Saved Orbs

    @Test func everyHairStyleSavedBeforeTheRedesignStillExists() throws {
        // The ids options.json had before: none may vanish (saved Orbs point at them).
        for id in ["nenhum", "topete", "tufinho", "franja", "cachos", "coque", "moicano", "antena"] {
            #expect(catalog.options(.hair).contains { $0.id == id }, "\(id)")
            let json = #"{"color":"rosa","eyes":"ovais","hair":"\#(id)","hairColor":5913378,"accessories":["laco"]}"#
            let config = try JSONDecoder().decode(OrbConfig.self, from: Data(json.utf8))
            #expect(config.hair == id && config.hairColor == 0x5A3B22 && config.accessories == ["laco"])
        }
    }

    @Test func unknownOptionsDrawAsDefaultsButStaySaved() throws {
        // A look saved by a newer build: what this build doesn't know draws as the default…
        let json = #"{"color":"marte","eyes":"laser","mouth":"sorriso","hair":"careca-brilhante","accessories":["jetpack","laco"],"autoColors":2}"#
        let config = try JSONDecoder().decode(OrbConfig.self, from: Data(json.utf8))
        let paths = config.layers().map(\.path)
        #expect(paths.contains("body/indigo") && paths.contains("eyes/pilulas") && paths.contains("mouth/sorriso"))
        #expect(!paths.contains { $0.hasPrefix("hair/") })
        #expect(paths.filter { $0.hasPrefix("accessories/") } == ["accessories/laco"])
        // …but the saved look keeps its ids, so going back to the newer build loses nothing.
        #expect(config.color == "marte" && config.hair == "careca-brilhante" && config.accessories == ["jetpack", "laco"])
        let again = try JSONDecoder().decode(OrbConfig.self, from: JSONEncoder().encode(config))
        #expect(again == config)
    }


    @Test func renamedOptionsMapToTheirSuccessor() {
        var old = OrbConfig()
        old.hair = "cachinhos-antigos"
        old.accessories = ["chapeu-velho", "laco", "chapeu-velho"]
        let renamed: [OrbCategory: [String: String]] = [.hair: ["cachinhos-antigos": "cachos"], .accessories: ["chapeu-velho": "cartola"]]
        let migrated = old.migrated(in: catalog, renamed: renamed)
        #expect(migrated.hair == "cachos")
        #expect(migrated.accessories == ["cartola", "laco"])
        // A known config is left exactly as it is.
        let current = OrbConfig(color: "menta", eyes: "felizes", hair: "franja", accessories: ["flor"])
        #expect(current.migrated(in: catalog, renamed: renamed) == current)
    }

    // MARK: Layers

    @Test func everyHairAndHatCombinationFindsItsImages() {
        let hats = [nil] + catalog.options(.accessories).map(\.id)
        for hair in catalog.options(.hair).map(\.id) {
            for accessory in hats {
                let config = OrbConfig(color: "ceu", hair: hair, accessories: accessory.map { [$0] } ?? [])
                for layer in config.layers() {
                    #expect(OrbImages.cgImage(layer.path, pixels: 60, tint: layer.tint) != nil, "\(layer.path)")
                }
            }
        }
    }

    @Test func hairComesWithItsUntintedShineLayer() {
        let layers = OrbConfig(color: "rosa", hair: "franja").layers()
        let hair = layers.filter { $0.kind == .hair }
        #expect(hair.map(\.path) == ["hair/franja", "hair/franja-brilho"])
        #expect(hair[0].tint != nil && hair[1].tint == nil)
        let loose = hair.allSatisfy { $0.isLoose }
        #expect(loose)
    }

    @Test func tallStylesTuckUnderHats() {
        #expect(catalog.hats.contains("cartola"))
        let hatted = OrbConfig(hair: "coque", accessories: ["cartola"]).layers().filter { $0.kind == .hair }.map(\.path)
        #expect(hatted == ["hair/coque-chapeu", "hair/coque-chapeu-brilho"])
        // Not for things that don't cover the top of the head.
        let bow = OrbConfig(hair: "coque", accessories: ["laco"]).layers().filter { $0.kind == .hair }.map(\.path)
        #expect(bow == ["hair/coque", "hair/coque-brilho"])
        // Styles that already fit under a hat keep their only version.
        let bangs = OrbConfig(hair: "franja", accessories: ["bone"]).layers().filter { $0.kind == .hair }.map(\.path)
        #expect(bangs.first == "hair/franja")
    }

    @Test func defaultHairColorIsDesignedPerPalette() {
        for palette in catalog.palettes {
            #expect(palette.hair != nil, "\(palette.id)")
            let tint = OrbConfig(color: palette.id, hair: "franja").layers().first { $0.kind == .hair }?.tint
            #expect(tint == palette.hair)
        }
        var custom = OrbConfig(color: "rosa", hair: "franja")
        custom.hairColor = 0x123456
        #expect(custom.layers().first { $0.kind == .hair }?.tint == 0x123456)
    }

    @Test func mustachesShowOnLightBodies() {
        let tint = { (color: String) in
            OrbConfig(color: color, mustache: "classico").layers().first { $0.kind == .mustache }?.tint
        }
        #expect(tint("indigo") == 0xF4F2FF)
        #expect(tint("perola") == OrbCatalog.shared.palette("perola").hair)
    }

    @Test func layerArtStaysSmall() throws {
        // The art is re-encoded without hidden color under transparent pixels (it was ~12 MB before).
        let root = try #require(catalog.root)
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".png") }
        let bytes = try files.reduce(0) { total, file in
            total + (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(file).path)[.size] as? Int ?? 0)
        }
        #expect(bytes > 0 && bytes < 6_000_000)
    }

    // MARK: Automatic colors

    @Test func orbsSavedBeforeTheDesignedColorsKeepTheirColors() throws {
        // Saved by an earlier version (no `autoColors`): every automatic color is the one it always had.
        let json = #"{"color":"lima","eyes":"ovais","hair":"franja","mustache":"classico","accessories":["orelhas-gato","fones"]}"#
        let old = try JSONDecoder().decode(OrbConfig.self, from: Data(json.utf8))
        #expect(old.autoColors == .original)
        let lima = catalog.palette("lima")
        let tints = Dictionary(old.layers().map { ($0.path, $0.tint) }, uniquingKeysWith: { first, _ in first })
        #expect(tints["hair/franja"] == OrbConfig.darkened(lima.deep, 0.55))
        #expect(tints["mustache/classico"] == 0xF4F2FF)
        #expect(tints["accessories/orelhas-gato"] == lima.deep)
        // Headphones are the exception: the old dark ones vanished on the dark background.
        #expect(tints["accessories/fones"] == 0xE9E6F5)
        // It stays that way when saved again.
        #expect(try JSONDecoder().decode(OrbConfig.self, from: JSONEncoder().encode(old)).autoColors == .original)
        // New looks get the designed colors.
        var new = old
        new.autoColors = .designed
        #expect(new.layers().first { $0.kind == .hair }?.tint == lima.hair)
        #expect(OrbConfig().autoColors == .designed && OrbConfig.random().autoColors == .designed)
    }

    @Test func mustachesFollowTheHairAndShowOnPaleBodies() {
        let tint = { (config: OrbConfig) in config.layers().first { $0.kind == .mustache }?.tint }
        #expect(tint(OrbConfig(color: "indigo", mustache: "classico")) == 0xF4F2FF)
        #expect(tint(OrbConfig(color: "perola", mustache: "classico")) == catalog.palette("perola").hair)
        #expect(catalog.palette("sol").isPale && catalog.palette("lima").isPale && !catalog.palette("indigo").isPale)
        var brown = OrbConfig(color: "indigo", mustache: "classico")
        brown.hairColor = 0x6B4A2E
        #expect(tint(brown) == 0x6B4A2E)
        // Chosen colors always win.
        brown.mustacheColor = 0xF4F2FF
        #expect(tint(brown) == 0xF4F2FF)
    }

    @Test func catEarsStandOutFromTheHair() {
        let ears = { (config: OrbConfig) in config.layers().first { $0.path == "accessories/orelhas-gato" }?.tint }
        let ceu = catalog.palette("ceu")
        #expect(ears(OrbConfig(color: "ceu", accessories: ["orelhas-gato"])) == ceu.hair)
        #expect(ears(OrbConfig(color: "ceu", hair: "cachos", accessories: ["orelhas-gato"])) == ceu.hexes[1])
    }

    // MARK: Aleatório

    @Test func randomLooksHangTogether() {
        var rng = SeededRandom(seed: 42)
        let borrowed: Set = ["tontos", "bravos", "sono", "fendas", "triste", "preocupadas", "bravas"]
        var hairs = Set<String>(), colors = Set<String>()
        for _ in 0..<600 {
            let config = OrbConfig.random(using: &rng)
            // Every id exists, so nothing points at a missing image.
            #expect(config.migrated(in: catalog) == config)
            #expect(!borrowed.contains(config.eyes) && !borrowed.contains(config.mouth) && !borrowed.contains(config.brows))
            #expect(config.accessories.count <= 1)
            if config.hair == "nenhum" { #expect(config.hairColor == nil) }
            if let tint = config.hairColor { #expect(OrbSwatch.naturalHair.contains { $0.hex == tint }) }
            for accessory in config.accessories { #expect(OrbConfig.goesWith(hair: config.hair, accessory: accessory)) }
            hairs.insert(config.hair)
            colors.insert(config.color)
        }
        // ...and still explores the whole catalog of colors and hair.
        #expect(hairs.count == catalog.options(.hair).count)
        #expect(colors.count == catalog.palettes.count)
    }

    @Test func summaryDescribesTheLookInWords() {
        let config = OrbConfig(color: "rosa", eyes: "ovais", mouth: "sorriso", hair: "chiquinhas", accessories: ["laco"])
        #expect(config.summary == "Rosa, olhos Ovais, boca Sorriso, cabelo Maria-chiquinha, Laço")
        #expect(OrbConfig().summary == "Índigo, olhos Pílulas")
    }

    @Test func swatchesAreNamedAndDistinct() {
        #expect(OrbSwatch.mustache.first?.name == "Branco")
        for list in [OrbSwatch.hair, OrbSwatch.mustache, OrbSwatch.accent] {
            #expect(Set(list.map(\.hex)).count == list.count)
            let named = list.allSatisfy { !$0.name.isEmpty }
            #expect(named)
        }
    }

    // MARK: Motion

    @Test func happinessIsABurstThatCalmsDown() {
        func peak(_ range: ClosedRange<Double>) -> Double {
            stride(from: range.lowerBound, through: range.upperBound, by: 0.005)
                .map { OrbActivity.happy.motion(at: $0, elapsed: $0).lift }.max() ?? 0
        }
        #expect(peak(0...1.2) > 0.09)
        #expect(peak(2.6...3) < peak(0...1.2) * 0.4)
        // First it gets ready: a squash on the ground, long enough to show through the blend into the activity.
        let ready = OrbActivity.happyReady
        #expect(OrbActivity.happy.motion(at: 0, elapsed: 0).squash == 0)
        let crouch = OrbActivity.happy.motion(at: ready - 0.01, elapsed: ready - 0.01)
        #expect(crouch.lift == 0 && crouch.squash > 0.06)
        // The hops take over without a jump.
        let first = OrbActivity.happy.motion(at: ready + 0.001, elapsed: ready + 0.001)
        #expect(abs(first.squash - crouch.squash) < 0.01 && first.lift < 0.005)
        // Without timing it loops, and long after it started it neither jumps nor breaks.
        #expect(OrbActivity.happy.motion(at: 1, elapsed: .infinity).lift.isFinite)
        #expect(OrbActivity.happy.motion(at: 0.2).lift > 0)
    }

    @Test func calmedHappinessNeedsNoMoreThanIdleFrames() {
        #expect(OrbActivity.happy.minFrameRate(elapsed: 0.5) == 30)
        #expect(OrbActivity.happy.minFrameRate(elapsed: 5) == OrbActivity.idle.minFrameRate)
        #expect(OrbActivity.happy.minFrameRate(elapsed: .infinity) == OrbActivity.idle.minFrameRate)
        #expect(OrbActivity.typing.minFrameRate(elapsed: 60) == 30)
        // And the calm phase moves slowly enough for that floor at the editor's size.
        let lifts = stride(from: 4.0, to: 8, by: 0.01).map { OrbActivity.happy.motion(at: $0, elapsed: $0) }
        let speed = zip(lifts, lifts.dropFirst()).map { max(abs($1.lift - $0.lift), abs($1.tilt - $0.tilt) * .pi / 360) / 0.01 }.max() ?? 0
        #expect(OrbFrameRate.rate(forSpeed: speed * 144 * 2, cap: 60) <= 20)
    }


    @Test func idleSwayIsBarelyThere() {
        let tilts = stride(from: 0.0, to: 30, by: 0.01).map { OrbActivity.idle.motion(at: $0).tilt }
        #expect((tilts.max() ?? 0) > 0.5 && (tilts.max() ?? 0) < 1.5)
        // Slow enough that the adaptive frame rate stays at its floor for a 96 pt orb.
        let speed = zip(tilts, tilts.dropFirst()).map { abs($1 - $0) / 0.01 }.max() ?? 0
        let pixelsPerSecond = speed * .pi / 360 * 96 * 2
        #expect(OrbFrameRate.rate(forSpeed: pixelsPerSecond, cap: 60) == OrbFrameRate.steps[0])
    }

    @Test func hairSwingCountsAsMotionAndBlends() {
        var swung = OrbPose()
        swung.hairSwing = 2
        #expect(swung.pixelDistance(to: OrbPose(), size: 96, scale: 2) > 1)
        #expect(abs(OrbPose.mix(swung, .rest, 0.5).hairSwing - 1) < 1e-9)
        #expect(OrbPose.rest.hairSwing == 0)
    }

    // MARK: Editor

    // MARK: Reacting to the interface

    @Test func attentiveWatchesTheFieldWithoutAFaceOfItsOwn() {
        let attentive = OrbActivity.attentive
        #expect(attentive.eyes == nil && attentive.brows == nil && attentive.bubble == nil)
        #expect(attentive.mouth(base: "sorriso") == nil && attentive.mouth(base: "nenhuma") == nil)
        #expect(attentive.minFrameRate == OrbActivity.idle.minFrameRate && attentive.minFrameRate == 10)
        #expect(attentive.wander == 0.2)
        for t in stride(from: 0.0, through: 20, by: 0.25) {
            let gaze = attentive.gaze(at: t)
            #expect(gaze.look.y == -0.45 && abs(gaze.look.x) <= 0.1 && gaze.pointerWeight == 0.3)
        }
        // The body only breathes and floats, as when idle (no hop).
        #expect(attentive.motion(at: 3.1) == OrbActivity.idle.motion(at: 3.1))
        // It blinks less; other activities keep the temperament's rhythm.
        let gap = OrbTemperament.Traits().blinkGap
        #expect(attentive.blinkGap(gap).lowerBound > gap.lowerBound && attentive.blinkGap(gap).upperBound > gap.upperBound)
        #expect(OrbActivity.idle.blinkGap(gap) == gap && OrbActivity.listening.blinkGap(gap) == gap)
    }

    @Test func paleBodiesAreTheOnesWhiteDoesNotStandOutOn() {
        let pale = Set(catalog.palettes.filter(\.isPale).map(\.id))
        #expect(pale == ["perola", "lima", "algodao", "sol", "aurora", "pessego"])
        // No palette sits near the line, so a small change to a color does not flip it.
        for palette in catalog.palettes {
            #expect(abs(palette.whiteContrast - OrbPalette.paleContrast) > 0.1, "\(palette.id): \(palette.whiteContrast)")
        }
    }

    @Test func idleAttentiveAndListeningShareAFace() {
        for base in ["sorriso", "nenhuma"] {
            #expect(OrbActivity.idle.hasSameFace(as: .attentive, mouth: base))
            #expect(OrbActivity.attentive.hasSameFace(as: .listening, mouth: base))
            #expect(!OrbActivity.idle.hasSameFace(as: .happy, mouth: base))
            #expect(!OrbActivity.idle.hasSameFace(as: .thinking, mouth: base)) // the bubble and the whistle
        }
    }

    // MARK: Room on the stage

    @Test func stackedLiftsAreEasedUnderTheCap() {
        let room = OrbStageRoom.self
        // Unchanged below the knee: a balanced Orb's click jump (0.16) and Feliz's hops (0.1) look as before.
        #expect(room.softCap(0.1, knee: room.liftKnee, cap: room.maxLift) == 0.1)
        #expect(abs(room.softCap(0.16, knee: room.liftKnee, cap: room.maxLift) - 0.16) < 0.002)
        var last = -1.0
        for step in 0...600 {
            let value = room.softCap(Double(step) / 1000, knee: room.liftKnee, cap: room.maxLift)
            #expect(value > last && value < room.maxLift)
            last = value
        }
        // A click during a lively hop (0.224 + 0.14) with both stretches.
        var pose = OrbPose()
        pose.lift = 0.364
        pose.squash = -0.105
        room.limit(&pose)
        #expect(pose.lift < room.maxLift && -pose.squash < room.maxStretch)
        var squashed = OrbPose()
        squashed.squash = 0.12 // landing: squashing down is not capped
        room.limit(&squashed)
        #expect(squashed.squash == 0.12)
    }

    /// The tallest hat or hairdo, at the highest the body can go (lift and stretch at their caps, grown under the
    /// pointer, hair trailing up and the head looking up, tilted either way), stays inside the stage's headroom.
    @Test func theStageHeadroomFitsTheTallestHatAtTheHighestJump() throws {
        let root = try #require(catalog.root)
        let files = try ["hair", "accessories"].flatMap { folder in
            try FileManager.default.contentsOfDirectory(at: root.appending(path: folder), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "png" }
        }
        #expect(files.count > 30)
        let room = OrbStageRoom.self
        let sx = 1 + room.maxGrow, sy = 1 + room.maxStretch + room.maxGrow
        let tilts = [-16.0, -8, 0, 8, 16].map { $0 * .pi / 180 }
        let scale = Double(OrbGeometry.imageScale), bottom = Double(OrbGeometry.orbBottom)
        var highest = 0.0, tallest = ""
        for file in files {
            let (pixels, width, height) = try alpha(of: file)
            for y in stride(from: 0, to: height / 2, by: 2) {
                for x in stride(from: 0, to: width, by: 2) where pixels[y * width + x] > 40 {
                    let hx = (Double(x) / Double(width) - 0.5) * scale, hy = (bottom - Double(y) / Double(height)) * scale
                    for tilt in tilts {
                        let top = hx * sx * sin(tilt) + hy * sy * cos(tilt)
                        if top > highest { (highest, tallest) = (top, file.lastPathComponent) }
                    }
                }
            }
        }
        // Height of the size box's top above the orb's base (the anchor everything scales and turns around).
        let boxTop = (bottom - 0.5) * scale + 0.5
        let looseRise = OrbSprings.maxLag + 1 * OrbLayer(kind: .hair, path: "hair/coque", tint: nil).depth
        let reach = highest - boxTop + room.maxLift + looseRise
        #expect(reach <= room.headroomFraction, "\(tallest) reaches \(reach)")
        #expect(reach > room.headroomFraction - 0.1, "the headroom could be smaller: \(reach)")
    }

    /// Alpha of every pixel of a PNG, top row first.
    private func alpha(of file: URL) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        return (pixels, width, height)
    }

    // MARK: The selection glance

    @Test func theSelectionGlanceIsQuickSmoothAndBlinks() {
        #expect(OrbGlance.weight(0) == 0 && OrbGlance.weight(OrbGlance.duration) == 0 && OrbGlance.weight(-1) == 0)
        #expect(OrbGlance.weight(0.3) == 1) // held at the chat in the middle
        #expect(OrbGlance.duration <= 0.7 && OrbGlance.look.x > 0.5) // quick, and to the right, where the chat is
        var last = 0.0
        for step in 1...600 {
            let w = OrbGlance.weight(Double(step) / 1000)
            #expect(abs(w - last) < 0.03, "no jump at \(step) ms")
            last = w
        }
        var turning = OrbPose()
        OrbGlance.apply(to: &turning, elapsed: 0.06)
        #expect(turning.eyeLead.x > 0)     // the eyes get there first...
        #expect(turning.hairLag.x < 0)     // ...the hair after the head
        #expect(turning.blink == 0)        // and the turn is not hidden behind the blink
        var arrived = OrbPose()
        OrbGlance.apply(to: &arrived, elapsed: OrbGlance.blinkAt + 0.08)
        #expect(arrived.blink > 0.5)       // the blink comes as it gets there
        var after = OrbPose()
        OrbGlance.apply(to: &after, elapsed: OrbGlance.total)
        #expect(after == OrbPose())        // nothing left once it is over (the hair is back too)
    }

    @Test func theGlanceLooksTowardTheChatAndComesBack() {
        // From wherever the Orb was looking (here, down at the field while you type).
        let start = CGPoint(x: -0.2, y: -0.45)
        func look(at elapsed: Double) -> CGPoint {
            var pose = OrbPose()
            pose.look = start
            OrbGlance.apply(to: &pose, elapsed: elapsed)
            return pose.look
        }
        #expect(look(at: 0) == start)
        #expect(look(at: 0.06).x > start.x && look(at: 0.06).x < OrbGlance.look.x) // on its way right
        #expect(hypot(look(at: 0.3).x - OrbGlance.look.x, look(at: 0.3).y - OrbGlance.look.y) < 1e-9) // at the chat
        #expect(look(at: 0.5).x < OrbGlance.look.x && look(at: 0.5).x > start.x)     // coming back
        #expect(look(at: OrbGlance.duration) == start)                                // where it was
    }

    @Test @MainActor func orbEditsUndoAndRedoThroughTheWindowsUndoManager() {
        final class Box { var look = OrbConfig() }
        let box = Box(), undo = UndoManager(), target = OrbEditUndo.Target()
        undo.groupsByEvent = false
        let pink = OrbConfig(color: "rosa")
        undo.beginUndoGrouping()
        OrbEditUndo.register(undo, target: target, from: box.look, to: pink) { box.look = $0 }
        undo.endUndoGrouping()
        box.look = pink
        #expect(OrbEditUndo.canUndo(undo) && undo.undoActionName == OrbEditUndo.actionName)
        undo.undo()
        #expect(box.look == OrbConfig())
        #expect(undo.canRedo)
        undo.redo()
        #expect(box.look == pink)
        // Typing in a field of the same window is not the editor's to undo.
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: target) { _ in }
        undo.setActionName("Digitação")
        undo.endUndoGrouping()
        #expect(!OrbEditUndo.canUndo(undo))
        // Closing the editor drops its entries.
        undo.removeAllActions(withTarget: target)
        #expect(!undo.canUndo)
    }
}
