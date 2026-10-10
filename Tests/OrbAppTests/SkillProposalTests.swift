import Foundation
import Testing
@testable import Orb

/// What the Orb may propose as a skill: the check that turns shallow, diary-like or repeated proposals back, the pending
/// proposals and the copy of the Orb's skills in its memory folder, and the two memory tools that use them.
enum SkillSamples {
    /// A proposal that passes: a class of task, four sections, concrete steps and pitfalls.
    static let good = """
        ---
        name: publicar-site
        description: Publica o site em produção com testes antes e conferência depois; use quando pedirem para publicar ou subir o site.
        ---

        ## Quando usar
        Quando a usuária pedir para publicar, subir ou fazer deploy do site, em qualquer branch.

        ## Passos
        1. Rode `swift test --jobs 4` e pare se algum teste falhar.
        2. Confirme que a branch é `main` com `git branch --show-current` e que `git status` está limpo.
        3. Rode `./scripts/deploy.sh --prod` e acompanhe a saída até a linha "Deploy concluído".
        4. Abra a URL de produção e confira a versão no rodapé.

        ## Armadilhas
        - Nunca rode o deploy com arquivos modificados: o script publica a pasta, não o commit.
        - O script lê `.env.production` da pasta atual; rodar de outro lugar publica com as chaves erradas.

        ## Como verificar
        Abra o site e confira se a versão no rodapé é a do último commit (`git rev-parse --short HEAD`).
        """

    /// Wide and padded: sections, sizes and a plausible look, but not one command, file, tool or decision.
    static let generic = """
        ---
        name: tarefas-gerais
        description: Executa qualquer tarefa pedida pela usuária de forma eficiente e com muita qualidade.
        ---

        ## Quando usar
        Sempre que a usuária pedir qualquer coisa, em qualquer situação ou contexto de trabalho, sem exceção alguma.

        ## Passos
        1. Entenda com cuidado e atenção o que a usuária está pedindo antes de começar a trabalhar.
        2. Planeje a melhor forma de executar a tarefa com calma, pensando em todas as possibilidades.
        3. Execute o plano com capricho e dedicação, do início ao fim, sem deixar nada para trás.
        4. Revise o resultado final com cuidado e entregue tudo com clareza para a usuária.

        ## Armadilhas
        - Não faça nada às pressas, porque a pressa costuma gerar erros no resultado entregue.
        - Não esqueça de revisar tudo, porque o descuido prejudica a qualidade final do trabalho.

        ## Como verificar
        Confira se a usuária ficou satisfeita com o resultado que foi entregue por você ao final.
        """

    /// A skill with no terminal in it: a way of writing, with its format and its decisions.
    static let writing = """
        ---
        name: resumo-do-dia
        description: Escreve o resumo da agenda de hoje em três blocos curtos; use quando pedirem o resumo do dia ou da agenda.
        ---

        ## Quando usar
        Quando a usuária pedir o resumo do dia, a agenda de hoje ou "o que tenho pela frente", de manhã ou à tarde.

        ## Passos
        1. Abra com uma linha só: o número de compromissos e o horário do primeiro, no formato "4 compromissos, o primeiro às 9h".
        2. Se houver conflito de horários, abra o bloco "Atenção" com o conflito antes de qualquer outro item; senão, não crie o bloco.
        3. Liste os compromissos em ordem de horário, um por linha: hora, título e, entre parênteses, quem participa.
        4. Feche com "Livre:" e os intervalos de mais de 1 hora, para a usuária ver onde cabe uma tarefa.

        ## Armadilhas
        - Não use a cor #333 nem negrito nos títulos: o resumo vai para um app que mostra texto simples e os símbolos aparecem.
        - Nunca invente participantes: a agenda é a fonte, e um nome errado leva a usuária a uma reunião que não existe.

        ## Como verificar
        Conte as linhas de compromissos e confira se o número da primeira linha é o mesmo, e se a ordem de horários não volta.
        """

    /// A skill the Orb already has (the digest of its instructions), for the proposals that repeat it.
    static let npmDigest = SkillDigest(
        slug: "publicar-pacote-npm", name: "Publicar pacote npm", summary: "Publica uma nova versão do pacote no registro npm depois dos testes.",
        instructions: """
            ## Quando usar
            Quando a usuária pedir para publicar o pacote no npm.

            ## Passos
            1. Rode `npm test` e pare se algo falhar.
            2. Suba a versão com `npm version patch`.
            3. Publique com `npm publish --access public`.
            4. Envie a tag com `git push --follow-tags`.
            5. Confira com `npm view meu-pacote version`.

            ## Armadilhas
            - Nunca publique com a árvore suja: o npm leva tudo o que está na pasta.
            - O registro não deixa republicar a mesma versão, por isso a versão sobe antes.

            ## Como verificar
            `npm view meu-pacote version` mostra a versão nova.
            """, improvable: true)

