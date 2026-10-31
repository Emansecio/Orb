import SwiftUI

/// The top bar of a group's chat: its Orbs one over the other and "N Orbs". While a request runs it also shows what the request
/// has spent ("3 turnos · 42 mil tokens"), Parar grupo and the panel's button.
struct GroupHeader: View {
    let name: String
    let members: [StackedAvatars.Member]
    let orbCount: Int
    let usage: GroupUsage?
    /// A request is running: Parar grupo is offered.
    let isActive: Bool
    let onStop: () -> Void
    let onPanel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.m) {
            StackedAvatars(members: members, size: 24)
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Text(orbCount == 1 ? "· 1 Orb" : "· \(orbCount) Orbs")
                .font(Typography.label)
                .foregroundStyle(Palette.faint)
                .lineLimit(1)
                .accessibilityIdentifier("group-orb-count")
            Spacer(minLength: 12)
            if let usage {
                Text(GroupUsageText.summary(turns: usage.turnsUsed, tokens: usage.tokensUsed))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .help("Usados neste pedido")
                    .transition(.adapted(.opacity, reduceMotion: reduceMotion))
            }
            if isActive {
                Button(action: onStop) {
                    Label("Parar grupo", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .medium))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(GhostStyle(tint: Palette.danger))
                // Never squeezed: in a narrow window it broke letter by letter while the name still had room to shrink.
                .fixedSize()
                .help("Parar o grupo: cancela os turnos e a fila (⌘.)")
                .transition(.adapted(.opacity, reduceMotion: reduceMotion))
            }
            Button("Painel do grupo", systemImage: "sidebar.right", action: onPanel)
                .labelStyle(.iconOnly)
                .buttonStyle(CircleGhostStyle(side: 28, fontSize: 13))
                .foregroundStyle(Palette.muted)
                .help("Mostrar ou ocultar o painel do grupo (⌥⌘B)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Palette.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        .animation(reduceMotion ? Motion.fade : Motion.content, value: usage != nil)
        .animation(reduceMotion ? Motion.fade : Motion.content, value: isActive)
    }
}
