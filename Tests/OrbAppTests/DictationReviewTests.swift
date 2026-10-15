import Foundation
import Testing
@testable import Orb

// The dictated text read over by the Orb's model when the microphone closes: what is worth a request, what is sent, what
// of the reply is kept, and the call itself.

struct DictationReviewTests {
    private let heard = "abre a planilha de vendas e me manda um resumo do clow de"

    @Test func aRevisionIsKeptAndAnAnswerIsNot() {
        let fixed = "Abre a planilha de vendas e me manda um resumo do Claude."
        #expect(DictationReview.accept(fixed, for: heard) == fixed)
        // Quotes and the tags the request used come off.
        #expect(DictationReview.accept("“\(fixed)”", for: heard) == fixed)
        #expect(DictationReview.accept("<dictation>\n\(fixed)\n</dictation>", for: heard) == fixed)
        // An answer to the text, a translation, a summary or nothing: the text stays as dictated.
        #expect(DictationReview.accept("Claro! Vou abrir a planilha agora mesmo e te mando o resumo em seguida.", for: heard) == nil)
        #expect(DictationReview.accept("Open the sales spreadsheet and send me a summary of Claude.", for: heard) == nil)
        #expect(DictationReview.accept("Resumo da planilha.", for: heard) == nil)
        #expect(DictationReview.accept("  ", for: heard) == nil)
    }

    @Test func aFewWordsOrAVeryLongTextAreNotSent() {
        #expect(!DictationReview.isWorthReviewing("pode mandar"))
        #expect(!DictationReview.isWorthReviewing("sim sim sim"))
        #expect(DictationReview.isWorthReviewing(heard))
        #expect(!DictationReview.isWorthReviewing(String(repeating: "palavra ", count: 400)))
    }

    @Test func theRequestCarriesTheLastMessagesTheNamesAndTheText() throws {
        let context: [ChatMessage] = [.user("primeira"), .user("Bom dia"), .user("Quero ver as vendas"),
                                      ChatMessage(role: .assistant, content: "Achei a planilha vendas.xlsx."),
                                      .tool("call-1", "saída de um comando"), .user("   "), .user("Pode resumir")]
        let messages = DictationReview.prompt(heard, context: context, vocabulary: ["Atlas", "/publicar-site"])
        #expect(messages.count == 2 && messages[0].role == .system && messages[0].content == DictationReview.instructions)
        let asked = try #require(messages.last?.content)
        // The last four said, past a tool's output and an empty one.
        #expect(asked.contains("Person: Bom dia\nPerson: Quero ver as vendas\nAssistant: Achei a planilha vendas.xlsx.\nPerson: Pode resumir"))
        #expect(!asked.contains("primeira") && !asked.contains("saída de um comando"))
        #expect(asked.contains("Atlas, /publicar-site"))
        #expect(asked.hasSuffix("<dictation>\n\(heard)\n</dictation>"))
        // Without context or names, only the text.
        #expect(DictationReview.prompt(heard, context: [], vocabulary: []).last?.content == "Dictated text:\n<dictation>\n\(heard)\n</dictation>")
        #expect(DictationReview.instructions.contains("never answer it"))
    }

