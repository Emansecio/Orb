import SwiftUI

// The live screen's interface (docs/TELA-AO-VIVO.md, 3): the card in the chat while the turn uses the browser, the line it
// leaves after, and the panel's "Tela" tab. What changes rarely (the state, the host, the caption) is read here; what
// changes up to ten times a second (the picture, the pointer) is drawn by `LiveScreenLayerView` and never reaches a body.

/// The chat's row for one use of the Orb's browser: the live card while the turn uses it, the closing line after.
struct LiveScreenRow: View {
    let itemID: UUID
    let view: BrowserViewItem
    let botID: UUID

    var body: some View {
        ZStack(alignment: .topLeading) {
            if view.outcome == .running {
                LiveScreenCard(itemID: itemID, view: view, botID: botID).transition(.opacity)
            } else {
                LiveScreenClosedLine(itemID: itemID, view: view, botID: botID).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(Motion.content, value: view.outcome == .running)
    }
}

// MARK: - The card

/// 92 pt tall in every state, so the chat never jumps: the page on the left, on the right what it is (chip and host),
/// what the Orb does (caption) and the buttons.
private struct LiveScreenCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let itemID: UUID
    let view: BrowserViewItem
    let botID: UUID

    static let thumbnail = CGSize(width: 115, height: 72)

    var body: some View {
        let live = model.live(botID)
        let store = model.liveScreens.store(botID)
        // The Orb waits for a hand-off: the card answers it, in the place of the permission card (see `TranscriptRow`).
        let handoff = model.pendingHandoff(of: botID)
        let state = LiveCardState.of(outcome: view.outcome, phase: store.phase, isProtected: store.isProtected,
                                     isPrivate: store.isPrivate, handoff: handoff != nil)
        let work = live.shownWork
        let host = LiveScreenText.host(of: store.url) ?? (view.host.isEmpty ? nil : view.host)
        let caption = LiveScreenText.caption(for: state, work: work?.headline, handoffPage: handoff?.command,
                                             lastAction: work?.headline.trimmingCharacters(in: CharacterSet(charactersIn: "…")))
        HStack(alignment: .top, spacing: 12) {
            page(state, handoff: handoff, orb: live.look.orb)
            VStack(alignment: .leading, spacing: 0) {
                chipLine(state, host: host)
                Spacer(minLength: 2)
                captionLine(caption, state: state, work: work)
                Spacer(minLength: 2)
                buttons(state, handoff: handoff, store: store)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(height: 92)
        .card(radius: Radius.card)
        .overlay {
            // "Precisa de você" comes in once, with emphasis, and stays still: no pulse, no sound.
            if state == .needsYou {
                RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.warn.opacity(0.4), lineWidth: 1)
                    .entrance(EntranceStyle(distance: 0, scale: 0.97, animation: Motion.emphasis))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.leading, gutter)
        .background { if state == .needsYou, let handoff { ApprovalKeyMonitor { event, window in handleKey(event, window, handoff) } } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LiveScreenText.spoken(caption: caption))
        .onChange(of: state) { _, new in
            if let text = LiveScreenText.announcement(for: new) { AccessibilityNotification.Announcement(text).post() }
        }
    }

    // MARK: Pieces

    private func page(_ state: LiveCardState, handoff: ApprovalRequest?, orb: OrbConfig) -> some View {
        ZStack {
            Palette.raised
            LiveScreenSurface(hub: model.liveScreens, botID: botID, showsPage: state.showsFrames, isBlurred: state.veil == .blur,
                              isDimmed: state.dimsPage, showsPointer: state.showsPointer, pointerColor: orb.pointerColor)
            if state.veil != .none {
                LiveScreenVeil(veil: state.veil, text: LiveScreenText.veilText(for: state, handoffPage: handoff?.command), compact: true)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.thumbnail.width, height: Self.thumbnail.height)
        .clipShape(.rect(cornerRadius: Radius.small))
        .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Palette.line))
        .motion(Motion.content, value: state.veil)
        .contentShape(.rect(cornerRadius: Radius.small))
        .onTapGesture { if state.enlarges { enlarge() } }
        .help(state.enlarges ? Tip.enlargeScreen : "")
        .accessibilityHidden(true)
    }

    private func chipLine(_ state: LiveCardState, host: String?) -> some View {
        HStack(spacing: 8) {
            if let chip = state.chip {
                HStack(spacing: 5) {
                    if state.pulses {
                        BreathingDot(color: Palette.ok, breathes: !reduceMotion).frame(width: 6, height: 6).accessibilityHidden(true)
                    }
                    Text(chip).font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(chipColor(state))
            }
            if let host {
                Text(host).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(Typography.small)
        .foregroundStyle(Palette.faint)
        .motion(Motion.content, value: state)
    }

    private func chipColor(_ state: LiveCardState) -> Color {
        switch state {
        case .live, .privateView: Palette.ok
        case .needsYou: Palette.warn
        default: Palette.faint
        }
    }

    @ViewBuilder private func captionLine(_ caption: String, state: LiveCardState, work: WorkLine?) -> some View {
        let text = Text(caption)
            .font(Typography.label)
            .foregroundStyle(Palette.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        if state.shimmers && (work?.shimmers ?? true) {
            text.shimmer()
        } else {
            text
        }
    }

    private func buttons(_ state: LiveCardState, handoff: ApprovalRequest?, store: LiveFrameStore) -> some View {
        let kinds = state.buttons
        let showsKeys = handoff.map { model.showsApprovalKeys($0.id, of: botID) } ?? false
        // A narrow column first shortens the words ("Parar Orb" to "Parar"), and only then drops the last buttons rather
        // than wrapping: the card keeps its height.
        func row(_ count: Int, short: Bool = false) -> some View {
            HStack(spacing: Spacing.xs) {
                ForEach(Array(kinds.prefix(count)), id: \.self) { button($0, handoff: handoff, store: store, showsKeys: showsKeys, short: short) }
            }
        }
        return ViewThatFits(in: .horizontal) {
            row(kinds.count)
            row(kinds.count, short: true)
            row(max(kinds.count - 1, 1), short: true)
            row(1, short: true)
        }
        .controlSize(.small)
        .frame(height: ControlHeight.compact, alignment: .leading)
    }

    @ViewBuilder private func button(_ kind: LiveCardState.Button, handoff: ApprovalRequest?, store: LiveFrameStore,
                                     showsKeys: Bool, short: Bool) -> some View {
        switch kind {
        case .enlarge:
            Button("Ampliar") { enlarge() }.buttonStyle(SecondaryPillStyle()).help(Tip.enlargeScreen)
        case .stop:
            // Stops the whole Orb (its chains with other Orbs too), not just the turn as the composer's Stop does.
            Button(short ? "Parar" : "Parar Orb") { model.stop(botID) }.buttonStyle(GhostStyle()).help(Tip.stopBrowsing)
                .accessibilityLabel("Parar Orb")
        case .hide:
            Button(short ? "Ocultar" : "Ocultar tela") { store.isPrivate = true }.buttonStyle(GhostStyle()).help(Tip.hideScreen)
                .accessibilityLabel("Ocultar tela")
        case .reveal:
            Button(short ? "Mostrar" : "Mostrar tela") { store.isPrivate = false }.buttonStyle(PrimaryPillStyle()).help(Tip.revealScreen)
                .accessibilityLabel("Mostrar tela")
        case .done:
            Button { if let handoff { model.decide(.once, approvalID: handoff.id, botID: botID) } } label: {
                HStack(spacing: 7) {
                    Text("Terminei")
                    if showsKeys { Text(AppShortcut.commandReturn.label).font(Typography.small).opacity(0.55) }
                }
            }
            .buttonStyle(PrimaryPillStyle())
            .help("\(Tip.handoffDone) (\(AppShortcut.commandReturn.label))")
            .accessibilityHint("Atalho: ⌘↩")
        case .cancel:
            Button { if let handoff { model.decide(.deny, approvalID: handoff.id, botID: botID) } } label: {
                HStack(spacing: 6) {
                    Text("Cancelar")
                    if showsKeys { Text("esc").font(Typography.small).foregroundStyle(Palette.muted) }
                }
            }
            .buttonStyle(GhostStyle())
            .help("\(Tip.handoffCancel) (\(ShortcutCatalog.keys(for: .denyApproval)))")
            .accessibilityHint("Atalho: Esc")
        }
    }

    // MARK: Actions

    /// Opens the panel on the "Tela" tab, showing the page live.
    private func enlarge() {
        LiveScreenFocus.shared.clear(of: botID)
        model.setInspector(true)
        model.request(.showTab(.screen), of: botID)
    }

    /// ⌘↩ finishes the hand-off and Esc cancels it, as on the permission card this one stands for.
    private func handleKey(_ event: NSEvent, _ window: NSWindow, _ request: ApprovalRequest) -> Bool {
        guard model.selectedBot?.id == botID, model.newestPendingApprovalID(of: botID) == request.id,
              !model.findFieldHasFocus else { return false }
        let field = window.firstResponder as? NSTextView
        let editing = ApprovalShortcut.isEditing(responderIsText: field != nil, hasText: field.map { !$0.string.isEmpty } ?? false,
                                                 hasMarkedText: field?.hasMarkedText() ?? false, noteFocused: false)
        let typingInComposer = ApprovalShortcut.isTypingInComposer(isEditing: editing, noteFocused: false)
        guard let shortcut = ApprovalShortcut.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                                      isEditingText: editing, isTypingInComposer: typingInComposer) else { return false }
        switch shortcut {
        case .allow: model.decide(.once, approvalID: request.id, botID: botID)
        case .deny: model.decide(.deny, approvalID: request.id, botID: botID)
        }
        return true
    }
}

/// What covers a page the person must not see: a lock and a word, over an opaque fill (a login) or over a blurred page (Privado).
private struct LiveScreenVeil: View {
    let veil: LiveCardState.Veil
    let text: String
    var compact = false

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "lock.fill").font(.system(size: compact ? 14 : 22))
            Text(text).font(.system(size: compact ? 10 : 12))
        }
        .foregroundStyle(veil == .opaque ? Palette.muted : Palette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(veil == .opaque ? Palette.surface : Palette.surface.opacity(0.35))
    }
}

// MARK: - The line it leaves

/// The use is over: a line the height of a tool's, with what was done, and a way back to its last page while it is still
/// kept in memory (asked once, when the line appears: it is not watched).
private struct LiveScreenClosedLine: View {
    @Environment(AppModel.self) private var model
    let itemID: UUID
    let view: BrowserViewItem
    let botID: UUID
    @State private var hasLastScreen = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ToolCall.Kind.browser.symbol)
                .font(Typography.small)
                .foregroundStyle(Palette.faint)
                .frame(width: 22, height: 22)
                .background(Palette.raised, in: .rect(cornerRadius: 6))
                .accessibilityHidden(true)
            Text(LiveScreenText.closingLine(view))
                .font(Typography.label)
                .foregroundStyle(Palette.faint)
                .lineLimit(1)
                .truncationMode(.middle)
            if hasLastScreen {
                Button("Ver última tela") { showLastScreen() }
                    .buttonStyle(.plain)
                    .font(Typography.label)
                    .foregroundStyle(Palette.accentText)
                    .clickablePointer()
                    .help(Tip.lastScreen)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, gutter)
        .onAppear { hasLastScreen = model.liveScreens.hasLastScreen(of: itemID) }
    }

    private func showLastScreen() {
        LiveScreenFocus.shared.show(itemID: itemID, host: view.host, endedAt: view.endedAt, of: botID)
        model.setInspector(true)
        model.request(.showTab(.screen), of: botID)
    }
}

// MARK: - The panel's tab

/// Which finished use's last page the panel's "Tela" tab shows instead of the live one (nil: the live one). Only in memory.
@MainActor @Observable
final class LiveScreenFocus {
    static let shared = LiveScreenFocus()

