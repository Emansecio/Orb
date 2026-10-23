import Foundation
import Testing
@testable import Orb

// The structured, incremental summary of a conversation (`ConversationLedger`): what it keeps, its caps, how it
// survives compactions, and that it never nests.

// MARK: - Helpers

/// A turn: the request, one tool step (`name` with `arguments`) answered by `output`, and a reply.
private func step(_ request: String, tool name: String = "read_file", arguments: String = "{}", output: String = "ok",
                  isError: Bool = false, reply: String = "feito") -> [ChatMessage] {
    let id = "c-" + UUID().uuidString.prefix(6)
    return [.user(request), assistant(calls: [call(id, name, arguments)]), .tool(id, output, isError: isError), assistant(reply)]
}

private func ledger(of messages: [ChatMessage]) -> ConversationLedger { ConversationLedger().absorbing(messages) }

private let longRequest = "Construa o app Atlas com SQLite e rode os testes a cada mudança"

/// A long answer: old tool outputs are condensed before any turn is folded (`ContextCondensing`), so a history that has
/// to fold needs more than outputs to fill the window.
private let longReply = String(repeating: "texto da resposta ", count: 200)

// MARK: - The first request and the goal

struct LedgerOriginalTests {
    @Test func theFirstRealRequestIsKeptAsTheOriginal() {
        let ledger = ledger(of: step(longRequest))
        #expect(ledger.original == longRequest)
        #expect(ledger.render().hasPrefix("Pedido original: " + longRequest))
    }

    @Test func aGreetingIsNotTheOriginalRequest() {
        let ledger = ledger(of: step("oi") + step(longRequest))
        #expect(ledger.original == longRequest)
    }

    @Test func anOriginalRequestWithARuleInItIsStillTheOriginal() {
        let text = "Construa o app Atlas com SQLite; nunca apague /Users/x/dados."
        let ledger = ledger(of: step(text))
        #expect(ledger.original == text)
        #expect(ledger.entries.isEmpty)
    }

    @Test func theOriginalSurvivesAnyNumberOfLaterRequests() {
        var ledger = ledger(of: step(longRequest))
        for index in 0..<200 { ledger.absorb(step("pedido número \(index) do projeto")) }
        #expect(ledger.original == longRequest)
        #expect(ledger.render().contains("Pedido original: " + longRequest))
        #expect(ledger.entries.count <= ConversationLedger.maxEntries)
    }

    @Test func aLongOriginalIsClipped() throws {
        let long = String(repeating: "palavra ", count: 200)
        let original = try #require(ledger(of: step(long)).original)
        #expect(original.count <= ConversationLedger.originalLimit + 1)
    }

    @Test func theGoalFollowsTheLatestRequestButNotAConfirmation() {
        var ledger = ledger(of: step(longRequest))
        ledger.absorb(step("agora ajuste o módulo de login"))
        #expect(ledger.goal == "agora ajuste o módulo de login")
        ledger.absorb([.user("ok"), assistant("certo")])
        #expect(ledger.goal == "agora ajuste o módulo de login")
        ledger.absorb(step("e agora?"))   // too short to change what the task is
        #expect(ledger.goal == "agora ajuste o módulo de login")
    }

    @Test func aPictureAloneDoesNotReplaceTheGoal() {
        let picture = ImageAttachment(path: "/tmp/captura.png", mediaType: "image/png", width: 10, height: 10)
        let ledger = ledger(of: step("refatore o módulo de pagamentos para usar o novo cliente") + [.user("", images: [picture]), assistant("Vi a captura.")])
        #expect(ledger.goal == "refatore o módulo de pagamentos para usar o novo cliente")
        #expect(ledger.render().contains("refatore o módulo de pagamentos para usar o novo cliente"))
    }

    @Test func theGoalIsNotRepeatedWhenItIsTheNewestLineOfTheTimeline() {
        let ledger = ledger(of: step(longRequest) + step("agora ajuste o módulo de login"))
        let text = ledger.render()
        #expect(!text.contains("Objetivo atual"))
        #expect(text.contains("- agora ajuste o módulo de login"))
    }

    @Test func theGoalShowsWhenLaterMessagesMovedTheTimelineOn() {
        var ledger = ledger(of: step(longRequest) + step("agora ajuste o módulo de login"))
        ledger.absorb([.user("e agora?"), assistant("certo")])
        #expect(ledger.render().contains("Objetivo atual: agora ajuste o módulo de login"))
    }

    @Test func theSummaryOfAPrefacedMessageHasNoPreface() {
        let snapshot = WorkspaceSnapshot(path: "/p", entries: ["Package.swift"])
        let preface = TurnPreface.make(now: .now, timeZone: "UTC", snapshot: snapshot, notes: "")
        let ledger = ledger(of: step(TurnPreface.prepend(preface, to: longRequest)))
        #expect(ledger.original == longRequest)
        #expect(!ledger.render().contains(TurnPreface.openTag))
    }
}

// MARK: - What the app adds around the user's words

struct LedgerUserWordsTests {
    private let preface = TurnPreface.make(now: .now, timeZone: "America/Sao_Paulo", snapshot: nil, notes: "")
    private let review = Skill(slug: "revisar", name: "Revisar", summary: "Revisa código",
                               instructions: String(repeating: "Sempre confira os testes e nunca apague arquivos. Use o git diff. ", count: 25))

    @Test func aSkillRequestKeepsTheRealRequestNotTheSkillsInstructions() throws {
        let expanded = try #require(SystemPrompt.expandSkill(in: "/revisar corrigir o login", skills: [review])).prompt
        #expect(expanded.count > 1_500)
        let ledger = ledger(of: [.user(TurnPreface.prepend(preface, to: expanded)), assistant("feito")])
        #expect(ledger.original == "/Revisar corrigir o login")
        #expect(ledger.goal == "/Revisar corrigir o login")
        #expect(!ledger.entries.contains { $0.isDecision })
        // The same on a later request: the instructions never become "decisions".
        var later = ledger
        later.absorb([.user(TurnPreface.prepend(preface, to: SystemPrompt.expandSkill(in: "/revisar o cadastro também", skills: [review])!.prompt)),
                      assistant("feito")])
        #expect(later.entries.map(\.text) == ["/Revisar o cadastro também"] && !later.entries.contains { $0.isDecision })
    }

