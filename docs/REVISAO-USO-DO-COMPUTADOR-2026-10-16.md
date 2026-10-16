# Revisão: uso do computador — 16/10/2026 (fase 1, diagnóstico; fase 2, correções)

Escopo: `Sources/Orb/Engine/Tools/Accessibility*.swift` (Contracts, Elements, Events, Outline, Session e Tools), `ScreenTakeover`, `SyntheticInput`, `UIMarks`, `ScreenshotTool`, `WindowCapture`, `MacAppTools`, `MacTools` e `AppleScriptSupport`, mais os seis arquivos de teste da área. Meta do usuário: controlar apps em segundo plano sem tomar a tela (menus sem ativar o app, clique por posição via hit-test AX, ScreenCaptureKit), "sem dor de cabeça na execução nem gargalo".

## Resposta direta

**Nota 4 de 5.** A área é a mais bem protegida do app. Toda chamada AX roda numa fila de GCD por app, com prazo, com no máximo 4 apps ao mesmo tempo, e nenhuma roda no main ou no pool cooperativo. Um app travado custa um prazo e depois falha na hora. Ação, digitação e captura checam o ⌘. antes de cada efeito. O takeover devolve o app da frente e o cursor mesmo cancelado, e nunca deixa uma tecla modificadora presa, porque o modificador vai nos `flags` do próprio evento, não em teclas separadas. O que ficou para trás é pequeno e quase tudo está em **o prazo dizer "não respondeu" e o trabalho continuar**:

- passado o prazo, o trabalho seguia na fila do app: a ação que ainda não tinha saído podia sair **depois** de o modelo ouvir "não respondeu em 2 s", e ele repetia o pedido;
- três laços sem relógio nem checagem de cancelamento (busca de atalho no menu, busca de linha em tabela, coleta de marcas) gastavam o prazo inteiro e marcavam o app como travado;
- um ⌘. no meio de um clique N1 podia deixar o botão do mouse apertado no app;
- digitar um texto longo no takeover estourava o limite de 2 s "da etapa" no meio e deixava o texto pela metade;
- `wait` relia a janela inteira a cada 250 ms durante até 30 s.

O que continua tirando o foco sem necessidade é **uma decisão de produto**: `open` ativa o app (`NSWorkspace.open`), e a mensagem de "app não está aberto" manda o modelo usar `open`. (Decidido e corrigido depois: P1-2, abaixo.)

## Situação depois da fase 2 (16/10)

Os achados P1-1, P1-2 e P2-1 a P2-7 estão corrigidos, com teste; os P3 baratos também. Nenhum limite voltou (nem passos por turno nem orçamento): o que entrou são relógios **internos** de uma busca, sempre menores que o prazo que já existia, e a regra de cancelar o trabalho quando o prazo vence.

