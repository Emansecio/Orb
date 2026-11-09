# Instruções do projeto

## Contexto e ponto de entrada

Orb é um app nativo de macOS em SwiftUI e Swift 6, organizado como pacote SwiftPM, sem dependências externas. Antes de alterar uma área, consulte a categoria abaixo e leia apenas os arquivos e testes relacionados. O mapa detalhado e as receitas para estender o projeto estão em `docs/ARQUITETURA.md`; convenções adicionais estão em `CLAUDE.md`.

## Mapa por responsabilidade

Os caminhos de código abreviados são relativos a `Sources/Orb/`. Caminhos iniciados por `Sources/`, `Tests/`, `docs/`, `scripts/`, `art/` ou `.github/` partem da raiz do repositório; `Package.swift`, `README.md` e `CLAUDE.md` também ficam na raiz.

| Categoria | Onde procurar | Responsabilidade |
| --- | --- | --- |
| Inicialização e configuração do pacote | `Package.swift`, `Sources/OrbMain/main.swift`, `Sources/Orb/OrbApp.swift`, `DevRun.swift` | Alvos, janela, menus, entrada do app e modos de desenvolvimento. O app é a biblioteca `Orb`; o executável `OrbMain` só chama `Launcher.main()`. |
| Estado e execução de cada Orb | `AppModel.swift`, `AppModel+*.swift`, `BotSession.swift`, `BotSession+*.swift`, `BotLive.swift` | Orquestração, eventos de turno, estado observado pelas telas e operações por tema. Prefira a extensão da área afetada. |
| Conversa e apresentação de atividades | `LiveText.swift`, `ToolTally.swift`, `ToolIntent.swift`, `WorkLine.swift`, `MultiOrb/TranscriptFolding.swift`, `Views/ChatView.swift`, `Views/TranscriptViews.swift` | Streaming, agrupamento por pedido e etapa, resumos de ações, status e expansão. `TranscriptFolding` decide os grupos; as views os apresentam. |
| Interface e identidade visual | `Views/`, `Theme.swift`, `Motion.swift`, `Shortcuts.swift` | Chat, compositor, painel, ajustes, estilos, movimento e atalhos. `Views/Multi/` contém colaboração; `Views/Groups/`, conversas em grupo. |
| Catálogos e buscas na interface | `Views/CatalogParts.swift`, `Views/ConnectorGalleryView.swift`, `Views/ConnectorsView.swift`, `Views/SkillsView.swift`, `Views/MarketplaceGallery.swift`, `Catalog/BrandGlyph.swift` | Busca compartilhada, estados de carga, cards, ferramentas e marcas. O catálogo de dados fica em `Catalog/`; filtros e layout pertencem às views. |
| Folhas, campos e seleção de modelos | `Views/SheetKit.swift`, `Views/SharedControls.swift`, `Views/ModelPicker.swift`, `Views/ModelPopover.swift`, `Views/ProviderSettings.swift` | Molduras e rodapés, edição de nomes, foco, listas de modelos e configuração dos provedores. Reuse os controles existentes. |
| Motor e provedores | `Engine/` | Loop do agente, clientes de modelos, eventos, plano, prompt, contexto, compactação e política de permissões. `Engine/ClaudePipe/` integra o CLI Claude Code. |
| Ferramentas e controle do computador | `Engine/Tools/`, `MacPermissions.swift` | Terminal, arquivos, web, Acessibilidade, automação de apps, captura e passagem do controle. |
| Navegador e conectores | `Engine/Browser/`, `Engine/MCP*.swift`, `Engine/ConnectorGateway.swift`, `AppModel+Browser.swift`, `AppModel+*Connector*.swift` | Sessões e abas, instalação do navegador, ferramentas MCP, autenticação e conectores locais. |
| Tela ao vivo | `LiveScreen/`, `BotSession+LiveScreen.swift` | Frames, fonte do navegador, transmissão, prévia, histórico visual e intervenção da pessoa. Não confundir a apresentação da tela com a execução das ferramentas em `Engine/`. |
| Persistência e segredos | `Models.swift`, `Store.swift`, `StoreCoordination.swift`, `ConversationCoding.swift`, `ConversationHistory.swift`, `InicioHistory.swift`, `LegacyMigration.swift`, `Sources/OrbKeychainHelper/` | Tipos persistidos, JSON, histórico, migrações e acesso estável ao Keychain. Campos novos precisam de defaults e decodificação tolerante. |
| Memória | `Memory/`, `AppModel+Memory*.swift`, `AppModel+SessionNotes.swift`, `AppModel+ChunkSummaries.swift`, `Views/MemoryViews.swift`, `Views/InspectorSupport.swift`, `Views/Groups/GroupBoardView.swift` | Recuperação e consolidação no modelo; agrupamento, filtros e cache de busca em `MemoryGroups`/`FoldedTextCache`; apresentação nas views de memória e quadro do grupo. |
| Colaboração | `MultiOrb/`, `Groups/`, `MultiOrb/AppModel+Delegation.swift` | Mensagens e delegação entre Orbs, pedidos paralelos, grupos e seus estados. O agrupamento visual do transcript também fica em `MultiOrb/TranscriptFolding.swift`. |
| Rotinas e agendamento | `AppModel+Schedule.swift`, `AppModel+RoutinesUI.swift`, `RoutineGoal.swift`, `CronExpression.swift`, `RoutinePrecheck.swift`, `RoutineFollowUps.swift`, `RoutineWake.swift`, `Engine/Tools/ScheduleTool.swift`, `Views/RoutinesView.swift` | Criação, execução, repetição, pré-checagem, acompanhamentos, despertar por sinal externo, relatórios e apresentação das rotinas. Confira os nomes existentes com `rg` antes de criar arquivos. |
| Catálogos, importação e criação | `Catalog/`, `Import/`, `Wizard/` | Skills e conectores disponíveis, importação de outros assistentes e assistente de criação de Orb. |
| Avatares e arte | `Orbs/`, `Resources/Orbs/`, `AppIcon.swift`, `art/` | Modelos, animação, renderização dos avatares e ícone. `art/orbgen/` e `art/orbkit/` são ferramentas de geração; veja `art/README.md` antes de regenerar recursos. |
| Uso e custos | `Usage/` | Registros, preços de modelos, agregação e relatórios de consumo. |
| Ditado e anexos | `Dictation/`, `AppModel+Dictation.swift`, `ImageAttachments.swift`, `AttachmentInfo.swift`, `Views/Attachment*.swift` | Microfone, transcrição, imagens, arquivos anexados e arquivos produzidos. |
| Redefinição de dados | `Reset/`, `AppModel+Reset.swift` | Plano de redefinição, execução e relançamento. |
| Testes | `Tests/OrbAppTests/`, `Tests/OrbAppTests/TestSupport/`, `Tests/OrbAXFixture/` | Suítes por tema, fakes e sincronização compartilhados; app separado para smoke de Acessibilidade. |
| Scripts e CI | `scripts/`, `.github/workflows/` | Bundle e assinatura, modelo falso, capturas do README e verificações de CI. |
| Documentação e referências | `docs/`, `README.md`, `CLAUDE.md` | Arquitetura e manual; `docs/CONTEXTO.md`, `docs/PERMISSOES.md`, `docs/MEMORIA.md`, `docs/ORBS.md`, `docs/MOVIMENTO.md`, `docs/FERRAMENTAS.md`, `docs/COLABORACAO.md`, `docs/PERSISTENCIA.md`, `docs/TESTES.md`, `docs/DESENVOLVIMENTO.md`, `docs/TELA-AO-VIVO.md` e `docs/USO-DO-COMPUTADOR.md` detalham cada área. Relatórios `docs/REVISAO-*`, `docs/AUTONOMIA-*` e `docs/historico/` são históricos: valide no código. `docs/mocks/` e `docs/readme/` contêm referências visuais. |