    struct Shown: Equatable {
        var itemID: UUID
        var host: String
        var endedAt: Date?
    }

    private(set) var shown: [UUID: Shown] = [:]

    func show(itemID: UUID, host: String, endedAt: Date?, of botID: UUID) {
        shown[botID] = Shown(itemID: itemID, host: host, endedAt: endedAt)
    }

    func clear(of botID: UUID) {
        if shown[botID] != nil { shown[botID] = nil }
    }
}

/// The panel's "Tela" tab: the Orb's page, live and larger (or the last page of a use that ended, when asked for).
struct LiveScreenTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let botID: UUID
    @AppStorage(LiveScreenSetting.key) private var showsScreen = true
    @State private var lastImage: NSImage?

    var body: some View {
        let focus = LiveScreenFocus.shared.shown[botID]
        Section {
            VStack(alignment: .leading, spacing: 10) {
                if !showsScreen {
                    // Off in Settings: as before the live screen, nothing is opened.
                    placeholder("A tela do navegador está desligada em Ajustes → Navegador")
                        .aspectRatio(1.6, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                } else if let focus {
                    lastScreen(focus)
                } else {
                    liveScreen()
                }
            }
            .padding(.vertical, 2)
        } footer: {
            FormFootnote { Text("Só você vê esta tela. Nada é gravado nem vai para o modelo.") }
        }
        .task(id: focus?.itemID) {
            lastImage = focus.flatMap { model.liveScreens.lastScreen(of: $0.itemID) }.flatMap { NSImage(data: $0) }
        }
    }

    // MARK: Live

    private func liveScreen() -> some View {
        let live = model.live(botID)
        let store = model.liveScreens.store(botID)
        let handoff = model.pendingHandoff(of: botID)
        let state = LiveCardState.of(outcome: .running, phase: store.phase, isProtected: store.isProtected,
                                     isPrivate: store.isPrivate, handoff: handoff != nil)
        let host = LiveScreenText.host(of: store.url)
        let isIdle = store.phase == .idle && state != .needsYou && state != .protected
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let chip = isIdle ? nil : state.chip {
                    HStack(spacing: 5) {
                        if state.pulses {
                            BreathingDot(color: Palette.ok, breathes: !reduceMotion).frame(width: 6, height: 6).accessibilityHidden(true)
                        }
                        Text(chip).font(.system(size: 11, weight: .semibold))
                    }
                    // The state and the button keep their words whole at 244 pt ("Conectan / do"); the host is what gets cut.
                    .fixedSize()
                    .foregroundStyle(state == .needsYou ? Palette.warn : state.pulses ? Palette.ok : Palette.faint)
                }
                if let host { Text(host).font(Typography.small).foregroundStyle(Palette.faint).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 0)
                if state == .live || state == .connecting {
                    Button("Ocultar tela") { store.isPrivate = true }
                        .buttonStyle(GhostStyle()).controlSize(.small).fixedSize().hangsOnTrailingEdge().help(Tip.hideScreen)
                } else if state == .privateView {
                    Button("Mostrar tela") { store.isPrivate = false }
                        .buttonStyle(SecondaryPillStyle()).controlSize(.small).fixedSize().help(Tip.revealScreen)
                }
            }
            .motion(Motion.content, value: state)
            ZStack {
                Palette.raised
                LiveScreenSurface(hub: model.liveScreens, botID: botID, wide: true, showsPage: state.showsFrames,
                                  isBlurred: state.veil == .blur, isDimmed: state.dimsPage, showsPointer: state.showsPointer,
                                  pointerColor: live.look.orb.pointerColor)
                if state.veil != .none {
                    LiveScreenVeil(veil: state.veil, text: LiveScreenText.veilText(for: state, handoffPage: handoff?.command))
                        .transition(.opacity)
                } else if isIdle {
                    placeholder("O Orb não está usando o navegador agora")
                }
            }
            .aspectRatio(1.6, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Palette.line))
            .motion(Motion.content, value: state.veil)
            .accessibilityLabel(LiveScreenText.spoken(caption: live.shownWork?.headline ?? "sem atividade"))
            if state == .needsYou {
                Text(LiveScreenText.handoffCaption(page: handoff?.command ?? ""))
                    .font(Typography.label).foregroundStyle(Palette.secondary)
            }
        }
    }

    // MARK: A finished use's last page

    private func lastScreen(_ focus: LiveScreenFocus.Shown) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("Última tela")
                    if let end = focus.endedAt { Text("·"); Text(end, format: .dateTime.hour().minute()) }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.faint)
                if !focus.host.isEmpty {
                    Text(focus.host).font(Typography.small).foregroundStyle(Palette.faint).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Button("Ao vivo") { LiveScreenFocus.shared.clear(of: botID) }
                    .buttonStyle(SecondaryPillStyle()).controlSize(.small).help(Tip.backToLiveScreen)
            }
            ZStack {
                Palette.raised
                if model.liveScreens.store(botID).isPrivate {
                    // "Privado" hides every picture of the Orb's page, this one too.
                    LiveScreenVeil(veil: .blur, text: LiveScreenText.veilText(for: .privateView, handoffPage: nil))
                } else if let lastImage {
                    Image(nsImage: lastImage).resizable().scaledToFill()
                } else {
                    placeholder("Esta tela não está mais na memória")
                }
            }
            .aspectRatio(1.6, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Palette.line))
            .accessibilityLabel("Última tela do navegador, \(focus.host)")
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: ToolCall.Kind.browser.symbol).font(.system(size: 18))
            Text(text).font(Typography.label).multilineTextAlignment(.center)
        }
        .foregroundStyle(Palette.faint)
        .padding(12)
    }
}

// MARK: - Helpers

extension OrbConfig {
    /// The Orb's own color, for the dot of its pointer on the page.
    var pointerColor: NSColor { NSColor(hex: OrbCatalog.shared.palette(color).hexes[1]) }
}
