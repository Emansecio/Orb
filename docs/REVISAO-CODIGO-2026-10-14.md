# Revisão de código, etapa 2: economia de tokens e bugs prováveis (14/10/2026)

Base: `main` em 757d76d. Escopo pedido pela usuária: só a frente 1 (tokens) e a frente 2 (bugs). Desempenho, código morto e testes ficaram fora; o que apareceu de passagem está em uma linha no fim.

Convenções:

- **Tokens equivalentes**: tokens de entrada pesados pelo preço da Anthropic. Leitura de cache vale 0,1×, gravação de cache (5 min) vale 1,25× e entrada sem cache vale 1×. Em dólar, usei o Sonnet a US$ 3 por milhão de tokens de entrada.
- **Tamanhos**: chars ÷ 3,5 = tokens, a mesma conta do app (`ContextBudget.charactersPerToken`).
- **CONFIRMADO**: reproduzido em teste temporário ou sem dúvida pela leitura do código. **PROVÁVEL**: o caminho no código está certo, mas depende de algo que não deu para medir daqui (servidor de terceiros, hardware).

## 1. Resumo

| Prioridade | Achados |
|---|---|
| P0 | 1 (T1) |
| P1 | 2 (T2, B1) |
| P2 | 3 (T3, B2, B3) |
| P3 | 5 (T4, B4, B5, B6, B7) |
| **Total** | **11** (4 de tokens, 7 de bugs) |

### Os 10 primeiros

1. **T1 (P0)**: Claude pelo OpenRouter vai sem `cache_control`, então nada entra em cache. Uma tarefa de 20 passos custa 530 mil tokens de entrada (US$ 1,59). Com o cache, custaria cerca de 100 mil equivalentes (US$ 0,30).
2. **T2 (P1)**: numa tarefa com capturas de tela, a 7ª captura em diante apaga a imagem mais antiga a cada passo. Isso reescreve o cache inteiro a cada passo. Com 40 capturas, a tarefa custa 11% **mais** do que sem cache nenhum. Apagando as imagens em lote, cai 68%.
3. **B1 (P1)**: qualquer erro com a palavra "context" é tratado como estouro de janela, inclusive "context deadline exceeded" e "context canceled" (tempo esgotado e cancelamento). O efeito é cortar 69% do histórico, pular a retentativa e gravar por 7 dias uma janela 15% menor, que encolhe de novo a cada erro.
4. **B2 (P2)**: quando a resposta é interrompida antes de mostrar qualquer coisa, o turno falha sem tentar de novo, mesmo sendo seguro repetir.
5. **B3 (P2)**: o microfone do ditado continua aberto ao sair do chat (Rotinas, Conectores, Skills, um grupo) e também depois de apagar o Orb.
6. **T3 (P2)**: as chamadas à xAI vão sem `x-grok-conv-id`. Sem esse cabeçalho, o acerto de cache da Grok fica por sorte.
7. **T4 (P3)**: em tarefas longas, encurtar saídas antigas muda o pedido mais de 20 posições antes do fim. É mais longe do que a Anthropic procura, então todas as mensagens são regravadas. Um 4º marcador recupera 20% do custo das mensagens.
8. **B4 (P3)**: depois de "Parar" com uma ferramenta pendente, o processo `claude` do Claude Code fica vivo por até 30 min.
9. **B5 (P3)**: os `finish_reason` "insufficient_system_resource" (DeepSeek) e "error" (OpenRouter) são tratados como fim normal. Uma resposta cortada aparece como completa.
10. **B6 (P3)**: apagar um Orb não cancela a consolidação nem a unificação de memória em andamento. Essas chamadas são pagas e não aparecem na página Uso.

### Economia de tokens somada

| Achado | Cenário medido | Hoje | Depois | Economia |
|---|---|---|---|---|
| T1 | Claude via OpenRouter, tarefa de 20 passos | 530 mil (US$ 1,59) | ~100 mil equiv. (US$ 0,30) | **~81%** da entrada, ~430 mil equiv. |
| T1 | mesma, 120 passos | 7,24 milhões (US$ 21,70) | ~1,58 milhão equiv. (US$ 4,70) | **~78%**, ~5,7 milhões equiv. |
| T2 | tarefa com 40 capturas (parte das mensagens) | 433 mil equiv. | 140 mil equiv. | **68%**, ~292 mil equiv. |
| T4 | tarefa de texto com 120 passos, API da Anthropic | 1,33 milhão equiv. (mensagens) | 1,06 milhão equiv. | **20%** das mensagens, ~266 mil equiv. (zero em tarefas de até ~20 passos) |
| T3 | xAI | sem medida | sem medida | teto: o desconto de cache da xAI sobre ~95% da entrada de cada passo |

B1 não economiza tokens. O que ele corrige é qualidade: hoje um tempo esgotado tira 2/3 do histórico do Orb.

## 2. Achados

### P0

#### T1. Claude pelo OpenRouter sem cache de prompt

- **Onde**:
  - `Sources/Orb/Engine/OpenAIClient.swift:73-93` (`requestBody`) e `:42-50` (`stream`).
  - `Sources/Orb/Engine/Providers.swift:320-328`: `openRouterModels` marca todo modelo como `.chat`.