`build/` e `.build/` são saídas de compilação. As pastas `~/` e `.slim/` na raiz são resíduos de ferramenta; não são código do produto.

## Como trabalhar em cada área

- Preserve alterações locais existentes. Mantenha a mudança na categoria responsável, sem reorganizar arquivos ou criar abstrações sem necessidade.
- Fluxo principal: `Views` → `AppModel`/`BotSession` → `Engine`; eventos retornam para `BotLive`/`OrbTranscript` e atualizam as telas. Não mova execução ou persistência para o `body` de uma view.
- Agrupamento do chat: preserve os itens originais e seus IDs, a busca, os limites de pedidos e de compactação. Perguntas, aprovações pendentes, avisos e navegador ao vivo precisam continuar acessíveis. Não feche detalhes abertos ao chegar uma nova ação.
- Valide com as suítes afetadas: `scripts/test.sh --filter 'SuiteA|SuiteB'` (roda com metade dos núcleos; `swift test` sem limite derruba testes de tempo). A suíte completa leva cerca de 1 min com o script e não traz janelas para a frente, mas ocupa metade dos núcleos: informe quando ela não rodou. Testes reais (navegador, Acessibilidade, internet) exigem suas flags próprias, descritas em `CLAUDE.md`.
- Para alterações visuais nativas, use os modos `--snapshot` existentes em debug, com dados isolados, e confira as imagens em 460 e 1100 pt. Cenários do chat ficam em `Views/TranscriptSamples.swift`; o dispatcher fica em `OrbApp.swift`. Confira também o release: código necessário em produção não pode ficar preso a `#if DEBUG || ORB_DEV_TOOLS`.
- Desempenho visual: comece em `Orbs/OrbDriver.swift` e `OrbAnimationView.swift` (relógios/camadas), `Views/TextFade.swift` e `SelectableProse.swift` (texto), `Views/ImageThumbnails.swift` (imagens) ou `LiveScreen/` (frames). Preserve a pausa por visibilidade, os limites de cache/concorrência e a decodificação fora da thread principal. O inventário e as medições desta revisão estão em `docs/REVISAO-RENDERIZACAO-2026-10-26.md`; valide conclusões históricas no código atual.
- Nas demais telas visuais, consulte `docs/REVISAO-VISUAL-COMPLEMENTAR-2026-10-26.md` para o inventário por arquivo. Buscas canceladas não podem encerrar o loading da consulta seguinte; leituras assíncronas devem conferir cancelamento antes de publicar estado. Avatares decorativos ociosos podem reutilizar `SettlingOrb`; mudanças de layout por largura devem observar limites, sem guardar cada pixel em `@State`.

