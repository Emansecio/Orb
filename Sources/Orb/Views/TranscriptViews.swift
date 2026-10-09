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
    /// The row just arrived in a chat that was open (the list says so). Not part of the row's identity: it is read
    /// once, when the row is made, by the one row that does something with it (the approval card's pulse).
    var entering = false
    /// This is the Orb's reply at the very end of the chat: its avatar is alive (the one Orb in view), and the
    /// working line below it hides its own. Part of the row's identity, so only the two rows that change re-render.
    var isLastReply = false

    nonisolated static func == (lhs: TranscriptRow, rhs: TranscriptRow) -> Bool {
        lhs.item == rhs.item && lhs.botID == rhs.botID && lhs.orb == rhs.orb && lhs.isLastReply == rhs.isLastReply
    }

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments):
            UserBubble(text: text, attachments: attachments)
        case .bot(let text, let isStreaming):
            BotMessage(orb: orb, botID: botID, text: text, live: isStreaming ? model.liveText(for: item.id, of: botID) : nil,
                       isLastReply: isLastReply)
        case .tool(let call):
            ToolCallLine(call: call)
        case .approval(let request):
            ApprovalCard(request: request, botID: botID, pulses: entering)
        case .notice(let text):
            NoticeLine(id: item.id, text: text, botID: botID)
        case .greeting(let text):
            GreetingMessage(orb: orb, botID: botID, text: text, isLast: isLastReply)
        }
    }
}

/// Left gutter width shared by bot messages, tool lines and approvals.
private let gutter: CGFloat = 36

// MARK: - Spoken labels

/// What VoiceOver says for the rows of the transcript, so it says who spoke instead of reading the avatar.
enum TranscriptSpeech {
    static func user(text: String, attachmentCount: Int) -> String {
        let attached = attachmentCount == 0 ? "" : attachmentCount == 1 ? ", com 1 anexo" : ", com \(attachmentCount) anexos"
        return "Você: \(text)\(attached)"
    }

    static func reply(of name: String) -> String { "Resposta de \(name)" }

    static func notice(_ text: String) -> String { "Aviso: \(text)" }

    static func approval(botName: String, title: String) -> String { "\(botName) pede permissão: \(title)" }
}

// MARK: - Messages

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
                                .accessibilityLabel("Imagem anexada: " + URL(fileURLWithPath: attachment).lastPathComponent)
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
                        .contextMenu { Button("Copiar") { Clipboard.copy(text) } }
                        .accessibilityLabel(TranscriptSpeech.user(text: text, attachmentCount: attachments.count))
                }
            }
        }
    }
}

/// A reply of the Orb. While it streams, `live` has its text and the views below read it; the row itself is not
/// redrawn per flush. Once it is done it is its blocks again (paragraphs, lists, code…) drawn from the whole text,
/// which is cached, and hovering it shows "Copiar" and "Copiar como Markdown" (the buttons, not only a context menu:
/// over selectable text the right click shows the system's menu). Selection works inside a block (a paragraph, a
/// list item, the code); it does not cross from one block to the next.
private struct BotMessage: View {
    @Environment(AppModel.self) private var model
    let orb: OrbConfig
    let botID: UUID
    let text: String
    let live: LiveText?
    let isLastReply: Bool

    @State private var hovering = false

    /// Read from this Orb's own state, so reordering or adding Orbs does not redraw the reply. A deleted Orb's
    /// stand-in has no name.
    private var orbName: String {
        let name = model.live(botID).look.name
        return name.isEmpty ? "Orb" : name
    }

