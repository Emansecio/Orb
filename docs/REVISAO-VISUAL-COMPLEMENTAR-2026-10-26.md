# Revisão complementar das telas e controles visuais

Revisão de 26/10/2026, posterior a `REVISAO-RENDERIZACAO-2026-10-26.md`. Escopo: os 60 arquivos de produção de `Views/` classificados como componentes estáticos na primeira passagem, mais os auxiliares de marcas em `Catalog/`. O inventário por arquivo está abaixo. Esta passagem aprofunda layout, foco, estados assíncronos, listas, leitura de arquivos e vida das animações; não repete os benchmarks do renderizador de cabelos ou a auditoria do motor.

## Mudanças aplicadas

| Área | Problema observado | Resultado |
| --- | --- | --- |
| Criação de grupos | Cada opção mantinha um avatar ocioso animado durante toda a permanência da folha. | `SettlingOrb` reutilizado para repousar os avatares após seis segundos e reagir à interação/seleção. Teste com janela nativa confirma o relógio parado. |
| Busca em memória | Selecionar uma categoria ainda normalizava e armazenava o texto das outras categorias antes de descartá-las. | Tipo filtrado antes do Unicode folding. Na fixture com três páginas e uma preferência, o cache recebe uma entrada, preservando os mesmos resultados e ordenação. |
| Skills e conectores | O `defer` de uma busca cancelada podia desligar o indicador de uma busca iniciada depois dela. | O encerramento de loading exige termo atual e tarefa não cancelada. Regressão cobre os dois critérios. |
| Anexos | Uma leitura cancelada de metadados ainda podia publicar nome/ícone do caminho anterior em uma view reutilizada. | Os três consumidores conferem cancelamento depois do `await` e antes de alterar estado. |
| Boas-vindas e trabalho delegado | Leituras anteriores podiam publicar estado após o cancelamento da tarefa da view. | Publicação protegida em `loadKept` e `SideWorkSheet`, preservando a leitura fora da thread principal. |
| Galeria de conectores | Um serviço com aviso obrigava todos os cards a reservar espaço para aviso, inclusive em coluna única. | Reserva uniforme mantida apenas quando há várias colunas; coluna única fica mais compacta. Observação de geometria produz só um booleano ao cruzar o limite. |
| Skills instaladas | A captura de 460 pt mostrou nomes e comandos espremidos pelos controles laterais. | Ações passam para uma linha própria nos cards estreitos, usando `AnyLayout` para preservar identidade dos controles. Layout horizontal mantido nos cards largos. |
| Campos de busca | Limpar podia tirar o foco da digitação; busca de modelos não tinha botão de limpeza. | Foco devolvido ao campo ao limpar; botão com rótulo acessível. Lupa decorativa removida da árvore de acessibilidade. |
| Seleção de modelo | Espaços no campo escondiam “Padrão”, embora Return ainda o escolhesse. | Visibilidade usa as mesmas palavras da filtragem, incluindo consulta composta só de espaços. |
| Ferramentas de conectores | Indicadores curtos competiam por largura com identificadores longos; descrição estava truncada. | Badges mantêm tamanho legível; tooltip disponibiliza identificador e descrição completa. |

## Critérios preservados

Mantidos os estilos e tokens nativos do Orb: tipografia, contraste, formas, densidade e comportamento do chat. A skill `design-taste-frontend` orientou a crítica de hierarquia, legibilidade, feedback e espaço útil. O inspetor CSS dessa skill não se aplica à interface SwiftUI; a verificação foi feita nas capturas nativas, sem atribuir notas fictícias de navegador.

Foram inspecionados os pontos de atualização e renderização dos 60 arquivos, com leitura aprofundada dos caminhos assíncronos e componentes afetados. Componentes estáticos não ganharam caches ou timers novos. As marcas SVG já são analisadas uma vez, seus limites são reutilizados e os ícones pequenos de colaboração já usam avatares estáticos. A busca de marketplace já prepara índice fora da thread principal; os seletores de modelos já usam listas preguiçosas para catálogos grandes. Esses caminhos foram preservados.

