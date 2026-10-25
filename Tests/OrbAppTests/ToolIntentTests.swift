import Foundation
import Testing
@testable import Orb

// What each action of the Orb is for, in words a person watching can read: the model's description in the infinitive, said
// in the gerund while it runs and in the preterite after; the gist of a command that came with none; and the lines that
// say it (the tool's, the folded run's, the working line's).

struct ToolIntentTests {
    // MARK: Conjugation

    @Test func theGerundIsRegularAndOnlyTheFirstWordChanges() {
        #expect(ToolIntent.gerund("Conferir se a vaga do Marcus já saiu") == "Conferindo se a vaga do Marcus já saiu")
        #expect(ToolIntent.gerund("Rodar os testes") == "Rodando os testes")
        #expect(ToolIntent.gerund("Ler o histórico dos três chats") == "Lendo o histórico dos três chats")
        #expect(ToolIntent.gerund("Fazer um backup") == "Fazendo um backup")
        #expect(ToolIntent.gerund("Ver a agenda") == "Vendo a agenda")
        #expect(ToolIntent.gerund("Sair da conta") == "Saindo da conta")
        #expect(ToolIntent.gerund("Conferir") == "Conferindo")
    }

    @Test func thePutFamilyHasItsOwnGerund() {
        #expect(ToolIntent.gerund("Pôr a pasta no lugar") == "Pondo a pasta no lugar")
        #expect(ToolIntent.gerund("Por o arquivo na pasta") == "Pondo o arquivo na pasta")
        #expect(ToolIntent.gerund("Compor o relatório") == "Compondo o relatório")
        #expect(ToolIntent.gerund("Repor o estoque") == "Repondo o estoque")
        #expect(ToolIntent.gerund("Propor um plano") == "Propondo um plano")
    }

    @Test func thePretéritoIsRegularByEnding() {
        #expect(ToolIntent.past("Conferir se a vaga do Marcus já saiu") == "Conferiu se a vaga do Marcus já saiu")
        #expect(ToolIntent.past("Instalar as dependências") == "Instalou as dependências")
        #expect(ToolIntent.past("Mover os arquivos") == "Moveu os arquivos")
        #expect(ToolIntent.past("Ler o histórico dos três chats") == "Leu o histórico dos três chats")
        #expect(ToolIntent.past("Abrir a página") == "Abriu a página")
        #expect(ToolIntent.past("Sair da conta") == "Saiu da conta")
        #expect(ToolIntent.past("Conferir") == "Conferiu")
    }

    @Test func theIrregularVerbsComeFromTheTable() {
        let table: [(String, String)] = [
            ("Fazer", "Fez"), ("Desfazer", "Desfez"), ("Refazer", "Refez"), ("Ver", "Viu"), ("Rever", "Reviu"), ("Prever", "Previu"),
            ("Ter", "Teve"), ("Manter", "Manteve"), ("Obter", "Obteve"), ("Conter", "Conteve"), ("Deter", "Deteve"),
            ("Pôr", "Pôs"), ("Por", "Pôs"), ("Compor", "Compôs"), ("Repor", "Repôs"), ("Propor", "Propôs"), ("Supor", "Supôs"),
            ("Dispor", "Dispôs"), ("Trazer", "Trouxe"), ("Dizer", "Disse"), ("Ir", "Foi"), ("Vir", "Veio"), ("Intervir", "Interveio"),
            ("Ser", "Foi"), ("Estar", "Esteve"), ("Poder", "Pôde"), ("Querer", "Quis"), ("Saber", "Soube"), ("Dar", "Deu"),
            ("Haver", "Houve"), ("Caber", "Coube"),
        ]
        for (infinitive, preterite) in table {
            #expect(ToolIntent.past("\(infinitive) o arquivo") == "\(preterite) o arquivo", "\(infinitive)")
        }
    }

