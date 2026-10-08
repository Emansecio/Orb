# Permissões

Como o Orb decide se uma ação roda, pergunta ou é recusada. Vale para os dois motores (o nativo, `AgentEngine`, e o do
Claude Code, `ClaudeCodeEngine`): os dois transformam a chamada numa `PermissionCall` e perguntam a mesma função,
`PermissionPolicy.evaluate`. Assim as regras não se afastam uma da outra.

Para o ponto de vista de quem usa o app, veja a seção "Permissões" do [README](../README.md).

## Visão geral

```
chamada de ferramenta (nativa, de conector ou do Claude Code)
        │  PermissionPolicy.call(for:…) / call(claudeCodeTool:…)
        ▼
PermissionCall   família · risco · perigo · comando · pastas · site · conector
        │  PermissionPolicy.evaluate(modo, chamada, liberações, concessões da tarefa, pasta)
        ▼
.allow            roda
.ask(motivo)      cartão de aprovação (ApprovalGate espera a resposta)
.deny(mensagem)   volta para o modelo como erro ("Not run: …")
```

O modo e as liberações são lidos **a cada chamada** (`PermissionSource`, que o `AppModel` entrega às duas engines), nunca
copiados no começo do turno. Trocar o modo ou remover uma liberação no meio de uma tarefa vale já para a próxima ação.

## Modos

`PermissionMode` (`Models.swift`). O rótulo é o que aparece no app. A ordem da tabela é a de todo seletor do app (o painel do
Orb, a folha "Novo Orb" e o botão do compositor leem `PermissionMode.allCases`): do mais cuidadoso ao menos, com "Sem pedir
permissão" por último. Cada modo tem uma descrição curta (`shortSummary`, no compositor) e uma completa (`summary`, no painel,
na folha "Novo Orb", na rotina e na confirmação), e a completa sempre começa pela curta.

| Modo | `rawValue` | O que `evaluate` faz |
|---|---|---|
| Perguntar antes | `ask` | Ler e pesquisar roda. O resto pergunta, a menos que uma liberação cubra a chamada, a tarefa já a tenha liberado ou seja uma escrita na pasta própria do Orb |
| Automático | `auto` | Roda tudo, **menos** o que é perigoso ou muda as instruções do Orb (esses perguntam) |
| Só leitura | `readOnly` | Recusa tudo o que não é seguro, **mesmo com liberação**. O modelo recebe `Not run: the user set you to read-only mode…` |
| Sem pedir permissão | `bypass` | Roda tudo, inclusive o perigoso. Ligar o modo exige uma confirmação ("Rodar sem pedir permissão?") |

Um modo desconhecido (arquivo de uma versão mais nova) volta para `ask`, o mais cuidadoso.

A ordem de `evaluate`:

1. risco `.safe`: **permite**, em qualquer modo (inclusive "Só leitura");
2. `bypass`: permite; `readOnly`: nega;
3. `ask` e `auto`: perigo declarado ou detectado: **pergunta** (`.dangerous(motivo)`);
4. risco `.instructs` (identidade e preferências da memória): **pergunta**;
5. `auto`: permite;
6. `ask`: permite se `isCovered(chamada, liberações + concessões da tarefa)` ou `isInsideOwnFolder`; senão pergunta
   (`.needsPermission`).