## Build e Dock

- Sempre que executar um build para o usuário, conclua gerando a versão release com `./scripts/bundle.sh release` e abrindo `build/Orb.app`, que é o aplicativo fixado no Dock neste Mac. Uma compilação `swift build` sozinha não atualiza o app do Dock.
- Se o Orb estiver aberto, encerre-o normalmente e reabra o bundle atualizado para que o processo em execução corresponda à assinatura e continue acessando o Keychain. Respeite eventuais diálogos ou trabalho em andamento; não force o encerramento.
- Confirme que o bundle foi gerado e que o processo aberto corresponde a `build/Orb.app`. Não execute o bundling ao fim de cada compilação intermediária do mesmo trabalho: atualize o Dock ao final do build solicitado.

## Regras fixas

Correções que o usuário já fez mais de uma vez e decisões dele que já estão fechadas. Valem em toda tarefa, inclusive para subagentes.

### Interface

1. Controle novo copia o estilo das linhas vizinhas da mesma seção (tipo de linha, `Picker`/`Toggle` nativo, tamanho, alinhamento). Não invente um estilo próprio para um controle só.
2. Todo cartão usa `.card()`/`CardSurface` (no painel, `PanelSection`); nunca um fundo chapado com fio. Link em texto usa `LinkTextStyle`.
3. Cor tem função: laranja só para aviso ou risco; vermelho só na confirmação de uma ação destrutiva, que fica no menu `⋯`, não exposta na linha.
4. Mudança visual só está pronta depois de conferida por `--snapshot` em 460 e 1100 pt (com `ORB_DATA_DIR` temporário). O `--snapshot` não tira o foco; rode um por vez, não em lote longo.

### Textos da interface

5. pt-BR com acentuação correta e caixa de sentença; nada de Title Case em rótulos, títulos ou botões.
6. Sem jargão na tela: nenhum slug, id ou nome técnico (ex.: "agent-browser"); use o nome falado ("o controle do navegador").
7. Pasta, grupo, espaço e categoria já têm significado na lateral; não reutilize essas palavras para outra coisa.
8. Não corte a parte útil: caminho trunca no meio (`.truncationMode(.middle)`); texto que pode ser cortado ganha `.help` com o texto inteiro.

### Foco e máquina

