import SwiftUI

/// Equatable: while a reply streams, the list does not redraw at all (the text is a `LiveText` its own views read);
/// when the transcript changes, only the row whose item changed re-renders.
struct TranscriptRow: View, Equatable {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem
    /// Only what a row shows of its Orb (its avatar, and whose card an approval is), not the whole `Bot`: changing
    /// the Orb's permissions or folder does not re-render the visible rows.
    let botID: UUID
    let orb: OrbConfig

    nonisolated static func == (lhs: TranscriptRow, rhs: TranscriptRow) -> Bool {
        lhs.item == rhs.item && lhs.botID == rhs.botID && lhs.orb == rhs.orb
    }

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments):
            UserBubble(text: text, attachments: attachments)
        case .bot(let text, let isStreaming):
            BotMessage(orb: orb, text: text, live: isStreaming ? model.liveText(for: item.id, of: botID) : nil)
        case .tool(let call):
            ToolCallLine(call: call)
        case .approval(let request):
            ApprovalCard(request: request, botID: botID)
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

/// A reply of the Orb. While it streams, `live` has its text and the views below read it; the row itself is not
/// redrawn per flush. Once it is done it is one text again, which can be selected from the first word to the last
/// (and is cheaper to keep on screen: every text on screen is asked its size at each frame of an animation).
private struct BotMessage: View {
    let orb: OrbConfig
    let text: String
    let live: LiveText?

    // The bubble is padded and given the row's width instead of sharing an HStack with the avatar and a Spacer:
    // the text then gets one definite width to wrap to (an HStack asks for several sizes, and each one lays the
    // whole text out). The avatar floats over the left padding; the right one is 80 and the HStack's spacing, 10.
    var body: some View {
        content
            .font(Palette.conversationFont)
            .foregroundStyle(Palette.ink)
            .lineSpacing(Palette.conversationLineSpacing)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Palette.agentBubble, in: .rect(cornerRadius: 18))
            .padding(.leading, 40)
            .padding(.trailing, 90)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottomLeading) {
                BotAvatar(orb: orb, size: 30, animated: false)
            }
    }

    @ViewBuilder private var content: some View {
        if let live {
            ParagraphStack(live: live)
        } else {
            MarkdownText(source: text)
        }
    }
}

/// The reply being streamed as paragraphs: the finished ones keep their identity and text (so they are neither
/// parsed nor measured again) and only the last, the one being written, changes. Rendered pixel-identical to one text.
private struct ParagraphStack: View {
    let live: LiveText

    var body: some View {
        VStack(alignment: .leading, spacing: Palette.conversationLineSpacing) {
            ClosedParagraphs(live: live)
            LastParagraph(live: live)
        }
    }
}

/// Reads only the finished paragraphs, so it is redrawn when a paragraph ends, not on every flush.
private struct ClosedParagraphs: View {
    let live: LiveText

    var body: some View {
        ForEach(Array(live.closed.enumerated()), id: \.offset) { _, paragraph in
            MarkdownText(source: paragraph, endsParagraph: true, streaming: true).equatable()
        }
    }
}

/// Reads only the paragraph being written.
private struct LastParagraph: View {
    let live: LiveText
    @Environment(\.replyGrew) private var replyGrew

    var body: some View {
        MarkdownText(source: live.tail, streaming: true)
            .onChange(of: live.tail.utf8.count) { replyGrew?() }
    }
}

extension EnvironmentValues {
    /// Called when the reply being streamed grows, by a list that has to scroll to follow it itself.
    @Entry var replyGrew: (@MainActor () -> Void)?
}

/// Inline Markdown. Equatable on its source, so unchanged text is neither re-parsed nor re-measured. `endsParagraph`
/// is a paragraph followed by another: the blank line between them is part of its text (as it is in the whole reply).
/// `streaming` is a piece of the reply being written (it is not kept in `MarkdownCache`, the finished text is); the
/// cursor follows the last one.
private struct MarkdownText: View, Equatable {
    let source: String
    var endsParagraph = false
    var streaming = false