    // The bubble is padded and given the row's width instead of sharing an HStack with the avatar and a Spacer:
    // the text then gets one definite width to wrap to (an HStack asks for several sizes, and each one lays the
    // whole text out). The avatar floats over the left padding; the right one is 80 and the HStack's spacing, 10.
    var body: some View {
        content
            // The reply's text never animates: not as it streams, and not when the last flush swaps the paragraphs for
            // the finished blocks, whatever the list around it is animating (the row's own entrance is outside this).
            .transaction { $0.animation = nil }
            .font(Palette.conversationFont)
            .foregroundStyle(Palette.ink)
            .lineSpacing(Palette.conversationLineSpacing)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Palette.agentBubble, in: .rect(cornerRadius: 18))
            .overlay(alignment: .bottomTrailing) {
                // Beside the bubble, in the space its right padding leaves; the row's hover keeps it up while the
                // pointer travels to it.
                if live == nil {
                    MessageActions(text: text)
                        .offset(x: 62)
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                }
            }
            .padding(.leading, 40)
            .padding(.trailing, 90)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottomLeading) {
                // The last reply of the chat has the one living Orb in view (it works, celebrates, watches you type, and
                // rests once idle); the ones above are still, in the same resting pose. When it stops being the last (a tool
                // line or a new message came in) the live one may be mid-expression: the two cross-fade (0.15 s) instead
                // of the expression jumping. The animation is tied to this flag, which changes rarely, not to the list.
                Group {
                    if isLastReply {
                        LiveBotAvatar(botID: botID, orb: orb, size: 30, restsWhenIdle: true)
                            .transition(.opacity)
                    } else {
                        BotAvatar(orb: orb, size: 30, animated: false)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.fade, value: isLastReply)
                .accessibilityHidden(true)
            }
            .onHover { if live == nil { hovering = $0 } }
            // Responds fast and lets go slowly (§2.7).
            .animation(Motion.hover(hovering), value: hovering)
            .contextMenu {
                if live == nil {
                    Button("Copiar") { Clipboard.copy(MarkdownBlocks.plainText(of: text)) }
                    Button("Copiar como Markdown") { Clipboard.copy(text) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(TranscriptSpeech.reply(of: orbName))
            .accessibilityAction(named: "Copiar resposta") {
                if live == nil { Clipboard.copy(MarkdownBlocks.plainText(of: text)) }
            }
    }

    @ViewBuilder private var content: some View {
        if let live {
            ParagraphStack(live: live)
        } else {
            MarkdownChunk(source: text).equatable()
        }
    }
}

/// A new Orb's first words: a reply like any other, and, while nothing was said after it, the ways to begin. It
/// comes in the first time the chat shows in the session (like the empty chat it replaces), never again.
private struct GreetingMessage: View {
    @Environment(\.presentedEmptyChats) private var presented
    let orb: OrbConfig
    let botID: UUID
    let text: String
    let isLast: Bool

    var body: some View {
        let enters = isLast && EmptyChatEntrance.plays(for: botID, in: presented)
        VStack(alignment: .leading, spacing: 10) {
            BotMessage(orb: orb, botID: botID, text: text, live: nil, isLastReply: isLast)
                .entrance(.rise, enters: enters)
            if isLast {
                GreetingReplies(botID: botID)
                    .transition(.opacity)
            }
        }
        .motion(Motion.exit, value: isLast)
        .onAppear { if isLast { presented?.insert(botID) } }
    }
}

/// The three quick replies. They go away when one is chosen or when the person starts to write (a draft), and come
/// back (fading) if the draft is erased; the only part of the chat that reads the drafts, so typing redraws nothing else.
private struct GreetingReplies: View {
    @Environment(AppModel.self) private var model
    @Environment(\.presentedEmptyChats) private var presented
    let botID: UUID

    var body: some View {
        // Read here, not handed down: once the greeting is on screen the Orb counts as presented, so the buttons that
        // come back after an erased draft only fade in.
        let enters = EmptyChatEntrance.plays(for: botID, in: presented)
        let isTyping = !(model.drafts[botID] ?? "").isEmpty
        VStack(spacing: 6) {
            if !isTyping {
                ForEach(Array(OrbGreeting.Reply.allCases.enumerated()), id: \.element) { index, reply in
                    SuggestionButton(symbol: reply.symbol, text: reply.title) { model.answerGreeting(reply, for: botID) }
                        .entrance(.staggered(index, start: EmptyChatEntrance.suggestionsStart), enters: enters)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: 360)
        .padding(.leading, 40)
        .motion(Motion.exit, value: isTyping)
    }
}

/// The small buttons beside a finished reply: copy it as text, copy it as Markdown.
private struct MessageActions: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            CopyButton(symbol: "doc.on.doc", help: "Copiar resposta", copiedHelp: "Copiado") {
                Clipboard.copy(MarkdownBlocks.plainText(of: text))
            }
            CopyButton(symbol: "number", help: "Copiar como Markdown", copiedHelp: "Markdown copiado") {
                Clipboard.copy(text)
            }
        }
    }
}

private struct CopyButton: View {
    let symbol: String
    let help: String
    let copiedHelp: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    /// The pending return to the copy symbol, so a second click starts the 1.5 s over instead of being cut short.
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button {
            action()
            copied = true
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? Palette.ink : Palette.muted)
                // The symbol is swapped for the check (a plain fade under Reduce Motion), inside a frame that does not move.
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .background(Palette.surface, in: .circle)
                .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
                .contentShape(.circle)
                // Set on the view that changes (the code block's button does the same, where it must: the reply says
                // "never animate" to everything it draws).
                .animation(copied ? Motion.press : Motion.content, value: copied)
        }
        .buttonStyle(.plain)
        .help(copied ? copiedHelp : help)
        .accessibilityLabel(help)
    }
}

