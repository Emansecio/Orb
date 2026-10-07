# OpenBot para macOS

App nativo em SwiftUI (macOS 14+) para conversar com bots que agem no seu Mac. Cada bot é um
**Orb** animado, tem seu modelo, sua memória, suas permissões e suas rotinas. Inspirado nas
funcionalidades do Grok Bot, com design e código próprios.

```bash
./scripts/bundle.sh && open build/OpenBot.app   # gera e abre o app (com ícone)
swift test                                      # 42 testes (motor, cliente, ferramentas, MCP, dados)
```

Na primeira vez: **Ajustes → Modelos → Adicionar provedor**, cole a chave (ou entre com o ChatGPT ou o Claude Code)
e escolha o modelo padrão.

> Para usar a assinatura do **Claude (Pro/Max)**, escolha **Claude Code (sua assinatura)**: o OpenBot roda o Claude Code
> instalado no seu Mac, e o login é o do próprio Claude Code (veja [Claude Code](#claude-code)). Login do Claude.ai dentro
> do OpenBot não é oferecido.

## O que o app faz

| Área | Como funciona |
|---|---|
| **Modelos** | Vários provedores ao mesmo tempo, cada bot escolhe o seu (`provedor/modelo`): **ChatGPT** (sua assinatura Plus/Pro, login oficial "Sign in with ChatGPT" para apps locais), **Claude Code** (sua assinatura Pro/Max, pelo Claude Code instalado no Mac), **OpenAI**, **Claude** (chave da API Anthropic), **OpenCode Zen**, **OpenCode Go**, **Command Code**, xAI, OpenRouter, Ollama, LM Studio ou URL própria. Listas de modelos vêm **ao vivo** do endpoint de cada provedor (ao abrir e a cada 6 h), com o formato certo de cada modelo: chat completions, Responses ou Messages (os do Claude Code vêm do próprio CLI). Chaves e login no **Keychain**. |
| **Ferramentas** | `run_command` (zsh), `read_file`, `write_file`, `list_directory`, `search_files` (Spotlight), `web_fetch`, `open`, `applescript` (Mail, Calendário, Notas…), `remember`. |
| **Permissões** | Por bot: **Perguntar antes** (ações que mudam algo, acessam a web ou guardam memória pedem aprovação), **Automático** ou **Só leitura**. “Sempre permitir” vale por ferramenta e pode ser revogado no painel do bot. Cada grupo de ferramentas pode ser desligado (Terminal e arquivos, Web, Apps do Mac, Conectores). |
| **Conectores** | Servidores **MCP** locais (stdio: npx, uvx, docker) ou **remotos** (Streamable HTTP, com fallback SSE). Aba **Explorar** busca no [registro oficial do MCP](https://registry.modelcontextprotocol.io) e monta a configuração (você só preenche as chaves); aba **Instalados** com status ao vivo, ativar/desativar, editar e apagar. |
| **Skills** | Formato aberto **SKILL.md**. Aba **Explorar** busca no catálogo [Skills.sh](https://skills.sh) e lê o `SKILL.md` no GitHub de quem publicou, com prévia completa antes de instalar; aba **Instaladas** para ativar/desativar, editar e apagar. Use com `/atalho` (ex.: `/pdf`, `/resumir`). |
| **Rotinas** | O bot faz uma tarefa sozinho todo dia, toda semana ou a cada X horas enquanto o app está aberto; resultado no card e notificação. |
| **Memória** | O bot guarda fatos duradouros sobre você (`remember`); você vê e apaga no painel. |
| **Mac** | Ícone na barra de menus com pergunta rápida, notificações quando termina ou precisa de você, abrir ao iniciar sessão, arrastar arquivos para o chat. |
| **Orbs** | 18 cores e dezenas de rostos, cabelos e acessórios; expressões por tipo de tarefa; olhos seguem o cursor. Veja [docs/ORBS.md](docs/ORBS.md). |

Atalhos: ⌘N novo bot · ⇧⌘N nova conversa · ⌥⌘B painel do bot · ⌥↑/⌥↓ trocar de bot · ⌘1…⌘9 ir para um bot · ↩ enviar.

## Arquitetura

```
Views (SwiftUI)  ──►  AppModel (@MainActor @Observable)
                        │  estado, conversas, rotinas, notificações
                        ├─ Store ............ JSON em ~/Library/Application Support/OpenBot + Keychain
                        ├─ AgentEngine ...... loop modelo ↔ ferramentas + portão de aprovação (actor)
                        │    ├─ OpenAIClient  streaming SSE, tool calls
                        │    ├─ ToolBox ..... ferramentas nativas (ProcessRunner com timeout e grupo de processos)
                        │    └─ MCPManager .. conectores MCP via stdio
                        └─ Orbs ............. avatar 3D em camadas, animado em Core Animation
```

- **Contratos** em [`Engine/EngineTypes.swift`](Sources/OpenBotMac/Engine/EngineTypes.swift): `LLMClient`, `AgentTool`,
  `ToolSpec`, `ChatMessage`, `JSONValue`. Uma ferramenta nova é um `struct` que implementa `AgentTool` e entra em `ToolBox.all`.
- **Um turno**: `AppModel.send` monta um `TurnRequest` (prompt do sistema, histórico, ferramentas permitidas) e consome os
  `TurnEvent`s do `AgentEngine` (texto, ferramenta iniciada/terminada, aprovação, mensagens para o histórico, erro).
- **Risco**: só ler arquivos, listar pastas e buscar no Spotlight é `.safe`. Todo o resto é `.sensitive` e passa pelo
  portão: o que muda o Mac ou roda código, e também o que pode **mandar dados para fora** (`web_fetch`, `open`) ou ficar no
  prompt de todas as conversas (`remember`). Assim, um texto malicioso numa página não consegue ler um segredo e enviá-lo
  sem você aprovar. “Só leitura” vale mesmo para ferramentas marcadas como “Sempre permitir”.
- **Contexto**: o modelo recebe as últimas 60 mensagens (começando numa mensagem sua), com saídas antigas de ferramentas
  encurtadas; chamadas interrompidas recebem um resultado “não executado” para o histórico continuar válido.
- **Claude Code**: bots com modelo `claudeCode/…` não passam pelo `AgentEngine`; o `ClaudeCodeEngine` roda um
  `claude -p` por turno (veja abaixo).
- **Dados**: `state.json` (bots, rotinas, skills, conectores, provedor) e `conversations/<bot>.json` (o que a tela mostra e
  o histórico do modelo). Campos novos devem ter valor padrão na decodificação (`value(_:default:)`), para arquivos antigos
  continuarem abrindo.

## Claude Code

O provedor **Claude Code (sua assinatura)** usa o `claude` que você já instalou (achado pelo shell de login;
[como instalar](https://code.claude.com/docs/en/setup)). A [política da Anthropic](https://code.claude.com/docs/en/legal-and-compliance)
proíbe apps de terceiros de oferecer login do Claude.ai ou de guardar e repassar as credenciais dele, mas permite rodar o
Claude Code sem modificações com a sua própria assinatura. Por isso o OpenBot **nunca lê, copia nem guarda os tokens** do
Claude Code e nunca chama a Anthropic com eles:

- **Entrar / Sair** rodam `claude auth login --claudeai` / `claude auth logout`: o próprio Claude Code abre o navegador e
  guarda a sessão. O status vem de `claude auth status --json`. “Sair” desconecta o Claude Code no Mac inteiro (Terminal também).
- **Um turno** é `claude -p --input-format stream-json --output-format stream-json --include-partial-messages --verbose
  --permission-prompt-tool stdio --permission-mode … --append-system-prompt=… (--resume=<sessão> | --session-id=<nova>)` na
  pasta do bot. O OpenBot manda `initialize` e a mensagem pelo stdin, mostra o texto em streaming e as ferramentas do Claude Code
  no chat, e responde os pedidos `can_use_tool` (protocolo do Agent SDK) com os cartões de aprovação. A sessão fica salva na
  conversa; “Nova conversa” começa outra.
- **Permissões**: Perguntar antes → modo `default` (o que precisa de aprovação vira cartão; “Sempre permitir” vale por
  ferramenta, ex.: `Bash`); Automático → `acceptEdits` e o OpenBot aprova o resto; Só leitura → `plan` e toda escrita é negada.
  Sem “Terminal e arquivos” saem `Bash`/`Edit`/`Write`…; sem “Web” saem `WebFetch`/`WebSearch`; com “Conectores” os
  conectores ativos vão por `--mcp-config` (arquivo temporário só seu), sem eles saem as ferramentas `mcp__*`.
- **Modelos**: a lista é a que o Claude Code oferece à sua conta (resposta do `initialize`, sem mandar prompt);
  “Padrão do Claude Code” não passa `--model`. Se o CLI não responder, ficam os apelidos documentados (opus, sonnet, haiku).
- Limites: a memória do bot entra no prompt da sessão quando ela começa (o Claude Code reaproveita esse prompt ao retomar);
  a ferramenta `remember` não existe nesse modo; ao trocar de outro provedor para o Claude Code no meio da conversa, o Claude Code
  começa sem o histórico anterior.

## Desenvolvimento

```bash
python3 scripts/fake-llm.py          # modelo falso em http://127.0.0.1:8765/v1 (pede um run_command)
open -n build/OpenBot.app --env OPENBOT_DATA_DIR=/tmp/openbot-teste   # dados isolados
open -n build/OpenBot.app --env OPENBOT_SEND="Como está meu Mac?"   # envia um prompt ao abrir
./build/OpenBot.app/Contents/MacOS/OpenBot --render-orbs docs/orbs-activities.png
```

| Variável / argumento | Efeito |
|---|---|
| `OPENBOT_DATA_DIR` | Pasta de dados alternativa (testes sem tocar nos seus bots) |
| `OPENBOT_SEND` | Envia o texto ao bot selecionado ao abrir (teste ponta a ponta) |
| `OPENBOT_STATIC_ORBS` | Desliga a animação dos Orbs |
| `--render-orbs arquivo.png` / `--render-icon arquivo.png` | Gera a folha de Orbs / o ícone e sai |
| `--snapshot <tela> arquivo.png` | Renderiza uma tela fora do monitor (chat, skills, skills-explore, connectors, connectors-explore, routines) e sai |
| `OPENBOT_LIVE_TESTS=1 swift test --filter LiveCatalogTests` | Testa os catálogos e um conector remoto de verdade (precisa de internet) |
| `OPENBOT_CLAUDE_PATH=/caminho/claude` | Usa outro executável como Claude Code (ex.: um `claude` falso para testes) |
| `OPENBOT_LIVE_TESTS=1 swift test --filter ClaudeCodeLiveTests` | Roda o `claude` de verdade **deslogado** (pasta de config vazia): confere flags, handshake e lista de modelos, sem usar conta |

## Próximos passos
1. Distribuição: assinatura Developer ID, Hardened Runtime, notarização e atualizações (Sparkle).
2. Atalho global para a pergunta rápida; chamar outro bot com `@`.
3. Controle do Mac por Acessibilidade e captura de tela (helper separado, com onboarding de permissões).
4. Anexar imagens para modelos com visão; histórico de várias conversas por bot.
