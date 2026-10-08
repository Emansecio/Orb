# Contexto e compactação

Como o Orb decide o que o modelo vê de uma conversa que não cabe na janela dele, e como faz isso gastando poucos tokens.
Para quem desenvolve; o lado de quem usa (anel de contexto, "Compactar agora", "Memória das conversas") está no
[README](../README.md).

Duas ideias dirigem tudo:

1. **O que sai da janela é resumido uma vez, em lote, por regras (sem chamar o modelo).** Os provedores guardam em cache o
   *começo* do pedido; cada mudança no começo reescreve o cache a partir dali. Então o histórico só muda quando passa do
   orçamento, e aí desce de uma vez até a metade dele, em vez de ceder uma mensagem por vez.
2. **O que é esquecido não se perde.** As mensagens ficam inteiras no disco (só a *cópia enviada* encolhe), o resumo é um
   registro estruturado que mantém o pedido original, e o trecho vai para a memória do Orb antes de sair da janela.

## Onde acontece

| Momento | Quem | O que faz |
|---|---|---|
| Ao enviar (motor nativo) | `Conversation.prepareHistory` (chamado por `AppModel.send`) | Decide o corte e a condensação do histórico que o turno vai usar; grava resumo, `ledger`, `summaryCoveredCount`, `condensedCount` na conversa |
| A cada chamada ao modelo | `AgentEngine.fitted` → `ContextWindow.fit` | Reajusta a janela com o `ContextCut` do turno; só mexe no começo quando enche de novo |
| Dentro de uma tarefa longa | `TurnEvent.compacted` (com `CompactionReport.Fold`) | O app guarda a dobra em turnos inteiros (`BotSession.keepFold`) para o próximo turno partir do mesmo resumo |
| Sob pedido | `AppModel.compactNow` / `/compactar [foco]` | Mesma máquina, até 30% do orçamento |
| Claude Code | `ClaudeCodeEngine` + `ClaudeCodePrompt.catchUp` | O contexto é do próprio CLI; o Orb só recomeça sessões (veja abaixo) |

## Orçamento (`ContextBudget`)

Tudo é estimado em tokens a 3,5 caracteres por token.

```
histórico (tokens) = máx( 2 000,  mín( 90% da janela − sobrecarga − reserva da resposta,  teto do nível ) )
```

| Parte | Valor |
|---|---|
| Janela | a do catálogo do modelo (`ProviderModel.contextLength`); senão 16 000 (Ollama e LM Studio), 128 000 (chat e Responses) ou 200 000 (Messages e Claude Code); o menor entre ela e a **janela aprendida** |
| Sobrecarga | prompt do sistema + especificações das ferramentas. O motor mede a real (`ContextBudget.overheadTokens`) e avisa o app (`onOverheadMeasured`); antes disso vale 8 000 |
| Reserva da resposta | 16 000 (Messages, Claude Code) ou 4 000 (demais), nunca mais que 1/8 da janela |
| Teto do nível | "Memória das conversas" em Ajustes → Geral: **Econômica** 40 000 · **Equilibrada** 80 000 (padrão) · **Ampla** 60% da janela. `ContextMemoryLevel`, salvo em `AppState.contextMemory` |
| Folga para o pedido | `leavingRoom`: tira do orçamento a mensagem nova e o prefácio (até 4 000 caracteres de reserva, `AppModel.prefaceAllowance`), nunca mais que a metade |

Um modelo fora do catálogo usa o formato do provedor (ou o `format` da conta, no gateway próprio). Claude Code não tem
orçamento do Orb (`contextBudget(for:)` devolve `nil`).

### Janela aprendida

Se o provedor recusa o pedido por tamanho (HTTP 400/413 ou erro dentro do stream, `ContextOverflow.matches`), o motor tenta
**uma vez** com menos histórico:

- a recusa disse a janela ("maximum context length is 8192", `reportedWindow`): o orçamento é refeito por ela;
- não disse: o histórico cai à metade e a janela passa a valer 85% da que se supunha (`unstatedWindowShare`).

Em ambos a nova tentativa é **sempre menor** que a que falhou (senão o teto do nível reenviaria o mesmo pedido). Se a
tentativa menor funciona, `onContextLearned` grava o valor em `AppState.learnedContexts["provedor/modelo"]`
(`LearnedContext`). Vale 21 dias (7 se foi só estimada) e aparece em Ajustes → Geral → "Janelas aprendidas", com "Esquecer"
(útil depois de aumentar o limite do servidor).