- **O que é**: todo modelo do OpenRouter, inclusive `anthropic/claude-*`, vai no formato Chat Completions. O corpo não leva `cache_control`, nem no topo nem por bloco. Para modelos da Anthropic, o OpenRouter só usa cache com esse marcador. Pela documentação: "Add a single `cache_control` field at the top level of your request". Funciona na Anthropic, Vertex, Bedrock e Azure. Gravar custa 1,25×, ler custa 0,1×.
- **Razão envelhecida**: o comentário em `OpenAIClient.swift:33-35` ("the request would need `cache_control`, which this format does not send") foi escrito em 2bbd9e0. Hoje o OpenRouter aceita o `cache_control` de topo no próprio formato chat.
- **Roteamento grudento**: o corpo também não leva `session_id`. Sem ele, o OpenRouter só fixa o provedor depois do primeiro acerto de cache. Com ele, fixa já no primeiro pedido, e isso vale para todos os modelos (DeepSeek, Grok e OpenAI pelo OpenRouter também têm cache automático).
- **Evidência**: CONFIRMADO pelo código (o corpo é montado só com `model`, `stream`, `messages`, `stream_options`, `prompt_cache_key` só para api.openai.com, `tools` e `tool_choice`).
  - Números da simulação da seção 6: a sobrecarga fixa (system mais ferramentas) é de 37,4 mil chars (≈10,7 mil tokens), e cada passo acrescenta ≈6 mil chars.
  - **Tarefa de 20 passos**: hoje, 316 mil tokens de mensagens mais 214 mil de sobrecarga dão 530 mil a preço cheio. Com o cache, ficam ~30 mil gravados (×1,25), ~290 mil lidos (×0,1) e a sobrecarga gravada uma vez e depois lida: ≈100 mil equivalentes.
  - **Tarefa de 120 passos**: 7,24 milhões contra ≈1,58 milhão equivalente. Esse número já conta as 9 quebras da tarefa e o alcance de 20 posições da Anthropic.
  - **Por pedido, no meio da tarefa (passo 60)**: 85,6 mil tokens a preço cheio contra ≈10,6 mil equivalentes.
- **Correção** (só em `OpenAIClient.swift`):

  ```swift
  var isOpenRouter: Bool { baseURL.host() == "openrouter.ai" }

  // stream(...)
  try WireEncoder.encode(Self.requestBody(
      model: model, messages: messages, tools: tools, includeUsage: reportsUsage,
      promptCacheKey: isOpenAI ? conversationID : nil,
      sessionID: isOpenRouter ? conversationID : nil,
      cacheMarker: isOpenRouter && model.hasPrefix("anthropic/"),
      toolChoice: toolChoice), trailing: Self.trailingKeys)

  // requestBody(..., sessionID: String? = nil, cacheMarker: Bool = false, ...)
  if let sessionID, !sessionID.isEmpty { body["session_id"] = .string(sessionID) }
  if cacheMarker { body["cache_control"] = .object(["type": .string("ephemeral")]) }
  ```

  - O `conversationID` que chega aqui já é estável por conversa: `BotSession.gatewaySessionID()`, um UUID salvo na conversa, que cabe no limite de 256 caracteres do `session_id`.
  - O uso com cache já é lido: `OpenAIClient.usage` conhece `cached_tokens` e `cache_write_tokens`, e o OpenRouter está em `usageHosts`.
  - Deixar `arrangesPromptCache` como está. A propriedade não sabe o modelo, e ligar o aviso de cache para todo o OpenRouter acusaria modelos sem cache.
- **Efeito no cache**: liga o cache, que hoje não existe. O marcador de topo é um só, no fim do pedido. Por isso cada uma das quebras normais da tarefa regrava também system e ferramentas (≈10,7 mil tokens), em vez de só as mensagens, e isso já está no 1,58 milhão. Como passo opcional, dá para pôr um `cache_control` no conteúdo da mensagem de sistema (o OpenRouter aceita até 4 marcadores) e economizar esses ≈10,7 mil por quebra.
- **Risco**: baixo, porque os dois campos são documentados pelo OpenRouter. Um modelo `anthropic/*` abaixo do mínimo cacheável (512 a 4.096 tokens) só deixa de usar o cache.
- **Como verificar**:
  - `swift test --filter OpenAIClientTests`, com um teste novo. Para `https://openrouter.ai/api/v1` e o modelo `anthropic/claude-sonnet-4.5`, o corpo deve ter `cache_control == {"type":"ephemeral"}` e `session_id` igual ao id da conversa. Para `openai/gpt-5`, só `session_id`. Para `api.x.ai` e `localhost`, nenhum dos dois.
  - Depois, no app da usuária: na página Uso, o 2º pedido de uma conversa com Claude pelo OpenRouter deve mostrar leitura de cache maior que zero.

### P1

#### T2. Capturas de tela: a imagem mais antiga sai a cada passo e o cache é regravado inteiro

- **Onde**:
  - `Sources/Orb/Engine/ContextWindow.swift:376-386` (`elidingOldImages`), chamado em toda janela por `fit` (`:147`).
  - O teste existente está em `Tests/OrbAppTests/ImageAttachmentTests.swift:462-472`.
- **O que é**: numa tarefa, só as `maxToolImages = 6` capturas mais novas mantêm a imagem. A partir da 7ª, cada nova captura troca a imagem mais antiga por "[imagem anexada: …]". Essa mensagem fica logo no começo da tarefa, então o prefixo muda em todo passo e tudo depois dela é regravado.
- **Evidência**: CONFIRMADO por simulação de 40 passos, cada um com 1 captura, chamando `ContextWindow.fit` com o mesmo `ContextCut` e comparando o prefixo comum com o pedido anterior.

  | | Quebras de prefixo | Chars lidos do cache | Chars gravados | Tokens equiv. (mensagens) |
  |---|---|---|---|---|
  | Hoje | 34 (do passo 7 ao 40, todos) | 161.829 | 1.198.804 | **433 mil** |
  | Em lote (proposta) | 9 (passos 7, 11, 15, … 39) | 730.956 | 334.614 | **140 mil** |
  | Sem cache nenhum | n/a | n/a | n/a | 389 mil |

  Hoje uma tarefa com muitas capturas custa 11% **mais** do que sem cache, porque quase tudo é gravado a 1,25×. Com a proposta: −292 mil equivalentes (−68%), ou US$ 1,30 → US$ 0,42 por tarefa de 40 capturas no Sonnet. Também se mandam menos imagens em média (de 3 a 6, em vez de sempre 6): 1,36 milhão de chars passam a 1,07 milhão no total.