    @Test func theCapitalOfTheFirstWordIsKept() {
        #expect(ToolIntent.past("conferir a vaga") == "conferiu a vaga")
        #expect(ToolIntent.gerund("conferir a vaga") == "conferindo a vaga")
        #expect(ToolIntent.past("Conferir a vaga") == "Conferiu a vaga")
        // In the middle of a sentence the verb is lower case; a name or an acronym keeps its capital.
        #expect(ToolIntent.pastInSentence("Conferir a API") == "conferiu a API")
        #expect(ToolIntent.pastInSentence("API caiu") == "API caiu")
        #expect(ToolIntent.pastOpening("conferir a vaga") == "Conferiu a vaga")
    }

    @Test func theVerbsJoinedToTheFirstTakeItsFormToo() {
        #expect(ToolIntent.past("Listar modelos e ver uso do send.py") == "Listou modelos e viu uso do send.py")
        #expect(ToolIntent.gerund("Listar modelos e ver uso do send.py") == "Listando modelos e vendo uso do send.py")
        #expect(ToolIntent.past("Baixar áudio, transcrever e responder") == "Baixou áudio, transcreveu e respondeu")
        #expect(ToolIntent.past("Ler o pedido, conferir, enviar") == "Leu o pedido, conferiu, enviou")
        #expect(ToolIntent.pastInSentence("Ler A e abrir B") == "leu A e abriu B")
        // Not a verb after " e ": a number, a name, a noun that ends like one, the preposition "por".
        #expect(ToolIntent.past("Enviar Guilherme e 5 mensagens vazias (reenvio)") == "Enviou Guilherme e 5 mensagens vazias (reenvio)")
        #expect(ToolIntent.past("Abrir Finder e Terminal") == "Abriu Finder e Terminal")
        #expect(ToolIntent.past("Reiniciar o nginx e docker") == "Reiniciou o nginx e docker")
        #expect(ToolIntent.past("Comparar preço e lugar") == "Comparou preço e lugar")
        #expect(ToolIntent.past("Conferir pedidos e por fim enviar") == "Conferiu pedidos e por fim enviar")
        // Only after a first word that was a verb.
        #expect(ToolIntent.past("Testes de login e rodar build") == "Testes de login e rodar build")
        #expect(ToolIntent.past("Conferir, depois ler e enviar") == "Conferir, depois ler e enviar")
    }

    @Test func aFirstWordThatIsNotAnInfinitiveIsShownAsItCame() {
        for text in ["Conferindo a vaga do Marcus", "Conferiu a vaga do Marcus", "Check the build", "Clear the cache", "Clear cache",
                     "Filter the results", "A vaga do Marcus saiu", "Mar de dúvidas", "Por que a build falhou", "Por causa do erro",
                     "Qualquer coisa", "Rodando", "Testes novos", "", "   "] {
            #expect(ToolIntent.gerund(text) == text, "\(text)")
            #expect(ToolIntent.past(text) == text, "\(text)")
        }
        // A word with punctuation is not a clean infinitive either.
        #expect(ToolIntent.past("Conferir, depois ler") == "Conferir, depois ler")
        #expect(ToolIntent.past("Conferir-se de tudo") == "Conferir-se de tudo")
    }

    @Test func theDescriptionIsOneShortLineWithoutAFinalPeriod() {
        #expect(ToolIntent.normalize("  Ler o histórico\n dos três chats.  ") == "Ler o histórico dos três chats")
        #expect(ToolIntent.normalize("Conferir a vaga...") == "Conferir a vaga")
        #expect(ToolIntent.normalize("") == nil)
        #expect(ToolIntent.normalize("  \n ") == nil)
        #expect(ToolIntent.normalize(".") == nil)
        #expect(ToolIntent.normalize(nil) == nil)
        let long = ToolIntent.normalize(String(repeating: "conferir a vaga ", count: 20)) ?? ""
        #expect(long.count <= ToolIntent.limit + 1 && long.hasSuffix("…") && !long.contains("\n"))
        #expect(long.hasSuffix("vaga…"), "cut on a word")
    }

    // MARK: A command with no description