| Achado | O que mudou | Teste |
|---|---|---|
| P1-1 | Vencido o prazo da sessão, `AXSessions.run` cancela o `AXWorkToken` do trabalho (`CallGate.resolve` agora diz se foi ele quem fechou a chamada). O trabalho para no próximo elemento, e uma ação ainda não enviada nunca sai depois do "não respondeu". Quando o trabalho volta, a sessão deixa de ser "ocupada". Uma chamada que termina antes do prazo não é tocada. | `AccessibilityHangTests`: `pastTheDeadlineTheWorkIsToldToStopSoASlowActionNeverReachesTheApp`, `aCallThatFinishesBeforeItsDeadlineIsNotCancelledByIt` |
| P2-1 | `LiveSyntheticInput.click` só olha o cancelamento **antes de apertar** (índices pares dos eventos), nunca entre o aperto e a soltura. Num duplo clique o Parar vale entre os cliques. | `SyntheticInputTests.stopArrivingBetweenAPressAndItsReleaseStillReleasesTheButton` |
| P2-2 | `UIMarkCollector` usa `AXWork.isCancelled` (a coleta roda fora de qualquer tarefa, e `Task.isCancelled` ali é sempre falso). O relógio da coleta cai de 4 s para 3,5 s, e o `screenshot` passa o prazo de leitura menos 0,5 s: app lento dá menos marcas, não "Sem marcas: não respondeu em 4 s". | `UIMarksTests`: `theWalkOnTheAppsQueueStopsWhenItsCallWasCancelled`, `theWalkEndsBeforeTheReadDeadlineSoASlowAppGivesFewerMarksNotAnError` |
| P2-3 | `UIMenu.item(for:)` (atalho achado no menu) ganha relógio de 1 s e checa o cancelamento. Passado o relógio, o atalho vai como evento (N1) em vez de o menu gastar os 2 s da ação. | `AccessibilityLadderTests.theMenuSearchForAShortcutGivesUpOnASlowMenuAndTheKeyGoesAsAnEvent` |
| P2-4 | `select` por valor numa tabela usa `UIActTool.findRow`: 500 linhas no máximo, 1,2 s, para no cancelamento. Se não achou antes do fim, o erro diz quantas linhas olhou e manda usar `ui_read` com `query`. | `aRowSearchStopsAtItsBudgetAndSaysHowFarItLooked` |
| P2-5 | `UIWaiter.pause(after:took:)`: depois de uma olhada que custou 100 ms ou mais, a pausa tem o tamanho da olhada (no máximo 1 s). O app lento não fica ocupado mais da metade do tempo com `wait: appears`. Olhada barata mantém o ritmo de 50 ms a 250 ms. | `AccessibilityWaitTests.anExpensiveLookIsFollowedByAPauseAsLongAsTheLook` (o teste de ritmo dos 250 ms desliga o espaçamento: `spacesLooksByCost`) |
| P2-6 | `LiveTakeoverHand.type` aplica o limite de etapa **por pedaço** de 20 unidades (o evento e a sua espera), com `checkTime` depois do pedaço. O limite do takeover inteiro continua valendo. | `ScreenTakeoverTests`: `aLongTextIsNotCutHalfwayByTheLimitOfOneStep`; `oneStepCannotTakeMoreThanItsOwnLimit` passou a usar um pedaço de 150 ms contra o limite de 80 ms |
| P2-6 (conferência) | Na revisão final: o último pedaço não passa mais pelo `checkTime` (o texto já saiu inteiro; "Uma etapa passou de 2 s" faria o modelo digitá-lo de novo). Um pedaço lento no meio continua parando os seguintes. | `ScreenTakeoverTests.aSlowLastChunkIsNotCalledAFailureOnceTheTextIsWhole` |
| P1-2 | Decisão do usuário (16/10): tudo o que o `open` abre (app, arquivo, link, e arquivo com `app`) vai **em segundo plano**, com `NSWorkspace.OpenConfiguration.activates = false` (`LiveURLOpener`, atrás do protocolo `URLOpening`). Só `front: true` ativa; a descrição manda usá-lo só quando a pessoa pediu para ver. A saída diz "em segundo plano" ou "na frente", o cartão diz "Abrindo na frente", e a recusa "não está aberto" manda abrir com `open`, em segundo plano. O teto das specs sobe de 18.250 para 18.400. | `MacToolTests`: `everythingOpensInTheBackgroundUnlessFrontIsAsked`, `theAppNotOpenMessageSaysOpenKeepsItInTheBackground` |
| P2-7 | Decisão do usuário (16/10): se a pessoa apertou tecla ou botão nos últimos 2 s (`AccessibilitySystem.secondsSinceUserInput`, `.hidSystemState`, que não conta os eventos sintéticos do Orb), foi ela que foi ao app: ele fica na frente, não ganha a marca `stealsFocus`, e a saída avisa. Teclas e texto para um app em que ela acabou de entrar são recusados como "o usuário está usando". Passados os 2 s, o comportamento é o de antes. | `AccessibilityRefusalTests`: `anAppThePersonWentToStaysInFrontAndIsNotTakenForOneThatStealsFocus`, `nothingIsTypedIntoAnAppThePersonJustWentTo` |
| P3-1 | Saem `UIMenu.listing(under:)` (a revisão de higiene já citava), `UILiveElements.removeAll()`, `UIReadTool.read` (só um teste usava; o teste chama `reading`), `LiveTakeoverPlatform.init() {}` e `LiveTakeoverPoster.flags` (usa `SyntheticEventBuilder.flags(for:)`). | compilação e as suítes de sempre |

