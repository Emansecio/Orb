# Persistência

Parte do mapa do código: veja [ARQUITETURA.md](ARQUITETURA.md) para a visão geral.


Pasta de dados: `~/Library/Application Support/Orb/` (a variável `ORB_DATA_DIR` troca).

```
state.json                       AppState: Orbs, rotinas, skills, conectores (segredos viram "@keychain"), provedores,
                                 modelo padrão, não lidas, nível de contexto das conversas, janelas aprendidas, correções de preço,
                                 as conversas de cada Orb que tem mais de uma (`OrbChats`: a que está na tela, títulos, datas, não lidas, o último modelo de cada uma)
conversations/<Orb>.json         a primeira conversa do Orb (nunca some): itens da tela + mensagens do modelo + resumo/ledger + marcas
conversations/<Orb>.meta.json    nota ao lado: quantos itens, quantos já foram para a memória, impressão digital do arquivo
conversations/<Orb>/<id>.json    só de versões antigas ("Nova conversa"): `Store.mergeArchive` as junta à conversa na abertura, em ordem, e apaga
conversations/<Orb>/conversa-<id>.json      cada conversa aberta com "Nova conversa" (e a nota `.meta.json` ao lado); trocar
                                 de conversa grava a que sai e lê a outra (`BotSession.openChat`); o que chega numa que não está
                                 na memória é gravado direto nela (`Store.amend`)
conversations/<Orb>/routine-<rotina>.json   a conversa de cada rotina
conversations/<Orb>/pulso-<id do Orb>.json  a conversa do pulso do Orb (uma só; o pulso começa de onde parou)
wake/<nome ou id>.wake           a campainha de fora: um processo externo grava o arquivo e a rotina roda na hora
                                 (`RoutineWake`; consumido ao ser lido, o texto vira o motivo na execução)
rascunhos.json                   o que cada compositor guarda sem enviar (`ComposerDraft`: texto e caminhos de arquivos e imagens); gravado ao sair, depois que o turno interrompido devolveu a fila, e a cada rodada do agendador; lido na abertura
execucoes.json                   o que estava em andamento (`WorkJournal`): tarefa do chat de um Orb, pedido a um grupo, pedido de um Orb a outro; gravado só quando um trabalho começa ou termina, nunca por token. Sair do app não apaga as entradas: a próxima abertura retoma cada uma, uma vez (`AppModel+Resume`). Ver "Retomar sozinho" abaixo
conectores/<id>.json             catálogo do conector (`ConnectorCatalog`): o que o servidor ofereceu da última vez, sem segredos
memoria/<Orb>/…                  a memória (páginas .md + index.sqlite, _propostas/ e _skills.json das skills); memoria/_guardadas/<nome> – <data>/ de Orbs apagados ou
                                 redefinidos, com perfil.json (nome, papel e aparência) ao lado das páginas
anexos/<Orb>/<uuid>.jpg|png      imagens reduzidas (a conversa guarda o caminho); saem com o Orb, ou na abertura do app quando nenhum arquivo salvo (estado, rascunhos, conversas, arquivadas, rotinas, pedidos, grupos; as cópias `.corrupt-…` também contam como uso) cita o nome e a imagem tem mais de 7 dias (`ImageStore.removeOrphans`; um arquivo que não abre cancela a limpeza)
perfil/foto-<8 hex>.jpg|png      a foto da usuária (quadrada, até 256 px; nome novo a cada troca, a antiga é apagada); nunca vai a provedor nem a ferramenta; o Redefinir apaga a pasta
saidas/<Orb>/*.txt               saídas grandes de ferramentas; limpas por idade (14 dias) e tamanho (200 MB)
claude-pipe/cwd/                 a pasta (vazia) em que o `claude` roda como cano até o modelo; nenhum projeto à vista
claude-pipe/runs/<uuid>/         os arquivos de um processo do `claude` (prompt do sistema, declaração das ferramentas, configuração do MCP, caixa de correio dos resultados);
                                 apagada quando o processo termina, e as que um app que caiu deixou somem depois de um dia
uso/aaaa-mm.json                 histórico de uso: uma linha por hora × Orb × modelo × origem, só números (veja "Uso e custos")
*.corrupt-<aaaammdd-hhmmss>      cópia de um arquivo que não pôde ser lido (nunca sobrescrito)
.migrado-do-openbot              marca de que a migração do OpenBot já foi feita
```

## Retomar sozinho

