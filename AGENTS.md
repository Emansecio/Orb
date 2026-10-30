# Instruções do projeto

## Contexto e ponto de entrada

Orb é um app nativo de macOS em SwiftUI e Swift 6, organizado como pacote SwiftPM, sem dependências externas. Antes de alterar uma área, consulte a categoria abaixo e leia apenas os arquivos e testes relacionados. O mapa detalhado e as receitas para estender o projeto estão em `docs/ARQUITETURA.md`; convenções adicionais estão em `CLAUDE.md`.

## Mapa por responsabilidade

Os caminhos de código abreviados são relativos a `Sources/Orb/`. Caminhos iniciados por `Sources/`, `Tests/`, `docs/`, `scripts/`, `art/` ou `.github/` partem da raiz do repositório; `Package.swift`, `README.md` e `CLAUDE.md` também ficam na raiz.

| Categoria | Onde procurar | Responsabilidade |
| --- | --- | --- |
| Inicialização e configuração do pacote | `Package.swift`, `Sources/Orb/OrbApp.swift`, `DevRun.swift` | Alvos, janela, menus, entrada do app e modos de desenvolvimento. |
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
| Documentação e referências | `docs/`, `README.md`, `CLAUDE.md` | Arquitetura e manual; `docs/CONTEXTO.md`, `docs/PERMISSOES.md`, `docs/MEMORIA.md`, `docs/ORBS.md`, `docs/MOVIMENTO.md`, `docs/TELA-AO-VIVO.md` e `docs/USO-DO-COMPUTADOR.md` detalham cada área. Relatórios `docs/REVISAO-*`, `docs/AUTONOMIA-*` e `docs/historico/` são históricos: valide no código. `docs/mocks/` e `docs/readme/` contêm referências visuais. |

`build/` e `.build/` são saídas de compilação. As pastas `~/` e `.slim/` na raiz são resíduos de ferramenta; não são código do produto.

## Como trabalhar em cada área

- Preserve alterações locais existentes. Mantenha a mudança na categoria responsável, sem reorganizar arquivos ou criar abstrações sem necessidade.
- Fluxo principal: `Views` → `AppModel`/`BotSession` → `Engine`; eventos retornam para `BotLive`/`OrbTranscript` e atualizam as telas. Não mova execução ou persistência para o `body` de uma view.
- Agrupamento do chat: preserve os itens originais e seus IDs, a busca, os limites de pedidos e de compactação. Perguntas, aprovações pendentes, avisos e navegador ao vivo precisam continuar acessíveis. Não feche detalhes abertos ao chegar uma nova ação.
- Valide com as suítes afetadas: `ORB_SKIP_REAL_BROWSER_TESTS=1 swift test --no-parallel --filter 'SuiteA|SuiteB'`. A suíte completa disputa foco e recursos com o app aberto; informe quando ela não rodou. Testes reais exigem suas flags próprias, descritas em `CLAUDE.md`.
- Para alterações visuais nativas, use os modos `--snapshot` existentes em debug, com dados isolados, e confira as imagens em 460 e 1100 pt. Cenários do chat ficam em `Views/TranscriptSamples.swift`; o dispatcher fica em `OrbApp.swift`. Confira também o release: código necessário em produção não pode ficar preso a `#if DEBUG || ORB_DEV_TOOLS`.
- Desempenho visual: comece em `Orbs/OrbDriver.swift` e `OrbAnimationView.swift` (relógios/camadas), `Views/TextFade.swift` e `SelectableProse.swift` (texto), `Views/ImageThumbnails.swift` (imagens) ou `LiveScreen/` (frames). Preserve a pausa por visibilidade, os limites de cache/concorrência e a decodificação fora da thread principal. O inventário e as medições desta revisão estão em `docs/REVISAO-RENDERIZACAO-2026-10-26.md`; valide conclusões históricas no código atual.
- Nas demais telas visuais, consulte `docs/REVISAO-VISUAL-COMPLEMENTAR-2026-10-26.md` para o inventário por arquivo. Buscas canceladas não podem encerrar o loading da consulta seguinte; leituras assíncronas devem conferir cancelamento antes de publicar estado. Avatares decorativos ociosos podem reutilizar `SettlingOrb`; mudanças de layout por largura devem observar limites, sem guardar cada pixel em `@State`.

## Build e Dock

- Sempre que executar um build para o usuário, conclua gerando a versão release com `./scripts/bundle.sh release` e abrindo `build/Orb.app`, que é o aplicativo fixado no Dock neste Mac. Uma compilação `swift build` sozinha não atualiza o app do Dock.
- Se o Orb estiver aberto, encerre-o normalmente e reabra o bundle atualizado para que o processo em execução corresponda à assinatura e continue acessando o Keychain. Respeite eventuais diálogos ou trabalho em andamento; não force o encerramento.
- Confirme que o bundle foi gerado e que o processo aberto corresponde a `build/Orb.app`. Não execute o bundling ao fim de cada compilação intermediária do mesmo trabalho: atualize o Dock ao final do build solicitado.