9. Não roube o foco do usuário: nada de trazer apps para a frente, abrir abas do Chrome por AppleScript/`open` ou ativar janelas enquanto ele trabalha. Para links, entregue um arquivo ou a lista clicável.
10. A suíte padrão pode rodar com o Orb aberto; só os testes ligados por `ORB_REAL_BROWSER_TESTS=1` exigem o Orb fechado (ele limpa os navegadores ao sair). No dia a dia, rode apenas as suítes filtradas da área.
11. Nada pago: nenhuma API ou serviço cobrado sem pedido explícito. Erro 429 significa esperar, não trocar para uma API paga.
12. Espere com `waitUntil`, `TestGate`, `Monitor` ou um processo em segundo plano; nunca com `sleep N` (nem em subagentes, que deixam `sleep` órfãos).
13. Antes de algo que ocupe a máquina por minutos (render, benchmark, lote longo), diga o que muda e quanto leva, e espere o ok. Itere com testes curtos e encerre no fim todo loop de CPU que um benchmark abriu.
14. Suíte que passa de ~2 min está presa: rode `sample` no `swiftpm-testing-helper` para achar o teste, encerre, rode de novo com `--skip` nele, rode-o sozinho e diga no relatório que foi pulado. Rode a suíte com `caffeinate -i`.
15. Imagem para o usuário vai por link ou anexo (`SendUserFile` com `display: "attach"`), nunca por algo que abra janela ou painel sozinho.

### Agentes e forma de trabalho

16. Subagentes que escrevem código são Sonnet, cada um em sua worktree, no máximo 3 compilando ao mesmo tempo (com `nice -n 15`). A worktree nasce de `origin/main`: o agente roda `git merge --ff-only main` antes de começar. A revisão final dos diffs é da sessão principal.
17. Depois de levar o commit do agente para a `main`, remova a worktree e o branch dele.
18. Não repita o que o usuário já recusou ou desfez (ex.: a janela de Ajustes mudando de altura entre abas). Antes de corrigir, confirme a causa no código e nas capturas, não na suposição.
19. Nenhum subagente Opus, a menos que o usuário peça o modelo pelo nome. Agentes só de leitura podem ir em maior número; o teto de 3 vale para quem compila, mesmo quando o pedido é "paralelize o quanto puder".
20. Opção técnica com recomendação clara: escolha, registre a decisão e siga. Pergunte ao usuário só o que é gosto dele ou exige ação dele (login, instalação, pagamento).

### Git e CI

21. Trabalho direto na `main`, com push liberado. Use worktree quando outra sessão estiver mexendo na `main`.
22. Push só depois da suíte completa e do bundle passarem; nunca encadeie o push aos testes com `&&` frouxo (já subiu push com teste falhando).
23. O CI usa Swift 6.3.3, mais estrito que o Swift local: erros que passam aqui quebram lá. Depois do push, confira com `gh run list --branch main`.

### Decisões de produto

24. Recurso que mexe em janela, app ou navegador trabalha em segundo plano por padrão; vai para a frente só com pedido explícito ou quando a tarefa não anda de outro jeito.
25. Entregas arredondadas: cada etapa é usável sozinha, com padrão seguro (sem a pré-condição, o comportamento é o de hoje), avisos, travas e um toggle em Ajustes quando houver custo ou risco. Nunca obrigue a etapa seguinte.
26. O Claude Code é só o cano até o modelo (`Engine/ClaudePipe/`), com o motor do Orb no comando: nunca reintroduza o harness dele (prompt, ferramentas, sessões, compactação) nem OAuth direto.
27. Não mude como a memória trata páginas escritas fora do padrão sem pedido: Orbs antigos do usuário dependem disso.
28. Nunca remova um recurso existente sem pedido explícito (as várias conversas por Orb saíram em `e3f90ba` sem aval e tiveram de voltar).

### Qualidade de código

29. Escreva o mínimo de código que resolve, e de forma eficiente. Antes de criar algo, procure o que já existe no projeto, na biblioteca padrão ou na plataforma. Sem overcoding: nenhuma abstração, camada, opção ou caso hipotético que a tarefa não pede. Ser enxuto não justifica cortar validação, tratamento de erro, proteção de dados ou acessibilidade.
30. Depois de cada feature implementada ou alterada, rode as suítes afetadas (`scripts/test.sh --filter`) antes de passar à próxima.
31. Toda correção de bug ganha um teste de regressão, e você confere que ele falha sem a correção (dois testes já passavam mesmo sem ela). Lógica nova com ramificação, laço ou parsing ganha testes do caminho principal e dos casos de borda.
32. Antes de dar por pronto, revise o diff inteiro procurando bug, caso de borda, código morto ou duplicado e gargalo (trabalho no `body`, loop ou leitura repetida, I/O na thread principal). Corrija o que achar e diga no relatório o que a revisão encontrou.