Uma rotina pode ter modo próprio (`Routine.permissionMode`: "Igual ao Orb", "Automático" ou "Só leitura"; "Sem pedir
permissão" não é oferecido). Enquanto ela roda, `AppModel.effectiveBot` troca o modo do Orb pelo da rotina, e mudar o modo
do Orb não mexe nos cartões dela. Como não há ninguém para responder, uma rotina em "Perguntar antes" espera pelo usuário;
o editor avisa e oferece "Usar Automático" / "Só leitura".

## Risco, família e perigo

Cada ferramenta declara três coisas (`AgentTool`):

- **Risco** (`ToolRisk`): `.safe` (lê ou consulta), `.sensitive` (muda algo, roda código ou pode mandar dados para fora) e
  `.instructs` (muda as instruções permanentes do Orb).
- **Família** (`PermissionFamily`): o tipo de coisa que a chamada faz, igual nos dois motores (`run_command` e o `Bash`
  do Claude Code são `shell`), para que uma liberação continue valendo se o Orb trocar de modelo.
- **Perigo** (`danger`): por que *esta* chamada é destrutiva, ou `nil`.

| Família | Ferramentas nativas | Claude Code |
|---|---|---|
| `shell` | `run_command` | `Bash` |
| `writeFiles` | `write_file`, `edit_file`, `trash` | `Write`, `Edit`, `MultiEdit`, `NotebookEdit` |
| `web` | `web_fetch` | `WebFetch`, `WebSearch` |
| `open` | `open` | |
| `appleScript` | `applescript` | |
| `macApps` | `shortcuts_run`, `clipboard_write`, `app_quit` | |
| `appInterface` | `ui_act` | |
| `connector` | ferramentas de conectores (`Servidor__ferramenta`) | `mcp__servidor__ferramenta` |
| `memory` | `remember` | `mcp__orb_memoria__remember` |
| `jobs` | `job_output`, `job_list`, `job_stop` | `BashOutput`, `KillShell`, `KillBash` (`TaskOutput` e `TaskStop` nos CLIs novos) |

Detalhes que costumam surpreender:

- **O que é `.safe`** (roda sem perguntar, até em "Só leitura"): `read_file`, `list_directory`, `search_files`, `grep`,
  `glob`, `recall`, `job_output`, `job_list`, `job_stop`, `shortcuts_list`, `clipboard_read`, `screenshot`, `apps_list`,
  `processes`, `browser_tab`, `notify`, `ui_read`. No Claude Code: `Read`, `LS`, `Glob`, `Grep`, `NotebookRead`,
  `BashOutput`, `TaskOutput`, `KillShell`, `KillBash` e `TaskStop`; qualquer outra ferramenta dele é `.sensitive`. Parar um processo é
  seguro nos dois motores pelo mesmo motivo: só alcança processos em segundo plano que o próprio Orb iniciou (e que já
  passaram pela aprovação do comando que os começou). `TaskStop` e `TaskOutput` são os nomes novos de `KillShell`/`KillBash` e `BashOutput` no CLI.
- **Dois casos em que o `.safe` da ferramenta não vale.** (1) **Segredos**: `read_file` e `grep` (e `Read`/`Grep`/`NotebookRead` do
  Claude Code) de uma chave ou credencial (`~/.ssh` menos `.pub`/`known_hosts`/`config`, `~/.aws` menos `config`, `~/.gnupg`,
  `~/.kube`, `~/.config/gcloud`, `~/Library/Keychains`, `~/.netrc`, `~/.npmrc`, `~/.config/gh/hosts.yml`,
  `~/.docker/config.json`, `.env` e `.env.*` menos `.example`/`.sample`, `*.pem`, `*.p12`, `*.key`, `id_rsa`…; ver
  `DangerousCommand.SensitiveFiles`) viram `.sensitive` com perigo: **perguntam** em "Perguntar antes" e "Automático", são
  **negadas** em "Só leitura" e rodam em "Sem pedir permissão". Uma busca em pasta (`grep` sem apontar o arquivo) não lê esses
  arquivos de passagem: deixa-os de fora e diz quantos. Comandos de shell também perguntam no "Automático" quando uma palavra
  deles aponta para um segredo em `~` (`cat ~/.ssh/id_rsa`, `tar … ~/.aws`), com exceção dos que só mostram nomes e tamanhos
  (`ls`, `stat`, `file`, `du`, `wc`, `find`). (2) **Comandos que só olham**: uma linha de `run_command` (ou `Bash`) feita só de
  `ls`, `cat`/`head`/`tail`, `grep` (sem `-r`), `wc`, `file`, `stat`, `du`, `df`, `which`, `echo`, `pwd`, `find` (sem
  `-exec`/`-delete`/`-fprint`), `sort`/`uniq` (sem arquivo de saída) e `git status`/`log`/`diff`/`show`/`blame`/`branch`
  (listar)/`remote -v`/`config --get` (a opção de leitura vem antes de qualquer chave)…, ligadas por `;`, `&&`, `||` ou `|`, sem redirecionamento, substituição, variável,
  `-c`/`--output`/`--ext-diff` do git nem segundo plano, é tratada como `.safe` (`ReadOnlyCommand`): não pede cartão em "Perguntar
  antes" e roda em "Só leitura". Qualquer coisa fora dessa lista curta segue a regra normal; um `cd` só conta se o alvo é
  claro (sem curingas), e as palavras relativas são conferidas em todas as pastas onde o shell pode estar. O classificador lê
  as palavras como texto, mas o zsh expande mais do que isso (qualificadores de glob como `*(e:'cmd':)`, `=(cmd)`, `=cmd`,
  chaves `{a,b}`): qualquer palavra com `(`, `)`, `{`, `}` ou começando com `=` volta ao cartão, mesmo entre aspas. Nenhum
  desses comandos acessa a rede (`git remote show <url>`, `fetch`, `ls-remote` ficam de fora), então não abrem canal de saída
  de dados; `ps` com `e`/`E`/`-e` (que mostra o ambiente dos processos) também pede cartão.
- `web_fetch`, `open` e `remember` são `.sensitive` de propósito: são o caminho de **saída** de dados (ou o que fica no
  prompt de toda conversa). Um texto malicioso numa página não consegue ler um segredo e mandá-lo sem você aprovar.
- `remember` com `tipo` `identidade` ou `preferencia` é `.instructs`. Com `fato` ou `procedimento` é `.sensitive`.
- Ferramentas de conectores (`MCPTool`) são `.sensitive`, **exceto** quando o servidor as anuncia como somente leitura
  (`readOnlyHint`), de mundo fechado (`openWorldHint` não verdadeiro) e não destrutivas. Uma ferramenta anunciada como
  destrutiva (`destructiveHint`) tem perigo: pergunta até no "Automático".
- `ui_act` tem perigo quando o rótulo do elemento (ou o item de menu) fala em excluir, enviar, comprar ou descartar, ou
  quando preenche um campo de senha. `app_quit` com `force` tem perigo ("encerra o app à força").
- A família `appInterface` é só do `ui_act`: uma liberação antiga de Atalhos ou da área de transferência (`macApps`) não passa a
  cobrir "clicar e digitar em qualquer app".

## Liberações ("Sempre permitir")

Uma liberação é uma `PermissionRule`: uma família com um **escopo** (`Bot.permissionRules`, salvo no `state.json`).

| Escopo | Cobre | Exemplo no painel |
|---|---|---|
| `any` | toda chamada da família | "Qualquer comando no Terminal" |
| `commandPrefix(palavras)` | comandos que começam com essas palavras | "Rodar comandos git", "Rodar comandos npm run" |
| `folder(caminho)` | gravar em arquivos **dentro** da pasta (absoluta, nunca `/`) | "Gravar em ~/Projetos/app" |
| `host(site)` | o site e seus subdomínios | "Acessar exemplo.com" |
| `search` | pesquisar na web (o `WebSearch` do Claude Code, que não tem site); nunca cobre ler uma página | "Pesquisar na web" |
| `connectorTool(chave)` | uma ferramenta de conector | "Usar create_issue (github)" |

Regras de validade (`PermissionRule.isValid`): o escopo só faz sentido para a sua família. Ao ler o arquivo, uma regra de
escopo inválido ou desconhecido é **descartada**, nunca ampliada.

`isCovered` por família:

- `shell`: **todos** os comandos da linha precisam começar com as palavras de alguma regra (`cd pasta &&` na frente é ignorado).
  Substituições `$( )`, crases, redirecionamento para arquivo, heredoc e aspas abertas fazem a linha não ser coberta
  (`ShellCommandLine.isPlain`).
- `writeFiles`: todo caminho da chamada precisa ficar dentro de uma das pastas liberadas. O caminho é o que de fato seria
  gravado (`PermissionPolicy.resolved`: `..` resolvido, link simbólico seguido até o fim, pastas existentes resolvidas, então
  `/tmp` e `/private/tmp` são iguais).
- `web`: o site da URL. `web_fetch` com `save_to` faz duas coisas, alcançar o site e gravar um arquivo, e **as duas** precisam
  estar cobertas: uma regra do site (ou "qualquer site") e uma regra de pasta (ou a pasta própria do Orb). Só "Acessar
  qualquer site" nunca libera gravar em qualquer lugar. O destino é julgado como em `write_file`
  (`DangerousCommand.reason(forWritingTo:)`): `~/Library/LaunchAgents`, `.zshrc`, `.ssh`… perguntam até no "Automático". O
  `WebSearch` do Claude Code não tem site: o cartão oferece "Pesquisar na web" (escopo `search`), não "qualquer site", que
  liberaria todo `WebFetch`. Sem "Terminal e arquivos" o `web_fetch` recusa `save_to` (`ToolContext.canSaveFiles`).
- `connector`: a chave da ferramenta (`PermissionPolicy.connectorKey`, igual para `GitHub__create_issue` e
  `mcp__github__create_issue`).
- `open`, `appleScript`, `macApps`, `appInterface`, `memory`, `jobs`: só o escopo `any`.

**Sugestões do cartão.** `PermissionPolicy.suggestions` oferece até 3 regras, da mais estreita para a mais larga:
`git push` antes de `git`; a pasta do projeto (a mais próxima com `.git`) antes da pasta do arquivo; o site. Nunca sugere
regra para interpretadores (`sh`, `bash`, `python3`, `node`, `env`, `xargs`, `sudo`, `find`, `awk`, `sed`, `ssh`, `open`…),
porque liberaria qualquer coisa. Chamadas perigosas e as que mudam instruções não têm sugestões. No Claude Code, as
sugestões que o próprio CLI manda (`permission_suggestions`) entram depois, filtradas pelas mesmas regras.

**Migração.** Orbs antigos tinham `allowedTools` (nomes de ferramenta dos dois motores). `Bot.init(from:)` converte cada
nome em regra de escopo `any` da família certa (`legacyRules`).

## Escrita na pasta própria

Em "Perguntar antes", gravar, editar ou mover para a Lixeira **dentro** da pasta própria do Orb (`~/Orbs/<Nome>`) não pede
cartão (`isInsideOwnFolder`). Condições:

- só a família `writeFiles` e risco `.sensitive`, com pelo menos um caminho, todos *estritamente* dentro da pasta (a pasta
  em si não conta);
- a pasta precisa ser "própria" (`PermissionPolicy.ownFolder`): não pode ser a pasta pessoal (o padrão de Orbs sem pasta),
  nem uma pasta que **contenha** a pessoal, nem `/`. Senão o Orb escreveria em qualquer lugar sem perguntar;
- vale só para escrita de arquivos. Comandos de terminal (`run_command`) continuam pedindo, e um caminho perigoso (abaixo)
  continua perguntando.

Nada confina o Orb à pasta: o prompt do sistema a chama de base, não de limite ("home base, not a boundary"). Ele pode ler e agir em qualquer lugar do Mac
dentro das regras acima.

## Comandos perigosos (v2)

`DangerousCommand` lê as **palavras de comando** de cada trecho do `run_command`, não qualquer texto que as mencione:
`grep -rn halt`, `echo 'reboot depois'` e `man sudo` passam. Pergunta no "Perguntar antes" e no "Automático", nunca entra
em grupo de aprovação, nunca ganha sugestão de "Sempre permitir" e, na notificação, o "Permitir" exige desbloquear o Mac.
No "Sem pedir permissão" não pergunta.

O analisador (`ShellCommandLine`) separa a linha em trechos (`;`, `&&`, `||`, `|`, `&`, quebras de linha), expande
`sh -c '…'`, `bash -lc`, `eval`, `$( )`, crases e `osascript -e`, até 4 níveis (mais que isso é perigoso por si:
"usa comandos aninhados demais para conferir"). Atravessa `env`, `nohup`, `command`, `exec`, `time`, `nice`, `caffeinate`,
`stdbuf` e `ionice`, sabendo quais opções de cada um levam valor (`env -i rm -rf x` ainda é `rm -rf`).

| Padrão reconhecido | Motivo mostrado |
|---|---|
| `sudo`, `doas` | roda como administrador |
| `rm -r`, `rm -f` (e `--recursive`/`--force`); `xargs rm`; `find -delete` | apaga arquivos de forma recursiva ou forçada |
| `rm`/`unlink` simples com algum alvo fora da pasta própria e fora de `/tmp`/`/var/folders` (ou sem pasta própria, ou alvo que não dá para saber, como `$VAR`) | apaga de forma definitiva (sem passar pela Lixeira) fora da pasta do Orb |
| `git push --force`/`-f`/`--mirror`/`+ref`; `reset --hard`; `clean -f`; `checkout .`/`-f`; `restore .`; `branch -D` | sobrescreve o histórico remoto / descarta mudanças |
| `curl`/`wget` em pipe para um shell; `sh <(curl …)` | baixa e executa um script da internet |
| `rsync --delete` com destino na pasta pessoal ou `/` | apaga no destino |
| `chmod`/`chown`/`chgrp -R` na raiz, na pasta pessoal ou em pastas do sistema | muda permissões em massa |
| `dd of=/dev/…`; `> /dev/disk…`; `mkfs`/`newfs`; `diskutil erase…`/`partitionDisk`/`zeroDisk`/`secureErase`/`reformat` | grava direto num disco / formata |
| `shutdown`, `reboot`, `halt`, `poweroff` | desliga ou reinicia o Mac |
| `killall`, `pkill` | encerra processos em massa |
| `launchctl unload`/`bootout`/`remove`; `csrutil`; `spctl --master-disable` | mexe em serviços ou na proteção do sistema |
| fork bomb | trava o sistema |

Exceção: `rm -rf node_modules .build dist DerivedData` **dentro da pasta própria** limpa saída de build e não é perigoso
(só caminhos literais, sem `*`, `$`, `~` ou crase).

**AppleScript/JXA** (`applescript`, `osascript`): o texto dentro de `do shell script "…"` / `doShellScript('…')` passa pelo
mesmo analisador (aspas duplas, simples e crases). O script é lido na linguagem dele, nunca por palpite: o parâmetro
`language` da ferramenta (padrão AppleScript) ou o `-l` do `osascript`. Em AppleScript só as aspas duplas são texto e os
comentários (`--`, `#`, `(* *)`) saem da análise, então um apóstrofo (`window 1's`, `it's`) não esconde código; em JXA as
aspas simples, os templates e os comentários (`//`, `/* */`) ficam de fora. Linguagem desconhecida: o script é lido das
duas formas e vale o primeiro motivo. O script de `osascript -e` pode começar com `--`. Shell montado sem literal (`do shell script c`, `("rm -rf " & "~")`) é julgado juntando todas as strings
do script ("monta um comando de shell que…"). Fora das aspas, são perigosos esvaziar a Lixeira, `delete every …`, apagar
vários itens de uma vez (`delete notes of folder …`, `delete (… whose …)`), `shut down`, `restart`, `log out`,
`with administrator privileges` e **enviar**: `send` em Mail, Mensagens, Outlook, WhatsApp, Telegram, Slack, Signal, Discord ou
Teams (ou `.send()` em JXA), e `keystroke return` / `key code 36` num desses apps. Um rascunho do Mail (`make new outgoing
message`) não é perigoso.

**`open`**: abrir script ou instalador (`.command`, `.sh`, `.pkg`, `.dmg`, `.scpt`, `.workflow`…), um `.app` de fora de
`/Applications`, `/System/Applications` e `~/Applications` (o caminho é normalizado: `/Applications/../x/Evil.app` não
vale), um arquivo executável sem extensão (abre no Terminal e roda) ou um link `shortcuts://run-shortcut…` é perigoso. Com
"Controlar apps do Mac" desligado, `open` recusa o link que roda um Atalho.

**Escritas**: `write_file`/`edit_file`/`trash` (e `Write`/`Edit`/`MultiEdit`/`NotebookEdit` do Claude Code, também no
"Automático") em arquivos de inicialização do shell
(`.zshrc`, `.zprofile`, `.bashrc`…), em `~/.ssh`, em `~/Library/LaunchAgents`, em `/Library/LaunchAgents`,
`/Library/LaunchDaemons` e `/etc` são perigosas.

O detector é conservador sobre o que reconhece e **nunca afirma que um comando é seguro**: o que ele não conhece cai na regra
normal do modo.

## Aprovações

### O cartão

Quando `evaluate` devolve `.ask`, o motor monta um `ApprovalRequest`, abre uma entrada no `ApprovalGate` (um actor
compartilhado pelas duas engines, seguro contra cancelamento), emite `TurnEvent.approval` e espera. O cartão aparece na
conversa e o Orb passa a `waiting` ("Esperando sua resposta").

| Controle | Efeito (`ApprovalDecision`) |
|---|---|
| Permitir (⌘↩) | `once`: só esta ação |
| Só nesta tarefa | `task`: concede a regra sugerida (a primeira) até o fim do turno |
| Sempre permitir… | `always`: grava a regra escolhida em `Bot.permissionRules` **antes** de responder, então a próxima chamada já a vê |
| Não permitir (esc) | `deny`: o modelo recebe `Not run: the user denied this action. Do not retry it…` |
| Dizer o que fazer em vez disso | `deny` com `note` (até 500 caracteres): `… The user said: <nota>`; o cartão respondido mostra "Você disse: …" |
| Revisar uma a uma (só em grupo) | `review`: cada ação da lista ganha o seu cartão |

Cartões respondidos viram uma linha que expande o pedido original. Um cartão já respondido não é respondido de novo (um
banner tocado tarde, depois de reabrir o app, não sobrescreve nada).

### Grupos

`ApprovalBatch` junta, num só cartão, as chamadas **de um mesmo passo** que perguntariam por `.needsPermission` (mínimo 2).
As perigosas e as que mudam instruções nunca entram: ganham cartão próprio. Título "N ações precisam da sua permissão",
botão "Permitir as N". "Só nesta tarefa" num grupo concede todas as regras que o cartão ofereceu. Depois de aprovado, cada
chamada é **avaliada de novo com o modo da hora**: só troca "perguntar" por "permitir", então "Só leitura" continua
bloqueando o que ainda não rodou. Chamadas só de leitura do mesmo passo rodam ao mesmo tempo; o resto roda em ordem.

### Teclado

⌘↩ permite e Esc nega o cartão **mais novo** do Orb aberto (`ApprovalKeyboard`). Esc não conta enquanto você edita texto
(campo com algo digitado, texto sendo composto ou o campo "Diga o que fazer em vez disso"): ali ele pertence ao campo.

### Fora da janela

- **Notificação.** Se o app está em segundo plano, ou outro Orb está aberto, e as notificações estão ligadas
  (Ajustes → Geral), o cartão vira um banner com "Permitir" e "Não permitir" (categoria `orb.approval`). Nos perigosos
  (`orb.approval.dangerous`) o "Permitir" exige desbloquear o Mac. Tocar no banner abre o Orb. O banner sai quando o cartão
  é respondido no app, por troca de modo ou ao parar o Orb. No início e no fim do app, banners velhos são removidos.
- **Barra de menus.** O painel lista os cartões abertos de todos os Orbs, com o que cada um faz (um grupo lista as 3
  primeiras ações). Permite e nega ali; um cartão perigoso só oferece "Abrir o app". O ícone ganha um ponto quando algum Orb espera.
- **Barra lateral.** A linha do Orb mostra "Precisa de você".

### Trocar o modo com cartões abertos

`ApprovalGate.applyModeChange`: "Sem pedir permissão" permite todos os cartões abertos; "Automático" permite os que não
são `alwaysAsks` (perigo ou mudança de instruções continuam esperando); "Só leitura" nega todos. A conversa marca o que foi
respondido sozinho. No Claude Code, o novo modo também vai ao processo (`set_permission_mode`).

## Ponte com o Claude Code

O `ClaudeCodeEngine` roda um `claude -p` por turno, em `stream-json`, com `--permission-prompt-tool stdio`: cada ferramenta
que o CLI não aprova sozinho chega como um pedido `can_use_tool`. O engine converte o pedido com
`PermissionPolicy.call(claudeCodeTool:input:workspace:)` e usa o mesmo `evaluate`, o mesmo `ApprovalGate` e o mesmo cartão.

| Modo do Orb | `--permission-mode` |
|---|---|
| Perguntar antes | `default` |
| Automático | `default` |
| Só leitura | `plan` |
| Sem pedir permissão | `bypassPermissions` |

"Perguntar antes" e "Automático" rodam o CLI do mesmo jeito (`default`): o CLI não aprova sozinho nada que considere
arriscado, e tudo isso chega ao Orb como `can_use_tool`. Quem decide é `PermissionPolicy.evaluate`, igual ao motor nativo:
no "Automático" permite, a não ser que seja perigoso (`~/.zshrc`, `~/.ssh`, LaunchAgents, `rm -rf`…) ou mude as instruções do
Orb. O modo `acceptEdits` não é usado de propósito: com ele o CLI aprovaria edições de arquivo sozinho e a checagem de
perigo do Orb (`DangerousCommand.reason(forWritingTo:)`) nunca as veria. `default` é aceito pelo CLI instalado (2.1.x; a
lista de `--help` mostra `manual`, que o próprio CLI converte em `default`).
- Capacidades desligadas viram `--disallowedTools` (sem "Terminal e arquivos": `Bash`, `Edit`, `Write`, `MultiEdit`,
  `NotebookEdit`, `Glob`, `Grep`, `LS`, `NotebookRead` e os controles de shell `BashOutput`, `TaskOutput`, `KillShell`,
  `KillBash`, `TaskStop`, como no motor nativo; só o `Read` fica, porque o CLI abre por ele as imagens anexadas; sem "Navegar na
  web": `WebFetch`, `WebSearch`) e, sem "Conectores", `--strict-mcp-config`. Fora do "Sem pedir permissão", entram também
  `Read(~/.ssh/**)`, `Read(~/.aws/**)` e as outras leituras de segredo (`ClaudeCodeTools.secretReads`): o CLI confia na pasta pessoal
  inteira (`--add-dir`) e nunca perguntaria ao Orb, então a leitura é recusada de vez (o motor nativo pergunta). Isso vale para
  a ferramenta `Read`; um `cat ~/.ssh/id_rsa` pelo `Bash` do CLI passa pela ponte do Orb, a não ser que o próprio CLI o aprove antes
  (ele aprova sozinho alguns comandos de leitura dentro das pastas de `--add-dir`): não foi possível conferir isso sem abrir uma
  sessão real, então é um limite conhecido.
- O CLI roda com o mesmo ambiente do `run_command` (`ShellEnvironment`: shell de login interativo, com o PATH do `.zshrc`,
  `JAVA_HOME` etc.) e com a pasta do `claude` na frente do PATH, menos as variáveis do provedor (`ANTHROPIC_*`, como
  `ANTHROPIC_API_KEY`), que trocariam em silêncio o login do claude.ai por cobrança da API; o Bash dele e os conectores MCP que ele inicia herdam isso.
  Os argumentos (persona e memória em português) chegam byte a byte (`LineProcess` usa `posix_spawn`).
- As ferramentas do próprio Orb (memória e Mac), que o Claude Code vê como `mcp__orb_memoria__…`, passam pela mesma política
  que as gêmeas nativas: risco, perigo (`app_quit` forçado, `do shell script`) e família. As seguras rodam em todos os modos.
- Uma negação aparece na linha da ferramenta em português ("Você negou esta ação." / "Bloqueado: o Orb está em modo Só
  leitura.").
- Limite: o que o **próprio CLI** aprova sozinho (`bypassPermissions`, ferramentas de leitura, e o que as regras de
  `permissions.allow` do Claude Code já liberam) não chega ao Orb (veja "Limites conhecidos").
  `ClaudeCodeEngine.modeChanged` avisa o CLI quando o modo muda.

## Permissões do macOS (TCC)

Separadas das anteriores: dizem o que o **macOS** deixa o app fazer. Ficam em Ajustes → Permissões do Mac
(`MacPermissionsView`, `MacPermissions.swift`).

| Permissão | Como o app descobre | Quem usa |
|---|---|---|
| Automação (por app: Mail, Calendário, Notas, Lembretes, Finder, System Events, Mensagens, Safari, Música) | `AEDeterminePermissionToAutomateTarget`, sem perguntar | `applescript`, `browser_tab` |
| Acessibilidade | `AXIsProcessTrusted` | `ui_read`, `ui_act` |
| Gravação de Tela | `CGPreflightScreenCaptureAccess` | `screenshot` |
| Acesso Total ao Disco | **estimativa**: tenta abrir `~/Library/Mail` ou `~/Library/Safari/Bookmarks.plist` | pastas protegidas |

- A aba nunca pede nada sozinha; cada linha tem um botão: "Pedir agora" mostra o aviso do macOS onde ele existe, "Abrir <app> e
  pedir" cobre a Automação de um app fechado e "Abrir Ajustes do Sistema" leva ao painel certo. Atualiza ao voltar ao app. Gravação de Tela e Acesso Total só valem depois de reabrir o Orb.
- **Pré-voo de Automação.** Antes de rodar AppleScript/JXA, `AutomationPreflight` lê os apps que o script endereça
  (`tell application "X"`, `application id "…"`, `Application("X")`) e, para os que estão abertos e ainda sem resposta do
  macOS, mostra o aviso e espera (até 120 s, fora do tempo do script). Um app conhecido que está fechado (o System Events
  quase sempre está) é aberto escondido, sem tomar o foco, para o aviso aparecer antes do script e não dentro dos 60 s dele.
  App recusado falha na hora, sem rodar.
  `application "X" is running` e `name/id/version of application "X"` não mandam eventos e são ignorados.
- **Tradução de erro.** `MacPermissionProblem.detect` reconhece a falta de permissão na saída de `osascript`,
  `screencapture` e do shell (`-1743`, `-25211`, `-1719` com "assistive access", "Operation not permitted" em pastas
  protegidas da Biblioteca, "could not create image from display") e devolve ao modelo uma mensagem em inglês que diz o que
  falta e onde ligar, e que **não** tentem de novo nem contornem. A linha da ferramenta na conversa ganha o botão
  "Permitir…" (`OpenPrivacySettingsButton`: pede ao macOS onde ele mostra o aviso, senão abre o painel certo); o botão também
  aparece quando uma captura de tela sai só com o papel de parede ou o `browser_tab` traz a recusa dentro do resultado.
  O nome do app recusado é lido também do texto em português do sistema ("eventos Apple para Mail") e, se nada o nomeia e o
  script fala com um só app, esse é o app. No painel do Orb (Geral → "O que o Orb pode usar"), a chave "Controlar apps do Mac"
  ligada mostra o atalho **Permissões do Mac**.
- `ui_read` e `ui_act` só são oferecidos ao modelo com a Acessibilidade concedida (o prompt avisa quando ficam de fora). O
  servidor de ferramentas do Claude Code recebe a resposta do app (`--accessibility` / `--no-accessibility`) em vez de
  perguntar ao macOS de dentro de um processo filho.
- As permissões valem para a identidade de assinatura do app. Com assinatura ad-hoc (o padrão de `scripts/bundle.sh`), cada
  compilação é "outro app" para o macOS; `scripts/make-signing-identity.sh` cria o certificado local "Orb Local" que mantém
  a identidade (veja o README).

## Limites conhecidos

O que o modelo de permissões **não** faz, para ninguém contar com isso:

- **Ler quase nunca pergunta.** `read_file`, `grep`, `glob`, `list_directory`, `clipboard_read`, `screenshot` e `ui_read` rodam em
  qualquer modo, em qualquer pasta que o macOS deixe o app ler, **exceto** os segredos listados acima (chaves, `.env`, credenciais) (a captura de tela, a leitura da interface e o Acesso Total
  ao Disco dependem das permissões do macOS). `ui_read` nunca devolve o conteúdo de campos de senha. O que protege contra
  vazamento é que o **envio** (`web_fetch`, `open`, `run_command`, AppleScript, conectores) pergunta em "Perguntar antes".
- **"Automático" e "Sem pedir permissão" não olham para onde os dados vão.** `curl -d @arquivo` ou um `web_fetch` roda sem
  cartão: só a lista de comandos perigosos acima pergunta. Ela fala de destruir e, em AppleScript e na tecla Return de apps de
  mensagem, também de enviar; um Atalho (`shortcuts_run`) ou um clique em "Enviar" fora de um app de mensagem não são vistos.
- **Não é uma jaula.** A pasta própria só dá conforto de escrita; o Orb lê e age em qualquer lugar. Ir além disso exigiria
  um sandbox, que o app não tem.
- **O detector olha o texto do comando.** Um script gravado em arquivo e executado (`bash script.sh`, `python3 x.py`) não é
  lido; só `sh -c '…'`, `eval`, `$( )`, crases e `osascript -e` são abertos (até 4 níveis).
- **Claude Code.** No "Automático" o CLI roda em `default`, então todo pedido de ferramenta que ele não considera de
  leitura passa pelo Orb, inclusive edições de arquivo. Ainda não passa pelo Orb: o que o CLI aprova pelo `bypassPermissions`
  (só no "Sem pedir permissão"), as ferramentas de leitura dele e o que as regras `permissions.allow` das configurações do
  próprio Claude Code (`~/.claude/settings.json`, `.claude/settings.json` da pasta) já liberam. A checagem de perigo do Orb
  só vê o que chega como `can_use_tool`.

## Instruções da pasta

`ORB.md`, senão `AGENTS.md`, senão `CLAUDE.md` na pasta do Orb é **material de referência**, não ordem: qualquer pasta
baixada pode trazer um. "Confiar nas instruções desta pasta" (painel, aba "Pasta e acessos") guarda o SHA-256 completo do
arquivo em `Bot.trustedInstructionsHash`; se o arquivo mudar, volta a ser referência até confiar de novo. Para um Orb no
Claude Code o `CLAUDE.md` é lido pelo próprio CLI e o interruptor não aparece. O texto da pasta e da memória não consegue
fechar as tags `<orb_context>`/`<workspace_snapshot>` (`Fence.neutralize`).

## Onde está no código

| Arquivo | Papel |
|---|---|
| `Models.swift` | `PermissionMode`, `Capability`, `ApprovalRequest`/`ApprovalDecision`, `Bot.permissionRules` |
| `Engine/PermissionPolicy.swift` | famílias, regras e escopos, `evaluate`, `isCovered`, pasta própria, sugestões, migração |
| `Engine/DangerousCommand.swift`, `Engine/ShellCommandLine.swift` | perigo em shell, AppleScript e escritas; segredos que não se leem sem perguntar (`SensitiveFiles`); análise da linha de comando |
| `Engine/ReadOnlyCommand.swift` | quais linhas de shell só olham (sem cartão no "Perguntar antes", rodam no "Só leitura") |
| `Engine/ApprovalGate.swift`, `Engine/ApprovalBatch.swift` | cartões abertos, resposta, grupos, troca de modo |
| `Engine/AgentEngine.swift` | `execute` / `confirmBatch`: onde o motor nativo pergunta |
| `Engine/ClaudeCodeEngine.swift`, `Engine/ClaudeCodeProtocol.swift` | `can_use_tool`, `ClaudeCodePolicy`, modos do CLI |
| `AppModel.swift`, `AppModel+Approvals.swift` | `permissionState`, `decide`, `permissionModeChanged`, banners |
| `ApprovalNotifications.swift`, `Views/ApprovalKeyboard.swift` | notificações com ações, ⌘↩ / Esc |
| `Views/TranscriptViews.swift` (`ApprovalCard`), `Views/QuickAskView.swift` | os cartões |
| `Views/ComposerChips.swift`, `Views/BotInspector.swift`, `Views/PermissionConfirmation.swift` | seletor de modo, "Liberações", confirmação do bypass |
| `MacPermissions.swift`, `Views/MacPermissionsView.swift` | TCC, pré-voo, tradução de erros |
| Testes | `PermissionPolicyTests`, `ReadOnlyCommandTests`, `PermissionModelTests`, `DangerousCommandTests`, `ApprovalNotificationTests`, `MacPermissionsTests`, `AgentEngineTests`, `ClaudeCodeEngineTests` |