## Marca d'água baixa e lote

`ContextWindow.fit` (puro, testado sem rede):

1. começa sempre numa mensagem do usuário; preserva imagens só nos 3 últimos turnos do usuário (as outras viram uma linha
   com o caminho) e no máximo 6 imagens de ferramentas;
2. **cabe**: não toca em nada. Por isso a requisição seguinte só cresce no fim e o cache do provedor continua valendo;
3. **passou do orçamento**: descarta turnos inteiros do começo, do mais velho para o mais novo, até o histórico ficar em
   `lowWater` do orçamento: **50%** (75% se o orçamento tem menos de 12 000 tokens, onde não dá para gastar metade), e
   dobra o que saiu no resumo;
4. se o turno mais recente sozinho ainda não cabe, aperta em degraus (abaixo).

O `ContextCut` lembra, entre as chamadas de um turno, onde o corte está, o resumo, o nível de aperto e quantas saídas já
viraram prévia. Ele só se mexe quando o histórico passa do orçamento outra vez.

## Condensação (`ContextCondensing`)

Antes de esquecer, o app *encolhe a cópia enviada* do trecho velho. As mensagens guardadas ficam inteiras.

- o prefácio `<orb_context>` das mensagens antigas é cortado até a linha `Now:`, menos o do snapshot mais novo e as
  mudanças da pasta enviadas depois dele (sem elas o modelo perderia o estado da pasta);
- saídas antigas de ferramentas ficam com **800 caracteres** (erros, 1 200; a nota "full output saved at …" sempre inteira);
- o raciocínio criptografado e as assinaturas de "thinking" deixam de ser reenviados;
- os dois últimos turnos nunca são condensados (`frontier`).

`Conversation.condensedCount` guarda até onde já se condensou e só avança junto com uma compactação, ou quando condensar
sozinho economiza pelo menos 8% do orçamento (`condenseShare`), para o custo de reescrever o cache valer a pena.

## Uma tarefa maior que a janela

Dentro do turno em andamento (`ContextWindow.fit`, passo 4):

- as saídas de ferramentas **da tarefa atual** ficam inteiras enquanto frescas; as 3 mais novas sempre. Quando as inteiras
  passam de 40% do orçamento e há 3 além das 3 novas, as mais velhas viram prévia **em lote**, até 20%;
- se ainda aperta, os degraus (`ContextWindow.rungs`): prévias antigas 4 000 → 1 500 → 800 caracteres e argumentos 1 000 → 300;
  depois limita também as saídas inteiras a 8 000; o nível só sobe;
- por último, os passos mais antigos da tarefa são **postos de lado**, um por um, até 60% do orçamento (`stepsLowWater`).
  Cada um vira uma linha (`ToolDigest`): `[passo 7] read_file /src/mod3.swift -> ok, 20.000 car.; começa com «func exemplo…»`
  (até 24 linhas, as mais novas; o resto é contado). O pedido que começou a tarefa e o passo mais novo ficam sempre.

Ao bater no limite de passos (30 por turno, 60 numa rotina) o motor deixa um **registro de progresso**
(`ProgressRecord`) no histórico e emite `taskPaused`: o próximo "continua" retoma de onde parou. `Conversation.taskPaused`
é um campo explícito (zerado na próxima mensagem do usuário), então um modelo que imita o marcador numa resposta comum não
pausa nada. O "continue" que o motor injeta após uma resposta cortada por `max_tokens` (`nudge`) não conta como início de
turno nem entra na linha do tempo.

## Resumo estruturado (`ConversationLedger`)

