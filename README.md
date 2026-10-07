# OpenBot para macOS

App nativo em SwiftUI (macOS 14+) para conversar com bots que agem no seu Mac. Cada bot é um
**Orb** animado, tem seu modelo, sua memória, suas permissões e suas rotinas. Inspirado nas
funcionalidades do Grok Bot, com design e código próprios.

```bash
./scripts/bundle.sh && open build/OpenBot.app   # gera e abre o app (com ícone)
swift test                                      # 42 testes (motor, cliente, ferramentas, MCP, dados)
```

Na primeira vez: **Ajustes → Modelo**, escolha o provedor, cole a chave e clique em
**Testar e buscar modelos**.

## O que o app faz

| Área | Como funciona |
|---|---|
| **Modelos** | Qualquer API compatível com OpenAI: xAI (Grok), OpenAI, OpenRouter, Ollama, LM Studio ou URL própria. Resposta em streaming; modelo padrão + modelo por bot. Chave no **Keychain**. |
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
- **Dados**: `state.json` (bots, rotinas, skills, conectores, provedor) e `conversations/<bot>.json` (o que a tela mostra e
  o histórico do modelo). Campos novos devem ter valor padrão na decodificação (`value(_:default:)`), para arquivos antigos
  continuarem abrindo.

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

## Próximos passos
1. Distribuição: assinatura Developer ID, Hardened Runtime, notarização e atualizações (Sparkle).
2. Atalho global para a pergunta rápida; chamar outro bot com `@`.
3. Controle do Mac por Acessibilidade e captura de tela (helper separado, com onboarding de permissões).
4. Anexar imagens para modelos com visão; histórico de várias conversas por bot.
