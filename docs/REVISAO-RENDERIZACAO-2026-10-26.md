# Revisão de animação e renderização — 26/10/2026

## Escopo e método

Foram inventariados **203 arquivos (68.789 linhas)**: todos os Swift de `Views/` e `Orbs/`, toda a transmissão em `LiveScreen/`, entradas de desenho encontradas no restante do app, produtores de estado que alimentam esses caminhos, geradores de arte e scripts de captura/bundle. A lista completa está abaixo. Arquivos de recursos PNG e manifestos são entradas estáticas, não código executado por quadro. Rede, persistência e motor aparecem somente quando fornecem dados ou imagens para a apresentação.

A cobertura de arquivos está concluída para esse inventário. “Triagem estática” significa inspeção de entradas de desenho, coleções, observação, I/O, tarefas e temporizadores; “detalhada” inclui o fluxo de execução e ciclo de vida das áreas críticas. Isso não equivale a instrumentar cada tela em todas as combinações de hardware e dados. Medições abaixo são dos cenários descritos, sem extrapolar um percentual para o aplicativo inteiro.

Busca de fechamento: `NSViewRepresentable`, `NSViewControllerRepresentable`, `CALayer`, `CGContext`, `Canvas`, `ImageRenderer`, `ImageIO`, `TimelineView`, `Timer`, `displayLink`, `repeatCount`, `repeatForever`, `symbolEffect`, `Layout`, métodos `body` e tarefas de atualização. Os relógios foram separados de esperas de rede, prazos de ferramentas e modos de benchmark. A revisão preservou as alterações que já estavam na árvore; a base local foi salva em `build/render-audit/baseline.patch`.

## Correções

1. **Miniaturas:** um pedido em andamento por caminho/tamanho é compartilhado por todos os consumidores; até duas decodificações simultâneas no total. ImageIO recebe `ShouldCacheImmediately`, evitando transferir a decodificação para a primeira apresentação. A tarefa da view considera também o tamanho. O consumidor da foto de perfil descarta resultados cancelados.
2. **Rosto do avatar:** referências de cache ficam retidas até terminar a troca de camadas. Um arquivo que falha em segundo plano conserva o último rosto completo; não há nova tentativa síncrona na thread principal.
3. **Texto durante streaming:** o fade termina sem animar conteúdo oculto/fora do viewport; ao perder visibilidade/atividade, o próximo tick libera o relógio e restaura as cores. Continua sendo uma mudança de atributos temporários, sem layout por quadro.
4. **Indicadores:** pontos do assistente acompanham scroll, atividade, ocultação e desmontagem; efeitos repetitivos do ditado e dos grupos pausam com janela inativa. Sob Reduce Motion, o halo do ditado também deixa de observar as leituras de áudio.
5. **Última tela:** o JPEG retido decodifica em tarefa separada e chega à UI como bitmap pronto; uma troca de foco não recebe o resultado antigo.
6. **Arte offline:** cada passe do cabelo calcula somente base ou brilho. Antes, os dois passes calculavam as duas camadas e descartavam metade do resultado.

## Evidências e medições

- **Concorrência de imagens:** teste com 64 pedidos simultâneos para o mesmo arquivo/tamanho entrega a mesma instância de `NSImage` a todos; tamanho diferente entrega outro bitmap com a resolução esperada.
- **Visibilidade:** testes com NSWindow/NSScrollView verificam que pontos fora do viewport não animam, voltam ao aparecer e param ao ocultar/remover; texto oculto não recebe cores temporárias de fade.
- **Avatares:** testes de resize, troca de expressão, conjunto completo, descarte de pedido antigo e contador de decodificações na main continuam passando.
- **Arte completa:** 12 estilos, 30 PNGs incluindo versões de chapéu. **30/30 arquivos idênticos byte a byte por SHA-256**. Tempo decorrido: **56,02 → 31,98 s**; CPU de processos filhos: **197,31 → 147,29 s** (**25,35% menos CPU**). Uma execução completa antes/depois, com outras compilações presentes; o tempo decorrido não é uma medição isolada de hardware. Três repetições menores do topete: mediana **2,383 → 1,295 s**, também com os quatro PNGs idênticos. Nenhum recurso do produto foi regenerado.
- **Recursos:** todos os 129 PNGs de produção conferidos: 640 × 640 px, 3.493.865 bytes comprimidos ao todo (3,33 MiB), CRCs válidos e streams IDAT descomprimidos sem erro. Fonte já adequada ao editor; o runtime faz downsample e limita os bitmaps em cache. Evidências: `assets.json` e `assets-integrity.json`.
- **App parado, antes:** cinco amostras de um segundo do processo real, 0,0% de CPU informado pelo `ps`, sem avanço do tempo acumulado. Esse estado já não tinha desperdício contínuo reproduzido; não serve para prometer economia adicional em repouso.

