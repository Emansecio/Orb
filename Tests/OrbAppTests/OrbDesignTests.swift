import Foundation
import CoreGraphics
import Testing
@testable import Orb

/// The redesigned art and motion: saved Orbs keep loading, every combination finds its images, and the one-shot
/// reactions calm down.
struct OrbDesignTests {
    private let catalog = OrbCatalog.shared

    // MARK: Saved Orbs

    @Test func unknownOptionsDrawAsDefaultsButStaySaved() throws {
        // A look saved by a newer build: what this build doesn't know draws as the default…
        let json = #"{"color":"marte","eyes":"laser","mouth":"sorriso","brows":"monocelha"}"#
        let config = try JSONDecoder().decode(OrbConfig.self, from: Data(json.utf8))
        let paths = config.layers().map(\.path)
        #expect(paths.contains("body/indigo") && paths.contains("eyes/pilulas") && paths.contains("mouth/sorriso"))
        #expect(!paths.contains { $0.hasPrefix("brows/") })
        // …but the saved look keeps its ids, so going back to the newer build loses nothing.
        #expect(config.color == "marte" && config.eyes == "laser" && config.brows == "monocelha")
        let again = try JSONDecoder().decode(OrbConfig.self, from: JSONEncoder().encode(config))
        #expect(again == config)
    }

    @Test func aTemperamentFromANewerBuildReadsAsTheDefault() throws {
        let config = try JSONDecoder().decode(OrbConfig.self, from: Data(#"{"color":"rosa","temperament":"dorminhoco"}"#.utf8))
        #expect(config.color == "rosa" && config.temperament == .equilibrado)
        let known = try JSONDecoder().decode(OrbConfig.self, from: Data(#"{"temperament":"timido"}"#.utf8))
        #expect(known.temperament == .timido)
    }

    @Test func renamedOptionsMapToTheirSuccessor() {
        var old = OrbConfig()
        old.eyes = "olhos-antigos"
        let renamed: [OrbCategory: [String: String]] = [.eyes: ["olhos-antigos": "ovais"]]
        #expect(old.migrated(in: catalog, renamed: renamed).eyes == "ovais")
        // An id nobody maps falls back to the default.
        #expect(old.migrated(in: catalog, renamed: [:]).eyes == OrbConfig().eyes)
        // A known config is left exactly as it is.
        let current = OrbConfig(color: "menta", eyes: "felizes", cheeks: "blush")
        #expect(current.migrated(in: catalog, renamed: renamed) == current)
    }

    // MARK: Layers

    @Test func layerArtStaysSmall() throws {
        // The art is re-encoded without hidden color under transparent pixels (it was ~12 MB before). The plush
        // bodies (2026-11) are most of it, ~4.5 MB: fur is fine detail that PNG can't squeeze like the satin gradient.
        let root = try #require(catalog.root)
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".png") }
        let bytes = try files.reduce(0) { total, file in
            total + (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(file).path)[.size] as? Int ?? 0)
        }
        #expect(bytes > 0 && bytes < 8_000_000)
    }

    // MARK: Hair and accessories removed

    @Test func hairAndAccessoriesLeaveEveryOrb() throws {
        // A look saved while hair, accessories and their colors existed: they are ignored, the rest stays.
        let json = #"{"color":"ceu","eyes":"ovais","mouth":"sorriso","cheeks":"blush","temperament":"timido","hair":"coque","hairColor":5913378,"accessories":["fones","oculos-sol"],"accentColor":16732043,"autoColors":2}"#
        let old = try JSONDecoder().decode(OrbConfig.self, from: Data(json.utf8))
        #expect(old.color == "ceu" && old.eyes == "ovais" && old.mouth == "sorriso" && old.cheeks == "blush")
        #expect(old.temperament == .timido)
        // No hair or accessory layer is drawn.
        let paths = old.layers().map(\.path)
        #expect(paths == ["body/ceu", "cheeks/blush", "mouth/sorriso", "eyes/ovais"])
        #expect(!paths.contains { $0.hasPrefix("hair/") || $0.hasPrefix("accessories/") })
        // Saved again, the look no longer carries any of the removed keys.
        let saved = try #require(String(data: JSONEncoder().encode(old), encoding: .utf8))
        for key in ["hair", "accessories", "hairColor", "accentColor", "autoColors"] {
            #expect(!saved.contains("\"\(key)\""), "\(key)")
        }
        #expect(try JSONDecoder().decode(OrbConfig.self, from: Data(saved.utf8)) == old)
        // The editor and the catalog offer none of them, and the art is gone.
        #expect(OrbCategory.allCases.map(\.rawValue) == ["color", "temperament", "eyes", "mouth", "brows", "cheeks"])
        let root = try #require(catalog.root)
        for folder in ["hair", "accessories"] {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).path), "\(folder)")
        }
    }

    // MARK: Sortear

    @Test func randomLooksHangTogether() {
        var rng = SeededRandom(seed: 42)
        let borrowed: Set = ["tontos", "bravos", "sono", "fendas", "triste", "preocupadas", "bravas"]
        var colors = Set<String>()
        for _ in 0..<600 {
            let config = OrbConfig.random(using: &rng)
            // Every id exists, so nothing points at a missing image.
            #expect(config.migrated(in: catalog) == config)
            #expect(!borrowed.contains(config.eyes) && !borrowed.contains(config.mouth) && !borrowed.contains(config.brows))
            colors.insert(config.color)
        }
        // ...and still explores the whole catalog of colors.
        #expect(colors.count == catalog.palettes.count)
    }

    @Test func summaryDescribesTheLookInWords() {
        let config = OrbConfig(color: "rosa", eyes: "ovais", mouth: "sorriso", cheeks: "blush")
        #expect(config.summary == "Rosa, olhos Ovais, boca Sorriso, bochechas Rosadas")
        #expect(OrbConfig().summary == "Índigo, olhos Pílulas")
    }

    // MARK: Motion

    #if DEBUG || ORB_DEV_TOOLS
    @Test @MainActor func theIconSheetRowsDoNotCoverEachOther() {
        let layout = OrbDesignSheet.iconLayout(pixels: OrbDesignSheet.iconSizes)
        let band = CGRect(origin: .zero, size: OrbDesignSheet.iconBand)
        for (first, top) in layout.row1 {
            #expect(band.contains(top), "\(first)")
            for (second, bottom) in layout.row2 {
                #expect(!top.intersects(bottom), "the \(first) px icon of row 1 and the magnified \(second) px of row 2")
            }
        }
        #expect(layout.row1.count == 7 && layout.row2.count == 4)
    }
    #endif

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
        #expect(turning.blink == 0)        // and the turn is not hidden behind the blink
        var arrived = OrbPose()
        OrbGlance.apply(to: &arrived, elapsed: OrbGlance.blinkAt + 0.08)
        #expect(arrived.blink > 0.5)       // the blink comes as it gets there
        var after = OrbPose()
        OrbGlance.apply(to: &after, elapsed: OrbGlance.duration)
        #expect(after == OrbPose())        // nothing left once it is over
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
