# Ferramentas de desenvolvimento

Parte do mapa do código: veja [ARQUITETURA.md](ARQUITETURA.md) para a visão geral.


## Argumentos

| Argumento | Efeito |
|---|---|
| `--pipe-tools <declarações.json> --pipe-mailbox <pasta>` (montado pelo `ClaudeCodeClient`) | roda só o servidor MCP que declara as ferramentas do Orb ao CLI do Claude Code (que é apenas o cano até o modelo); os resultados vêm da caixa de correio que o motor do Orb preenche; sem janela |
| `--snapshot <modo> <arquivo.png>` | desenha uma tela fora da vista e sai (abaixo; só em build de desenvolvimento) |
| `--render-orbs <arquivo.png>` | folha de Orbs × atividades (`docs/orbs-activities.png`) |
| `--render-icon <arquivo.png> [pixels]` | o ícone do app, desenhado no tamanho pedido (padrão 1024; `scripts/bundle.sh` chama um por tamanho do iconset) |

`--snapshot` e `--render-orbs` só existem em build de desenvolvimento (`swift build`, que é debug, ou um release com
`-Xswiftc -DORB_DEV_TOOLS`, p. ex. `ORB_DEV_TOOLS=1 scripts/bundle.sh`): ficam atrás de `#if DEBUG || ORB_DEV_TOOLS`, junto com as
cenas (`*Snapshots.swift`, `TranscriptSamples`, `SnapshotComposerScenes`, `SwitchBench`). No app distribuído, os dois avisam no stderr
e saem com código 64 em `Launcher.main`, antes de existir modelo, janela ou pasta de dados. `--render-icon` fica em todos os
builds (o `bundle.sh` o usa em release). Para gerar uma tela: `.build/debug/Orb --snapshot skills /tmp/skills.png`.

Os três modos de desenho (`--snapshot`, `--render-orbs`, `--render-icon`) usam uma pasta de dados temporária nova, nunca a sua
(`DevRun.dataFolder`), a menos que você defina `ORB_DATA_DIR` de propósito. Neles o Keychain não é lido, gravado nem migrado do
OpenBot, e a migração de dados do OpenBot não roda. Também não há trabalho de fundo com efeito fora do processo, mesmo com
`ORB_DATA_DIR` apontando para uma cópia de dados reais: nada de agendador de rotinas, servidores dos conectores (MCP) nem
verificação do Claude Code (`AppModel(devRun:)`); `ORB_SEND` continua funcionando. A pasta temporária é apagada ao terminar.

## Variáveis de ambiente

| Variável | Efeito |
|---|---|
| `ORB_DATA_DIR` | pasta de dados alternativa (use sempre que testar). Nos modos `--snapshot`/`--render-*`, sem ela vale uma pasta temporária nova |
| `ORB_SEND="texto"` | envia o texto ao Orb selecionado ao abrir (ponta a ponta) |
| `ORB_STATIC=1` | desliga a animação dos Orbs |
| `ORB_ANIMATE_INACTIVE=1` | Orbs e brilho animam mesmo com a janela inativa ou coberta (medir CPU sem trazer o app para a frente) |
| `ORB_MEMORY_IDLE=<segundos>` | tempo de pausa até a conversa virar página de sessão (padrão 1 800) |
| `ORB_CLAUDE_PATH=/caminho/claude` | outro executável como Claude Code (um falso, nos testes) |
| `ORB_DEBUG_USAGE=1` | uma linha por chamada ao modelo no stderr: tokens, cache lido/escrito |
| `ORB_SNAPSHOT_WIDTH` / `ORB_SNAPSHOT_HEIGHT` / `ORB_SNAPSHOT_WAIT` | tamanho (1100×760) e espera em segundos (8) de `--snapshot` |
| `ORB_SNAPSHOT_PANE_WIDTH` | largura da lateral (280) e do painel do Orb (360) em `sidebar`, `sidebar-profile`, `sidebar-categories*`, `groups-sidebar` e `inspector*`; use 240 e 244 para ver o mínimo |
| `ORB_LIVE_TESTS=1` | liga as suítes que usam a rede (catálogos reais) |
| `ORB_REAL_BROWSER_TESTS=1` / `ORB_REAL_BROWSER_WINDOW=1` | ligam os testes com o navegador real (internet) e, dentre eles, o que abre uma janela e toma o foco |
| `ORB_TEST_WIDTH=<n>` | (em `scripts/test.sh`) quantos testes rodam de uma vez; o padrão é metade dos núcleos |
| `ORB_SIGN_IDENTITY="Nome"` | (em `scripts/bundle.sh`) assina com outra identidade |