## Fase 3 (16/10): ver o app antes de agir

Pedido do usuário: o Orb sabe que algo existe e onde buscar; o detalhe só entra quando precisa. O modelo local (Foundation Models) foi descartado por ele.

| Item | O que mudou | Teste |
|---|---|---|
| 1 | `app_dictionary` (`.safe`): o dicionário AppleScript do app, lido do `sdef` só quando o Orb pede, em resumo compacto (suítes, classes com propriedades e elementos, comandos com parâmetros), filtrável por `search`/`suite`, em páginas de 6.000 caracteres (`offset`), em cache por app e versão. App sem dicionário: diz isso e sugere Atalhos ou `ui_read`/`ui_act`. A descrição do `applescript` e o prompt ganham uma frase. Teto das specs 18.400 para 18.900. | `AppDictionaryTests` (fixture de sdef, cache, sem dicionário, páginas) |

**Ficou, e por quê:**

- **P1-2** e **P2-7**: ficaram para decisão do usuário e entraram depois dela (linhas acima).
- **P3-2 a P3-9:** custo maior que o ganho agora, ou muda um contrato; cada um tem a razão na tabela de achados.

**Regressão.** Só suítes filtradas, sem a suíte inteira e sem `--snapshot`; a lista com as linhas finais de cada execução está no relatório da entrega. Não rodaram, pelas regras: `AXSmokeTests`, a `WindowCaptureSmokeTests` e qualquer coisa com `ORB_AX_SMOKE`, `ORB_AX_SMOKE_SYSTEM`, `ORB_AX_TAKEOVER`, `ORB_LIVE_TESTS` ou `ORB_DEV_TOOLS` (apps reais, eventos sintéticos de verdade, captura de tela e tomada de tela).

## O que já estava resolvido (não repeti)

Da `REVISAO-HIGIENE-2026-10-15.md` e do `docs/USO-DO-COMPUTADOR.md` §0: timeout por elemento no sistema inteiro, `read(_:)` que distingue "sem atributo" de "app travado", ausência de `activate`/`AXRaise`/`.cghidEventTap` fora do takeover, fila serial por app, `AXObserver` no lugar de espera fixa, captura por janela com ScreenCaptureKit e permissão pedida uma vez, `ui_act` sem `app` nunca age no app da frente. Da `REVISAO-TURNO-2026-10-16.md` (linhas 134 e 186): `withDeadline`/`cancellably`, ScreenCaptureKit com 10 s e queda para `screencapture`, OCR com 20 s, espera cancelável, PDF e Office por página. Nada disso foi mexido.

## Achados

### P1

**P1-1. O prazo vence, o trabalho continua e a ação ainda pode sair.** `AccessibilitySession.swift:178-185` (antes da correção): o cronômetro de GCD marcava a chamada como atrasada e entregava "não respondeu em N s", mas não cancelava o `AXWorkToken`; só o ⌘. o cancelava (`:187-190`). `LiveAccessibilityElement.perform` e `setValue` checam `AXWork.checkCancellation()` (`AccessibilityElements.swift:381-389`), mas o token nunca estava cancelado. Uma ação de 2 s que lia devagar (`subscribe` + `capture` + `resolve` + `AXPress`) falhava para o modelo e **apertava o botão no app logo depois**; o modelo tentava de novo e apertava duas vezes (um "Enviar", um "Comprar"). Além disso, a sessão ficava "ocupada" (`overdue`) até o trabalho terminar por conta própria, e as chamadas seguintes ouviam "o app não responde" de um app que só estava lento. **Correção mínima:** cancelar o token quando o cronômetro vence primeiro. **Teste:** `pastTheDeadlineTheWorkIsToldToStopSoASlowActionNeverReachesTheApp`. **Corrigido.**