    /// The same procedure in other words and another name: only the commands are the same.
    static let npmRepeated = """
        ---
        name: lancar-versao-npm
        description: Lança uma versão nova da biblioteca para quem a instala; use quando pedirem um lançamento da lib.
        ---

        ## Quando usar
        Sempre que a usuária pedir um lançamento da biblioteca para o mundo, seja correção ou novidade pequena.

        ## Passos
        1. Execute `npm test` no projeto e interrompa o lançamento se qualquer teste quebrar.
        2. Aumente o número da versão: `npm version minor` cria o commit e a tag.
        3. Disponibilize com `npm publish --access public` e espere a mensagem de sucesso.
        4. Empurre os commits e a tag: `git push --follow-tags`.

        ## Armadilhas
        - Não lance com alterações soltas na pasta: o registro recebe tudo, inclusive o que não foi commitado.
        - Um número de versão não pode ser usado duas vezes, então aumente antes de disponibilizar.

        ## Como verificar
        Rode `npm view minha-lib version` e compare com o número que acabou de subir.
        """

    /// `good` with `old` replaced by `new`.
    static func changed(_ old: String, _ new: String) -> String { good.replacingOccurrences(of: old, with: new) }
}

struct SkillProposalValidationTests {
    private func problems(_ text: String, among skills: [SkillDigest] = []) -> [String] {
        if case .failure(let refusal) = SkillProposal.validate(text, among: skills) { refusal.problems } else { [] }
    }

    private func refuses(_ text: String, among skills: [SkillDigest] = [], mentioning word: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let found = problems(text, among: skills)
        #expect(found.contains { $0.contains(word) }, "\(found)", sourceLocation: sourceLocation)
    }

    @Test func aSkillOfTheClassOfTaskWithItsFourSectionsIsAccepted() throws {
        let proposal = try SkillProposal.validate(SkillSamples.good, among: []).get()
        #expect(proposal.slug == "publicar-site")
        #expect(proposal.name == "Publicar site")
        #expect(proposal.summary.hasPrefix("Publica o site em produção"))
        #expect(proposal.instructions.hasPrefix("## Quando usar") && proposal.instructions.contains("./scripts/deploy.sh"))
        #expect(!proposal.instructions.contains("name: publicar-site"))
    }

    @Test func englishTitlesDoAsWell() {
        let english = SkillSamples.good.replacingOccurrences(of: "## Quando usar", with: "## When to use")
            .replacingOccurrences(of: "## Passos", with: "## Steps").replacingOccurrences(of: "## Armadilhas", with: "## Pitfalls")
            .replacingOccurrences(of: "## Como verificar", with: "## Verification")
        #expect(problems(english).isEmpty)
    }

    @Test func aCommentInsideACodeBlockIsNotASectionTitle() {
        let withCode = SkillSamples.changed("1. Rode `swift test --jobs 4` e pare se algum teste falhar.",
                                            "1. Rode os testes e pare se algum falhar:\n```bash\n# testes\nswift test --jobs 4\n```")
        #expect(problems(withCode).isEmpty)
    }

    @Test func aProposalWithoutNameOrDescriptionIsTurnedBack() {
        refuses(SkillSamples.changed("name: publicar-site\n", ""), mentioning: "name")
        refuses(SkillSamples.changed("description: Publica o site em produção com testes antes e conferência depois; use quando pedirem para publicar ou subir o site.\n", ""),
                mentioning: "description")
        refuses("Passos: rode os testes e publique.", mentioning: "frontmatter")
    }

    @Test func theNameIsTheClassOfTaskNotTheIncident() {
        for name in ["Publicar Site", "publicar_site", "fix-erro-do-deploy", "debug-login", "deploy-12345", "publicar-o-site-de-producao-da-empresa"] {
            refuses(SkillSamples.changed("name: publicar-site", "name: \(name)"), mentioning: "name")
        }
    }

    @Test func theDescriptionHasTheLengthOfALineOfThePrompt() {
        refuses(SkillSamples.changed("Publica o site em produção com testes antes e conferência depois; use quando pedirem para publicar ou subir o site.", "Publica o site."),
                mentioning: "description")
        refuses(SkillSamples.changed("Publica o site em produção", String(repeating: "Publica o site em produção. ", count: 8)), mentioning: "description")
    }

    @Test func everySectionMustBeThereAndSaySomething() {
        refuses(SkillSamples.changed("## Armadilhas", "## Observações"), mentioning: "Missing sections: ## Armadilhas")
        refuses(SkillSamples.changed("Quando a usuária pedir para publicar, subir ou fazer deploy do site, em qualquer branch.", "Ao publicar."), mentioning: "Quando usar")
        refuses(SkillSamples.changed("2. Confirme que a branch é `main` com `git branch --show-current` e que `git status` está limpo.\n", "")
            .replacingOccurrences(of: "3. Rode `./scripts/deploy.sh --prod` e acompanhe a saída até a linha \"Deploy concluído\".\n", with: ""), mentioning: "Passos")
        refuses(SkillSamples.changed("- O script lê `.env.production` da pasta atual; rodar de outro lugar publica com as chaves erradas.\n", ""), mentioning: "Armadilhas")
        refuses(SkillSamples.changed("Abra o site e confira se a versão no rodapé é a do último commit (`git rev-parse --short HEAD`).", "Confira."), mentioning: "Como verificar")
    }