    @Test func theMemoryInstructionAndTheFileListsAreNotPartOfTheRequest() {
        let remember = TurnPreface.prepend(preface, to: "memorize que uso tabs" + MemoryIntent.instruction(tool: "remember"))
        #expect(TurnPreface.userWords(remember) == "memorize que uso tabs")
        let files = "veja isto\n\nAttached files (read them with your tools):\n- /Users/x/relatorio.pdf\n- /tmp/dados.csv"
            + MemoryIntent.instruction(tool: "remember")
        #expect(TurnPreface.userWords(files) == "veja isto (anexos: relatorio.pdf, dados.csv)")
        let picture = "o que é isso?\n\nAttached images (resized copies, shown to you with this message):\n- /tmp/foto.jpg"
        #expect(TurnPreface.userWords(picture) == "o que é isso? (anexos: foto.jpg)")
        #expect(TurnPreface.userWords("texto normal") == "texto normal")
        let address = "veja\n\nAttached files (read them with your tools):\n- http://localhost:$PORT/x"
        #expect(TurnPreface.userWords(address) == "veja (anexos: x)")
    }

    @Test func aSkillWithoutARequestIsJustItsName() throws {
        let expanded = try #require(SystemPrompt.expandSkill(in: "/revisar", skills: [review])).prompt
        #expect(TurnPreface.userWords(expanded) == "/Revisar")
    }

    @Test func theToolDigestSaysWhatTheUserAskedToo() throws {
        let expanded = try #require(SystemPrompt.expandSkill(in: "/revisar corrigir o login", skills: [review])).prompt
        let lines = ToolDigest.lines(for: [.user(TurnPreface.prepend(preface, to: expanded))])
        #expect(lines == ["[usuário] «/Revisar corrigir o login»"])
    }
}

// MARK: - Decisions

struct LedgerDecisionTests {
    @Test(arguments: [
        "Decisão: a porta do servidor será 4711, não mude.", "vamos usar Postgres em vez de SQLite", "use sempre tabs",
        "nunca apague a pasta dados", "Lembre: o cliente prefere relatórios em PDF.", "a partir de agora responda em inglês",
        "prefiro commits pequenos", "não use o módulo antigo",
    ])
    func decisionsAreRecognized(_ text: String) {
        #expect(ConversationLedger.looksLikeDecision(text))
    }

    @Test(arguments: [
        "ajuste o módulo de login", "rode os testes", "por que o build nunca termina?", "você sempre faz isso?", "mostre o arquivo",
    ])
    func ordinaryRequestsAndQuestionsAreNot(_ text: String) {
        #expect(!ConversationLedger.looksLikeDecision(text))
    }

    @Test func aDecisionIsKeptWithItsLabelAndWithoutTheWordDecision() {
        let ledger = ledger(of: step(longRequest) + step("Decisão: a porta do servidor será 4711, não mude."))
        #expect(ledger.entries.last == .init(text: "a porta do servidor será 4711, não mude.", isDecision: true))
        #expect(ledger.render().contains("- decisão: a porta do servidor será 4711, não mude."))
    }

    @Test func aLongMessageKeepsTheSentenceThatStatesTheDecision() throws {
        let filler = String(repeating: "Contexto sobre o projeto e o histórico da equipe. ", count: 8)
        let ledger = ledger(of: step(longRequest) + step(filler + "Daqui em diante use sempre o prefixo orb_ nos testes. " + filler))
        let entry = try #require(ledger.entries.last)
        #expect(entry.isDecision)
        #expect(entry.text.contains("use sempre o prefixo orb_"))
        #expect(entry.text.count <= ConversationLedger.decisionLimit + 1)
    }

    @Test func aYesToAQuestionBecomesADecisionWithTheQuestion() {
        let ledger = ledger(of: step(longRequest) + [.user("posso apagar a pasta antiga?"), assistant("Posso apagar a pasta /tmp/antiga agora?"),
                                                    .user("sim"), assistant("Apagada.")])
        let decision = ledger.entries.last
        #expect(decision?.isDecision == true)
        #expect(decision?.text.contains("“sim” em resposta a: Posso apagar a pasta /tmp/antiga agora?") == true)
    }

    @Test func aBareYesWithoutAQuestionIsDropped() {
        let ledger = ledger(of: step(longRequest) + [.user("ok"), assistant("certo"), .user("continua"), assistant("segue")])
        #expect(ledger.entries.isEmpty)
    }

    @Test func theAssistantsLastQuestionIsKeptForTheMessageThatFollows() {
        let messages = step(longRequest) + [.user("o que você acha?"), assistant("Tenho duas opções. Quer que eu use SQLite ou Postgres?")]
        let withUser = ConversationLedger().absorbing(messages, followedByUser: true)
        #expect(withUser.openQuestion == "Quer que eu use SQLite ou Postgres?")
        #expect(withUser.render().contains("Última pergunta do assistente"))
        #expect(ConversationLedger().absorbing(messages, followedByUser: false).openQuestion == nil)
        // The user's next message answers it.
        var later = withUser
        later.absorb([.user("SQLite"), assistant("Certo.")])
        #expect(later.openQuestion == nil)
    }

    @Test func aQuestionKeepsItsFileNamesAndVersionsWhole() {
        func question(_ reply: String) -> String? {
            ConversationLedger().absorbing(step(longRequest) + [.user("e agora?"), assistant(reply)], followedByUser: true).openQuestion
        }
        #expect(question("Posso renomear o arquivo config.json para settings.json?") == "Posso renomear o arquivo config.json para settings.json?")
        #expect(question("Atualizo para a versão 2.5 agora?") == "Atualizo para a versão 2.5 agora?")
        #expect(question("Feito. Abro https://exemplo.com/a?") == "Abro https://exemplo.com/a?")
    }

    @Test func decisionsOutliveOrdinaryRequestsWhenThereAreTooMany() {
        var ledger = ledger(of: step(longRequest) + step("Decisão: a porta do servidor será 4711, não mude."))
        for index in 0..<80 { ledger.absorb(step("pedido número \(index) do projeto")) }
        #expect(ledger.entries.count == ConversationLedger.maxEntries)
        #expect(ledger.entries.contains { $0.isDecision && $0.text.contains("4711") })
        #expect(ledger.earlierEntries > 0)
        let text = ledger.render()
        #expect(text.contains("decisão: a porta do servidor será 4711"))
        #expect(text.contains("(+"))
        #expect(text.contains("pedido número 79 do projeto"))
    }
}

// MARK: - Files, errors, pending

