import SwiftUI

// The one "Orb speaking" style (8.10 item 1): the same in the group's thread, in an exchange and on a received request. The
// avatar, the name in the Orb's own color, the orchestrator's pill, a 2 pt bar in that color, the Markdown, "Copiar" on hover.

/// The color that stands for an Orb in its words and its bar: its palette's core. Gray for an Orb that is gone.
enum OrbColor {
    static func core(_ orb: OrbConfig?) -> Color {
        orb.map { OrbCatalog.shared.palette($0.color).core } ?? Palette.muted
    }
}

/// A member's message in a group (a reply to the one who asked, or the final answer of the orchestrator).
struct GroupMessageBubble: View {
    @Environment(AppModel.self) private var model
    let message: OrbMessageItem
    /// The Orb as it is now; nil once it is deleted (the name the message kept is shown, in gray).
    let look: BotLook?
    let isOrchestrator: Bool
    /// The last speaker of the thread: its avatar lives; the ones above rest in the same pose.
    var isLastSpeaker = false

    @State private var hovering = false
    @State private var flash = CopiedFlash()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var name: String { look?.name ?? message.from.name }
    private var core: Color { OrbColor.core(look?.orb) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name.isEmpty ? "Orb" : name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(core)
                    if isOrchestrator { OrchestratorPill() }
                }
                HStack(alignment: .top, spacing: 0) {
                    Rectangle().fill(core).frame(width: 2)
                    MarkdownChunk(source: message.text).equatable()
                        .font(Palette.conversationFont)
                        .foregroundStyle(Palette.ink)
                        .lineSpacing(Palette.conversationLineSpacing)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
                .background(Palette.agentBubble, in: .rect(cornerRadius: 14))
                .clipShape(.rect(cornerRadius: 14))
                copyButton
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                    .frame(height: 20, alignment: .leading)
            }
            .frame(maxWidth: 680, alignment: .leading)
            Spacer(minLength: 0)
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
        .accessibilityLabel("Resposta de \(name)\(isOrchestrator ? ", orquestrador" : "")")
        .accessibilityAction(named: "Copiar resposta") { Clipboard.copy(MarkdownBlocks.plainText(of: message.text)) }
    }

    @ViewBuilder private var avatar: some View {
        if let look {
            if isLastSpeaker {
                LiveBotAvatar(botID: look.id, orb: look.orb, size: 30, restsWhenIdle: true)
            } else {
                BotAvatar(orb: look.orb, size: 30, animated: false)
            }
        } else {
            Circle().fill(Palette.raised)
        }
    }

    private var copyButton: some View {
        Button {
            Clipboard.copy(MarkdownBlocks.plainText(of: message.text))
            flash.trigger()
        } label: {
            Label(flash.isOn ? "Copiado" : "Copiar", systemImage: flash.isOn ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Palette.surface, in: .capsule)
                .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Copia a resposta sem a formatação")
    }
}

/// "Orquestrador" in a small pill, with the branch mark: the Orb that splits the work.
struct OrchestratorPill: View {
    var body: some View {
        Label("Orquestrador", systemImage: "arrow.triangle.branch")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Palette.raised, in: .capsule)
            .accessibilityHidden(true)
    }
}

/// The person's message in a group's thread: the same bubble as everywhere in the app (the one that belongs to "Você").
struct GroupUserBubble: View {
    let text: String
    var attachmentCount = 0

    var body: some View {
        HStack {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 6) {
                Text("Você")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .padding(.trailing, 4)
                    .accessibilityHidden(true)
                Text(text)
                    .font(Palette.conversationFont)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Palette.userBubble, in: .rect(cornerRadius: 16))
                    .accessibilityLabel("Você: \(text)")
            }
        }
    }
}

/// An assignment the orchestrator (or a member) made ("Atlas → Pesquisador: …"): one quiet line that opens the text.
struct GroupAssignmentLine: View {
    let message: OrbMessageItem
    let from: BotLook?
    let to: BotLook?
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fromName = from?.name ?? message.from.name
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
                    Text("\(fromName) → \(toName): \(GroupAssignmentLine.oneLine(message.text))")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
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
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: 680, alignment: .leading)
                    .card(radius: 10)
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
        }
        .padding(.leading, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pedido de \(fromName) a \(toName)")
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

    /// The first line of the text, cut to 90 characters (the line says the rest is in the card).
    static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 90 ? String(line.prefix(89)) + "…" : line
    }
}
