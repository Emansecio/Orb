import SwiftUI

// A member's words in a group read like one Orb's reply in the single chat (BotMessage): the reply's bubble beside the
// Orb's avatar, its name above, "Copiar" beside the bubble on hover. The person's own words keep their bubble.

/// The color that stands for an Orb: its palette's core (bars, borders, rings). Gray for an Orb that is gone.
enum OrbColor {
    static func core(_ orb: OrbConfig?) -> Color {
        orb.map { OrbCatalog.shared.palette($0.color).core } ?? Palette.muted
    }
}

/// Orb colors as TEXT on the app's canvas: the palette's core lifted toward white until it reads (WCAG 4.5 : 1). Borders and
/// rings keep the pure core (`OrbColor`); only words use this. Pure, so the contrast is tested.
enum OrbInk {
    static let minimumContrast = 4.5
    /// Palette.canvas (#070707), the background the words sit on.
    static let canvas: UInt32 = Palette.canvasHex

    /// The name color of an Orb's words; a readable gray for an Orb that is gone.
    static func readableName(for orb: OrbConfig?) -> Color {
        Color(hex: readableHex(of: orb.map { OrbCatalog.shared.palette($0.color).hexes[1] } ?? 0x9A9A9A))
    }

    /// The core as hex, lifted toward white in steps of 2 % until it meets `minimumContrast` on `background`.
    static func readableHex(of core: UInt32, on background: UInt32 = canvas) -> UInt32 {
        var lift = 0.0
        while lift <= 1.0 {
            let mixed = mix(core, toward: 0xFFFFFF, by: lift)
            if contrast(mixed, background) >= minimumContrast { return mixed }
            lift += 0.02
        }
        return 0xFFFFFF
    }

    /// `color` moved `amount` (0...1) of the way to `target`, channel by channel.
    static func mix(_ color: UInt32, toward target: UInt32, by amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let from = Double((color >> shift) & 0xFF), to = Double((target >> shift) & 0xFF)
            return UInt32((from + (to - from) * amount).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }

    /// The WCAG relative luminance of an sRGB color.
    static func luminance(_ hex: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }

    /// The WCAG contrast ratio between two colors (1 ... 21).
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (light, dark) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (light + 0.05) / (dark + 0.05)
    }
}

/// A member's words in a group's thread, as one Orb's reply reads in the single chat. Consecutive words of the same Orb are
/// grouped: only the first one shows the avatar and the header; the others sit under it.
struct GroupMessageBubble: View {
    let message: OrbMessageItem
    /// The Orb as it is now; nil once it is deleted (the name the message kept is shown, in gray).
    let look: BotLook?
    let isOrchestrator: Bool
    /// The last speaker of the thread: its avatar lives; the ones above rest in the same pose.
    var isLastSpeaker = false
    /// The first of a run of words from this Orb: the avatar and the name line. Others continue under it.
    var showsHeader = true

    @State private var hovering = false

    private var name: String { look?.name ?? message.from.name }

    var body: some View {
        // 6 pt from the name to the words: without a bubble's padding, 4 pt glued them.
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader { header }
            text
                .replyText()
                .overlay(alignment: .bottomTrailing) {
                    // Beside the text, in the space the right padding leaves (as a reply's buttons in the single chat).
                    CopyButton(symbol: "doc.on.doc", help: "Copiar", copiedHelp: "Copiado") {
                        Clipboard.copy(MarkdownBlocks.plainText(of: message.text))
                    }
                        .fixedSize()
                        .alignmentGuide(.trailing) { $0[.leading] - 6 }
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                }
        }
        .padding(.leading, gutter)
        .padding(.trailing, 40)
        .frame(maxWidth: 720, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if showsHeader { avatar.frame(width: 30, height: 30).accessibilityHidden(true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(Motion.hover(hovering), value: hovering)
        .contextMenu {
            Button("Copiar") { Clipboard.copy(MarkdownBlocks.plainText(of: message.text)) }
            Button("Copiar como Markdown") { Clipboard.copy(message.text) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Self.spokenKind(message.kind)) de \(name)\(isOrchestrator ? ", orquestrador" : "")")
        .accessibilityAction(named: "Copiar resposta") { Clipboard.copy(MarkdownBlocks.plainText(of: message.text)) }
    }

    /// What VoiceOver calls the message: the group's thread and the exchange sheet show requests and notices here too, not
    /// only answers.
    static func spokenKind(_ kind: OrbMessageItem.Kind) -> String {
        switch kind {
        case .reply: "Resposta"
        case .ask: "Pedido"
        case .tell: "Mensagem"
        }
    }

    /// The name in the Orb's readable tint, its role in faint, and "orquestrador" as a quiet inline detail (no pill).
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name.isEmpty ? "Orb" : name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OrbInk.readableName(for: look?.orb))
            if let role = look?.role, !role.isEmpty {
                Text(role)
                    .font(Typography.small)
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
            }
            if isOrchestrator {
                Label("orquestrador", systemImage: "arrow.triangle.branch")
                    .font(Typography.small)
                    .foregroundStyle(Palette.faint)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.top, Spacing.xs)
    }

    private var text: some View {
        MarkdownChunk(source: message.text).equatable()
            .font(Palette.conversationFont)
            .foregroundStyle(Palette.ink)
            .lineSpacing(Palette.conversationLineSpacing)
            .textSelection(.enabled)
    }

    @ViewBuilder private var avatar: some View {
        if let look {
            // The living avatar passes to the newest answer with a fade, as in an Orb's chat (only opacity, so it is the
            // same under Reduce Motion).
            ZStack {
                if isLastSpeaker {
                    LiveBotAvatar(botID: look.id, orb: look.orb, size: 30, restsWhenIdle: true)
                        .transition(.opacity)
                } else {
                    BotAvatar(orb: look.orb, size: 30, animated: false)
                        .transition(.opacity)
                }
            }
            .animation(Motion.fade, value: isLastSpeaker)
        } else {
            Circle().fill(Palette.raised)
        }
    }
}

/// The person's message in a group's thread: the same bubble as everywhere in the app, on the right, without a name (the
/// side and the fill say whose it is; VoiceOver reads "Você").
struct GroupUserBubble: View {
    let text: String
    /// The paths of the pictures that went with the message (as in an Orb's chat; empty for older threads).
    var attachments: [String] = []

