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
    /// The reply wears its Orb's avatar: false for one that a later reply of the same run (no message of yours between
    /// them) gives it up to. Part of the row's identity, like `isLastReply`.
    var showsAvatar = true
    /// The Orb's words in the middle of its work (`ReplyAvatars.narration`): no bubble, a step quieter than an answer.
    var isNarration = false
    /// This is the reply "Refazer" belongs to (the last one of an idle chat).
    var offersRedo = false
    /// The row is about to leave (an edit or "Refazer" cuts the chat before it): it fades out first.
    var isDropping = false
    /// This is the result a search in the conversation has chosen: its text is marked and a wash fades behind it. Only the
    /// row of that result is given one, so choosing another result redraws two rows.
    var find: FindFocus?
    /// The row is in the Orb's own chat, where a message of yours can be edited (not in a routine's run, an exchange…).
    var editable = false

    nonisolated static func == (lhs: TranscriptRow, rhs: TranscriptRow) -> Bool {
        lhs.item == rhs.item && lhs.botID == rhs.botID && lhs.orb == rhs.orb && lhs.isLastReply == rhs.isLastReply
            && lhs.showsAvatar == rhs.showsAvatar && lhs.isNarration == rhs.isNarration
            && lhs.offersRedo == rhs.offersRedo && lhs.isDropping == rhs.isDropping && lhs.find == rhs.find
            && lhs.editable == rhs.editable
    }

    var body: some View {
        content
            .background { if let find { FindWash(isOn: find.isFlashing) } }
            .opacity(isDropping ? 0 : 1)
            .animation(Motion.exit, value: isDropping) // opacity only, so it holds under Reduce Motion too
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .user(let text, let attachments):
            UserBubble(text: text, attachments: attachments, duringTask: item.duringTask == true, botID: botID, itemID: item.id,
                       editable: editable, highlight: find?.query)
        case .bot(let text, let isStreaming):
            BotMessage(orb: orb, botID: botID, text: text, live: isStreaming ? model.liveText(for: item.id, of: botID) : nil,
                       isLastReply: isLastReply, showsAvatar: showsAvatar, isNarration: isNarration, offersRedo: offersRedo,
                       highlight: find?.query)
        case .tool(let call):
            ToolCallLine(call: call)
        case .approval(let request):
            if let proposal = request.proposal { // MultiOrb (WP3): an Orb proposes a new Orb
                OrbProposalCard(request: request, proposal: proposal, botID: botID, pulses: entering)
            } else if let question = request.question {
                QuestionCard(request: request, question: question, botID: botID, pulses: entering)
            } else if request.isHandoff, request.decision == nil, model.liveCardDrawsHandoff(of: botID) {
                // The live card of this turn's browser stands for it (its "Terminei" and "Cancelar" answer this request);
                // answered, it is the usual line again. Not observed: the row changes when the request is answered.
                EmptyView()
            } else {
                ApprovalCard(request: request, botID: botID, pulses: entering)
            }
        case .notice(let text):
            NoticeLine(id: item.id, text: text, botID: botID)
        case .greeting(let text):
            GreetingMessage(orb: orb, botID: botID, text: text, isLast: isLastReply, showsAvatar: showsAvatar, highlight: find?.query)
        // MARK: MultiOrb (WP0)
        case .event(let event):
            EventLineView(event: event).alignedWithReplyText()
        case .orbMessage(let message):
            // A card: from the gutter, as wide as the others (`cardWidth`), not narrowed by the text's right margin.
            OrbMessageRow(message: message, botID: botID).padding(.leading, gutter)
        case .groupPause(let pause):
            GroupPauseCard(pause: pause)
        case .browserView(let view):
            LiveScreenRow(itemID: item.id, view: view, botID: botID)
        }
    }
}

/// The wash behind the message a search just brought into view: it comes at once and fades in `Motion.content` (a plain
/// fade of the same length under Reduce Motion: it is opacity, not movement).
private struct FindWash: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.card)
            .fill(Palette.findWash)
            .padding(.horizontal, -10)
            .padding(.vertical, -4)
            .opacity(isOn ? 1 : 0)
            .motion(Motion.content, value: isOn)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Left gutter width shared by bot messages, tool lines, cards and notices: the replies' text starts here (44 pt), so every row has one left edge.
let gutter: CGFloat = 44
/// The widest a card of the chat gets (a request, a question, a proposal, the live screen, an exchange), from the gutter:
/// one right edge for all of them.
let cardWidth: CGFloat = 560

extension View {
    /// A line of the chat that is not a message (a notice, an event, a delegation) starts where the replies' text starts, so
    /// the eye keeps one left edge down the transcript instead of jumping to a centre.
    func alignedWithReplyText() -> some View {
        padding(.leading, gutter).padding(.trailing, 90)
    }

    /// A card in the chat that asks or shows something (a permission, a question, a proposal, the live screen): one width
    /// from the replies' left edge. The width before the inset, so the inset does not eat into it.
    func chatCard() -> some View {
        frame(maxWidth: cardWidth, alignment: .leading).padding(.leading, gutter)
    }

    /// An Orb's words (a reply, a member's words in a group, an exchange, the wizard), straight on the canvas: no bubble,
    /// so a code block or a table inside is one frame and not a frame in a frame, and the text starts on the chat's one
    /// left edge. As wide as its longest line (`proseHugsText`) up to the width it is given, so the buttons beside it
    /// stay near a short reply.
    func replyText(narration: Bool = false) -> some View {
        environment(\.proseHugsText, true)
            .padding(.vertical, narration ? ReplyText.narrationPadding : 0)
    }

    /// The person's words in a bubble (a chat, a group, the wizard, the queue): one type, inset and shape everywhere, so a
    /// message keeps its size as it moves from the queue to the transcript. The line spacing stays with the text, because a
    /// quote above it keeps its tighter lines.
    func userBubble(fill: Color = Palette.userBubble) -> some View {
        font(Palette.conversationFont)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(fill, in: .rect(cornerRadius: Radius.bubble))
    }
}

/// The measures of `replyText()`, so the avatar beside it can be set against its first line.
enum ReplyText {
    /// Above and below words said along the work: close to the action lines around them.
    static let narrationPadding: CGFloat = 3
    /// How far a 30 pt avatar goes from the text's top for its middle to be level with the first line (a 14 pt line is
    /// about 17 pt tall): up, into the gap above.
    static let avatarDrop: CGFloat = -6
}

// MARK: - Spoken labels

/// What VoiceOver says for the rows of the transcript, so it says who spoke instead of reading the avatar.
enum TranscriptSpeech {
    static func user(text: String, quote: String? = nil, attachmentCount: Int, duringTask: Bool = false) -> String {
        let attached = attachmentCount == 0 ? "" : attachmentCount == 1 ? ", com 1 anexo" : ", com \(attachmentCount) anexos"
        let quoted = quote.map { "citando \"\($0)\": " } ?? ""
        return "Você: \(quoted)\(text)\(attached)" + (duringTask ? ", durante a tarefa" : "")
    }

    /// "Anexo: relatório.pdf, PDF, 2,1 MB", or why there is nothing to open.
    static func attachment(_ info: AttachmentInfo) -> String {
        let detail: String
        switch info.state {
        case .ok: detail = [info.ext, AttachmentKind.size(info.size)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        case .missing: detail = "arquivo ausente"
        case .legacy: detail = "anexo antigo, sem local salvo"
        }
        return "Anexo: " + info.name + (detail.isEmpty ? "" : ", " + detail)
    }

    static func reply(of name: String) -> String { "Resposta de \(name)" }

    static func notice(_ text: String) -> String { "Aviso: \(text)" }

    /// A tool's line: what it did, and that it failed (the label of the button replaces the mark's own "Falhou").
    static func tool(title: String, detail: String, state: ToolCall.State) -> String {
        "\(title) \(detail)" + (state == .failed ? ", falhou" : "")
    }

    static func approval(botName: String, title: String) -> String { "\(botName) pede permissão: \(title)" }
    static func handoff(title: String) -> String { "\(title). Termine no navegador e responda Pronto ou Cancelar" }
}

// MARK: - Messages

private struct UserBubble: View {
    @Environment(AppModel.self) private var model
    let text: String
    let attachments: [String]
    /// It reached the Orb in the middle of its task (see `TranscriptItem.duringTask`): a small, quiet line says so.
    var duringTask = false
    let botID: UUID
    let itemID: UUID
    var editable = false