    @Test func aShortSketchIsTurnedBack() {
        let sketch = """
            ---
            name: publicar-site
            description: Publica o site em produção quando a usuária pedir para publicar.
            ---

            ## Quando usar
            Ao publicar o site.
            ## Passos
            1. Teste.
            2. Publique.
            3. Confira.
            ## Armadilhas
            - Cuidado.
            ## Como verificar
            Veja se funcionou.
            """
        let found = problems(sketch)
        #expect(found.count >= 4, "\(found)")
        refuses(sketch, mentioning: "characters")
    }

    @Test func aDiaryEntryIsTurnedBack() {
        refuses(SkillSamples.changed("Quando a usuária pedir", "Ontem a usuária pediu"), mentioning: "narrates")
        refuses(SkillSamples.changed("Quando a usuária pedir", "Nesta sessão a usuária pediu"), mentioning: "narrates")
        refuses(SkillSamples.changed("em qualquer branch.", "em qualquer branch, como em 07/10/2026."), mentioning: "narrates")
        refuses(SkillSamples.changed("em qualquer branch.", "em qualquer branch (sessão 3fa85f64-5717-4562-b3fc-2c963f66afa6)."), mentioning: "narrates")
        refuses(SkillSamples.changed("em qualquer branch.", "em qualquer branch, como no PR #4821."), mentioning: "narrates")
    }

    @Test func wordsAndColorsThatMerelyLookLikeADiaryAreNotOne() throws {
        // "hoje" in "agenda de hoje", "#333" and "desta vez" belong to legitimate skills.
        let proposal = try SkillProposal.validate(SkillSamples.writing, among: []).get()
        #expect(proposal.slug == "resumo-do-dia")
        #expect(problems(SkillSamples.changed("em qualquer branch.", "em qualquer branch; desta vez ou da próxima, sempre igual.")).isEmpty)
        // A PR number is still an incident, a hashtag-like number alone is not.
        #expect(problems(SkillSamples.changed("em qualquer branch.", "em qualquer branch, como no #4821.")).isEmpty)
        refuses(SkillSamples.changed("em qualquer branch.", "em qualquer branch, como no PR 4821."), mentioning: "narrates")
    }

    @Test func aGenericSkillWithAllTheSectionsIsTurnedBackWithHowToImproveIt() {
        let found = problems(SkillSamples.generic)
        #expect(found.contains { $0.contains("covers any task") }, "\(found)")
        #expect(found.contains { $0.contains("Passos is generic") && $0.contains("`command`") }, "\(found)")
        // A good name does not hide steps that say nothing.
        let renamed = SkillSamples.generic.replacingOccurrences(of: "tarefas-gerais", with: "revisar-texto")
            .replacingOccurrences(of: "Executa qualquer tarefa pedida pela usuária de forma eficiente e com muita qualidade.",
                                  with: "Revisa textos da usuária antes de enviar; use quando pedirem uma revisão de texto.")
        let steps = problems(renamed)
        #expect(steps.count == 1 && steps[0].contains("Passos is generic"), "\(steps)")
    }

    @Test func aNameOrDescriptionThatCoversEverythingIsTurnedBack() {
        for name in ["geral", "tarefas", "ajuda-geral", "qualquer-coisa", "general-helper", "tudo"] {
            refuses(SkillSamples.changed("name: publicar-site", "name: \(name)"), mentioning: "covers any task")
        }
        for summary in ["Faz qualquer tarefa que a usuária pedir, quando ela pedir.", "Executa todas as tarefas pedidas com atenção e cuidado.",
                        "Handles any request the user sends, whenever the user asks for it."] {
            refuses(SkillSamples.changed("Publica o site em produção com testes antes e conferência depois; use quando pedirem para publicar ou subir o site.", summary),
                    mentioning: "covers any task")
        }
    }

    @Test func stepsMayBeConcreteWithoutATerminal() {
        // A file, a tool, a URL, an option or a decision each make a step concrete; two of them are enough.
        func steps(_ one: String, _ two: String) -> [String] {
            let body = SkillSamples.generic.replacingOccurrences(of: "1. Entenda com cuidado e atenção o que a usuária está pedindo antes de começar a trabalhar.", with: "1. " + one)
                .replacingOccurrences(of: "2. Planeje a melhor forma de executar a tarefa com calma, pensando em todas as possibilidades.", with: "2. " + two)
                .replacingOccurrences(of: "tarefas-gerais", with: "revisar-texto")
                .replacingOccurrences(of: "Executa qualquer tarefa pedida pela usuária de forma eficiente e com muita qualidade.",
                                      with: "Revisa textos da usuária antes de enviar; use quando pedirem uma revisão de texto.")
            return problems(body)
        }
        #expect(steps("Leia o texto com `read_file` e anote os parágrafos longos.", "Abra https://exemplo.com/estilo e confira o guia.").isEmpty)
        #expect(steps("Leia o arquivo ~/Documentos/texto.md inteiro, sem pular nada.", "Se o texto passar de 2 páginas, resuma antes de revisar; senão, revise direto.").isEmpty)
        #expect(steps("Use run_command com a opção --check antes de enviar o texto.", "Corte cada parágrafo para no máximo 4 linhas.").isEmpty)
        #expect(!steps("Leia o texto com `read_file` e anote os parágrafos longos.", "Planeje a melhor forma de revisar o texto com calma e cuidado.").isEmpty)
    }