/// The reply being streamed as paragraphs: the finished ones keep their identity and text (so they are neither
/// parsed nor measured again) and only the last, the one being written, changes. Each paragraph is read into the
/// same blocks the finished reply has, so nothing moves when the last flush arrives.
private struct ParagraphStack: View {
    let live: LiveText

    var body: some View {
        VStack(alignment: .leading, spacing: markdownBlockSpacing) {
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
            MarkdownChunk(source: paragraph, cached: false).equatable()
        }
    }
}

/// Reads only the paragraph being written.
private struct LastParagraph: View {
    let live: LiveText
    @Environment(\.replyGrew) private var replyGrew

    var body: some View {
        MarkdownChunk(source: live.tail, streaming: true, cached: false)
            .onChange(of: live.tail.utf8.count) { replyGrew?() }
    }
}

extension EnvironmentValues {
    /// Called when the reply being streamed grows, by a list that has to scroll to follow it itself.
    @Entry var replyGrew: (@MainActor () -> Void)?
}

/// The parsed Markdown of text that is done changing, so a row the LazyVStack recreates while scrolling (or a
/// paragraph that moves from "being written" to "finished") is not parsed again. Two generations: when the newer one
/// is full the older is dropped, so memory stays bounded and what was used lately survives. Inline text
/// (`attributed`) and the blocks of a text (`blocks`) are kept apart.
/// UTF-8 bytes of source text a generation of `MarkdownCache` holds.
private let markdownGenerationBytes = 512 * 1024

@MainActor
enum MarkdownCache {
    private struct Key: Hashable {
        let source: String
        let endsParagraph: Bool
    }

    /// Two generations of parsed values, bounded by the UTF-8 bytes of the source text they hold.
    private struct Generations<Value> {
        var recent: [Key: Value] = [:]
        var older: [Key: Value] = [:]
        var recentBytes = 0

        var count: Int { recent.count + older.count }

        mutating func value(for key: Key, size: Int) -> Value? {
            if let hit = recent[key] { return hit }
            if let hit = older[key] {
                remember(hit, for: key, size: size)
                return hit
            }
            return nil
        }

        mutating func remember(_ value: Value, for key: Key, size: Int) {
            if recentBytes + size > markdownGenerationBytes {
                older = recent
                recent = [:]
                recentBytes = 0
            }
            recent[key] = value
            recentBytes += size
        }

        mutating func removeAll() {
            recent = [:]
            older = [:]
            recentBytes = 0
        }
    }

