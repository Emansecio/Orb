# Revisão de economia de tokens, frente B: a contagem e o histórico (2026-10-17)

Revisão local, sem chamar nenhum provedor: leitura do código a partir do HEAD `c51ba85`, testes com respostas gravadas e uma olhada (só em totais, nada copiado) no arquivo de uso real do mês (`uso/2026-10.json`). Não mexi no texto do prompt de sistema nem nas descrições das ferramentas (frente A), e não trouxe de volta nenhum limite tirado em `c3d8029`: o que há aqui só mostra ou conta consumo.

## Resumo

O caminho dos tokens está bem feito: cada cliente normaliza a contagem para `input + cacheRead + cacheWrite` (o prompt inteiro) e `output`, os repasses de falha e de nova tentativa estão contados uma vez, o cache de prompt tem marcadores e ordem de chaves estáveis, e o histórico só muda em lotes. Achei **três erros de contagem** (todos corrigidos, com teste que falhava antes), **uma confirmação em teste** do que o cache precisa (a requisição de um passo é o começo da do passo seguinte, nos três formatos) e seis propostas; a revisão do código corrigiu uma delas (item 7, a linha de trabalho), e ficam **cinco propostas** de maior efeito que dependem de decisão ou de medição com o app aberto.

| # | Achado | Prioridade | Estado |
|---|--------|-----------|--------|
| 1 | Um evento posterior do formato Messages apagava a contagem que o primeiro tinha dito (zero no `message_delta`) | P1 | corrigido |
| 2 | Resposta cortada ou parada em "Parar" contava a saída do `message_start` (1 ou 2 tokens) em vez do que já escreveu | P2 | corrigido |
| 3 | Nota de trecho (`ChunkSummarizer`) lida só até o teto: saída zerada; `WizardRunner` com ramo morto que contaria em dobro | P2 / P3 | corrigido |
| 4 | `stream_options` só vai para hosts conhecidos: xAI (chat), gateways custom e servidores locais não reportam uso (sem custo, medidor real nem aviso de cache) | P2 | proposta |
| 5 | O medidor de contexto é só estimativa (3,5 caracteres por token); o número real da última chamada não calibra nada | P2 | proposta |
| 6 | OpenAI: o cache em memória dura 5 a 10 min; `prompt_cache_retention: "24h"` seguraria o início da conversa entre turnos distantes sem custo extra | P2 | proposta |
| 7 | A linha de trabalho soma leituras de cache como "tokens" (de 50 mil em diante) | P3 | corrigido na revisão do código |
| 8 | Raciocínio criptografado do Responses vai de volta nos dois últimos turnos; o orçamento o conta como texto | P3 | proposta |
| 9 | "Parar" em OpenAI/Responses perde a chamada inteira (não há uso adiantado); cancelar o assistente de criação também | P3 | proposta |
| 10 | Saídas de turnos anteriores viram prévia de 4.000 caracteres na virada do turno (uma reescrita de cache por turno) | P3 | análise, sem mudança |

## 1. Como a contagem funciona hoje

### Do provedor até a tela

```
resposta do provedor --(cliente normaliza)--> TokenUsage{input, output, cacheRead, cacheWrite, cacheWrite1h}
   .usage (adiantado, só Anthropic)  .finished(razão, uso)          Engine/EngineTypes.swift:291
        |
AgentEngine.respond (retentativas)  ->  Reply.usage                 Engine/AgentEngine.swift:494-543
        |  uma chamada terminada:  .requestUsage(uso da chamada)  +  .usage(soma do turno)   AgentEngine.swift:305-316
        v
BotSession.apply                                                    BotSession+Turn.swift
   .requestUsage -> recordUsage(UsageTotals) -> AppModel.recordUsage -> UsageLog (hora x Orb x modelo x origem)
                    setRequestUsage / live.lastUsage (medidor: razão de cache)
   .usage        -> setUsage + TurnSpend (linha de trabalho, a partir de 50 mil)  + spentDollars
```

Regras que valem para todos os provedores: `input` nunca inclui cache (os clientes subtraem), então `promptTokens = input + cacheRead + cacheWrite`; uma contagem fora de `0...1e12` vira desconhecida (`TokenUsage.sane`); a soma é saturada.

### Por provedor