    private func withSteps(_ one: String, _ two: String) -> String {
        SkillSamples.generic.replacingOccurrences(of: "1. Entenda com cuidado e atenção o que a usuária está pedindo antes de começar a trabalhar.", with: "1. " + one)
            .replacingOccurrences(of: "2. Planeje a melhor forma de executar a tarefa com calma, pensando em todas as possibilidades.", with: "2. " + two)
            .replacingOccurrences(of: "tarefas-gerais", with: "revisar-texto")
            .replacingOccurrences(of: "Executa qualquer tarefa pedida pela usuária de forma eficiente e com muita qualidade.",
                                  with: "Revisa textos da usuária antes de enviar; use quando pedirem uma revisão de texto.")
    }

    @Test func aNumberOrAnEmptyConditionDoesNotMakeAStepConcrete() {
        // A digit alone, "se necessário" and "se houver dúvida" fit any task.
        for (one, two) in [("Se houver dúvida, pergunte à usuária antes de seguir com o texto.", "Se necessário, divida o texto em partes menores e revise uma a uma."),
                           ("Reserve 5 minutos para entender o que a usuária pediu.", "Revise 2 vezes o resultado antes de entregar o texto."),
                           ("Caso a tarefa seja grande, quebre em partes menores e entregue uma por vez.", "Se algo der errado, volte ao passo anterior e tente de novo com calma."),
                           ("Caso seja possível, peça mais contexto à usuária antes de começar o texto.", "Em inglês: if needed, ask the user, and if unsure, ask again before going on.")] {
            let found = problems(withSteps(one, two))
            #expect(found.contains { $0.contains("Passos is generic") }, "\(one) | \(two) → \(found)")
        }
        // Two measures are concrete steps, but without a command, file, URL, tool, option or literal nothing says what to do.
        let measures = problems(withSteps("Reserve 5 minutos para entender o que a usuária pediu.", "Corte cada parágrafo para no máximo 4 linhas, sem exceção."))
        #expect(measures.contains { $0.contains("Passos is generic") && $0.contains("no step names") }, "\(measures)")
        // The same measures next to one strong anchor are fine.
        #expect(problems(withSteps("Reserve 5 minutos para ler o arquivo `texto.md` inteiro.", "Corte cada parágrafo para no máximo 4 linhas, sem exceção.")).isEmpty)
        #expect(problems(withSteps("Abra o texto e escreva \"Revisado por mim\" no topo.", "Se o texto passar de 2 páginas, resuma antes de revisar; senão, revise direto.")).isEmpty)
    }

    @Test func aReportOfTheDayInTheFirstPersonIsTurnedBack() throws {
        let diary = SkillSamples.good
            .replacingOccurrences(of: "Quando a usuária pedir", with: "A usuária me pediu hoje de manhã")
            .replacingOccurrences(of: "1. Rode", with: "1. Eu rodei")
        refuses(diary, mentioning: "report of the day")
        refuses(SkillSamples.changed("1. Rode", "1. Eu tentei rodar").replacingOccurrences(of: "2. Confirme", with: "2. Eu descobri que"), mentioning: "report of the day")
        refuses(SkillSamples.changed("Quando a usuária pedir", "The user asked and I ran").replacingOccurrences(of: "em qualquer branch.", with: "em qualquer branch, this morning."),
                mentioning: "report of the day")
        // One sign is an example in a rule; the good and the writing samples have none or one.
        #expect(problems(SkillSamples.changed("Quando a usuária pedir", "Quando a usuária me pediu")).isEmpty)
        _ = try SkillProposal.validate(SkillSamples.writing, among: []).get()
        _ = try SkillProposal.validate(SkillSamples.good, among: []).get()
    }

    @Test func aDiaryWithoutThePronounIsTurnedBack() throws {
        let diary = SkillSamples.good
            .replacingOccurrences(of: "Quando a usuária pedir", with: "Hoje a usuária pediu")
            .replacingOccurrences(of: "1. Rode", with: "1. Primeiro rodei")
            .replacingOccurrences(of: "2. Confirme que", with: "2. Depois descobri e confirmei que")
            .replacingOccurrences(of: "3. Rode", with: "3. Então tentei de novo e rodei")
        refuses(diary, mentioning: "report of the day")
        refuses(SkillSamples.changed("1. Rode", "1. Rodamos").replacingOccurrences(of: "2. Confirme", with: "2. Corrigimos e confirmamos"), mentioning: "report of the day")
        _ = try SkillProposal.validate(SkillSamples.good, among: []).get()
        _ = try SkillProposal.validate(SkillSamples.writing, among: []).get()
    }

    @Test func whatTheUserAskedInARuleInThePresentIsNotAReport() {
        let rule = SkillSamples.good
            .replacingOccurrences(of: "4. Abra a URL", with: "4. Releia o que a usuária pediu e pergunte se a usuária ficou com alguma dúvida; quando a usuária disse que sim, abra a URL")
        #expect(problems(rule).isEmpty, "\(problems(rule))")
        // Two of them in the past are still a diary.
        refuses(SkillSamples.changed("Quando a usuária pedir", "A usuária pediu").replacingOccurrences(of: "4. Abra", with: "4. A usuária confirmou e abra"),
                mentioning: "report of the day")
    }