**P1-2. `open` traz o app para a frente.** `MacTools.swift:97` (`NSWorkspace.shared.open(url)`) e `:106` (`OpenConfiguration()` com `activates` padrão, que é `true`). A mensagem de `UIAppResolver.Failure.notRunning` (`AccessibilityTools.swift:26`) diz "Abra-o com open e tente de novo". Ou seja, o caminho normal para operar um app fechado tira a tela de quem usa o Mac. **Correção mínima:** abrir apps com `NSWorkspace.openApplication(at:configuration:)` e `activates = false` quando o alvo é um app; ficaria como "o app abre sem ir para a frente". **Teste:** a configuração montada por uma função estática (`activates == false`); a abertura de verdade só em app real. **Corrigido depois da decisão do usuário:** tudo abre em segundo plano, e `front: true` traz para a frente.

### P2

**P2-1. ⌘. entre o aperto e a soltura do clique N1.** `SyntheticInput.swift:407` (antes): `try Task.checkCancellation()` a cada evento, inclusive antes do `mouseUp`. Um Parar nessa fresta, de microssegundos mas real, deixava o botão apertado no app (arrasto, menu aberto, seleção). Teclas não têm o problema (`keys` posta o par de uma vez). **Correção mínima:** checar só nos eventos pares. **Teste:** `stopArrivingBetweenAPressAndItsReleaseStillReleasesTheButton`. **Corrigido.**

**P2-2. A coleta de marcas ignora o Parar e disputa o prazo com o relógio dela.** `UIMarks.swift:147` usava `Task.isCancelled`, que no trabalho da fila do app (fora de tarefa) é sempre falso; o `Limits.seconds` era 4 (`:117`) e o prazo de leitura também é 4 s (`AccessibilitySession.swift:14`), então o prazo vencia primeiro e o `screenshot` dizia "Sem marcas: o app não respondeu" em vez de entregar as marcas já lidas. O `ui_read` já subtrai 0,25 s por isso (`AccessibilityTools.swift:261`). **Correção mínima:** `AXWork.isCancelled` e 0,5 s de folga. **Testes:** os dois de `UIMarksTests`. **Corrigido.**

**P2-3. Busca de atalho no menu sem relógio.** `AccessibilityTools.swift:844-862` (antes): até 800 itens, um `read` por item, sem checar o cancelamento; num app com menus grandes (Xcode, Office) passa dos 2 s da ação e a tecla falha com "não respondeu" quando bastava mandá-la como evento. **Correção mínima:** relógio de 1 s e cancelamento; passado o relógio, volta `nil` e a tecla segue como N1. **Teste:** `theMenuSearchForAShortcutGivesUpOnASlowMenuAndTheKeyGoesAsAnEvent`. **Corrigido.**

**P2-4. Busca de linha por valor lê até 500 linhas, cada uma com vários round trips.** `AccessibilityTools.swift:2155` (antes) com `rowText` (`:2177-2193`): 1 leitura da linha mais, para cada uma das 4 primeiras células, 1 de atributos e 1 de filhos (e 2 netos). Pior caso, milhares de chamadas dentro dos 2 s da ação. **Correção mínima:** `findRow` com 1,2 s, cancelamento e o número de linhas olhadas no erro. **Teste:** `aRowSearchStopsAtItsBudgetAndSaysHowFarItLooked`. **Corrigido.**

