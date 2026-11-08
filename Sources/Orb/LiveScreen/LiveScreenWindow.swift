import AppKit
import SwiftUI

/// The Orb's browser in a window of its own (docs/TELA-AO-VIVO.md, 7): the page live and large, opened from the card
/// ("Ampliar" or a click on the thumbnail). A click on the page, or "Assumir", hands the browser to the person: their clicks,
/// the wheel and the keys go to the page through the stream (the page does not reload), the Orb's browser tools wait, and
/// "Devolver ao Orb" (or closing the window) gives it back. Only the person sees this window; nothing of it is kept or sent.
struct LiveScreenWindow: View {
    static let id = "browser-screen"

    /// Opens the window of this Orb's browser, or brings it to the front if it is open.
    @MainActor static func open(_ botID: UUID, with openWindow: OpenWindowAction) {
        openWindow(id: id, value: botID)
    }

    @Environment(AppModel.self) private var model
    let botID: UUID
    @State private var isHovering = false

    var body: some View {
        Group {
            if let name = model.bot(botID)?.name {
                content.navigationTitle("Navegador de \(name)")
            } else {
                Text("Este Orb não existe mais").font(Typography.label).foregroundStyle(Palette.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Navegador")
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(Palette.chrome)
        .background(LiveScreenWindowMarker())
        // Closing the window gives the browser back: the Orb never waits on a window nobody can see.
        .onDisappear { model.liveScreens.giveBackControl(botID) }
    }

    private var content: some View {
        let live = model.live(botID)
        let store = model.liveScreens.store(botID)
        let handoff = model.pendingHandoff(of: botID)
        let inControl = store.isUserInControl
        let state = LiveCardState.of(outcome: .running, phase: store.phase, isProtected: store.isProtected,
                                     isPrivate: store.isPrivate, handoff: handoff != nil, userControls: inControl)
        let isIdle = store.phase == .idle && !inControl && state != .needsYou && state != .protected
        let canTake = Self.canTakeOver(state) && !isIdle
        return VStack(spacing: 0) {
            bar(state, handoff: handoff, host: LiveScreenText.host(of: store.url), isIdle: isIdle, canTake: canTake, store: store)
            Rectangle().fill(Palette.line).frame(height: 1)
            page(state, handoff: handoff, inControl: inControl, isIdle: isIdle, canTake: canTake, orb: live.look.orb)
                .padding(Spacing.m)
            footer(state, handoff: handoff, isIdle: isIdle)
        }
        .onChange(of: state) { _, new in
            if let text = LiveScreenText.announcement(for: new) { AccessibilityNotification.Announcement(text).post() }
        }
    }

    /// The person can take the browser over while the page is there to use: live, or protected (they see it once they have it).
    static func canTakeOver(_ state: LiveCardState) -> Bool { state == .live || state == .protected }

    // MARK: Pieces

    private func bar(_ state: LiveCardState, handoff: ApprovalRequest?, host: String?, isIdle: Bool, canTake: Bool,
                     store: LiveFrameStore) -> some View {
        HStack(spacing: Spacing.s) {
            if let chip = isIdle ? nil : state.chip {
                LiveChip(chip: chip, state: state).fixedSize()
            }
            if let host {
                Text(host).font(Typography.small).foregroundStyle(Palette.faint).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Spacing.s)
            switch state {
            case .youControl:
                Button("Devolver ao Orb") { model.liveScreens.giveBackControl(botID) }
                    .buttonStyle(PrimaryPillStyle()).help(Tip.giveBackBrowser)
            case .needsYou:
                if let handoff {
                    Button("Cancelar") { model.decide(.deny, approvalID: handoff.id, botID: botID) }
                        .buttonStyle(GhostStyle()).help(Tip.handoffCancel)
                    Button("Terminei") { model.decide(.once, approvalID: handoff.id, botID: botID) }
                        .buttonStyle(PrimaryPillStyle()).help(Tip.handoffDone)
                }
            case .failed where store.isUserInControl:
                Button("Devolver ao Orb") { model.liveScreens.giveBackControl(botID) }
                    .buttonStyle(PrimaryPillStyle()).help(Tip.giveBackBrowser)
            case .privateView:
                Button("Mostrar tela") { store.isPrivate = false }.buttonStyle(SecondaryPillStyle()).help(Tip.revealScreen)
            default:
                if model.canStop(botID) {
                    Button("Parar Orb") { model.stop(botID) }.buttonStyle(SecondaryPillStyle()).help(Tip.stopBrowsing)
                }
                if canTake {
                    Button("Assumir") { takeOver() }.buttonStyle(PrimaryPillStyle()).help(Tip.takeOverBrowser)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.m)
        .frame(height: 44)
    }

    private func page(_ state: LiveCardState, handoff: ApprovalRequest?, inControl: Bool, isIdle: Bool, canTake: Bool,
                      orb: OrbConfig) -> some View {
        ZStack {
            Palette.canvas
            // In the person's hands the page shows whatever it is (they need to see a login to type in it); otherwise as the card.
            LiveScreenSurface(hub: model.liveScreens, botID: botID, wide: true, fits: true, isInteractive: inControl,
                              showsPage: inControl || state.showsFrames, isBlurred: state.veil == .blur,
                              isDimmed: state.dimsPage, showsPointer: state.showsPointer, pointerColor: orb.pointerColor)
            if !inControl, state.veil != .none {
                veil(state, handoff: handoff).transition(.opacity)
            } else if isIdle {
                note("O Orb não está usando o navegador agora")
            }
            if canTake, isHovering {
                Text("Clique para assumir o controle")
                    .font(Typography.label.weight(.medium))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                    .background(.black.opacity(0.6), in: .capsule)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .clipShape(.rect(cornerRadius: Radius.small))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.small)
                .strokeBorder(inControl ? Palette.accent : Palette.line, lineWidth: inControl ? 1.5 : 1)
        }
        .contentShape(.rect)
        // While the Orb drives, a click on the page takes it over (that click itself is not sent: it could press something).
        .onTapGesture { if canTake { takeOver() } }
        .onHover { hovering in isHovering = hovering }
        .motion(Motion.content, value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(inControl ? "Página do navegador, sob seu controle" : "Página do navegador do Orb")
        .accessibilityAddTraits(canTake ? .isButton : [])
        .accessibilityAction { if canTake { takeOver() } }
    }

    private func veil(_ state: LiveCardState, handoff: ApprovalRequest?) -> some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "lock.fill").font(.system(size: 22))
            Text(state == .protected ? "Página protegida" : LiveScreenText.veilText(for: state, handoffPage: handoff?.command))
                .font(Typography.label)
        }
        .foregroundStyle(state.veil == .opaque ? Palette.muted : Palette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(state.veil == .opaque ? Palette.surface : Palette.surface.opacity(0.35))
    }

    private func note(_ text: String) -> some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: ToolCall.Kind.browser.symbol).font(.system(size: 22))
            Text(text).font(Typography.label).multilineTextAlignment(.center)
        }
        .foregroundStyle(Palette.faint)
        .padding(Spacing.l)
    }

    private func footer(_ state: LiveCardState, handoff: ApprovalRequest?, isIdle: Bool) -> some View {
        let caption = Text(Self.caption(for: state, isIdle: isIdle, handoffPage: handoff?.command))
            .font(Typography.label).foregroundStyle(state == .youControl ? Palette.secondary : Palette.faint)
        let privacy = Text("Só você vê esta tela. Nada é gravado nem vai para o modelo.")
            .font(Typography.small).foregroundStyle(Palette.hint)
        // Side by side when they fit; in a narrow window the privacy line goes under what to do, and neither is cut.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.l) {
                caption.fixedSize()
                Spacer(minLength: 0)
                privacy.fixedSize()
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                caption.fixedSize(horizontal: false, vertical: true)
                privacy.fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.bottom, Spacing.m)
    }