    var body: some View {
        HStack {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty { AttachmentStack(paths: attachments) }
                // Pictures alone make a message with no text bubble.
                if !text.isEmpty {
                    Text(text)
                        .foregroundStyle(Palette.ink)
                        .lineSpacing(Palette.conversationLineSpacing)
                        .userBubble()
                        .accessibilityLabel(TranscriptSpeech.user(text: text, attachmentCount: attachments.count))
                        // Editing does not fit a group, which cannot go back; copying does.
                        .contextMenu { Button("Copiar") { Clipboard.copy(text) } }
                }
            }
        }
    }
}

/// An assignment the orchestrator (or a member) made: two 16 pt avatars and an arrow, then the words "pediu ao Pesquisador:
/// Levante…" in one quiet line; a click unfolds the whole text.
struct GroupAssignmentLine: View {
    let message: OrbMessageItem
    let from: BotLook?
    let to: BotLook?
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let toName = to?.name ?? message.to?.name ?? "outro Orb"
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    miniAvatar(from)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.hint)
                    miniAvatar(to)
                    Text(GroupAssignmentLine.sentence(kind: message.kind, toName: toName, text: message.text,
                                                      fromChat: message.fromChat == true))
                        .font(Typography.label)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ExchangeStateMark(state: message.state, showsWord: false)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(Motion.panel(reduceMotion: reduceMotion), value: expanded)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(expanded ? "Recolhe o texto do pedido" : "Mostra o texto do pedido")
            if expanded {
                Text(message.text)
                    .font(Typography.text)
                    .foregroundStyle(Palette.secondary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: 680, alignment: .leading)
                    .card(radius: Radius.medium)
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
        }
        .padding(.leading, gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pedido de \(from?.name ?? message.from.name) a \(toName)\(message.fromChat == true ? ", a seu pedido" : "")")
        .accessibilityValue(ExchangeStateMark.spoken(message.state))
    }

    private func miniAvatar(_ look: BotLook?) -> some View {
        Group {
            if let look {
                BotAvatar(orb: look.orb, size: 16, animated: false)
            } else {
                Circle().fill(Palette.raised).frame(width: 16, height: 16)
            }
        }
        .accessibilityHidden(true)
    }

    /// "pediu ao Pesquisador: Levante três…" (or "avisou a Lia: …" for a tell: "avisar" takes the article, not "ao"), the first
    /// line of the text cut to 90 characters.
    /// A request a member sent from its chat because you asked says so: "pediu ao Atlas, a seu pedido: …".
    static func sentence(kind: OrbMessageItem.Kind, toName: String, text: String, fromChat: Bool = false) -> String {
        let to = kind == .tell ? "avisou \(PortugueseArticle.article(for: toName))"
            : "pediu \(PortugueseArticle.contraction(for: toName))"
        return "\(to) \(toName)\(fromChat ? ", a seu pedido" : ""): \(oneLine(text))"
    }

    /// The first line of the text, cut to 90 characters (the line says the rest is in the card).
    static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 90 ? String(line.prefix(89)) + "…" : line
    }
}
