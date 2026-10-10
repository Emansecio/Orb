import Foundation
import SwiftUI
import Testing
@testable import Orb

// The logos of the gallery: the SVG path reader, the data embedded from Simple Icons and which card gets which mark.
// Nothing is drawn on screen and nothing is downloaded.

struct SVGPathDataTests {
    private func segments(_ data: String) -> [PathSegment] { SVGPathData.segments(data) ?? [] }
    private func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: Double = 1e-6) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }

    @Test func absoluteLinesAndTheClosingCommand() {
        #expect(segments("M10 20 L30 40 H50 V60 Z") == [.move(p(10, 20)), .line(p(30, 40)), .line(p(50, 40)), .line(p(50, 60)), .close])
    }

    @Test func relativeCommandsCountFromTheCurrentPoint() {
        #expect(segments("m1 2 l3 4 h5 v6 l-1-1") == [.move(p(1, 2)), .line(p(4, 6)), .line(p(9, 6)), .line(p(9, 12)), .line(p(8, 11))])
        // The first "m" is absolute, and a Z puts the pen back at the start of the subpath, where a relative line begins anew.
        #expect(segments("m5 5 l5 0 z l0 5") == [.move(p(5, 5)), .line(p(10, 5)), .close, .move(p(5, 5)), .line(p(5, 10))])
    }

    @Test func aRepeatedMoveBecomesLines() {
        #expect(segments("M0 0 10 0 10 10") == [.move(p(0, 0)), .line(p(10, 0)), .line(p(10, 10))])
        #expect(segments("m1 1 2 0 0 2") == [.move(p(1, 1)), .line(p(3, 1)), .line(p(3, 3))])
        #expect(segments("L0 0") == [] && SVGPathData.segments("L0 0") == nil)
    }

    @Test func cubicsAndTheirSmoothShorthand() {
        #expect(segments("M0 0 C1 2 3 4 5 6") == [.move(p(0, 0)), .curve(control1: p(1, 2), control2: p(3, 4), to: p(5, 6))])
        #expect(segments("M0 0 c1 2 3 4 5 6 c1 1 2 2 3 3")
                == [.move(p(0, 0)), .curve(control1: p(1, 2), control2: p(3, 4), to: p(5, 6)),
                    .curve(control1: p(6, 7), control2: p(7, 8), to: p(8, 9))])
        // S mirrors the second control point of the last cubic through the current point; after a line it uses the point itself.
        #expect(segments("M0 0 C1 2 3 4 5 6 S9 9 10 10")
                == [.move(p(0, 0)), .curve(control1: p(1, 2), control2: p(3, 4), to: p(5, 6)),
                    .curve(control1: p(7, 8), control2: p(9, 9), to: p(10, 10))])
        #expect(segments("M0 0 L5 5 s1 2 3 4") == [.move(p(0, 0)), .line(p(5, 5)), .curve(control1: p(5, 5), control2: p(6, 7), to: p(8, 9))])
    }

    @Test func quadraticsAndTheirSmoothShorthand() {
        #expect(segments("M0 0 Q1 2 3 4") == [.move(p(0, 0)), .quad(control: p(1, 2), to: p(3, 4))])
        #expect(segments("M0 0 q1 2 3 4 t3 4") == [.move(p(0, 0)), .quad(control: p(1, 2), to: p(3, 4)), .quad(control: p(5, 6), to: p(6, 8))])
        #expect(segments("M1 1 T4 4") == [.move(p(1, 1)), .quad(control: p(1, 1), to: p(4, 4))])
        // A cubic's control point is not the quadratic's: T after C mirrors nothing.
        #expect(segments("M0 0 C1 1 2 2 3 3 T6 6")[2] == .quad(control: p(3, 3), to: p(6, 6)))
    }

    @Test func numbersPackedTogether() {
        #expect(segments("M1.5.5L-1-2") == [.move(p(1.5, 0.5)), .line(p(-1, -2))])
        #expect(segments("M.5.5.5-.5") == [.move(p(0.5, 0.5)), .line(p(0.5, -0.5))])
        #expect(segments("M1e1 2E-1 L+3,4") == [.move(p(10, 0.2)), .line(p(3, 4))])
        #expect(segments("M 1 ,\n2\tL3\r\n4") == [.move(p(1, 2)), .line(p(3, 4))])
        #expect(segments("M0 0h1.2.3") == [.move(p(0, 0)), .line(p(1.2, 0)), .line(p(1.5, 0))])
        // The decimal point ends a number that already has one, and a letter ends it too.
        #expect(segments("M0 0h1e2v3") == [.move(p(0, 0)), .line(p(100, 0)), .line(p(100, 3))])
    }

    @Test func arcsReachTheirEndPoint() throws {
        let half = segments("M0 0 A5 5 0 0 1 10 0")
        #expect(half.count == 3, "a half turn is two quarter curves")
        guard case .curve(_, _, let end) = half.last else { Issue.record("expected a curve"); return }
        #expect(close(end, p(10, 0)))
        // Sweep flag 1 goes clockwise on screen (y down): from (0,0) to (10,0) the half circle passes above, through (5,-5).
        guard case .curve(_, _, let middle) = half[1] else { Issue.record("expected a curve"); return }
        #expect(close(middle, p(5, -5), 1e-9))
        guard case .curve(_, _, let below) = segments("M0 0 A5 5 0 0 0 10 0")[1] else { Issue.record("expected a curve"); return }
        #expect(close(below, p(5, 5), 1e-9))
        // Relative, and the large-arc flag choosing the long way round a chord shorter than a diameter.
        let small = segments("m0 0 a10 10 0 0 1 10 10")
        let large = segments("m0 0 a10 10 0 1 1 10 10")
        #expect(small.count == 2 && large.count == 4)
        guard case .curve(_, _, let smallEnd) = small.last, case .curve(_, _, let largeEnd) = large.last else { Issue.record("expected curves"); return }
        #expect(close(smallEnd, p(10, 10)) && close(largeEnd, p(10, 10)))
    }

    @Test func arcsStayOnTheirEllipse() throws {
        // A large arc of an 8 x 4 ellipse (more than half a turn) takes three or four quarter curves and ends where asked.
        let pieces = segments("M0 0 a8 4 0 1 1 8 4")
        var ends: [CGPoint] = []
        for piece in pieces { if case .curve(_, _, let to) = piece { ends.append(to) } }
        #expect((3...4).contains(ends.count) && close(ends[ends.count - 1], p(8, 4)))
        // Radii too small for the chord grow until the arc reaches: a half circle of radius 5.
        let grown = segments("M0 0 a1 1 0 0 1 10 0")
        guard case .curve(_, _, let top) = grown[1] else { Issue.record("expected a curve"); return }
        #expect(close(top, p(5, -5), 1e-9))
        // Rotation: a half ellipse with radii 10 x 5 turned 90 degrees reaches 10 down.
        let turned = segments("M0 0 a10 5 90 0 1 0 10")
        guard case .curve(_, _, let last) = turned.last else { Issue.record("expected a curve"); return }
        #expect(close(last, p(0, 10)))
    }

    @Test func degenerateArcs() {
        #expect(segments("M0 0 A0 5 0 0 1 10 0") == [.move(p(0, 0)), .line(p(10, 0))])
        #expect(segments("M3 3 A5 5 0 0 1 3 3") == [.move(p(3, 3))])
        // Flags need no separator, as in the data of Atlassian's logo.
        #expect(segments("M10 0 a.5.5 0 00-1 0").count == 3)
        #expect(segments("M10 0a1 1 0 1110 0").count == 3)
    }

    @Test func malformedDataIsRefused() {
        for bad in ["", "   ", "10 20", "L1 1", "M", "M1", "M1 2 L3", "M1 2 Z 3 4", "M1 2 X3 4", "M1 2 C1 2 3 4 5", "M1 2 A1 1 0 2 0 3 3", "M1 2 L#"] {
            #expect(SVGPathData.path(bad) == nil, Comment(rawValue: bad))
        }
    }

    @Test func aPathHasTheBoundsOfItsPoints() throws {
        let path = try #require(SVGPathData.path("M2 3 L12 3 L12 9 L2 9 Z"))
        #expect(path.boundingRect == CGRect(x: 2, y: 3, width: 10, height: 6))
        let circle = try #require(SVGPathData.path("M12 0 a12 12 0 1 1 0 24 a12 12 0 1 1 0-24z"))
        let box = circle.cgPath.boundingBoxOfPath
        #expect(abs(box.minX) < 1e-6 && abs(box.minY) < 1e-6 && abs(box.width - 24) < 1e-6 && abs(box.height - 24) < 1e-6)
    }
}