## `--snapshot`

Renderiza a tela com dados de exemplo numa janela fora da tela, sem tirar o foco
(`NSApp.setActivationPolicy(.accessory)`), e grava o PNG. Os Orbs saem estáticos (o Core Animation não é capturado). Os dados
vêm de uma pasta temporária nova (os Orbs iniciais) ou, se você definir `ORB_DATA_DIR`, dessa pasta. O Keychain não é tocado.

> O `--snapshot` nunca usa a sua pasta real: só escreve em `ORB_DATA_DIR` se você o definir (aponte para uma pasta de teste).

Modos (qualquer outro nome mostra o chat do primeiro Orb):

| Área | Modos |
|---|---|
| Janela e painéis | `app`, `sidebar`, `sidebar-profile` (com o perfil de exemplo), `inspector` (aba Geral), `inspector-memory`, `inspector-folder`, `inspector-routines`, `memory-sheet`, `new-orb`, `new-orb-kept` (com memórias guardadas, uma escolhida), `new-orb-import` (o painel de importação vazio), `new-orb-import-preview` (a prévia de um exemplo, com um item suspeito desmarcado; use `ORB_SNAPSHOT_HEIGHT=1300` para vê-la inteira), `new-orb-imported` (de volta ao formulário, com a importação confirmada), `new-orb-marketplace` (a galeria do marketplace do Grok Bot com bots de exemplo e um deles na prévia; use `ORB_SNAPSHOT_HEIGHT=1300`), `welcome` (sem modelo), `welcome-checking` (conexões ainda não verificadas), `welcome-ready`, `welcome-kept` (com duas memórias guardadas), `welcome-returning` (lista esvaziada), `welcome-narrow` (a pronta; use `ORB_SNAPSHOT_WIDTH=1000 ORB_SNAPSHOT_HEIGHT=620`) — todas com `ORB_DATA_DIR` numa pasta com `{"bots":[]}`, senão o modo de desenvolvedor cria o Atlas —, `editor`, `editor-<categoria>` (o editor numa categoria, com um visual que tem cabelo e chapéu), `delete-orb`, `palette`, `shortcuts`, `menubar-icons` |
| Conversa | `transcript-rich` (cores do código, tabela, mudança de `edit_file`, volta ao fim, gráficos, Mermaid, KaTeX, prévia e página), `transcript-rich-work` (trilho, cartão do plano, fontes, mudanças e perguntas com várias respostas e formulário), `rich-sheet-diagram`, `rich-sheet-chart`, `rich-sheet-page` (a folha não captura o conteúdo do `WKWebView`), `side-question`, `chat-greeting`, `chat-greeting-returning`, `chat-greeting-typed`, `chat-working` (uma mensagem direcionada, uma para depois da tarefa e uma entregue no meio, com a marca), `chat-working-wait`, `chat-working-retry`, `chat-plan-done` (a resposta com a linha "Plano concluído · 5 etapas" embaixo), `chat-typed`, `chat-attachments`, `chat-attachments-queued`, `chat-drop` (arquivos arrastados sobre o chat, antes de soltar), `chat-slash`, `popover-permissions`, `popover-model`, `popover-skills`, `approvals`, `transcript`, `transcript-approvals`, `transcript-notices`, `transcript-compacted` (o que a compactação resumiu, recolhido numa faixa com "Mostrar"), `transcript-failed`, `transcript-retry`, `transcript-find` (a barra ⌘F aberta sobre o começo da conversa), `transcript-edit` (a primeira mensagem de volta no campo, em edição), `transcript-attachments` (uma, duas, cinco e doze imagens, arquivos longos, ausente e antigo), `transcript-outputs` (arquivo novo, alterado e captura sob a linha da ferramenta), `transcript-tools` e `transcript-tools-open` (ações seguidas recolhidas numa linha, com um aviso e uma falha no meio; e abertas), `transcript-work` e `transcript-work-open` (o mesmo pedido terminado: o trabalho numa linha acima da resposta), `chat-long-draft` (mensagem maior que o campo, que rola) |
| Contexto | `context-meter`, `context-nudge`, `context-popover`, `context-popover-result`, `context-popover-short`, `settings-context` |
| Ajustes | `settings-general`, `settings-profile` (Geral com um perfil de exemplo e foto desenhada na hora), `settings-orbs` (a aba Orbs inteira, com conversas abertas de exemplo), `settings-reset` (a folha "Redefinir o Orb?"), `settings-models`, `settings-usage` (um mês de uso de exemplo escrito na pasta de dados; `-usagePeriod today\|week\|month30\|thisMonth` e `-usageChartBy model`, antes de `--snapshot`, escolhem outra vista sem salvar nada), `settings-usage-empty` (sem exemplo: mostra o que a pasta tiver), `settings-perms`, `settings-perms-tested` e `settings-perms-stale` (linhas fixas depois do "Testar" e com a gravação de tela esperando reabrir), `first-run-banner`, `models` |
| Barra de menus | `quickask`, `quickask-approvals`, `quickask-reply` |
| Rotinas e conversas | `routines`, `routine-editor`, `routine-editor-new`, `routine-run`, `routine-run-failed`, `routine-conversation` |
| Skills e conectores | `skills`, `skills-explore`, `skill-editor`, `skill-editor-new`, `skill-preview`, `skill-preview-installed`, `connectors` (instalados), `connectors-gallery`, `connectors-explore`, `connectors-lazy`, `conn-tools`, `conn-signin`, `conn-needs-signin`, `conn-editor-notion`, `conn-google-intro`, `conn-google-account`, `conn-google-account-agenda`, `conn-google-denied`, `conn-google-working`, `conn-google-done`, `conn-editor-supabase`, `conn-editor-github`, `conn-editor-files`, `conn-editor-slack`, `conn-editor-manual`, `conn-editor-edit`, `conn-editor-edit-registry`, `conn-editor-connecting`, `conn-editor-connected`, `conn-editor-failed`, `conn-editor-retired-slack` |
| Início | `inicio`, `inicio-empty` (sem Orbs), `inicio-working` (um Orb com trabalho em andamento), `inicio-attention` (um resultado de rotina pedindo atenção), `inicio-long` (textos longos), `inicio-many` (14 resultados, com "Ver mais"), `inicio-reduced-motion` (a página com `reduceMotionOverride`, já que `accessibilityReduceMotion` é um ambiente somente leitura), `inicio-sidebar` (a página ao lado da `SidebarView` real), `inicio-interactive` (não grava PNG: abre uma janela real da prévia com botões que simulam trabalho e resultado, para conferir clique, foco, scroll e a pílula "Novos resultados") |