**P2-5. `wait: appears` relê a janela inteira, sem parar, por até 30 s.** `AccessibilityTools.swift:486-517` (antes): cada olhada é `UIOutlineBuilder.outline` com `stopAtFirstMatch`, que só encerra cedo quando acha; enquanto o texto não aparece, a janela inteira (até 3.000 elementos, 1,5 s) é lida a cada 250 ms. Num app grande o Orb mantém o app ocupado quase todo o tempo e disputa a thread dele com o usuário. **Correção mínima:** pausa com o tamanho da olhada quando ela custou 100 ms ou mais. **Teste:** `anExpensiveLookIsFollowedByAPauseAsLongAsTheLook`. **Corrigido.**

**P2-6. Digitar texto longo no takeover estoura o limite "da etapa".** `ScreenTakeover.swift:244-260` (antes): `begin()` dava um prazo de 2 s para o `type` inteiro, e cada pedaço (20 unidades) chama `platform.frontmost()` no `tick` (janela do sistema + pergunta ao app). Perto de 2.000 caracteres o texto parava no meio com "Uma etapa passou de 2 s", metade digitada no app do usuário, sem dizer quanto. **Correção mínima:** o limite é por pedaço (`checkTime` depois do pedaço); o limite total de 10 s continua. **Teste:** `aLongTextIsNotCutHalfwayByTheLimitOfOneStep`. **Corrigido.**

**P2-7. A devolução do app da frente pode contrariar a própria pessoa.** `AccessibilityTools.swift:1511-1522`: depois de toda ação, se o app alvo está na frente e o app de antes não era ele, o Orb o trata como "roubou o foco", manda o anterior de volta e marca o app (`stealsFocus`) para o resto da sessão. Se foi a pessoa que clicou no app alvo para ver o que o Orb fazia, ela é arrancada de lá, e o app passa a pedir takeover para focar e digitar. O sinal certo seria "a pessoa não mexeu no teclado nem no mouse nos últimos segundos", mas ele erra no caso inverso (o app roubou o foco enquanto a pessoa digita, e é aí que devolver mais importa). **Corrigido depois da decisão do usuário:** 2 s sem tecla nem botão da pessoa.

### P3

**P3-1. Código morto e duplicado.** `AccessibilityTools.swift:826` (`UIMenu.listing(under:)`), `AccessibilitySession.swift:369` (`removeAll`), `AccessibilityTools.swift:304-308` (`UIReadTool.read`), `ScreenTakeover.swift:516` (`init() {}`) e `:550-557` (`flags`, cópia de `SyntheticEventBuilder.flags(for:)`). **Corrigido.**

**P3-2. O takeover tem a sua própria tabela de teclas.** `ScreenTakeover.swift:550-632` (`LiveTakeoverPoster.virtualKey`, `currentLayout`, `usLayout`) repete o `LiveKeyLayout` de `SyntheticInput.swift:91-153`, guarda o mapa **para sempre** (`characterKeys`: quem troca de teclado no meio da sessão fica com o antigo) e usa `DispatchQueue.main.sync` sem espera máxima (o `LiveKeyLayout` espera 400 ms). A diferença que impede trocar: o takeover pede o teclado ASCII (`TISCopyCurrentASCIICapableKeyboardInputSource`), útil para atalhos em quem escreve em outro alfabeto, e o `LiveKeyLayout` usa o teclado atual. **Não corrigido:** unir as duas pede uma regra para teclado não latino, e testar isso exige o teclado real. Correção mínima futura: o `LiveKeyLayout` ganha "ASCII primeiro" e o poster o usa, com prazo de 10 s no cache.

**P3-3. Esperar uma vaga não ouve o Parar.** `AccessibilitySession.swift:198-221` (`acquire`) e `WindowCapture.swift:26-35` (`AsyncGate.run`): quem espera uma das 4 vagas (ou uma das 2 capturas, ou o Vision) só sai no prazo ou quando a vaga passa. Só aparece com 4 apps lentos ao mesmo tempo. **Não corrigido:** o prazo já limita a espera a 2-8 s.