Uma tarefa interrompida por sair do app ou por uma queda continua sozinha na abertura seguinte, uma vez por interrupção; **Parar** antes de sair é o jeito de encerrar de verdade. `WorkJournal` (`MultiOrb/WorkJournal.swift`, `execucoes.json`) guarda uma entrada quando o trabalho começa (`BotSession.beginTurn` no chat do próprio Orb, nunca em rotina, pedido ou turno de grupo; `GroupHub.runs`; `DelegationHub.submit` fora de grupo e fora de outro pedido) e a tira quando termina, falha ou a pessoa para (`finishTurn`, o fim da rodada do grupo, `DelegationHub.refresh`). `stopTurnsForQuit` congela o diário (`freeze`): os turnos que terminam ao sair não apagam nada, e é isso que a abertura retoma. O que cada entrada vira:

- **Tarefa do chat**: a conversa já termina no aviso "O app foi fechado no meio desta tarefa." (`closingInterruptedTurn`); o Orb recebe a mesma mensagem do botão "Continuar", só se a pessoa não escreveu depois do corte, e com a contagem de processos em segundo plano que morreram com o app (só o número, nunca o comando).
- **Pedido a um grupo**: o fio ganha "O app fechou no meio deste pedido; retomando." e o orquestrador recebe um turno com as atribuições marcadas como perdidas (`GroupHub.resume`).
- **Pedido de um Orb a outro**: reenviado ao mesmo destino, na mesma cadeia, com o aviso para conferir o que já foi feito (`DelegationHub.resubmit`); a resposta acorda quem pediu como sempre. Um pedido feito enquanto o Orb atendia outro pedido ou uma rotina não é guardado: quem pediu é refeito do começo e pergunta de novo.
- **Rotinas**: não são retomadas; o agendamento as roda de novo.
- **Pulso**: não é retomado; a abertura descarta a entrada (`dropPulse`) e o próximo pulso cobre o que faltou.

Cada entrada retoma uma vez (`resumes`); a que já foi retomada é descartada e fica o "Continuar" do aviso. Guarda contra ciclo de quedas: `cleanQuit` fica falso ao abrir e verdadeiro no `willTerminate`; duas aberturas depois de queda em menos de 10 minutos não retomam nada e limpam o diário. A retomada espera a primeira checagem das conexões e, para a tarefa do chat, até um minuto por um Orb que outra coisa tomou na abertura.

Fora dela: o **Keychain** (serviço `app.orb.mac`; uma conta por provedor com chave, `chatgpt` com o JSON do login e
`mcp.<id do conector>.<NOME>` para segredos de conectores e `mcp.<id>.oauth` para o login de um conector), as **preferências** (`UserDefaults`: `notifyWhenDone`,
`quickAskGlobalShortcut`, `keychainAccountsFromOpenBot`, as chaves multi-Orb (`orbsActOnOwn`…) e do pulso (`pulseEnabled`, `pulseMinutes`, `pulseDailyTokens` e o `pulseState` em JSON), aba de Ajustes e do painel de cada Orb, modelos recentes…) e a **pasta de cada Orb**
(`~/Orbs/<Nome>/`, com `Rotinas/<nome>/…md`), que o app não apaga ao apagar o Orb.

## Redefinir o Orb

Ajustes → Geral → Seus dados → "Redefinir o Orb…" leva o app ao primeiro uso. A ordem importa, porque o app continua rodando
até o fim:

1. **Recusa** (`ResetGuard.refusal`): nos modos de desenvolvedor (`--snapshot`, `--render-*`); numa pasta que não pode ser a
   de dados (a raiz, a pasta pessoal ou uma que a contenha); e, quando a pasta não é a padrão (`~/Library/Application Support/Orb`,
   por exemplo `ORB_DATA_DIR`), se ela for, ficar dentro de ou conter `~/Orbs` ou a pasta de algum Orb (arquivos dos Orbs
   nunca são apagados) ou se não tiver `state.json` (não parece dados do Orb: `~/Documents`, um disco externo). Nada é tocado.
2. **Sela o estado** (`isResetting`, `Store.sealWrites`): `scheduleStateSave` e `saveNow` (que o término do app chama) não fazem
   nada, o `Store` descarta tudo o que já estava na fila e tudo o que vier (`WriteSeals`, em `enqueue` e `writeFile`). Nenhuma
   gravação atrasada, nem a do término, regrava o estado antigo depois da limpeza. Com `isResetting` a janela, o painel da
   barra de menus e Ajustes ficam cobertos (`resetShield`) e o modelo recusa `send`, rotinas e adotar uma memória guardada.
3. **Para tudo** (`AppModel.stopForReset`): agendador, turnos de todos os Orbs (cancelar o turno termina o processo do Claude
   Code), rotinas e a fila delas, cartões de aprovação e banners, conectores (MCP). Espera os turnos acabarem, no máximo 3 s.
