import SwiftUI

struct TranscriptRow: View {
    let item: TranscriptItem
    let bot: Bot

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments):
            UserBubble(text: text, attachments: attachments)
        case .bot(let text, let isStreaming):
            BotMessage(bot: bot, text: text, isStreaming: isStreaming)
        case .tool(let call):
            ToolCallLine(call: call)
        case .approval(let request):
            ApprovalCard(request: request, bot: bot)
        case .notice(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.faint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }
}

/// Left gutter width shared by bot messages, tool lines and approvals.
private let gutter: CGFloat = 36

private struct UserBubble: View {
    let text: String
    let attachments: [String]

    var body: some View {
        HStack {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { name in
                            Label(name, systemImage: "doc")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .card(radius: 10)
                        }
                    }
                }
                Text(text)
                    .font(Palette.conversationFont)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Palette.userBubble, in: .rect(cornerRadius: 18))
            }
        }
    }
}

private struct BotMessage: View {
    let bot: Bot
    let text: String
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            BotAvatar(bot: bot, size: 30, animated: false)
            (Text(Self.markdown(text)) + Text(isStreaming ? " ●" : "").foregroundColor(Palette.faint))
                .font(Palette.conversationFont)
                .foregroundStyle(Palette.ink)
                .lineSpacing(Palette.conversationLineSpacing)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Palette.agentBubble, in: .rect(cornerRadius: 18))
            Spacer(minLength: 80)
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Quiet one-line activity entry (shimmers while running); expands to show output.
struct ToolCallLine: View {
    let call: ToolCall
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: call.kind.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                        .frame(width: 14)
                    (Text(call.title).foregroundColor(Palette.muted)
                        + Text("  \(call.detail)").foregroundColor(Palette.faint))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .shimmer(active: call.state == .running)
                    stateMark
                    if call.output != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.faint)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(call.output == nil)

            if isExpanded, let output = call.output {
                Text(output)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(radius: 10)
                    .transition(.opacity)
            }
        }
        .padding(.leading, gutter)
    }

    @ViewBuilder private var stateMark: some View {
        switch call.state {
        case .running:
            EmptyView()
        case .done:
            if let duration = call.duration {
                (Text(duration, format: .number.precision(.fractionLength(1))) + Text("s"))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Palette.faint)
            }
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(Palette.danger)
                .accessibilityLabel("Falhou")
        }
    }
}

/// Approval prompt. Three outcomes: deny, allow once, always allow for this bot.
struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let request: ApprovalRequest
    let bot: Bot

    private var isPending: Bool { request.decision == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(request.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                if let decision = request.decision {
                    Text(decision.label)
                        .font(.system(size: 12))
                        .foregroundStyle(decision == .deny ? Palette.danger : Palette.muted)
                }
            }
            if !request.reason.isEmpty {
                Text(request.reason)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            Text(request.command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.secondary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.raised, in: .rect(cornerRadius: 8))
            if isPending {
                HStack(spacing: 6) {
                    Button("Não permitir") {
                        model.decide(.deny, approvalID: request.id, botID: bot.id)
                    }
                    .buttonStyle(GhostStyle())
                    Spacer()
                    Button("Sempre permitir") {
                        model.decide(.always, approvalID: request.id, botID: bot.id)
                    }
                    .buttonStyle(SecondaryPillStyle())
                    Button("Permitir uma vez") {
                        model.decide(.once, approvalID: request.id, botID: bot.id)
                    }
                    .buttonStyle(PrimaryPillStyle())
                }
            }
        }
        .padding(14)
        .card(radius: 12, stroke: isPending ? Palette.lineStrong : Palette.line)
        .opacity(isPending ? 1 : 0.7)
        .padding(.leading, gutter)
        .frame(maxWidth: 560, alignment: .leading)
        .animation(.snappy, value: request.decision)
    }
}
