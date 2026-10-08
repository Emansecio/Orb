import SwiftUI

/// Equatable: while a reply streams, only the row whose item changed re-renders.
struct TranscriptRow: View, Equatable {
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
                        ForEach(attachments, id: \.self) { attachment in
                            if attachment.hasPrefix("/"), ImageProcessing.isImageFile(URL(fileURLWithPath: attachment)) {
                                // Conversations from before this stored only the file name, which shows as a chip below.
                                Button { NSWorkspace.shared.open(URL(fileURLWithPath: attachment)) } label: {
                                    ImageThumbnail(path: attachment, side: 96)
                                }
                                .buttonStyle(.plain)
                                .help("Abrir " + URL(fileURLWithPath: attachment).lastPathComponent)
                            } else {
                                Label((attachment as NSString).lastPathComponent, systemImage: "doc")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .card(radius: 10)
                            }
                        }
                    }
                }
                if !text.isEmpty {
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
}

private struct BotMessage: View {
    let bot: Bot
    let text: String
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            BotAvatar(bot: bot, size: 30, animated: false)
            content
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

    /// While streaming, the finished paragraphs and the one being written are two texts (rendered
    /// pixel-identical to one), so each update re-parses and re-lays out only the last paragraph.
    @ViewBuilder private var content: some View {
        if isStreaming, let lastBreak = text.range(of: "\n\n", options: .backwards) {
            VStack(alignment: .leading, spacing: Palette.conversationLineSpacing) {
                MarkdownText(source: text[..<lastBreak.lowerBound] + "\n")
                MarkdownText(source: String(text[lastBreak.upperBound...]), showsCursor: true)
            }
        } else {
            MarkdownText(source: text, showsCursor: isStreaming)
        }
    }
}

/// Inline Markdown. Equatable on its source, so unchanged text is neither re-parsed nor re-measured.
private struct MarkdownText: View, Equatable {
    let source: String
    var showsCursor = false

    var body: some View {
        Text(Self.parse(source)) + Text(showsCursor ? " ●" : "").foregroundColor(Palette.faint)
    }

    private static func parse(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Quiet one-line activity entry (shimmers while running); expands to show output.
struct ToolCallLine: View {
    let call: ToolCall
    @State private var isExpanded = false
    /// Found once per output, not on every render.
    @State private var permissionProblem: MacPermissionProblem?

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
            .animateChanges(of: call.state)

            if call.state == .failed, let problem = permissionProblem {
                OpenPrivacySettingsButton(problem: problem).padding(.leading, 22)
            }

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
        .task(id: call.state == .failed ? call.output : nil) {
            permissionProblem = call.state == .failed ? call.output.flatMap(MacPermissionProblem.detect(in:)) : nil
        }
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

/// Approval prompt: allow, allow for this task, always allow (by a rule picked from the suggestions), or deny, with
/// a line to tell the Orb what to do instead. A card for several actions lists them and adds "Revisar uma a uma".
/// Destructive commands and changes to the Orb's instructions offer only allow and deny. ⌘↩ allows and Esc denies
/// on the Orb's newest open card.
struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let request: ApprovalRequest
    let bot: Bot

    @State private var note = ""
    @FocusState private var noteFocused: Bool
    /// `noteFocused` as the key handler needs it (a focus state is only meant to be read while drawing).
    @State private var isEditingNote = false

    private var isPending: Bool { request.decision == nil }
    private var allowTitle: String { request.isBatch ? "Permitir as \(request.items.count)" : "Permitir" }
    private static let visibleItems = 8

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
            if request.isBatch {
                batchList
            } else {
                Text(request.command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.raised, in: .rect(cornerRadius: 8))
            }
            if let note = request.note {
                Text("Você disse: \(note)")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            if isPending {
                TextField("Diga o que fazer em vez disso…", text: $note)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($noteFocused)
                    .onSubmit(deny)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Palette.raised.opacity(0.6), in: .rect(cornerRadius: 8))
                    .accessibilityLabel("Instrução ao negar")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { denyButtons; Spacer(); allowButtons }
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 6) { denyButtons; Spacer() }
                        HStack(spacing: 6) { Spacer(); allowButtons }
                    }
                }
            }
        }
        .padding(14)
        .card(radius: 12, stroke: isPending ? Palette.lineStrong : Palette.line)
        .opacity(isPending ? 1 : 0.7)
        .padding(.leading, gutter)
        .frame(maxWidth: 560, alignment: .leading)
        .animateChanges(of: request.decision)
        .onChange(of: noteFocused) { isEditingNote = noteFocused }
        .background {
            if isPending { ApprovalKeyMonitor(handler: handleKey) }
        }
    }

    private var batchList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(request.items.prefix(Self.visibleItems).enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                    if !item.command.isEmpty {
                        Text(item.command)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                    }
                }
            }
            if request.items.count > Self.visibleItems {
                Text("e mais \(request.items.count - Self.visibleItems)")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.faint)
            }
        }
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.raised, in: .rect(cornerRadius: 8))
    }

    @ViewBuilder private var denyButtons: some View {
        Button("Não permitir", action: deny)
            .buttonStyle(GhostStyle())
            .help("Não permitir (esc)")
        if request.isBatch {
            Button("Revisar uma a uma") {
                model.decide(.review, approvalID: request.id, botID: bot.id)
            }
            .buttonStyle(GhostStyle())
            .help("Uma pergunta para cada ação")
        }
    }

    @ViewBuilder private var allowButtons: some View {
        if let suggestion = request.suggestions.first {
            Menu {
                ForEach(request.suggestions, id: \.self) { rule in
                    Button(rule.menuTitle) {
                        model.decide(.always, rule: rule, approvalID: request.id, botID: bot.id)
                    }
                }
            } label: {
                Text("Sempre…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.1), in: .capsule)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Deixa de perguntar daqui para frente. Você pode revogar em Trabalho, no painel do Orb.")
            Button("Só nesta tarefa") {
                // A single card grants its first rule; a grouped one, everything it offered.
                model.decide(.task, rule: request.isBatch ? nil : suggestion, approvalID: request.id, botID: bot.id)
            }
            .buttonStyle(SecondaryPillStyle())
            .help(request.isBatch
                  ? "Vale até o Orb terminar esta tarefa: \(request.suggestions.map { $0.title.lowercased() }.joined(separator: "; "))."
                  : "Vale até o Orb terminar esta tarefa: \(suggestion.title.lowercased()).")
        }
        Button(allowTitle) {
            model.decide(.once, approvalID: request.id, botID: bot.id)
        }
        .buttonStyle(PrimaryPillStyle())
        .help("\(allowTitle) (⌘↩)")
    }

    private func deny() {
        model.decide(.deny, note: note, approvalID: request.id, botID: bot.id)
    }

    /// ⌘↩ and Esc answer this card when it is the newest open one of the Orb being shown.
    private func handleKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard model.selectedBot?.id == bot.id, model.newestPendingApprovalID(of: bot.id) == request.id else { return false }
        let field = window.firstResponder as? NSTextView
        let editing = ApprovalShortcut.isEditing(responderIsText: field != nil, hasText: field.map { !$0.string.isEmpty } ?? false,
                                                 hasMarkedText: field?.hasMarkedText() ?? false, noteFocused: isEditingNote)
        switch ApprovalShortcut.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags, isEditingText: editing) {
        case .allow: model.decide(.once, approvalID: request.id, botID: bot.id)
        case .deny: deny()
        case nil: return false
        }
        return true
    }
}