4. **Guarda o último trecho** (`saveLastStretches`, só em "Guardar as memórias"): a conversa depois da última página de sessão de
   cada Orb vira página em `sessoes/`, como em `deleteBot(keepMemory:)`, e a espera termina (no máximo 5 s) **antes** de
   `MemoryLibrary.seal`, que fecha os bancos para que nenhuma tarefa atrasada recrie uma pasta depois de movida.
5. **Limpa fora da thread principal** (`ResetExecutor.run`, em `Task.detached`): `store.flush()` (o que estava sendo gravado
   termina), `BackgroundJobs.killAllNow()`, e então, na ordem: move a memória de cada Orb para `_guardadas` com o perfil (ou, em
   "Apagar tudo", remove `memoria/` inteira); remove **só o que o app grava** na pasta de dados (`ResetGuard.removes(entry:)`:
   `state.json` e suas cópias `state.json.…`, `rascunhos.json`, `conversations/`, `memoria/`, `anexos/`, `conectores/`, `saidas/`, `perfil/`, `uso/`; qualquer outro arquivo, como
   `.migrado-do-openbot`, fica); e, em `navegador/`, só os dados dos navegadores dos Orbs (uma pasta por id de Orb, com perfil, logins,
   cookies e estados salvos, e `sessoes/`), como apagar um Orb faz: `bin/`, `chrome/` (Chrome for Testing), `instalados.json`,
   `atualizacoes.json`, `agent-browser.json` e `lancadores/` são ferramentas e ficam; apaga os segredos pelo cofre injetável (`SecretVault.remove` = `Keychain.set("")`, o mesmo
   caminho público de apagar chave: conectores e, com "Também sair dos provedores", uma conta por provedor mais `chatgpt`;
   nunca o Claude Code); devolve as preferências ao padrão (`UserDefaults` do próprio app, menos `LegacyKeychainLedger.key`);
   grava um `state.json` novo só com os provedores, o modelo padrão e as janelas aprendidas quando eles ficam; e, se a pasta do
   OpenBot ainda tem dados e o marcador faltava, cria o marcador. Cada passo continua se outro falhou; o relatório
   (`ResetReport`) diz o que sobrou e, se sobrou algo, um aviso (`ResetWarning`, injetável em `ResetEnvironment.warn`) lista os itens
   antes de o app fechar.
6. **Fecha e reabre** (`AppRelaunch.finish`): um `sh` espera o processo acabar (até 20 s) e roda `open` no `.app` (sem `-n`; se o
   processo não acabou, não abre nada); fora de um `.app` (SwiftPM) só fecha.

**Por que o OpenBot não volta.** O Keychain do OpenBot (`app.openbot.mac`) é só backup: `Keychain.lookup` copia uma conta dele
na primeira leitura e anota a conta em `LegacyKeychainLedger` (`keychainAccountsFromOpenBot`, nas preferências); depois disso o
item antigo não é mais consultado. Apagar uma chave pelo `Keychain.write` já anota a conta, então a redefinição só precisa
(a) apagar pelo caminho público e (b) deixar essa chave das preferências em paz (`ResetGuard.keepsPreference`, a mesma
constante). Sem isso, "Também sair dos provedores" seria desfeito na reabertura, que copiaria as chaves do OpenBot de volta.
Os testes usam um Keychain de mentira com os itens do OpenBot.

O alerta de confirmação é um `NSAlert` (`ResetConfirmation`): Esc aperta "Cancelar", Return não aperta nada e o botão
destrutivo não tem tecla. Nos testes, `AppModel.resetEnvironment` (argumentos, preferências, pasta do OpenBot, o último passo)
é "inerte" quando o modelo não é o app (`runsBackgroundWork: false`), então um teste nunca toca nas preferências reais.

## Uso e custos

Cada resposta do provedor traz os tokens do pedido (`TokenUsage`); o app os soma por hora, e o custo é calculado na hora de mostrar.

- **Registro.** `BotSession.apply` entrega a `AppModel.recordUsage` cada `TurnEvent.requestUsage` (uma chamada ao modelo, também com o Claude Code: o cano lê os tokens
  do fluxo do CLI). O modelo é o do turno (`BotSession.turnModel`); a origem é `routine` se há uma rotina rodando,
  senão `chat`; `auxiliary` é para chamadas do próprio app fora de um turno: hoje a revisão de skills em segundo plano (`reviewSkillsIfDue` repassa cada
  `.requestUsage` a `recordUsage`; o resumo da compactação é por regras e não gasta nada). Um pedido interrompido
  pelo botão Parar também é cobrado: o transporte anuncia os tokens de entrada assim que o provedor os informa (`LLMEvent.usage`,
  o `message_start` da Anthropic, antes de qualquer saída), o motor repassa como `TurnEvent.pendingUsage` e `BotSession.play`, que
  é quem ainda lê o fluxo depois do Parar, registra o último que não foi seguido de um `.requestUsage`.
  O `UsageRecorder` guarda o que chega num dicionário e o entrega ao `Store` a cada 10 s, ao fim do turno e no `saveNow`.
