import Foundation

/// Runs osascript (AppleScript or JXA) and turns its failures into advice the model and the user can act on.
enum AppleScript {
    enum Language: String, Sendable {
        case applescript, javascript

        var arguments: [String] { self == .javascript ? ["-l", "JavaScript"] : [] }
    }

    /// `structured` asks osascript for recompilable output (`-s s`): strings are quoted and lists/records keep their
    /// shape, so the model can tell `"1"` from `1`. Throws a `ToolError` whose text already explains the likely fix.
    /// Before the script starts, apps it addresses that macOS has never asked about get their consent dialog (the user may
    /// take a while to answer, and that wait must not count against `timeout`); a refused app fails the call at once.
    static func run(_ script: String, language: Language = .applescript, structured: Bool = false,
                    timeout: Duration = .seconds(60), outputLimit: Int = 20_000,
                    permissions: MacPermissionChecker = .live) async throws -> String {
        if let problem = await AutomationPreflight.blockingProblem(for: script, language: language, checker: permissions) {
            throw ToolError(problem.modelMessage)
        }
        let arguments = language.arguments + (structured ? ["-s", "s"] : []) + ["-e", script]
        let result = try await ProcessRunner.run("/usr/bin/osascript", arguments, timeout: timeout, outputLimit: outputLimit)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.timedOut { throw ToolError(timeoutMessage(seconds: Int(timeout.components.seconds))) }
        guard result.status == 0 else { throw ToolError(explain(output, status: result.status, scriptApps: AutomationPreflight.appNames(in: script, language: language))) }
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

    /// Adds guidance for the errors that need a human step; the system's own message stays as detail.
    /// `scriptApps` are the apps the script addresses: when macOS does not name the refused app and the script talks to
    /// only one, that one is the app.
    static func explain(_ message: String, status: Int32 = 1, scriptApps: [String] = []) -> String {
        guard !message.isEmpty else { return "O script falhou (código \(status))." }
        if var problem = MacPermissionProblem.detect(in: message) {
            if case .automation(nil) = problem, scriptApps.count == 1 { problem = .automation(app: scriptApps[0]) }
            return problem.modelMessage + "\n\nmacOS said: " + message
        }
        guard let code = errorCode(in: message), let advice = advice(for: code) else { return message }
        return advice + "\n\nDetalhe do macOS: " + message
    }

    private static func advice(for code: Int) -> String? {
        switch code {
        case -600, -609:
            "O app não está aberto (ou fechou durante o script). Abra-o com a ferramenta open e tente de novo."
        case -1712:
            "O app não respondeu a tempo. Ele pode estar ocupado ou travado, ou esperando uma resposta numa janela."
        case -30720:
            "Data ou hora inválida para o idioma do Mac. Não escreva a data como texto: monte a partir de `current date` "
                + "(set d to current date; set day of d to 1; depois year, month, day, hours, minutes e seconds), ou em JXA use new Date(ano, mês-1, dia, hora, minuto)."
        case -1728:
            "O item não existe (ou o nome está diferente). Liste os nomes antes (por exemplo name of every calendar / list / folder) e use o nome exato."
        case -1708:
            "O app não entende esse comando. Confira o vocabulário do app (sdef) ou use outra forma, como ui_read/ui_act ou um Atalho."
        case -2741:
            "Erro de sintaxe no script: corrija o script. Não é um problema de permissão."
        case -128:
            "O usuário cancelou um diálogo aberto pelo script."
        default:
            nil
        }
    }
}