- **Correção**: apagar em lote, de modo determinístico e sem estado novo. Passando de `maxToolImages`, as mais velhas saem até sobrar a metade, e o conjunto apagado só cresce a cada `max - metade + 1` capturas:

  ```swift
  let toolImages = indices.filter { self[$0].role == .tool && !self[$0].images.isEmpty && $0 >= oldest }
  // Past `maxToolImages` the oldest go in batches (down to half): the start of the request changes every few
  // screenshots instead of at every one, and each change rewrites the provider's cache from there on.
  let floor = Swift.max(1, maxToolImages / 2)
  let keep = toolImages.count <= maxToolImages ? toolImages.count
      : floor + (toolImages.count - maxToolImages - 1) % (maxToolImages - floor + 1)
  let recentToolImages = Set(toolImages.suffix(keep))
  ```

  - Com 6 de máximo, 7 capturas mantêm 3, e 8, 9 e 10 mantêm 4, 5 e 6. Com 11 volta a 3.
  - O teste `aTaskWithManyScreenshotsKeepsOnlyTheNewestOnes`, com 9 capturas, passa a esperar `(5...9)` em vez de `(4...9)`.
  - Uma variante mantém pelo menos 6 imagens: máximo 9 e piso 6. As quebras ficam iguais, com ~3 imagens a mais por pedido (≈+0,5 mil equivalentes por passo).
- **Efeito no cache**: as quebras caem de 34 para 9 em 40 passos. Na virada de turno, a regra dos 3 turnos pode devolver uma imagem que estava apagada, mas o prefixo já muda ali de qualquer jeito.
- **Risco**: baixo. O modelo passa a ver de 3 a 6 capturas recentes, e não sempre 6. Não vale para o Claude Code, que mantém a própria sessão.
- **Como verificar**:
  - `swift test --filter ImageContextTests`, com o teste atualizado e um novo: para n de 7 a 10, `elidingOldImages()` dá o mesmo prefixo até a última imagem apagada.
  - Medição: refazer a simulação da seção 6 e esperar 9 quebras.

#### B1. "context" solto é lido como estouro de janela: corta o histórico, pula a retentativa e encolhe a janela por 7 dias

- **Onde**:
  - `Sources/Orb/Engine/ContextWindow.swift:716-733` (`ContextOverflow.matches`).
  - Quem consome: `Sources/Orb/Engine/AgentEngine.swift:563-567`, em `respond`, transforma em `.contextExceeded` e pula o `withRetries`. `AgentEngine.swift:272-297` corta o orçamento pela metade e grava 85% da janela como "inferida".
  - Onde a janela aprendida é salva: `Sources/Orb/AppModel.swift:1654-1658` (`learnContextWindow`) e `ContextBudget.swift:127-143`, onde a janela vira `min(catálogo, aprendida)`.
- **O que é**: em `.stream` e `.invalidResponse` (e em `.http` 400), basta a mensagem conter "context" ou "too long". Servidores e gateways escritos em Go (Ollama, proxies) dizem "context deadline exceeded" para tempo esgotado e "context canceled" para cancelamento, que são exatamente esses erros.
- **Evidência**: CONFIRMADO por teste temporário.
  - `matches(.stream("server_error", "upstream error: context deadline exceeded")) == true`.
  - `matches(.invalidResponse("… context canceled")) == true`.
  - Num turno com histórico de 30 pares e janela de 200 mil, um `server_error` com "context deadline exceeded" (tipo que entraria na retentativa) produziu:
    - o 1º pedido com 61.607 chars;
    - **nenhuma espera de retentativa**;
    - o 2º pedido com **19.253 chars (−69%)**, porque turnos antigos foram dobrados no resumo e a dobra fica gravada na conversa;
    - `onContextLearned(170000, stated: false)`, isto é, 85% de 200 mil guardados por 7 dias.
  - O erro seguinte do mesmo tipo pega a janela já reduzida e grava 85% dela: 200 mil → 170 mil → 144,5 mil → 122,8 mil, e cada gravação renova os 7 dias.
  - Para um modelo de chat sem janela no catálogo (128 mil), o 2º erro já baixa o teto do nível Equilibrado de 80 mil para ~68 mil tokens de histórico.
  - Num Ollama (16 mil assumidos), um único erro deixa 13,6 mil, abaixo da sobrecarga fixa de um Orb com todas as capacidades (~10,7 mil).
- **Correção** (só em `ContextWindow.swift`): usar as frases específicas que os clientes já usam e não as palavras soltas. Um 413 vale sempre como estouro.

  ```swift
  case LLMError.http(let status, _, _) where status == 413: return true
  case LLMError.http(let status, let text, _) where status == 400: message = text
  ...
  let text = message.lowercased()
  // Specific wordings only: a bare "context" is also how Go servers say a request timed out ("context deadline
  // exceeded") or was cancelled ("context canceled").
  return LLMError.isContextOverflow(text)
      || ["too many tokens", "maximum length", "input length", "context size"].contains { text.contains($0) }
  ```

  `LLMError.isContextOverflow` (`EngineTypes.swift:548-552`) já cobre "context_length_exceeded", "context length", "context window", "prompt is too long", "prompt too long", "input is too long" e "maximum context". "context size" cobre o llama.cpp ("exceeds the available context size").
