import Foundation

/// Runs osascript (AppleScript or JXA) and turns its failures into advice the model and the user can act on.
enum AppleScript {
    enum Language: String, Sendable {
        case applescript, javascript

        var arguments: [String] { self == .javascript ? ["-l", "JavaScript"] : [] }
    }

    /// `structured` asks osascript for recompilable output (`-s s`): strings are quoted and lists/records keep their
    /// shape, so the model can tell `"1"` from `1`. Throws a `ToolError` whose text already explains the likely fix.
    static func run(_ script: String, language: Language = .applescript, structured: Bool = false,
                    timeout: Duration = .seconds(60), outputLimit: Int = 20_000) async throws -> String {
        let arguments = language.arguments + (structured ? ["-s", "s"] : []) + ["-e", script]
        let result = try await ProcessRunner.run("/usr/bin/osascript", arguments, timeout: timeout, outputLimit: outputLimit)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.timedOut { throw ToolError(timeoutMessage(seconds: Int(timeout.components.seconds))) }
        guard result.status == 0 else { throw ToolError(explain(output, status: result.status)) }
        return output
    }

    static func timeoutMessage(seconds: Int) -> String {
        "O script passou de \(seconds) s e foi interrompido. Ele pode estar esperando você responder a um aviso de "
            + "permissão do macOS (olhe a tela) ou o app alvo pode estar travado."
    }

    /// The Apple Event error number osascript prints at the end of a failure, e.g. "... (-1743)".
    /// The message text is localized by the system, the number is not.
    static func errorCode(in message: String) -> Int? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: #"\(-?[0-9]+\)\s*$"#, options: .regularExpression) else { return nil }
        return Int(text[range].filter { $0 == "-" || $0.isNumber })
    }

    /// Adds Portuguese guidance for the errors that need a human step; the system's own message stays as detail.
    static func explain(_ message: String, status: Int32 = 1) -> String {
        guard !message.isEmpty else { return "O script falhou (código \(status))." }
        guard let code = errorCode(in: message), let advice = advice(for: code, message: message) else { return message }
        return advice + "\n\nDetalhe do macOS: " + message
    }

    /// -1719 is "Invalid index" (a window or element that does not exist) as well as the old "assistive access" code,
    /// so it only gets permission advice when the system's message talks about assistive access.
    private static func mentionsAssistiveAccess(_ message: String) -> Bool {
        ["assistive", "assistiva", "acessibilidade", "accessibility"].contains {
            message.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func advice(for code: Int, message: String) -> String? {
        switch code {
        case -1743:
            "O macOS bloqueou o controle desse app: o Orb não tem permissão de Automação para ele. Peça ao usuário para "
                + "ativar em Ajustes do Sistema → Privacidade e Segurança → Automação (marcar o app abaixo de Orb) e "
                + "tente de novo."
        case -1719 where !mentionsAssistiveAccess(message):
            nil
        case -1719, -25211:
            "O macOS bloqueou o controle da interface: o Orb não tem permissão de Acessibilidade. Peça ao usuário para "
                + "ativar em Ajustes do Sistema → Privacidade e Segurança → Acessibilidade (marcar o Orb) e tente de novo."
        case -600, -609:
            "O app não está aberto (ou fechou durante o script). Abra-o com a ferramenta open e tente de novo."
        case -1712:
            "O app não respondeu a tempo. Ele pode estar ocupado ou travado, ou esperando uma resposta numa janela."
        case -128:
            "O usuário cancelou um diálogo aberto pelo script."
        default:
            nil
        }
    }
}
