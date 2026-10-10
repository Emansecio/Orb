import SwiftUI

/// `--snapshot` modes of the "Criar conversando" assistant, each the new-Orb sheet in the assistant with a runner put in a given
/// state (no model is called):
/// - `wizard`: just opened, the first line and the three suggestions, the preview empty;
/// - `wizard-asking`: two turns in, the preview half made (the role was just changed, so it is washed);
/// - `wizard-writing`: the assistant answering, the Orb thinking, "escrevendo…";
/// - `wizard-ready`: the draft complete, the final card at the foot of the preview;
/// - `wizard-narrow`: the same with a short window (`ORB_SNAPSHOT_HEIGHT=620`);
/// - `wizard-failed`: a turn that failed, with "Tentar de novo";
/// - `wizard-form`: the sheet in the form, to see the choice between the two ways and the preview beside it;
/// - `wizard-appearance`: the "Aparência" tab, the editor at the sheet's whole width.
@MainActor
enum WizardSnapshots {
    static func view(_ screen: String, model: AppModel) -> AnyView? {
        guard screen == "wizard" || screen.hasPrefix("wizard-") else { return nil }
        // A model "connected" so the assistant is on (only in the snapshot's own temporary data).
        model.providers = [ProviderAccount(kind: .custom)]
        model.defaultModel = "custom/modelo"
        let height = ProcessInfo.processInfo.environment["ORB_SNAPSHOT_HEIGHT"].flatMap(Double.init).map { CGFloat($0) } ?? NewBotSheetLayout.preferredHeight
        switch screen {
        case "wizard":
            return sheet(WizardRunner(model: model), height: height)
        case "wizard-asking":
            return sheet(WizardRunner(messages: asking, draft: partialDraft, isThinking: false), height: height, flashed: [.role])
        case "wizard-writing":
            return sheet(WizardRunner(messages: asking, draft: partialDraft, isThinking: true), height: height)
        case "wizard-ready", "wizard-narrow":
            return sheet(WizardRunner(messages: asking + readyTail, draft: readyDraft), height: height)
        case "wizard-failed":
            return sheet(WizardRunner(messages: asking, draft: partialDraft, failure: "O modelo não respondeu."), height: height)
        case "wizard-form":
            return AnyView(NewBotSheet(height: height, mode: .form, look: look))
        case "wizard-appearance":
            return sheet(WizardRunner(messages: asking, draft: partialDraft), height: height, tab: .look)
        default:
            return nil
        }
    }

    private static func sheet(_ runner: WizardRunner, height: CGFloat?, flashed: Set<DraftField> = [], tab: NewOrbTab = .who) -> AnyView {
        AnyView(NewBotSheet(height: height, mode: .assistant, assistant: runner, previewFlashed: flashed, tab: tab, look: look))
    }

    // MARK: Scenes

    private static func bot(_ text: String) -> TranscriptItem { TranscriptItem(.bot(text: text, isStreaming: false)) }
    private static func user(_ text: String) -> TranscriptItem { TranscriptItem(.user(text: text, attachments: [])) }

    private static let asking: [TranscriptItem] = [
        bot(WizardPrompt.firstLine),
        user("Quero que ele cuide da minha agenda e dos e-mails do trabalho."),
        bot("Boa! Um bom resultado seria uma manhã sem surpresas?\n\nComo você prefere que ele trabalhe: respostas curtas ou mais detalhadas, e ele pode agir sozinho ou pergunta antes?"),
        user("Curtas e diretas. E que pergunte antes de enviar qualquer coisa."),
        bot("Anotado. Última coisa: ele pode usar a web para conferir informações, ou só trabalhar com o que você contar?"),
    ]

    private static let readyTail: [TranscriptItem] = [
        user("Pode usar a web, sim."),
        bot("Tudo certo: a Maia está pronta. É só tocar em Criar."),
    ]

    private static let look = OrbConfig(color: "menta", eyes: "pilulas", mouth: "sorriso", cheeks: "blush", hair: "franja",
                                        accessories: ["laco"])

    private static let instructions = """
    Você é a Maia, assistente de agenda e e-mails do trabalho.
    - Responda de forma curta e direta.
    - Antes de enviar qualquer e-mail ou aceitar um convite, mostre o rascunho e pergunte.
    - Toda manhã, resuma a caixa de entrada: o que é urgente e o que pode esperar.
    - Se faltar um dado (horário, nome), pergunte em vez de supor.
    """

    private static var partialDraft: OrbDraft {
        var draft = OrbDraft()
        draft.name = "Maia"
        draft.role = "Cuida da agenda e dos e-mails do trabalho"
        draft.instructions = instructions
        draft.mode = .ask
        draft.revision = 2
        draft.changed = [.role]
        return draft
    }

    private static var readyDraft: OrbDraft {
        var draft = partialDraft
        draft.capabilities = [.browser, .terminal]
        draft.revision = 3
        draft.changed = []
        draft.ready = true
        return draft
    }
}