struct LedgerStateTests {
    @Test func writtenFilesAreSeparateFromReadOnes() {
        let ledger = ledger(of: step(longRequest, tool: "read_file", arguments: #"{"path":"/p/a.swift"}"#)
            + step("edite", tool: "edit_file", arguments: #"{"path":"/p/b.swift","old_string":"x","new_string":"y"}"#)
            + step("crie", tool: "write_file", arguments: #"{"path":"/p/c.swift","content":"..."}"#))
        #expect(ledger.read == ["/p/a.swift"])
        #expect(ledger.changed == ["/p/b.swift", "/p/c.swift"])
        let text = ledger.render()
        #expect(text.contains("Arquivos alterados: /p/b.swift; /p/c.swift"))
        #expect(text.contains("Arquivos e links lidos: /p/a.swift"))
    }

    @Test func aFileThatIsChangedLaterMovesOutOfTheReadList() {
        let ledger = ledger(of: step(longRequest, tool: "read_file", arguments: #"{"path":"/p/a.swift"}"#)
            + step("edite", tool: "edit_file", arguments: #"{"path":"/p/a.swift"}"#)
            + step("leia de novo", tool: "read_file", arguments: #"{"path":"/p/a.swift"}"#))
        #expect(ledger.changed == ["/p/a.swift"])
        #expect(ledger.read.isEmpty)
    }

    @Test func aFailedWriteDoesNotCountAsChanged() {
        let ledger = ledger(of: step(longRequest, tool: "write_file", arguments: #"{"path":"/p/a.swift","content":"x"}"#,
                                     output: "Error: permission denied", isError: true))
        #expect(ledger.changed.isEmpty)
        #expect(ledger.failures.first?.text.contains("write_file /p/a.swift: Error: permission denied") == true)
    }

    @Test func linksFetchedAreRecordedAsRead() {
        let ledger = ledger(of: step(longRequest, tool: "web_fetch", arguments: #"{"url":"https://example.com/doc"}"#))
        #expect(ledger.read == ["https://example.com/doc"])
    }

    @Test func trashedFilesCountAsChanged() {
        let ledger = ledger(of: step(longRequest, tool: "trash", arguments: #"{"paths":["/p/a.txt","/p/b.txt"]}"#))
        #expect(ledger.changed == ["/p/a.txt", "/p/b.txt"])
    }

    @Test func shellCommandsThatWriteFilesAreRecognized() {
        func written(_ command: String) -> [String] {
            ledger(of: step("x", tool: "run_command", arguments: JSONValue.object(["command": .string(command)]).jsonString)).changed
        }
        #expect(written("echo oi > /p/out.txt") == ["/p/out.txt"])
        #expect(written("echo oi >> /p/log.txt 2>&1") == ["/p/log.txt"])
        #expect(written("cat a | tee /p/copy.txt") == ["/p/copy.txt"])
        #expect(written("mkdir -p /p/novo && touch /p/novo/a") == ["/p/novo", "/p/novo/a"])
        #expect(written("rm -rf /p/velho") == ["/p/velho"])
        #expect(written("mv /p/a /p/b") == ["/p/a", "/p/b"])
        #expect(written("sed -i '' 's/a/b/' /p/f.txt") == ["/p/f.txt"])
        #expect(written("swift build 2>&1 | tail -5").isEmpty)
        #expect(written("ls > /dev/null").isEmpty)
        #expect(written("git status").isEmpty)
        // The body of a here-document is data, not commands.
        #expect(written("cat > /p/nota.txt <<'EOF'\necho x > /p/outro.txt\nEOF") == ["/p/nota.txt"])
    }

    @Test func fileListsKeepTheNewestAndCountTheRest() {
        var ledger = ConversationLedger()
        for index in 0..<30 {
            ledger.absorb(step("escreva \(index)", tool: "write_file", arguments: #"{"path":"/projeto/modulos/arquivo-\#(index).swift"}"#))
        }
        let line = ledger.render().split(separator: "\n").first { $0.hasPrefix("Arquivos alterados") } ?? ""
        #expect(line.contains("arquivo-29.swift"))
        #expect(!line.contains("arquivo-0.swift"))
        #expect(line.contains("e mais"))
        #expect(line.count < 520)
        #expect(ledger.changed.count == 30)
        // The store is capped too.
        for index in 30..<80 { ledger.absorb(step("escreva \(index)", tool: "write_file", arguments: #"{"path":"/p/f\#(index).swift"}"#)) }
        #expect(ledger.changed.count == ConversationLedger.maxFiles)
    }

    @Test func anErrorStaysUntilTheSameActionWorks() {
        var ledger = ledger(of: step(longRequest, tool: "run_command", arguments: #"{"command":"swift test"}"#,
                                     output: "Error: 3 tests failed\nmore", isError: true))
        #expect(ledger.render().contains("Erros e bloqueios:\n- run_command swift test: Error: 3 tests failed"))
        ledger.absorb(step("de novo", tool: "run_command", arguments: #"{"command":"swift test"}"#, output: "ok"))
        #expect(ledger.failures.isEmpty)
        #expect(!ledger.render().contains("Erros e bloqueios"))
    }

    @Test func aDeniedActionIsAnError() {
        let denied = ledger(of: step(longRequest, tool: "run_command", arguments: #"{"command":"rm -rf /p"}"#,
                                     output: PermissionPolicy.userDenial, isError: true))
        #expect(denied.failures.first?.text.contains("você negou esta ação") == true)
        #expect(denied.changed.isEmpty)
    }

    @Test func onlyTheNewestFiveErrorsAreKept() {
        var ledger = ConversationLedger()
        for index in 0..<9 {
            ledger.absorb(step("x", tool: "read_file", arguments: #"{"path":"/p/\#(index).txt"}"#, output: "Error: not found", isError: true))
        }
        #expect(ledger.failures.count == ConversationLedger.maxFailures)
        #expect(ledger.failures.last?.text.contains("/p/8.txt") == true)
    }

    @Test func aRequestWithoutAFinalAnswerIsPending() {
        let id = "c1"
        let ledger = ledger(of: [.user(longRequest), assistant(calls: [call(id, "read_file", #"{"path":"/p/a"}"#)]), .tool(id, "dados")])
        #expect(ledger.render().contains("Pedido ainda sem resposta final: " + longRequest))
        let answered = ledger.absorbing([assistant("Aqui está.")])
        #expect(!answered.render().contains("sem resposta final"))
    }

    @Test func aReplyThatWasCutOffKeepsTheRequestPending() {
        let ledger = ledger(of: [.user(longRequest), assistant("Comecei a escrever" + AgentEngine.interruptedMarker)])
        #expect(ledger.render().contains("sem resposta final"))
    }

    @Test func theLastReplyIsShortAndHasNoCode() throws {
        let reply = "Pronto, ajustei o login.\n```swift\n" + String(repeating: "let x = 1\n", count: 100) + "```\nTestes passam."
        let text = try #require(ledger(of: [.user(longRequest), assistant(reply)]).lastReply)
        #expect(text == "Pronto, ajustei o login. [código] Testes passam.")
        let long = try #require(ledger(of: [.user(longRequest), assistant(String(repeating: "blá ", count: 500))]).lastReply)
        #expect(long.count <= ConversationLedger.replyLimit + 1)
    }

    @Test func claudeCodesActionNoteIsNotPartOfTheReply() {
        let reply = "Feito." + "\n\n(Actions taken in this turn: Rodando no Terminal: swift test)"
        #expect(ledger(of: [.user(longRequest), assistant(reply)]).lastReply == "Feito.")
    }

    @Test func aSummaryPairInTheInputIsNotCountedAsARequest() {
        let pair = ContextSummary.pair("Pedido original: algo")
        let ledger = ledger(of: pair + step(longRequest))
        #expect(ledger.original == longRequest)
        #expect(ledger.foldedMessages == 4)
    }
}

// MARK: - Incremental, bounded, never nested

struct LedgerIncrementalTests {
    private func conversation(_ turns: Int) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for index in 0..<turns {
            let request = index == 0 ? longRequest : index == 3 ? "Decisão: a porta será 4711, não mude." : "pedido número \(index) do projeto"
            messages += step(request, tool: "edit_file", arguments: #"{"path":"/p/m\#(index % 7).swift"}"#, reply: "ok \(index)")
        }
        return messages
    }

    @Test func absorbingInPiecesGivesTheSameLedgerAsAbsorbingAtOnce() {
        let messages = conversation(30)
        let whole = ledger(of: messages)
        var pieces = ConversationLedger()
        for start in stride(from: 0, to: messages.count, by: 4) { pieces.absorb(Array(messages[start..<min(start + 4, messages.count)])) }
        #expect(pieces == whole)
        #expect(pieces.render() == whole.render())
    }

    @Test func theRenderedTextIsDeterministic() {
        let messages = conversation(40)
        #expect(ledger(of: messages).render() == ledger(of: messages).render())
    }

    @Test func theRenderNeverExceedsItsLimitAndKeepsTheOriginalFirst() {
        var ledger = ledger(of: conversation(200))
        for index in 0..<60 {
            ledger.absorb(step("use sempre o padrão número \(index) com bastante texto para ocupar espaço no resumo", tool: "write_file",
                               arguments: #"{"path":"/projeto/com/um/caminho/bem/longo/arquivo\#(index).swift"}"#,
                               reply: String(repeating: "resposta longa ", count: 40)))
        }
        for limit in [3_000, 1_500, 700, 200] {
            let text = ledger.render(limit: limit)
            #expect(text.count <= limit + 1, "limit \(limit)")
            #expect(text.hasPrefix("Pedido original: Construa o app Atlas"))
        }
        // The decision from turn 3 is still there at the default size.
        #expect(ledger.render().count <= ContextSummary.maxLength)
    }

    @Test func lessImportantSectionsGoFirstWhenTheTextIsTooLong() {
        var ledger = ledger(of: conversation(5))
        ledger.legacy = String(repeating: "texto antigo ", count: 100)
        ledger.lastReply = String(repeating: "resposta ", count: 40)
        let full = ledger.render(limit: 10_000)
        #expect(full.contains("Resumo anterior (formato antigo)") && full.contains("Última resposta"))
        // The last answer goes first, then the old text.
        let tight = ledger.render(limit: full.count - 100)
        #expect(!tight.contains("Última resposta") && tight.contains("Resumo anterior"))
        let tighter = ledger.render(limit: full.count - 460)
        #expect(!tighter.contains("Resumo anterior"))
        #expect(tighter.contains("Pedidos e decisões") && tighter.contains("Pedido original"))
    }

    @Test func theFirstRequestOfAnOldSummaryIsPinnedAndOutlivesItsText() {
        let old = "Pedidos do usuário:\n- Construa o app Atlas com SQLite. NUNCA use a porta 80\n- rode os testes\nÚltima resposta do assistente: pronto"
        var ledger = ConversationLedger(legacy: old)
        #expect(ledger.original == "Construa o app Atlas com SQLite. NUNCA use a porta 80")
        for round in 0..<30 {
            ledger.absorb(step("pedido \(round) " + String(repeating: "x", count: 100), tool: "write_file", arguments: #"{"path":"/p/f\#(round).swift"}"#)
                          + step("Decisão: regra número \(round) deve valer sempre, sem exceção alguma neste projeto."))
        }
        let text = ledger.render()
        #expect(text.count <= ContextSummary.maxLength)
        #expect(text.contains("Pedido original: Construa o app Atlas com SQLite. NUNCA use a porta 80"))
        // A first request that older versions had already cut from the list is not guessed.
        #expect(ConversationLedger(legacy: "Pedidos do usuário:\n(+3 pedidos anteriores)\n- algo bem longo para ser pedido").original == nil)
        #expect(ConversationLedger(legacy: "Pedidos do usuário:\n- oi").original == nil)
    }

    @Test func foldingAgainAndAgainNeverNestsASummary() {
        // The way the app does it: each compaction extends the ledger it saved, then renders again.
        var saved = ConversationLedger()
        var text = ""
        for round in 0..<12 {
            saved = saved.absorbing(conversation(6).map { message in
                var copy = message
                if message.role == .user { copy.content += " rodada \(round)" }
                return copy
            })
            text = saved.render()
        }
        #expect(!text.contains("Resumo anterior"))
        #expect(text.components(separatedBy: "Pedido original").count == 2)
        #expect(text.count <= ContextSummary.maxLength)
    }

    @Test func aSummaryFromAnEarlierVersionIsCarriedOnceAndNeverExtended() {
        let old = "Pedidos do usuário:\n- pedido antigo\nResumo anterior: Pedidos do usuário:\n- mais antigo\nResumo anterior: ainda mais"
        var ledger = ConversationLedger(legacy: old)
        #expect(ledger.legacy == "Pedidos do usuário:\n- pedido antigo")
        for round in 0..<5 { ledger.absorb(conversation(4).map { m in var c = m; if m.role == .user { c.content += " \(round)" }; return c }) }
        let text = ledger.render()
        #expect(text.components(separatedBy: "Resumo anterior").count == 2)
        #expect(text.contains("pedido antigo"))
        #expect(!text.contains("mais antigo"))
        // With a legacy summary the first new message is not mistaken for the original request of the conversation.
        #expect(ledger.original == nil)
    }

    @Test func anEmptyLegacyTextIsNothing() {
        #expect(ConversationLedger(legacy: "  \n ") == ConversationLedger())
    }
}

// MARK: - Persistence

struct LedgerPersistenceTests {
    @Test func aLedgerSurvivesEncodingAndDecoding() throws {
        var ledger = ledger(of: step(longRequest, tool: "edit_file", arguments: #"{"path":"/p/a"}"#) + step("Decisão: porta 4711, não mude."))
        ledger.focus = "o login"
        let again = try JSONDecoder().decode(ConversationLedger.self, from: JSONEncoder().encode(ledger))
        #expect(again == ledger)
    }

    @Test func aLedgerWithMissingOrUnknownFieldsStillDecodes() throws {
        let empty = try JSONDecoder().decode(ConversationLedger.self, from: Data("{}".utf8))
        #expect(empty == ConversationLedger())
        let partial = #"{"original":"algo","entries":[{"text":"a","isDecision":false},{"nope":1}],"future":{"x":1},"changed":["/p/a"]}"#
        let decoded = try JSONDecoder().decode(ConversationLedger.self, from: Data(partial.utf8))
        #expect(decoded.original == "algo" && decoded.changed == ["/p/a"])
        #expect(decoded.entries.count == 1)   // the unreadable entry is skipped
    }

    @Test func aConversationWithAnUnreadableLedgerStillLoads() throws {
        let json = #"{"items":[],"messages":[{"role":"user","content":"oi","toolCalls":[]}],"summary":"texto","summaryCoveredCount":1,"ledger":"lixo","compactions":"x"}"#
        let decoded = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        #expect(decoded.messages.count == 1 && decoded.summary == "texto")
        #expect(decoded.ledger == nil)
        #expect(decoded.compactions == nil)
        // The summary is carried as text.
        #expect(decoded.currentLedger?.legacy == "texto")
    }

    @Test func aConversationSavedBeforeLedgersExistedLoadsAndKeepsItsSummary() throws {
        let json = #"{"items":[],"messages":[],"summary":"Pedidos do usuário:\n- antigo","summaryCoveredCount":4}"#
        let decoded = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        #expect(decoded.ledger == nil && decoded.compactions == nil)
        #expect(decoded.summary?.contains("antigo") == true)
    }

    @Test func theLedgerAndTheCountComeBackWithTheConversation() throws {
        var conversation = Conversation()
        for index in 0..<10 {
            conversation.messages += step(index == 0 ? longRequest : "pedido \(index) do projeto", output: String(repeating: "x", count: 25_000),
                                          reply: longReply)
        }
        _ = conversation.prepareHistory(budget: ContextBudget(tokens: 10_000))
        let again = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        #expect(again.ledger == conversation.ledger && again.ledger != nil)
        #expect(again.compactions == conversation.compactions && (again.compactions ?? 0) >= 1)
    }

    @Test func aRoutineRunStartsWithoutTheLedger() {
        var conversation = Conversation()
        conversation.summary = "algo"
        conversation.ledger = ConversationLedger(legacy: "algo")
        conversation.compactions = 3
        let fresh = conversation.startingRoutineRun(at: .now)
        #expect(fresh.ledger == nil && fresh.compactions == nil && fresh.summary == nil)
    }
}

// MARK: - Through the history

struct LedgerHistoryTests {
    private func longConversation(turns: Int = 10) -> Conversation {
        var conversation = Conversation()
        for index in 0..<turns {
            let request = index == 0 ? longRequest : index == 2 ? "Decisão: a porta será 4711, não mude." : "pedido número \(index) do projeto"
            conversation.messages += step(request, tool: "read_file", arguments: #"{"path":"/p/m\#(index).swift"}"#,
                                          output: String(repeating: "x", count: 25_000), reply: "resposta \(index) " + longReply)
        }
        return conversation
    }

    @Test func compactingKeepsTheLedgerAndTheRenderedSummaryTogether() throws {
        var conversation = longConversation()
        let attempt = conversation.prepareHistory(budget: ContextBudget(tokens: 10_000)).compaction
        let report = try #require(attempt)
        let ledger = try #require(conversation.ledger)
        #expect(conversation.summary == ledger.render())
        #expect(ledger.original == longRequest)
        #expect(report.kind == .turns && report.foldedMessages == conversation.summaryCoveredCount)
        #expect(conversation.compactions == 1)
        #expect((report.tokensAfter ?? .max) < (report.tokensBefore ?? 0))
    }

    @Test func theOriginalRequestAndTheDecisionSurviveManyCompactions() throws {
        var conversation = longConversation()
        let budget = ContextBudget(tokens: 10_000)
        for round in 0..<30 {
            conversation.messages += step("pedido de rodada \(round) para o projeto", output: String(repeating: "y", count: 25_000),
                                          reply: "feito " + longReply)
            let history = conversation.prepareHistory(budget: budget).history
            #expect(history.first?.content.contains("Pedido original: " + longRequest) == true)
        }
        let summary = try #require(conversation.summary)
        #expect(summary.contains("a porta será 4711"))
        #expect(!summary.contains("Resumo anterior"))
        #expect(summary.count <= ContextSummary.maxLength)
        #expect((conversation.compactions ?? 0) > 5)
    }

    @Test func aFitThatFoldsNothingReportsNothingAndKeepsTheLedger() throws {
        var conversation = longConversation()
        _ = conversation.prepareHistory(budget: ContextBudget(tokens: 10_000))
        let ledger = conversation.ledger
        let count = conversation.compactions
        let again = conversation.prepareHistory(budget: ContextBudget(tokens: 10_000))
        #expect(again.compaction == nil && !again.firstCompaction)
        #expect(conversation.ledger == ledger && conversation.compactions == count)
    }

    @Test func aShortConversationHasNoLedger() {
        var conversation = Conversation()
        conversation.messages = step("oi")
        let prepared = conversation.prepareHistory(budget: .fallback)
        #expect(prepared.compaction == nil && conversation.ledger == nil && conversation.compactions == nil)
    }

    @Test func aSummaryFromAnEarlierVersionIsExtendedFromItsText() throws {
        var conversation = longConversation()
        conversation.summary = "Pedidos do usuário:\n- trabalho antigo sobre o Atlas"
        conversation.summaryCoveredCount = 0
        _ = conversation.prepareHistory(budget: ContextBudget(tokens: 10_000))
        let summary = try #require(conversation.summary)
        #expect(summary.contains("trabalho antigo sobre o Atlas"))
        #expect(conversation.ledger?.legacy?.contains("trabalho antigo") == true)
        #expect(summary.components(separatedBy: "Resumo anterior").count == 2)
    }

    @Test func theEngineExtendsTheConversationsLedgerInsteadOfItsText() throws {
        var conversation = longConversation()
        let history = conversation.prepareHistory(budget: ContextBudget(tokens: 10_000)).history
        let saved = try #require(conversation.ledger)
        // Another fit over the history that begins with the pair, given the ledger, extends it (no legacy text).
        let more = (0..<4).flatMap { step("pedido extra \($0) do projeto", output: String(repeating: "z", count: 25_000), reply: longReply) }
        let window = ContextWindow.fit(history + more, budget: ContextBudget(tokens: 10_000), ledger: saved)
        let extended = try #require(window.ledger)
        #expect(extended.legacy == nil && extended.original == longRequest)
        #expect(extended.foldedMessages > saved.foldedMessages)
        #expect(window.summary == extended.render())
    }
}

// MARK: - Manual compaction

struct ManualCompactionTests {
    private func conversation(turns: Int, output: Int = 8_000) -> Conversation {
        var conversation = Conversation()
        for index in 0..<turns {
            let request = index == 0 ? longRequest : index == 2 ? "Decisão: a porta será 4711, não mude." : "pedido número \(index) do projeto"
            conversation.messages += step(request, tool: "read_file", arguments: #"{"path":"/p/m\#(index).swift"}"#,
                                          output: String(repeating: "x", count: output), reply: "resposta \(index)")
        }
        return conversation
    }

    @Test func itShrinksTheHistoryBelowTheLowWaterMarkAndTellsHowMuch() throws {
        var conversation = conversation(turns: 24)
        let budget = ContextBudget(tokens: 20_000)   // 70,000 characters; the conversation holds about 24 × 4,000 after shortening
        // What the history takes now, as the context meter says.
        let before = conversation.contextFill(budget: budget).historyTokens
        #expect(Double(before) > Double(budget.tokens) * ContextMeter.compactingShare)
        let attempt = conversation.compact(budget: budget)
        let report = try #require(attempt)
        #expect(report.kind == .manual)
        let after = try #require(report.tokensAfter), reported = try #require(report.tokensBefore)
        #expect(reported == before)
        #expect(after < reported)
        // Down to the manual mark, the summary included.
        #expect(Double(after) <= Double(budget.tokens) * ContextMeter.compactingShare)
        #expect(conversation.compactions == 1)
        #expect(conversation.summary?.contains("Pedido original: " + longRequest) == true)
        // The next ordinary request carries what the report said.
        let next = conversation.prepareHistory(budget: budget)
        #expect(next.compaction == nil)
        #expect(ContextBudget.tokens(forCharacters: next.history.reduce(0) { $0 + $1.contextCharacters }) == after)
    }

    @Test func aConversationUnderTheMarkStillShrinksToHalf() throws {
        var conversation = conversation(turns: 8, output: 300)
        let budget = ContextBudget(modelWindow: 128_000)
        let attempt = conversation.compact(budget: budget)
        let report = try #require(attempt)
        let before = try #require(report.tokensBefore), after = try #require(report.tokensAfter)
        #expect(Double(after) <= Double(before) * 0.6)
        #expect(report.foldedMessages >= 8)
    }

    @Test func theFocusLandsInTheSummaryAndStaysThroughLaterCompactions() throws {
        var conversation = conversation(turns: 24)
        let budget = ContextBudget(tokens: 20_000)
        let attempt = conversation.compact(budget: budget, focus: "  o   módulo\nde login  ")
        _ = try #require(attempt)
        #expect(conversation.summary?.contains("Dar atenção a: o módulo de login") == true)
        #expect(conversation.ledger?.focus == "o módulo de login")
        for round in 0..<10 { conversation.messages += step("pedido de rodada \(round) do projeto", output: String(repeating: "y", count: 20_000)) }
        _ = conversation.prepareHistory(budget: budget)
        #expect(conversation.summary?.contains("Dar atenção a: o módulo de login") == true)
        // A new focus replaces it; none given keeps it.
        _ = conversation.compact(budget: budget, focus: "os testes")
        #expect(conversation.ledger?.focus == "os testes")
        conversation.messages += (0..<6).flatMap { step("mais um pedido \($0) do projeto", output: String(repeating: "w", count: 20_000)) }
        _ = conversation.compact(budget: budget)
        #expect(conversation.ledger?.focus == "os testes")
    }

    @Test func aLongFocusIsClippedAndABlankOneIgnored() throws {
        var conversation = conversation(turns: 24)
        let attempt = conversation.compact(budget: ContextBudget(tokens: 20_000), focus: String(repeating: "foco ", count: 200))
        _ = try #require(attempt)
        #expect((conversation.ledger?.focus?.count ?? .max) <= ConversationLedger.focusLimit + 1)
        var other = self.conversation(turns: 24)
        let blank = other.compact(budget: ContextBudget(tokens: 20_000), focus: "   ")
        _ = try #require(blank)
        #expect(other.ledger?.focus == nil)
    }

    @Test func aSingleTurnHasNothingToCompact() {
        var conversation = Conversation()
        conversation.messages = step(longRequest, output: String(repeating: "x", count: 50_000))
        #expect(conversation.compact(budget: ContextBudget(tokens: 20_000)) == nil)
        #expect(conversation.summary == nil && conversation.ledger == nil && conversation.compactions == nil)
    }

    @Test func compactingTwiceInARowTheSecondTimeFindsLittleOrNothing() throws {
        var conversation = conversation(turns: 24)
        let budget = ContextBudget(tokens: 20_000)
        let attempt = conversation.compact(budget: budget)
        _ = try #require(attempt)
        let covered = conversation.summaryCoveredCount
        _ = conversation.compact(budget: budget)
        // Never past the last turn, never backwards.
        #expect((conversation.summaryCoveredCount ?? 0) >= (covered ?? 0))
        #expect((conversation.summaryCoveredCount ?? 0) < conversation.messages.count)
        let history = conversation.prepareHistory(budget: budget).history
        #expect(history.last?.content == "resposta 23")
    }

}

// MARK: - Reports and notices

struct CompactionReportTests {
    @Test func tokenNumbersAreShortAndInPortuguese() {
        #expect(CompactionReport.tokenText(0) == "0")
        #expect(CompactionReport.tokenText(850) == "850")
        #expect(CompactionReport.tokenText(1_000) == "1 mil")
        #expect(CompactionReport.tokenText(1_240) == "1,2 mil")
        #expect(CompactionReport.tokenText(9_960) == "10 mil")
        #expect(CompactionReport.tokenText(58_400) == "58 mil")
        #expect(CompactionReport.tokenText(-5) == "0")
    }

    @Test func aFoldOfTurnsSaysHowManyMessagesAndHowManyTokens() {
        let report = CompactionReport(kind: .turns, foldedMessages: 42, tokensBefore: 58_400, tokensAfter: 19_100)
        #expect(report.notice == "Compactei a conversa: 42 mensagens antigas viraram um resumo (≈ 58 mil → 19 mil tokens).")
        #expect(CompactionReport(kind: .manual, foldedMessages: 1, tokensBefore: 900, tokensAfter: 500).notice
            == "Compactei a conversa: 1 mensagem antiga virou um resumo (≈ 900 → 500 tokens).")
        #expect(CompactionReport(kind: .manual, foldedMessages: 3, tokensBefore: nil, tokensAfter: nil).notice
            == "Compactei a conversa: 3 mensagens antigas viraram um resumo.")
    }

    @Test func aFoldCountsYourRequestsWhenItKnowsThem() {
        var report = CompactionReport(kind: .turns, foldedMessages: 40, tokensBefore: 58_400, tokensAfter: 19_100)
        report.foldedRequests = 5
        #expect(report.notice == "Compactei a conversa: os 5 primeiros pedidos viraram um resumo (≈ 58 mil → 19 mil tokens).")
        report.foldedRequests = 1
        #expect(report.notice == "Compactei a conversa: o primeiro pedido virou um resumo (≈ 58 mil → 19 mil tokens).")
    }

    @Test func aFoldOfStepsSaysItIsAboutThisRequest() {
        let report = CompactionReport(kind: .steps, foldedMessages: 18, tokensBefore: 60_000, tokensAfter: 40_000)
        #expect(report.notice == "Neste pedido, resumi os 18 primeiros passos para caber no modelo (≈ 60 mil → 40 mil tokens).")
        #expect(CompactionReport(kind: .steps, foldedMessages: 1, tokensBefore: nil, tokensAfter: nil).notice
            == "Neste pedido, resumi o primeiro passo para caber no modelo.")
    }

    @Test func theSlashCommandIsParsedWithItsFocus() {
        #expect(CompactionCommand.parse("/compactar") == .some(nil))
        #expect(CompactionCommand.parse("  /compactar  ") == .some(nil))
        #expect(CompactionCommand.parse("/compactar o login e os testes") == .some("o login e os testes"))
        #expect(CompactionCommand.parse("/COMPACTAR foco") == .some("foco"))
        #expect(CompactionCommand.parse("/compactarr") == nil)
        #expect(CompactionCommand.parse("compactar") == nil)
        #expect(CompactionCommand.parse("por favor /compactar") == nil)
    }
}

// MARK: - Announcements inside a turn

/// The engine fits the window again before every model call; `AgentEngine.Announced` reports each fold once.
struct InTurnAnnouncementTests {
    /// Ten turns of four messages each, as the engine's fit takes them (no system message).
    private let input: [ChatMessage] = (0..<10).flatMap { step("pedido \($0) do projeto") }

    /// A window whose estimate says 70,000 characters became 35,000 (20 thousand and 10 thousand tokens).
    private func window(steps: Int = 0) -> ContextWindow {
        ContextWindow(messages: [.user(String(repeating: "a", count: 35_000 - 16))], droppedCount: 0, summary: nil,
                      skippedSteps: steps, charactersBefore: 70_000)
    }

    private func cut(covered: Int, summary: String? = nil) -> ContextCut {
        var cut = ContextCut(summary: summary ?? (covered > 0 ? "resumo \(covered)" : nil))
        cut.covered = covered
        return cut
    }

    @Test func aFoldIsReportedOnceEvenThoughEveryStepFitsAgain() {
        var announced = AgentEngine.Announced()
        #expect(announced.reports(after: window(), cut: cut(covered: 0), input: input[...]).isEmpty)
        let first = announced.reports(after: window(), cut: cut(covered: 8), input: input[...])
        #expect(first.count == 1 && first[0].kind == .turns && first[0].foldedMessages == 8)
        #expect(first[0].fold?.summary == "resumo 8" && first[0].fold?.turns == 2)
        #expect(first[0].tokensBefore == 20_000 && first[0].tokensAfter == 10_000)
        for _ in 0..<5 { #expect(announced.reports(after: window(), cut: cut(covered: 8), input: input[...]).isEmpty) }
    }

    @Test func moreTurnsFoldingLaterIsReportedAsTheDifference() {
        var announced = AgentEngine.Announced()
        _ = announced.reports(after: window(), cut: cut(covered: 8), input: input[...])
        let more = announced.reports(after: window(), cut: cut(covered: 20), input: input[...])
        #expect(more.count == 1 && more[0].foldedMessages == 12 && more[0].fold?.turns == 3)
        #expect(more[0].fold?.summary == "resumo 20")
    }

    @Test func aSummaryPairTheHistoryStartsWithIsNotCountedAgain() {
        var announced = AgentEngine.Announced()
        let withPair = ContextSummary.pair("Pedido original: algo") + input
        let reports = announced.reports(after: window(), cut: cut(covered: 2 + 8), input: withPair[...])
        #expect(reports.first?.foldedMessages == 8 && reports.first?.fold?.turns == 2)
    }

    @Test func stepsSetAsideAreAnnouncedOncePerTurnAndKeepNothing() {
        var announced = AgentEngine.Announced()
        let first = announced.reports(after: window(steps: 5), cut: cut(covered: 0), input: input[...])
        #expect(first.count == 1 && first[0].kind == .steps && first[0].foldedMessages == 5 && first[0].fold == nil)
        #expect(announced.reports(after: window(steps: 9), cut: cut(covered: 0), input: input[...]).isEmpty)
    }

    @Test func aTurnThatBothFoldsTurnsAndSetsStepsAsideReportsBoth() {
        var announced = AgentEngine.Announced()
        let reports = announced.reports(after: window(steps: 3), cut: cut(covered: 4), input: input[...])
        #expect(reports.map(\.kind) == [.turns, .steps])
    }
}

// MARK: - A summary whose ledger was lost

struct LedgerRereadTests {
    private func compacted() -> Conversation {
        var conversation = Conversation()
        for index in 0..<10 {
            let request = index == 0 ? longRequest : index == 2 ? "Decisão: a porta será 4711, não mude." : "pedido \(index) do projeto"
            conversation.messages += step(request, tool: "write_file", arguments: #"{"path":"/p/m\#(index).swift"}"#,
                                          output: String(repeating: "x", count: 25_000), reply: longReply)
        }
        _ = conversation.prepareHistory(budget: ContextBudget(tokens: 10_000))
        return conversation
    }

    @Test func aRenderedSummaryIsReadBackIntoItsSections() throws {
        var ledger = ledger(of: step(longRequest, tool: "edit_file", arguments: #"{"path":"/p/a.swift"}"#)
                            + step("Decisão: porta 4711, não mude.", tool: "read_file", arguments: #"{"path":"/p/b.swift"}"#)
                            + step("agora rode os testes do módulo", tool: "run_command", arguments: #"{"command":"swift test"}"#,
                                   output: "falhou", isError: true, reply: "Quer que eu corrija?"))
        ledger.focus = "o login"
        let read = ConversationLedger(legacy: ledger.render())
        #expect(read.original == longRequest)
        #expect(read.legacy == nil)
        #expect(read.focus == "o login")
        #expect(read.entries.contains(.init(text: "porta 4711, não mude.", isDecision: true)))
        #expect(read.changed == ["/p/a.swift"] && read.read == ["/p/b.swift"])
        #expect(read.failures.count == 1)
        // The text it renders again is the same.
        #expect(read.render() == ledger.render())
    }

    @Test func anOlderSummaryIsStillCarriedAsText() {
        let old = "Pedidos do usuário:\n- Construa o app Atlas com SQLite. NUNCA use a porta 80\nÚltima resposta do assistente: pronto"
        let read = ConversationLedger(legacy: old)
        #expect(read.legacy != nil && read.original == "Construa o app Atlas com SQLite. NUNCA use a porta 80")
        #expect(ConversationLedger(legacy: "Última resposta do assistente: pronto").legacy != nil)
    }

    /// A version without ledgers saves the conversation again without the key (or the saved ledger is unreadable).
    @Test(arguments: [false, true])
    func aSummarySavedWithoutItsLedgerKeepsTheOriginalRequestPinned(unreadable: Bool) throws {
        let conversation = compacted()
        let summary = try #require(conversation.summary)
        #expect(summary.hasPrefix("Pedido original: " + longRequest))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(conversation)) as? [String: Any])
        object["ledger"] = unreadable ? "lixo" : nil
        var reopened = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(reopened.ledger == nil && reopened.summary == summary)
        #expect(reopened.currentLedger?.original == longRequest)

        // More turns, and the next folds: the request stays pinned, said once, with the decision and nothing nested.
        for index in 10..<30 {
            reopened.messages += step("pedido \(index) do projeto", tool: "write_file", arguments: #"{"path":"/p/m\#(index).swift"}"#,
                                      output: String(repeating: "x", count: 25_000), reply: longReply)
            _ = reopened.prepareHistory(budget: ContextBudget(tokens: 10_000))
        }
        let text = try #require(reopened.summary)
        #expect(text != summary)
        #expect(text.hasPrefix("Pedido original: " + longRequest))
        #expect(text.components(separatedBy: "Pedido original").count == 2)
        #expect(text.contains("decisão: a porta será 4711, não mude."))
        #expect(!text.contains("Resumo anterior"))
        #expect(reopened.ledger?.original == longRequest)
    }
}

// MARK: - Calls that never ran

struct LedgerUnrunCallTests {
    private let neverWritten = "/x/nunca-gravado.txt"

    /// Turn 1 fails to write the file; turn 2 tries again and is stopped before the call answers.
    private func interrupted() -> [ChatMessage] {
        let arguments = #"{"path":"/x/nunca-gravado.txt"}"#
        return step(longRequest, tool: "write_file", arguments: arguments, output: "Error: permission denied", isError: true)
            + [.user("tente gravar de novo"), assistant(calls: [call("w2", "write_file", arguments)])]
    }

    @Test func aMadeUpAnswerToAStoppedCallIsNoWrite() {
        let answered = interrupted().answeringDanglingToolCalls()
        #expect(answered.contains { $0.role == .tool && $0.content == ChatMessage.interruptedResult })
        let ledger = ledger(of: answered)
        #expect(!ledger.changed.contains(neverWritten))
        // The failure before it stands: the action never worked.
        #expect(ledger.failures.contains { $0.text.contains("write_file") })
        // Folded from the raw conversation (no made-up answer) it is the same.
        #expect(ledger.changed == ConversationLedger().absorbing(interrupted()).changed)
        #expect(ledger.failures == ConversationLedger().absorbing(interrupted()).failures)
    }

    @Test func aFoldInsideATurnDoesNotRecordTheStoppedCallAsDone() throws {
        // What the engine is handed: the prepared history (every call answered), more turns, and the new message.
        var input = interrupted().answeringDanglingToolCalls()
        for index in 0..<8 { input += step("pedido \(index) do projeto", output: String(repeating: "x", count: 25_000), reply: longReply) }
        input.append(.user("e agora?"))
        var cut = ContextCut()
        let window = ContextWindow.fit(input, budget: ContextBudget(tokens: 10_000), cut: &cut)
        let ledger = try #require(window.ledger)
        #expect(ledger.foldedMessages >= interrupted().count + 1)
        #expect(!ledger.changed.contains(neverWritten))
        #expect(ledger.failures.contains { $0.text.contains("write_file") })
    }

    @Test func aRefusalIsStillAFailure() {
        let ledger = ledger(of: step(longRequest, tool: "trash", arguments: #"{"path":"/p/a"}"#,
                                     output: PermissionPolicy.userDenial, isError: true))
        #expect(ledger.failures.first?.text.contains("você negou esta ação") == true)
        #expect(ledger.changed.isEmpty)
    }
}
