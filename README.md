# OpenBot para macOS (protótipo de interface)

App nativo em SwiftUI (macOS 14+). Usa as funcionalidades do Grok Bot como referência,
mas com design próprio. Os dados ainda são simulados (`MockGateway`); o próximo passo é
ligar no gateway do OpenBot.

```bash
swift run                 # roda direto
./scripts/bundle.sh       # gera build/OpenBot.app
open build/OpenBot.app
```

## Design: dark monocromático (tokens do tema dark do Grok Bot)
- Conversa `#070707`, barra lateral/detalhes `#111111`, cards/compositor `#181818`, texto `#FCFCFC` em 100/74/60/36%.
- Balão do usuário `#5A5A5A`, balão do bot `#262626`, bordas `#FCFCFC` a 10–15%, azul `#1084FE`/`#459FFE`.
- Layout: barra lateral 280 px (240–400), conversa ≥ 424 px, painel de detalhes 320 px; fonte 14 px com altura de linha de 22 px.
- Aprovação: Não permitir · Sempre permitir · Permitir uma vez. Ferramentas como linhas discretas com brilho animado enquanto rodam.
- Atalhos: ⌘N novo bot, ⇧⌘N nova conversa, ⌥⌘B detalhes, ⌥↑/⌥↓ trocar de bot, ⌘1…⌘9 ir para um bot, ⌘↩ enviar.
- **Personalização:** cada bot é um Orb próprio (veja abaixo). Sem nome, logo, fontes (XVF) ou sons do Grok Bot (usa SF Pro).

## Orbs (os bots)
Cada bot é um **Orb**, uma esfera de gel brilhante renderizada em 3D no Blender e composta em camadas no app.
Documentação completa em [docs/ORBS.md](docs/ORBS.md).
- 18 cores, 12 olhos, 10 bocas, 5 sobrancelhas, 4 bochechas, 6 bigodes, 8 cabelos e 15 acessórios combináveis, com cor livre para cabelo, bigode e acessórios.
- Editor ao vivo em **Novo bot** e em **Painel do bot → Personalizar Orb…** (miniaturas renderizadas, Sortear).
- Mostra o que o bot está fazendo: ouvindo (pula quando você envia), pensando, terminal, navegando, lendo, buscando,
  esperando aprovação, feliz ao terminar, erro ao parar, dormindo (rotina pausada).
- Os olhos seguem o cursor (com paralaxe), crescem e encaram ao passar o mouse, pulam ao clicar e piscam.
- Animação em Core Animation (~1 % de CPU parado). `OPENBOT_STATIC_PETS=1` desliga, `OPENBOT_DEMO=1` envia um prompt
  sozinho, `--render-orbs docs/orbs-activities.png` gera a folha de referência.

## Funcionalidades do Grok Bot → telas daqui
| Grok Bot | OpenBot Mac |
|---|---|
| Vários bots, avatares 3D | Barra lateral com Orbs animados, não lidas e status ao vivo; ⌘N cria bot com editor de Orb |
| Status "trabalhando" | Linha pulsante com a atividade atual + Orb que muda de expressão por tipo de tarefa |
| Cards de ferramenta | `ToolCallStrip`: rodando → concluído (com duração), saída expansível |
| Aprovações | `ApprovalCard`: Negar · Permitir uma vez · Sempre para este bot |
| Compositor | Anexos, `/` skills, `@` outro bot, modo de permissão, seletor de modelo, parar |
| Computador do bot | Painel "Mesa de trabalho" (pastas e uso) |
| Memória | Lista editável no painel do bot ("Esquecer") |
| Rotinas com pausa por inatividade | Tela Rotinas com cards, liga/desliga e "Retomar" |
| Conectores / MCP | Tela Conectores por categoria, com busca |
| Skills | Tabela com busca; uso via `/` no chat |
| Atalho rápido | Ícone na barra de menus com pergunta rápida |
| Permissões do Mac | Ajustes → Permissões (checa Acessibilidade e Gravação de Tela de verdade) |

## Arquitetura
- `AppModel` (`@Observable`, MainActor): estado, turnos, aprovações.
- `AgentGateway` (protocolo): `runTurn` devolve um `AsyncStream<TurnEvent>` (status, texto, ferramentas, aprovação).
  Trocar `MockGateway` por um cliente HTTP+SSE para `127.0.0.1:1340` (gateway do OpenBot) não muda nada na UI.

## Próximos passos
1. `OpenBotGatewayClient` (SSE `/api/events` + `POST /api/<method>`) no lugar do mock.
2. Chaves no Keychain; item de login com `SMAppService`; atalho global.
3. Helper de Computer Use (Acessibilidade + ScreenCaptureKit) via XPC.
4. Notificações ao terminar/pedir aprovação; Sparkle para atualizações.