**P3-4. Captura de tela inteira roda o OCR "accurate" na imagem cheia.** `ScreenshotTool.swift:144-156`: `screencapture` grava um PNG da resolução nativa (uma tela 5K passa de 20 MB), e `TextRecognizer.recognize(imageAt:)` (`:589`) usa `.accurate` com correção de idioma, com a imagem anexada para o modelo, que usa só 1.500 caracteres do texto. O `ocr: auto` de display roda sempre (não há árvore AX para dizer que bastava). **Não corrigido:** mudar o padrão do `ocr` muda o contrato da ferramenta. Correção mínima: em `auto`, com a imagem anexada, pular o OCR de display.

**P3-5. Cada ação lista todos os processos do Mac.** `AccessibilityTools.swift:98-100` (`verify`) e `:70` (`open`) chamam `runningApps(withFrontmost: false)`, que cria um `NSRunningApplication` por pid (`AccessibilityElements.swift:532-543`, "alguns milissegundos"). **Não corrigido:** é pouco; a correção pede um método novo no protocolo `AccessibilitySystem`.

**P3-6. Estado por Orb que só sai por tempo.** `UILiveElements` (10 min, poda só quando guarda uma leitura nova, `AccessibilitySession.swift:332-343`), `UISnapshotStore` (1 h) e `AXSessions` (poda só com 64 apps): nada limpa quando o Orb é apagado. Segura referências AX por alguns minutos; sem vazamento contínuo. **Não corrigido.**

**P3-7. `attributes` repete `read`.** `AccessibilityElements.swift:291-342`; a revisão de higiene já tinha achado. A diferença é o que volta quando o app falha no meio do lote (`attributes` devolve o parcial). **Não corrigido:** mudaria o comportamento num caso raro.

**P3-8. `apps_list` sem teto próprio.** `MacAppTools.swift:338-342`: com `include_background` passa de 100 linhas; o `ToolOutputCap` (30.000 caracteres) cobre. **Não corrigido.**

**P3-9. O aviso do takeover aparece só na tela principal.** `ScreenTakeover.swift:704` usa `NSScreen.main`, a tela da janela com o teclado; com duas telas o cartão "Orb está usando a tela" pode estar na outra. **Não corrigido:** exige captura de tela para conferir.

## Casos que o Orb ainda não faz sozinho (por desenho)

| Caso | Hoje | Saída |
|---|---|---|
| Pop-up e menu de contexto que só existem abertos | `needsScreen` com o motivo | `takeover` |
| Arrastar e soltar | só no takeover (15 passos) | alternativa semântica (arquivos, AppleScript) |
| Janela minimizada | lê a árvore, não captura a imagem; avisa | pedir para restaurar (visível) |
| App sem árvore AX (canvas, jogo) | `screenshot` com OCR e `x,y` por evento ao pid | takeover quando o app ignora o evento |
| Electron | `AXManualAccessibility` uma vez por app; nova leitura após 300 ms se vier vazio | — |
| Folha (sheet) modal | aparece em `UIState.sheet`; a leitura vem da janela em foco | tratar a folha primeiro |
| Várias janelas | `window` por número ou título; a lista vem no cabeçalho | — |
| Várias telas | coordenadas globais, `display` por número; `-D` no `screencapture` | — |
| Campo de senha | nunca lido; preencher passa pelo cartão | — |

## Tabela das ferramentas (depois da fase 2)