    @Test func aTrivialLiteralAndAConditionOnTheTaskItselfDoNotMakeSkillConcrete() {
        // `"Ok"` fits any answer and "caso a tarefa seja grande" fits any task: neither says what to do.
        let found = problems(withSteps("Comece a resposta com \"Ok\" e siga para o texto.", "Caso a tarefa seja grande, quebre em partes menores e entregue uma por vez."))
        #expect(found.contains { $0.contains("Passos is generic") }, "\(found)")
        // A literal with two words, or one that looks like an output, is something to write or to find.
        #expect(problems(withSteps("Comece a resposta com \"Tudo certo\" e siga para o texto.", "Se o texto passar de 2 páginas, resuma antes de revisar; senão, revise direto.")).isEmpty)
        #expect(problems(withSteps("Confira se a saída traz \"PASS\" ou \"ok: 3\" no final.", "Se o texto passar de 2 páginas, resuma antes de revisar; senão, revise direto.")).isEmpty)
        // Two literals side by side are not read as one long literal between them.
        let sides = problems(withSteps("Escreva \"Ok\" e depois do texto \"Fim\".", "Caso a tarefa seja grande, quebre em partes menores e entregue uma por vez."))
        #expect(sides.contains { $0.contains("Passos is generic") }, "\(sides)")
        // What comes after the closing quote is not part of the literal, and a period that ends it is no output.
        for trivial in ["Comece a resposta com \"Ok\" e siga para o texto.", "Comece a resposta com “Ok” e siga.", "Comece a resposta com \"Pronto.\" e siga."] {
            let found = problems(withSteps(trivial, "Se o cliente for da área jurídica, cite o artigo da lei antes do resumo."))
            #expect(found.contains { $0.contains("Passos is generic") }, "\(trivial): \(found)")
        }
        // A condition on the request, the document or the work is as empty as one on the task.
        for empty in ["Caso o pedido seja grande, quebre em partes.", "Se o documento for longo, divida antes.", "Se o trabalho for muito complexo, peça ajuda."] {
            let found = problems(withSteps("Comece a resposta com \"Ok\" e siga para o texto.", empty))
            #expect(found.contains { $0.contains("Passos is generic") }, "\(empty): \(found)")
        }
    }

    @Test func oneCommandInCommonWithTheSameVocabularyIsTheSameSkill() {
        // Only `npm publish` in common, but the steps are the same ones in other words.
        let digest = SkillDigest(slug: "publicar-pacote-npm", name: "Publicar pacote npm", summary: "Publica o pacote no registro",
                                 instructions: """
            ## Passos
            1. Rode os testes do pacote e pare se algum falhar, antes de publicar a versão nova.
            2. Suba a versão do pacote e confira a versão nova no registro depois de publicar com `npm publish`.
            ## Armadilhas
            - Nunca publique a versão com a árvore suja.
            """, improvable: true)
        let proposal = SkillSamples.good
            .replacingOccurrences(of: "`./scripts/deploy.sh --prod`", with: "`npm publish`")
            .replacingOccurrences(of: "swift test --jobs 4", with: "swift test")
        let found = problems(proposal, among: [digest])
        // Not the same vocabulary: no repetition.
        #expect(!found.contains { $0.contains("already covers") }, "\(found)")
        let close = proposal.replacingOccurrences(of: "## Quando usar\n", with: "## Quando usar\nRode os testes do pacote, suba a versão do pacote, publique a versão nova e confira a versão nova no registro.\n")
        #expect(problems(close, among: [digest]).contains { $0.contains("already covers") }, "\(problems(close, among: [digest]))")
    }

    @Test func aNameMayStartWithHelpOrCarryANumberThatIsNotATicket() {
        for name in ["ajuda-declaracao-irpf", "revisar-tudo-antes-deploy", "help-desk-chamados", "exportar-x265", "mp3-para-wav"] {
            #expect(problems(SkillSamples.changed("name: publicar-site", "name: \(name)")).filter { $0.contains("name") || $0.contains("covers") }.isEmpty, "\(name)")
        }
        for name in ["ajuda", "help", "ajuda-geral", "geral-ajuda", "qualquer-coisa", "exportar-2024", "revisar-404-erro", "bug123"] {
            let found = problems(SkillSamples.changed("name: publicar-site", "name: \(name)"))
            #expect(found.contains { $0.contains("covers any task") || $0.contains("names one incident") }, "\(name) → \(found)")
        }
    }

    @Test func aProposalThatParaphrasesAnExistingSkillIsSentBackToImproveIt() {
        let found = problems(SkillSamples.npmRepeated, among: [SkillSamples.npmDigest])
        #expect(found.contains { $0.contains("Improve it") && $0.contains("name: publicar-pacote-npm") }, "\(found)")
        // The same, in the other order and in other words: still the same commands.
        let other = SkillSamples.npmRepeated.replacingOccurrences(of: "lancar-versao-npm", with: "release-npm")
            .replacingOccurrences(of: "Lança uma versão nova da biblioteca para quem a instala; use quando pedirem um lançamento da lib.",
                                  with: "Faz o release da lib: usar quando for preciso soltar uma edição nova para os consumidores.")
        let again = problems(other, among: [SkillSamples.npmDigest])
        #expect(again.contains { $0.contains("name: publicar-pacote-npm") }, "\(again)")
        // A skill about something else is not a repetition, even with the same four sections and a command or two in common.
        #expect(problems(SkillSamples.good, among: [SkillSamples.npmDigest]).isEmpty)
        let shared = SkillSamples.changed("`./scripts/deploy.sh --prod`", "`git push --follow-tags`")
        #expect(problems(shared, among: [SkillSamples.npmDigest]).isEmpty)
    }