As mudanças de largura observam limites, sem gravar cada pixel em estado. A consulta mantém seu debounce. Não há nova camada genérica de estado, biblioteca ou dependência. O teste de repouso usa a view real e os relógios de `OrbAnimationView`, em vez de apenas repetir a condição da implementação.

## Validação e evidências

- `build/visual-polish/baseline.patch`: estado das alterações locais ao iniciar esta passagem, preservado.
- `build/visual-polish/files.json`: lista dos 60 arquivos complementares.
- `build/visual-polish/coverage.json`: inventário com tamanho, hash e conclusão por arquivo.
- `build/visual-polish/Orb-before`: binário debug anterior aos polimentos desta passagem.
- `build/visual-polish/before-snapshots.json` e `after-snapshots.json`: comandos, larguras, timestamp, exit code e stderr das capturas.
- `build/visual-polish/focused-tests.log`: primeira validação, 143 testes aprovados.
- `build/visual-polish/final-verification.log`: validação final dos componentes alterados, 291 testes em 32 suítes aprovados.
- `build/visual-polish/final-debug-build.log`: build debug concluído.
- `build/visual-polish/release-build.log`: bundling release e assinatura.
- `build/visual-polish/validation.json`: comando de testes, resultados, verificação da assinatura/UUID e processo reaberto.

Os artefatos em `build/` são locais e ignorados pelo Git. Para reproduzir uma captura:

```sh
ORB_SNAPSHOT_WIDTH=460 ORB_SNAPSHOT_WAIT=1.5 .build/debug/Orb --snapshot skills /tmp/orb-skills.png
ORB_SNAPSHOT_WIDTH=1100 ORB_SNAPSHOT_WAIT=1.5 .build/debug/Orb --snapshot connectors-gallery /tmp/orb-gallery.png
```

As capturas anteriores e finais cobrem galeria de conectores, conectores instalados, ferramentas, skills, memória vazia, novo grupo, prévia de importação e paleta, em 460 e 1100 pt. O modo novo `model-search` permite conferir o campo preenchido sem autenticação nem catálogo remoto. Todos usam dados isolados. As 18 capturas finais foram inspecionadas: nomes e comandos das skills legíveis em 460 pt, controles horizontais preservados em 1100 pt, cards alinhados em múltiplas colunas e aviso da Agenda preservado em coluna única. Folhas com largura mínima nativa superior a 460 pt podem ser cortadas pelo host artificial estreito; esse corte já ocorre nas capturas anteriores e não representa uma janela real redimensionável até essa largura.

O teste nativo mediu aproximadamente 6,7 s até todos os avatares da criação de grupo pararem. Isso demonstra a eliminação dos frames contínuos nesse estado; não é uma medição percentual de CPU do app inteiro. Da mesma forma, a contagem do cache prova a redução de normalizações no filtro da fixture, sem extrapolar para um ganho global.

Houve uma tentativa intermediária de configurar `accessibilityReduceMotion` diretamente no teste. A compilação a recusou porque o ambiente é somente leitura no SDK atual (`cannot convert value ... to expected argument type 'WritableKeyPath<EnvironmentValues, Bool>'`), registrada em `final-tests.log`. O teste foi corrigido para respeitar a preferência real do sistema, e as validações seguintes passaram. Uma busca por glob de testes também retornou `zsh:1: no matches found: Tests/OrbAppTests/*Skills*Tests.swift`; a seleção foi refeita a partir dos nomes existentes.

A suíte completa não foi executada para não disputar foco/recursos com o Orb em uso. Não foram realizados testes com contas, mensagens, instalação de conectores ou redefinição reais. A revisão estática não garante ausência de todo gargalo possível; os ganhos afirmados acima têm mecanismo e validação identificados.