### Ensaio de avatares e decisão sobre molas

Foram feitas três repetições de oito segundos por cenário, após três segundos de aquecimento, em release com `ORB_DEV_TOOLS`, `ORB_ANIMATE_INACTIVE=1` e display link real. A coluna de protótipo inclui o fast path de repouso das molas, que foi **removido da entrega** após esse ensaio. Estes números documentam a decisão; não são um antes/depois da versão final.

| Cenário | CPU mediana: base → protótipo | Instruções/s: base → protótipo | Frames/s: base → protótipo |
| --- | --- | --- | --- |
| 1 avatar idle | 1,10% → 1,15% | 9,31 → 9,49 milhões | 13,7 → 14,0 |
| 12 avatares idle | 1,89% → 1,67% | 15,54 → 16,14 milhões | 140,5 → 142,7 |
| 12 avatares typing | 1,84% → 2,51% | 29,61 → 30,47 milhões | 360,1 → 359,6 |

Não houve ganho consistente que justificasse manter o fast path. A CPU da base em typing oscilou de 0,79% a 2,92%, portanto não se atribui causalidade a essas diferenças curtas. O integrador original permanece na versão final. As correções aprovadas atacam caminhos distintos desse estado aquecido: concorrência de imagens, cache frio/evicção e ausência de visibilidade. Não foi demonstrado um percentual global de redução da CPU da interface.

As medições do gerador são de uma ferramenta offline e não representam queda de CPU da interface. O benchmark de avatares mede a própria CPU/instruções do processo com link real; `ticks/s=0` é o contador do emulador desligado, não ausência de frames. As poses contêm aleatoriedade e as amostras curtas têm ruído; compare também frames/desenhos, não só percentuais de CPU.

## Caminhos preservados e oportunidades avaliadas

