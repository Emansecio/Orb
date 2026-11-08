import SwiftUI
import AppKit

// The menu bar panel: ask an Orb something, answer its permission requests and read its reply without opening the
// app.

// MARK: Plain values (tested)

/// What a permission card in the panel shows of the request, so a "Permitir" is never given blind.
struct ApprovalPreview: Equatable {
    struct Row: Equatable {
        /// The action's name; nil for a single action, whose name is the card's title.
        var title: String?
        var command: String
    }

    var rows: [Row]
    /// Actions of a group that are not listed.
    var extra: Int

    static let limit = 3

    static func of(_ request: ApprovalRequest, limit: Int = ApprovalPreview.limit) -> ApprovalPreview {
        guard request.isBatch else {
            return ApprovalPreview(rows: request.command.isEmpty ? [] : [Row(title: nil, command: request.command)], extra: 0)
        }
        let rows = request.items.prefix(limit).map { Row(title: $0.title, command: $0.command) }
        return ApprovalPreview(rows: rows, extra: max(0, request.items.count - limit))
    }

    /// "+ 2 ações" / "+ 1 ação".
    var extraLabel: String? {
        extra > 0 ? "+ \(extra) \(extra == 1 ? "ação" : "ações")" : nil
    }
}

/// The reply shown in the panel: the newest Orb message of the turn that was just asked, cut to its last lines.
enum QuickAskReplyText {
    struct Reply: Equatable {
        var itemID: UUID
        var text: String
        var isStreaming: Bool
    }

    /// The Orb's newest message after the user's last one; nil while nothing has been said yet.
    static func latestReply(in items: [TranscriptItem]) -> Reply? {
        for item in items.reversed() {
            switch item.kind {
            case .bot(let text, let isStreaming): return Reply(itemID: item.id, text: text, isStreaming: isStreaming)
            case .user: return nil
            default: continue
            }
        }
        return nil
    }

    /// Whether the header says what the Orb is doing instead of "respondeu": before any reply and while one is written, and also
    /// while the Orb still works after a message it already closed ("Vou ver o que tem lá." and then commands).
    static func showsWork(reply: Reply?, isWorking: Bool) -> Bool {
        reply == nil || reply?.isStreaming == true || isWorking
    }

    /// The last `maxLines` lines that have text, with the blank line between paragraphs kept (one, however many there
    /// were), and whether something was left out at the start. A list's "- " becomes a bullet.
    static func excerpt(_ text: String, maxLines: Int = 6) -> (text: String, isCut: Bool) {
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let last = lines.last, !last.isEmpty { lines.append("") }
            } else {
                lines.append(bulleted(line))
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        var kept: [String] = []
        var count = 0
        for line in lines.reversed() {
            if !line.isEmpty {
                if count == maxLines { break }
                count += 1
            }
            kept.append(line)
        }
        while kept.last?.isEmpty == true { kept.removeLast() }
        return (kept.reversed().joined(separator: "\n"), kept.count < lines.count)
    }

    /// The same, from a streamed reply's closed paragraphs and its open tail, reading only as far back as the
    /// excerpt needs: a long reply is not joined and split again on every token.
    static func excerpt(closed: [String], tail: String, maxLines: Int = 6) -> (text: String, isCut: Bool) {
        var pieces = [tail]
        var count = Self.textLines(tail)
        var index = closed.count
        while count <= maxLines, index > 0 {
            index -= 1
            pieces.insert(closed[index], at: 0)
            count += Self.textLines(closed[index])
        }
        // It stopped before the start only with more than `maxLines` lines in hand, so `excerpt` sees the cut itself.
        return excerpt(pieces.joined(separator: "\n\n"), maxLines: maxLines)
    }

    private static func textLines(_ text: String) -> Int {
        text.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }.count
    }

    private static func bulleted(_ line: String) -> String {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return "• " + line.dropFirst(marker.count)
        }
        return line
    }
}

/// What ↩ does in the panel, by the state of the chosen Orb: the same rule as the composer's (queue while it works on
/// your chat), and a line instead of silence when it cannot take a message (a routine holds it).
enum QuickAskSend: Equatable {
    case send, queue, blocked, noModel, nothing

    /// `orbHasModel`: the Orb's own model (it may differ from the default one `isReady` is about) is usable.
    static func action(isWorking: Bool, canSteer: Bool, isReady: Bool, hasText: Bool, orbHasModel: Bool = true) -> QuickAskSend {
        guard isReady, hasText else { return .nothing }
        guard orbHasModel else { return .noModel }
        if !isWorking { return .send }
        return canSteer ? .queue : .blocked
    }