    @Test func aReferenceToWhereACredentialIsKeptIsNotASecret() {
        let reference = SkillSamples.changed("--prod", "--prod\n   export NPM_TOKEN=$(security find-generic-password -s npm -w)")
        #expect(problems(reference).isEmpty)
        let curl = SkillSamples.changed("--prod", "--prod\n   curl -u \"$USER:$SENHA\" https://exemplo.com/api e confira a resposta")
        #expect(problems(curl).isEmpty)
        let placeholder = SkillSamples.changed("--prod", "--prod\n   export API_KEY=<a chave do 1Password>")
        #expect(problems(placeholder).isEmpty)
        // The value itself is still one.
        refuses(SkillSamples.changed("--prod", "--prod\n   curl -u thiago:hunter2 https://exemplo.com"), mentioning: "secret")
    }

    @Test func aSecretIsTurnedBackNotKept() {
        refuses(SkillSamples.changed("--prod", "--prod --token ghp_0123456789abcdefghij0123456789ab"), mentioning: "secret")
        refuses(SkillSamples.changed("--prod", "--prod\n   export API_KEY=abc123def456"), mentioning: "secret")
    }

    @Test func aSkillOfTheAppOrTheCatalogCannotBeProposedAgain() {
        let app = SkillDigest(slug: "publicar-site", name: "Publicar site", summary: "x", instructions: "y", improvable: false)
        refuses(SkillSamples.good, among: [app], mentioning: "another name")
    }

    @Test func aSkillOfTheUserCanBeImprovedWithTheSameName() {
        let mine = SkillDigest(slug: "publicar-site", name: "Publicar site", summary: "Publica", instructions: "y", improvable: true)
        #expect(problems(SkillSamples.good, among: [mine]).isEmpty)
    }

    @Test func aProposalThatRepeatsAnotherSkillIsSentBackToImproveIt() {
        let existing = SkillDigest(slug: "deploy-do-site", name: "Deploy do site",
                                   summary: "Publica o site em produção com testes antes e conferência depois", instructions: "y", improvable: true)
        let found = problems(SkillSamples.good, among: [existing])
        #expect(found.contains { $0.contains("/deploy-do-site already covers this") && $0.contains("name: deploy-do-site") }, "\(found)")
        let shipped = SkillDigest(slug: "deploy-do-site", name: "Deploy do site",
                                  summary: "Publica o site em produção com testes antes e conferência depois", instructions: "y", improvable: false)
        refuses(SkillSamples.good, among: [shipped], mentioning: "from the app or the catalog")
    }

    @Test func theRefusalGivesAllTheReasonsAndTheFormat() throws {
        let refusal = try #require({ () -> SkillRefusal? in
            if case .failure(let refusal) = SkillProposal.validate("nada", among: []) { refusal } else { nil }
        }())
        #expect(refusal.problems.count >= 4)
        #expect(refusal.message.hasPrefix("The skill was NOT proposed:"))
        #expect(refusal.message.contains("## Quando usar") && refusal.message.contains("## Armadilhas") && refusal.message.contains("publicar-site"))
    }

    @Test func aKeptProposalReadsBackAsItWasWritten() throws {
        let proposal = try SkillProposal.validate(SkillSamples.good, among: []).get()
        let read = try #require(SkillProposal.read(proposal.markdown(), modified: .now))
        #expect(read.slug == proposal.slug && read.summary == proposal.summary && read.instructions == proposal.instructions)
        #expect(SkillProposal.read("sem frontmatter", modified: .now) == nil)
    }
}