| Área | Decisão e motivo |
| --- | --- |
| Molas | Um fast path de repouso exato foi ensaiado, testado e descartado: não mostrou ganho consistente no benchmark e acrescentou instruções em alguns cenários. O integrador original foi preservado. |
| Relógio dos avatares | Preservado: um link por tela, lista de ativos mantida, 10–60 FPS por necessidade, descarte de variação inferior a 0,25 pixel e pausa por visibilidade. Batching adicional de `refresh` não foi justificado por um gargalo reproduzido. |
| Retorno ao viewport | Preservado o timer compartilhado de 2 Hz, com tolerância de 250 ms: cobre movimentos de layout sem notificação de scroll e existe apenas enquanto há Orb esperando retornar. |
| Shimmer/pontos de presença | Já usavam Core Animation, 24–30 FPS e suspensão por app/oclusão/scroll; não foram convertidos para estado SwiftUI por quadro. |
| Tela ao vivo | Já limita a uma conexão e uma decodificação + um frame pendente, descarta frames antigos e publica diretamente na layer. Os três segundos após o último espectador são uma troca deliberada por reconexão; preservados. Pausar só o decoder exigiria reter e reapresentar o último frame ao voltar, inclusive em página que não emite novos frames. |
| Privacidade da tela | Proteção descarta imagens antes de decodificar. O blur da opção Privado e a checagem de proteção têm função de produto; não removidos para baixar GPU/CPU. |
| Conversa longa | Já usa lista lazy, cauda separada, cache limitado, blocos fechados estáveis, âncora de scroll nativa e fallback de 200 ms. A árvore de detalhes de atividades só é criada quando aberta. |
| Tabelas e wizard | Ainda percorrem conteúdo da tabela/cauda para analisar ou medir. Tabelas já evitam muitas medidas e separam linhas em blocos. Cache incremental seria a próxima investigação se um perfil de conteúdo extremo mostrar esse custo; não há evidência aqui para aumentar estado e regras de invalidação. |
| Layout de chips | `WrappingLayout`/`WizardWrap` repetem medidas intrínsecas ao organizar. São layouts pequenos e por evento; cache não introduzido sem evidência de custo relevante, pois precisa invalidar com fonte/conteúdo. |
| Metadados de imagens | `ReplyImageSizes` guarda dimensões por caminho em dicionário sem limite, sem guardar bitmaps. Potencial de crescimento em sessões com muitos caminhos únicos; não foi observado como pressão relevante. Caches de bitmaps do produto já têm limite de bytes. |
| Painéis e gráficos | `ColumnSizing` já evita medidas triplas durante resize. Arquivos usam FSEvents com coalescência; uso/custos agrega fora da main, por evento. |
| Relógios de texto | Contador da tarefa a 1 Hz isolado; próximas rotinas por minuto; datas à meia-noite. Reduzir frequência tiraria informação visível sem evidência de ganho relevante. |
| Permissões e ajustes | Consultas de dois segundos só na aba aberta; permissões precisam acompanhar mudanças em Ajustes do Sistema mesmo quando o Orb perde foco. Não pausadas indiscriminadamente. |
| Capturas e OCR | Gate de captura, timeout e orçamento de Vision já limitam concorrência. Conversões de imagem/alpha/OCR de alta resolução são por solicitação, fora do loop da UI; não se diminuiu qualidade sem medição que justificasse. |
| Blender | Render explícito offline, com Metal quando disponível e fallback CPU. Não executado: comparar as fontes e separar esse custo do produto foi suficiente; os scripts não foram alterados. |
| Snapshots/benchmarks | Temporizadores de alta frequência e decodificação síncrona nesses modos são instrumentação/render único. Não confundidos com comportamento de produção. |

## Validação

- `swift build` de debug concluído.
- `ORB_SKIP_REAL_BROWSER_TESTS=1 swift test --no-parallel --filter 'OrbDriverTests|OrbPerformanceTests|OrbTests|OrbDesignTests|OrbFootprintTests|OrbRhythmTests|OrbPolishTests|OrbReactionTests|TextFadeTests|AttachmentPresentationTests|LiveFeedHubTests|LiveScreenLogicTests|LiveScreenItemTests|LiveScreenFoldingTests|LiveScreenLayerTests|MotionControlsTests|TransitionsTests|SelectableProseTests|ProseWidthTests|MarkdownBlocksTests|TranscriptStreamingTests|ColumnSizingTests|GroupScreensTests|DictationTests|ToolRunFoldingTests|ContextBatchingTests'`: **472 testes em 43 suítes passaram**, em 17,365 s. Log: `render-tests.log`.
- Primeira rodada focada: 78 testes em quatro suítes passaram. O experimento das molas também passou 97 testes antes de ser descartado; o teste específico acrescentado ao experimento foi removido com ele.
- `swift build -c release -Xswiftc -DORB_DEV_TOOLS` concluído para as medições; `swift build -c release --package-path art/orbgen` concluído antes/depois da alteração do gerador.
- Capturas de `transcript-activity-open`, `transcript-browser-live`, `wizard-writing` e `settings-profile`, em 460 e 1100 pt: geradas e inspecionadas. Chat/atividade/tela ao vivo mantêm o layout estreito. Wizard e perfil têm largura mínima própria e ficam recortados pelo host artificial de 460 pt; a mesma limitação foi confirmada executando o binário anterior. Não se declarou esse recorte uma regressão ou uma tela adaptada a 460 pt.
- `git diff --check` sem erros.
- `./scripts/bundle.sh release`: compilação de produção concluída em 214,61 s, versão 1.0.602 (602, `aa20d46-dirty`), assinatura `Orb Local` validada com `codesign --verify --deep --strict`. Processo anterior encerrado normalmente e bundle exato `build/Orb.app` reaberto; a conversa selecionada foi restaurada.
- Rodada complementar de imagens/captura/foto: `ORB_SKIP_REAL_BROWSER_TESTS=1 swift test --no-parallel --filter 'WindowCaptureTests|ScreenshotToolTests|ProfilePhotoTests|ImageProcessingTests|ImageStoreTests'`: **74 testes passaram e dois smokes reais foram ignorados**, em seis suítes. Somando às 43 suítes principais, **546 testes passaram**; os 78 da rodada inicial são repetidos e não entram novamente nessa soma.