    private static var inlineText = Generations<AttributedString>()
    private static var blockLists = Generations<[MarkdownBlock]>()
    /// The longest text worth keeping.
    private static let longestText = 64 * 1024

    static func attributed(_ source: String, endsParagraph: Bool = false, cached: Bool = true) -> AttributedString {
        let size = source.utf8.count
        guard cached, size <= longestText else { return parse(source, endsParagraph: endsParagraph) }
        let key = Key(source: source, endsParagraph: endsParagraph)
        if let hit = inlineText.value(for: key, size: size) { return hit }
        let parsed = parse(source, endsParagraph: endsParagraph)
        inlineText.remember(parsed, for: key, size: size)
        return parsed
    }

    /// The blocks of a reply, or of one paragraph of it.
    static func blocks(_ source: String, cached: Bool = true) -> [MarkdownBlock] {
        let size = source.utf8.count
        guard cached, size <= longestText else { return MarkdownBlocks.parse(source) }
        let key = Key(source: source, endsParagraph: false)
        if let hit = blockLists.value(for: key, size: size) { return hit }
        let parsed = MarkdownBlocks.parse(source)
        blockLists.remember(parsed, for: key, size: size)
        return parsed
    }

    /// Empties the cache (tests).
    static func removeAll() {
        inlineText.removeAll()
        blockLists.removeAll()
    }

    /// Entries of inline text kept.
    static var count: Int { inlineText.count }
    /// Entries of parsed blocks kept.
    static var blockCount: Int { blockLists.count }

    /// Inline Markdown with the look of the chat: code on a faint fill, links in the accent color.
    private static func parse(_ text: String, endsParagraph: Bool) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let source = endsParagraph ? text + "\n" : text
        guard var result = try? AttributedString(markdown: source, options: options) else { return AttributedString(source) }
        var code: [Range<AttributedString.Index>] = []
        var links: [Range<AttributedString.Index>] = []
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true { code.append(run.range) }
            if run.link != nil { links.append(run.range) }
        }
        for range in code { result[range].backgroundColor = Palette.ghostSelected }
        for range in links {
            result[range].foregroundColor = Palette.accentText
            result[range].underlineStyle = .single
        }
        return result
    }
}

// MARK: - Tool lines

/// Quiet one-line activity entry; expands to show output. While it runs it is still, in the quietest ink: the "now"
/// is the working line at the end of the chat, which says the same with the Orb next to it, so the transcript does not
/// shimmer a second time. When it ends the title comes back to its ink and the mark of the result comes in.
struct ToolCallLine: View {
    let call: ToolCall
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Found once per output, not on every render.
    @State private var permissionProblem: MacPermissionProblem?

    private struct PermissionKey: Equatable { var state: ToolCall.State; var output: String? }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: call.kind.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                        .frame(width: 14)
                    (Text(call.title).foregroundColor(call.state == .running ? Palette.faint : Palette.muted)
                        + Text("  \(call.detail)").foregroundColor(Palette.faint))
                        .font(.system(size: 12))
                        .lineLimit(1)
                    stateMark
                    if call.output != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.faint)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            // No turning under Reduce Motion: the arrow points the other way at once.
                            .animation(reduceMotion ? nil : Motion.content, value: isExpanded)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(call.output == nil)
            // Running -> done or failed: the mark of the state comes in (see `stateMark`).
            .motion(Motion.enter, value: call.state)
            .accessibilityLabel("\(call.title) \(call.detail)")
            .accessibilityValue(call.output == nil ? "" : (isExpanded ? "expandido" : "recolhido"))
            .accessibilityHint(call.output == nil ? "" : "Mostra a saída")

            if let problem = permissionProblem {
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
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
        }
        .padding(.leading, gutter)
        .task(id: PermissionKey(state: call.state, output: call.state == .running ? nil : call.output)) {
            permissionProblem = call.permissionProblemToShow
        }
    }

    /// The mark of a state that ended comes in small and grows to size while it appears; a failure's the same, without
    /// shaking (the Orb shows the error). A plain fade under Reduce Motion.
    private var markTransition: AnyTransition {
        .adapted(.scale(scale: 0.6).combined(with: .opacity), reduceMotion: reduceMotion)
    }

    @ViewBuilder private var stateMark: some View {
        switch call.state {
        case .running:
            EmptyView()
        case .done:
            if let duration = call.duration {
                (Text(duration, format: .number.precision(.fractionLength(1))) + Text(" s"))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Palette.faint)
                    .contentTransition(.numericText())
                    .transition(markTransition)
            }
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(Palette.danger)
                .accessibilityLabel("Falhou")
                .transition(markTransition)
        }
    }
}