@Suite final class SkillProposalBankTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "OrbSkills-\(UUID().uuidString)")
    deinit { removeTestFolder(root) }

    func bank() -> MemoryBank { MemoryBank(directory: root.appending(path: "orb")) }

    private func file(_ bank: MemoryBank, _ path: String) -> URL { bank.directory.appending(path: path) }

    @Test func aProposalWaitsInItsOwnFolderUntilTheUserDecides() async {
        let bank = bank()
        #expect(await bank.proposeSkill(SkillSamples.good) == .proposed(slug: "publicar-site", isUpdate: false))
        #expect(FileManager.default.fileExists(atPath: file(bank, "_propostas/publicar-site.md").path))
        let waiting = await bank.proposals()
        #expect(waiting.map(\.slug) == ["publicar-site"])
        #expect(await bank.proposal("publicar-site")?.instructions.contains("## Passos") == true)
        await bank.discardProposal("publicar-site")
        #expect(await bank.proposals().isEmpty)
        #expect(await bank.proposal("publicar-site") == nil)
    }

    @Test func theSameCommandReplacesItsProposalAndTheLimitHoldsForOthers() async {
        let bank = bank()
        await bank.proposeSkill(SkillSamples.good)
        await bank.proposeSkill(SkillSamples.changed("Confirme que a branch é `main`", "Confirme que a branch é `release`"))
        #expect(await bank.proposals().count == 1)
        #expect(await bank.proposal("publicar-site")?.instructions.contains("`release`") == true)
        for name in ["revisar-pr", "gerar-relatorio", "limpar-cache", "migrar-banco"] {
            #expect(await bank.proposeSkill(SkillSamples.changed("name: publicar-site", "name: \(name)")
                .replacingOccurrences(of: "Publica o site em produção", with: "Faz \(name.replacingOccurrences(of: "-", with: " ")) completo")) == .proposed(slug: name, isUpdate: false))
        }
        let sixth = await bank.proposeSkill(SkillSamples.changed("name: publicar-site", "name: ajustar-fontes")
            .replacingOccurrences(of: "Publica o site em produção", with: "Ajusta as fontes do projeto inteiro"))
        guard case .refused(let reason) = sixth else { Issue.record("a sixth proposal was kept"); return }
        #expect(reason.contains("already waiting"))
        // Changing one that waits is still possible.
        #expect(await bank.proposeSkill(SkillSamples.good) == .proposed(slug: "publicar-site", isUpdate: false))
    }

    @Test func aRefusedProposalLeavesNothingBehind() async {
        let bank = bank()
        guard case .refused(let reason) = await bank.proposeSkill("name: x") else { Issue.record("kept"); return }
        #expect(reason.contains("NOT proposed"))
        #expect(!FileManager.default.fileExists(atPath: file(bank, "_propostas").path))
    }

    @Test func aClosedMemoryKeepsNothing() async {
        let bank = bank()
        bank.close()
        guard case .refused = await bank.proposeSkill(SkillSamples.good) else { Issue.record("kept"); return }
        await bank.publishSkills([SkillDigest(slug: "a", name: "A", summary: "s", instructions: "i", improvable: true)])
        #expect(!FileManager.default.fileExists(atPath: file(bank, "_skills.json").path))
    }

    @Test func theOrbsSkillsAreWrittenOnlyWhenTheyChange() async throws {
        let bank = bank()
        let skills = [SkillDigest(slug: "resumir", name: "Resumir", summary: "Resume", instructions: "Resuma em 5 tópicos.", improvable: false)]
        await bank.publishSkills(skills)
        let url = file(bank, "_skills.json")
        let first = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(30))
        await bank.publishSkills(skills)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == first)
        await bank.publishSkills(skills + [SkillDigest(slug: "revisar", name: "Revisar", summary: "Revisa", instructions: "Revise.", improvable: true)])
        #expect(await bank.skillDigests().map(\.slug) == ["resumir", "revisar"])
    }

    @Test func anotherProcessSeesTheSkillsThroughTheSameFolder() async {
        let writer = bank()
        await writer.publishSkills([SkillDigest(slug: "resumir", name: "Resumir", summary: "Resume", instructions: "Resuma em 5 tópicos.", improvable: false)])
        let reader = MemoryBank(directory: writer.directory) // the tools server of Claude Code
        let text = await reader.skillText(named: "/resumir")
        #expect(text.contains("Skill /resumir") && text.contains("Resuma em 5 tópicos."))
        let none = await reader.skillText(named: "/nada")
        #expect(none.contains("No skill /nada") && none.contains("/resumir"))
    }

    @Test func proposalsAndTheCopyOfSkillsAreNotMemoryPages() async {
        let bank = bank()
        await bank.remember("Publica o site com make deploy.", kind: .procedimento)
        await bank.proposeSkill(SkillSamples.good)
        await bank.publishSkills([SkillDigest(slug: "resumir", name: "Resumir", summary: "Resume", instructions: "Resuma.", improvable: false)])
        await bank.reconcile()
        let snapshot = await bank.snapshot()
        #expect(snapshot.items.map(\.kind) == [.procedimento])
        #expect(await bank.recall("deploy publicar site", limit: 10).map(\.kind) == [.procedimento])
        for path in ["_propostas/publicar-site.md", "_skills.json"] {
            await bank.forget(path)
            #expect(FileManager.default.fileExists(atPath: file(bank, path).path), "\(path) is not a page")
        }
    }

    @Test func aMemoryAdoptedByAnotherOrbBringsNoProposalsOrSkills() async throws {
        let bank = bank()
        await bank.proposeSkill(SkillSamples.good)
        await bank.publishSkills([SkillDigest(slug: "resumir", name: "Resumir", summary: "Resume", instructions: "Resuma.", improvable: false)])
        let target = root.appending(path: "novo")
        try KeptMemories.adopt(bank.directory, into: target)
        #expect(!FileManager.default.fileExists(atPath: target.appending(path: "_propostas").path))
        #expect(!FileManager.default.fileExists(atPath: target.appending(path: "_skills.json").path))
    }
}