| Provedor | De onde vem | Cache de leitura | Cache de escrita | Raciocínio |
|----------|-------------|------------------|------------------|------------|
| Anthropic (Messages) | `message_start` (entrada, cache) e `message_delta` (saída; hoje também o resto, acumulado) | `cache_read_input_tokens` | `cache_creation_input_tokens`, e `cache_creation.ephemeral_1h_input_tokens` para o preço de 1 h | dentro de `output_tokens` (o app não liga o thinking) |
| OpenAI e compatíveis (chat) | último chunk, com `stream_options.include_usage` (só OpenAI, OpenRouter, Command Code e OpenCode; `OpenAIClient.swift:39-43`) | `prompt_tokens_details.cached_tokens`, ou `prompt_cache_hit_tokens` (DeepSeek) | `cache_write_tokens` (OpenRouter) | dentro de `completion_tokens` |
| OpenAI e ChatGPT (Responses) | `response.completed` / `response.incomplete` | `input_tokens_details.cached_tokens` | não existe | dentro de `output_tokens` |
| Claude Code (cano) | os mesmos eventos Messages que o CLI repassa; `carried` soma mensagens continuadas após corte | idem Anthropic | idem (o CLI grava sempre por 1 h: nos meus dados `cacheWrite == cacheWrite1h`) | idem |
| Custom | pelo formato escolhido; chat sem `stream_options` | se o servidor mandar | se mandar | idem |

Preço: `PriceBook.cost` usa o preço corrigido pelo usuário, depois o da lista do provedor, depois a tabela (`ModelPricing.swift`); `ModelPrice.cost` separa escrita de 5 min e de 1 h, e lê cache sem preço como entrada (lado seguro). Plano e local mostram "incluído"/"grátis". A tabela traz a data da consulta (2026-10-09); não conferi os valores com as páginas dos provedores (sem rede), só a aritmética e o casamento de nomes (versão maior nunca casa com a menor, `claude-opus-4.9` não vira `claude-opus-4`).

### O que a revisão conferiu e está certo

- **Entrada contada duas vezes em turnos de várias chamadas**: não. `Reply.usage` é a chamada, `usage` do turno é a soma de `Reply.usage`; `.requestUsage` grava cada chamada uma vez e `.usage` (a soma) não é gravado (`BotSession+Turn.swift:289-296`; teste `everyModelCallOfAChatTurnIsCountedWithItsOrbAndModel`).
- **Retentativas**: uma tentativa que quebrou depois de o provedor dizer o que usou entra como descartada (`countDiscarded`, `AgentEngine.swift:170`, `:503`, `:539`); uma tentativa que falhou antes de qualquer uso não conta (não foi cobrada); a última tentativa cortada devolve o `Reply` e é contada uma vez na linha 305.
- **Parar no meio**: `play` guarda o `.pendingUsage` e grava se o `.requestUsage` não chegou (`BotSession+Turn.swift:100-127`).
- **Saída contada como entrada**: não; **raciocínio fora da conta**: não (já está em `output_tokens`/`completion_tokens`).
- **Preço ao modelo errado**: a normalização remove prefixo do provedor, `:thinking`, data e `-latest`, e só aceita sufixos de mesma família (`codex`, `preview`, `chat`…); `-mini`, `-pro` ficam sem preço em vez de herdar o do irmão.
- **Aviso "O provedor não está reaproveitando…"** (`CacheHealth`): dispara com 3 ou mais chamadas, prompt médio de 4.096 ou mais e razão abaixo de 20% da soma do turno, só em cliente que arruma cache (`arrangesPromptCache`: Anthropic, Claude Code, OpenAI, Responses em `api.openai.com`/`chatgpt.com`), uma vez por turno e por conversa. A primeira chamada de um turno é sempre uma escrita, por isso o juízo é pela soma e não pela primeira. Não achei jeito de falso positivo no desenho; a única imprecisão é que as chamadas descartadas entram no prompt total mas não em `requestsWithUsage` (efeito desprezível).

## 2. Erros de contagem achados (com evidência e teste)

### P1-1. Um evento posterior apagava o que o primeiro tinha dito (corrigido)