    var body: some View {
        Text(MarkdownCache.attributed(source, endsParagraph: endsParagraph, cached: !streaming))
            + Text(streaming && !endsParagraph ? " ●" : "").foregroundColor(Palette.faint)
    }
}

/// The parsed Markdown of text that is done changing, so a row the LazyVStack recreates while scrolling (or a
/// paragraph that moves from "being written" to "finished") is not parsed again. Two generations: when the newer one
/// is full the older is dropped, so memory stays bounded and what was used lately survives.
@MainActor
enum MarkdownCache {
    private struct Key: Hashable {
        let source: String
        let endsParagraph: Bool
    }

    private static var recent: [Key: AttributedString] = [:]
    private static var older: [Key: AttributedString] = [:]
    private static var recentBytes = 0
    /// UTF-8 bytes of source text a generation holds, and the longest text worth keeping.
    private static let generationBytes = 512 * 1024
    private static let longestText = 64 * 1024

    static func attributed(_ source: String, endsParagraph: Bool = false, cached: Bool = true) -> AttributedString {
        let size = source.utf8.count
        guard cached, size <= longestText else { return parse(source, endsParagraph: endsParagraph) }
        let key = Key(source: source, endsParagraph: endsParagraph)
        if let hit = recent[key] { return hit }
        if let hit = older[key] {
            remember(hit, for: key, size: size)
            return hit
        }
        let parsed = parse(source, endsParagraph: endsParagraph)
        remember(parsed, for: key, size: size)
        return parsed
    }

    private static func remember(_ value: AttributedString, for key: Key, size: Int) {
        if recentBytes + size > generationBytes {
            older = recent
            recent = [:]
            recentBytes = 0
        }
        recent[key] = value
        recentBytes += size
    }

    /// Empties the cache (tests).
    static func removeAll() {
        recent = [:]
        older = [:]
        recentBytes = 0
    }

    static var count: Int { recent.count + older.count }

    private static func parse(_ text: String, endsParagraph: Bool) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let source = endsParagraph ? text + "\n" : text
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
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
                        .shimmer(active: call.state == .running, keepsColors: true)
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
    let botID: UUID

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
                model.decide(.review, approvalID: request.id, botID: botID)
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
                        model.decide(.always, rule: rule, approvalID: request.id, botID: botID)
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
                model.decide(.task, rule: request.isBatch ? nil : suggestion, approvalID: request.id, botID: botID)
            }
            .buttonStyle(SecondaryPillStyle())
            .help(request.isBatch
                  ? "Vale até o Orb terminar esta tarefa: \(request.suggestions.map { $0.title.lowercased() }.joined(separator: "; "))."
                  : "Vale até o Orb terminar esta tarefa: \(suggestion.title.lowercased()).")
        }
        Button(allowTitle) {
            model.decide(.once, approvalID: request.id, botID: botID)
        }
        .buttonStyle(PrimaryPillStyle())
        .help("\(allowTitle) (⌘↩)")
    }

    private func deny() {
        model.decide(.deny, note: note, approvalID: request.id, botID: botID)
    }

    /// ⌘↩ and Esc answer this card when it is the newest open one of the Orb being shown.
    private func handleKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard model.selectedBot?.id == botID, model.newestPendingApprovalID(of: botID) == request.id else { return false }
        let field = window.firstResponder as? NSTextView
        let editing = ApprovalShortcut.isEditing(responderIsText: field != nil, hasText: field.map { !$0.string.isEmpty } ?? false,
                                                 hasMarkedText: field?.hasMarkedText() ?? false, noteFocused: isEditingNote)
        switch ApprovalShortcut.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags, isEditingText: editing) {
        case .allow: model.decide(.once, approvalID: request.id, botID: botID)
        case .deny: deny()
        case nil: return false
        }
        return true
    }
}