| Ferramenta | Tempo-limite | Tamanho da saída | Tira o foco? |
|---|---|---|---|
| `ui_read` | leitura 4 s (8 s com `query`; a caminhada para 0,25 s antes); `wait` 1-30 s (+0,5 s) | até 400 linhas e 14.000 caracteres; relógio de 3.000 elementos | Não (AX). Liga `AXManualAccessibility` uma vez por app |
| `ui_act` | 2 s por chamada ao app (cada passo, cada leitura de estado); até 8 passos; `wait` 1-30 s; busca de atalho 1 s; busca de linha 1,2 s | "o que mudou" em até 600 caracteres, mais a lista do menu (40 itens) | Não em N0/N1. Se o app se traz sozinho, o Orb devolve o anterior e avisa |
| `ui_act` com `takeover` | 10 s no total, 2 s por clique, tecla ou pedaço de texto; 0,5 s para o app vir; 0,5 s para voltar | uma frase | **Sim**, com confirmação; devolve app, janela e cursor |
| `screenshot` (janela) | ScreenCaptureKit 10 s, depois `screencapture` 20 s; marcas 3,5 s; OCR 20 s | JPEG até 450 KB; legenda até 4.000 caracteres; OCR 1.500 (com imagem) ou 8.000 (sem) | Não |
| `screenshot` (tela) | `screencapture` 20 s; OCR 20 s | PNG nativo (anexado já reduzido); OCR 1.500 ou 8.000 | Não (o diálogo de permissão aparece uma vez por processo) |
| `open` | sem prazo (LaunchServices); busca de app por nome 5 s (`mdfind`) | uma linha | Não: abre em segundo plano; só `front: true` traz para a frente (P1-2) |
| `applescript` | 60 s (até 300) | até 20.000 caracteres | Depende do script; o diálogo de Automação aparece uma vez por app e a espera dele não conta |
| `shortcuts_list` / `shortcuts_run` | 20 s / 60 s (até 300) | 300 nomes / 20.000 caracteres | A lista não; o Atalho depende do que ele faz |
| `clipboard_read` / `clipboard_write` | sem prazo (ator principal) | 20.000 caracteres | Não |
| `notify` | sem prazo | uma linha | Não |
| `apps_list` | sem prazo | sem teto próprio (cai no teto geral de 30.000) | Não |
| `app_quit` | 5 s à espera (2 s no `force`) | uma linha | Não; fecha o app alvo |
| `trash` | sem prazo | até 50 caminhos | Não |

## Como foi feita

- **Versão:** `db080f6` (main). Trabalho no branch do worktree, sem tocar na main nem em `~/Library/Application Support/Orb` e `~/Orbs`.
- **Leitura:** li inteiros os 14 arquivos do escopo, os dois documentos de contexto e os trechos citados das revisões anteriores. Cada achado foi conferido na linha antes de entrar aqui, e os de tempo e cancelamento ganharam teste que **falha sem a correção** (o relógio, o token, a soltura do botão, o pedaço de texto).
- **Testes:** só suítes filtradas das áreas tocadas, com fakes (nenhum app real lido, clicado ou digitado, nenhuma captura, nenhuma tomada de tela). O app não foi aberto e não houve `--snapshot`.
- **Falta app real ou captura:** (1) que o cancelamento por prazo interrompe de fato uma caminhada num app lento de verdade (Xcode com um projeto grande); (2) o duplo clique N1 com ⌘. no meio; (3) um texto de 2.000 caracteres no takeover; (4) `wait: appears` num app grande, medindo a carga no app; (5) o P1-2, `open` sem ativar, num app que se ativa sozinho ao abrir; (6) o P2-7 com a pessoa clicando no app no meio de uma ação.

## Perguntas só suas (respondidas em 16/10)

Respostas: (1) tudo abre em segundo plano, inclusive arquivos e links, e só `front: true` traz para a frente; (2) não devolver quando a pessoa usou teclado ou mouse nos últimos 2 s. As duas entraram (P1-2 e P2-7).

1. **`open` de um app deve ir para a frente?** Hoje vai. Se a resposta for "não, a menos que eu peça", o Orb abre o app sem ativá-lo e diz isso ("abri o Notas sem trazê-lo para a frente"). Pela meta de segundo plano eu faria assim para apps, e manteria arquivos e links como estão (quem pede para abrir um arquivo quer vê-lo).
2. **Devolver o app anterior quando você mesmo foi ao app alvo.** Hoje o Orb o devolve sempre que o alvo veio para a frente durante uma ação. Dá para não devolver quando você usou o teclado ou o mouse nos últimos 2 s, ao custo de não devolver também quando o app rouba o foco enquanto você digita. Qual dos dois erros incomoda menos?