- **Efeito no cache**: positivo. Hoje um tempo esgotado ainda força uma dobra, e a dobra regrava o cache.
- **Risco**: médio-baixo. Uma mensagem de estouro de algum provedor que só dizia "context" ou "too long" deixa de ser reconhecida. Nesse caso o turno falha com a mensagem do provedor, em vez de tentar com menos histórico. Os testes existentes continuam passando.
- **Como verificar**:
  - `swift test --filter "ContextEngineTests|AgentEngineTests"`.
  - Em `overflowDetection`, acrescentar `!matches(.stream(type: "server_error", message: "context deadline exceeded"))`, `!matches(.invalidResponse("context canceled"))` e `matches(.http(status: 413, message: ""))`.
  - O teste `anOverflowReportedAsATransientErrorSkipsTheRetries` deve continuar passando, porque "prompt is too long" segue reconhecido.
  - Teste novo: `server_error` com "context deadline exceeded" deve gerar 2 pedidos de mesmo tamanho, 1 espera e nenhum `onContextLearned`.

### P2

#### T3. xAI sem `x-grok-conv-id`

- **Onde**: `Sources/Orb/Engine/Providers.swift:478-479` (`client(for:)`). Só o OpenCode recebe um cabeçalho de sessão; a xAI usa o formato chat (`Providers.swift:280-282`).
- **O que é**: a documentação da xAI diz que o cache fica no servidor e que o cabeçalho `x-grok-conv-id` manda os pedidos da mesma conversa para o mesmo servidor, "which improves hit rates". Sem o cabeçalho, cada passo pode cair num servidor sem o prefixo.
- **Evidência**: PROVÁVEL. O cabeçalho falta sem dúvida, mas não medi a taxa de acerto, porque não posso chamar a API.
  - Teto da economia: no meio de uma tarefa, ~95% de cada pedido é prefixo repetido (seção 6), que receberia o desconto de cache da xAI.
- **Correção**: em `Providers.swift:479`, logo depois do cabeçalho do OpenCode:

  ```swift
  if kind == .xai { headers["x-grok-conv-id"] = conversationID } // sticky routing: xAI keeps its cache per server
  ```

- **Efeito no cache**: mais acertos; nada muda no corpo.
- **Risco**: mínimo. É um cabeçalho documentado, com o mesmo id estável usado no OpenCode.
- **Como verificar**: `swift test --filter ProviderTests`, com um teste irmão de `openCodeClientsCarryASessionHeader` para `ProviderAccount(kind: .xai)`.

#### B2. Resposta interrompida antes de mostrar qualquer coisa não é tentada de novo

- **Onde**:
  - `Sources/Orb/Engine/AgentEngine.swift:531-575` (`respond`).
  - O caso `.incomplete` está em `:344-347`.
  - Quem produz `.incomplete`: `OpenAIClient.stopReason` (`:142`), quando o stream acaba sem `[DONE]` e sem `finish_reason`, e `AnthropicClient`, quando falta `message_stop`.
- **O que é**: `withRetries` só tenta de novo quando algo é lançado, e um stream que termina limpo antes do fim não lança nada. O motor encerra o turno com "A resposta foi interrompida: o provedor encerrou antes do fim." mesmo com `reply.emitted == false`, quando repetir não duplica nada.
- **Evidência**: CONFIRMADO por teste temporário. Com um cliente que na 1ª chamada só emite `.finished(.incomplete, nil)` e na 2ª responde "ok", o resultado foi `calls=1` e a falha acima.
- **Cenário**: gateway ou proxy que fecha a conexão sem erro (tempo limite do proxy, reinício do upstream) antes do primeiro token. A usuária precisa reenviar à mão.
- **Correção**, dentro de `operation`, logo depois da linha do `.contextExceeded` (`:561`):

  ```swift
  // Cut off before anything was shown: a dropped stream, worth another try like any transient failure.
  if case .incomplete = reply.stop, !reply.emitted {
      throw LLMError.stream(type: "api_error", message: "o provedor encerrou a resposta antes do fim")
  }
  ```

  `"api_error"` já está em `retryableStreamErrors`. O uso informado na tentativa descartada já é contado (`onDiscardedUsage`).
- **Efeito no cache**: nenhum, porque o pedido repetido é idêntico.
- **Risco**: baixo. Esgotadas as tentativas, a mensagem final passa a ser a de provedor indisponível (`describe(status: 503, …)`) em vez de "A resposta foi interrompida".
- **Como verificar**: `swift test --filter AgentEngineTests`, com um teste irmão de `aTransientFailureBeforeAnyOutputIsRetried`, cuja 1ª resposta é `[.finished(.incomplete, nil)]`. Esperar 2 pedidos e nenhuma falha.

#### B3. Ditado: o microfone fica aberto fora do chat e depois de apagar o Orb

- **Onde**:
  - O único fechamento ao sair está em `Sources/Orb/Views/ComposerView.swift:110-112` (`orbChanged`), e só roda quando o compositor continua na tela e o Orb muda.
  - Não há `onDisappear`.
  - Nem `AppModel.selection.didSet` (`Sources/Orb/AppModel.swift:170-182`) nem `deleteBot` (`:1100-1154`) fecham o ditado.
  - Não existe limite de tempo em `Sources/Orb/Dictation/`.
- **O que é**: o ditado ativo vive em `AppModel.dictation`, enquanto o botão para fechá-lo vive no compositor.
- **Evidência**: CONFIRMADO pelo código. Os cenários:
  - **Sair do chat**: com o ditado aberto no chat do Orb A, a usuária clica em Rotinas, Conectores, Skills ou num grupo. O `ComposerView` some, o microfone continua (a bolinha laranja do macOS fica acesa) e o que for falado continua entrando no rascunho de A.
  - **Apagar o Orb**: se ela apaga o Orb A, o microfone só fecha quando o app sai, e escreve no rascunho de um Orb que já não existe.