struct BrandMarksTests {
    /// The brands the gallery names, by the card's id.
    private let branded = ["gmail", "agenda", "slack", "notion", "github", "supabase", "linear", "atlassian", "sentry"]

    @Test func everyBrandedCardResolvesToAMarkOrADeliberateFallback() {
        for service in ConnectorGallery.services {
            if branded.contains(service.id) {
                guard let brand = service.mark.brand else { Issue.record("no brand: \(service.id)"); continue }
                #expect(BrandMarks.mark(brand) != nil || BrandMarks.withoutLogo.contains(brand), Comment(rawValue: service.id))
                #expect(service.mark.logo != nil || BrandMarks.withoutLogo.contains(brand), Comment(rawValue: service.id))
                // A card with no logo keeps the symbol or the letter it had.
                if service.mark.logo == nil { #expect(service.mark.symbol != nil || !service.mark.monogram.isEmpty) }
            } else {
                // Apple's apps and the generic tools keep their symbol.
                #expect(service.mark.brand == nil && service.mark.symbol != nil, Comment(rawValue: service.id))
            }
        }
        #expect(Set(ConnectorGallery.services.filter { $0.mark.brand != nil }.map(\.id)) == Set(branded))
        #expect(BrandMarks.withoutLogo.isEmpty)
        #expect(Set(BrandMarks.all.keys).isDisjoint(with: BrandMarks.withoutLogo))
    }

    @Test func noMarkIsUnused() {
        let used = Set(ConnectorGallery.services.compactMap(\.mark.brand))
        #expect(Set(BrandMarks.all.keys).isSubset(of: used))
        for (key, mark) in BrandMarks.all { #expect(mark.slug == key) }
    }

    @Test func everyMarkParsesToAShapeInsideTheBox() throws {
        for (slug, mark) in BrandMarks.all {
            let comment = Comment(rawValue: slug)
            let segments = try #require(SVGPathData.segments(mark.path), comment)
            #expect(segments.count > 3, comment)
            let path = try #require(SVGPathData.path(mark.path), comment)
            let box = path.cgPath.boundingBoxOfPath
            #expect(!path.isEmpty && box.width > 8 && box.height > 8, comment)
            // Inside the 24x24 viewBox, with room for rounding of the curves.
            #expect(box.minX >= -0.01 && box.minY >= -0.01 && box.maxX <= 24.01 && box.maxY <= 24.01, comment)
            // Every point the reader produced is inside it too.
            for segment in segments {
                let points: [CGPoint]
                switch segment {
                case .move(let a), .line(let a): points = [a]
                case .quad(let c, let a): points = [c, a]
                case .curve(let c1, let c2, let a): points = [c1, c2, a]
                case .close: points = []
                }
                for point in points { #expect(point.x >= -2 && point.x <= 26 && point.y >= -2 && point.y <= 26, comment) }
            }
            #expect(mark.hex <= 0xFFFFFF)
            #expect(!mark.title.isEmpty)
            let glyph = try #require(BrandMarks.glyph(slug), comment)
            #expect(glyph.bounds.width > 0 && glyph.bounds.height > 0, comment)
        }
    }

    @Test func theColoursAreTheOnesSimpleIconsPublishes() {
        // Pinned with the version: a refresh that changes one has to change this on purpose.
        #expect(BrandMarks.version == "16.34.0")
        #expect(BrandMarks.mark("gmail")?.hex == 0xEA4335)
        #expect(BrandMarks.mark("googlecalendar")?.hex == 0x4285F4)
        #expect(BrandMarks.mark("supabase")?.hex == 0x3FCF8E)
        #expect(BrandMarks.mark("linear")?.hex == 0x5E6AD2)
        #expect(BrandMarks.mark("atlassian")?.hex == 0x0052CC)
        #expect(BrandMarks.mark("sentry")?.hex == 0x362D59)
        #expect(BrandMarks.mark("notion")?.hex == 0x000000)
        #expect(BrandMarks.mark("github")?.hex == 0x181717)
    }

    @Test func darkBrandsAreNeverDrawnBlackOnDark() {
        for (slug, mark) in BrandMarks.all {
            let comment = Comment(rawValue: slug)
            switch mark.treatment {
            case .brandOnDark: #expect(BrandMark.contrast(mark.hex, BrandMark.darkTileHex) >= BrandMark.minimumContrast, comment)
            case .inkOnDark: #expect(BrandMark.luminance(mark.hex) < BrandMark.nearBlackLuminance, comment)
            case .whiteOnBrand:
                // White has to read on the brand's colour.
                #expect(BrandMark.contrast(0xFFFFFF, mark.hex) >= BrandMark.minimumContrast, comment)
            }
        }
        #expect(BrandMarks.mark("notion")?.treatment == .inkOnDark)
        #expect(BrandMarks.mark("github")?.treatment == .inkOnDark)
        #expect(BrandMarks.mark("sentry")?.treatment == .whiteOnBrand)
        #expect(BrandMarks.mark("atlassian")?.treatment == .whiteOnBrand)
        #expect(BrandMarks.mark("gmail")?.treatment == .brandOnDark)
        #expect(BrandMarks.mark("supabase")?.treatment == .brandOnDark)
    }

    @Test func contrastIsTheWebOnes() {
        #expect(abs(BrandMark.contrast(0xFFFFFF, 0x000000) - 21) < 1e-9)
        #expect(abs(BrandMark.contrast(0x777777, 0x777777) - 1) < 1e-9)
        #expect(BrandMark.luminance(0x000000) == 0 && abs(BrandMark.luminance(0xFFFFFF) - 1) < 1e-9)
    }

    @Test func theShapeCentresAndScalesTheMarkWhateverItsBox() throws {
        for (slug, _) in BrandMarks.all {
            let glyph = try #require(BrandMarks.glyph(slug))
            let rect = CGRect(x: 0, y: 0, width: 36, height: 36)
            let box = BrandShape(glyph: glyph, fill: 0.5).path(in: rect).cgPath.boundingBoxOfPath
            let comment = Comment(rawValue: slug)
            // The longer side takes half the tile, and the mark sits in the middle of it.
            #expect(abs(max(box.width, box.height) - 18) < 0.01, comment)
            #expect(abs(box.midX - 18) < 0.01 && abs(box.midY - 18) < 0.01, comment)
        }
    }

    @Test func anInstalledConnectorFindsItsCardByWhatItIs() throws {
        func service(_ config: MCPServerConfig) -> String? { ConnectorGallery.service(for: config)?.id }
        for kind in LocalConnectorKind.allCases { #expect(service(kind.config) == kind.rawValue) }
        for template in ConnectorTemplate.all {
            let id = ConnectorGallery.services.first { $0.source == .template(template.id) }?.id
            #expect(id != nil && service(template.config.withNewID()) == id, Comment(rawValue: template.id))
        }
        // Renamed, and the retired models of Notion and Slack: still the same brand.
        var renamed = try #require(ConnectorTemplate.all.first { $0.id == "github" }).config.withNewID()
        renamed.name = "Meu código"
        #expect(service(renamed) == "github")
        for retired in ConnectorTemplate.retired {
            #expect(service(retired.config.withNewID()) == retired.id, Comment(rawValue: retired.id))
        }
        // A server of the registry or typed by hand has no card, so it keeps the generic icon.
        #expect(service(MCPServerConfig(name: "Meu servidor", command: "node", arguments: ["server.js"])) == nil)
        #expect(service(MCPServerConfig(name: "Outro", url: "https://example.com/mcp")) == nil)
        // Only a brand gets a tile in the installed list and the sheets: Arquivos and Lembretes keep their symbols.
        #expect(ConnectorGallery.service(for: LocalConnectorKind.lembretes.config)?.mark.ifBranded == nil)
        #expect(ConnectorGallery.service(for: LocalConnectorKind.gmail.config)?.mark.ifBranded?.brand == "gmail")
    }
}