`AnthropicStreamAssembler.record` e o do Claude Code (`ClaudePipeStepState.record`) trocavam cada campo pelo valor do evento mais recente (`total.input = value`, etc.). Pela API da Anthropic o `message_delta` repete os totais acumulados e isso funcionava, mas gateways no formato Messages (e versões antigas) mandam `"input_tokens": 0` e nenhuma leitura de cache no `message_delta`: o prompt inteiro da chamada, 50 mil tokens por exemplo, virava 0. O efeito era custo zerado, razão de cache 0 (e o aviso de cache disparando sem motivo) e a barra de uso errada.

- Antes: `Engine/AnthropicClient.swift` (`record`, linhas 337-346 da versão anterior) e `ClaudePipe/ClaudeCodeClient.swift:577-588`.
- Correção: `TokenUsage.absorb(messages:)` (`EngineTypes.swift:334`) guarda o maior valor visto de cada contagem; as contagens de uma resposta só crescem.
- Teste que falhava: `AnthropicClientTests.aLaterEventNeverLowersWhatTheFirstOneReported`.

### P2-1. Resposta cortada ou parada contava 1 ou 2 tokens de saída (corrigido)

A Anthropic diz a saída de verdade só no `message_delta`; no `message_start` vai `output_tokens` 1 ou 2. Uma resposta cortada por queda de rede, erro no fluxo ou "Parar" é cobrada pelo que foi escrito até fechar a conexão, e o app contava só esse 1. O evento adiantado `.usage` existe justamente para não perder a entrada, mas não a saída.

- Correção: o assembler soma os caracteres que já chegaram (texto, argumentos de ferramenta, raciocínio) e, antes do `message_delta`, `usage` devolve a saída estimada pelo mesmo 3,5 caracteres por token do histórico, nunca abaixo do que o provedor disse (`AnthropicClient.swift:272`, `TokenUsage.withOutput(atLeastCharacters:)` em `EngineTypes.swift:350`). Em `BotSession.play` a parada do usuário usa o texto mostrado desde o `.pendingUsage` (`BotSession+Turn.swift:106-125`).
- Ordem de grandeza: uma parada no meio de uma resposta de 400 a 1.000 tokens deixava de contar essa saída; em Opus (US$ 25 por milhão) são US$ 0,01 a 0,025 por parada. Pequeno por ocorrência, mas é conta errada e some do relatório de uso.
- Testes que falhavam: `AnthropicClientTests.aResponseCutOffCountsWhatItHadWritten` e `UsageEventsTests.aCallStoppedMidAnswerCountsTheWordsAlreadyWritten`.

### P2-2. Nota de trecho lida só até o teto (corrigido) e P3-1, ramo morto do assistente (corrigido)

`ChunkSummarizer.write` para de ler quando o texto passa de `maxLength + 400`, então nunca vê o `message_delta` e contava a saída do `message_start`; agora usa a mesma estimativa (`ChunkSummary.swift:267`). O teste `ChunkCallTests.aReplyTooShortOrAFailureMakesNoNoteButKeepsWhatItCost` fixava a saída zerada e passou a esperar a estimativa.

`WizardRunner.consume` tinha `case .usage(let total): if !tracksHistory { record(total) }`. Hoje `tracksHistory` é sempre verdadeiro, então o ramo não roda; mas `.usage` é a soma corrente do turno, e gravá-la a cada chamada contaria a primeira chamada de novo na segunda. Virou `case .usage: break` com a razão em comentário.

### Conferido sem erro: o que um teste novo passa a guardar

`CachePrefixStabilityTests.eachStepsRequestIsTheStartOfTheNextOne` monta um turno de três passos (duas chamadas em paralelo, raciocínio criptografado do Responses com `callsBefore`, `thinking` assinado da Anthropic, resultados) e confere, nos três formatos, que tudo que vem antes da conversa (ferramentas, sistema, modelo, `prompt_cache_key`) é idêntico entre passos e que cada item da conversa, menos o último, é idêntico no passo seguinte. Passou sem correção: o prefixo é estável.

## 3. Cache de prompt

**Anthropic** (`AnthropicClient.requestBody`, linhas 141-214): quatro marcadores no máximo, na ordem em que a API exige (os de vida longa primeiro): última ferramenta e sistema com TTL de 1 h em `api.anthropic.com` (5 min nos outros hosts, que podem não conhecer `ttl`), cauda da conversa com 5 min, e um quarto marcador no resultado `stableToolCallID` das tarefas longas (as prévias de saídas antigas entram em lotes a ~30 mensagens do fim, além dos 20 blocos que a API olha para trás). O marcador da cauda sempre renova a cada passo; uma nota curta (`forShortReply`) não escreve cache para a cauda. As chaves do JSON saem ordenadas e a conversa por último (`WireEncoder`), então o corpo de um passo é o começo do seguinte. Pensamento (thinking) nunca leva marcador e só vai de volta se assinado e do mesmo provedor e modelo.