- **Correção** (só em `AppModel.swift`):
  - No `didSet` de `selection`:

    ```swift
    // Leaving the chat being dictated into (another Orb, a group, a catalog page): its microphone closes, with its words.
    if let dictating = dictation.botID, selection != .bot(dictating) { Task { await dictation.finish() } }
    ```

  - Em `deleteBot`, antes de `bots.removeAll`: `if dictation.botID == botID { dictation.cancel() }`.
  - A linha de `ComposerView.orbChanged` fica redundante, mas pode ficar.
- **Risco**: baixo. Ajustes é outra janela e não muda `selection`, então abrir Ajustes não fecha o ditado.
- **Como verificar**: teste novo num arquivo próprio. Com `model.dictation.pose(.listening, for: id)`, trocar `selection` para `.routines` e esperar `dictation.phase == .idle`. Repetir com `deleteBot(id)`.

### P3

#### T4. Tarefas longas: encurtar saídas antigas regrava todas as mensagens (alcance de 20 posições)

- **Onde**:
  - `Sources/Orb/Engine/AnthropicClient.swift:127-197`: três marcadores, um na última ferramenta, um no system e um no último bloco.
  - O encurtamento em lote é feito em `ContextWindow.swift`, por `fit`, com `freshShare 0,4` e `freshBatch 3`.
- **O que é**: numa tarefa longa, quando as saídas inteiras passam de 40% do orçamento, `fit` transforma em prévia as mais antigas, cerca de 9 de uma vez. A mudança fica umas 36 mensagens antes do fim. A Anthropic procura uma entrada de cache em no máximo 20 posições antes de cada marcador. Pela documentação, sequências de `tool_use` paralelos contam como uma posição, mas passos alternados não.
- **Evidência**: CONFIRMADO pela simulação com a regra documentada, contando uma mensagem como uma posição (aproximação). Na tarefa de texto de 120 passos (Equilibrado, janela de 200 mil), as quebras ficam nos passos 22, 34, 46, 58, 64, 83, 95, 106 e 117.

  | | Lidos | Gravados | Equiv. (mensagens) |
  |---|---|---|---|
  | Sem o limite de 20 (o ideal) | 19,44 M chars | 1,41 M | 1,06 milhão |
  | Com o limite (o que acontece hoje) | 18,63 M | 2,22 M | 1,33 milhão |

  A diferença é de ≈266 mil equivalentes por tarefa (−20% do custo das mensagens). Em tarefas de até ~20 passos é zero, porque nada é encurtado.
- **Correção** (4º marcador, no fim do trecho já encurtado):
  1. `ContextWindow` passa a expor `stableCount`, o índice em `messages` logo depois da última saída já em prévia, e nil se não houver nenhuma. Ele sai de `cut.settled`: é a mensagem cujo `toolCallID` é o de `raw[taskOutputs[settled - 1]]`.
  2. `LLMClient` (`EngineTypes.swift:411`) ganha o requisito `stream(model:messages:tools:toolChoice:stableCount:)`, com padrão na extensão chamando o atual. O `AgentEngine.respond` passa a chamar esse.
  3. `AnthropicClient.requestBody` marca com `ephemeral` o último bloco do turno que contém a mensagem `stableCount - 1`, se não for o mesmo bloco da cauda.

  Ficam 4 marcadores, o limite da API.
- **Efeito no cache**: a cada encurtamento, o prefixo até o fim das prévias anteriores é lido em vez de gravado. Isso depende de cada lote ter até ~19 posições, que no cenário medido são ~18.
- **Risco**: médio. Mexe no protocolo `LLMClient` e em três arquivos, e um 5º marcador vindo de outro caminho daria erro 400. Fazer depois de T2, B1 e B2, no mesmo pacote.
- **Como verificar**:
  - `swift test --filter RequestBodyTests`: no teste dos marcadores, `found.map(\.place)` deve ganhar o lugar do trecho estável. Acrescentar uma checagem de que nunca há mais de 4 marcadores.
  - Medição: a simulação com o limite de 20 deve ficar perto da linha "sem o limite".

#### B4. Processo `claude` estacionado vive até 30 min depois de "Parar"

- **Onde**:
  - `Sources/Orb/BotSession+Turn.swift:21-31` (`keepForReview` guarda o `TurnRequest` com o `client`) e `:34-42` (só `beginTurn` solta).
  - `Sources/Orb/Engine/ClaudePipe/ClaudeCodeClient.swift:71` (`parkTimeout` de 30 min), `:81-89` (`deinit` encerra o processo) e `:205-220` (`park`).
- **O que é**: quando o modelo pede uma ferramenta, o `ClaudeCodeClient` estaciona o processo do CLI esperando o resultado. Se a usuária clica em Parar nessa hora (ferramenta rodando ou cartão de aprovação aberto), o turno acaba, mas o `reviewBase` continua segurando o cliente.
- **Consequência**: o processo `claude` (Node, mais o servidor MCP "orb" filho) fica vivo até a próxima mensagem para aquele Orb ou até 30 min. Ninguém vai usá-lo: a revisão de skill só roda quando o turno terminou de fato (`finishTurn:400`).
- **Evidência**: CONFIRMADO pelo código. Não rodei o CLI real.
- **Correção**: em `finishTurn`, logo depois de `let completed = succeeded && !paused` (`BotSession+Turn.swift:325`):

  ```swift
  if !completed { reviewBase = nil } // never reviewed: lets go of the client (and Claude Code's parked process)
  ```

- **Risco**: baixo. `stepsSinceSkill` (`:242`) é contado durante o turno, antes disso.
- **Como verificar**: teste novo num arquivo próprio. Depois de `session.stop()` num turno com `reviewBase` preenchido, `reviewBase == nil`. Para ver o processo: com o Claude Code, parar num cartão de aprovação e conferir `pgrep -f "claude.*stream-json"`.

#### B5. `finish_reason` de erro tratado como fim normal