Release concluído com `./scripts/bundle.sh release` em 208,79 s, versão 1.0.602, assinatura “Orb Local”. `codesign --verify --deep --strict build/Orb.app` terminou com exit 0. Executável release e bundle têm o mesmo UUID `EDEAACD1-44CA-3639-B239-370FEAACDABB`. A reabertura aguardou a rotina do Atendente concluir às 22h20; todos os Orbs estavam parados antes de ⌘Q. O processo anterior foi encerrado normalmente e o bundle `/Users/thiagomacbookpro/Orb/build/Orb.app` foi reaberto às 22h21, com a conversa do Atendente restaurada. Nenhuma execução foi interrompida nesta passagem.

## Cobertura por arquivo

Caminhos desta tabela relativos a `Sources/Orb/Views/`. “Preservado” significa que a inspeção não justificou uma alteração nesta passagem, não que houve benchmark individual de cada componente.

| Arquivo | Foco da revisão e resultado |
| --- | --- |
| `ApprovalKeyboard.swift` | Monitores limitados à janela e removidos pelo ciclo de vida; preservado. |
| `AttachmentViews.swift` | Três publicações assíncronas protegidas contra cancelamento; grids e prévias limitados preservados. |
| `BrowserPickers.swift` | Estados e opções de navegador, sem relógio próprio; preservado. |
| `BrowserSettings.swift` | Atualização na abertura/ativação; progresso só durante instalação; preservado. |
| `CatalogParts.swift` | Foco ao limpar e lupa acessível; política de resposta inclui cancelamento. |
| `ClaudeCodeSettings.swift` | Configuração curta e estado observado; preservado. |
| `Clipboard.swift` | Feedback temporário finito de cópia; preservado. |
| `CommandPalette.swift` | Índice preparado na abertura, lista preguiçosa e comandos após fechamento; preservado. |
| `ComposerChips.swift` | Menus, seleção, foco e escopo de skills; preservado. |
| `ConnectorGalleryView.swift` | Reserva de aviso apenas em múltiplas colunas; geometria observada como booleano. |
| `ConnectorsView.swift` | Loading de busca cancelada corrigido; badges legíveis e descrição completa no tooltip. |
| `ContextSettings.swift` | Preferências e controles estáticos; preservado. |
| `DeleteOrbDialog.swift` | Estados destrutivos e aviso finito; preservado, sem executar exclusão. |
| `FindViews.swift` | Seleção e resultados por evento, sem polling; preservado. |
| `FirstRunCard.swift` | Detecção e conexão por tarefas, geração de tentativa e pulso finito; preservado. |
| `Groups/GroupBoardView.swift` | Filtro de memória ganha normalização seletiva via MemoryGroups; undo finito preservado. |
| `Groups/GroupComposer.swift` | Menções e teclado locais à janela; preservado. |
| `Groups/GroupDeleteDialog.swift` | Diálogo estático; preservado, sem executar exclusão. |
| `Groups/GroupHeader.swift` | Título e avatares pequenos; preservado. |
| `Groups/GroupPanel.swift` | Membros limitados e campos gravados ao confirmar/perder foco; preservado. |
| `Groups/GroupPauseCard.swift` | Aviso e ações por estado; preservado. |
| `Groups/MentionPicker.swift` | Candidatos limitados aos membros; preservado. |
| `Groups/NewGroupSheet.swift` | Avatares ociosos passam a repousar; teste verifica relógios nativos. |
| `Groups/StackedAvatars.swift` | Composição limitada de avatares estáticos; preservado. |
| `ImportPanel.swift` | Leitura e parse fora da thread principal, cancelamento e identidade da tentativa; preservado. |
| `InspectorFold.swift` | Expansão finita e estado persistido por seção; preservado. |
| `LiveBotAvatar.swift` | Leitura de estado isolada por Orb; preservado. |
| `LocalConnectorSheet.swift` | Fases explícitas e trabalho acionado pelo usuário; preservado. |
| `MarketplaceGallery.swift` | Índice normalizado preparado fora da thread principal e lista preguiçosa; preservado. |
| `MemoryViews.swift` | Filtro compartilhado otimizado; detalhes sob demanda e undo com espera limitada preservados. |
| `ModelPicker.swift` | Botão de limpar, foco e Padrão para consulta só de espaços. |
| `ModelPopover.swift` | Grupos e recentes preparados por consulta, listas preguiçosas; usa campo compartilhado polido. |
| `Multi/CreatedByLine.swift` | Texto e avatar estático; preservado. |
| `Multi/EventLineView.swift` | Detalhes abertos sob demanda; preservado. |
| `Multi/ExchangeParts.swift` | Mini avatares estáticos e pulso limitado ao estado pendente; preservado. |
| `Multi/ExchangeSheet.swift` | Leitura de trabalho delegado confere cancelamento antes de publicar; lista preguiçosa preservada. |
| `Multi/OpenTalksSection.swift` | Seção derivada de trocas abertas; preservado. |
| `Multi/OrbMessageRow.swift` | Expansão e conteúdo por estado da troca; preservado. |
| `Multi/OrbProposalCard.swift` | Lookup de pasta com debounce/cancelamento e entrada finita; preservado. |
| `Multi/WizardFooter.swift` | Rodapé sem relógio ou I/O; preservado. |
| `ProviderSettings.swift` | Rascunho de URL evita invalidar provedores por tecla; login cancelado ao sair; preservado. |
| `QuestionCard.swift` | Pulso único, atalhos escopados e opções acionadas por evento; preservado. |
| `QueuedMessages.swift` | Identidade própria da fila, botões por hover/foco e anexos compartilhados; preservado. |
| `QuickAskView.swift` | Leitura de streaming isolada no trecho de resposta; avatares inativos não escolhidos pausados; preservado. |
| `ResetOrbSheet.swift` | Contagem fora da thread principal e bloqueio durante redefinição; preservado, sem executar reset. |
| `SavedKeyField.swift` | Campo seguro, foco e ações por estado; preservado. |
| `SharedControls.swift` | Commit de nome idempotente, confirmação por Return e blur; preservado. |
| `SheetKit.swift` | Tamanhos nativos, rodapé, registro da folha e foco; preservado. |
| `SheetsAndSettings.swift` | Lookup de pasta fora da thread principal e cancelamento do wizard; preservado. |
| `SidebarCategoryViews.swift` | Drag atualiza só quando preview muda; geometria em caixa de frames; preservado. |
| `SidebarChatList.swift` | Lista curta inicial, identidades persistentes e marcadores por estado; preservado. |
| `SkillsView.swift` | Ações em linha própria em cards estreitos; busca cancelada não encerra loading alheio. |
| `TaskPlanRing.swift` | Progresso atualiza por mudança do plano, sem relógio próprio; preservado. |
| `WelcomeOffer.swift` | Alternativas sob demanda e feedback durante conexão; preservado. |
| `WelcomeView.swift` | Leitura de memórias guardadas protegida contra cancelamento; entrada e celebração finitas preservadas. |
| `InspectorSupport.swift` | Categoria filtrada antes da normalização; cache conserva semântica de invalidação. |
| `ComposerSupport.swift` | Listagem de modelos calculada por consulta e histerese do painel; preservado. |
| `EmptyChatContent.swift` | Sugestões locais limitadas, sem requisição ao modelo; preservado. |
| `PermissionConfirmation.swift` | Confirmação e aplicação separadas, sem trabalho em body; preservado. |
| `ProviderPresentation.swift` | Formatação e estados puros; preservado. |

Auxiliares adicionais: `Catalog/BrandGlyph.swift` (cache de paths e bounds), `Catalog/SVGPathData.swift` (parse e arcos executados ao preparar as marcas), `Catalog/BrandMarks.swift` (dados vetoriais estáticos). `Views/CatalogSnapshots.swift` ganhou somente a fixture debug `model-search`. `Tips.swift`, `Shortcuts.swift`, `AppModel+Commands.swift` e `ApprovalNotifications.swift` foram classificados como texto/roteamento/eventos; não introduzem um loop de renderização.