    private func gist(_ command: String) -> String? { CommandGist.gist(of: command)?.text }

    @Test func aCommandIsItsProgramAndItsFirstMeaningfulArgument() {
        #expect(gist("swift build --jobs 6") == "swift build")
        #expect(gist("ls -la ~/Downloads") == "ls Downloads")
        #expect(gist("grep -rn TODO Sources") == "grep TODO")
        #expect(gist("make") == "make")
        #expect(gist("git -C /Users/x/Orb status") == "git status")
        #expect(gist("cat /Users/x/Projetos/Orb/README.md | head -20") == "cat README.md")
        #expect(gist("curl -s https://api.github.com/repos/x") == "curl api.github.com")
        #expect(gist("npm run dev") == "npm run dev")
        #expect(gist("python3 script.py --fast") == "python3 script.py")
        #expect(gist("python3 -m pytest tests") == "python3 -m pytest")
        #expect(gist("/opt/homebrew/bin/brew install node") == "brew install")
        #expect(gist("echo \"oi mundo\" > saida.txt") == "echo oi mundo")
    }

    @Test func stepsThatOnlyPrepareAreSkipped() {
        #expect(gist("cd ~/Projetos/Orb && swift test --filter Suite26") == "swift test")
        #expect(gist("cd /tmp; ls -la") == "ls")
        #expect(gist("export FOO=1 && export BAR=2 && npm run dev") == "npm run dev")
        #expect(gist("FOO=bar BAZ=1 make test") == "make test")
        #expect(gist("sudo apt install wget") == "apt install")
        #expect(gist("sudo -u deploy systemctl restart app") == "systemctl restart")
        #expect(gist("# instala tudo\n\nbrew install node") == "brew install")
        #expect(gist("cd /tmp") == nil, "nothing but the preparation")
        #expect(gist("") == nil && gist("  \n\n ") == nil && gist("# só um comentário") == nil)
        // The note a command run elsewhere carries is not part of it.
        #expect(gist("ls -la\n\nem ~/Projetos") == "ls")
    }

    @Test func aScriptOfAnInterpreterIsNamedByItsLanguage() {
        let python = CommandGist.gist(of: "python3 - <<'EOF'\nimport json\nprint(1)\nEOF")
        #expect(python == CommandGist.Gist(text: "um script Python", isScript: true))
        #expect(gist("cd ~/x && python3 -c \"print(1)\"") == "um script Python")
        #expect(gist("python3.12 - <<EOF\nprint(1)\nEOF") == "um script Python")
        #expect(gist("node -e 'console.log(1)'") == "um script Node")
        #expect(gist("ruby -e 'puts 1'") == "um script Ruby")
        #expect(gist("bash -c 'ls | wc -l'") == "um script shell")
        #expect(gist("sh <<'EOF'\nls\nEOF") == "um script shell")
        #expect(CommandGist.gist(of: "swift build")?.isScript == false)
    }

    // MARK: The line of a tool

    private func shell(_ detail: String, _ state: ToolCall.State = .done, intent: String? = nil,
                       title: String = "Rodando no Terminal") -> ToolCall {
        ToolCall(kind: .shell, title: title, detail: detail, state: state, intent: intent)
    }

    @Test func aDescribedActionIsSaidInTheGerundWhileItRunsAndInThePreteriteAfter() {
        let running = shell("python3 - <<'EOF'", .running, intent: "Conferir se a vaga do Marcus já saiu").lineWords
        #expect(running.main == "Conferindo se a vaga do Marcus já saiu" && running.rest == nil && running.hidesDetail)
        let done = shell("python3 - <<'EOF'", .done, intent: "Conferir se a vaga do Marcus já saiu").lineWords
        #expect(done.main == "Conferiu se a vaga do Marcus já saiu")
        #expect(shell("x", .failed, intent: "Ler o histórico").lineWords.main == "Leu o histórico")
        // The title and the command stay for when the line opens.
        let call = shell("python3 - <<'EOF'", intent: "Ler o histórico")
        #expect(call.hiddenDetail?.title == "Rodando no Terminal" && call.hiddenDetail?.detail == "python3 - <<'EOF'")
    }

