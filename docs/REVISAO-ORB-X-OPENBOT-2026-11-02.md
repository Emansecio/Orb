# Revisão: Orb x OpenBot, com foco no chat rico (02/11/2026)

**Objetivo.** Comparar o Orb com o [OpenBot](https://github.com/nightly-labs/openbot) no que importa para um app local e transformar a comparação em um plano. A prioridade definida é o **chat rico**: renderização e exibição mais organizada.

**Fora do escopo.** Integrações, segurança e serviços de nuvem, por decisão da revisão. Segurança só aparece como limite de projeto quando uma proposta executa conteúdo escrito pelo modelo.

**Base.** OpenBot no commit `ac99196` (01/11/2026), lido em clone local. Orb na árvore de trabalho de 02/11/2026, com mudanças ainda não commitadas.

**Como ler.**

- `[conferido]`: lido diretamente no código nesta revisão.
- `[relato]`: vem do relatório de um agente de leitura, sem nova conferência.
- `[doc]`: visto só na documentação do OpenBot.
- Esforço: **P** (pequeno), **M** (médio), **G** (grande).
- Caminhos com `OB:` são do repositório do OpenBot. Os demais são do Orb.

**Limites.**

- Nenhum dos dois apps foi executado.
- Não há medição de CPU, memória ou tempo de abertura.
- Estimativas de tamanho e de esforço são previsões, não medidas.
- O OpenBot usa licença PolyForm Noncommercial: as ideias podem servir de referência, mas **o código não deve ser copiado**.

## Resumo

O Orb é melhor como agente. O OpenBot é melhor como mesa de operação e, principalmente, como leitor do que o agente produziu.

O chat do Orb é mais calmo: resposta sem balão, trabalho recolhido em uma linha, tempo na conversa, streaming sem reflow. Falta a ele **variedade do que uma resposta pode ser**. Hoje uma resposta do Orb é Markdown com sete tipos de bloco e imagem local. No OpenBot ela também pode ser diagrama, fórmula, página HTML, código com realce, tabela exportável e cartão interativo.

O caminho recomendado é:

1. Fazer primeiro o que é nativo e barato: realce de código, tabelas exportáveis, diff com cor, voltar ao fim e caminhos clicáveis.
2. Usar Swift Charts para gráficos, que já é usado no app.
3. Desenhar Mermaid e KaTeX em um `WKWebView` escondido e mostrar o resultado como imagem, sem nenhum `WKWebView` por linha da conversa.
4. Deixar a página HTML interativa para o fim, porque ela é a única peça que executa JavaScript escrito pelo modelo.

## Chat rico: comparação

### O que o Orb tem hoje

Conteúdo da resposta (`Sources/Orb/MarkdownBlocks.swift:13`) `[conferido]`:

- parágrafo, título, lista (com tarefas), citação, código, tabela e linha horizontal;
- imagem local `![...](/caminho)`, nunca da web.

Decisões boas que devem ser preservadas:

- O texto é cortado nos mesmos pedaços durante e depois do streaming: "nada se move quando chega o último flush" (`MarkdownBlocks.swift:6-9`).
- Código longo e tabelas longas em streaming têm custo limitado por pedaços (`CodeBlockView.StreamCut`, `TableBlockView.FloorMeasure`).
- A seleção atravessa parágrafos, títulos e listas de uma resposta (`Views/SelectableProse.swift`).
- As palavras entram com fade, sem refazer layout (`Views/TextFade.swift`).
- Trabalho recolhido em uma linha, com desfecho, tempo e volume (`ToolTally.swift`, `MultiOrb/TranscriptFolding.swift`, descrito em `docs/MANUAL.md`).
- Marcas de hora, citar trecho, ⌘F com realce, e anexos em grade.

### Inventário lado a lado

| Recurso | OpenBot | Orb | À frente |
|---|---|---|---|
| Realce de sintaxe | Sim, com `@speed-highlight/core`; durante o streaming, só linhas completas (`OB:…/conversation/CodeBlock.tsx:8,155`) `[conferido]` | Não; código monocromático (`Views/MarkdownBlockViews.swift`) `[conferido]` | OpenBot |
| Números de linha e nome do arquivo | Sim (`CodeBlock.tsx:199,219`) `[conferido]` | Não; o cabeçalho mostra só a linguagem `[conferido]` | OpenBot |
| Linhas longas | Quebra a linha (CHANGELOG, linha 366) `[doc]` | Quebra a linha: `Text` na largura do bloco, sem rolagem lateral (`MarkdownBlockViews.swift:324`) `[conferido]` | Empate |
| Fórmulas | KaTeX carregado sob demanda, com cache (`MathFormula.tsx:5-11`) `[conferido]` | Não `[conferido]` | OpenBot |
| Mermaid | Sim, com tema, carregado sob demanda e desenhado como imagem (`mermaid-diagram.ts`, `chat-preview.ts:89`) `[conferido]` | Não `[conferido]` | OpenBot |
| Vista ampliada | Cresce a partir do bloco; arrastar, zoom, teclado (`CodePreview.tsx:199`, `DiagramCanvas.tsx:11`) `[conferido]` | Só Quick Look para imagens | OpenBot |
| HTML estático em bloco ` ```html ` | Sim: sem script e sem rede por CSP (`chat-preview.ts:50`) `[conferido]` | Não | OpenBot |
| Página visual interativa | `html_preview` e `html_render`: sandbox, altura de 80 a 2.000, tema por variáveis CSS, tela cheia, 512 mil caracteres (`chat-visual.ts`) `[conferido]` | Não | OpenBot |
| Gráficos | Pela página visual; dependem de JS e CDN `[conferido]` | Só imagem que o Orb gerou | OpenBot, mas o Orb pode superar com Swift Charts |
| Tabela | Copiar Markdown e CSV (`DataTable.tsx:111-112`), bloco de comparação `[conferido]` | Boa largura de colunas e rolagem; **sem copiar** (`MarkdownBlockViews.swift:346`) `[conferido]` | OpenBot |
| Cartões interativos | `ask_ui`: `confirm`, `quick_replies`, `choice`, `form` com data, seleção e segmentos (`ui-blocks.ts`) `[conferido]` | `ask_user`: opções curtas e resposta livre (`Engine/Tools/AskUserTool.swift`, `Views/QuestionCard.swift`) `[conferido]` | OpenBot |
| Plano | Bloco na conversa com anel e estados (`TaskList.tsx:37`) `[conferido]` | Anel na linha de trabalho, só enquanto há passo aberto (`Views/TaskPlanRing.swift`) `[conferido]` | OpenBot |
| Subagentes no turno | Bloco com o estado de cada um, detalhes no painel (`Subagents.tsx:158`) `[conferido]` | Linhas de evento de delegação `[relato]` | OpenBot |
| Esperando respostas | Bloco acima do compositor (`AwaitingReplies.tsx:60`) `[conferido]` | Não achei equivalente `[relato]` | OpenBot |
| Cartões de mudança | Rotina criada e afins, com ação (`ChatActionCard.tsx:41`) `[conferido]` | Texto da ferramenta | OpenBot |
| Resumo do turno | "9 steps · Memory: 2 saved" (`AgentSteps.tsx:129`) `[conferido]` | "Trabalhou por 1 min 05 s · 12 ações", com o desfecho `[conferido]` | Orb |
| Diff de edição | Realça blocos `diff` (`CodeBlock.tsx:44`); não achei componente próprio para edições `[conferido]` | Texto com `- ` e `+ `, até 8 linhas, sem cor por linha (`Engine/Tools/FileTools.swift:277`) `[conferido]` | Ninguém: oportunidade |
| Caminho de arquivo na resposta | Vira chip que abre a prévia (`MarkdownMessageText.tsx:991`) `[conferido]` | Texto ou código; não achei caminho clicável `[conferido]` | OpenBot |
| Fontes numeradas | `MessageCitation` com rodapé (`RichMessageText.tsx:58,77`) `[conferido]` | Links comuns no texto | OpenBot |
| Navegar em conversa longa | Trilho com um marco por pedido (`ChatScrollRail.tsx`) `[conferido]` | ⌘F | OpenBot |
| Voltar ao fim | Pílula com contagem do que chegou (`MessageNavigation.tsx:22`, `new-message-tally.ts`) `[conferido]` | Segue o fim sozinho, mas não achei botão de voltar (`Views/ChatView.swift:304`) `[conferido]` | OpenBot |
| Divisor de não lidas | Sim (`UnreadMessages.tsx`) `[conferido]` | Só contagem na lateral; não achei divisor `[conferido]` | OpenBot |
| Pergunta lateral | Pergunta fora do chat, sem ferramentas, descartada ao fechar (`SideQuestionPanel.tsx:68`) `[conferido]` | Não | OpenBot |
| Ações na seleção | Citar, Explicar, Melhorar (CHANGELOG, linha 917) `[doc]` | Citar e Copiar `[conferido]` | OpenBot, por pouco |
| Prévia de arquivos | Painel na conversa: PDF, planilha, áudio, vídeo, Markdown e HTML `[relato]` | Quick Look com setas (`Views/QuickLookPreview.swift`) `[relato]` | OpenBot no fluxo; Orb no custo |
| Imagens | Galeria justificada e visualizador próprio (`image-gallery-layout.ts`, `ImageLightbox.tsx`) `[conferido]` | Grade fixa e Quick Look `[conferido]` | Empate na prática |
| Hora na conversa | Só separador de dia (`chat-day-markers.ts`) `[conferido]` | Dia e retomada depois de 15 min (`docs/MANUAL.md`) `[conferido]` | Orb |
| Refazer e editar | Não achei `[relato]` | Sim, com avisos de efeitos (`Rewind.swift`) `[relato]` | Orb |
| Streaming | Revelação suave por palavras (`streamingReveal.ts`) `[conferido]` | Fade e custo limitado (`TextFade.swift`) `[conferido]` | Empate |
| Lista longa | Virtualização com `@tanstack/virtual-core` `[conferido]` | `LazyVStack` e cache de parse `[relato]` | Sem medição |
| Falha ao desenhar | Linha inválida vira aviso curto (`ChatRowBoundary.tsx`) `[conferido]` | Não se aplica do mesmo jeito em SwiftUI | Não comparável |

### O que o OpenBot acerta no desenho

- **Pesado só quando aparece.** KaTeX e Mermaid carregam na primeira ocorrência, porque a maioria das conversas não usa nenhum dos dois.
- **Durante o streaming, mostra o código.** "Meia página ou meio diagrama não vale desenhar" (`CodePreview.tsx:20`).
- **Fonte sempre recuperável.** Um diagrama inválido continua como código, com o motivo em cima, e toda prévia alterna com o código.
- **Mermaid como imagem.** O SVG vira imagem, então um diagrama não custa uma página viva por linha.
- **Cache de fórmula.** Cada fórmula é composta uma vez, com limite de tamanho.
- **Duas categorias de HTML.** Estático sem script e sem rede, e interativo em sandbox, com regras separadas.
- **O modelo aprende pouco e diretamente.** A orientação diz o que renderiza e pede para não repetir o que a página já mostrou (`OB:src/backend/agent/tool-guidance.ts:122-125`).
- **Resposta de cartão sobrevive a cliente antigo.** O bloco tem perguntas de reserva: quem não entende o cartão ainda consegue responder.

### O que não copiar

- `@tanstack/virtual-core` ou reescrever a lista: não há medição que mostre problema no `LazyVStack`.
- `SelectionActions` inteiro: 751 linhas de web para algo que o `NSTextView` já resolve em boa parte.
- Visualizador de imagens próprio: Quick Look já serve.
- Prévias próprias de planilha e PDF: Quick Look cobre sem renderizador para manter.
- CDN em página visual: contraria o foco local e faz cada resposta depender de rede.
- Trocar o streaming do Orb: o desenho atual é mais simples e não perde nada.

## Plano do chat rico

### Princípios

1. **Nativo primeiro.** SwiftUI, Swift Charts e `NSAttributedString`. `WKWebView` só para o que não tem caminho nativo razoável.
2. **A fonte continua sendo o texto.** Copiar como Markdown, buscar, citar e refazer funcionam sobre o Markdown original, sem depender do que foi desenhado.
3. **Nada novo no caminho quente.** Blocos ricos aparecem em forma de código durante o streaming e são trocados uma vez, quando o bloco fecha. `body` continua sem trabalho.
4. **Toda falha volta para código.** Um bloco que não desenha mostra a fonte e o motivo, nunca um espaço vazio.
5. **Cada entrega fica de pé sozinha.** Cada onda é útil mesmo que a seguinte nunca aconteça.
6. **Visual igual ao vizinho.** Mesmo fundo, raio, espaçamento e botão de Copiar do `CodeBlockView`. Conferir em 460 e 1100 pt.

### Modelo proposto

Em `MarkdownBlock`, acrescentar só o que tiver renderizador pronto:

```swift
case chart(ChartSpec, source: String)     // onda 2, fence `chart`
case diagram(source: String)              // onda 3, fence `mermaid`
case math(tex: String)                    // onda 3, $$…$$ em bloco
```

Com isso, `parsePiece` continua sendo o ponto único de leitura e a regra de `ReplyParagraphs` não muda. Um fence aberto continua saindo como `.code` com `isClosed: false`, e só depois de fechado vira bloco rico. Assim nada se move durante o streaming, exceto a troca única no fechamento.

Fórmula inline (`$…$`) fica fora da primeira versão: ela exige leitura dentro do `AttributedString` e tem alto risco de falso positivo com preços em reais e dólares.

### Serviço de desenho para Mermaid e KaTeX

Um único `RichRenderer` `@MainActor`:

1. Mantém **um** `WKWebView` escondido, criado na primeira necessidade e fechado depois de um tempo parado.
2. Carrega um HTML local com `mermaid` e `katex` nos recursos do app, sem rede, usando `WKWebsiteDataStore.nonPersistent()`.
3. Recebe a fonte, devolve SVG ou imagem e mede o tamanho.
4. Grava em cache em disco por hash de fonte e versão, com limite de tamanho, em pasta derivada que pode ser apagada.
5. Processa uma fila, um bloco por vez, com prazo. Estourado o prazo, o bloco fica como código.

A linha da conversa só desenha a imagem. Nenhum `WKWebView` entra no `LazyVStack`, o que preserva a rolagem e a memória.

**Decisão necessária.** O Orb é "sem dependências externas". Os arquivos JS em `Resources/` não são dependência SwiftPM, mas são código de terceiros mantido dentro do app e aumentam o bundle. A alternativa é escrever só um subconjunto nativo de `flowchart`, com muito menos alcance. Recomendo os recursos JS, com versão fixa e hash, como já acontece com o `agent-browser`. Se a regra for mantida à risca, as ondas 1 e 2 continuam valendo sozinhas.

### Ondas

#### Onda 1: leitura melhor, tudo nativo

Todos os itens feitos em 02/11/2026. Os itens 1 a 4: `Sources/Orb/CodeHighlight.swift`, `MarkdownBlockViews.swift`, `ChatView.swift`. A volta ao fim vale para o chat de um Orb, em macOS 15 ou mais novo; a conversa de grupo não tem. Copiar CSV põe um apóstrofo antes de células que começam com `=` ou `@`, para a planilha não as rodar como fórmula.

| # | Entrega | Onde mexer | Esf. | Pronto quando |
|---|---|---|---|---|
| 1 | **[feito]** **Realce de sintaxe** para as linguagens mais usadas (Swift, Python, JS/TS, shell, JSON, HTML/CSS, SQL, Markdown, YAML, diff). Tokenizador próprio e pequeno, fora da main, com cache. Em streaming, sem realce ou só linhas completas. Acima de um teto, texto simples | Novo `CodeHighlight.swift`; `CodeLines` em `MarkdownBlockViews.swift`; cores em `Theme.swift` | M | ScrollBench sem piora; ⌘F continua marcando; seleção e Copiar intactos |
| 2 | **[feito]** **Tabela com Copiar**: Markdown e CSV (RFC 4180), no mesmo botão do código | `TableBlockView`, `MarkdownBlocks.swift` | P | Vírgula, aspas e quebra de linha testadas |
| 3 | **[feito]** **Diff com cor** em `edit_file` e nos cartões de aprovação: linhas verdes e vermelhas, sem depender só da cor | `TranscriptViews.swift`, `Theme.swift`; hoje a fonte é `EditFileTool.diff` | P | Reconhecível em VoiceOver e em alto contraste |
| 4 | **[feito]** **Voltar ao fim** com contagem do que chegou, aparecendo só ao sair do fim | `ChatView.swift` (`followsBottom`) | P | Não pisca durante o streaming; some ao voltar |
| 5 | **[feito]** **Divisor "Novas"** ao abrir uma conversa com não lidas | `ChatView.swift`, contagem de não lidas | P | Não salta quando imagens carregam |
| 6 | **[feito]** **Caminhos clicáveis**: caminho absoluto que existe vira link, abre em Quick Look, com Mostrar no Finder. A verificação de existência fica fora do `body` | `MarkdownCache`, `SelectableProse.swift`, `AttachmentInfo.swift` | M | Texto parecido com caminho não vira link falso; copiar mantém o texto |
| 7 | **[feito]** **Código longo recolhido**, com "Mostrar tudo", no mesmo padrão da saída de comando | `CodeBlockView` | P | Busca abre o bloco quando o resultado está dentro |

#### Onda 2: organização e gráficos nativos

| # | Entrega | Onde mexer | Esf. | Pronto quando |
|---|---|---|---|---|
| 8 | **[feito]** **Gráfico nativo** com fence `chart` e JSON curto: barras, linhas, área, pizza. Desenhado com Swift Charts. JSON inválido fica como código | `MarkdownBlocks.swift`, novo `ChartBlockView.swift`, `SystemPrompt.swift` | M | Cores do `Palette` e Reduzir movimento corretos; dados acessíveis em VoiceOver |
| 9 | **[feito]** **Trilho de pedidos**: um marco por mensagem sua, título ao passar o mouse, clique leva ao pedido. Usa `scrollTo(id)`, sem medir posições | `ChatView.swift`, `OrbTranscript` | M | Só aparece a partir de 2 pedidos e em janela larga; alcançável por teclado |
| 10 | **[feito]** **Plano como cartão na conversa**, que permanece depois do fim, além do anel | `TaskPlanRing.swift`, `TranscriptViews.swift` | M | Atualiza no lugar, sem criar linhas novas |
| 11 | **[feito]** **Vista ampliada** para código, tabela e diagrama, em folha grande ou no inspetor | `SheetKit.swift`, blocos | M | Esc fecha; respeita Reduzir movimento |
| 12 | **[feito]** **Cartões de mudança**: rotina criada, memória guardada, Orb criado, com ação de abrir e desfazer quando existir | `TranscriptViews.swift`, `WorkLine.swift` | M | O resultado da ferramenta continua igual para o modelo |
| 13 | **[feito]** **`ask_user` melhor**: seleção múltipla e formulário curto, com reserva em texto. Dá para trocar por um parâmetro em vez de ferramenta nova | `AskUserTool.swift`, `QuestionCard.swift` | M | Fila, Pular, Esc e grupos continuam funcionando |
| 14 | **[feito]** **Pergunta lateral**: pergunta sobre o chat, sem ferramentas, sem entrar no histórico | Inspetor ou painel; `AppModel` | M | O tamanho do histórico do modelo não muda; uso contado como `auxiliary` |
| 15 | **[feito]** **Fontes**: rodapé com páginas lidas no turno, derivado de `web_fetch` e `web_search`, sem pedir nada ao modelo | `TranscriptViews.swift`, `TranscriptFolding.swift` | M | Sem mudança no prompt |

O que mudou no caminho, em relação à tabela: 12 ficou como linhas sob a resposta (rotina, memória, grupo), com "Abrir" onde há destino, sem desfazer e sem Orb criado, que já tem cartão próprio. 10: o plano terminado continua na linha do evento, com as etapas. 14 usa o modelo barato do Orb e abre por ⇧⌘K ou pela paleta.

#### Onda 3: diagramas e fórmulas

Feita em 02/11/2026. Mermaid 12.2.0 e KaTeX 0.19.1 (5,8 MB) em `Sources/Orb/Resources/Rich`. O `WKWebView` escondido funcionou sem janela. Além de `$$…$$`, o fence `math` também vira fórmula. Nenhum `WKWebView` é criado sem um bloco desses, mas o framework WebKit passa a ser ligado ao app.

| # | Entrega | Esf. | Pronto quando |
|---|---|---|---|
| 16 | `RichRenderer` com um `WKWebView` escondido e cache em disco | G | Nada de WebKit carregado em conversa sem diagrama ou fórmula |
| 17 | Mermaid em fence `mermaid`, com as cores do Orb e alternância entre desenho e código | M | Diagrama inválido fica como código, com o motivo |
| 18 | KaTeX em bloco `$$…$$` | M | Preço com `$` nunca vira fórmula |
| 19 | Vista ampliada de diagrama com zoom e arrasto | P | Teclado e trackpad |

#### Onda 4: páginas visuais

Feita em 02/11/2026, com duas mudanças. A prévia de `html` é um botão, porque esse fence quase sempre é código a ler. E a página interativa é o fence `page`, não a ferramenta `html_render`: a página fica no Markdown da resposta, sem novo item persistido e sem spec em cada requisição. Roda só numa folha, o que garante uma por vez e nenhum `WKWebView` na lista; a miniatura é sem scripts. Pode ser desligada em Ajustes.

Na revisão própria, um harness com servidor local que registra HTTP, TCP e UDP não viu nenhum acesso, em todos os vetores tentados. O `preconnect` passa pelo CSP e só a lista de regras o barra, por isso sem regras não há página. DNS prefetch ficou inconclusivo: o padrão do WebKit é desligado, mas não houve controle positivo. A revisão também fechou esquemas de link além de http(s) e mailto, que já abriam qualquer app.

A revisão das vistas achou 14 pontos, todos conferidos no código e 13 corrigidos: custo por item no `refold`, o rastro saltando durante o turno, a linha "Novas" perdida com duas saídas, o Return e o ⌘↩ nos formulários, folha presa em carregamento, falhas passageiras gravadas como permanentes, links perdidos com seleção ativa, séries sem nome, área com ponto isolado e a pergunta paralela refeita por token. Ficou como está, por decisão: o bloco longo dobra quando o fence fecha, mesmo seguindo o fim, porque mantê-lo aberto desfaria a organização. Também ficou: a busca conta ocorrências na fonte de gráficos e diagramas, sem destacá-las no desenho.

| # | Entrega | Esf. | Pronto quando |
|---|---|---|---|
| 20 | Fence `html` estático: sem script e sem rede | M | CSP e ausência de JS testados |
| 21 | `html_render`: página interativa, **uma viva por vez**; as demais mostram a captura até o clique | G | Passa pela revisão abaixo |

Limites de projeto da onda 4, mesmo com segurança fora desta revisão, porque o conteúdo é escrito pelo modelo:

- Sem rede por padrão, ao contrário do OpenBot.
- Sem acesso a arquivos, cookies e armazenamento persistente.
- Armazenamento de dados não persistente e nenhuma ponte que execute ações.
- Uma página só pode propor texto ao compositor; quem envia é a pessoa.
- Altura com limites e tamanho máximo de HTML.
- Precisa de revisão própria antes de ir para a main.

### Orientação ao modelo

Texto enviado ao modelo vai em toda requisição, deve ser em inglês e curto, e precisa ser estável para não quebrar o cache. O precedente é `SystemPrompt.showPicture` (`Engine/SystemPrompt.swift:150`).

- Acrescentar uma frase por recurso, só quando ele existir.
- Medir o custo em tokens por requisição com `scripts/audit-token-usage.py`.
- Avaliar se a orientação pode entrar somente quando a capacidade for relevante.

### Critérios para todas as ondas

**Desempenho.** Medir com `ScrollBench` e `SwitchBench` antes e depois, em conversa longa real. Nenhuma tarefa de realce, tokenização ou verificação de arquivo no `body`. Resultado em cache por conteúdo.

**Acessibilidade.** Diagrama e gráfico precisam de rótulo e de acesso à fonte ou aos dados. Nada pode depender só de cor. Reduzir movimento vale para a vista ampliada.

**Busca.** `ConversationSearch` continua lendo o texto original. Resultado dentro de bloco recolhido abre o bloco.

**Persistência.** O desenho nunca entra na conversa salva: a resposta guarda o Markdown e o cache é descartável. Campo novo só com decodificação tolerante.

**Testes.** Lógica pura em Swift Testing: parser, tokenizador, CSV, leitura do `ChartSpec`, detecção de `$`, detecção de caminho e chave do cache. Rodar com `scripts/test.sh --filter`, com as suítes afetadas.

**Conferência visual.** Criar cenas `--snapshot` (por exemplo, `transcript-rich-code`, `-table`, `-chart`, `-diagram`) em 460 e 1100 pt. Compilar em debug e em release.

### Ordem recomendada

Começar pelos itens 1, 2, 3 e 4: são os que mudam a leitura diária com menos risco. Em seguida, 8 e 9. O item 16 só depois da decisão sobre recursos JS.

## Restante da comparação

### Núcleo do agente

| Área | À frente | Motivo |
|---|---|---|
| Motor do turno | Orb | Motor próprio e comportamento igual em qualquer modelo (`Engine/AgentEngine.swift`). O OpenBot delega a CLIs, e compactação e retomada variam por provedor `[relato]` |
| Provedores | Empate | O OpenBot é mais amplo (ACP, endereços na rede). O Orb trata melhor Ollama e LM Studio, com janela aprendida e custo zero `[relato]` |
| Contexto e tokens | Orb, folgado | Resumo estruturado, cache medido e memória antes de esquecer. O OpenBot compacta a 80% com um turno do provedor `[relato]` |
| Memória | Orb | Páginas por tipo, recuperação por assunto, desfazer. O OpenBot leva em memória compartilhada `[relato]` |
| Skills | Orb | Proposta validada com aprovação. O OpenBot leva na leitura de `~/.agents/skills` `[relato]` |
| Importar | Orb | Hermes, OpenClaw, Character Card, texto livre `[relato]` |
| Ramificar conversa | OpenBot | Em andamento (`OB:plans/010-branch-a-conversation.md`) `[conferido]`; o Orb não tem `[conferido]` |
| Recuperação de crash | OpenBot | Fila persistida e reconciliação de entregas (`OB:src/backend/agent/boot-recovery.ts`) `[relato]`. No Orb, a fila não vai a disco; rascunhos vão `[conferido]` |

### Multiagente e automação

| Área | À frente | Motivo |
|---|---|---|
| Mensagens entre agentes | OpenBot | Anexos e `expectsReply` (`OB:src/backend/openbot-tools.ts:680`) `[relato]`. O `orbs` só aceita `action`, `to`, `message` `[conferido]` |
| Proteção contra loops | Orb | Regras de cadeia e Parar `[relato]` |
| Canais e tarefas | OpenBot | Dono da tarefa, Retomar e Reatribuir `[relato]`. O Orb leva no quadro de memória do grupo `[relato]` |
| Esperas | OpenBot | `await_event` visível (`OB:src/backend/agent-waits/agent-wait-schema.ts`) `[conferido]` |
| Rotinas | Orb | Pré-checagem sem modelo, metas, cron com fuso, espera ao acordar, `wake/` `[relato]`. O OpenBot leva em rotina quieta (`OB:src/backend/agent/routine-quiet-runs.ts`) `[conferido]` e feed `.ics` |
| Workflows | OpenBot | Grafo visual; parte dos nós ainda não roda `[relato]` |
| API local e CLI | OpenBot | Loopback com token e `openbot-cli` `[relato]`; o Orb só tem `wake/` `[conferido]` |
| Tabelas compartilhadas | OpenBot | SQLite comum `[relato]`; o Orb tem quadro em Markdown |
| Acompanhamento | Empate | Tasks no OpenBot; Início do Orb mais voltado a resultados `[relato]` |

### Ferramentas locais e app

| Área | À frente | Motivo |
|---|---|---|
| Computer use | Orb | AX e eventos nativos, sem binário de terceiros. Falta sinal visual nas ações sem takeover `[relato]` |
| Navegador | OpenBot | Painel interativo, PiP, gravação, perfis nomeados `[relato]`. O Orb é mais leve e tem o modo Privado |
| Voz | OpenBot | TTS local e modo conversa `[relato]`. O Orb não tem TTS `[conferido]`; no ditado, empate |
| Diagnóstico de turno | OpenBot | `TraceWaterfall.tsx` `[conferido]` |
| Uso e custo | Empate | O Orb detalha mais o cache `[relato]` |
| Integração com o macOS | Orb | Barra de menus, notificações acionáveis, atalhos catalogados `[relato]` |
| Avatares | Orb | Atividades, visemas e pausa por oclusão `[relato]` |
| Peso | Orb, por inferência | Nativo contra Electron; **sem medição** |
| Plataformas e idiomas | OpenBot | Três sistemas e 13 idiomas `[relato]`; não faz diferença para o foco do Orb |

## Backlog fora do chat

Em ordem de valor para uso local:

| Ideia | Esf. | Referência no OpenBot |
|---|---|---|
| Rotina quieta (`routine_no_update`) | P–M | `src/backend/agent/routine-quiet-runs.ts` |
| Anexos e `expects_reply` no `orbs` | P | `src/backend/openbot-tools.ts:680` |
| Fila de mensagens em disco | P–M | `src/backend/agent/boot-recovery.ts` |
| Borda na janela-alvo durante `ui_act` | P–M | `src/main/computer-use-highlight-window.ts` |
| Ramificar conversa | M | `plans/010-branch-a-conversation.md` |
| Retomar e Reatribuir | M | `src/backend/channel-service.ts:685` |
| Esperas visíveis no Início | M | `src/backend/agent-waits/agent-wait-schema.ts` |
| Linha do tempo do turno | M | `packages/ui/src/features/conversation/TraceWaterfall.tsx` |
| Clique e teclado na tela ao vivo | M | `BrowserLiveView.tsx:194` |
| Ler `~/.agents/skills` | P | `src/backend/home-skills.ts` |
| Feed `.ics` das rotinas | P–M | `src/main/routine-feed-ics.ts` |
| TTS e modo conversa | G | `VoicePanel.tsx`, `src/main/voice-speech-service.ts` |
| `orb run --wait` com loopback e token | M–G | `src/main/automation-server.ts` |

**Descartado por já existir no Orb:** memória essencial e pesquisável (o Orb tem memória fixada) e arquivo de instruções (`identidade.md`, `ORB.md`).

**Descartado por não servir:** delegar o motor a CLIs, editor de workflows em grafo, multiplataforma, 13 idiomas e Chromium embutido.

## Decisões tomadas

1. `mermaid` e `katex` entram como recursos fixos, com versão e hash em `Resources/Rich/VERSIONS.md`, atualizados só por `scripts/vendor-rich.sh`. O app não os baixa.
2. A onda 4 entrou com os limites acima e teve revisão adversarial própria. Os ataques ficam em `PageSandboxLiveTests`, com `ORB_RICH_RENDER_TESTS=1`.