- **Onde**: `Sources/Orb/Engine/OpenAIClient.swift:135-144` (`stopReason`) e `AgentEngine.swift:372` (`.unknown` segue como `.done`).
- **O que é**:
  - A DeepSeek documenta `insufficient_system_resource`, que é a resposta interrompida por falta de recurso.
  - O OpenRouter lista `error` entre os `finish_reason` normalizados.
  - Os dois viram `.unknown(...)` e o motor trata como resposta completa. O texto cortado entra no histórico sem o marcador de interrupção, e sem texto o turno termina calado.
- **Evidência**: CONFIRMADO no código: `stopReason("insufficient_system_resource", …) == .unknown("insufficient_system_resource")`. Para chegar à usuária é PROVÁVEL: no OpenRouter, o erro no meio do stream vem com `error` no topo, que já é tratado. A DeepSeek chega por provedor personalizado ou por gateways que repassam o valor original (não verifiquei OpenCode Go nem Command Code).
- **Correção**: `case "insufficient_system_resource", "error": .incomplete`. Com B2, quando nada foi mostrado, isso ainda ganha retentativa.
- **Risco**: mínimo.
- **Como verificar**: `swift test --filter OpenAIReliabilityTests`, perto da linha 183 (`reason("weird", …) == .unknown("weird")`), acrescentar os dois valores como `.incomplete`.

#### B6. Apagar um Orb não cancela a consolidação nem a unificação de memória

- **Onde**:
  - `Sources/Orb/AppModel.swift:1124-1127`: `deleteBot` cancela `memoryIdle` e `skillReview`, mas não `memoryConsolidation` nem `memoryMerge`.
  - As tarefas estão em `AppModel+MemoryConsolidation.swift:15-37` e `:52-77`.
- **O que é**: se o Orb é apagado durante a chamada, ela termina e é paga. Na volta, `guard … self.bot(botID) != nil else { return }` sai **antes** de `recordAuxiliaryUsage`, então o gasto não aparece na página Uso. No caso da unificação, até a primeira resposta do laço.
- **Evidência**: CONFIRMADO pelo código.
- **Impacto**: uma chamada de modelo menor com a memória fixada, até ~12 mil chars de identidade mais preferências, ou seja, alguns milhares de tokens fora da contabilidade.
- **Correção**: junto de `session.skillReview?.cancel()`, adicionar `session.memoryConsolidation?.cancel()` e `session.memoryMerge?.cancel()`. O cancelamento chega ao stream do cliente e corta a chamada.
- **Risco**: mínimo.
- **Como verificar**: por leitura. Um teste opcional com `clientOverride` lento: apagar o Orb e conferir que o stream foi cancelado.

#### B7. Comando em segundo plano começa depois de "Parar"

- **Onde**:
  - `Sources/Orb/Engine/Tools/ShellTool.swift:63-70`: `await context.shell.resolved()` e depois `startInBackground`.
  - `Sources/Orb/Engine/Tools/BackgroundJobs.swift:108-150`: `start` não confere cancelamento antes de `SpawnedProcess.start`.
- **O que é**: na primeira vez (ou depois de uma falha), `resolved()` roda o shell de login da usuária, o que leva segundos. Se ela clica em Parar nesse intervalo, o comando com `background: true` é iniciado assim mesmo e continua rodando depois do Parar. Um comando em primeiro plano não tem esse problema, porque `ProcessRunner` confere o cancelamento.
- **Evidência**: CONFIRMADO pelo código. A janela é estreita: só a primeira resolução do shell.
- **Correção**: em `ShellTool.swift:67`, depois de `let shell = await context.shell.resolved()`, adicionar `try Task.checkCancellation()`.
- **Risco**: mínimo.
- **Como verificar**: `swift test --filter RunCommandTests`, com um teste novo. Chamar a ferramenta com `background: true` dentro de uma `Task` já cancelada deve lançar `CancellationError` sem criar job.

## 3. Os logs "não foi possível salvar … mktemp failed"

Conclusão: são artefato dos testes. Não é problema do app em uso normal.

- **errno 13 (EACCES)**: CONFIRMADO. Vem dos testes que tiram a permissão de escrita da pasta de propósito:
  - `Tests/OrbAppTests/StoreIOTests.swift:216-235` (`aFailedWriteIsNeverMistakenForAFinishedOne`, `0o555` na linha 225);
  - `Tests/OrbAppTests/StoreTests.swift:71-113` (`0o555` na linha 73).

  `Store.writeFile` (`Sources/Orb/Store.swift:618-643`) registra o NSLog antes de avisar a falha, como deve.
- **errno 2 (ENOENT)**: PROVÁVEL que seja a limpeza dos testes. `removeTestFolder` (`Tests/OrbAppTests/TestSupport/TestFolders.swift:10-19`) sela a pasta e remove. Um escritor do `Store` que já tinha passado pela checagem de `WriteSeals` faz `createDirectory` e o `write(.atomic)`; se a pasta some entre os dois, o `mktemp` não acha a pasta.

  No app, a única remoção de pasta com `Store` vivo é "Redefinir", que sela antes. A janela é a mesma, mas lá os dados estão sendo apagados de qualquer jeito.
- **Como verificar**: `swift test --filter StoreIOTests`. A linha com errno 13 aparece na saída.

## 4. Pacotes de implementação

Os pacotes A, B, C, D, E e F não têm arquivos em comum e podem ser feitos em paralelo. Dentro de cada um, siga a ordem indicada.