// MARK: - Notices

/// A line of the transcript that is not anyone's speech ("Você interrompeu esta resposta", "Conversa compactada…").
/// When it is the last thing in the chat and the Orb is not working, a notice about a failure, a pause or a missing
/// model offers what to do about it (`NoticeAction`).
private struct NoticeLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let id: UUID
    let text: String
    let botID: UUID
    /// Whether the conversation has something older to summarize, read once for a notice that offers to compact.
    @State private var canCompact = false

    var body: some View {
        let actions = NoticeAction.actions(for: text, canCompact: canCompact)
        let failure = NoticeAction.failureDetail(of: text)
        VStack(spacing: 8) {
            if let failure {
                VStack(spacing: 2) {
                    Label("Não deu certo", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.warn)
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
            } else {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
            }
            if !actions.isEmpty, offersActions {
                HStack(spacing: 8) {
                    ForEach(actions, id: \.self) { action in
                        Button { perform(action) } label: {
                            Label(action.title, systemImage: action.symbol)
                        }
                        .buttonStyle(NoticeActionStyle(prominent: action == actions.first))
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TranscriptSpeech.notice(failure.map { "não deu certo. " + $0 } ?? text))
        .task(id: id) {
            guard NoticeAction.actions(for: text).contains(.compact), let input = model.contextInput(for: botID) else { return }
            canCompact = await Task.detached { ContextReading.make(input)?.canCompact ?? false }.value
        }
    }

    /// The last item of the chat, with nothing running. (Read only by notices that have an action.)
    private var offersActions: Bool {
        model.orbTranscript(botID).items.last?.id == id && !model.live(botID).isWorking
    }

    private func perform(_ action: NoticeAction) {
        switch action {
        case .retry: model.retryLastTurn(botID)
        case .continueTurn: model.continueTurn(botID)
        case .openSettings: SettingsRouter.open(.models, using: openSettings)
        case .newConversation: model.newConversation(botID)
        case .compact: model.compactAndRetry(botID)
        case .openMemory: model.showMemory(of: botID)
        }
    }
}

private struct NoticeActionStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Palette.onInk : Palette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(prominent ? Palette.ink.opacity(configuration.isPressed ? 0.8 : 1)
                        : Color.white.opacity(configuration.isPressed ? 0.16 : 0.1), in: .capsule)
    }
}

// MARK: - Approvals

/// What an answered approval card says on its one line.
enum ApprovalSummary {
    static func label(_ decision: ApprovalDecision) -> String {
        decision == .once ? "Permitido" : decision.label
    }

    /// "Rodando no Terminal", or "3 ações" for a card that groups several.
    static func title(_ request: ApprovalRequest) -> String {
        request.isBatch ? "\(request.items.count) ações" : request.title
    }

    /// What was asked, on one line: the command, the first of a group "e mais N", or what the user said instead.
    static func detail(_ request: ApprovalRequest) -> String {
        if let note = request.note, !note.isEmpty { return "Você disse: " + oneLine(note) }
        if request.isBatch {
            let first = request.items.first.map { $0.command.isEmpty ? $0.title : $0.command } ?? ""
            return oneLine(first) + (request.items.count > 1 ? " e mais \(request.items.count - 1)" : "")
        }
        return oneLine(request.command)
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// Approval prompt. Pending: the action, why, and one primary button ("Permitir", ⌘↩) with a menu for the rest
/// ("Só nesta tarefa", "Sempre permitir…", and "Revisar uma a uma" on a group), next to "Não permitir" (esc); a link
/// opens a line to tell the Orb what to do instead. Destructive commands and changes to the Orb's instructions offer
/// only allow and deny. ⌘↩ allows and Esc denies on the Orb's newest open card. Answered: one quiet line, which opens
/// the card as it was asked.
struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let request: ApprovalRequest
    let botID: UUID

    /// The card arrived while the chat was open: its border pulses once (the list says so, see `TranscriptRow`). Decided
    /// when the card is made and kept: the row's "entering" is not part of its identity and reads false again as soon as
    /// the item changes (a batch that grows), which must not take the pulse away halfway.
    @State private var pulsesOnArrival: Bool
    @State private var note = ""
    @State private var showsNote = false
    @FocusState private var noteFocused: Bool
    /// `noteFocused` as the key handler needs it (a focus state is only meant to be read while drawing).
    @State private var isEditingNote = false
    /// An answered card shown in full.
    @State private var isOpen = false
    /// A group's actions past the first `visibleItems`, shown once asked for.
    @State private var showsAllItems = false
    /// Changes once to play the pulse.
    @State private var pulse = 0
    /// The button a keyboard shortcut is pressing (shown for `ApprovalShortcut.pressDuration` before it answers).
    @State private var pressed: ApprovalShortcut?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(request: ApprovalRequest, botID: UUID, pulses: Bool = false) {
        self.request = request
        self.botID = botID
        _pulsesOnArrival = State(initialValue: pulses)
    }

    /// Read from this Orb's own state (not the list of Orbs), so reordering Orbs does not redraw the card.
    private var orbName: String { model.live(botID).look.name }

    private var isPending: Bool { request.decision == nil }
    private var allowTitle: String { request.isBatch ? "Permitir as \(request.items.count)" : "Permitir" }
    private var hasMoreOptions: Bool { !request.suggestions.isEmpty || request.isBatch }
    private static let visibleItems = 8

    var body: some View {
        // One container for the card and its record, so while one fades out and the other in they overlap instead of
        // the list making room for both. The pending card leaves fast and the record comes in at the content pace;
        // the card never disappears, it leaves its record.
        ZStack(alignment: .topLeading) {
            if isPending {
                pendingCard.transition(.adapted(Self.leaving, reduceMotion: reduceMotion))
            } else {
                answeredCard.transition(.opacity)
            }
        }
        .padding(.leading, gutter)
        .frame(maxWidth: 560, alignment: .leading)
        .motion(Motion.content, value: request.decision)
        .motion(Motion.content, value: request.items.count)
        .onChange(of: noteFocused) { isEditingNote = noteFocused }
        .background {
            if isPending { ApprovalKeyMonitor(handler: handleKey) }
        }
        .task(id: pressed) { await answerPressed() }
    }

    /// Fades out at the exit pace, whatever the animation of the change.
    private static var leaving: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.exit))
    }

    // MARK: Pending

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            details
            if showsNote {
                TextField("Diga o que fazer em vez disso…", text: $note)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($noteFocused)
                    .onSubmit(deny)
                    .onKeyPress(.escape) {
                        note = ""
                        showsNote = false
                        return .handled
                    }
                    .onAppear { noteFocused = true }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Palette.raised.opacity(0.6), in: .rect(cornerRadius: 8))
                    .accessibilityLabel("Instrução ao negar")
            } else {
                Button { showsNote = true } label: {
                    Label("Dizer o que fazer em vez disso", systemImage: "text.bubble")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.accentText)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Nega e diz ao Orb o que fazer no lugar")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { denyButton; Spacer(minLength: 8); allowControl }
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 6) { denyButton; Spacer() }
                    HStack(spacing: 6) { Spacer(); allowControl }
                }
            }
        }
        .padding(14)
        .card(radius: 12, stroke: Palette.lineStrong)
        .overlay {
            if ApprovalPulse.pulses(isNew: pulsesOnArrival, reduceMotion: reduceMotion) {
                ApprovalPulseBorder(radius: 12, trigger: pulse)
            }
        }
        .onAppear { if pulsesOnArrival { pulse += 1 } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TranscriptSpeech.approval(botName: orbName.isEmpty ? "O Orb" : orbName, title: request.title))
    }

    /// The title, why, the command or the list of actions, and what the user said when denying.
    @ViewBuilder private var details: some View {
        HStack(spacing: 8) {
            if request.isDangerous {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.warn)
                    .accessibilityLabel("Ação arriscada")
            }
            Text(request.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText())
            Spacer()
        }
        if !request.reason.isEmpty {
            Text(request.reason)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
        }
        if request.isBatch {
            batchList
        } else if !request.command.isEmpty {
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
    }

    /// What opening the rest of a long group does to the actions it reveals: each comes down from the one above, a
    /// beat after the last (at most six are staggered; the others come with the sixth), and only fades under Reduce Motion.
    private func revealTransition(_ index: Int) -> AnyTransition {
        AnyTransition.adapted(.unfold, reduceMotion: reduceMotion)
            .animation(reduceMotion ? Motion.fade : Motion.enter.delay(Motion.staggerDelay(index)))
    }

    private var batchList: some View {
        let shown = showsAllItems ? request.items : Array(request.items.prefix(Self.visibleItems))
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
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
                .transition(index >= Self.visibleItems ? revealTransition(index - Self.visibleItems) : .identity)
            }
            if !showsAllItems, request.items.count > Self.visibleItems {
                Button {
                    withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) { showsAllItems = true }
                } label: {
                    Text("e mais \(request.items.count - Self.visibleItems)")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .contentTransition(.numericText())
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Mostrar todas as ações")
                .accessibilityHint("Mostra todas as ações")
                .transition(.opacity)
            }
        }
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.raised, in: .rect(cornerRadius: 8))
    }

    private var denyButton: some View {
        Button(action: deny) {
            HStack(spacing: 6) {
                Text("Não permitir")
                Text("esc")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
        }
        .buttonStyle(GhostStyle())
        .background(pressed == .deny ? Palette.ghostSelected : .clear, in: .capsule)
        .scaleEffect(pressed == .deny ? ApprovalShortcut.pressScale : 1)
        .animation(Motion.press, value: pressed)
        .help("Não permitir (esc)")
        .accessibilityLabel("Não permitir")
        .accessibilityHint("Atalho: Esc")
    }

    /// "Permitir ⌘↩" with, when there is more to choose, a chevron in the same capsule that opens the rest.
    private var allowControl: some View {
        HStack(spacing: 0) {
            Button {
                model.decide(.once, approvalID: request.id, botID: botID)
            } label: {
                HStack(spacing: 7) {
                    Text(allowTitle)
                        .contentTransition(.numericText())
                    Text(AppShortcut.commandReturn.label)
                        .font(.system(size: 11))
                        .opacity(0.55)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.onInk)
                .padding(.leading, 14)
                .padding(.trailing, hasMoreOptions ? 10 : 14)
                .padding(.vertical, 7)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("\(allowTitle) (\(AppShortcut.commandReturn.label))")
            .accessibilityLabel(allowTitle)
            .accessibilityHint("Atalho: ⌘↩")
            if hasMoreOptions {
                Rectangle().fill(Palette.onInk.opacity(0.25)).frame(width: 1, height: 16)
                    .accessibilityHidden(true)
                Menu {
                    if let suggestion = request.suggestions.first {
                        Button("Só nesta tarefa") {
                            // A single card grants its first rule; a grouped one, everything it offered.
                            model.decide(.task, rule: request.isBatch ? nil : suggestion, approvalID: request.id, botID: botID)
                        }
                        Divider()
                        Section("Sempre permitir…") {
                            ForEach(request.suggestions, id: \.self) { rule in
                                Button(rule.menuTitle) {
                                    model.decide(.always, rule: rule, approvalID: request.id, botID: botID)
                                }
                            }
                        }
                    }
                    if request.isBatch {
                        if !request.suggestions.isEmpty { Divider() }
                        Button("Revisar uma a uma") {
                            model.decide(.review, approvalID: request.id, botID: botID)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.onInk)
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Só nesta tarefa, sempre permitir… Você pode remover em Liberações, no painel do Orb.")
                .accessibilityLabel("Sempre permitir e outras opções")
            }
        }
        .background(Palette.ink, in: .capsule)
        .opacity(pressed == .allow ? 0.85 : 1)
        .scaleEffect(pressed == .allow ? ApprovalShortcut.pressScale : 1)
        .animation(Motion.press, value: pressed)
    }

    // MARK: Answered

    private var answeredCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.adapted(Motion.content, reduceMotion: reduceMotion)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: request.decision == .deny ? "xmark.circle" : "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(request.decision == .deny ? Palette.danger : Palette.faint)
                        .frame(width: 14)
                    (Text(ApprovalSummary.label(request.decision ?? .deny))
                        .foregroundColor(request.decision == .deny ? Palette.danger : Palette.muted)
                        + Text(" · \(ApprovalSummary.title(request))").foregroundColor(Palette.muted)
                        + Text("  \(ApprovalSummary.detail(request))").foregroundColor(Palette.faint))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .animation(reduceMotion ? nil : Motion.content, value: isOpen)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(ApprovalSummary.label(request.decision ?? .deny)): \(ApprovalSummary.title(request)). \(ApprovalSummary.detail(request))")
            .accessibilityValue(isOpen ? "expandido" : "recolhido")
            .accessibilityHint("Mostra o pedido")

            if isOpen {
                VStack(alignment: .leading, spacing: 10) { details }
                    .padding(14)
                    .card(radius: 12, stroke: Palette.line)
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
        }
    }

    // MARK: Answers

    private func deny() {
        model.decide(.deny, note: note, approvalID: request.id, botID: botID)
    }

    /// ⌘↩ and Esc answer this card when it is the newest open one of the Orb being shown.
    private func handleKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard model.selectedBot?.id == botID, model.newestPendingApprovalID(of: botID) == request.id else { return false }
        let field = window.firstResponder as? NSTextView
        let editing = ApprovalShortcut.isEditing(responderIsText: field != nil, hasText: field.map { !$0.string.isEmpty } ?? false,
                                                 hasMarkedText: field?.hasMarkedText() ?? false, noteFocused: isEditingNote)
        let typingInComposer = ApprovalShortcut.isTypingInComposer(isEditing: editing, noteFocused: isEditingNote)
        guard let shortcut = ApprovalShortcut.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                                      isEditingText: editing, isTypingInComposer: typingInComposer) else { return false }
        press(shortcut)
        return true
    }

    /// A shortcut shows its button pressed for a beat so the person sees what the key did, then answers. (Under
    /// Reduce Motion nothing is pressed and the answer is immediate; a second press during the beat is ignored.)
    private func press(_ shortcut: ApprovalShortcut) {
        guard pressed == nil else { return }
        if ApprovalShortcut.pressDelay(reduceMotion: reduceMotion) == .zero {
            answer(shortcut)
        } else {
            pressed = shortcut
        }
    }

    /// The beat of a pressed button, then its answer. Runs also if the card goes away during the beat: the key was pressed.
    private func answerPressed() async {
        guard let shortcut = pressed else { return }
        try? await Task.sleep(for: ApprovalShortcut.pressDelay(reduceMotion: reduceMotion))
        answer(shortcut)
        pressed = nil
    }

    private func answer(_ shortcut: ApprovalShortcut) {
        switch shortcut {
        case .allow: model.decide(.once, approvalID: request.id, botID: botID)
        case .deny: deny()
        }
    }
}