**O que fica estável de um turno para o outro**: o prompt de sistema é congelado (a hora, a pasta e as notas de memória vão no começo de cada mensagem do usuário, `TurnPreface`, e a memória nova só como bloco `memory_update`); as ferramentas oferecidas não mudam durante a revisão de skills (`onlyTools` só recusa na execução, `AgentEngine.swift:945`, e não tira a ferramenta da lista, então o início da requisição da revisão é o mesmo do turno); o assistente de criação e as notas curtas têm cliente e prompt próprios.

**OpenAI**: chat usa `prompt_cache_key` só em `api.openai.com` (um host que valida o corpo à risca recusaria o turno inteiro por um campo que não conhece); o Responses usa em `api.openai.com` e `chatgpt.com`; OpenRouter recebe `session_id` e, para Claude, `cache_control` no topo; xAI recebe o cabeçalho `x-grok-conv-id`; OpenCode `x-opencode-session`. As ferramentas do ChatGPT vão como item `additional_tools` na posição 0 do `input`, estável.

**O histórico reescrito e o cache** (`Conversation.prepareHistory`, `ContextWindow.fit`): nada muda enquanto o histórico cabe; ao estourar, desce até a marca de 50% do orçamento (a próxima compactação vem muitas mensagens depois), as saídas de tarefa em andamento ficam inteiras e viram prévia em lotes (a cada 3 além das 3 mais novas, quando passam de 40% do orçamento), capturas de tela saem em lote (de 6 cai para 3), e a condensação (800 caracteres por saída, preâmbulo cortado até a linha "Now:") só anda quando uma compactação já acontece ou quando economiza 8% do orçamento. Com o cache frio (mais de 5 min desde a última chamada) a compactação adianta para 60% do orçamento, porque reescrever já é grátis. A compactação não usa modelo: o resumo vem do `ConversationLedger` (regras); a nota de trecho do modelo é opcional e limitada (seção 5). Não achei reescrita desnecessária fora da virada de turno (item 10).

## 4. Desperdícios no histórico (estimativas)

Referências do código: ferramentas e sistema somam cerca de 8 mil tokens por requisição (6.900 + 1.250 medidos, `ContextBudget.swift:62`), lidos do cache a um décimo do preço. Orçamento de histórico: 40 mil (Econômico) ou 80 mil tokens (Equilibrado, padrão).

| Fonte | O que vai ao modelo | Estimativa | Já controlado? |
|-------|--------------------|-----------|---------------|
| Saída grande de ferramenta | até 30.000 caracteres (~8,5 mil tokens) inline, com o resto em arquivo, e `read_file`/PDF/listagem em páginas de 24.000 (~6,7 mil); `web_fetch` 12.000 (~3,3 mil) | uma saída máxima por passo; segue inteira no turno e vira 4.000 caracteres (~1,1 mil) no turno seguinte, 800 depois | sim (`ToolOutputCap`, `ContextWindow.toolOutputPreview`, `ContextCondensing`) |
| Imagens e capturas | 1.600 tokens estimados por imagem; só as 6 capturas mais novas da tarefa e as imagens dos 3 últimos turnos ficam | até ~10 mil tokens de capturas por chamada em tarefa de navegador, lidos do cache | sim (`elidingOldImages`) |
| Snapshot do navegador / da pasta | a pasta só entra quando o modelo ainda não a viu; só o snapshot mais novo e as mudanças depois dele ficam inteiros | ~1 a 2 mil tokens por turno cortados depois de dois turnos | sim (`ContextCondensing`) |
| Nota de passos omitidos | só quando a tarefa sozinha estoura a janela; uma linha por passo | ≤ 4.000 caracteres (~1.100 tokens) | sim |
| Reenvio de anexos | texto de anexo entra na mensagem e envelhece como qualquer outra; imagem segue a regra acima | sem desperdício achado | sim |
| Raciocínio reenviado | Anthropic: o app não liga thinking, só reenvia o assinado que o endpoint produziu; Responses: itens criptografados vão de volta até a condensação (dois turnos) | de 0,5 a 3 mil tokens por passo de reasoning, lidos do cache | em parte (item 8) |
| Compactação | sem modelo; vai a 50% do orçamento; um resumo ≤ 3.000 caracteres (~860 tokens) mais ≤ 4.000 de "sala" para notas | uma reescrita de cache (≈ 40 mil tokens a 1,25x no Equilibrado) por ~40 mil tokens novos de conversa (estimativa: de 8 a 10 turnos) | sim |