Com `ORB_SEND`, o snapshot envia o prompt e espera `ORB_SNAPSHOT_WAIT` segundos antes de fotografar. Para medir o streaming sem
abrir janela, use o modelo falso com `--long`, `ORB_SEND` e `ORB_SNAPSHOT_WAIT=40` e observe o processo (`ps -o %cpu=`,
`sample`).

## Scripts

| Script | O que faz |
|---|---|
| `scripts/bundle.sh [debug\|release]` | compila (padrão `release`), monta `build/Orb.app` (executável, `Resources/Orbs`, `Info.plist` com `app.orb.mac`, `NSAllowsArbitraryLoads` (sem isso o macOS bloqueia `http://` no app empacotado) e os textos de permissão de Agenda (`NSCalendarsFullAccessUsageDescription`), Lembretes (`NSRemindersFullAccessUsageDescription`) e Apple Events, ícone gerado pelo próprio app) e assina |
| `scripts/make-signing-identity.sh` | cria uma vez o certificado local "Orb Local" no chaveiro de login e o marca como confiável para assinar |
| `scripts/fake-llm.py` | o modelo falso acima |
| `scripts/test.sh [opções do swift test]` | roda os testes com metade dos núcleos (veja "Testes") |

A arte (camadas dos Orbs) tem o seu próprio gerador, descrito em [art/README.md](../art/README.md).