Os logs, comandos brutos, saídas e códigos de saída dos benchmarks estão em `build/render-audit/`; os JSONs também registram horário UTC. São artefatos locais ignorados pelo Git. A suíte completa do repositório não foi executada, conforme a regra local de evitar disputa de foco/recursos com o Orb aberto. As suítes afetadas e relacionadas à renderização foram executadas.

O processo final foi confirmado em `/Users/thiagomacbookpro/Orb/build/Orb.app/Contents/MacOS/Orb` (PID 11742), assinatura válida e UUID Mach-O igual ao release compilado. Após estabilizar, cinco amostras finais mostraram 0,0% de CPU e tempo acumulado sem avanço; a janela estava aberta. O cenário inicial estava em segundo plano, portanto não se usa isso como comparação de ganho. Evidência bruta: `final-process.json`.

## Ocorrência no reinício

A interface mostrava todos os Orbs parados e permaneceu sem mudança na última consulta antes de ⌘Q. O encerramento foi normal, sem força. Ao reabrir, o histórico da rotina automática das **21h30** apareceu como “Interrompido: o app foi fechado no meio desta tarefa”. O reinício coincidiu com o disparo agendado. Nenhuma rodada foi repetida durante esta revisão: o histórico precisa ser conferido antes de repetir ações externas. As rotinas existentes foram preservadas.

## Inventário de arquivos

As observações sem alteração indicam o resultado da revisão estática, não uma certificação de custo zero. O manifesto local também registra SHA-256 dos arquivos revisados.