- **Arquivo.** `Store.addUsage` lê o mês (decodificação tolerante, `.corrupt-…` se não decodifica), soma e grava na fila de
  gravação, então lotes e leituras (que esperam as gravações do mesmo arquivo) ficam em ordem. Um mês nunca passa de 20 000 linhas
  (as que não cabem são contadas em `dropped`). A hora é a hora local do relógio (`Calendar.current`) e o mês do arquivo, o do relógio.
  Um Orb apagado continua no histórico: o arquivo guarda o nome que ele tinha.
- **Preço.** `PriceBook.price(for:)`: correção da usuária (`AppState.priceCorrections`, lida entrada por entrada: uma estragada não leva as outras) → preço da lista do provedor
  (`ProviderModel.price`, lido de OpenRouter `pricing` e de models.dev `cost`, os mesmos que o app já baixava) → `PriceTable`
  (id normalizado: sem prefixo de provedor, data, `:thinking`, `-latest`; pontos viram traços; um id que a tabela não tem acha a
  família mais longa só quando o que sobra são sufixos que não mudam o preço, `PriceTable.sameFamilySuffixes`: `codex`, `preview`,
  `customtools`…, nunca uma versão nem `-pro`/`-mini`/`-deep-research`; a data só fica para `gpt-4o-2024-05-13`, que tem preço próprio).
  Preços que mudam com o tempo ficam em `PriceTable.adjustments` (fator sobre o preço da tabela, escolhido pela hora da linha:
  DeepSeek fora do pico = metade; Gemini Flash 3.6-3.8 = dobro a partir de 2027-01-01). A gravação de cache de 1 h
  (`TokenUsage.cacheWrite1h`, lida de `usage.cache_creation` da Anthropic; subconjunto de `cacheWrite`) tem preço próprio
  (`ModelPrice.cacheWrite1h`, 2× a entrada). A correção vence também sobre o equivalente calculado nos planos. `PriceDraft` é o texto do editor
  e conserva o que ele não mostra (a escrita de 1 h) para que salvar sem mudar nada não altere o preço. `UsageBilling.of(provedor)` diz se é por uso, plano (ChatGPT,
  Claude Code, OpenCode Go: `incluído`, com o equivalente da tabela de preços) ou local (Ollama, LM Studio, gateway em localhost: grátis).
  O custo não é gravado (a não ser o `reportedCost` que linhas antigas do Claude Code trazem): corrigir um preço corrige o passado.
- **Página.** `UsageModel.reload` descarrega o recorder, lê os meses do período no `Store` e soma em `Task.detached`
  (`UsageReport.make`, pura); um resultado de uma leitura mais velha nunca substitui o de uma mais nova. Só roda ao abrir, ao
  trocar de período, ao corrigir um preço e ao voltar ao app; nada contínuo. Animações: `Motion.content` em valores e barras, nada com Reduzir movimento.
- **Tabela de preços.** `PriceTable.consultedOn` é o dia em que as páginas oficiais foram lidas (a nota da página o mostra). Para
  atualizar: leia as páginas citadas no comentário da tabela, troque os valores e o dia; `UsagePricingTests` confere o formato, não os números.

## Decodificação tolerante

Campo novo precisa de valor padrão: `container.value(_:default:)`, listas com `lossyArray` (um item ilegível é pulado, não
derruba a lista) e enums de texto com `Decoder.rawValue(_:fallback:)`. O que se perdeu vira aviso: `DecodeLoss` conta os itens
pulados e o `Store` guarda uma cópia do original (`.corrupt-…`) antes de regravar. Um arquivo que não decodifica é **movido**
para essa cópia (nunca fica no caminho de uma escrita); se nem isso dá, o `FileGate` bloqueia as gravações naquele arquivo até
o app abrir de novo. Falha ao gravar avisa uma vez. Na conversa, uma mensagem ou item pulado faz os números que apontam para as listas
(`summaryCoveredCount`, `condensedCount`, as faixas de `chunkSummaries`, `memorySavedCount`) recuarem junto, e um resultado
de ferramenta cuja chamada foi pulada sai também (o provedor recusa um resultado sem a chamada; `lossyOptionals`). Os avisos aparecem no alerta "Atenção com seus dados"
(`AppModel.dataNotices`), que trocam o nome do arquivo pelo que ele guarda ("a conversa de Lia", "os ajustes do app";
`StoreNotice.file` + `AppModel.described`); falha ao gravar o `.meta.json` não avisa (ele se refaz da conversa). Enums de
texto de versões novas (`OrbTemperament`, `APIFormat`, modo de permissão…) caem no padrão em vez de derrubar o Orb; um
modelo de provedor com formato desconhecido sai da lista. A gravação incremental da conversa mantém o formato do arquivo, legível por versões anteriores.