    var highlight: String?

    @State private var hovering = false

    var body: some View {
        HStack {
            Spacer(minLength: 120)
            // No "Você" over it: the bubble on the right says whose it is, and its label for VoiceOver starts with "Você".
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty { AttachmentStack(paths: attachments) }
                if !text.isEmpty {
                    let parts = MessageQuote.split(text)
                    VStack(alignment: .leading, spacing: 6) {
                        if let quote = parts.quote { QuotedPassage(quote: quote, itemID: itemID) }
                        if !parts.body.isEmpty { userText(parts.body) }
                    }
                    .foregroundStyle(Palette.ink)
                    .userBubble()
                    .contextMenu {
                        Button("Copiar") { Clipboard.copy(text) }
                        // Without the mouse too; when it cannot be edited now, the reason is said instead.
                        if editable { Button("Editar") { model.editOrExplain(itemID: itemID, of: botID) } }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityActions {
                        if editable { Button("Editar") { model.editOrExplain(itemID: itemID, of: botID) } }
                    }
                    .accessibilityLabel(TranscriptSpeech.user(text: parts.body, quote: parts.quote, attachmentCount: attachments.count,
                                                              duringTask: duringTask))
                }
                if duringTask {
                    HStack(spacing: 4) {
                        Label("Durante a tarefa", systemImage: "arrow.turn.down.right")
                            .font(Typography.small)
                            .foregroundStyle(Palette.muted)
                            .accessibilityHidden(!text.isEmpty) // the bubble's label already says it
                        SendNowButton(botID: botID, itemID: itemID)
                    }
                }
            }
            .overlay(alignment: .leading) {
                // To the left of the bubble, in the space the row leaves; the row's hover keeps it up while the pointer
                // travels to it. Made only while hovered: whether the message can be edited is looked at then.
                if hovering, editable {
                    EditMessageButton(botID: botID, itemID: itemID)
                        .offset(x: -34)
                        .transition(.opacity)
                }
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        // Responds fast and lets go slowly (§2.7).
        .animation(Motion.hover(hovering), value: hovering)
    }

    /// The reply's line spacing, so a message of two lines reads as loosely as the answer under it. Here and not on the
    /// bubble's stack: the quote above it keeps its own tighter lines.
    @ViewBuilder private func userText(_ text: String) -> some View {
        Group {
            if highlight != nil { Text(FindMarking.marked(text, query: highlight)) } else { Text(text) }
        }
        .lineSpacing(Palette.conversationLineSpacing)
    }
}

/// The part of a reply a message of yours quotes (`MessageQuote`), above what you wrote: a click goes back to the reply.
private struct QuotedPassage: View {
    @Environment(\.revealQuote) private var revealQuote
    let quote: String
    /// The message that quotes it: the reply is looked for before it.
    let itemID: UUID
    @State private var hovering = false

    var body: some View {
        Button { revealQuote?.reveal(quote, itemID) } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(hovering ? Palette.accentText : Palette.lineStrong)
                    .frame(width: 2)
                Text(quote)
                    .font(Typography.label)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(revealQuote == nil)
        .clickablePointer()
        .onHover { hovering = $0 }
        .animation(Motion.hover(hovering), value: hovering)
        .help(Tip.goToQuote)
        .accessibilityLabel("Citação: \(quote)")
        .accessibilityHint("Vai até o trecho na resposta")
    }
}

/// What a click on a quote in a message of yours does: takes the chat to the reply it came from (set by the chat's list).
/// Equal whatever its closure: it only reaches the list's own state.
struct RevealQuoteAction: Equatable {
    let reveal: @MainActor (_ quote: String, _ messageID: UUID) -> Void

    nonisolated static func == (lhs: RevealQuoteAction, rhs: RevealQuoteAction) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var revealQuote: RevealQuoteAction?
}

/// "Parar e enviar" on a message of yours that reached the task and that the Orb has not acted on yet. The queue's bubble
/// had the button until the message went in, often a fraction of a second after it was sent: here it stays until the Orb
/// answers it (or the turn ends), so a click never lands where the button was.
private struct SendNowButton: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let itemID: UUID

    var body: some View {
        if model.unansweredSteered(of: botID).contains(itemID) {
            Button("Parar e enviar", systemImage: "arrow.up.circle.fill") {
                // A click while the button fades out, after the Orb answered: nothing to send any more.
                guard model.unansweredSteered(of: botID).contains(itemID) else { return }
                model.stopAndSend(botID)
            }
                .buttonStyle(GhostStyle(tint: Palette.accentText))
                .controlSize(.small)
                .clickablePointer()
                .help("Interrompe o que o Orb está fazendo e envia esta mensagem agora (\(AppShortcut.commandReturn.label))")
                .transition(.opacity)
        }
    }
}

/// "Editar" beside a message of yours: puts it in the composer to be written again (what came after it leaves the
/// conversation). Not shown while the Orb works, waits for a permission or a routine runs; shown but dimmed, with the
/// reason as its hover text, for a message that already became part of the summary or that entered in the middle of a
/// task.
private struct EditMessageButton: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let itemID: UUID