| Arquivo | Categoria | Revisão | Resultado |
| --- | --- | --- | --- |
| `art/orbgen/Package.swift` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `art/orbgen/Sources/orbgen/Body.swift` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `art/orbgen/Sources/orbgen/Decals.swift` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `art/orbgen/Sources/orbgen/Hair.swift` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `art/orbgen/Sources/orbgen/HairRenderer.swift` | Arte offline | detalhada | Base e brilho calculam apenas a própria camada, eliminando ray marching e sombras duplicados. |
| `art/orbgen/Sources/orbgen/Manifest.swift` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `art/orbgen/Sources/orbgen/Math.swift` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `art/orbgen/Sources/orbgen/OrbGen.swift` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `art/orbgen/Sources/orbgen/Palettes.swift` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `art/orbgen/Sources/orbgen/Preview.swift` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `art/orbgen/Sources/orbgen/Raster.swift` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `art/orbgen/Sources/orbgen/SDF.swift` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `art/orbkit/__init__.py` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `art/orbkit/core.py` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `art/orbkit/features.py` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `art/orbs.py` | Arte offline | triagem estática | Geometria, materiais, composição ou manifesto; execução explícita do gerador, sem custo durante uso do Orb. |
| `Sources/Orb/Orbs/OrbActivity.swift` | Avatares | detalhada | Expressões e funções numéricas; pisos de FPS caem após reações transitórias. |
| `Sources/Orb/Orbs/OrbAnimationView.swift` | Avatares | detalhada | Mantém referências às imagens consultadas; falha assíncrona preserva o rosto anterior, sem fallback síncrono. |
| `Sources/Orb/Orbs/OrbDesignSheets.swift` | Avatares | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Orbs/OrbDriver.swift` | Avatares | detalhada | Relógio compartilhado por tela, cache de Orbs ativos, taxas compatíveis, transação única; observador de retorno 2 Hz condicional. |
| `Sources/Orb/Orbs/OrbEditor.swift` | Avatares | detalhada | Miniaturas estáticas até hover; liberação dos caches ao fechar; geometria convertida em booleano antes de observar. |
| `Sources/Orb/Orbs/OrbFootprint.swift` | Avatares | detalhada | Geometria derivada da configuração; não há relógio próprio. |
| `Sources/Orb/Orbs/OrbModel.swift` | Avatares | detalhada | Caches 96/24 MiB, resolução alvo, locks por chave e prewarm de baixa prioridade; catálogo carregado uma vez. |
| `Sources/Orb/Orbs/OrbMotion.swift` | Avatares | detalhada | Integração numérica e distância em pixels revisadas; atalho de repouso ensaiado e descartado sem ganho consistente. |
| `Sources/Orb/Orbs/OrbSpeech.swift` | Avatares | detalhada | Visemas por prazo e gerador numérico, não por token recebido. |
| `Sources/Orb/Orbs/OrbTemperament.swift` | Avatares | detalhada | Traços constantes e agendamento de floreios por prazo, sem tarefa ou alocação de imagem por quadro. |
| `Sources/Orb/Orbs/OrbView.swift` | Avatares | detalhada | Canvas com conjunto completo de bitmaps retido, tarefa por chave e descarte de resultado cancelado. |
| `Sources/Orb/Orbs/SettlingOrb.swift` | Avatares | detalhada | Tarefa por estado; repouso após seis segundos, sem timer permanente. |
| `Sources/Orb/DevRun.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/LiveScreen/LiveScreenSnapshots.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Orbs/OrbBench.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/PanelsBench.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/ScrollBench.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/SwitchBench.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/AttachmentSnapshots.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/CatalogSnapshots.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/ChatsSnapshots.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/ContextSnapshots.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/Groups/GroupSnapshots.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/Multi/CreationSnapshots.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/Multi/DelegationSnapshots.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/Multi/MultiOrbSnapshotsFinal.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/Multi/WizardSnapshots.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/ReadmeSnapshots.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/SidebarCategorySnapshots.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/SystemSnapshots.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/TranscriptSamples.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/UsageSnapshots.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/Views/WelcomeSnapshots.swift` | Cenários e medições | triagem estática | Dados de exemplo/CLI isolados; relógios de benchmark não fazem parte da execução normal. |
| `Sources/Orb/AppIcon.swift` | Estado, imagens e produtores indiretos | detalhada | Renderização de ícone comandada por CLI/bundling, fora do loop normal da interface. |
| `Sources/Orb/AppModel+Attachments.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/AppModel+Steering.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/AppModel.swift` | Estado, imagens e produtores indiretos | detalhada | Atualizações de presença e atribuições condicionais; tarefas periódicas do motor não são render loops. |
| `Sources/Orb/AttachmentInfo.swift` | Estado, imagens e produtores indiretos | detalhada | Metadados lidos fora da main e cache limitado a 500 entradas. |
| `Sources/Orb/AttachmentText.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/BotLive.swift` | Estado, imagens e produtores indiretos | detalhada | Atribuições condicionais; composição/fala usam prazos prorrogáveis, sem publicar cada tecla. |
| `Sources/Orb/BotSession+Conversation.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/BotSession+LiveScreen.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/BotSession+Turn.swift` | Estado, imagens e produtores indiretos | detalhada | Flush de texto em 33 ms; fronteiras de ferramentas fecham o streaming antes de alterar o transcript. |
| `Sources/Orb/BotSession.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/ContextGauge.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/ConversationFind.swift` | Estado, imagens e produtores indiretos | detalhada | Debounce, cancelamento e aplicação de resultados por pedido; apenas linha selecionada recebe destaque. |
| `Sources/Orb/ConversationSearch.swift` | Estado, imagens e produtores indiretos | detalhada | Busca linear em escalares, cache local e cancelamento; sem cópia normalizada da conversa inteira. |
| `Sources/Orb/Dictation/Dictation.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Dictation/SpeechCapture.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/AgentEngine.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/ContextWindow.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/MCPTool.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/ProviderTransport.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/SystemPrompt.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/Tools/AccessibilityContracts.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/Tools/AccessibilityEvents.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/Tools/AccessibilityTools.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/Tools/BackgroundJobs.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/Tools/DocumentReader.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/Tools/FileTools.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/Tools/MacAppTools.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/Tools/ProcessRunner.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/Tools/ScreenTakeover.swift` | Estado, imagens e produtores indiretos | detalhada | Painel nativo de aviso com prazo finito; esperas de transferência do controle não são clocks de animação. |
| `Sources/Orb/Engine/Tools/ScreenshotTool.swift` | Estado, imagens e produtores indiretos | detalhada | OCR e captura sob demanda com limites; thumbnail de 24 px para detectar frame vazio. |
| `Sources/Orb/Engine/Tools/SpawnedProcess.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/Tools/SyntheticInput.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Engine/Tools/TableRecognizer.swift` | Estado, imagens e produtores indiretos | detalhada | Heurística antes de Vision; reconhecimento com orçamento, sem trabalho recorrente na UI. |
| `Sources/Orb/Engine/Tools/UIMarks.swift` | Estado, imagens e produtores indiretos | detalhada | Composição de marcas e codificação somente na captura solicitada. |
| `Sources/Orb/Engine/Tools/WindowCapture.swift` | Estado, imagens e produtores indiretos | detalhada | Gate de duas capturas e cache de enumeração de janelas; ScreenCaptureKit com timeout/fallback. |
| `Sources/Orb/FolderWatcher.swift` | Estado, imagens e produtores indiretos | detalhada | FSEvents com coalescência, newest-only e exclusão de pastas de build; nada de polling de diretório por frame. |
| `Sources/Orb/Groups/GroupSession.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/ImageAttachments.swift` | Estado, imagens e produtores indiretos | detalhada | Downsample para 1568 px, orientação/alpha e codificação em tarefa separada; base64 em cache limitado. |
| `Sources/Orb/LiveText.swift` | Estado, imagens e produtores indiretos | detalhada | Parágrafos fechados estáveis e cauda observada separadamente; agrupamento não é refeito por token. |
| `Sources/Orb/MacPermissions.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/MarkdownBlocks.swift` | Estado, imagens e produtores indiretos | detalhada | Parser puro; sem I/O ao reconhecer blocos ou links de imagens. |
| `Sources/Orb/MemoryRelief.swift` | Estado, imagens e produtores indiretos | detalhada | Limpeza de zonas do alocador em utility após liberar arte, nunca por frame. |
| `Sources/Orb/MenuBarSupport.swift` | Estado, imagens e produtores indiretos | detalhada | Três imagens template em cache; avatar do popover usa o mesmo ciclo de visibilidade. |
| `Sources/Orb/MessageQuote.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Models.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Motion.swift` | Estado, imagens e produtores indiretos | detalhada | Curvas/tempos constantes e transições finitas; sem loop SwiftUI repeatForever. |
| `Sources/Orb/MotionControls.swift` | Estado, imagens e produtores indiretos | detalhada | Spinner atrasado e transições locais; tarefa cancelada pela identidade da view. |
| `Sources/Orb/MultiOrb/TranscriptFolding.swift` | Estado, imagens e produtores indiretos | detalhada | Agrupamento no estado do transcript; fronteiras de pedido e itens originais preservados. |
| `Sources/Orb/OrbApp.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/SidebarCategories.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/SnapshotComposerScenes.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Theme.swift` | Estado, imagens e produtores indiretos | detalhada | Shimmer e pulsação em Core Animation, já limitados por visibilidade/app e 24–30 FPS. |
| `Sources/Orb/ToolIntent.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/ToolTally.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Wizard/WizardRunner.swift` | Estado, imagens e produtores indiretos | detalhada | Texto agrupado a cada 33 ms; limites de turnos/mensagens; parser da cauda permanece candidato para textos extremos. |
| `Sources/Orb/WorkLine.swift` | Estado, imagens e produtores indiretos | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `scripts/bundle.sh` | Ferramentas de build/captura | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `scripts/readme-frame.swift` | Ferramentas de build/captura | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `scripts/readme-shots.sh` | Ferramentas de build/captura | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/Views/ApprovalKeyboard.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/AttachmentViews.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/BotInspector.swift` | Interface | detalhada | Observação de arquivos somente na aba aberta; relógios de rotinas a cada minuto. |
| `Sources/Orb/Views/BrowserPickers.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/BrowserSettings.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/CatalogParts.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/ChatView.swift` | Interface | detalhada | LazyVStack, âncora de scroll do sistema e fallback limitado; contador isolado a 1 Hz, datas à meia-noite. |
| `Sources/Orb/Views/ClaudeCodeSettings.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Clipboard.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/ColumnSizing.swift` | Interface | detalhada | Hosting views das colunas deixam de medir mínimo/ideal/máximo durante cada frame de resize. |
| `Sources/Orb/Views/CommandPalette.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/ComposerChips.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/ComposerSupport.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/ComposerView.swift` | Interface | detalhada | Superfície com sombra isolada do campo; medidor em subview; caret por evento de seleção. |
| `Sources/Orb/Views/ConnectorGalleryView.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/ConnectorsView.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/ContextMeterViews.swift` | Interface | detalhada | Debounce de 150 ms e cálculo destacável com cancelamento encaminhado. |
| `Sources/Orb/Views/ContextSettings.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/CustomProviderFields.swift` | Interface | detalhada | WrappingLayout mede filhos ao organizar; candidato a cache se catálogo amplo aparecer em perfil de layout. |
| `Sources/Orb/Views/DeleteOrbDialog.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/DictationButton.swift` | Interface | detalhada | Símbolo respeita atividade/Reduce Motion; halo parado não observa níveis do microfone. |
| `Sources/Orb/Views/EmptyChatContent.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/EntranceMotion.swift` | Interface | detalhada | Entrada finita com ledger de IDs; pulsos limitados, sem replay de transcript histórico. |
| `Sources/Orb/Views/FindViews.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/FirstRunCard.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Groups/GroupBoardView.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Groups/GroupChatView.swift` | Interface | detalhada | Revisões por mensagens concluídas; varredura linear de falantes não roda por token. |
| `Sources/Orb/Views/Groups/GroupComposer.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Groups/GroupDeleteDialog.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Groups/GroupHeader.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Groups/GroupMessageBubble.swift` | Interface | detalhada | Avatares estáticos e comparação de mensagem; tinta acessível calculada sem relógio. |
| `Sources/Orb/Views/Groups/GroupPanel.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Groups/GroupPauseCard.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Groups/GroupPresenceStrip.swift` | Interface | detalhada | Efeito repetitivo do símbolo pausa com a janela inativa. |
| `Sources/Orb/Views/Groups/MentionPicker.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Groups/NewGroupSheet.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Groups/SidebarGroupRow.swift` | Interface | detalhada | BreathingDot em Core Animation, com pausa por app, oclusão, ocultação e scroll. |
| `Sources/Orb/Views/Groups/StackedAvatars.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/ImageThumbnails.swift` | Interface | detalhada | Pedidos simultâneos compartilham tarefa; limite de duas decodificações; ImageIO decodifica antes de apresentar. |
| `Sources/Orb/Views/ImportPanel.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/InspectorFold.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/InspectorSupport.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/LiveBotAvatar.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/LocalConnectorSheet.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/MacPermissionsView.swift` | Interface | detalhada | Consulta de dois segundos só enquanto a aba está montada; necessária para acompanhar Ajustes do Sistema. |
| `Sources/Orb/Views/MarkdownBlockViews.swift` | Interface | detalhada | Código em blocos de 40 linhas, tabelas em blocos de 20; medidas de coluna com atalhos; metadados de imagem fora da main. |
| `Sources/Orb/Views/MarketplaceGallery.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/MemoryViews.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/ModelPicker.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/ModelPopover.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Multi/CreatedByLine.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Multi/EventLineView.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Multi/ExchangeParts.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Multi/ExchangeSheet.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Multi/OpenTalksSection.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Multi/OrbMessageRow.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Multi/OrbProposalCard.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Multi/WizardChatView.swift` | Interface | detalhada | Pontos pausam por viewport, atividade do app e desmontagem; posição não gera animação implícita. |
| `Sources/Orb/Views/Multi/WizardFooter.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/Multi/WizardPreviewPane.swift` | Interface | detalhada | Reações finitas e tarefas canceladas ao sair; layout dos chips por alteração de dados. |
| `Sources/Orb/Views/PermissionConfirmation.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/ProfileSettings.swift` | Interface | detalhada | Resultado de miniatura cancelada não substitui a foto atual. |
| `Sources/Orb/Views/ProviderPresentation.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/ProviderSettings.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/QuestionCard.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/QueuedMessages.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/QuickAskView.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/QuickLookPreview.swift` | Interface | detalhada | Prévia do sistema sob demanda; sem renderização própria contínua. |
| `Sources/Orb/Views/ResetOrbSheet.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/RootView.swift` | Interface | detalhada | Identidade de detalhe estável por Orb; largura observada por evento, sem valor de pixel no estado a cada frame. |
| `Sources/Orb/Views/RoutinesView.swift` | Interface | detalhada | Cards em grade lazy; próxima execução atualizada por minuto; validação de cron fora do body. |
| `Sources/Orb/Views/SavedKeyField.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/SelectableProse.swift` | Interface | detalhada | TextKit reaproveitado, conversão por assinatura e cache de larguras; fade não relê layout a cada quadro. |
| `Sources/Orb/Views/SettingsView.swift` | Interface | detalhada | Solicitações abertas consultadas a cada dois segundos apenas no painel pertinente; mudanças de dados condicionais. |
| `Sources/Orb/Views/SharedControls.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/SheetKit.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/SheetsAndSettings.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/SidebarCategoryViews.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/SidebarChatList.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/SidebarView.swift` | Interface | detalhada | Observação por Orb, apenas selecionado/ocupados mantêm atividade; animação de seleção depende de IDs. |
| `Sources/Orb/Views/SkillsView.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/TaskPlanRing.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/TextFade.swift` | Interface | detalhada | Texto oculto, fora do viewport, janela coberta ou app inativo termina o fade e libera o display link. |
| `Sources/Orb/Views/TranscriptViews.swift` | Interface | detalhada | Cache Markdown limitado, linhas Equatable e detalhes sob demanda; arquivos de saída dependem de ações, não dos tokens. |
| `Sources/Orb/Views/UsageSettings.swift` | Interface | detalhada | Agregação fora da main e recarga por evento; gráficos não têm timer. |
| `Sources/Orb/Views/WelcomeOffer.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/Views/WelcomeView.swift` | Interface | triagem estática | Entradas visuais, coleções, observação e tarefas triadas; sem novo desperdício confirmado nesta revisão. |
| `Sources/Orb/LiveScreen/LiveBrowserSource.swift` | Tela ao vivo | detalhada | Leitura de socket em tarefa separada, cancelada no encerramento. |
| `Sources/Orb/LiveScreen/LiveFeedHub.swift` | Tela ao vivo | detalhada | Uma conexão, referências de espectadores e grace de três segundos; último JPEG limitado a dez usos. |
| `Sources/Orb/LiveScreen/LiveFrameStore.swift` | Tela ao vivo | detalhada | Entrega direta a observadores locais, sem publicar bitmap no estado geral do app. |
| `Sources/Orb/LiveScreen/LiveScreenLayerView.swift` | Tela ao vivo | detalhada | CALayer recebe frames sem body SwiftUI por frame; aquisição por visibilidade; filtros só mudam com privacidade. |
| `Sources/Orb/LiveScreen/LiveScreenLogic.swift` | Tela ao vivo | triagem estática | Caminho indireto triado quanto a I/O, coleções e frequência de publicação; sem alteração necessária nesta revisão. |
| `Sources/Orb/LiveScreen/LiveScreenViews.swift` | Tela ao vivo | detalhada | Última tela decodifica em tarefa separada; tarefa cancelada não apresenta resultado antigo. |
| `Sources/Orb/LiveScreen/LiveStream.swift` | Tela ao vivo | detalhada | Decodificação imediata de JPEG reutilizável pela prévia estática. |