## Convenção: inits dos tipos de dados

- Não escreva `init` memberwise à mão: o Swift gera um, e só deixa de gerar quando algum `init` está declarado no corpo do tipo.
- `init(from:)` e inits de conveniência vão numa `extension` do tipo, no mesmo arquivo (o `CodingKeys` privado exige o mesmo
  arquivo), para o Swift continuar gerando o memberwise. Tipo aninhado pede a extension qualificada (`extension TaskPlan.Step`).
  Mover o `init(from:)` para a extension não muda o formato em disco.
- O valor padrão fica na propriedade (`var state: State = .queued`), não no init. Um `let` com valor inicial não entra no
  memberwise, e a ordem dos parâmetros é a ordem de declaração das propriedades.
- Init manual só com motivo, explicado num comentário de uma linha: rótulo `_`, validação ou conversão, propriedade `private`
  sem valor inicial, dependência injetada em `let`, classe ou actor.

## Filas e gravação

- Gravações: **uma fila serial por pasta de dados** (`WriterQueues`), em ordem, fora da thread principal. O estado é salvo
  400 ms depois da última mudança (`scheduleStateSave`); uma conversa, no máximo a cada 5 s enquanto uma resposta chega (um
  pouco mais em conversas longas) e na hora ao fim do turno; ao sair, só o que mudou (`saveNow`). Uma gravação que falha marca a
  conversa como não salva de novo (`reportSaveFailure`), para o `saveNow` ao sair tentar outra vez. A conversa de uma execução de
  rotina que já terminou (o chat voltou) fica em `unsavedRoutineConversations` se a gravação falha, e é gravada de novo ao sair; a próxima execução da rotina parte dela, não do arquivo mais antigo.
- Ao sair (`willTerminate`): `stopTurnsForQuit` interrompe os turnos (os cartões fecham e a conversa diz "Você interrompeu"), o estado e os rascunhos são salvos, e `ChildProcessGroups.killAllNow` e `BackgroundJobs.killAllNow()` encerram os grupos de processos que o app iniciou: os comandos em
  segundo plano, o `claude` do Claude Code e o `run_command` em primeiro plano (cada um lidera um grupo próprio, que a morte do app não alcança).
- Leituras: fila concorrente própria, coordenada por arquivo (`FileGate`): uma leitura espera as gravações *daquele* arquivo
  (nunca vê um arquivo pela metade nem uma versão velha) e não espera as dos outros. O nome de um arquivo para o `FileGate`,
  as filas de escrita e os selos (`FileKey`) sai só do texto do caminho: `standardizedFileURL` olha o disco (tira o `/private`
  de um caminho que existe), então um arquivo que ainda não existia ao registrar a gravação ganhava outro nome ao terminá-la,
  e uma leitura esperava para sempre ("Carregando a conversa" sem fim em `--snapshot` com `ORB_DATA_DIR` em `/private/tmp`).
  Uma leitura que passa de 3 s esperando registra no log o que a segura.
- Gravação incremental: `ConversationEncoder` reaproveita o JSON dos itens que não mudaram desde a última gravação do
  arquivo (cache por arquivo, no máximo 4 arquivos e 48 MB) e não grava quando nada mudou. Ao gravar, saídas antigas de
  ferramentas (anteriores à penúltima mensagem do usuário) ficam com começo e fim (~4 000 caracteres).
- Só a conversa do Orb aberto é lida na abertura (`beginLoading`, com marcador de carregamento); as outras, ao trocar de Orb ou
  quando algo precisa delas (`ensureLoaded`, na thread principal, só quando não dá para esperar). Começar uma rotina (a leitura
  da conversa dela, `startRoutine`) também lê fora da thread
  principal e conferem depois que o Orb, a rotina e a conversa ainda existem e que nenhum turno começou. Uma conversa parada há mais
  de 5 min, sem nada para gravar, volta ao disco (`unloadIdleConversations`, a cada 30 s), o que a nota `.meta.json` ao lado
  permite verificar sem reler.