    @Test func oneRequestWithoutToolsAndWhatItCost() async throws {
        let reviewer = CallScriptModel(always: [.text("Abre a planilha de vendas e me manda "), .text("um resumo do Claude."),
                                         .finished(.done, TokenUsage(input: 300, output: 20))])
        let result = await DictationReview.revise(heard, context: [], vocabulary: [], client: reviewer, model: "haiku")
        #expect(result == DictationReview.Result(text: "Abre a planilha de vendas e me manda um resumo do Claude.",
                                                 usage: TokenUsage(input: 300, output: 20)))
        let calls = await reviewer.script.calls
        #expect(calls.count == 1 && calls.first?.model == "haiku")
    }

    @Test func aFailureOrAnAnswerKeepsTheTextButNotWhatItCost() async {
        let failed = await DictationReview.revise(heard, context: [], vocabulary: [],
                                                  client: CallScriptModel(failure: LLMError.network(code: -1009, message: "offline")), model: "m")
        #expect(failed == DictationReview.Result(text: nil, usage: nil))
        let answered = await DictationReview.revise(heard, context: [], vocabulary: [], client: CallScriptModel(always: [
            .usage(TokenUsage(input: 300, output: 0)), .text(String(repeating: "Claro, aqui está o resumo. ", count: 20)),
        ]), model: "m")
        #expect(answered == DictationReview.Result(text: nil, usage: TokenUsage(input: 300, output: 0)))
    }

    @Test @MainActor func theReviewerIsTheCheapModelOfTheOrbsMaker() {
        var claudeCode = ProviderAccount(kind: .claudeCode)
        claudeCode.models = ClaudeCodeModels.fallback
        #expect(AppModel.dictationReviewer(in: claudeCode, orb: "sonnet") == "haiku")
        claudeCode.models = []
        #expect(AppModel.dictationReviewer(in: claudeCode, orb: "sonnet") == "sonnet")
        var anthropic = ProviderAccount(kind: .anthropic)
        anthropic.models = ["claude-sonnet-4", "claude-haiku-4-5"].map { ProviderModel(id: $0, name: $0, format: .chat) }
        #expect(AppModel.dictationReviewer(in: anthropic, orb: "claude-sonnet-4") == "claude-haiku-4-5")
        var other = ProviderAccount(kind: .openai)
        other.models = [ProviderModel(id: "o3", name: "o3", format: .chat)]
        #expect(AppModel.dictationReviewer(in: other, orb: "o3") == "o3")
    }
}

/// The call from the app: the Orb's account, the cheap model, the chat as context, the cost on the Uso page.
@Suite final class DictationReviewCallTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbDictationReview-\(UUID().uuidString)")

    init() { QuietNotifications.hold() }

    deinit {
        QuietNotifications.release()
        removeTestFolder(root)
    }

    @MainActor private func setUp(_ reviewer: CallScriptModel) -> (AppModel, UUID) {
        let state = AppState.initial
        let store = Store(directory: root)
        store.save(state)
        store.flush()
        let model = AppModel(store: store, runsBackgroundWork: false)
        model.homeFolder = root
        var account = ProviderAccount(kind: .claudeCode)
        account.models = ClaudeCodeModels.fallback
        model.providers = [account]
        model.publishConnections([.claudeCode])
        model.defaultModel = "claudeCode/sonnet"
        model.clientOverride = { reviewer }
        return (model, state.bots[0].id)
    }

    @Test @MainActor func theRevisedTextComesBackAndItsCostIsKeptApartFromTheChat() async throws {
        let reviewer = CallScriptModel(always: [.text("Abre a planilha de vendas e me manda um resumo, por favor."),
                                         .finished(.done, TokenUsage(input: 400, output: 15))])
        let (model, botID) = setUp(reviewer)
        let text = await model.reviewDictation("abre a planilha de vendas e me manda um resumo por favor", of: botID, vocabulary: ["Atlas"])
        #expect(text == "Abre a planilha de vendas e me manda um resumo, por favor.")
        let calls = await reviewer.script.calls
        #expect(calls.count == 1 && calls.first?.model == "haiku")
        #expect(calls.first?.sent.last?.content.contains("Atlas") == true)

        model.usageLog.flush()
        model.store.flush()
        let buckets = await model.store.readUsage(from: .now.addingTimeInterval(-86_400), to: .now.addingTimeInterval(86_400)).buckets
        #expect(buckets.count == 1)
        #expect(buckets.first?.key.source == .auxiliary && buckets.first?.key.model == "claudeCode/haiku")
        #expect(buckets.first?.totals == UsageTotals(requests: 1, input: 400, output: 15))
    }

    @Test @MainActor func anOrbThatIsGoneGetsNoRequest() async {
        let reviewer = CallScriptModel(always: [.text("Texto.")])
        let (model, _) = setUp(reviewer)
        #expect(await model.reviewDictation("abre a planilha de vendas", of: UUID(), vocabulary: []) == nil)
        #expect(await reviewer.script.calls.isEmpty)
    }
}