Um turno típico (6 passos, histórico de 40 mil tokens, ferramentas e sistema de 8 mil): 6 × 48 mil = 288 mil tokens de prompt, dos quais cerca de 90% são leitura de cache (≈ 29 mil tokens equivalentes de entrada a preço cheio) mais uma escrita de ~12 mil na virada. A linha de trabalho dizia "~300 mil tokens", acima do que se paga; desde o item 7 conta ~16 mil (entrada, escrita e resposta) e não aparece.

## 5. Chamadas extras de modelo fora do turno

| Chamada | Quando | Modelo | Custo típico | Limite |
|---------|--------|--------|--------------|--------|
| Revisão de skills (`AppModel+SkillReview`) | fim de um turno que tomou 10 passos com ferramenta, nada de leitura-só | o do Orb (para reaproveitar o cache do turno) | em geral 1 chamada ("Nothing to save."): o prefixo do turno lido do cache + poucos tokens; no máximo 6 chamadas | só com ≥ 10 passos, não roda com o limite de propostas pendentes (`MemoryBank.maximumProposals`), `maxSteps = 6` |
| Nota de trecho (`ChunkSummarizer`) | fim de um turno com o histórico a 60% do orçamento | o menor do mesmo fabricante (haiku, mini, flash, lite, nano) quando existe; nunca troca de fabricante, nunca modelo de raciocínio nem gratuito | entrada ≤ 24 mil tokens, saída ≤ 350 palavras | 2 tentativas por trecho; nunca em rotina, Claude Code ou servidor local de um slot |
| Nota de sessão (`SessionNote`) | ao salvar trecho longo na memória | o menor do fabricante, como acima | idem | desligada por padrão |
| Consolidação da memória | memória fixada passou do limite | o "revisor" (`dictationReviewer`, o menor) | uma chamada | no máximo uma por dia se nada mudou |
| Unificar páginas da memória | páginas escritas passaram do limite | idem | uma chamada por grupo | uma vez por dia |
| Revisão do ditado | cada ditado revisado | idem | uma chamada curta | a cada ditado, só com a revisão ligada |
| Título de conversa, resumo de sessão | nenhum chamado a modelo achado | n/a | 0 | n/a |

Conclusão: cada chamada extra já usa o menor modelo possível ou o cache do turno, tem teto de tentativas e cadência, e é contada como `auxiliary` (`recordUsage`). A única que roda no modelo do Orb é a revisão de skills, e é de propósito (trocar de modelo perderia o cache e custaria mais). Nos meus dados do mês as chamadas `auxiliary` pelo Claude Code somam cerca de 7% dos tokens do Claude Code no mês.

## 6. O que ficou como proposta (e por quê)

**P2-3. Enviar `stream_options` a mais hosts, com recuo (ganho: contagem, não tokens).** Hoje só OpenAI, OpenRouter, Command Code e OpenCode recebem `stream_options.include_usage` (`OpenAIClient.swift:39-43`; os testes `compatibleServersGetNeitherUsageNorCacheKeyOnTheWire` e `ProviderTests.swift:178` fixam isso de propósito). xAI (chat), qualquer gateway custom e Ollama/LM Studio só reportam uso se o servidor o fizer sem pedir; vários não fazem. Sem uso não há custo, linha de turno com dinheiro, medidor com cache nem o aviso de cache. Proposta: mandar o campo também a hosts custom e remotos e, se o servidor responder 400/422 falando de `stream_options`, repetir sem ele e guardar o host numa lista de recusas da sessão. Não implementei porque muda um contrato testado de propósito e o recuo mexe no transporte; custo estimado: um 400 barato por host que recusa, uma vez por sessão.

