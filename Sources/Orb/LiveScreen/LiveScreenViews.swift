import SwiftUI

// The live screen's interface (docs/TELA-AO-VIVO.md, 3): the card in the chat while the turn uses the browser, the line it
// leaves after, and the panel's "Tela" tab. What changes rarely (the state, the host, the caption) is read here; what
// changes up to sixty times a second (the picture, the pointer) is drawn by `LiveScreenLayerView` and never reaches a body.

/// The chat's row for one use of the Orb's browser: the live card while the turn uses it, the closing line after.
struct LiveScreenRow: View {
    let itemID: UUID
    let view: BrowserViewItem
    let botID: UUID

    var body: some View {
        ZStack(alignment: .topLeading) {
            if view.outcome == .running {
                LiveScreenCard(view: view, botID: botID).transition(.opacity)
            } else {
                LiveScreenClosedLine(itemID: itemID, view: view, botID: botID).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(Motion.content, value: view.outcome == .running)
    }
}

/// The state's word, with a breathing dot while the page is live: the same chip on the card and on the tab.
struct LiveChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let chip: String
    let state: LiveCardState

    var body: some View {
        HStack(spacing: 5) {
            if state.pulses {
                BreathingDot(color: Palette.ok, breathes: !reduceMotion).frame(width: 6, height: 6).accessibilityHidden(true)
            } else if state == .connecting {
                // "Conectando" is work in progress: a gray breathing dot says so, where the word alone looked stalled.
                BreathingDot(color: Palette.faint, breathes: !reduceMotion).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Text(chip).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(state == .needsYou ? Palette.warn : state == .youControl ? Palette.accentText
                         : state.pulses ? Palette.ok : Palette.faint)
    }
}

// MARK: - The card

/// The Orb's browser in the chat, as a small browser window: a bar with what it is (state and site), the page live and large
/// with the Orb's pointer on it, and under it what the Orb does and what the person can do about it. The person takes the
/// browser over right here ("Assumir"): the page then takes their clicks, wheel and keys. The page keeps its pictures' shape
/// (`LiveFrameStore.pageAspect`), so the card's height only changes with the column's width.
private struct LiveScreenCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let view: BrowserViewItem
    let botID: UUID

    /// The tallest the page is drawn: a page of the usual shape fills the width of the chat's other cards (`cardWidth`),
    /// and one nearer a square makes the card narrower instead of taller.
    static let maxPageHeight = cardWidth / LiveFrameStore.defaultAspect
    /// How tall the page's place is while it shows nothing (a login the person must not see through the Orb): a lock and
    /// a word do not need the room of a page, and what the person has to do is in the bar below.
    static let coveredHeight: CGFloat = 132

    var body: some View {
        let live = model.live(botID)
        let store = model.liveScreens.store(botID)
        // The Orb waits for a hand-off: the card answers it, in the place of the permission card (see `TranscriptRow`).
        let handoff = model.pendingHandoff(of: botID)
        let state = LiveCardState.of(outcome: view.outcome, phase: store.phase, isProtected: store.isProtected,
                                     isPrivate: store.isPrivate, handoff: handoff != nil, userControls: store.isUserInControl)
        let work = live.shownWork
        let host = LiveScreenText.host(of: store.url) ?? (view.host.isEmpty ? nil : view.host)
        let caption = LiveScreenText.caption(for: state, work: work?.headline, handoffPage: handoff?.command,
                                             lastAction: work?.headline.trimmingCharacters(in: CharacterSet(charactersIn: "…")))
        VStack(spacing: 0) {
            topBar(state, host: host, store: store)
            Rectangle().fill(Palette.line).frame(height: 1)
            page(state, handoff: handoff, orb: live.look.orb, aspect: store.pageAspect)
            Rectangle().fill(Palette.line).frame(height: 1)
            bottomBar(state, caption: caption, handoff: handoff)
        }
        .card(radius: Radius.card)
        // No taller than `maxPageHeight`: never the chat's whole height.
        .frame(maxWidth: Self.maxPageHeight * store.pageAspect, alignment: .leading)
        .overlay {
            // "Precisa de você" comes in once, with emphasis, and stays still: no pulse, no sound. In the person's hands the
            // card is outlined as the window's page is.
            if state == .needsYou {
                RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.warn.opacity(0.4), lineWidth: 1)
                    .entrance(EntranceStyle(distance: 0, scale: 0.97, animation: Motion.emphasis))
                    .allowsHitTesting(false)
            } else if state == .youControl {
                RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.accent, lineWidth: 1.5)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .motion(Motion.content, value: state)
        .chatCard()
        // ⌘↩ finishes the hand-off and Esc cancels it, as on the permission card this one stands for. No button is drawn
        // pressed here, so the answer is immediate.
        .approvalKeys(botID: botID, approvalID: handoff?.id, isActive: state == .needsYou) { shortcut in
            guard let handoff else { return }
            switch shortcut {
            case .allow: model.decide(.once, approvalID: handoff.id, botID: botID)
            case .deny: model.decide(.deny, approvalID: handoff.id, botID: botID)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LiveScreenText.spoken(caption: caption))
        .onChange(of: state) { _, new in
            if let text = LiveScreenText.announcement(for: new) { AccessibilityNotification.Announcement(text).post() }
        }
    }

    // MARK: Pieces

    /// What it is: the state's chip and the site. On the right, what changes how it is seen (hide it, see it larger).
    private func topBar(_ state: LiveCardState, host: String?, store: LiveFrameStore) -> some View {
        HStack(spacing: Spacing.s) {
            if let chip = state.chip {
                LiveChip(chip: chip, state: state).fixedSize()
            }
            if let host {
                // The site gives way first: the state and the buttons keep their words whole.
                Text(host).font(Typography.small).foregroundStyle(Palette.faint).lineLimit(1).truncationMode(.middle)
                    .help(host).layoutPriority(-1)
            }
            Spacer(minLength: Spacing.s)
            if state.buttons.contains(.hide) {
                Button("Ocultar tela") { store.isPrivate = true }.buttonStyle(GhostStyle()).help(Tip.hideScreen)
            }
            if state.buttons.contains(.reveal) {
                // The same quiet words as "Ocultar tela", whose place it takes.
                Button("Mostrar tela") { store.isPrivate = false }.buttonStyle(GhostStyle()).hangsOnTrailingEdge().help(Tip.revealScreen)
            }
            if state.buttons.contains(.enlarge) {
                Button("Ampliar") { enlarge() }.buttonStyle(GhostStyle()).hangsOnTrailingEdge().help(Tip.enlargeScreen)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.m)
        .frame(height: 36)
    }

    private func page(_ state: LiveCardState, handoff: ApprovalRequest?, orb: OrbConfig, aspect: CGFloat) -> some View {
        let inControl = state == .youControl
        let isCovered = !inControl && state.veil == .opaque
        // One place whose height changes, not two branches: the page's view (and its stream) stays the same through it.
        return PagePlace(aspect: aspect, height: isCovered ? Self.coveredHeight : nil) {
          ZStack {
            Palette.raised
            // In the person's hands the page shows whatever it is (they need to see a login to type in it), as in the window.
            LiveScreenSurface(hub: model.liveScreens, botID: botID, wide: true, fits: true, isInteractive: inControl,
                              showsPage: inControl || state.showsFrames, isBlurred: state.veil == .blur,
                              isDimmed: state.dimsPage, showsPointer: state.showsPointer, pointerColor: orb.pointerColor)
            if !inControl, state.veil != .none {
                LiveScreenVeil(veil: state.veil, text: LiveScreenText.veilText(for: state, handoffPage: handoff?.command))
                    .transition(.opacity)
            }
          }
        }
        .motion(Motion.content, value: state.veil)
        .motion(Motion.content, value: aspect)
        .contentShape(.rect)
        // A click on the page the Orb drives opens it larger; taking it over is a button, so a stray click never stops the Orb.
        .onTapGesture { if state.enlarges, !inControl { enlarge() } }
        .help(state.enlarges && !inControl ? Tip.enlargeScreen : "")
        .accessibilityHidden(true)
    }

    /// What the Orb does (or what the person has to do) and, beside it, what they can do. A column too narrow for both on one
    /// line cuts the caption (its `help` has it whole), except a hand-off's, which says what to do: that one goes above the buttons.
    private func bottomBar(_ state: LiveCardState, caption: String, handoff: ApprovalRequest?) -> some View {
        let kinds = state.buttons.filter { !$0.isOnTopBar }
        let showsKeys = handoff.map { model.showsApprovalKeys($0.id, of: botID) } ?? false
        let text = Text(caption).font(Typography.label).foregroundStyle(Palette.secondary)
        @ViewBuilder func actions(short: Bool) -> some View {
            HStack(spacing: Spacing.xs) {
                ForEach(kinds, id: \.self) { button($0, handoff: handoff, showsKeys: showsKeys, short: short) }
            }
            .fixedSize()
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.m) {
                text.lineLimit(1).fixedSize()
                Spacer(minLength: 0)
                actions(short: false)
            }
            if state == .needsYou {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    text.fixedSize(horizontal: false, vertical: true)
                    // At the card's edge, where the wide card has them.
                    actions(short: false).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: Spacing.m) {
                    text.lineLimit(1).truncationMode(.tail).help(caption)
                    Spacer(minLength: 0)
                    actions(short: true)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(minHeight: 40)
    }

    @ViewBuilder private func button(_ kind: LiveCardState.Button, handoff: ApprovalRequest?, showsKeys: Bool, short: Bool) -> some View {
        switch kind {
        case .enlarge, .hide, .reveal:
            // On the top bar.
            EmptyView()
        case .stop:
            // Stops the whole Orb (its chains with other Orbs too), not just the turn as the composer's Stop does.
            StopOrbButton(botID: botID, short: short)
        case .takeOver:
            Button("Assumir") { withAnimation(Motion.content) { model.liveScreens.takeControl(botID, fromChat: true) } }
                .buttonStyle(SecondaryPillStyle()).help(Tip.takeOverBrowser)
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
        case .giveBack:
            Button(short ? "Devolver" : "Devolver ao Orb") { withAnimation(Motion.content) { model.liveScreens.giveBackControl(botID) } }
                .buttonStyle(PrimaryPillStyle()).help(Tip.giveBackBrowser)
                .accessibilityLabel("Devolver ao Orb")
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

    /// Opens the Orb's browser in a window of its own, live and larger still.
    private func enlarge() {
        LiveScreenWindow.open(botID, with: openWindow)
    }
}

/// The place of the card's page: as wide as it is given, and as tall as the page's shape makes that width, or `height`
/// when the page is covered.
private struct PagePlace: Layout {
    var aspect: CGFloat
    var height: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? cardWidth
        return CGSize(width: width, height: height ?? width / max(aspect, 0.1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

/// "Parar Orb" on the card and on the tab: red text and a stop sign, so it is not read as one more of the neutral pills beside
/// it. It stops the whole Orb (its chains with other Orbs too), not just the turn as the composer's Stop does.
private struct StopOrbButton: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    var short = false

    var body: some View {
        Button { model.stop(botID) } label: {
            Label(short ? "Parar" : "Parar Orb", systemImage: "stop.fill")
        }
        .buttonStyle(GhostStyle(tint: Palette.danger))
        .help(Tip.stopBrowsing)
        .accessibilityLabel("Parar Orb")
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
            // The mark of a finished action (`ToolCallLine`), so the line sits in the column of the ones around it.
            Image(systemName: ToolCall.Kind.browser.symbol)
                .font(Typography.small)
                .foregroundStyle(Palette.muted)
                .frame(width: 14)
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
    @Environment(\.openWindow) private var openWindow
    let botID: UUID
    @AppStorage(LiveScreenSetting.key) private var showsScreen = true
    @State private var lastImage: NSImage?

    var body: some View {
        let focus = LiveScreenFocus.shared.shown[botID]
        PanelSection {
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
            lastImage = nil
            guard let jpeg = focus.flatMap({ model.liveScreens.lastScreen(of: $0.itemID) }) else { return }
            let image = await Task.detached(priority: .userInitiated) { LiveJPEG.image(from: jpeg) }.value
            guard !Task.isCancelled else { return }
            lastImage = image.map { NSImage(cgImage: $0, size: .zero) }
        }
    }

    // MARK: Live

    private func liveScreen() -> some View {
        let live = model.live(botID)
        let store = model.liveScreens.store(botID)
        let handoff = model.pendingHandoff(of: botID)
        let state = LiveCardState.of(outcome: .running, phase: store.phase, isProtected: store.isProtected,
                                     isPrivate: store.isPrivate, handoff: handoff != nil, userControls: store.isUserInControl)
        let host = LiveScreenText.host(of: store.url)
        let isIdle = store.phase == .idle && state != .needsYou && state != .protected
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let chip = isIdle ? nil : state.chip {
                    // The state keeps its word whole at 244 pt ("Conectan / do"), as the pills do; the host is what gets cut.
                    LiveChip(chip: chip, state: state).fixedSize()
                }
                if let host { Text(host).font(Typography.small).foregroundStyle(Palette.faint).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 0)
                if state == .live || state == .connecting {
                    Button("Ocultar tela") { store.isPrivate = true }
                        .buttonStyle(GhostStyle()).controlSize(.small).hangsOnTrailingEdge().help(Tip.hideScreen)
                } else if state == .privateView {
                    Button("Mostrar tela") { store.isPrivate = false }
                        .buttonStyle(GhostStyle()).controlSize(.small).hangsOnTrailingEdge().help(Tip.revealScreen)
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
                    placeholder("O Orb não está usando o navegador agora. Peça uma tarefa na web e a página aparece aqui.")
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
            // The card's actions (Ampliar, Parar Orb), so the tab is not a thumbnail with nothing to do about it.
            if !isIdle, state.buttons.contains(.enlarge) || state.buttons.contains(.stop) {
                HStack(spacing: Spacing.xs) {
                    if state.buttons.contains(.enlarge) {
                        Button("Ampliar") { LiveScreenWindow.open(botID, with: openWindow) }
                            .buttonStyle(SecondaryPillStyle()).help(Tip.enlargeScreen)
                    }
                    Spacer(minLength: Spacing.s)
                    if state.buttons.contains(.stop) { StopOrbButton(botID: botID).hangsOnTrailingEdge() }
                }
                .controlSize(.small)
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
