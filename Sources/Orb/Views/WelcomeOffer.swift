import SwiftUI

// The welcome screen with no model when one path is already ready to use (Claude Code logged in): instead of a card with
// three paths, one big button that connects it and makes the Atlas, landing in its chat. The other paths stay one
// click away under "Outras formas de conectar". docs/MOVIMENTO.md §2.11, §2.13.

/// The one big button, the line under it and the quiet way to the other paths.
struct WelcomeOfferView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let offer: FirstRunOffer
    let run: FirstRunModel
    /// The Atlas was made by the click.
    var onStarted: () -> Void = {}
    @State private var showsOthers = false

    /// Connecting, or connected and the Atlas not made yet.
    private var isBusy: Bool { run.working == .claudeCode || run.isStarting }

    private var failure: String? {
        run.failure.flatMap { $0.choice == .claudeCode ? $0.message : nil }
    }

    var body: some View {
        VStack(spacing: 14) {
            if let name = run.connectedName {
                Label("Pronto: \(name) conectado.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ok)
                    .padding(.vertical, 6)
                    .transition(.opacity)
            } else {
                mainAction
                othersToggle
                if showsOthers {
                    FirstRunCard(style: .welcome, run: run, detectsOnAppear: false, asAlternatives: true)
                        .transition(.adapted(.unfold, reduceMotion: reduceMotion))
                }
            }
        }
        .animateChanges(of: run.connectedName)
        .accessibilityElement(children: .contain)
    }

    private var mainAction: some View {
        VStack(spacing: 10) {
            Button(action: start) {
                Text(offer.buttonTitle)
            }
            .buttonStyle(HeroPillStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy)
            .opacity(isBusy ? 0.6 : 1)
            .help(offer.createsAtlas ? Tip.startWithClaudeCode : Tip.useClaudeCode)
            .accessibilityHint(offer.accessibilityHint)
            statusLine
        }
        .animateChanges(of: StatusPhase(busy: isBusy, failure: failure))
    }

    /// Under the button: what is happening, why it failed, or the one sentence of what the click does.
    @ViewBuilder private var statusLine: some View {
        if isBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(offer.workingTitle)
                    .font(Typography.label)
                    .foregroundStyle(Palette.secondary)
                if run.working == .claudeCode {
                    Button("Cancelar", action: run.cancel)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.accentText)
                        .help(Tip.stopConnecting)
                }
            }
        } else if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(Typography.label)
                .foregroundStyle(Palette.danger)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
        } else {
            Text(offer.detail)
                .font(Typography.label)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
        }
    }

    private var othersToggle: some View {
        Button {
            withAnimation(Motion.panel(reduceMotion: reduceMotion)) { showsOthers.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text(FirstRunOffer.othersTitle)
                Image(systemName: showsOthers ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(Typography.label)
            .foregroundStyle(Palette.secondary)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Tip.otherWaysToConnect(isShowing: showsOthers))
        .accessibilityValue(showsOthers ? "Aberto" : "Fechado")
    }

    private func start() {
        if offer.createsAtlas {
            Task {
                if await run.connectClaudeCodeAndStart(model: model).value { onStarted() }
            }
        } else {
            run.connectClaudeCode(model: model)
        }
    }

    /// What the line under the button depends on, as one value (its swaps animate with it).
    private struct StatusPhase: Equatable {
        var busy: Bool
        var failure: String?
    }
}

/// Above the connect card when something other than an empty list brought the screen up (a routine with no model).
struct WelcomeReasonNote: View {
    let reason: WelcomeReason

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(Typography.label)
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            Text(reason.message)
                .font(Typography.label)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Color.white.opacity(0.04), in: .rect(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Palette.line))
        .accessibilityElement(children: .combine)
        .onAppear { AccessibilityNotification.Announcement(reason.message).post() }
    }
}
