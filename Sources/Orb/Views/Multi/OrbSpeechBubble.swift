import SwiftUI

/// What an Orb says in an exchange or a group, drawn as a reply of an Orb in the chat is drawn (`BotMessage`): no bubble, the
/// avatar at the left, a header with the name in a lighter tint of the Orb's color and its role, then the text as Markdown.
/// Every Orb speaks on the left, whoever it is: the bubble on the right belongs to the person (docs/MULTI-ORBS.md, 8.10).
/// `continues`: the same Orb spoke just before, so the avatar and the header are left out and the text follows closely.
struct OrbSpeechBubble: View {
    let orb: OrbConfig
    let name: String
    var role: String?
    let text: String
    var continues = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // The avatar's place stays when it is left out, so the text of a run lines up with the first one.
            Group {
                if continues {
                    Color.clear
                } else {
                    BotAvatar(orb: orb, size: 30, animated: false)
                }
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if !continues {
                    header
                }
                Text(Self.attributed(text))
                    .font(Palette.conversationFont)
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(Palette.conversationLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Self.nameTint(OrbCatalog.shared.palette(orb.color)))
            if let role, !role.isEmpty {
                Text(role)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
            }
        }
    }

    /// The Orb's color lifted toward white (45 %), so the name reads on the dark canvas (its own color is too dark for small text
    /// in some palettes).
    static func nameTint(_ palette: OrbPalette) -> Color {
        let hex = palette.hexes[1]
        func lifted(_ shift: UInt32) -> Double {
            let channel = Double((hex >> shift) & 0xFF)
            return (channel + (255 - channel) * 0.45) / 255
        }
        return Color(red: lifted(16), green: lifted(8), blue: lifted(0))
    }

    /// The text with its inline Markdown (bold, code, links); what the Markdown cannot read stays as it is.
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