| Pacote | IDs (ordem) | Arquivos de código | Testes |
|---|---|---|---|
| **A**: OpenAI/OpenRouter | T1, B5 | `Engine/OpenAIClient.swift` | `OpenAIClientTests.swift` (suítes `OpenAIClientTests` e `OpenAIReliabilityTests`) |
| **B**: provedores | T3 | `Engine/Providers.swift` | `ProviderTests.swift` |
| **C**: motor e janela | B1, T2, B2, T4 | `Engine/ContextWindow.swift`, `Engine/AgentEngine.swift`; T4 também usa `Engine/AnthropicClient.swift` e `Engine/EngineTypes.swift` | `ContextWindowTests.swift`, `ImageAttachmentTests.swift`, `AgentEngineTests.swift`, `RequestBodyTests.swift` |
| **D**: AppModel | B3, B6 | `AppModel.swift` | teste novo em arquivo próprio |
| **E**: sessão | B4 | `BotSession+Turn.swift` | teste novo em arquivo próprio |
| **F**: terminal | B7 | `Engine/Tools/ShellTool.swift` | `ShellTests.swift` (suíte `RunCommandTests`) |

No pacote C, T4 é opcional e vem por último, porque é o único com risco médio. B1, T2 e B2 são pequenos e independentes entre si.

## 5. Não mexer

Pontos que parecem candidatos a mudança, mas estão certos. A maioria foi medida aqui.

- **Encurtamento das saídas em lote** (`freshShare 0,4`, `freshBatch 3`, `freshToolOutputs 3`): na tarefa de 120 passos são só 9 quebras e ~89% dos chars de mensagens lidos do cache. Encurtar passo a passo quebraria o cache em todo passo.
- **Dobra até a marca d'água baixa** (`lowWater 0,5`) com o resumo determinístico do `ConversationLedger`: são 4 dobras em 30 turnos, uma a cada 5 ou 6 turnos, e o par de resumo fica em 1,9–2,7 mil chars.
- **Encurtar as saídas do turno anterior na virada de turno**: a mudança fica perto do fim (dentro das 20 posições) e economiza nos turnos seguintes. São 29 das 33 quebras da conversa de 30 turnos, e 90% ainda é lido.
- **TTL de 1 h só em api.anthropic.com** (`AnthropicClient.stablePrefixTTL`); nos outros hosts, o marcador simples.
- **System prompt estável**: sem data nem hora, e a memória congelada durante a conversa (`memoryUpdate` vai na mensagem, não no system).
- **`WireEncoder` determinístico**, com as chaves que repetem antes de `messages`.
- **`tool_choice: none` no último passo mantendo as ferramentas**, para não mudar o prefixo.
- **Revisão de skill com o mesmo system, ferramentas e histórico do turno**: o `onlyTools` filtra na execução, não no pedido, e é isso que mantém o cache quente.
- **Chamadas auxiliares com o modelo menor do mesmo fabricante** (`dictationReviewer`): resumo de trecho, consolidação, unificação e revisão do ditado. O contexto do ditado é limitado a 4 mensagens de 400 chars.
- **`answeringDanglingToolCalls`** e o **`Store` com escrita atômica e selo**.
- **Descrições de ferramenta**: já foram enxugadas em 2bbd9e0. As maiores (ui_act 1.785 bytes, schedule 1.530, screenshot 1.197) explicam formatos que o modelo precisa.
- **Claude Code só como cano, pela CLI**: o cache é do lado do CLI e não se propõe OAuth direto.

## 6. Medições

### Método

- **Teste temporário** `Tests/OrbAppTests/ZZTokenMeasureTests.swift`, já apagado, rodado com `swift test --filter "ZZTokenMeasureTests|ZZSimulationTests|ZZBugConfirmTests"`. Nenhuma API foi chamada e nada leu o Keychain.
- **Cenário do Orb**:
  - capacidades: terminal, navegador, uso do Mac e conectores (1 conector, GitHub);
  - modo "Perguntar antes";
  - 6 skills;
  - memória com identidade, preferências e 20 notas;
  - 4 colegas;
  - pasta de trabalho: este repositório.
- **Tamanhos**: o system, cada ferramenta e o prefácio foram medidos com as funções reais (`SystemPrompt.make`, `ToolBox.offered`, `WireEncoder`, `TurnPrompt.native`).
- **Simulações**: `ContextWindow.fit` chamado a cada passo com o mesmo `ContextCut`, como o motor faz, comparando o prefixo comum com o pedido anterior:
  - tarefa de texto: 120 passos, cada saída com ~6 mil chars;
  - tarefa de capturas: 40 passos, 1 imagem cada;
  - conversa: 30 turnos de pedido, 3 leituras e resposta.
- **Quebras de cache**: com o limite de 20 posições da Anthropic, uma mudança mais de 20 mensagens antes do fim conta como regravação de todas as mensagens.
- **Fora do que foi medido**: o tamanho real cobrado pelo provedor (usei chars ÷ 3,5) e as respostas do modelo, que nas simulações são pedidos de leitura de arquivo.

### Por parte do pedido

| Parte | 1º pedido | Meio de tarefa longa (passo 60, Equilibrado, janela 200 mil) | Logo depois da compactação (Econômico, 30 turnos) |
|---|---|---|---|
| System | 9.840 chars ≈ 2,8 mil tok | igual (no cache) | igual (no cache) |
| … identidade e comportamento | 1.308 | | |
| … ambiente | 122 | | |
| … permissões | 945 | | |
| … conteúdo não confiável | 341 | | |
| … hábitos e dicas de ferramentas | 1.451 | | |
| … apps do Mac | 1.120 | | |
| … memória (parte estável) | 2.014 | | |
| … skills (6) | 1.144 | | |
| … navegador | 683 | | |
| … colegas (4) | 698 | | |
| Ferramentas (48) | 27.535 bytes ≈ 7,9 mil tok (só terminal: 18, 11.444 bytes) | igual (no cache) | igual (no cache) |
| Prefácio do turno | 2.567 chars (pasta 1.848, notas da memória 616) | dentro do histórico | 99 chars nos turnos seguintes |
| Histórico | só o pedido | 262.265 chars ≈ 74,9 mil tok (48 saídas em prévia, 12 inteiras) | 59–62 mil chars ≈ 17 mil tok (antes da dobra, ~136 mil ≈ 39 mil) |
| Par de resumo | 0 | 0 (a tarefa única não dobra: encurta e põe passos de lado) | 1.933–2.696 chars ≈ 0,55–0,77 mil tok |
| **Total aproximado** | **≈ 40 mil chars ≈ 11,4 mil tok** | **≈ 300 mil chars ≈ 85,6 mil tok** | **≈ 98 mil chars ≈ 28 mil tok** |
| Novo a cada pedido | todo | ~6 mil chars (≈1,7 mil tok) | ~6 mil chars |

