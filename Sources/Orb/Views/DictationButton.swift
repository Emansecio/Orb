import SwiftUI

/// The composer's microphone, beside Send: a click opens it (the words land in the field as they are said), another
/// click closes it, ↩ closes it and sends. While it listens it turns red, with a halo that breathes with your voice.
struct DictationButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: [.starting, .downloading, .finishing, .reviewing].contains(phase))
                .frame(width: 28, height: 28)
                .background { Circle().fill(isOn ? Palette.danger : .clear) }
                .background {
                    // The halo: grows with how loud the microphone is (not under Reduce Motion, where it holds still).
                    Circle()
                        .fill(Palette.danger.opacity(0.28))
                        .scaleEffect(phase == .listening && !reduceMotion ? 1 + CGFloat(dictation.level) * 0.4 : 1)
                        .opacity(phase == .listening ? 1 : 0)
                        // Glides between the readings (about ten a second) instead of stepping.
                        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: dictation.level)
                }
                .contentShape(.circle)
        }
        .buttonStyle(MicStyle(isOn: isOn))
        .padding(.horizontal, 3) // room for the halo before Send
        .animation(Motion.adapted(Motion.content, reduceMotion: reduceMotion), value: isOn)
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