O resumo não é um texto resumido de novo a cada vez: é um modelo de dados ao qual cada mensagem que sai da janela é
**absorvida uma única vez**, com teto por seção, e o texto que o modelo lê é *renderizado* dele (`render`, determinístico:
o mesmo ledger dá o mesmo texto, então o cache continua valendo). Nunca aninha ("Resumo anterior" dentro de "Resumo
anterior").

| Seção | Conteúdo | Limite |
|---|---|---|
| Pedido original | a primeira mensagem de verdade (≥ 20 caracteres), **fixa**: nunca trocada nem descartada | 600 |
| Objetivo atual | o pedido mais recente (≥ 10 caracteres) | 200 |
| Dar atenção a | o foco de "Compactar agora" | 300 |
| Pedidos e decisões | pedidos (120 caracteres) e decisões (160): frases com "decidi", "vamos usar", "sempre", "nunca", "prefiro", "use", "a partir de agora", "evite"…, e um "sim"/"pode" só como resposta à última pergunta do assistente; sobram os mais novos | 25 linhas, 900 caracteres para decisões e 1 400 no total |
| Erros e bloqueios | chamadas que falharam ou foram negadas, até a mesma ação funcionar | 5 |
| Pendente | pedido ainda sem resposta final; última pergunta do assistente | uma de cada |
| Arquivos alterados / lidos | alterados: `write_file`, `edit_file`, `trash` e, em `run_command`, redirecionamentos, `tee`, `touch`, `mkdir`, `rm`, `mv`, `cp`, `ln`, `sed -i`; lidos: `read_file`, `web_fetch`. Os mais novos; um arquivo alterado sai de "lidos" | 40 cada (420 e 260 caracteres no texto) |
| Última resposta | sem blocos de código | 300 |
| Resumo anterior (formato antigo) | texto de versões sem ledger, lido uma vez (`init(legacy:)`) | 400 |

O texto inteiro tem até 3 000 caracteres (`ContextSummary.maxLength`); se passa, as seções saem da menos importante
(última resposta, arquivos lidos, formato antigo…) para a mais; o pedido original nunca sai. Resumos no formato novo
("Pedido original: …") cujo ledger se perdeu são relidos por `init(legacy:)`, sem aninhar. Chamadas "Not run:" que não são
erro (a resposta inventada para uma chamada interrompida) não entram em "Arquivos alterados". No histórico, o resumo vai
como um par: uma mensagem do usuário que começa com `[Resumo do começo desta conversa]` e uma confirmação curta do
assistente, para os papéis alternarem para qualquer provedor.

## Memória antes de esquecer

Quando uma compactação tira mensagens da janela, o que elas continham vai para a memória do Orb **antes**, uma vez:

- no envio: `BotSession.announce(report, memoryUpTo:)` grava as páginas de sessão até a mensagem que está sendo enviada;
- dentro do turno: o fim do turno grava (`compactedInTurn`);
- o Claude Code compactando a própria sessão também marca `compactedInTurn`.

Execuções de rotina não viram sessões. Veja [MEMORIA.md](MEMORIA.md) para o formato da página.

## Saídas grandes

`ToolOutputCap.apply`: uma saída de ferramenta com mais de 30 000 caracteres vai inteira para `saidas/<id do Orb>/…txt` e o
modelo recebe o começo (10 000), o fim (5 000) e o caminho, com o jeito de ler de volta (`read_file` com `offset`/`limit`,
`grep`). Sem `read_file` nem `run_command` não há como reler, então a saída fica na conversa até 40 000 caracteres. A nota
com o caminho fica por último e sobrevive a qualquer encurtamento posterior. Os arquivos são apagados após 14 dias ou quando
o Orb passa de 200 MB (`ToolOutputCap.cleanUp`, na abertura do app) e com o Orb.

`run_command` faz o mesmo por conta própria, e antes: o `ProcessRunner` guarda só o começo e o fim (20 KB) na memória, mas, quando
a saída passa disso, vai gravando **tudo** em `saidas/<id do Orb>/comando-….txt` e termina com a mesma nota
(`[full output saved at …; read it with read_file …]`), que o encurtamento posterior da conversa também preserva. Assim um
`npm test` ou `git log` longo não precisa ser rodado de novo para ver o meio. O arquivo para em 50 MB (como o log de um
processo em segundo plano): um comando que não para de imprimir (`yes`) não enche o disco, e a nota diz `file cut at 50 MB`.

## Medidor, "Compactar agora" e `/compactar`

- **Medidor** (`ContextMeter.fill`, `ContextReading.make`): função pura da conversa e do orçamento, medida **fora da thread
  principal** com debounce (`ContextGaugeDriver`). O anel no compositor mostra a fração da **janela do modelo** (a cor
  esquenta a partir de 70% e fica "cheia" a partir de 85%); fica oculto sem histórico. O popover "Contexto desta conversa"
  diz em palavras quanto, o que é mantido palavra por palavra (resumo + últimas mensagens), quanto do último pedido veio do
  cache do provedor e quanto "Compactar agora" liberaria.
- **Aviso** "Esta conversa está ficando longa. Compactar agora ou começar uma nova?": aparece uma vez por conversa quando o
  histórico passa de 85% da janela **ou** do orçamento do nível (`ContextReading.pressure`, o maior dos dois), porque com uma
  janela grande o nível dobra o começo muito antes de a janela encher.
- **Compactar agora** (`AppModel.compactNow`, também por `/compactar [foco]`): `Conversation.compact` leva o histórico a 30%
  do orçamento (`ContextMeter.compactingShare`), ou à metade do que o histórico já condensado ocupa, o que for menor, para
  uma conversa ainda curta também dobrar turnos. O último turno fica inteiro. O foco (até 300 caracteres) entra no resumo
  como "Dar atenção a" até ser trocado. Não roda com o Orb respondendo ("Espere o Orb terminar…"); com uma conversa de um
  turno só diz "não há o que compactar". O resultado (`CompactionResult`) traz os números antes/depois, os mesmos do medidor,
  e vira também um aviso na conversa: "Compactei a conversa: N mensagens antigas viraram um resumo (≈ 58 mil → 19 mil tokens)."
- **Claude Code**: não há medida do Orb. "Compactar agora" dobra tudo menos o último turno no resumo
  (`compactAllButLatestTurn`), zera a sessão (`claudeSessionReported("")`) e a **próxima mensagem começa uma sessão nova** a
  partir do resumo. Os números são estimativas da cópia do Orb.

## Claude Code

O CLI mantém a própria sessão, então o Orb não corta histórico para ele. O que o Orb faz:

- **Catch-up** (`ClaudeCodePrompt.catchUp`, até 16 000 caracteres): numa sessão nova recebe a conversa até ali; numa retomada,
  só o que *outros modelos* responderam desde a última vez (`Conversation.claudeSeenCount`). O resumo ocupa o lugar do que
  cobre; as mensagens entram inteiras ou não entram, das mais novas para as mais velhas (pedido e resposta cortados em
  1 200 caracteres, menos o último pedido e a última resposta: 8 000 e 4 000); o que não cabe é absorvido num ledger, não
  cortado no meio.
- **Aviso do próprio CLI**: o evento `compact_boundary` vira "O Claude Code compactou a sessão (de X para Y tokens)."
- **Prompt estável**: a sessão retomada reenvia byte a byte o prompt anexado com que começou; identidade, modo, skills e
  instruções da pasta que mudaram vão junto da mensagem ("[Updated rules]"), e o prompt só é reconstruído (um único corte de
  cache) quando identidade, preferências ou regras permanentes mudam.

## Economia de tokens

Medidas que não são "compactar" mas decidem quanto cada mensagem custa:

| Medida | Onde | Efeito |
|---|---|---|
| Corpo da requisição **determinístico** | `WireEncoder` (chaves ordenadas; `messages` e `tool_choice` por último) nos 3 clientes | O prefixo é idêntico byte a byte entre chamadas, então o cache do provedor acerta |
| Marcadores de cache | Anthropic: `cache_control` na última ferramenta, no sistema e no fim da última mensagem (as duas primeiras com TTL de 1 h só em `api.anthropic.com`; o fim, 5 min). `prompt_cache_key` por conversa: chat só em `api.openai.com`; Responses em `api.openai.com` e `chatgpt.com`. O OpenCode recebe `x-opencode-session` por conversa | Chamadas seguidas leem o prefixo do cache |
| **Cache medido** | `TokenUsage.promptTokens` / `cacheHitRatio`, `TurnEvent.requestUsage` | O medidor mostra o acerto do último pedido; `ORB_DEBUG_USAGE=1` imprime uma linha por passo no stderr |
| Aviso de cache que não pega | `CacheHealth.isFailing`: pelo menos 3 chamadas, prompt médio ≥ 4 096 tokens e menos de 20% lido do cache | Um aviso por conversa, e só para clientes que de fato armam o cache (`arrangesPromptCache`: OpenAI, Responses em hosts com chave, Anthropic; chat em OpenRouter ou servidor local não é culpado) |
| Prompt do sistema **estável** | `SystemPrompt`, `PromptParts` | Sem data nem hora: o texto é igual de um dia para o outro. O que muda a cada mensagem vai no prefácio |
| **Prefácio por diferença** | `TurnPreface`, `WorkspaceSnapshot.report`, `WorkspaceChanges` | A pasta vai inteira uma vez; depois só `<workspace_changes>` (entradas, branch, mudanças e commits novos), ou nada. O hash exclui "arquivos recentes" (mudavam a cada escrita do próprio Orb). O snapshot completo volta quando o histórico não o tem mais |
| **Memória relacionada sem repetição** | `MemoryBank.related`, `TurnPreface.relatedLines` | No máximo 3 itens de 220 caracteres, só para mensagens com assunto (nada para "obrigado"), com 2 palavras em comum quando a mensagem tem 3 ou mais; um item (id `#a1b2`) que as últimas 3 mensagens já levaram só volta se a página mudou |
| Ferramentas enxutas | `ToolSpec`, `JSONValue.property` | Descrições e schemas ~35% menores; `required` vazio sai; `ui_read`/`ui_act` só são oferecidos com Acessibilidade concedida |
| Ferramentas que pagam o próprio orçamento | `ToolOutputBudget` | `read_file`, `grep`, `glob`, `list_directory` devolvem até 24 000 caracteres por página e dizem como continuar; `web_fetch` devolve 12 000 por padrão (`offset` continua e `find` procura; a página convertida fica 10 min em memória) |
| Imagens | `ImageProcessing`, `elidingOldImages` | Reduzidas a 1 568 px (JPEG 0,85) ao anexar; só as 3 últimas vezes do usuário mantêm imagens no envio; cada imagem é contada como 1 600 tokens |
| Raciocínio | `ReasoningTrace` | Guardado e reenviado só ao mesmo formato, endpoint e modelo; entra no orçamento; descartado na condensação |

## Constantes

| Constante | Valor | Onde |
|---|---|---|
| Caracteres por token | 3,5 | `ContextBudget` |
| Parte da janela planejada | 90% | `ContextBudget.windowShare` |
| Histórico mínimo | 2 000 tokens | `ContextBudget.minimumTokens` |
| Marca d'água baixa | 50% (75% abaixo de 12 000 tokens) | `defaultLowWater`, `smallBudgetLowWater` |
| Marca d'água dos passos | 60% | `defaultStepsLowWater` |
| Condensar sozinho se economiza | 8% do orçamento | `condenseShare` |
| Saída antiga / erro antigo | 800 / 1 200 caracteres | `ContextCondensing` |
| Saídas frescas inteiras | as 3 mais novas; lote a 40% → 20% | `ContextWindow.freshToolOutputs`, `freshShare` |
| Resumo | 3 000 caracteres; reserva de 4 000 no orçamento | `ContextSummary` |
| Compactar agora | 30% do orçamento | `ContextMeter.compactingShare` |
| Anel quente / aviso | 70% / 85% | `ContextReading` |
| Passos por turno | 30 (60 em rotinas) | `AgentEngine` |
| Saída grande | 30 000 caracteres | `ToolOutputCap.limit` |
| Janela aprendida | 21 dias (7 se estimada) | `LearnedContext` |

## Onde está no código

`Engine/ContextBudget.swift` (orçamento, níveis, janela aprendida), `Engine/ContextWindow.swift` (corte, degraus, resumo em
par, `prepareHistory`, saídas grandes), `Engine/ContextCondensing.swift`, `Engine/ConversationLedger.swift`,
`Engine/ToolDigest.swift` (linhas por passo e registro de progresso), `Engine/Compaction.swift` (relatório, `compact`,
`/compactar`), `Engine/ContextMeter.swift`, `Engine/ToolOutputSpill.swift`, `AppModel+ContextUI.swift`, `ContextGauge.swift`,
`Views/ContextMeterViews.swift`, `Views/ContextSettings.swift`, `Engine/TurnPrompt.swift`, `Engine/WorkspaceChanges.swift`.
Testes: `ContextWindowTests`, `ContextBatchingTests`, `ContextEngineBatchingTests`, `ConversationLedgerTests`,
`CompactionFlowTests`, `CompactionIntegrationTests`, `CompactionReviewTests`, `ContextUITests`, `CacheMetricsTests`,
`PrefaceFlowTests`, `RelatedMemoryTests`.
