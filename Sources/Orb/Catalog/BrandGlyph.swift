import SwiftUI

/// A brand mark parsed once: its outline on the 24x24 box and the tight box the drawing really fills, which is what
/// `BrandShape` centres and scales so the marks look about the same size whatever room their own box leaves.
struct BrandGlyph: Sendable {
    let path: Path
    let bounds: CGRect
}

extension BrandMarks {
    /// The parsed marks, built on first use.
    private static let glyphs: [String: BrandGlyph] = all.compactMapValues { mark in
        SVGPathData.path(mark.path).map { BrandGlyph(path: $0, bounds: $0.cgPath.boundingBoxOfPath) }
    }

    static func glyph(_ slug: String) -> BrandGlyph? { glyphs[slug] }
}

extension BrandMark {
    /// How a mark is drawn. Every service has the same dark tile; only the mark's colour changes, by what reads on it.
    enum Treatment: Equatable, Sendable {
        /// The brand colour on the dark tile.
        case brandOnDark
        /// White on the dark tile: the brand's colour is too dark to read there (GitHub, Notion, Sentry, Slack, Atlassian).
        case whiteOnDark
    }

    /// The dark tile's colour (`Palette.raised`), what the contrast is judged against.
    static let darkTileHex: UInt32 = 0x222222
    /// Below this contrast against the dark tile (WCAG asks 3:1 for graphics) the colour is not used as the mark's colour.
    static let minimumContrast = 3.0

    var treatment: Treatment { Self.readsOnDarkTile(hex) ? .brandOnDark : .whiteOnDark }

    /// Whether a colour can be the colour of a mark on the dark tile (a brand's, or a generic connector's symbol).
    static func readsOnDarkTile(_ hex: UInt32) -> Bool { contrast(hex, darkTileHex) >= minimumContrast }

    /// WCAG relative luminance of a 0xRRGGBB colour.
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /// WCAG contrast ratio between two colours, from 1 to 21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }
}