    var body: some View {
        let refusal = model.editRefusal(itemID: itemID, of: botID)
        if refusal == nil || refusal?.hidesButton == false {
            ActionCircleButton(symbol: "pencil", help: refusal?.reason ?? Tip.editMessage, isEnabled: refusal == nil) {
                model.beginEditing(itemID: itemID, of: botID)
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
    /// False when a later reply of the same run wears the avatar: the margin stays, empty.
    var showsAvatar = true
    /// Words said along the work, before more actions: drawn like the work around them, without the bubble that marks
    /// an answer.
    var isNarration = false
    /// The last reply of an idle chat: "Refazer" is beside its copy buttons.
    var offersRedo = false
    var highlight: String?

    @State private var hovering = false
    /// What is selected in the reply's text, for "Citar".
    @State private var selection: String?
    /// "Refazer" asking first. Here and not in the hover button: the button leaves with the pointer, and a dialog opened
    /// from the menu or by VoiceOver would go with it.
    @State private var isConfirmingRedo = false
    /// The dialog's sentence, read when it opens: `body` must not look into the Orb's conversation (it would redraw per token).
    @State private var redoMessage = ""

    /// The one path of "Refazer" (button, menu, VoiceOver): says why not when it cannot, asks first when the steps that
    /// go may have changed things on the Mac. The refusal is read here, not in `body`, which must not watch the Orb's state.
    private func redo() {
        guard model.redoOrExplain(botID) else { return }
        if model.regenerateDropsChanges(botID) {
            redoMessage = RewindWords.redoMessage(savedToMemory: model.regenerateSavedToMemory(botID))
            isConfirmingRedo = true
        } else { model.regenerateLastReply(botID, animated: true) }
    }

    /// Read from this Orb's own state, so reordering or adding Orbs does not redraw the reply. A deleted Orb's
    /// stand-in has no name.
    private var orbName: String {
        let name = model.live(botID).look.name
        return name.isEmpty ? "Orb" : name
    }

    /// Which avatar the margin holds (none, the still one, the living one); the fade is tied to this.
    private var avatarPhase: Int { showsAvatar ? (isLastReply ? 2 : 1) : 0 }

    // The text is padded and given the row's width instead of sharing an HStack with the avatar and a Spacer: it then
    // gets one definite width to wrap to (an HStack asks for several sizes, and each one lays the whole text out), and
    // it is as wide as its longest line within it. The avatar floats over the left padding; the right one leaves room
    // for the buttons beside the text.
    var body: some View {
        content
            // The reply's text never animates: not as it streams, and not when the last flush swaps the paragraphs for
            // the finished blocks, whatever the list around it is animating (the row's own entrance is outside this).
            .transaction { $0.animation = nil }
            .environment(\.proseIsQuiet, isNarration)
            .font(isNarration ? Palette.narrationFont : Palette.conversationFont)
            .foregroundStyle(isNarration ? Palette.secondary : Palette.ink)
            .lineSpacing(isNarration ? Palette.narrationLineSpacing : Palette.conversationLineSpacing)
            .textSelection(.enabled)
            // Beside its Orb, on the chat's left edge (the tool lines, the notices, the cards'), the first line level with
            // the avatar's middle. Narration starts there too, set apart by its quieter type.
            .replyText(narration: isNarration)
            .overlay(alignment: .bottomTrailing) {
                // Beside the text, in the space the right padding leaves; the row's hover keeps it up while the pointer
                // travels to it.
                // Shown while something is selected too: "Citar" is for the selection.
                // Not mounted at all otherwise: a long chat does not carry a hidden set of buttons on every reply.
                if live == nil, hovering || selection != nil {
                    MessageActions(text: text, botID: botID, offersRedo: offersRedo, selection: selection, redo: redo)
                        .fixedSize()
                        .alignmentGuide(.trailing) { $0[.leading] - 6 }
                        .transition(.opacity)
                }
            }
            .environment(\.proseSelection, live == nil ? ProseSelectionAction(
                changed: { selection = $0 }, quote: { [model, botID] in model.quote($0, for: botID) }) : nil)
            .alignedWithReplyText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                // The last reply of the chat has the one living Orb in view (it works, celebrates, watches you type, and
                // rests once idle); the ones above are still, in the same resting pose. When it stops being the last (a tool
                // line or a new message came in) the live one may be mid-expression: the two cross-fade (0.15 s) instead
                // of the expression jumping. The animation is tied to this flag, which changes rarely, not to the list.
                Group {
                    if showsAvatar {
                        if isLastReply {
                            LiveBotAvatar(botID: botID, orb: orb, size: 30, restsWhenIdle: true)
                                .transition(.opacity)
                        } else {
                            BotAvatar(orb: orb, size: 30, animated: false)
                                .transition(.opacity)
                        }
                    }
                }
                // A reply that a newer one of the run takes the avatar from fades it out the same way, the margin kept.
                .animation(Motion.fade, value: avatarPhase)
                .offset(y: ReplyText.avatarDrop)
                .accessibilityHidden(true)
            }
            // Without a bubble the margins are empty: the whole row still keeps the buttons up under the pointer.
            .contentShape(.rect)
            .onHover { if live == nil { hovering = $0 } }
            // Responds fast and lets go slowly (§2.7).
            .animation(Motion.hover(hovering), value: hovering)
            .contextMenu {
                if live == nil {
                    Button("Copiar") { Clipboard.copy(MarkdownBlocks.plainText(of: text)) }
                    Button("Copiar como Markdown") { Clipboard.copy(text) }
                    if offersRedo { Button("Refazer", action: redo) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(TranscriptSpeech.reply(of: orbName))
            .accessibilityActions {
                if live == nil {
                    Button("Copiar resposta") { Clipboard.copy(MarkdownBlocks.plainText(of: text)) }
                    Button("Copiar como Markdown") { Clipboard.copy(text) }
                    if offersRedo { Button("Refazer", action: redo) }
                }
            }
            .confirmationDialog(RewindWords.redoTitle, isPresented: $isConfirmingRedo, titleVisibility: .visible) {
                Button(RewindWords.redoConfirm, role: .destructive) { model.regenerateLastReply(botID, animated: true) }
            } message: {
                Text(redoMessage)
            }
    }

    @ViewBuilder private var content: some View {
        if let live {
            ParagraphStack(live: live)
        } else {
            MarkdownChunk(source: text, highlight: highlight).equatable()
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
    var showsAvatar = true
    var highlight: String?

    var body: some View {
        let enters = isLast && EmptyChatEntrance.plays(for: botID, in: presented)
        VStack(alignment: .leading, spacing: 10) {
            BotMessage(orb: orb, botID: botID, text: text, live: nil, isLastReply: isLast, showsAvatar: showsAvatar, highlight: highlight)
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
        let isTyping = !model.draftText(botID).isEmpty
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
        .padding(.leading, gutter) // under the reply's text
        .motion(Motion.exit, value: isTyping)
    }
}

/// The small buttons beside a finished reply: copy it as text, copy it as Markdown, and, on the last reply of an idle
/// chat, ask for it again.
private struct MessageActions: View {
    @Environment(AppModel.self) private var model
    let text: String
    let botID: UUID
    let offersRedo: Bool
    /// The words selected in the reply: "Citar" puts them in your next message.
    var selection: String?
    /// "Refazer", decided by the reply (it also owns the confirmation).
    let redo: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let selection {
                Button { model.quote(selection, for: botID) } label: {
                    Label("Citar", systemImage: "text.quote")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Palette.surface, in: .capsule)
                        .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(Tip.quoteSelection)
                .transition(.opacity)
            }
            CopyButton(symbol: "doc.on.doc", help: Tip.copyReply, copiedHelp: "Copiado") {
                Clipboard.copy(MarkdownBlocks.plainText(of: text))
            }
            CopyButton(symbol: "number", help: Tip.copyMarkdown, copiedHelp: "Markdown copiado") {
                Clipboard.copy(text)
            }
            if offersRedo { RedoReplyButton(botID: botID, action: redo) }
        }
    }
}

/// "Refazer": the reply and the steps of its turn leave the conversation and the same request runs again (the reply
/// asks first when those steps may have changed things on the Mac: what the Orb did stays done).
private struct RedoReplyButton: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let action: () -> Void

    var body: some View {
        let refusal = model.regenerateRefusal(botID)
        if refusal == nil || refusal?.hidesButton == false {
            ActionCircleButton(symbol: "arrow.clockwise", help: refusal?.reason ?? Tip.redoReply, isEnabled: refusal == nil, action: action)
        }
    }
}

/// A round button of the hover actions of a message (the same look as the copy buttons), dimmed when it cannot be used.
private struct ActionCircleButton: View {
    let symbol: String
    let help: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 26, height: 26)
                .background(Palette.surface, in: .circle)
                .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
                .contentShape(.circle)
                .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct CopyButton: View {
    let symbol: String
    let help: String
    let copiedHelp: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = CopiedFlash()

    var body: some View {
        Button {
            action()
            flash.trigger()
        } label: {
            Image(systemName: flash.isOn ? "checkmark" : symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(flash.isOn ? Palette.ink : Palette.muted)
                // The symbol is swapped for the check (a plain fade under Reduce Motion), inside a frame that does not move.
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .background(Palette.surface, in: .circle)
                .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
                .contentShape(.circle)
                // Set on the view that changes (the code block's button does the same, where it must: the reply says
                // "never animate" to everything it draws).
                .animation(flash.isOn ? Motion.press : Motion.content, value: flash.isOn)
        }
        .buttonStyle(.plain)
        .help(flash.isOn ? copiedHelp : help)
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
        ForEach(Array(live.closed.enumerated()), id: \.offset) { index, paragraph in
            MarkdownChunk(source: paragraph, cached: false, first: index == 0).equatable()
        }
    }
}

/// Reads only the paragraph being written (and how many came before it, which changes only when it ends).
private struct LastParagraph: View {
    let live: LiveText
    @Environment(\.replyGrew) private var replyGrew

    var body: some View {
        // Each paragraph is a view of its own, so its first words fade in as the rest do (`TextFade`) instead of
        // replacing the last one's text at once.
        MarkdownChunk(source: live.tail, streaming: true, cached: false, first: live.closed.isEmpty)
            .id(live.closed.count)
            .onChange(of: live.tail.utf8.count) { replyGrew?() }
    }
}

extension EnvironmentValues {
    /// Called when the reply being streamed grows, by a list that has to scroll to follow it itself.
    @Entry var replyGrew: ReplyGrewAction?
}

/// What a growing reply calls. Equatable by `id` (whoever provides it, e.g. the follower it scrolls for), not by the
/// closure, so a provider that rebuilds the action on every body pass does not invalidate the rows that read it.
struct ReplyGrewAction: Equatable {
    let id: ObjectIdentifier
    private let action: @MainActor () -> Void

    init(id: ObjectIdentifier, _ action: @escaping @MainActor () -> Void) {
        self.id = id
        self.action = action
    }

    @MainActor func callAsFunction() { action() }

    static func == (lhs: ReplyGrewAction, rhs: ReplyGrewAction) -> Bool { lhs.id == rhs.id }
}

/// UTF-8 bytes of source text a generation of `MarkdownCache` holds.
private let markdownGenerationBytes = 512 * 1024

/// The parsed Markdown of text that is done changing (the final text of an answer; the streaming rows use `cached: false`
/// and do not fill it), so a row the LazyVStack recreates while scrolling is not parsed again. Two generations: when the
/// newer one is full the older is dropped, so memory stays bounded and what was used lately survives. Inline text
/// (`attributed`) and the blocks of a text (`blocks`) are kept apart.
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

/// One action on one line: what it did, in the tense of its state, with what it acted on written as code ("Rodou
/// `swift build`", "Leu `SKILL.md`"), and how long it took. Running, a small spinner stands in for its symbol; failed, a
/// red mark does, with "Falhou" and the exit code. A click opens what it ran and what came out (`CommandBlock`).
struct ToolCallLine: View {
    let call: ToolCall
    @State private var isExpanded = Self.opensInSnapshots
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Found once per output, not on every render.
    @State private var permissionProblem: MacPermissionProblem?

    /// Review snapshots cannot press the line: they draw every action open.
    static var opensInSnapshots = false

    /// The output's length, not the output: it is set once when the call ends, and comparing a 20,000-character string on
    /// every render would cost more than the search it guards.
    private struct PermissionKey: Equatable { var state: ToolCall.State; var outputLength: Int? }

    var body: some View {
        // What the line says (see `ToolCall.lineWords`): what the action is for, or its verb and what it acted on.
        let words = call.lineWords
        let hidden = call.hiddenDetail(given: words)
        let canOpen = call.output != nil || hidden != nil
        let failed = call.state == .failed
        // How a command ended, read off its output (`CommandOutput`, which copies up to 20,000 characters): only once it
        // ended and only for a command, and only where it is used: the open block, or the code beside a failed line.
        let ended = call.isCommand && call.state != .running && (isExpanded || failed) ? call.output.map(CommandOutput.init) : nil
        let time = call.state == .running ? nil : call.duration.map(ElapsedFormat.duration)
        let meta = [failed ? ended?.lineNote : nil, time].compactMap { $0 }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(FoldMotion.animation(reduceMotion: reduceMotion)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    stateMark
                        .frame(width: 14)
                    Text(words.main)
                        .font(Typography.label)
                        .foregroundStyle(failed ? Palette.danger : Palette.secondary)
                        .lineLimit(1)
                    if let code = words.code {
                        Text(code)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Palette.secondary)
                            .lineLimit(1)
                            // Cut in the middle: the program stays and so does the end of a command, where what tells two
                            // runs apart usually is ("… --lote 3").
                            .truncationMode(.middle)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Palette.chipFill, in: .rect(cornerRadius: 4))
                            // The code gives way before the verb and the time do.
                            .layoutPriority(-1)
                    }
                    if let rest = words.rest {
                        Text(rest)
                            .font(Typography.label)
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(-1)
                    }
                    if !meta.isEmpty {
                        Text(meta)
                            .font(Typography.small)
                            .monospacedDigit()
                            .foregroundStyle(failed ? Palette.danger.opacity(0.85) : Palette.faint)
                            .lineLimit(1)
                            .fixedSize()
                            .transition(.opacity)
                    }
                    if canOpen {
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
            .disabled(!canOpen)
            .help(!canOpen ? "" : hidden == nil ? Tip.toggleOutput(isExpanded: isExpanded) : Tip.toggleCommand(isExpanded: isExpanded))
            // Running -> done or failed: the mark of the state comes in (see `stateMark`).
            .motion(Motion.enter, value: call.state)
            .accessibilityLabel(TranscriptSpeech.tool(title: words.main, detail: [words.code, words.rest, meta.isEmpty ? nil : meta]
                .compactMap { $0 }.joined(separator: " "), state: call.state))
            .accessibilityValue(!canOpen ? "" : (isExpanded ? "expandido" : "recolhido"))
            .accessibilityHint(!canOpen ? "" : hidden == nil ? "Mostra a saída" : "Mostra o comando e a saída")

            if let problem = permissionProblem {
                OpenPrivacySettingsButton(problem: problem).padding(.leading, 22)
            }

            if call.state == .done, let files = call.files, !files.isEmpty {
                ProducedFilesView(files: files, captures: Set(call.capturedPictures.map(\.path))).padding(.leading, 22)
            }

            if isExpanded, canOpen {
                block(hidden: hidden, ended: ended, time: time)
                    .padding(.leading, 22) // under the line's words, past its symbol
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
        }
        .padding(.leading, gutter)
        .task(id: PermissionKey(state: call.state, outputLength: call.state == .running ? nil : call.output?.utf8.count)) {
            permissionProblem = call.permissionProblemToShow
        }
    }

    /// What the line opens to: a command as a terminal shows it, with how it ended at its foot; any other action, what it
    /// acted on (the whole path, the script) and what came out.
    @ViewBuilder private func block(hidden: (title: String, detail: String)?, ended: CommandOutput?, time: String?) -> some View {
        if call.isCommand {
            let shown = ShownCommand.split(call.detail)
            let end = call.state == .running ? nil : CommandBlock.End(
                text: [ended?.endText(failed: call.state == .failed, background: call.title == "Rodando em segundo plano") ?? "Concluído",
                       time].compactMap { $0 }.joined(separator: " · "),
                outcome: call.state == .failed ? .failed : ended?.end == nil || ended?.end == .code(0) ? .succeeded : .neutral)
            CommandBlock(command: shown.command, folder: shown.folder, output: ended?.text ?? call.output, end: end)
        } else {
            // A detail on one line (a path, an address) heads the block; a longer one (a script) is the block's text.
            let detail = hidden?.detail
            let oneLine = detail.map { !$0.contains("\n") } ?? false
            CommandBlock(command: oneLine ? nil : detail, prompt: false, folder: nil,
                         heading: oneLine ? detail.map { (call.kind.symbol, $0) } : nil, output: call.output)
        }
    }

    /// The mark of a state that ended comes in small and grows to size while it appears (`AnyTransition.mark`); a
    /// failure's the same, without shaking (the Orb shows the error). A plain fade under Reduce Motion.
    private var markTransition: AnyTransition {
        .adapted(.mark, reduceMotion: reduceMotion)
    }

    /// Where the action's symbol is: a spinner while it runs, a red mark when it failed.
    @ViewBuilder private var stateMark: some View {
        switch call.state {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        case .done:
            Image(systemName: call.kind.symbol)
                .font(Typography.small)
                .foregroundStyle(Palette.muted)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(Typography.small)
                .foregroundStyle(Palette.danger)
                .accessibilityLabel("Falhou")
                .transition(markTransition)
        }
    }
}

/// A command as a terminal shows it, in one block at most the width of the cards: the folder it ran in (when it was not
/// the Orb's), `$ command`, what it printed (its first lines, the rest one click away, `CommandExcerpt`) and how it ended.
/// The approval card shows the command it asks about in the same block, without output or end; another action's open
/// line, what it acted on and what came out.
struct CommandBlock: View {
    struct End: Equatable {
        enum Outcome: Equatable { case succeeded, neutral, failed }
        /// "Concluído · 12,4 s", "Saiu com código 1 · 2,1 s".
        var text: String
        var outcome: Outcome

        var symbol: String {
            switch outcome {
            case .succeeded: "checkmark.circle.fill"
            case .neutral: "minus.circle.fill"
            case .failed: "xmark.circle.fill"
            }
        }
    }

    /// What ran; nil when the block only shows an output.
    var command: String?
    /// "$" before the command: a command of the Terminal, not a path or a script of another tool.
    var prompt = true
    /// Code, in the monospaced font; false for words (a hand-off's instructions).
    var isCode = true
    /// Long commands fold (`CommandExcerpt`) and open whole on request: what is approved is never hidden, only folded. A
    /// risky one is always shown whole.
    var foldsCommand = true
    var folder: String?
    /// A symbol and a line above it all when there is no folder (the file an action read).
    var heading: (symbol: String, text: String)?
    var output: String?
    var end: End?
    /// `Palette.raised` on a card, so the block stands apart from it.
    var fill = Palette.surface
    /// "Copiar" for the command, or for the output when there is no command; off on an approval card.
    var copies = true
    @State private var showsWholeCommand = false
    @State private var showsWholeOutput = false

    var body: some View {
        let output = output.flatMap { $0.isEmpty ? nil : $0 }
        let copied = command ?? output
        let head = folder.map { ("folder", $0) } ?? heading
        VStack(alignment: .leading, spacing: 0) {
            if head != nil || command != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let head {
                        HStack(spacing: 6) {
                            Image(systemName: head.0)
                                .font(.system(size: 10))
                            Text(head.1)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 8)
                            if copies, let copied { copyButton(copied) }
                        }
                        .foregroundStyle(Palette.faint)
                    }
                    if let command {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            commandText(command)
                            if head == nil, copies {
                                Spacer(minLength: 8)
                                copyButton(command)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, head == nil ? 10 : 9)
                .padding(.bottom, 10)
            }
            if let output {
                if head != nil || command != nil { rule }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    outputText(output)
                    if head == nil, command == nil, copies {
                        Spacer(minLength: 8)
                        copyButton(output)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            if let end {
                rule
                HStack(spacing: 6) {
                    Image(systemName: end.symbol)
                        .foregroundStyle(end.outcome == .succeeded ? Palette.ok : end.outcome == .failed ? Palette.danger : Palette.faint)
                    Text(end.text)
                        .foregroundStyle(end.outcome == .failed ? Palette.danger.opacity(0.9) : Palette.faint)
                        .monospacedDigit()
                }
                .font(Typography.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: cardWidth, alignment: .leading)
        .card(radius: Radius.small, fill: fill, stroke: end?.outcome == .failed ? Palette.danger.opacity(0.35) : Palette.line)
    }

    private var rule: some View {
        Rectangle().fill(Palette.line).frame(height: 1)
    }

    private func copyButton(_ text: String) -> some View {
        CopyTextButton(text: text, help: command == nil ? Tip.copyOutput : Tip.copyCommand,
                       label: command == nil ? "Copiar resultado" : "Copiar comando",
                       copiedLabel: command == nil ? "Resultado copiado" : "Comando copiado")
    }

    @ViewBuilder private func commandText(_ command: String) -> some View {
        let excerpt = foldsCommand ? CommandExcerpt.excerpt(of: command) : nil
        VStack(alignment: .leading, spacing: 6) {
            (Text(prompt ? "$ " : "").foregroundColor(Palette.faint)
                + Text(showsWholeCommand ? command : excerpt?.text ?? command).foregroundColor(isCode ? Palette.ink : Palette.secondary))
                .font(.system(size: 12, design: isCode ? .monospaced : .default))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let excerpt {
                showAllButton(isShowing: $showsWholeCommand, hidden: excerpt.hiddenLines)
            }
        }
    }

    @ViewBuilder private func outputText(_ output: String) -> some View {
        let head = CommandExcerpt.head(of: output)
        VStack(alignment: .leading, spacing: 6) {
            Text(showsWholeOutput ? output : head?.text ?? output)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Palette.secondary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let head {
                showAllButton(isShowing: $showsWholeOutput, hidden: head.hiddenLines)
            }
        }
    }

    private func showAllButton(isShowing: Binding<Bool>, hidden: Int) -> some View {
        Button(isShowing.wrappedValue ? "Mostrar menos" : CommandExcerpt.showAll(hidden: hidden)) {
            isShowing.wrappedValue.toggle()
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Palette.muted)
        .clickablePointer()
    }
}

/// The Orb's actions one after another, folded into one quiet line in the place of their lines: what they did ("Rodou
/// 7 comandos e leu 1 arquivo"), how many failed, and how long they took. A click opens it into the lines themselves
/// (each still opens into its output), set in under the line's words on a rail. What must not hide stays below the
/// folded line: the files the actions made and the button to a macOS permission one of them was refused. While the
/// actions run, a small spinner stands in for the line's symbol and the line only counts: the "now" is the working line
/// at the end of the chat.
struct ToolGroupRow: View, Equatable {
    let items: [TranscriptItem]
    let botID: UUID
    let orb: OrbConfig
    let isOpen: Bool
    /// The result of the find bar, when it is one of these actions.
    var find: FindFocus?
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var permissionProblem: MacPermissionProblem?

    /// Review snapshots cannot press the line: they draw every run open.
    static var opensInSnapshots = false

    private static let actionSpacing: CGFloat = 6

    nonisolated static func == (lhs: ToolGroupRow, rhs: ToolGroupRow) -> Bool {
        lhs.items == rhs.items && lhs.botID == rhs.botID && lhs.orb == rhs.orb && lhs.isOpen == rhs.isOpen && lhs.find == rhs.find
    }

    private var calls: [ToolCall] {
        items.compactMap { if case .tool(let call) = $0.kind { call } else { nil } }
    }

    var body: some View {
        let calls = calls
        let isRunning = calls.contains { $0.state == .running }
        let variants = ToolTally.lineVariants(calls)
        let failures = ToolTally.failures(calls)
        // 6 pt between the actions of one group (one list, read down), 12 between the group and what is around it.
        VStack(alignment: .leading, spacing: Self.actionSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                header(variants: variants, failures: failures, span: ToolTally.span(calls), count: ToolTally.countNote(calls),
                       isRunning: isRunning, symbol: ToolTally.symbol(calls))
                if !isOpen { keptInView(calls) }
            }
            .padding(.leading, gutter)
            if isOpen {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    TranscriptRow(item: item, botID: botID, orb: orb, find: item.id == find?.itemID ? find : nil)
                        .equatable()
                        .padding(.leading, 22) // under the line's words, past its symbol
                        // A rail under the line's symbol ties the actions to it, one piece per action that reaches down
                        // over the gap to the next (so it comes in with each one).
                        .background(alignment: .topLeading) {
                            Rectangle()
                                .fill(Palette.line)
                                .frame(width: 1)
                                .padding(.bottom, index == items.count - 1 ? 0 : -Self.actionSpacing)
                                .padding(.leading, gutter + 6.5)
                        }
                        // The find bar scrolls to an action by its id; the first one's is the row's own.
                        .id(index == 0 ? AnyHashable("\(item.id)-first") : AnyHashable(item.id))
                        .transition(reduceMotion ? .quiet : AnyTransition.unfold.animation(Motion.enter.delay(Motion.staggerDelay(index))))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(FoldMotion.animation(reduceMotion: reduceMotion), value: isOpen)
        .task(id: calls.map(\.state)) {
            permissionProblem = isRunning ? nil : calls.lazy.compactMap(\.permissionProblemToShow).first
        }
    }

    private func header(variants: [String], failures: ToolTally.Failures?, span: TimeInterval?, count: String?, isRunning: Bool,
                        symbol: String) -> some View {
        Button(action: toggle) {
            FittingWords(variants: variants) { summary in
                HStack(spacing: 8) {
                    Group {
                        if isRunning {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: symbol)
                                .font(Typography.small)
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .frame(width: 14)
                    Text(summary)
                        .font(Typography.label)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        // The words give way before the marks do, when even the shortest wording is too long.
                        .layoutPriority(-1)
                        // A new action changes a count, once per action (never per token): the number rolls.
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                        .animation(Motion.content, value: summary)
                    if let failures {
                        ErrorMark(failures: failures)
                            .transition(.adapted(.mark, reduceMotion: reduceMotion))
                    }
                    // How long it took and how many actions, when the words do not count them: in view, as on each line.
                    if let marks = marks(span: span, count: count) {
                        Text(marks)
                            .font(Typography.small)
                            .monospacedDigit()
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                            .fixedSize()
                            .transition(.opacity)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .animation(reduceMotion ? nil : Motion.content, value: isOpen)
                    Spacer(minLength: 0)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Tip.toggleActions(isOpen: isOpen))
        // The last action ending: the marks of the result come in (see `ToolCallLine`).
        .motion(Motion.enter, value: isRunning)
        .motion(Motion.enter, value: failures)
        .accessibilityLabel([variants[0], failures?.text, count].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(isOpen ? "expandido" : "recolhido")
        .accessibilityHint(isOpen ? "Recolhe as ações" : "Mostra cada ação")
    }

    /// "12 s · 6 ações": the time once every action ended, and the count when the words do not say it.
    private func marks(span: TimeInterval?, count: String?) -> String? {
        let parts = [span.map(ElapsedFormat.duration), count].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Under the folded line, what one of its actions would have shown under its own: the files they made, and the way
    /// to a permission of the Mac that one was refused.
    @ViewBuilder private func keptInView(_ calls: [ToolCall]) -> some View {
        if let problem = permissionProblem {
            OpenPrivacySettingsButton(problem: problem).padding(.leading, 22)
        }
        // What the Orb saw along the way, step by step; then the other files, a file two of them changed listed once.
        let steps = ScreenStepsStrip.steps(of: calls)
        let pictured = Set(steps?.map(\.path) ?? [])
        var seen = Set<String>()
        let files = calls.filter { $0.state == .done }.flatMap { $0.files ?? [] }
            .filter { !pictured.contains($0.path) && seen.insert($0.path).inserted }
        if let steps {
            ScreenStepsStrip(steps: steps).padding(.leading, 22)
        }
        if !files.isEmpty {
            ProducedFilesView(files: files, captures: Set(calls.flatMap(\.capturedPictures).map(\.path))).padding(.leading, 22)
        }
    }
}

/// The mark of the errors in a folded line: "3 com erro", red with its icon when the run ended on a failure, quiet gray
/// without icon when the Orb got over it (the last action worked), so a recovered stumble does not read as an alarm.
private struct ErrorMark: View {
    let failures: ToolTally.Failures

    var body: some View {
        if failures.recovered {
            Text(failures.text)
                .font(Typography.small)
                .foregroundStyle(Palette.faint)
                .lineLimit(1)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle")
                Text(failures.text)
            }
            .font(Typography.small)
            .foregroundStyle(Palette.danger)
            .lineLimit(1)
        }
    }
}

/// The words of a folded line in the fullest wording that fits the width (`variants`, fullest first, at most three): a
/// line is never cut in the middle of a word unless even the shortest does not fit. Only more than one wording asks the
/// layout to measure them.
private struct FittingWords<Row: View>: View {
    let variants: [String]
    @ViewBuilder let row: (String) -> Row

    var body: some View {
        if variants.count < 2 {
            row(variants[0])
        } else {
            ViewThatFits(in: .horizontal) {
                row(variants[0])
                row(variants[1])
                row(variants[min(2, variants.count - 1)])
            }
        }
    }
}

/// The work of a request on one line: how it ended, how long it took and how much was done ("Trabalhou por 1 min 05 s · 12
/// ações", "Interrompido após 40 s (app fechado) · 3 ações"), and how many actions failed. A click puts back what the Orb
/// said while it worked and its actions, as they were (`content`); the answer stays below, always in view.
struct WorkGroupRow<Content: View>: View, Equatable {
    /// What `content` draws from outside the row (the open runs inside, the find result, the Orb). Only filled in while
    /// the row is open, so a closed one is not drawn again for what only its hidden content would show.
    struct ContentInputs: Equatable {
        var openRuns: Set<UUID>
        var avatars: ReplyAvatars
        var redoID: UUID?
        var dropping: Set<UUID>
        var find: FindFocus?
        var orb: OrbConfig
    }

    let items: [TranscriptItem]
    let seconds: Int?
    let outcome: WorkOutcome
    let isOpen: Bool
    var inputs: ContentInputs?
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The closures (`toggle`, `content`) stay out: they are made again on every pass and say nothing the rest does not.
    nonisolated static func == (lhs: WorkGroupRow, rhs: WorkGroupRow) -> Bool {
        lhs.items == rhs.items && lhs.seconds == rhs.seconds && lhs.outcome == rhs.outcome && lhs.isOpen == rhs.isOpen
            && lhs.inputs == rhs.inputs
    }

    var body: some View {
        let calls = items.compactMap { if case .tool(let call) = $0.kind { call } else { nil } }
        let line = ToolTally.work(calls, seconds: seconds, outcome: outcome)
        // Stopped or cut by the app closing, the action that ran then counts as failed: the line already says why.
        let failures = [.stopped, .appClosed].contains(outcome) ? nil : ToolTally.failures(calls)
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: outcome.symbol)
                        .font(Typography.small)
                        .foregroundStyle(outcome.tint)
                        .frame(width: 14)
                    Text(line)
                        .font(Typography.label)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .layoutPriority(-1)
                    if let failures {
                        ErrorMark(failures: failures)
                    }
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
            .padding(.leading, gutter)
            .help(Tip.toggleWork(isOpen: isOpen))
            .accessibilityLabel(failures.map { "\(line), \($0.text)" } ?? line)
            .accessibilityValue(isOpen ? "expandido" : "recolhido")
            .accessibilityHint(isOpen ? "Recolhe o trabalho" : "Mostra o que o Orb disse e fez")
            if isOpen {
                VStack(alignment: .leading, spacing: 12) { content() }
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(FoldMotion.animation(reduceMotion: reduceMotion), value: isOpen)
    }
}

extension WorkOutcome {
    /// The symbol before the work's line: a request that did not end in an answer says so before its words are read.
    var symbol: String {
        switch self {
        case .answered: "stopwatch"
        case .stopped: "stop.circle"
        case .appClosed, .paused: "exclamationmark.triangle"
        case .failed: "exclamationmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .answered, .stopped: Palette.faint
        case .appClosed, .paused: Palette.warn
        case .failed: Palette.danger
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
    /// Whether the skill (or the memory merge) a notice proposes still waits for a decision, read for a notice that offers it.
    @State private var hasProposal = false
    @State private var reviewing: SkillDraft?
    @State private var showsProviderDetail = false

    var body: some View {
        if NoticeAction.isMark(text) { mark } else { notice }
    }

    /// A compaction: a point of the conversation, across it between two hairlines, like the time above a moment.
    private var mark: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Palette.line).frame(height: 1)
            Text(text)
                .font(Typography.small)
                .foregroundStyle(Palette.faint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
                .layoutPriority(1)
            Rectangle().fill(Palette.line).frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TranscriptSpeech.notice(text))
    }

    @ViewBuilder private var notice: some View {
        let failure = NoticeAction.failureDetail(of: text)
        let isOffer = NoticeAction.isOffer(text)
        // Read only under a failure that is the chat's last word: the menu lists them, the button needs one.
        let otherModels = failure != nil && offersActions ? model.retryModels(for: botID) : []
        let actions = NoticeAction.actions(for: text, canCompact: canCompact, hasProposal: hasProposal,
                                           canSwitchModel: !otherModels.isEmpty)
        let showsButtons = NoticeAction.showsButtons(for: text, actions: actions, offers: offersActions)
        Group {
            if isOffer {
                offer(actions: actions, showsButtons: showsButtons)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let failure {
                        let parts = NoticeAction.failureParts(of: failure)
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Não deu certo", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.danger)
                            Text(parts.sentence)
                                .font(Typography.label)
                                .foregroundStyle(Palette.muted)
                                .multilineTextAlignment(.leading)
                                .textSelection(.enabled)
                            if let provider = parts.provider { providerDetail(provider) }
                        }
                    } else {
                        Text(text)
                            .font(Typography.label)
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.leading)
                    }
                    if showsButtons {
                        buttons(actions, otherModels: otherModels)
                            .transition(.opacity)
                    }
                }
            }
        }
        // The buttons come with the notice's turn to be the last thing in the chat (and go when something follows): the
        // transition was there, the trigger was not (§2.13).
        .motion(Motion.content, value: showsButtons)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .alignedWithReplyText()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TranscriptSpeech.notice(failure.map { "não deu certo. " + $0 } ?? text))
        .task(id: id) {
            if let slug = NoticeAction.proposedSlug(in: text) { hasProposal = await model.hasSkillProposal(slug, of: botID) }
            if text.hasPrefix(NoticeAction.memoryMergePrefix) { hasProposal = await model.hasMemoryMergeProposal(botID, notice: text) }
            guard NoticeAction.actions(for: text).contains(.compact), let input = model.contextInput(for: botID) else { return }
            canCompact = await Task.detached { ContextReading.make(input)?.canCompact ?? false }.value
        }
        .sheet(item: $reviewing, onDismiss: {
            guard let slug = NoticeAction.proposedSlug(in: text) else { return }
            Task { hasProposal = await model.hasSkillProposal(slug, of: botID) }
        }) { draft in
            SkillEditor(skill: draft.skill, proposal: draft)
        }
    }

    /// Something kept or proposed for you (a memory, a skill): a card with its symbol and its buttons beside the words, or
    /// under them when they do not fit. Once decided it has no button left, and its words go quiet.
    private func offer(actions: [NoticeAction], showsButtons: Bool) -> some View {
        let symbol = NoticeAction.actions(for: text).first?.symbol ?? "sparkles"
        let words = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(Typography.small)
                .foregroundStyle(showsButtons ? Palette.accentText : Palette.faint)
                .accessibilityHidden(true)
            Text(text)
                .font(Typography.label)
                .foregroundStyle(showsButtons ? Palette.muted : Palette.faint)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                words.fixedSize()
                if showsButtons { buttons(actions, otherModels: []).transition(.opacity) }
            }
            VStack(alignment: .leading, spacing: 8) {
                words
                if showsButtons { buttons(actions, otherModels: []).transition(.opacity) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.ghostHover, in: .rect(cornerRadius: Radius.card))
    }

    private func buttons(_ actions: [NoticeAction], otherModels: [(ref: String, name: String, provider: String)]) -> some View {
        HStack(spacing: 8) {
            ForEach(actions, id: \.self) { action in
                if action == .otherModel {
                    Menu {
                        ForEach(otherModels, id: \.ref) { other in
                            Button("\(other.name) · \(other.provider)") { model.retryLastTurn(botID, model: ModelRef(other.ref)) }
                        }
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(NoticeActionStyle(prominent: false))
                    .fixedSize()
                    .help(action.help)
                } else {
                    Button { perform(action) } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                    .buttonStyle(NoticeActionStyle(prominent: action == actions.first))
                    .help(action.help)
                }
            }
        }
    }

    /// The provider's own words about a failure, folded under "Detalhes": the sentence above says what to do.
    private func providerDetail(_ provider: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                showsProviderDetail.toggle()
            } label: {
                HStack(spacing: 3) {
                    Text("Detalhes")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showsProviderDetail ? 90 : 0))
                }
                .font(Typography.small)
                .foregroundStyle(Palette.faint)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .clickablePointer()
            .help(showsProviderDetail ? "Esconde a mensagem do provedor" : "Mostra a mensagem do provedor")
            if showsProviderDetail {
                Text(provider)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.faint)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .transition(.opacity)
            }
        }
        .padding(.top, 2)
        .motion(Motion.content, value: showsProviderDetail)
    }

    /// The last item of the chat, with nothing running. (Read only by notices that have an action.)
    private var offersActions: Bool {
        model.orbTranscript(botID).items.last?.id == id && !model.live(botID).isWorking
    }

    private func perform(_ action: NoticeAction) {
        switch action {
        case .retry: model.retryLastTurn(botID)
        case .otherModel: break // a menu of models, built in `body`
        case .continueTurn: model.continueTurn(botID, after: text)
        case .openSettings: SettingsRouter.open(.models, using: openSettings)
        case .compact: model.compactAndRetry(botID)
        case .openMemory: model.showMemory(of: botID)
        case .reviewSkill:
            guard let slug = NoticeAction.proposedSlug(in: text) else { return }
            Task { reviewing = await model.skillDraft(slug, from: botID) }
        case .mergeMemory:
            hasProposal = false
            Task { await model.applyMemoryMerge(botID) }
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

/// A long command in a `CommandBlock` (an approval card, an action of the chat): its first lines and its last, with the
/// middle one click away (a script of 200 lines would push the buttons off the window). The end stays in view because
/// that is where a script does its work (`… | sh`), and a risky command is never folded. Its output shows its first
/// lines (`head`).
enum CommandExcerpt {
    static let headLines = 9
    static let tailLines = 3
    static let shownCharacters = 1_200
    static let outputLines = 8

    /// The first `outputLines` lines of an output (at most `shownCharacters` characters of them) and how many lines are
    /// left out; nil when it is short enough to show whole.
    static func head(of output: String) -> (text: String, hiddenLines: Int)? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        let hidden = lines.count - outputLines
        guard hidden > 0 || output.count > shownCharacters else { return nil }
        var text = lines.prefix(outputLines).joined(separator: "\n")
        if text.count > shownCharacters { text = String(text.prefix(shownCharacters)) + "…" }
        return (text, max(hidden, 0))
    }

    /// The start and end of `command` and how many lines are left out between them; nil when it is short enough to
    /// show whole.
    static func excerpt(of command: String) -> (text: String, hiddenLines: Int)? {
        let lines = command.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > headLines + tailLines + 1 || command.count > shownCharacters else { return nil }
        let head = lines.prefix(headLines).joined(separator: "\n"), tail = lines.suffix(tailLines).joined(separator: "\n")
        let hidden = max(lines.count - headLines - tailLines, 0)
        guard hidden > 0, head.count + tail.count <= shownCharacters else {
            // Few long lines: the characters at both ends.
            let end = shownCharacters / 4
            return (String(command.prefix(shownCharacters - end)) + "\n…\n" + String(command.suffix(end)), hidden)
        }
        return (head + "\n…\n" + tail, hidden)
    }

    static func showAll(hidden lines: Int) -> String {
        switch lines {
        case 0: "Mostrar tudo"
        case 1: "Mostrar tudo (mais 1 linha)"
        default: "Mostrar tudo (mais \(lines) linhas)"
        }
    }
}

/// What an answered approval card says on its one line.
enum ApprovalSummary {
    static func label(_ decision: ApprovalDecision) -> String {
        decision == .once ? "Permitido" : decision.label
    }

    /// The record of an answered card: a hand-off was finished or cancelled, not allowed or denied.
    static func label(_ request: ApprovalRequest) -> String {
        guard request.isHandoff else { return label(request.decision ?? .deny) }
        return request.decision == .deny || request.decision == nil ? "Cancelado" : "Pronto"
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
    /// False where the keys do not reach the card (a group's approval bar: ⌘↩ and esc answer the selected Orb's card).
    let showsKeyHints: Bool

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

    init(request: ApprovalRequest, botID: UUID, pulses: Bool = false, showsKeyHints: Bool = true) {
        self.request = request
        self.botID = botID
        self.showsKeyHints = showsKeyHints
        _pulsesOnArrival = State(initialValue: pulses)
    }

    /// Read from this Orb's own state (not the list of Orbs), so reordering Orbs does not redraw the card.
    private var orbName: String { model.live(botID).look.name }

    private var isPending: Bool { request.decision == nil }
    /// Whether this is the card ⌘↩ and esc answer, so its buttons name the keys.
    private var showsKeys: Bool { showsKeyHints && model.showsApprovalKeys(request.id, of: botID) }
    private var allowTitle: String { request.isHandoff ? "Pronto" : request.isBatch ? "Permitir as \(request.items.count)" : "Permitir" }
    private var denyTitle: String { request.isHandoff ? "Cancelar" : "Não permitir" }
    /// A request the gate marks as risky (deleting files, sudo, force push) gets the red pill: white is "go ahead".
    private var allowFill: Color { request.isDangerous ? Palette.danger : Palette.ink }
    private var allowText: Color { request.isDangerous ? .white : Palette.onInk }
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
        .chatCard()
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
            if request.isHandoff {
                EmptyView()
            } else if showsNote {
                TextField("Diga o que fazer em vez disso…", text: $note)
                    .textFieldStyle(.plain)
                    .font(Typography.label)
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
                    .background(Palette.raised.opacity(0.6), in: .rect(cornerRadius: Radius.small))
                    .accessibilityLabel("Instrução ao negar")
                    .transition(.adapted(.unfold, reduceMotion: reduceMotion))
            }
            ViewThatFits(in: .horizontal) {
                ActionRow { refusal.hangsOnLeadingEdge() } trailing: { allowControl }
                VStack(alignment: .trailing, spacing: Spacing.controlGap) {
                    ActionRow { refusal.hangsOnLeadingEdge() } trailing: { EmptyView() }
                    ActionRow { EmptyView() } trailing: { allowControl }
                }
            }
        }
        // The field opens under the text (4 pt down) and the link beside "Não permitir" gives way by fading; the card
        // grows in `Motion.content` (§2.13). Focus goes to the field at once.
        .motion(Motion.content, value: showsNote)
        .padding(14)
        .card(radius: Radius.card, stroke: Palette.lineStrong)
        .overlay {
            if ApprovalPulse.pulses(isNew: pulsesOnArrival, reduceMotion: reduceMotion) {
                ApprovalPulseBorder(radius: Radius.card, trigger: pulse)
            }
        }
        .onAppear { if pulsesOnArrival { pulse += 1 } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(request.isHandoff ? TranscriptSpeech.handoff(title: request.title)
                            : TranscriptSpeech.approval(botName: orbName.isEmpty ? "O Orb" : orbName, title: request.title))
    }

    /// The title, why, the command or the list of actions, and what the user said when denying.
    @ViewBuilder private var details: some View {
        HStack(spacing: 8) {
            if request.isDangerous {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Typography.label)
                    .foregroundStyle(Palette.warn)
                    .accessibilityLabel("Ação arriscada")
            }
            Text(request.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .contentTransition(reduceMotion ? .opacity : .numericText())
            Spacer()
            // At the end of the line, so the title starts where every other card's title does.
            if request.isHandoff {
                Image(systemName: "macwindow")
                    .font(Typography.label)
                    .foregroundStyle(Palette.accentText)
                    .accessibilityHidden(true)
            }
        }
        if !request.reason.isEmpty {
            Text(request.reason)
                .font(Typography.text)
                .foregroundStyle(Palette.muted)
        }
        if request.isBatch {
            batchList
        } else if !request.command.isEmpty {
            // The command as the chat shows it once it ran (`ToolCallLine`), on the card's own fill.
            let isCommand = request.toolName == "run_command"
            let shown = isCommand ? ShownCommand.split(request.command) : (command: request.command, folder: nil)
            CommandBlock(command: shown.command, prompt: isCommand, isCode: !request.isHandoff, foldsCommand: !request.isDangerous,
                         folder: shown.folder, fill: Palette.raised, copies: false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let note = request.note {
            Text("Você disse: \(note)")
                .font(Typography.label)
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
                    withAnimation(FoldMotion.animation(reduceMotion: reduceMotion)) { showsAllItems = true }
                } label: {
                    Text("e mais \(request.items.count - Self.visibleItems)")
                        .font(Typography.label)
                        .foregroundStyle(Palette.muted)
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(Tip.showAllActions)
                .accessibilityHint("Mostra todas as ações")
                .transition(.opacity)
            }
        }
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.raised, in: .rect(cornerRadius: Radius.small))
    }

    /// "Não permitir" and, beside it, the quiet way to say what to do instead: a refusal with a note belongs with the
    /// refusal, in gray, not in blue above the buttons of every card.
    private var refusal: some View {
        HStack(spacing: Spacing.controlGap) {
            denyButton
            if !request.isHandoff, !showsNote {
                Button("Dizer o que fazer…") { showsNote = true }
                    .buttonStyle(QuietTextStyle())
                    .font(Typography.label)
                    .fixedSize()
                    .help(Tip.denyWithNote)
                    .accessibilityHint("Recusa o pedido e deixa você dizer o que fazer em vez disso")
                    .transition(.opacity)
            }
        }
    }

    private var denyButton: some View {
        Button(action: deny) {
            HStack(spacing: 6) {
                Text(denyTitle)
                if showsKeys {
                    Text("esc")
                        .font(Typography.small)
                        .foregroundStyle(Palette.muted)
                }
            }
        }
        .buttonStyle(GhostStyle())
        .background(pressed == .deny ? Palette.ghostSelected : .clear, in: .capsule)
        .scaleEffect(pressed == .deny ? ApprovalShortcut.pressScale : 1)
        .animation(Motion.press, value: pressed)
        .help("\(request.isHandoff ? Tip.handoffCancel : Tip.deny) (\(ShortcutCatalog.keys(for: .denyApproval)))")
        .accessibilityLabel(denyTitle)
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
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                    if showsKeys {
                        Text(AppShortcut.commandReturn.label)
                            .font(Typography.small)
                            .opacity(0.55)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(allowText)
                .padding(.leading, 14)
                .padding(.trailing, hasMoreOptions ? 10 : 14)
                .frame(minHeight: ControlHeight.regular)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("\(request.isHandoff ? Tip.handoffDone : allowTitle) (\(AppShortcut.commandReturn.label))")
            .accessibilityLabel(allowTitle)
            .accessibilityHint("Atalho: ⌘↩")
            if hasMoreOptions {
                Rectangle().fill(allowText.opacity(0.25)).frame(width: 1, height: 16)
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
                        .foregroundStyle(allowText)
                        .frame(width: 30, height: ControlHeight.regular)
                        .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Tip.allowOptions)
                .accessibilityLabel("Sempre permitir e outras opções")
            }
        }
        .background(allowFill, in: .capsule)
        .opacity(pressed == .allow ? 0.85 : 1)
        .scaleEffect(pressed == .allow ? ApprovalShortcut.pressScale : 1)
        .animation(Motion.press, value: pressed)
    }

    // MARK: Answered

    private var answeredCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(FoldMotion.animation(reduceMotion: reduceMotion)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: request.decision == .deny ? "xmark.circle" : "checkmark.circle")
                        .font(Typography.small)
                        .foregroundStyle(request.decision == .deny ? Palette.danger : Palette.faint)
                        .frame(width: 14)
                    (Text(ApprovalSummary.label(request))
                        .foregroundColor(request.decision == .deny ? Palette.danger : Palette.muted)
                        + Text(" · \(ApprovalSummary.title(request))").foregroundColor(Palette.muted)
                        + Text("  \(ApprovalSummary.detail(request))").foregroundColor(Palette.faint))
                        .font(Typography.label)
                        .lineLimit(1)
                        .truncationMode(.middle) // a long command keeps its start and its end
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
            .help(Tip.toggleRequest(isOpen: isOpen))
            .accessibilityLabel("\(ApprovalSummary.label(request)): \(ApprovalSummary.title(request)). \(ApprovalSummary.detail(request))")
            .accessibilityValue(isOpen ? "expandido" : "recolhido")
            .accessibilityHint("Mostra o pedido")

            if isOpen {
                // A card read, not answered: 12 pt in, as the other cards to read (14 is for the ones that ask).
                VStack(alignment: .leading, spacing: 10) { details }
                    .padding(12)
                    .card(radius: Radius.card, stroke: Palette.line)
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
        guard model.selectedBot?.id == botID, model.newestPendingApprovalID(of: botID) == request.id,
              !model.findFieldHasFocus else { return false } // Esc in the find field closes the find bar
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