    @Test func aCommandWithNoDescriptionIsSaidByTheCommandItself() {
        #expect(shell("swift build --jobs 6").lineWords == ToolCall.LineWords(main: "Rodou", code: "swift build --jobs 6", hidesDetail: true))
        #expect(shell("swift build", .running).lineWords.main == "Rodando")
        #expect(shell("python3.14 historico.py --lote 3", .failed).lineWords
            == ToolCall.LineWords(main: "Falhou", code: "python3.14 historico.py --lote 3", hidesDetail: true))
        // Two runs that differ only at the end read apart: the whole command is on the line.
        #expect(shell("ls ~/Downloads").lineWords.code == "ls ~/Downloads")
        let background = shell("npm run dev", .running, title: "Rodando em segundo plano").lineWords
        #expect(background == ToolCall.LineWords(main: "Rodando", code: "npm run dev", rest: "em segundo plano", hidesDetail: true))
        // The folder the tool noted is not part of the command.
        #expect(shell("make\n\nem ~/Projetos/app").lineWords.code == "make")
        #expect(shell("").lineWords == ToolCall.LineWords(main: "Rodou no Terminal", hidesDetail: false))
    }

    @Test func aScriptSaysWhatItIsAndHowLongItIs() {
        let script = shell("python3 - <<'EOF'\nimport json\nprint(1)\nEOF").lineWords
        #expect(script.main == "Rodou um script Python")
        #expect(script.code == "python3 - <<'EOF' … 4 linhas")
        #expect(shell("python3 - <<'EOF'\nprint(1)\nEOF", .running).lineWords.main == "Rodando um script Python")
        // A comment first: the line shows the first line that runs, and counts them all.
        #expect(ShownCommand.line(of: "# limpa\n\nrm -rf build") == "rm -rf build … 2 linhas")
        #expect(ShownCommand.line(of: "  \n ") == nil)
    }

    @Test func theFolderACommandRanInIsReadBackFromItsDetail() {
        #expect(ShownCommand.split("swift build\n\nem ~/Projetos/app") == ("swift build", "~/Projetos/app"))
        #expect(ShownCommand.split("swift build").folder == nil)
        // Only the tool's own note, at the end and on one line: a script with a blank line and "em" is left whole.
        let script = "echo a\n\nem breve\necho b"
        #expect(ShownCommand.split(script) == (script, nil))
    }

    @Test func otherToolsSayTheirVerbInTheTenseOfTheirState() {
        let read = ToolCall(kind: .file, title: "Lendo arquivo", detail: "/Users/x/README.md", state: .done)
        #expect(read.lineWords == ToolCall.LineWords(main: "Leu", code: "README.md", hidesDetail: true))
        // The whole path is kept for when the line opens.
        #expect(read.hiddenDetail?.detail == "/Users/x/README.md")
        var running = read
        running.state = .running
        #expect(running.lineWords.main == "Lendo")
        var failed = read
        failed.state = .failed
        #expect(failed.lineWords.main == "Falhou ao ler")
        let search = ToolCall(kind: .search, title: "Pesquisando na web", detail: "swiftui shimmer", state: .done)
        #expect(search.lineWords == ToolCall.LineWords(main: "Pesquisou", rest: "“swiftui shimmer”", hidesDetail: false))
        // A title `WorkPhrase` does not know is conjugated whole, with its detail after it.
        let script = ToolCall(kind: .computer, title: "Usando o AppleScript", detail: "tell application \"Mail\"", state: .done)
        #expect(script.lineWords == ToolCall.LineWords(main: "Usou o AppleScript", rest: "tell application \"Mail\"", hidesDetail: false))
        let shot = ToolCall(kind: .computer, title: "Capturando a tela", detail: "", state: .failed)
        #expect(shot.lineWords.main == "Falhou ao capturar a tela")
    }

    @Test func aTitleInTheGerundIsSaidInThePreterite() {
        #expect(ToolIntent.pastOfGerund("Lendo arquivo") == "Leu arquivo")
        #expect(ToolIntent.pastOfGerund("Abrindo a pasta") == "Abriu a pasta")
        #expect(ToolIntent.pastOfGerund("Vendo as ferramentas") == "Viu as ferramentas")
        #expect(ToolIntent.pastOfGerund("Fazendo um backup") == "Fez um backup")
        #expect(ToolIntent.pastOfGerund("Propondo um Orb") == "Propôs um Orb")
        #expect(ToolIntent.pastOfGerund("Falando com Pesquisador") == "Falou com Pesquisador")
        #expect(ToolIntent.pastOfGerund("Planejamento") == "Planejamento", "not a gerund: as it came")
        #expect(ToolIntent.pastOfGerund("Segundo plano") == "Segundo plano")
        #expect(ToolIntent.failedGerund("Gravando arquivo") == "Falhou ao gravar arquivo")
        #expect(ToolIntent.failedGerund("Pondo a mesa") == "Falhou ao pôr a mesa")
        #expect(ToolIntent.failedGerund("Tela") == "Falhou: Tela")
        #expect(PortugueseVerb.infinitive(ofGerund: "lendo") == "ler")
        #expect(PortugueseVerb.infinitive(ofGerund: "indo") == nil, "too short to tell")
        #expect(PortugueseVerb.infinitive(ofGerund: "mundo") == nil)
    }

    // MARK: How a command ended

    @Test func theExitCodeLineAndTheNotesForTheModelLeaveTheOutput() {
        let worked = CommandOutput("Código de saída: 0\nBuild complete!")
        #expect(worked.end == .code(0) && worked.text == "Build complete!")
        #expect(worked.lineNote == nil)
        #expect(worked.endText(failed: false, background: false) == "Concluído")
        let saved = CommandOutput("Código de saída: 1\nTraceback\nErro\n[full output saved at /tmp/x.txt (44 lines, 2 KB); read it with read_file]")
        #expect(saved.text == "Traceback\nErro")
        #expect(saved.lineNote == "código 1")
        #expect(saved.endText(failed: true, background: false) == "Saiu com código 1")
        // The shell's own hint stays out of the code.
        #expect(CommandOutput("Código de saída: 127 (comando não encontrado: confira)\nzsh: x").end == .code(127))
        let killed = CommandOutput("Código de saída: encerrado pelo sinal 15 (SIGTERM)\n(sem saída)")
        #expect(killed.end == .signal("15 (SIGTERM)") && killed.text.isEmpty)
        #expect(killed.endText(failed: true, background: false) == "Encerrado pelo sinal 15 (SIGTERM)")
        let late = CommandOutput("rodando…\n[tempo esgotado após 120 s; o processo foi encerrado. Para comandos longos use x]")
        #expect(late.end == .timedOut && late.text == "rodando…")
        #expect(late.lineNote == "tempo esgotado")
        // No code line (a background start, an older conversation): the text as it is.
        let other = CommandOutput("[O comando continua rodando em segundo plano como o processo j1.]")
        #expect(other.end == nil && other.text.hasPrefix("[O comando"))
        #expect(other.endText(failed: false, background: true) == "Seguiu em segundo plano")
        #expect(other.endText(failed: true, background: false) == "Falhou")
        #expect(CommandOutput("Código de saída: 1\n(sem saída)").endText(failed: false, background: false) == "Saiu com código 1",
                "grep finding nothing: not a failure, but not a plain success either")
    }

    @Test func theToolWritesWhatTheChatReadsBack() {
        // The writer and the reader share the words (`RunCommandTool`, `CommandOutput`).
        #expect(RunCommandTool.folderNote == "\n\nem ")
        #expect(CommandOutput(CommandOutput.exitLead + "2\nx").end == .code(2))
    }

    // MARK: The working line

    @Test func theWorkingLineSaysWhatTheCurrentActionIsFor() {
        let call = shell("python3 - <<'EOF'", .running, intent: "Conferir se a vaga do Marcus já saiu")
        let line = WorkPhrase.line(for: call)
        #expect(line.text == "Conferindo se a vaga do Marcus já saiu", "a sentence: no ellipsis")
        #expect(line.headline == "Conferindo se a vaga do Marcus já saiu")
        #expect(line.isAnnounceable && line.runsCommand && line.shimmers)
        var routine = line
        routine.routine = "Rodada"
        #expect(routine.headline == "Rotina “Rodada” · Conferindo se a vaga do Marcus já saiu")
        // The meter beside it: "Conferindo… · 1 min 19 s · 16 ações".
        #expect(WorkMeter.text(elapsed: "1 min 19 s", actions: 16) == "1 min 19 s · 16 ações")
    }

    @Test func aCommandWithNoDescriptionIsWorkedAtByItsGist() {
        let script = WorkPhrase.line(for: shell("python3 - <<'EOF'\nprint(1)\nEOF", .running))
        #expect(script.text == "Rodando um script Python" && script.headline == "Rodando um script Python" && script.runsCommand)
        let build = WorkPhrase.line(for: shell("cd x && swift build --jobs 6", .running))
        #expect(build.text == "Rodando swift build" && build.headline == "Rodando um comando")
        // Without anything to say about the command it is as before: the verb alone.
        #expect(WorkPhrase.line(for: shell("", .running)).text == "Rodando…")
    }

    // MARK: The folded line

    private func described(_ intent: String?, _ state: ToolCall.State = .done) -> ToolCall { shell("x", state, intent: intent) }

    @Test func theFoldedLineNamesWhatTheActionsWereForInTheOrderTheyHappened() {
        let calls = [described("Ler o histórico dos três chats"), described("Conferir se a vaga do Marcus já saiu"),
                     described(nil), described(nil), described(nil), described(nil)]
        let variants = ToolTally.lineVariants(calls)
        // How many there were is on the hover, not in the words: no "e mais 4" beside "6 ações".
        #expect(variants == ["Leu o histórico dos três chats e conferiu se a vaga do Marcus já saiu",
                             "Leu o histórico dos três chats"])
        #expect(ToolTally.line(calls) == variants[0])
        #expect(ToolTally.countNote(calls) == "6 ações")
    }

    @Test func theFoldedLineNamesAtMostThreeDescriptionsEachOnce() {
        let calls = [described("Ler A"), described("Ler A"), described("Rodar B"), described("Abrir C"), described("Mover D"), described("Ler A")]
        #expect(ToolTally.lineVariants(calls) == ["Leu A, rodou B e abriu C", "Leu A e rodou B", "Leu A"])
        #expect(ToolTally.lineVariants([described("Ler A"), described("Rodar B"), described("Ler A")])
                == ["Leu A e rodou B", "Leu A"])
        #expect(ToolTally.lineVariants([described("Ler A"), described("Ler A")]) == ["Leu A"])
        #expect(ToolTally.countNote([described("Ler A")]) == nil)
    }

    @Test func withoutDescriptionsTheFoldedLineCountsAsBefore() {
        let calls = Array(repeating: shell("ls"), count: 12)
        #expect(ToolTally.lineVariants(calls) == ["Rodou 12 comandos"])
        #expect(ToolTally.countNote(calls) == nil)
        // A run where only some were described names those; the hover counts them all.
        #expect(ToolTally.lineVariants([described(nil), described("Ler A")]) == ["Leu A"])
        #expect(ToolTally.countNote([described(nil), described("Ler A")]) == "2 ações")
    }

    @Test func theWorkOfARequestCountsItsActionsAndLeavesTheDescriptionsToItsLines() {
        let calls = [described("Ler A"), described("Conferir B"), described(nil)]
        #expect(ToolTally.work(calls, seconds: 65) == "Trabalhou por 1 min 05 s · rodou 3 comandos")
        #expect(ToolTally.work([shell("ls")], seconds: 5) == "Trabalhou por 5 s · rodou 1 comando")
    }

    @Test func aStumbleTheOrbGotOverIsQuietAndOneItDidNotIsRed() {
        let failed = described("Ler A", .failed), worked = described("Ler B"), running = described("Ler C", .running)
        #expect(ToolTally.failures([failed, worked]) == ToolTally.Failures(text: "1 com erro", recovered: true))
        #expect(ToolTally.failures([worked, failed]) == ToolTally.Failures(text: "1 com erro", recovered: false))
        #expect(ToolTally.failures([failed, failed, worked]) == ToolTally.Failures(text: "2 com erro", recovered: true))
        #expect(ToolTally.failures([failed, running])?.recovered == true, "it goes on")
        #expect(ToolTally.failures([worked, running]) == nil)
    }

    // MARK: The model and the conversations

    @Test func aConversationFromBeforeOpensWithNoDescription() throws {
        let old = #"{"id":"7B5C9A52-6C5B-4D3B-8E37-0A6B9A6B3E11","kind":"shell","title":"Rodando no Terminal","detail":"ls","state":"done"}"#
        let call = try JSONDecoder().decode(ToolCall.self, from: Data(old.utf8))
        #expect(call.intent == nil && call.detail == "ls" && call.state == .done)
        // And one that has it keeps it, through the saved form.
        var described = call
        described.intent = "Listar a pasta"
        let back = try JSONDecoder().decode(ToolCall.self, from: JSONEncoder().encode(described))
        #expect(back.intent == "Listar a pasta" && back == described)
        // A damaged value is tidied or dropped, never an error.
        let odd = #"{"id":"7B5C9A52-6C5B-4D3B-8E37-0A6B9A6B3E11","kind":"shell","title":"x","detail":"y","intent":"  \n "}"#
        #expect(try JSONDecoder().decode(ToolCall.self, from: Data(odd.utf8)).intent == nil)
        let wrong = #"{"id":"7B5C9A52-6C5B-4D3B-8E37-0A6B9A6B3E11","kind":"shell","title":"x","detail":"y","intent":4}"#
        #expect(try JSONDecoder().decode(ToolCall.self, from: Data(wrong.utf8)).intent == nil)
    }

    @Test func theCommandToolsTakeADescriptionAndNormalizeIt() {
        let command = RunCommandTool()
        #expect(command.spec.parameters["properties"]?["description"]?["type"]?.string == "string")
        #expect(command.spec.parameters["properties"]?["description"]?["description"]?.string?.contains("infinitive") == true)
        #expect(command.spec.parameters["required"] == .array([.string("command")]), "still optional")
        let arguments = JSONValue.object(["command": .string("ls"), "description": .string("  Listar a pasta.\n")])
        #expect(command.intent(arguments) == "Listar a pasta")
        #expect(command.intent(.object(["command": .string("ls"), "background": .bool(true), "description": .string("Subir o servidor")])) == "Subir o servidor")
        #expect(command.intent(.object(["command": .string("ls")])) == nil)
        #expect(AppleScriptTool().intent(.object(["script": .string("x"), "description": .string("Abrir o Mail")])) == "Abrir o Mail")
        #expect(AppleScriptTool().spec.parameters["properties"]?["description"] != nil)
        // A tool that has a `description` of its own for something else (an event, a task) is not read as one.
        #expect(RememberTool().intent(.object(["description": .string("não é isto")])) == nil)
    }

    @Test func theClaudeCodePipeDeclaresTheSameDescription() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orb-intent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("tools.json")
        try ClaudePipeTools.writeDeclarations([RunCommandTool().spec], to: file)
        let declared = try #require(ClaudePipeServer.loadDeclarations(from: file).first)
        #expect(declared["name"]?.string == "run_command")
        #expect(declared["inputSchema"]?["properties"]?["description"]?["type"]?.string == "string")
        #expect(declared["inputSchema"] == RunCommandTool().spec.parameters)
    }
}