**P2-4. Calibrar o medidor de contexto com o número real.** `ContextMeter.fill` (`ContextMeter.swift:92`) mede `usedTokens` só por estimativa (`3,5` caracteres por token, mais 1.600 por imagem e o raciocínio contado como texto), embora `BotLive.lastUsage.promptTokens` diga o tamanho real da última requisição. A estimativa erra para baixo em JSON e código (cerca de 3 caracteres por token) e para cima em português corrido; o anel, o orçamento de compactação e o "cerca de 42 mil de 128 mil tokens" herdam o erro. Proposta: depois de cada chamada com contagem real, guardar a razão `real / estimado` da requisição que foi enviada (ela já passa por `ContextBudget.tokens(forCharacters:)`) e aplicar uma razão suavizada e limitada a 0,7 a 1,4 ao orçamento e ao medidor do mesmo modelo. Ganho: compactações no ponto certo (hoje uma estimativa 20% baixa deixa o histórico 20% maior que o orçamento dizia, e uma 20% alta compacta cedo e reescreve cache sem precisar). Não implementei: precisa de dados reais da razão por modelo, que o `ORB_DEBUG_USAGE=1` já imprime (`step N: prompt …`) e que só se confere com o app aberto.

**P2-5. `prompt_cache_retention: "24h"` na OpenAI.** O cache em memória da OpenAI dura 5 a 10 minutos de inatividade (até 1 hora); a retenção estendida de 24 h para os modelos que a aceitam não tem custo extra, segundo a documentação da OpenAI de que me lembro (não conferi, sem rede), e o Orb volta a conversas depois de mais de 10 minutos com frequência. Proposta: mandar o campo só em `api.openai.com` e só para modelos de uma lista que o aceitam, com o mesmo recuo do item 4 se o corpo for recusado. Não implementei: não dá para conferir sem chamar a API, e um campo recusado custa o turno. Ganho estimado: no turno que volta depois de 10 a 60 minutos, o histórico (40 mil tokens) é lido a um décimo em vez de pago por inteiro, ou seja ~36 mil tokens equivalentes a menos por volta.

**P3-2. Linha de trabalho com tokens "novos" (corrigido na revisão do código).** `TurnSpend` somava `input + output + cacheRead + cacheWrite`, então um turno de 6 passos com 48 mil de prompt mostrava 300 mil tokens e passava dos 50 mil (`TurnSpend.shownFrom`, "abaixo disso o turno custa pouco demais para dizer") já na primeira chamada de qualquer conversa com histórico: o gatilho não separava mais nada. Era erro de contagem contra o próprio propósito do número, com correção pequena: agora conta `input + cacheWrite + output`, a mesma regra do orçamento de grupo (`UsageTotals.budgetTokens`, `Usage/UsageRecord.swift:57`), em `WorkLine.swift:236-242`. O dinheiro ao lado continua contando as leituras pelo preço delas. O painel de uso (`UsageTotals.tokens`) segue somando tudo, porque lá o número é o volume e não o alerta. Teste: `TurnReliabilityTests.theMeterSaysWhatTheTurnSpentOnceItMatters` (a soma sem leituras, e um turno de 280 mil lidos do cache que não aparece).

**P3-3. Raciocínio criptografado do Responses.** Os itens `reasoning` (com `encrypted_content`) voltam em todos os passos dos dois últimos turnos (`ResponsesClient.requestBody`, linha 94-102); pelo que me lembro da documentação da OpenAI (não conferi, sem rede), o servidor descarta o raciocínio de antes da última mensagem do usuário, então o que vale ainda é o do turno corrente. Proposta: mandar de volta só os itens posteriores à última mensagem do usuário. O orçamento (`contextCharacters`) também conta o `data` desses itens por 3,5 caracteres por token, o que provavelmente superestima. Ganho: até alguns milhares de tokens por requisição e menos bytes na rede; a incerteza é se o servidor cobra o que descarta. Medir com `ORB_DEBUG_USAGE` antes e depois.

**P3-4. "Parar" fora da Anthropic.** OpenAI chat e Responses só dizem o uso no fim, então uma parada ou um corte perde a chamada inteira (a entrada foi cobrada). O assistente de criação também ignora a parada (`consume` sai ao primeiro evento depois do cancelamento). Proposta: gravar uma estimativa marcada como tal. Não fiz: gravaria um número que não é do provedor no histórico de uso.

