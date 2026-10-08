# Orb para macOS

App nativo em SwiftUI (macOS 14+) para conversar com Orbs: assistentes animados que agem no seu Mac.
Cada Orb tem seu modelo, sua memória, suas permissões e suas rotinas. Inspirado nas
funcionalidades do Grok Bot, com design e código próprios.

```bash
./scripts/bundle.sh && open build/Orb.app   # gera e abre o app (com ícone)
swift test                                      # 186 testes (motor, provedores, Claude Code, ferramentas, MCP, Orbs, dados)
```

Na primeira vez: **Ajustes → Modelos → Adicionar provedor**, cole a chave (ou entre com o ChatGPT ou o Claude Code)
e escolha o modelo padrão.

> Para usar a assinatura do **Claude (Pro/Max)**, escolha **Claude Code (sua assinatura)**: o app roda o Claude Code
> instalado no seu Mac, e o login é o do próprio Claude Code (veja [Claude Code](#claude-code)). Login do Claude.ai dentro
> do app não é oferecido.

## O que o app faz

| Área | Como funciona |
|---|---|
| **Modelos** | Vários provedores ao mesmo tempo, cada Orb escolhe o seu (`provedor/modelo`): **ChatGPT** (sua assinatura Plus/Pro, login oficial "Sign in with ChatGPT" para apps locais), **Claude Code** (sua assinatura Pro/Max, pelo Claude Code instalado no Mac), **OpenAI**, **Claude** (chave da API Anthropic), **OpenCode Zen**, **OpenCode Go**, **Command Code**, xAI, OpenRouter, Ollama, LM Studio ou URL própria. Listas de modelos vêm **ao vivo** do endpoint de cada provedor (ao abrir e a cada 6 h), com o formato certo de cada modelo: chat completions, Responses ou Messages (os do Claude Code vêm do próprio CLI). Chaves e login no **Keychain**. |
| **Ferramentas** | `run_command` (zsh), `read_file`, `write_file`, `list_directory`, `search_files` (Spotlight), `web_fetch`, `open`, `applescript` (Mail, Calendário, Notas…), `remember`, `recall`. |
| **Permissões** | Por Orb: **Perguntar antes** (ações que mudam algo, acessam a web ou guardam memória pedem aprovação), **Automático** ou **Só leitura**. “Sempre permitir” vale por ferramenta e pode ser revogado no painel do Orb. Cada grupo de ferramentas pode ser desligado (Terminal e arquivos, Web, Apps do Mac, Conectores). |
| **Conectores** | Servidores **MCP** locais (stdio: npx, uvx, docker) ou **remotos** (Streamable HTTP, com fallback SSE). Aba **Explorar** busca no [registro oficial do MCP](https://registry.modelcontextprotocol.io) e monta a configuração (você só preenche as chaves); aba **Instalados** com status ao vivo, ativar/desativar, editar e apagar. |
| **Skills** | Formato aberto **SKILL.md**. Aba **Explorar** busca no catálogo [Skills.sh](https://skills.sh) e lê o `SKILL.md` no GitHub de quem publicou, com prévia completa antes de instalar; aba **Instaladas** para ativar/desativar, editar e apagar. Use com `/atalho` (ex.: `/pdf`, `/resumir`). |
| **Rotinas** | O Orb faz uma tarefa sozinho todo dia, toda semana ou a cada X horas enquanto o app está aberto; resultado no card e notificação. |
| **Memória** | Cada Orb tem a sua, criada junto com ele: identidade, preferências, fatos, procedimentos e um resumo de cada conversa, em arquivos `.md` com busca (`remember`/`recall`). Entra no prompt um resumo de tamanho fixo; conversas antigas são compactadas. Ao apagar o Orb, você escolhe apagar ou guardar a memória. Veja [docs/MEMORIA.md](docs/MEMORIA.md). |
| **Mac** | Ícone na barra de menus com pergunta rápida, notificações quando termina ou precisa de você, abrir ao iniciar sessão, arrastar arquivos para o chat. |
| **Orbs** | 18 cores e dezenas de rostos, cabelos e acessórios; expressões por tipo de tarefa; olhos seguem o cursor. Veja [docs/ORBS.md](docs/ORBS.md). |

Atalhos: ⌘N novo Orb · ⇧⌘N nova conversa · ⌥⌘B painel do Orb · ⌥↑/⌥↓ trocar de Orb · ⌘1…⌘9 ir para um Orb · ↩ enviar.

## Arquitetura

```
Views (SwiftUI)  ──►  AppModel (@MainActor @Observable)
                        │  estado, conversas, rotinas, notificações
                        ├─ Store ............ JSON em ~/Library/Application Support/Orb + Keychain
                        ├─ AgentEngine ...... loop modelo ↔ ferramentas + portão de aprovação (actor)
                        │    ├─ OpenAIClient  streaming SSE, tool calls
                        │    ├─ ToolBox ..... ferramentas nativas (ProcessRunner com timeout e grupo de processos)
                        │    └─ MCPManager .. conectores MCP via stdio
                        └─ Orbs ............. avatar 3D em camadas, animado em Core Animation
```

- **Contratos** em [`Engine/EngineTypes.swift`](Sources/Orb/Engine/EngineTypes.swift): `LLMClient`, `AgentTool`,
  `ToolSpec`, `ChatMessage`, `JSONValue`. Uma ferramenta nova é um `struct` que implementa `AgentTool` e entra em `ToolBox.all`.
- **Um turno**: `AppModel.send` monta um `TurnRequest` (prompt do sistema, histórico, ferramentas permitidas) e consome os
  `TurnEvent`s do `AgentEngine` (texto, ferramenta iniciada/terminada, aprovação, mensagens para o histórico, erro).
- **Risco**: só ler arquivos, listar pastas, buscar no Spotlight e buscar na própria memória (`recall`) é `.safe`. Todo o resto é `.sensitive` e passa pelo
  portão: o que muda o Mac ou roda código, e também o que pode **mandar dados para fora** (`web_fetch`, `open`) ou ficar no
  prompt de todas as conversas (`remember`). Assim, um texto malicioso numa página não consegue ler um segredo e enviá-lo
  sem você aprovar. “Só leitura” vale mesmo para ferramentas marcadas como “Sempre permitir”.
- **Contexto** (`ContextBudget`, `ContextWindow`): o histórico enviado ao modelo cabe num orçamento de 90% da janela menos o
  prompt de sistema, as especificações das ferramentas e o espaço da resposta, com teto escolhido em “Memória da conversa”
  (40 mil tokens, 80 mil, ou até 60% da janela). Passou do orçamento, o começo vira resumo **em lote**, até a metade dele
  (cada mudança no começo do pedido reescreve o cache do provedor, então mexe-se pouco e de uma vez). O resumo é um
  registro estruturado (`ConversationLedger`), atualizado só com as mensagens que saem da janela: pedido original fixo,
  objetivo atual, pedidos e decisões, arquivos alterados e lidos, erros, pendências e última resposta, com teto por seção
  e sem resumos aninhados. Cada compactação vira um aviso com números e grava o trecho na memória antes de esquecer;
  “Compactar agora” (`AppModel.compactNow`, ou `/compactar [foco]` no compositor) faz o mesmo até 30% do orçamento. Saídas antigas de
  ferramentas, prefácios `<orb_context>` e raciocínio criptografado de trechos velhos são condensados na cópia enviada (as
  mensagens guardadas ficam inteiras); numa tarefa maior que a janela, as saídas mais novas ficam inteiras e os passos mais
  velhos viram uma linha cada. Uma tarefa que para no limite de passos deixa um registro de progresso para o “continua”.
  Saídas grandes demais vão para `saidas/<id do Orb>/` (apagadas após 14 dias ou acima de 200 MB por Orb). Uma recusa do
  provedor por tamanho ensina a janela real do modelo. Chamadas interrompidas recebem um resultado “não executado” para o
  histórico continuar válido.
- **Claude Code**: Orbs com modelo `claudeCode/…` não passam pelo `AgentEngine`; o `ClaudeCodeEngine` roda um
  `claude -p` por turno (veja abaixo).
- **Dados**: `state.json` (Orbs, rotinas, skills, conectores, provedor) e `conversations/<id do Orb>.json` (o que a tela mostra e
  o histórico do modelo). Campos novos devem ter valor padrão na decodificação (`value(_:default:)`), para arquivos antigos
  continuarem abrindo. A conversa é lida fora da thread principal (só a do Orb aberto na abertura; as outras ao trocar de Orb,
  e as paradas há alguns minutos voltam para o disco), e `conversations/<id>.meta.json` guarda, ao lado, o que o app precisa
  saber sem ler a conversa (quantos itens, quantos já foram para a memória); só vale enquanto o arquivo da conversa for
  exatamente o que ele descreve. Cada gravação refaz só os itens que mudaram, e o arquivo continua no formato de antes.
- **Memória**: `memoria/<id do Orb>/` (páginas `.md` + `index.sqlite`), e `memoria/_guardadas/` para a de Orbs apagados
  com “guardar a memória”. Ver [docs/MEMORIA.md](docs/MEMORIA.md).
- **Antes se chamava OpenBot**: ao abrir o app de verdade (pacote `app.orb.mac`; nunca nas execuções de
  desenvolvimento como `--render-icon`), `LegacyMigration` copia a pasta `~/Library/Application Support/OpenBot` e as
  preferências, a menos que o Orb já tenha dados tão novos quanto; uma cópia mais velha é posta de lado, não apagada.
  As chaves do Keychain (`app.openbot.mac` → `app.orb.mac`) passam uma a uma quando usadas (`Keychain.get`). Os
  originais ficam onde estavam. Como o identificador mudou, o macOS pede de novo as permissões (notificações, AppleScript)
  e “Abrir ao iniciar sessão” precisa ser ligado de novo (o item antigo do OpenBot pode ser removido em Ajustes do
  Sistema → Geral → Itens de Início).

## Claude Code

O provedor **Claude Code (sua assinatura)** usa o `claude` que você já instalou (achado pelo shell de login;
[como instalar](https://code.claude.com/docs/en/setup)). A [política da Anthropic](https://code.claude.com/docs/en/legal-and-compliance)
proíbe apps de terceiros de oferecer login do Claude.ai ou de guardar e repassar as credenciais dele, mas permite rodar o
Claude Code sem modificações com a sua própria assinatura. Por isso o app **nunca lê, copia nem guarda os tokens** do
Claude Code e nunca chama a Anthropic com eles:

- **Entrar / Sair** rodam `claude auth login --claudeai` / `claude auth logout`: o próprio Claude Code abre o navegador e
  guarda a sessão. O status vem de `claude auth status --json`. “Sair” desconecta o Claude Code no Mac inteiro (Terminal também).
- **Um turno** é `claude -p --input-format stream-json --output-format stream-json --include-partial-messages --verbose
  --permission-prompt-tool stdio --permission-mode … --append-system-prompt=… (--resume=<sessão> | --session-id=<nova>)` na
  pasta do Orb. O app manda `initialize` e a mensagem pelo stdin, mostra o texto em streaming e as ferramentas do Claude Code
  no chat, e responde os pedidos `can_use_tool` (protocolo do Agent SDK) com os cartões de aprovação. A sessão fica salva na
  conversa; “Nova conversa” começa outra.
- **Permissões**: Perguntar antes → modo `default` (o que precisa de aprovação vira cartão; “Sempre permitir” vale por
  ferramenta, ex.: `Bash`); Automático → `acceptEdits` e o app aprova o resto; Só leitura → `plan` e toda escrita é negada.
  Sem “Terminal e arquivos” saem `Bash`/`Edit`/`Write`…; sem “Web” saem `WebFetch`/`WebSearch`; com “Conectores” os
  conectores ativos vão por `--mcp-config` (arquivo temporário só seu), sem eles saem as ferramentas `mcp__*`.
- **Modelos**: a lista é a que o Claude Code oferece à sua conta (resposta do `initialize`, sem mandar prompt);
  “Padrão do Claude Code” não passa `--model`. Se o CLI não responder, ficam os apelidos documentados (opus, sonnet, haiku).
- **Memória**: o resumo da memória vai no `--append-system-prompt` de cada turno, e `remember`/`recall` chegam pelo MCP:
  o próprio binário do app roda como servidor (`Orb --memory-mcp <pasta>`, ver `MemoryMCPServer`) nos mesmos arquivos.
- **Contexto**: uma sessão nova (troca de modelo, pasta mudou, “Compactar agora”) recebe o resumo da conversa e as
  mensagens depois dele, inteiras e das mais novas para as mais velhas; o que não cabe entra no resumo. Quando o próprio
  Claude Code compacta a sessão (`compact_boundary`), a conversa mostra um aviso com os números que ele informa.

## Permissões do macOS

Os Ajustes têm a aba **Permissões do Mac**: Automação por app (Mail, Calendário, Notas, Lembretes, Finder, System Events,
Mensagens, Safari, Música), Acessibilidade, Gravação de Tela e Acesso Total ao Disco, cada uma com o estado atual,
**Pedir agora** (onde o macOS mostra o aviso) e **Abrir Ajustes** (leva ao painel certo). A aba atualiza ao voltar ao app e
nunca pede nada sozinha. O Acesso Total ao Disco é uma estimativa: o macOS não informa, então o Orb tenta abrir uma pasta
protegida (`~/Library/Mail` ou `~/Library/Safari/Bookmarks.plist`).

- Antes de rodar um AppleScript/JXA, o Orb olha quais apps o script usa e, para os que estão abertos e ainda sem resposta do
  macOS, mostra o aviso de Automação primeiro e espera você responder; só então o script começa a contar o tempo. App recusado
  falha na hora, sem rodar.
- Quando uma ferramenta falha por falta de permissão (`-1743`, `-25211`, "Operation not permitted" em pastas protegidas da
  Biblioteca, captura de tela sem imagem), o modelo recebe uma mensagem que diz o que falta e onde o usuário liga, em vez de
  tentar de novo, e a linha da ferramenta na conversa ganha o botão **Abrir Ajustes**.
- **Assinatura estável (opcional).** O build padrão é assinado de forma temporária (ad-hoc): a identidade é um hash do binário,
  então a cada compilação o macOS esquece Automação, Acessibilidade e Acesso Total ao Disco. Rode **uma vez**
  `scripts/make-signing-identity.sh`: ele cria o certificado autoassinado "Orb Local" no chaveiro de login (e pede sua senha
  para confiar nele). Dali em diante `scripts/bundle.sh` assina com ele sozinho; outra identidade pode ser escolhida com
  `ORB_SIGN_IDENTITY="Nome do certificado"`. Sem nenhuma das duas, o script mantém a assinatura temporária e avisa. Libere as
  permissões mais uma vez depois da primeira compilação assinada.

## Desenvolvimento

```bash
python3 scripts/fake-llm.py          # modelo falso em http://127.0.0.1:8765/v1 (pede um run_command)
open -n build/Orb.app --env ORB_DATA_DIR=/tmp/orb-teste   # dados isolados
open -n build/Orb.app --env ORB_SEND="Como está meu Mac?"   # envia um prompt ao abrir
./build/Orb.app/Contents/MacOS/Orb --render-orbs docs/orbs-activities.png
```

| Variável / argumento | Efeito |
|---|---|
| `ORB_DATA_DIR` | Pasta de dados alternativa (testes sem tocar nos seus Orbs) |
| `ORB_SEND` | Envia o texto ao Orb selecionado ao abrir (teste ponta a ponta) |
| `ORB_STATIC` | Desliga a animação dos Orbs |
| `ORB_MEMORY_IDLE=3` | Segundos de pausa até a conversa virar uma página de sessão na memória (padrão: 30 min) |
| `--render-orbs arquivo.png` / `--render-icon arquivo.png` | Gera a folha de Orbs / o ícone e sai |
| `--snapshot <tela> arquivo.png` | Desenha uma tela fora da vista (`app`, `chat`, `skills`, `connectors`, `inspector`, `new-orb`, `approvals`…) e sai; respeita `ORB_SEND` e `ORB_SNAPSHOT_HEIGHT` |
| `ORB_LIVE_TESTS=1 swift test --filter LiveCatalogTests` | Testa os catálogos e um conector remoto de verdade (precisa de internet) |
| `ORB_CLAUDE_PATH=/caminho/claude` | Usa outro executável como Claude Code (ex.: um `claude` falso para testes) |
| `ORB_LIVE_TESTS=1 swift test --filter ClaudeCodeLiveTests` | Roda o `claude` de verdade **deslogado** (pasta de config vazia): confere flags, handshake e lista de modelos, sem usar conta |

## Desempenho da interface

O que mantém a conversa leve enquanto uma resposta chega:
- **Texto em lotes**: os pedaços do modelo são juntados e publicados no máximo ~30 vezes por segundo
  (`AppModel.flushText`); rolagem para o fim e salvamento seguem esse ritmo (salva ~1×/s, não a cada pedaço).
- **Só o que mudou re-renderiza**: `TranscriptRow` é `Equatable`; a lista (`TranscriptList`) é separada da barra de
  ferramentas, do compositor e do painel; o estado dos Orbs (`activity`) não lê mais a conversa, então a barra lateral
  e o painel não redesenham a cada palavra.
- **Só o último parágrafo é refeito**: durante o streaming a mensagem vira dois textos (parágrafos prontos + o atual),
  com o mesmo resultado visual de um só; o Markdown e a medição do texto pronto ficam em cache.
- **Rolagem natural** (macOS 15+): se você rolar para cima para ler, a conversa para de puxar para o fim; volta a
  seguir quando você desce até o fim ou envia uma mensagem.
- **Transições discretas** (`animateChanges`, 0,25 s) para mensagens novas, ferramentas terminando, aprovações,
  status da barra lateral e resultados dos catálogos; com “Reduzir movimento” nada anima e o brilho vira texto fixo.

Para medir sem abrir janela (desenho fora da tela, CPU do processo), com um `state.json` em `ORB_DATA_DIR`
cujo provedor é `{"preset":"custom","baseURL":"http://127.0.0.1:8765/v1","defaultModel":"fake-model"}`:

```bash
python3 scripts/fake-llm.py 8765 --long    # resposta de ~2000 palavras, uma a cada 15 ms
ORB_DATA_DIR=/tmp/orb-perf ORB_SEND="Oi" ORB_SNAPSHOT_WAIT=40 \
  ./build/Orb.app/Contents/MacOS/Orb --snapshot app /tmp/perf.png &
sleep 5; ps -o %cpu= -p $!; sample $! 5        # durante o streaming
```

Referência (M4, conversa com 240 itens, resposta longa): CPU durante o streaming caiu de ~96% para ~20%;
parado, ~0% antes e depois.

## Próximos passos
1. Distribuição: assinatura Developer ID, Hardened Runtime, notarização e atualizações (Sparkle).
2. Atalho global para a pergunta rápida; chamar outro Orb com `@`.
3. Controle do Mac por Acessibilidade e captura de tela (helper separado, com onboarding de permissões).
4. Anexar imagens para modelos com visão; histórico de várias conversas por Orb.
