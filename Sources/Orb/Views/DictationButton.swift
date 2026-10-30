import SwiftUI

/// The composer's microphone, beside Send: a click opens it (the words land in the field as they are said), another
/// click closes it, ↩ closes it and sends. While it listens it turns red, with a halo that breathes with your voice.
struct DictationButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    let botID: UUID

    var body: some View {
        let dictation = model.dictation
        let phase = dictation.isActive(for: botID) ? dictation.phase : .idle
        let isOn = phase != .idle
        Button {
            model.toggleDictation(botID)
        } label: {
            Image(systemName: Self.symbol(phase))
                .font(.system(size: 13, weight: isOn ? .bold : .regular))
                .foregroundStyle(isOn ? Palette.onInk : Palette.muted)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating,
                              isActive: appearsActive && !reduceMotion && [.starting, .downloading, .finishing, .reviewing].contains(phase))
                .frame(width: 28, height: 28)
                .background { Circle().fill(isOn ? Palette.danger : .clear) }
                .background { DictationHalo(listening: phase == .listening) }
                .contentShape(.circle)
        }
        .buttonStyle(MicStyle(isOn: isOn))
        .padding(.horizontal, 3) // room for the halo before Send
        .motion(value: isOn)
        .animation(Motion.fade, value: phase)
        .help(Self.help(phase))
        .accessibilityLabel(isOn ? "Parar de ditar" : "Ditar")
        .accessibilityValue(Self.hintText(phase) ?? "")
    }

    static func symbol(_ phase: Dictation.Phase) -> String {
        switch phase {
        case .idle, .starting: "mic"
        case .downloading: "arrow.down.circle"
        case .listening: "mic.fill"
        case .finishing: "ellipsis"
        case .reviewing: "sparkles"
        }
    }

    static func help(_ phase: Dictation.Phase) -> String {
        phase == .idle ? "Ditar: fale e o texto aparece no campo (clique de novo para parar, ↩ envia)" : "Parar de ditar (o texto fica no campo)"
    }

    static func hintText(_ phase: Dictation.Phase) -> String? {
        switch phase {
        case .idle: nil
        case .starting: "Abrindo o microfone…"
        case .downloading: "Baixando o reconhecimento de fala do Mac (só desta vez)…"
        case .listening: "Ouvindo… ↩ envia · Esc encerra"
        case .finishing: "Terminando de transcrever…"
        case .reviewing: "Ajustando o texto com o modelo… · Esc mantém como foi ditado"
        }
    }

    /// The line under the composer while `botID` dictates.
    @MainActor static func hint(_ dictation: Dictation, botID: UUID) -> String? {
        dictation.isActive(for: botID) ? hintText(dictation.phase) : nil
    }
}

/// The halo behind the microphone: grows with how loud the microphone is (not under Reduce Motion, where it holds still).
/// A view of its own because it is the only one that reads the level, which changes ten to twelve times a second while
/// dictating: read in the button's body, every reading would redraw the whole button.
private struct DictationHalo: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    let listening: Bool

    var body: some View {
        // Only read while listening, so the readings after it do not redraw a halo that is not shown.
        // A still halo must not subscribe to microphone levels just to redraw the same circle 12 times a second.
        let animates = listening && !reduceMotion && appearsActive
        let level = animates ? model.dictation.level : 0
        Circle()
            .fill(Palette.danger.opacity(0.28))
            .scaleEffect(animates ? 1 + CGFloat(level) * 0.4 : 1)
            .opacity(listening ? 1 : 0)
            // Glides between the readings instead of stepping.
            .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: level)
    }
}

/// Hover fill when off, the composer's press feel either way.
private struct MicStyle: ButtonStyle {
    let isOn: Bool
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let press = ComposerAction.pressVisual(pressed: configuration.isPressed, reduceMotion: reduceMotion)
        configuration.label
            .hoverFill(!isOn && (configuration.isPressed || isHovering), pressed: configuration.isPressed, in: .circle,
                       color: Palette.ghostSelected)
            .scaleEffect(press.scale)
            .opacity(press.opacity)
            .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }
}