**P3-5. A virada de turno reescreve o cache (análise).** Na virada do turno, as saídas do turno que acabou deixam de ser "da tarefa em andamento" e viram prévia de 4.000 caracteres (`ContextWindow.fit`, `.tool` na linha 206): o cache muda a partir da primeira saída longa. Em um turno com 4 saídas de 15 mil caracteres, a reescrita custa cerca de 6 mil tokens a 1,25x e economiza cerca de 1,2 mil tokens a 0,1x por chamada seguinte; empata depois de ~6 chamadas. Com o cache já frio (volta depois de 5 min, o caso comum) a reescrita é grátis e o encolhimento é puro ganho. Não vale mudar sem medida: o desenho de "encolher agora" é defensável. A mesma análise vale para uma tarefa que subiu de degrau (`rung`) dentro do turno: no turno seguinte o degrau volta a 0 e as saídas voltam de 800 para 4.000 caracteres, uma segunda reescrita (só em tarefas que estouram a janela sozinhas).

## 7. Observação sobre o Claude Code (dados reais de uso do mês)

Totais do arquivo de uso do mês, sem nomes nem conteúdo. Claude Code, chat com Sonnet: 1.881 chamadas, prompt médio de 97 mil tokens, razão de cache 82%, `input` quase zero (o CLI põe tudo em cache) e escritas de 33 milhões de tokens, todas de 1 h (`cacheWrite1h == cacheWrite`, a 2x o preço de entrada; no plano isso é só o "equivalente"). Nas horas de uso contínuo a razão fica entre 87% e 93%, com 7 a 14 mil tokens de escrita por chamada, que é compatível com o crescimento normal de um passo (resultado da ferramenta mais a resposta). Houve uma hora (14 de outubro, 305 chamadas) com 61% e 41 mil de escrita por chamada, que parece uma tarefa de saídas enormes, não um defeito do prefixo. Cada turno abre um processo novo do CLI com o histórico reconstruído em arquivo de sessão (`ClaudeCodeClient.begin`), então o prefixo só bate com o do turno anterior se o CLI renderizar o histórico reconstruído byte a byte como o original; os números acima sugerem que bate na maior parte, mas não dá para provar sem o app aberto (`ORB_DEBUG_USAGE=1` mostra a razão por chamada, e a primeira chamada de cada turno é a que revela). Vale conferir quando alguém estiver com o app aberto. As conversas do ChatGPT desse mês são todas de 12 de outubro, antes de o prompt de sistema ser congelado (13), por isso mostram razão de 5% a 40% e não servem de medida do estado atual.

## 8. Notas para a frente A (prompt de sistema e descrições de ferramentas)

Só anotado, nada alterado: as ferramentas somam cerca de 6.900 tokens por requisição (medido, `ContextBudget.swift:62`), a maior parte do custo fixo; vale ver, em cada descrição, o que o modelo já sabe sem ela. Como estão em cache de 1 h na Anthropic e lidas a um décimo do preço, o ganho por turno é pequeno (cada 1.000 tokens cortados valem ~100 tokens equivalentes por passo), mas somam por conversa e pesam no primeiro passo e nas voltas depois de uma hora.

## 9. O que não mexi (e por quê)

- Nenhum limite voltou: orçamento de grupo, limite de passos e limites entre Orbs continuam sem corte. O que muda aqui é só conta.
- Estratégia de compactação, o 4.000/800 caracteres das saídas antigas e a escolha do modelo das chamadas extras ficam como estão (análise nos itens 5 e 10).
- Tabela de preços: não conferi com as páginas dos provedores (sem rede); a aritmética e o casamento de nomes têm testes.

## 10. Testes

Novos ou ajustados (todos filtrados, sem suíte inteira): `AnthropicClientTests` (2), `UsageEventsTests` (1), `CachePrefixStabilityTests` (3 casos), `ChunkCallTests` (expectativa corrigida) e, na revisão do código, `TurnReliabilityTests` (item 7). Sem a correção (o código de `c51ba85` com os testes novos) falham quatro: os dois de `AnthropicClientTests`, o de `UsageEventsTests` e o de `ChunkCallTests`; os de `CachePrefixStabilityTests` passam, porque guardam o que já estava certo. Com a correção, 925 testes em 161 suítes de provedores, uso, contexto, compactação, turno, Claude Code e preço passam.