final class SkillToolsTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "OrbSkillTools-\(UUID().uuidString)")

    deinit { removeTestFolder(directory) }

    private func context(skillReview: Bool = false) -> (ToolContext, MemoryBank) {
        let bank = MemoryBank(directory: directory)
        var context = ToolContext(workingDirectory: directory, memory: bank)
        context.skillReview = skillReview
        return (context, bank)
    }

    private func skill(_ text: String) -> JSONValue { .object(["fact": .string(text), "tipo": .string("skill")]) }

    @Test func proposingASkillAsksNothingBecauseItChangesNothing() {
        #expect(RememberTool().risk(skill("x")) == .safe)
        #expect(RememberTool().risk(.object(["fact": .string("x")])) == .sensitive)
        #expect(RememberTool().risk(.object(["fact": .string("x"), "tipo": .string("preferencia")])) == .instructs)
        // Not even in "Só leitura": nothing is saved until the user approves it in the app.
        let call = PermissionPolicy.call(for: RememberTool(), arguments: skill("x"), context: ToolContext(workingDirectory: directory))
        for mode in PermissionMode.allCases {
            #expect(PermissionPolicy.evaluate(mode: mode, call: call, rules: [], turnGrants: [], workspace: directory) == .allow, "\(mode)")
        }
        #expect(RememberTool().summary(skill(SkillSamples.good)) == ("Propondo uma skill", "publicar-site"))
    }

    @Test func rememberWithTipoSkillKeepsAProposalAndNoMemory() async throws {
        let (context, bank) = context()
        let answer = try await RememberTool().run(skill(SkillSamples.good), context: context)
        #expect(answer.contains("/publicar-site") && answer.contains("nothing changes until they approve"))
        #expect(await bank.proposals().map(\.slug) == ["publicar-site"])
        #expect(await bank.snapshot().items.isEmpty)
    }

    @Test func aShallowProposalComesBackAsAnErrorWithTheReasons() async {
        let (context, bank) = context()
        await #expect(throws: ToolError.self) { try await RememberTool().run(skill("1. Faça a tarefa"), context: context) }
        do { _ = try await RememberTool().run(skill("1. Faça a tarefa"), context: context) } catch {
            #expect(error.localizedDescription.contains("The skill was NOT proposed"))
        }
        #expect(await bank.proposals().isEmpty)
    }

    @Test func theReviewMayOnlyProposeSkills() async throws {
        let (context, bank) = context(skillReview: true)
        await #expect(throws: ToolError.self) {
            try await RememberTool().run(.object(["fact": .string("Mora em SP.")]), context: context)
        }
        await #expect(throws: ToolError.self) {
            try await RememberTool().run(.object(["fact": .string("x"), "tipo": .string("identidade")]), context: context)
        }
        let kept = await bank.snapshot()
        #expect(kept.items.isEmpty && kept.identity.isEmpty)
        _ = try await RememberTool().run(skill(SkillSamples.good), context: context)
        #expect(await bank.proposals().count == 1)
    }

    @Test func recallLoadsASkillWithItsSlash() async throws {
        let (context, bank) = context()
        await bank.publishSkills([SkillDigest(slug: "resumir", name: "Resumir", summary: "Resume", instructions: "Resuma em 5 tópicos.", improvable: false)])
        await bank.remember("Resumir é com 5 tópicos.", kind: .procedimento)
        let skill = try await RecallTool().run(.object(["query": .string("/resumir")]), context: context)
        #expect(skill.contains("Resuma em 5 tópicos.") && skill.contains("follow them"))
        #expect(try await RecallTool().run(.object(["query": .string("/nada")]), context: context).contains("No skill /nada"))
        // An ordinary query is a search, as before.
        #expect(try await RecallTool().run(.object(["query": .string("resumir tópicos")]), context: context).contains("From your memory"))
        #expect(RecallTool().summary(.object(["query": .string("/resumir")])) == ("Lendo a skill", "/resumir"))
    }

    @Test func claudeCodeProposesThroughTheSameTools() {
        let remember = ClaudeCodeTools.memoryPrefix + "remember"
        for mode in [PermissionMode.ask, .auto, .readOnly] {
            #expect(ClaudeCodePolicy.answer(mode: mode, toolName: remember, input: skill("x")) == .allow, "\(mode)")
        }
    }

    @Test func skillsDecodeWithoutTheOrbThatLearnedThem() throws {
        let old = #"{"id":"6F1B6E5E-7C65-4B6C-A8E1-0B2B3C4D5E6F","slug":"resumir","name":"Resumir","summary":"s","instructions":"i"}"#
        let decoded = try JSONDecoder().decode(Skill.self, from: Data(old.utf8))
        #expect(decoded.learnedBy == nil && decoded.isImprovable)
        let orb = UUID()
        var learned = Skill(slug: "publicar-site", name: "Publicar site", summary: "s", instructions: "i", source: Skill.learnedSource)
        learned.learnedBy = orb
        let again = try JSONDecoder().decode(Skill.self, from: JSONEncoder().encode(learned))
        #expect(again.learnedBy == orb && again.isImprovable && again.source == "aprendida")
        #expect(!Skill(slug: "a", name: "A", summary: "", instructions: "", source: Skill.builtInSource).isImprovable)
        #expect(!Skill(slug: "a", name: "A", summary: "", instructions: "", source: "anthropics/skills/pdf").isImprovable)
    }
}
