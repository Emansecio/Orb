import SwiftUI

/// Review samples for `--snapshot` (see `Snapshot` in OrbApp.swift): the menu bar panel with permission requests and a
/// reply, and the menu bar icon's three states. Nothing here runs in the app itself.
@MainActor
enum SystemSnapshots {
    static func quickAsk(_ model: AppModel, approvals: Bool, reply: Bool = false) -> AnyView {
        guard let bot = model.bots.first else { return AnyView(EmptyView()) }
        if approvals {
            let batch = ApprovalRequest(
                toolName: "batch", title: "4 ações precisam da sua permissão", command: "", reason: "\(bot.name) precisa da sua permissão para continuar.",
                items: [ApprovalItem(toolName: "write_file", title: "Gravando arquivo", command: "~/Projetos/app/README.md"),
                        ApprovalItem(toolName: "write_file", title: "Gravando arquivo", command: "~/Projetos/app/notas.txt"),
                        ApprovalItem(toolName: "run_command", title: "Rodando no Terminal", command: "git commit -am \"Atualiza notas\""),
                        ApprovalItem(toolName: "run_command", title: "Rodando no Terminal", command: "git push")])
            let single = ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "brew upgrade",
                                         reason: "Atualizar os pacotes que estão desatualizados.")
            var risky = ApprovalRequest(toolName: "run_command", title: "Rodando no Terminal", command: "rm -rf ~/Projetos/app/build", reason: "")
            risky.isDangerous = true
            return AnyView(VStack(alignment: .leading, spacing: 10) {
                QuickAskApprovalCard(entry: PendingApproval(bot: bot, request: batch), openApp: {})
                QuickAskApprovalCard(entry: PendingApproval(bot: bot, request: single), openApp: {})
                QuickAskApprovalCard(entry: PendingApproval(bot: bot, request: risky), openApp: {})
            }
            .padding(14)
            .frame(width: 340)
            .background(Color(white: 0.12))
            .clipShape(.rect(cornerRadius: 12))
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            if reply {
                QuickAskReply(botID: bot.id, openChat: {}, dismiss: {},
                              sample: QuickAskReplyText.Reply(itemID: UUID(), text: "Você tem 184 GB livres de 460 GB.\n\nAs maiores pastas são:\n- Biblioteca: 92 GB\n- Filmes: 41 GB\n- Downloads: 18 GB\n- Projetos: 9 GB\n\nPosso esvaziar os Downloads antigos se você quiser.", isStreaming: false))
                    .padding(14).frame(width: 340)
            }
            QuickAskView()
        }
        .background(Color(white: 0.12))
        .clipShape(.rect(cornerRadius: 12))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }

    /// The three states on a dark and a light menu bar.
    static func menuBarIcons() -> AnyView {
        func row(_ background: Color, _ scheme: ColorScheme) -> some View {
            HStack(spacing: 22) {
                ForEach([MenuBarState.idle, .working(1), .waiting(1)], id: \.accessibilityLabel) { state in
                    Image(nsImage: MenuBarIcon.image(for: state)).renderingMode(.template)
                        .foregroundStyle(scheme == .dark ? Color.white : Color.black).scaleEffect(2)
                }
            }
            .padding(24)
            .background(background)
            .environment(\.colorScheme, scheme)
        }
        return AnyView(VStack(spacing: 0) {
            row(Color(white: 0.1), .dark)
            row(Color(white: 0.92), .light)
        })
    }
}