    /// What the window says under the page.
    static func caption(for state: LiveCardState, isIdle: Bool, handoffPage: String?) -> String {
        if isIdle { return "Quando o Orb abrir uma página, ela aparece aqui." }
        switch state {
        case .youControl: return "Você está no controle: cliques, rolagem e teclado vão para a página, e ⌘V cola. O Orb espera você devolver."
        case .live: return "Clique na página para assumir o controle."
        case .protected: return "Página protegida. Assuma o controle para vê-la e usá-la."
        case .needsYou: return LiveScreenText.handoffCaption(page: handoffPage ?? "") + ": termine na janela do navegador e clique em Terminei."
        case .privateView: return "A tela está oculta."
        case .paused: return "Pausado: outro Orb está na tela."
        case .connecting: return "Conectando ao navegador do Orb…"
        case .failed: return "O navegador do Orb fechou."
        case .ended: return ""
        }
    }

    private func takeOver() {
        withAnimation(Motion.content) { model.liveScreens.takeControl(botID) }
    }
}

/// Marks the window it is in as a browser window, so what brings "the app's window" forward (a banner's tap) picks the main one.
private struct LiveScreenWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ view: MarkerView, context: Context) {}

    final class MarkerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { LiveScreenWindow.windows.add(window) }
        }
    }
}

extension LiveScreenWindow {
    /// The browser windows open now (weak: a closed one leaves by itself).
    @MainActor static let windows = NSHashTable<NSWindow>.weakObjects()
}
