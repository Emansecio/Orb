import SwiftUI

/// The card of `request_access`: what the Orb needs to go on (switches, "Automático", a folder) and why, with "Liberar" (⌘↩), which
/// turns it all on in one click, and "Agora não" (Esc). Answered, it shrinks to one line with the outcome and stays in view.
struct AccessCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let request: ApprovalRequest
    let access: AccessRequest
    let botID: UUID

    /// The card arrived while the chat was open: its border pulses once (as an approval card's does).
    @State private var pulsesOnArrival: Bool
    @State private var pulse = 0
    @State private var pressed: ApprovalShortcut?

    init(request: ApprovalRequest, access: AccessRequest, botID: UUID, pulses: Bool = false) {
        self.request = request
        self.access = access
        self.botID = botID
        _pulsesOnArrival = State(initialValue: pulses)
    }

    private var isPending: Bool { request.decision == nil }
    private var wasGranted: Bool { request.decision != nil && request.decision != .deny }
    private var showsKeys: Bool { model.showsApprovalKeys(request.id, of: botID) }
    private var orbName: String { model.live(botID).look.name.isEmpty ? "O Orb" : model.live(botID).look.name }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isPending {
                pendingCard.transition(.adapted(.cardLeaving, reduceMotion: reduceMotion))
            } else {
                answeredCard.transition(.opacity)
            }
        }
        .chatCard()
        .motion(Motion.content, value: request.decision)
        .approvalKeys(botID: botID, approvalID: request.id, isActive: isPending, noteFocused: false, pressed: $pressed, answer: answer)
        .accessibilityIdentifier("orb-access-card")
    }

    // MARK: Pending

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "key")
                    .font(Typography.label)
                    .foregroundStyle(Palette.accentText)
                    .accessibilityHidden(true)
                Text("\(orbName) precisa de acesso")
                    .font(Typography.label.weight(.medium))
                    .foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(AccessLines.lines(for: access), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(Typography.small)
                            .foregroundStyle(Palette.secondary)
                            .accessibilityHidden(true)
                        Text(line)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !access.reason.isEmpty {
                Text(access.reason)
                    .font(Typography.text)
                    .foregroundStyle(Palette.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ActionRow {
                Button(action: decline) {
                    HStack(spacing: 6) {
                        Text("Agora não")
                        if showsKeys { Text("esc").font(Typography.small).foregroundStyle(Palette.muted) }
                    }
                }
                .buttonStyle(GhostStyle())
                .background(pressed == .deny ? Palette.ghostSelected : .clear, in: .capsule)
                .scaleEffect(pressed == .deny ? ApprovalShortcut.pressScale : 1)
                .animation(Motion.press, value: pressed)
                .help(ApprovalHints.help(Tip.declineAccess, key: "Esc", showsKeys: showsKeys))
                .accessibilityLabel("Agora não")
                .accessibilityHint(ApprovalHints.accessibilityHint("Esc", showsKeys: showsKeys))
                .hangsOnLeadingEdge()
            } trailing: {
                Button(action: grant) {
                    HStack(spacing: 7) {
                        Text("Liberar")
                        if showsKeys { Text(AppShortcut.commandReturn.label).font(Typography.small).opacity(0.55) }
                    }
                }
                .buttonStyle(PrimaryPillStyle())
                .opacity(pressed == .allow ? 0.85 : 1)
                .scaleEffect(pressed == .allow ? ApprovalShortcut.pressScale : 1)
                .animation(Motion.press, value: pressed)
                .help(ApprovalHints.help(Tip.grantAccess, key: AppShortcut.commandReturn.label, showsKeys: showsKeys))
                .accessibilityLabel("Liberar")
                .accessibilityHint(ApprovalHints.accessibilityHint(AppShortcut.commandReturn.label, showsKeys: showsKeys))
            }
        }
        .padding(14)
        .card(radius: Radius.card, stroke: Palette.lineStrong)
        .overlay {
            if ApprovalPulse.pulses(isNew: pulsesOnArrival, reduceMotion: reduceMotion) {
                ApprovalPulseBorder(radius: Radius.card, trigger: pulse)
            }
        }
        .onAppear { if pulsesOnArrival { pulse += 1 } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AccessLines.pending(botName: orbName, access: access))
    }

    // MARK: Answered

    private var answeredCard: some View {
        let summary = AccessLines.answered(access, granted: wasGranted)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: wasGranted ? "checkmark.circle.fill" : "xmark.circle")
                .font(Typography.small)
                .foregroundStyle(wasGranted ? Palette.ok : Palette.danger)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(summary)
                .font(Typography.label)
                .foregroundStyle(wasGranted ? Palette.secondary : Palette.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary)
    }

    // MARK: Answers

    private func grant() {
        guard isPending else { return }
        model.decide(.once, approvalID: request.id, botID: botID)
    }

    private func decline() {
        guard isPending else { return }
        model.decide(.deny, approvalID: request.id, botID: botID)
    }

    private func answer(_ shortcut: ApprovalShortcut) {
        switch shortcut {
        case .allow: grant()
        case .deny: decline()
        }
    }
}

/// The words of the access card, and what VoiceOver reads.
enum AccessLines {
    /// One line per thing asked: "Terminal e arquivos", "Modo Automático", "Pasta ~/Projetos/Y".
    static func lines(for access: AccessRequest, home: String = NSHomeDirectory()) -> [String] {
        access.capabilities.map(\.label)
            + (access.autoMode ? ["Modo Automático"] : [])
            + (access.folder.isEmpty ? [] : ["Pasta \(shortPath(access.folder, home: home))"])
    }

    /// The path with the home folder as "~".
    static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func pending(botName: String, access: AccessRequest) -> String {
        "\(botName) precisa de acesso: \(lines(for: access).joined(separator: "; ")). \(access.reason)"
    }

    static func answered(_ access: AccessRequest, granted: Bool) -> String {
        (granted ? "Liberado: " : "Não liberado: ") + lines(for: access).joined(separator: ", ")
    }
}