### Cache ao longo das simulações (só as mensagens; system e ferramentas têm marcadores próprios)

| Simulação | Pedidos | Quebras | Lidos | Gravados | % lido |
|---|---|---|---|---|---|
| Texto, 120 passos (com o limite de 20) | 120 | 9 | 18,63 M chars | 2,22 M | 89% |
| Texto, 120 passos (sem o limite) | 120 | 9 | 19,44 M | 1,41 M | 93% |
| 40 capturas (hoje) | 40 | 34 | 0,16 M | 1,20 M | 12% |
| 40 capturas (em lote, T2) | 40 | 9 | 0,73 M | 0,33 M | 69% |
| 30 turnos, Econômico | 120 | 33 (4 dobras) | 9,27 M | 1,07 M | 90% |

### Testes que confirmaram bugs

| ID | Resultado |
|---|---|
| B1 | `matches` deu `true` para "context deadline exceeded" e para "context canceled". O turno passou de 61.607 para 19.253 chars, sem retentativa, e aprendeu 170.000 (inferido). |
| B2 | 1 chamada; falha "A resposta foi interrompida: o provedor encerrou antes do fim." |
| B5 | `stopReason("insufficient_system_resource")` = `.unknown("insufficient_system_resource")` |

## 7. Fora do escopo, visto de passagem

- Ollama e LM Studio sem janela no catálogo assumem 16 mil tokens (`ContextBudget.swift:133-135`). Com todas as capacidades, a sobrecarga fixa é de ~10,7 mil, e sobra pouco espaço para o histórico. Não verifiquei o `num_ctx` padrão atual do Ollama.

## 8. O que não deu para verificar

- **Taxas reais de acerto** no OpenRouter, na xAI e no Command Code: não chamei APIs. Os números são de simulação com os preços da Anthropic.
- **Command Code com Claude no formato chat**: não sei se o endpoint aplica cache sozinho.
- **Usage da xAI**: se a API manda o uso sem `stream_options` (`api.x.ai` não está em `usageHosts`).
- **Repasse do `finish_reason` da DeepSeek**: se OpenCode Go e Command Code repassam o valor original.
- **Busca de ferramentas do Claude Code** no servidor MCP "orb" (`ClaudeCode.swift:96-105` remove `ENABLE_TOOL_SEARCH` desligado): o custo em tokens do lado do CLI.
- **B3 e B4 não foram reproduzidos** com microfone e CLI reais, porque abrir o app é proibido nesta análise. As duas conclusões vêm da leitura do código.

## 9. Situação da implementação

Todos os 11 achados foram implementados, cada um com teste. Os testes dos arquivos tocados passaram, e a suíte completa rodou sem `RealBrowser` e `BrowserCleanup`.

| ID | O que mudou | Teste |
|---|---|---|
| T1 | OpenRouter: `session_id` em todo pedido da conversa e, para modelos `anthropic/` e `~anthropic/`, `cache_control` no topo do pedido (o OpenRouter põe o marcador no último bloco cacheável). | `OpenAIClientTests` |
| T2 | As capturas antigas saem em lote: passando de 6, ficam 3 e o número sobe de novo até 6 antes do próximo corte. O começo do histórico muda uma vez a cada 4 capturas, e não a cada passo. | `ImageContextTests` (9 capturas mantêm 5; o conjunto apagado só muda na 7ª e na 11ª) |
| B1 | Só frases específicas contam como estouro. "context deadline exceeded" e "context canceled" deixam de dobrar o histórico e de encolher a janela aprendida. 413 continua contando. | `ContextWindowTests.overflowDetection` |
| B2 | Resposta cortada antes de mostrar qualquer coisa é tentada de novo como falha passageira. Se todas as tentativas forem cortadas, o aviso continua "A resposta foi interrompida…", com o uso de cada tentativa contado uma vez. | `AgentEngineTests` (2 testes) |
| B3 | Sair do chat do Orb (outra página, outro Orb, um grupo) fecha o ditado e mantém o que foi dito. Apagar o Orb cancela o ditado. | `DictationLifecycleTests` (3 testes) |
| T3 | xAI: cabeçalho `x-grok-conv-id` com o id da conversa. | `ProviderTests` |
| T4 | 4º marcador de cache no resultado da última saída já em prévia (`ContextWindow.stableToolCallID`, `LLMClient.markingStable(upTo:)`). No máximo um, mesmo com ids repetidos de outro provedor. | `AnthropicClientTests`, `ContextWindowTests` |
| B4 | Turno que não terminou solta o `reviewBase` e, com ele, o processo estacionado do Claude Code. | coberto pela suíte de turnos |
| B5 | `finish_reason` "insufficient_system_resource" e "error" viram resposta interrompida. | `OpenAIClientTests.mapsFinishReasons` |
| B6 | Apagar o Orb cancela a consolidação e a unificação de memória em andamento. | coberto pela suíte de apagar Orb |
| B7 | Comando em segundo plano não começa se o turno foi parado enquanto o shell de login era lido. | `RunCommandTests` |