    static func blockedNote(name: String) -> String { "\(name) está ocupado com outro trabalho. Envie quando terminar." }

    static let checkingNote = "Verificando as conexões. Tente de novo em instantes."

    static func noModelNote(name: String) -> String { "O modelo de \(name) não está conectado. Veja em Ajustes → Modelos." }

    /// What the app shows after a question: the asked Orb's chat, unless a sheet of the main window is open (switching
    /// the screen would close it along with what was typed in it).
    static func selection(after target: UUID, current: SidebarItem?, hasOpenSheet: Bool) -> SidebarItem? {
        hasOpenSheet ? current : .bot(target)
    }

    /// The panel's key hint.
    /// `afterPulse`: the message waits for the pulse's turn in the chat, then goes (`AppModel.canQueueOutsideComposer`).
    static func hint(isWorking: Bool, canSteer: Bool, afterPulse: Bool = false) -> String {
        let newLine = "\(CommandName.newLineKeys) nova linha"
        if !isWorking { return "↩ envia · \(newLine)" }
        if afterPulse { return "↩ envia depois do pulso · \(newLine)" }
        guard canSteer else { return "Orb ocupado · \(newLine)" }
        return "↩ envia agora · \(newLine)"
    }
}

// MARK: The panel

struct QuickAskView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var botID: UUID?
    @State private var text = ""
    /// The Orb whose reply the panel shows (the one asked last).
    @State private var replyBotID: UUID?
    /// Why the last ↩ did nothing (the chosen Orb is in a routine).
    @State private var note: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        let selected = selectedID.flatMap { model.liveBot($0)?.look }
        VStack(alignment: .leading, spacing: 12) {
            PendingApprovalsSection(openApp: open)
            // The Orbs and the chosen one's name share a line while they fit (an Orb alone is not a line of its own); with
            // many Orbs the avatars scroll above the name, as before.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    orbButtons
                    chosenLabel(selected)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView(.horizontal) { orbButtons }
                        .scrollIndicators(.never)
                    chosenLabel(selected)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Mensagem para \(selected?.name ?? "um Orb")", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($isFocused)
                    .onSubmit(send)
                    // ⇧↩ breaks the line, as in the chat's field.
                    .background {
                        ApprovalKeyMonitor { event, window in
                            isFocused && window.attachedSheet == nil && NewLineKey.isShiftReturn(event) && NewLineKey.insert(in: window)
                        }
                    }
                    .accessibilityLabel("Mensagem para \(selected?.name ?? "um Orb")")
                    .onChange(of: text) { note = nil }
                    .onChange(of: selectedID) { note = nil }
                // The same button as the creation chat's: ↩ alone is no target for the pointer or for VoiceOver.
                let canSend = selectedID != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                SendArrowButton(canSend: canSend, help: "Enviar (↩)", action: send)
            }
            .padding(10)
            .card(radius: Radius.medium)
            // What appears here fades in by itself (`.quiet`, 0.15 s) and the panel, a window that fits its content, takes its
            // new height at once: animating the height would resize the window on every frame (§2.13).
            if let note {
                Text(note)
                    .font(Typography.label)
                    .foregroundStyle(Palette.warn)
                    .transition(.quiet)
            }

            if model.hasCheckedConnections, !(selectedID.map(model.hasUsableModel) ?? false) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").foregroundStyle(Palette.warn)
                    Text("Conecte um modelo.")
                        .font(Typography.label)
                        .foregroundStyle(Palette.secondary)
                    Spacer(minLength: 4)
                    Button("Abrir Ajustes") { SettingsRouter.open(.models, using: openSettings) }
                    .buttonStyle(.link)
                    .font(Typography.label)
                    .help(Tip.connectModel)
                }
                .transition(.quiet)
            }

            if let replyBotID, model.liveBot(replyBotID) != nil {
                QuickAskReply(botID: replyBotID, openChat: { openChat(replyBotID) }, dismiss: { self.replyBotID = nil })
                    .transition(.quiet)
            }

            let others = model.workingIDs.filter { $0 != replyBotID }
            if !others.isEmpty {
                Divider().transition(.quiet)
                ForEach(others, id: \.self) { id in
                    QuickAskWorkingRow(botID: id)
                        .transition(.quiet)
                }
            }
            HStack {
                // Same link, same size as "Abrir Ajustes" above; the key hint is one step smaller, as in the composer.
                Button("Abrir o app") { open() }
                    .font(Typography.label)
                    .help(Tip.openMainWindow)
                Spacer()
                Text(QuickAskSend.hint(isWorking: selectedID.map(model.isWorking) ?? false,
                                       canSteer: selectedID.map(model.canSteer) ?? false,
                                       afterPulse: selectedID.map { !model.canSteer($0) && model.canQueueOutsideComposer($0) } ?? false))
                    .font(Typography.small)
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { isFocused = true }
    }

    private var orbButtons: some View {
        HStack(spacing: 8) {
            ForEach(model.botIDs, id: \.self) { id in
                QuickAskOrbButton(botID: id, selectedID: selectedID, chosen: $botID)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
    }

    @ViewBuilder private func chosenLabel(_ selected: BotLook?) -> some View {
        if let selected {
            Text(selected.role.isEmpty ? selected.name : "\(selected.name) · \(selected.role)")
                .font(Typography.label)
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
        }
    }

    private var selectedID: UUID? {
        if let botID, model.botIDs.contains(botID) { return botID }
        if case .bot(let id) = model.selection, model.botIDs.contains(id) { return id }
        return model.sidebarBotIDs.first
    }

    private func send() {
        guard let id = selectedID else { return }
        let name = model.liveBot(id)?.look.name ?? "O Orb"
        guard model.hasCheckedConnections || model.hasUsableModel(id) else {
            note = QuickAskSend.checkingNote // what was typed stays
            return
        }
        switch QuickAskSend.action(isWorking: model.isWorking(id), canSteer: model.canQueueOutsideComposer(id), isReady: model.hasUsableModel(id) || model.isProviderReady,
                                   hasText: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                   orbHasModel: model.hasUsableModel(id)) {
        case .nothing: return
        case .blocked:
            note = QuickAskSend.blockedNote(name: name)
            return
        case .noModel:
            note = QuickAskSend.noModelNote(name: name) // what was typed stays
            return
        case .queue: model.queueOutsideComposer(text, to: id)
        case .send: model.sendWhenLoaded(text, to: id)
        }
        model.selection = QuickAskSend.selection(after: id, current: model.selection, hasOpenSheet: model.hasOpenSheet)
        replyBotID = id
        text = ""
    }

    private func openChat(_ id: UUID) {
        model.selection = QuickAskSend.selection(after: id, current: model.selection, hasOpenSheet: model.hasOpenSheet)
        open()
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// One Orb's avatar in the menu bar panel. Reads its own Orb only: another Orb's status does not redraw it.
private struct QuickAskOrbButton: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let selectedID: UUID?
    @Binding var chosen: UUID?

    var body: some View {
        let live = model.live(botID)
        let isSelected = selectedID == botID
        Button { chosen = botID } label: {
            // Only the chosen Orb and those with something going on move; the rest rest (no frames).
            BotAvatar(live: live, size: 28, paused: !isSelected && live.activity == .idle)
                .opacity(isSelected ? 1 : 0.5)
                .padding(3)
                .overlay(Circle().strokeBorder(isSelected ? Palette.ink.opacity(0.85) : .clear, lineWidth: 1.5))
                // A chip chosen: the ring and the opacity answer with the press curve (colors only, also under Reduce Motion).
                .animation(Motion.press, value: isSelected)
                .overlay(alignment: .topTrailing) {
                    if live.needsYou {
                        Circle().fill(Palette.warn).frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Palette.chrome, lineWidth: 1.5))
                    }
                }
                // Over the chip, not in the Orb: an Orb that is not chosen is dimmed, and the dot must not be. The amber
                // dot above has the corner when the Orb waits for you.
                .overlay(alignment: .topTrailing) { OrbBadge(show: live.unread > 0 && !live.needsYou, size: 28).padding(3) }
        }
        .buttonStyle(.plain)
        .help(Tip.chooseOrb(named: live.look.name))
        .accessibilityLabel(live.look.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "Name: doing X", the one look both lines of the panel give it (the working row and the reply's header): dim text with
/// the sweep while it works, amber and still while it waits for you.
private struct QuickAskWorkText: View {
    let name: String
    let work: WorkLine

    var body: some View {
        Text("\(name): \(work.text)")
            .shimmer(active: work.shimmers, pulses: work.runsCommand)
            .font(Typography.label.weight(.medium))
            .foregroundStyle(work.tone == .waiting ? Palette.warn : Palette.faint)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// A working Orb's line in the menu bar panel: its avatar and what it is doing.
private struct QuickAskWorkingRow: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        let live = model.live(botID)
        HStack(spacing: 8) {
            BotAvatar(live: live, size: 18, paused: live.activity == .idle)
            let work = live.shownWork
            if let work {
                QuickAskWorkText(name: live.look.name, work: work)
                    .animateChanges(of: work.text)
            }
        }
    }
}

/// What the Orb answered, in the panel: while it writes, the last few lines; when it is done, the same with a
/// button to continue in the app.
struct QuickAskReply: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let openChat: () -> Void
    let dismiss: () -> Void
    /// A fixed reply instead of the Orb's own (the review snapshots).
    var sample: QuickAskReplyText.Reply?

    var body: some View {
        let live = model.live(botID)
        let reply = sample ?? QuickAskReplyText.latestReply(in: model.orbTranscript(botID).items)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Rests when the Orb is idle (the finished reply stays on screen for a while).
                BotAvatar(live: live, size: 18, paused: live.activity == .idle)
                if let work = live.shownWork, QuickAskReplyText.showsWork(reply: reply, isWorking: live.isWorking) {
                    QuickAskWorkText(name: live.look.name, work: work)
                } else {
                    Text(reply == nil ? "\(live.look.name) não respondeu" : "\(live.look.name) respondeu")
                        .font(Typography.label.weight(.medium))
                        .foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 4)
                Button("Fechar resposta", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(CircleGhostStyle(side: 20, fontSize: 10)) // 20 pt target with hover around the small glyph
                    .help(Tip.closeReply)
                    .foregroundStyle(Palette.muted)
            }
            if let reply {
                ReplyExcerpt(botID: botID, reply: reply)
            }
            Button("Ver conversa", action: openChat)
                .help(Tip.openChatInApp)
                .buttonStyle(.link)
                .font(Typography.label)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Radius.medium)
        .accessibilityElement(children: .contain)
    }
}

/// The reply's last lines. Reads the streamed text through its `LiveText` like the chat does, so only this view is
/// redrawn as it arrives.
private struct ReplyExcerpt: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let reply: QuickAskReplyText.Reply

    var body: some View {
        let shown: (text: String, isCut: Bool) = {
            guard reply.isStreaming, let live = model.liveText(for: reply.itemID, of: botID) else {
                return QuickAskReplyText.excerpt(reply.text)
            }
            return QuickAskReplyText.excerpt(closed: live.closed, tail: live.tail)
        }()
        if !shown.text.isEmpty {
            // The line is joined once; the plain Text is only built if the markdown does not parse (`??` is lazy).
            let line = shown.isCut ? "… " + shown.text : shown.text
            let styled = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                .map { Text($0) } ?? Text(line)
            styled
                .font(Typography.label)
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

// MARK: Permission requests

/// Every Orb's open approval cards, answerable from the menu bar without opening the app.
private struct PendingApprovalsSection: View {
    @Environment(AppModel.self) private var model
    let openApp: () -> Void

    var body: some View {
        let pending = model.pendingApprovals
        if !pending.isEmpty {
            // Scrolls past a height, so several waiting Orbs do not push the question field off the panel.
            ViewThatFits(in: .vertical) {
                cards(pending)
                ScrollView { cards(pending) }
                    .frame(maxHeight: 300)
            }
            .transition(.quiet)
        }
    }

    private func cards(_ pending: [PendingApproval]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // One heading per Orb, its cards under it: "Atlas precisa de você" said once, not on every card.
            ForEach(QuickAskApprovalGroups.byOrb(pending), id: \.first?.bot.id) { group in
                VStack(alignment: .leading, spacing: 6) {
                    if let bot = group.first?.bot { QuickAskOrbHeading(bot: bot, count: group.count) }
                    ForEach(group) { entry in
                        QuickAskApprovalCard(entry: entry, showsHeading: false, openApp: {
                            // A sheet of the main window stays (switching the screen would close it with what was typed in it).
                            // An answered request has nothing to open (its card is leaving); a vanished chat still brings the app up.
                            if !model.hasOpenSheet,
                               model.openPending(entry.bot.id, approval: entry.request.id) == .answered { return }
                            openApp()
                        })
                        .transition(.quiet)
                    }
                }
            }
        }
    }
}

enum QuickAskApprovalGroups {
    /// The requests grouped by the Orb that asks, in the order each Orb first appears; inside a group, in the given order.
    static func byOrb(_ pending: [PendingApproval]) -> [[PendingApproval]] {
        var groups: [[PendingApproval]] = []
        var row: [UUID: Int] = [:]
        for entry in pending {
            if let index = row[entry.bot.id] {
                groups[index].append(entry)
            } else {
                row[entry.bot.id] = groups.count
                groups.append([entry])
            }
        }
        return groups
    }
}

/// "Atlas precisa de você", over the cards of one Orb.
private struct QuickAskOrbHeading: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    let count: Int

    var body: some View {
        let live = model.live(bot.id)
        HStack(spacing: 8) {
            BotAvatar(live: live, size: 18, paused: live.activity == .idle)
            Text(bot.name)
                .font(Typography.label.weight(.semibold))
            Text(count > 1 ? "precisa de você · \(count) pedidos" : "precisa de você")
                .font(Typography.small)
                .foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One card: who asks, what exactly (a group lists its first actions), why, and the answers. A risky action is not
/// allowed from here: the app shows it with its whole context.
struct QuickAskApprovalCard: View {
    @Environment(AppModel.self) private var model
    let entry: PendingApproval
    /// False under an Orb's own heading (`QuickAskOrbHeading`), which already says who asks.
    var showsHeading = true
    let openApp: () -> Void

    var body: some View {
        let request = entry.request
        let preview = ApprovalPreview.of(request)
        let live = model.live(entry.bot.id)
        VStack(alignment: .leading, spacing: 6) {
            if showsHeading {
                HStack(spacing: 8) {
                    BotAvatar(live: live, size: 18, paused: live.activity == .idle)
                    Text(entry.bot.name)
                        .font(Typography.label.weight(.semibold))
                    Text("precisa de você")
                        .font(Typography.small)
                        .foregroundStyle(Palette.muted)
                }
            }
            Text(request.title)
                .font(Typography.text.weight(.medium))
            if !request.reason.isEmpty, !request.isBatch {
                Text(request.reason)
                    .font(Typography.label)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(3)
            }
            ForEach(Array(preview.rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 1) {
                    if let title = row.title, !title.isEmpty {
                        Text(title)
                            .font(Typography.small)
                            .foregroundStyle(Palette.muted)
                    }
                    Text(row.command)
                        .font(request.isQuestion ? Typography.small : Typography.codeSmall)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(request.isBatch ? 1 : 4)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let extra = preview.extraLabel {
                Text(extra)
                    .font(Typography.small)
                    .foregroundStyle(Palette.muted)
            }
            if request.isDangerous {
                Label("Ação arriscada. Abra o app para revisar.", systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.label)
                    .foregroundStyle(Palette.warn)
            }
            ActionRow {
                Button(request.isProposal ? "Não criar" : request.isAccess ? "Agora não" : request.isQuestion ? "Pular" : request.isHandoff ? "Cancelar" : "Não permitir") {
                    model.decide(.deny, approvalID: request.id, botID: entry.bot.id)
                }
                .buttonStyle(GhostStyle())
                .help(request.isQuestion ? Tip.skipQuestion : request.isAccess ? Tip.declineAccess : request.isHandoff ? Tip.handoffCancel : Tip.deny)
                .hangsOnLeadingEdge()
            } trailing: {
                if request.isDangerous || request.isProposal || request.isQuestion || request.isAccess { // a new Orb, an access or an answer is given in the app
                    Button(request.isQuestion ? "Responder" : "Abrir o app", action: openApp)
                        .buttonStyle(SecondaryPillStyle())
                        .help(request.isQuestion ? Tip.answerInApp : request.isAccess ? Tip.accessInApp : Tip.reviewRiskyInApp)
                } else {
                    Button(request.isHandoff ? "Pronto" : request.isBatch ? "Permitir as \(request.items.count)" : "Permitir") {
                        model.decide(.once, approvalID: request.id, botID: entry.bot.id)
                    }
                    .buttonStyle(PrimaryPillStyle())
                    .help(request.isHandoff ? Tip.handoffDone : request.isBatch ? Tip.allowBatchOnce : Tip.allowOnce)
                }
            }
        }
        .padding(10)
        // The risky one stands out by its outline too, not only by the line inside it.
        .card(radius: Radius.medium, stroke: request.isDangerous ? Palette.warn : Palette.lineStrong)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(request.isQuestion ? "\(entry.bot.name) pergunta" : request.isHandoff ? "\(entry.bot.name) espera você terminar no navegador" : "\(entry.bot.name) precisa da sua permissão")
    }
}
