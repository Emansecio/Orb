# Permissões

Como o Orb decide se uma ação roda, pergunta ou é recusada. Vale para todo Orb, seja qual for o modelo, o do Claude Code
incluído (o `claude` é só o cano até o modelo, veja "Claude Code"): o motor (`AgentEngine`) transforma a chamada numa
`PermissionCall` e pergunta a `PermissionPolicy.evaluate` antes de rodar qualquer ferramenta.

Para o ponto de vista de quem usa o app, veja a seção "Permissões" do [manual](MANUAL.md#permissões).

## Visão geral

```
chamada de ferramenta (própria do Orb ou de conector)
        │  PermissionPolicy.call(for:…)
        ▼
PermissionCall   família · risco · perigo · comando · pastas · site · conector
        │  PermissionPolicy.evaluate(modo, chamada, liberações, concessões da tarefa, pasta)
        ▼
.allow            roda
.ask(motivo)      cartão de aprovação (ApprovalGate espera a resposta)
.deny(mensagem)   volta para o modelo como erro ("Not run: …")
```

O modo e as liberações são lidos **a cada chamada** (`PermissionSource`, que o `AppModel` entrega ao motor), nunca
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
o editor avisa e oferece "Usar Automático" / "Só leitura". O cartão fica na conversa da rotina (Rotinas → a rotina → conversa,
com "Ver pedido" no chat do Orb): é de lá que se responde, e os banners e a barra de menus também o enxergam
(`AppModel.pendingApprovals(of:)` lê a conversa em que o turno roda, não o chat estacionado).

## Risco, família e perigo

Cada ferramenta declara três coisas (`AgentTool`):

- **Risco** (`ToolRisk`): `.safe` (lê ou consulta), `.sensitive` (muda algo, roda código ou pode mandar dados para fora) e
  `.instructs` (muda as instruções permanentes do Orb).
- **Família** (`PermissionFamily`): o tipo de coisa que a chamada faz, para que uma liberação continue valendo se o Orb
  trocar de modelo. Liberações salvas no tempo em que o Claude Code usava as ferramentas dele (`Bash`, `Write`, `mcp__orb_memoria__…`,
  `mcp__servidor__ferramenta`) ainda são entendidas e viram a família certa (`legacyRule`).
- **Perigo** (`danger`): por que *esta* chamada é destrutiva, ou `nil`.

| Família | Ferramentas |
|---|---|
| `shell` | `run_command` |
| `writeFiles` | `write_file`, `edit_file`, `trash` |
| `web` | `web_fetch`, `web_search`, `browse_open`, `browse_tabs` (nova aba) |
| `browserPage` | `browse_click`, `browse_fill`, `browse_select`, `browse_press`, `browse_show` |
| `open` | `open` |
| `appleScript` | `applescript` |
| `macApps` | `shortcuts_run`, `clipboard_write`, `app_quit` |
| `appInterface` | `ui_read`, `ui_act` |
| `connector` | ferramentas de conectores (`Servidor__ferramenta`) |
| `memory` | `remember`, `recall` |
| `schedule` | `schedule` (criar, pausar, retomar, apagar) |
| `jobs` | `job_output` (sem `id`, lista todos), `job_stop` |

Detalhes que costumam surpreender:

- **O que é `.safe`** (roda sem perguntar, até em "Só leitura"): `read_file`, `list_directory`, `search_files`, `grep`,
  `glob`, `recall`, `job_output`, `job_stop`, `shortcuts_list`, `clipboard_read`, `screenshot`, `apps_list`,
  `browser_tab`, `notify`, `ui_read`. Parar um processo é seguro pelo mesmo motivo de ler a saída dele: só alcança
  processos em segundo plano que o próprio Orb iniciou (e que já passaram pela aprovação do comando que os começou).
- **Dois casos em que o `.safe` da ferramenta não vale.** (1) **Segredos**: `read_file` e `grep` de uma chave ou credencial (`~/.ssh` menos `.pub`/`known_hosts`/`config`, `~/.aws` menos `config`, `~/.gnupg`,
  `~/.kube`, `~/.config/gcloud`, `~/Library/Keychains`, `~/.netrc`, `~/.npmrc`, `~/.config/gh/hosts.yml`,
  `~/.docker/config.json`, `.env` e `.env.*` menos `.example`/`.sample`, `*.pem`, `*.p12`, `*.key`, `id_rsa`…; ver
  `DangerousCommand.SensitiveFiles`) viram `.sensitive` com perigo: **perguntam** em "Perguntar antes" e "Automático", são
  **negadas** em "Só leitura" e rodam em "Sem pedir permissão". Uma busca em pasta (`grep` sem apontar o arquivo) não lê esses
  arquivos de passagem: deixa-os de fora e diz quantos. Comandos de shell também perguntam no "Automático" quando uma palavra
  deles aponta para um segredo em `~` (`cat ~/.ssh/id_rsa`, `tar … ~/.aws`), com exceção dos que só mostram nomes e tamanhos
  (`ls`, `stat`, `file`, `du`, `wc`, `find`). (2) **Comandos que só olham**: uma linha de `run_command` feita só de
  `ls`, `cat`/`head`/`tail`, `grep` (sem `-r`), `wc`, `file`, `stat`, `du`, `df`, `which`, `echo`, `printf` (sem `-v`), `pwd`,
  `command -v`/`type`, `diff`/`cmp`/`shasum`/`md5` (sem `-r`, `-l`, `-c`), `find` (sem
  `-exec`/`-delete`/`-fprint`), `sort`/`uniq` (sem arquivo de saída) e `git status`/`log`/`diff`/`show`/`blame`/`branch`
  (listar)/`remote -v`/`config --get` (a opção de leitura vem antes de qualquer chave)…, ligadas por `;`, `&&`, `||` ou `|`, sem redirecionamento, substituição, variável,
  `-c`/`--output`/`--ext-diff` do git nem segundo plano, é tratada como `.safe` (`ReadOnlyCommand`): não pede cartão em "Perguntar
  antes" e roda em "Só leitura". Qualquer coisa fora dessa lista curta segue a regra normal; um `cd` só conta se o alvo é
  claro (sem curingas), e as palavras relativas são conferidas em todas as pastas onde o shell pode estar. O classificador lê
  as palavras como texto, mas o zsh expande mais do que isso (qualificadores de glob como `*(e:'cmd':)`, `=(cmd)`, `=cmd`,
  chaves `{a,b}`): qualquer palavra com `(`, `)`, `{`, `}` ou começando com `=` volta ao cartão, mesmo entre aspas. Nenhum
  desses comandos acessa a rede (`git remote show <url>`, `fetch`, `ls-remote` ficam de fora), então não abrem canal de saída
  de dados; `ps` com `e`/`E`/`-e` (que mostra o ambiente dos processos) também pede cartão. As opções que escrevem ou rodam
  outro programa são conferidas por **abreviação** e por **grupo**, porque o `getopt_long` do macOS e o `parse-options` do git aceitam
  qualquer prefixo de uma opção longa e letras coladas: `sort --out=x`, `grep --recur`, `git grep --no-ind` e `git grep --open=cmd`
  valem como a opção inteira, e `git grep -iOcmd` como `-O` (`ReadOnlyCommand.abbreviates`). `uniq` conta o `-` (entrada) como operando:
  `uniq - saida` grava. As opções são procuradas em **todas** as palavras, também depois de um `--`, porque ele pode ser o valor da
  opção anterior (`sort -T -- -o x`, `grep -e -- -r x .`, `git grep -e -- -iO'cmd'`). O `diff` com um operando que é pasta (ou pode
  ser: `~`, `.`, curinga, `~usuario`) ou com `--from-file` volta ao cartão, porque compara com o arquivo de mesmo nome dentro da
  pasta (`diff .npmrc ~` mostraria `~/.npmrc`). Na dúvida a linha só vai ao cartão.
- **O navegador do Orb** (`browse_*`, `web_search`; veja o [manual](MANUAL.md#navegador), "Navegador"). `browse_open`, a aba nova de `browse_tabs` e
  `web_search` são `.sensitive` na família `web`, como `web_fetch`: cartão no Perguntar antes, "Sempre permitir" por site (a pesquisa
  tem a regra `search`, "Pesquisar na web", que nunca cobre ler uma página). `browse_click`, `browse_fill`, `browse_select`,
  `browse_press` e `browse_show` mudam coisas dentro de páginas em que o Orb pode estar logado: são `.sensitive` na família
  `browserPage` ("Clicar e preencher páginas no navegador do Orb"), que **nenhuma regra de site cobre**, nem o contrário. O cartão
  diz em quê clica pelo nome que o último `browse_snapshot` deu ao elemento. Olhar a página que já está aberta (`browse_snapshot`,
  `browse_read`, `browse_screenshot`, `browse_scroll`, `browse_back`, `browse_tabs` sem criar aba) é `.safe`, **mas "Só leitura" recusa**
  (`PermissionCall.readsLivePage`, `AgentTool.readsLivePage`): é a web. `browse_close` só libera o navegador e roda em todo modo.
  `browse_press` aperta só teclas **com nome** (Enter, Tab, Shift+Tab, Escape, setas, PageUp/PageDown, Home, End, Backspace, Delete, Space): nada que digite um caractere, nem Control/Meta+V, que colaria o que está na área de transferência num campo de senha; e recusa qualquer tecla enquanto `document.activeElement` é um campo de senha ou de cartão (tipo, `autocomplete` ou nome). `browse_fill` **nunca digita em campo de senha ou de cartão**, em modo nenhum (nem em "Sem pedir permissão"): o campo é julgado
  pelo nome que o snapshot deu a ele (senha, password, contraseña, passwort, cartão, CVV…) e, quando o navegador sabe dizer, pelo
  `type`/`autocomplete` dele; a ferramenta responde que a pessoa deve digitar e que o Orb chame `browse_show`.
  Depois de permitido, `browse_show` abre a janela e põe um segundo cartão, **Pronto / Cancelar** (`ApprovalRequest.isHandoff`): não é permissão, é a vez
  da pessoa. Ele espera como qualquer cartão (Parar o cancela), **nenhuma troca de modo o responde** (nem "Sem pedir permissão") e não oferece "Sempre permitir".
  A dica `readOnlyHint` que o servidor MCP anuncia (`AgentTool.announcedReadOnly`) é a mesma lição do `schedule`: `risk` sem argumentos não basta. Ferramenta que olha uma página viva (`readsLivePage`: `browse_snapshot`, `browse_read`, `browse_screenshot`, `browse_scroll`, `browse_back`) **não** é anunciada como somente leitura, porque "Só leitura" a recusa, e `browse_tabs` também não (sem argumentos lista, mas `new` com `url` navega e `select`/`close` mexem no navegador); só `browse_close` é anunciada como segura.
- `web_fetch`, `open` e `remember` são `.sensitive` de propósito: são o caminho de **saída** de dados (ou o que fica no
  prompt de toda conversa). Um texto malicioso numa página não consegue ler um segredo e mandá-lo sem você aprovar.
- `remember` com `tipo` `identidade` ou `preferencia` é `.instructs`. Com `fato` ou `procedimento` é `.sensitive`. Com `skill` é
  `.safe` em todos os modos, "Só leitura" incluída: só grava uma **proposta** (`_propostas/`), que não muda nada até você ler o
  texto inteiro no editor de skills e salvar (a aprovação é essa, não um cartão no meio do turno). A revisão em segundo plano
  só roda com `recall` e `remember` `tipo` `skill` (`TurnRequest.onlyTools`): as outras ferramentas não rodam, e um `remember` de outro
  tipo, que num Orb em "Pedir permissão" abriria um cartão que ninguém vê, é recusado na hora ("This review only proposes
  skills"), sem cartão. Não roda em Orb "Só leitura".
- `schedule` tem família própria: uma tarefa agendada é uma mudança que **fica** e que roda sozinha depois, então criar, pausar,
  retomar e apagar são `.sensitive` (cartão em "Perguntar antes", `Sempre permitir` oferece "Gerenciar as tarefas agendadas";
  roda em "Automático" e "Sem pedir permissão"; **negado em "Só leitura"**). `list` é `.safe` e roda em todos os modos, e uma
  chamada que nomeia a ação mas não passa na conferência (intervalo de 5 minutos, `when` faltando) também é `.safe`: não muda nada,
  então vai direto ao erro, sem cartão para aprovar só para ouvir um não (sem `action` nenhuma, que é a ferramenta como um todo,
  vale `.sensitive`, para o `readOnlyHint` anunciado ao servidor MCP sair falso). O cartão mostra o nome, quando roda e o que será pedido, numa linha. A tarefa criada **nunca** é mais permissiva que o Orb: nasce com
  `permissionMode` nil (usa o modo do Orb na hora de rodar, como uma rotina feita à mão sem "Avançado"). Um Orb só enxerga e
  muda as rotinas dele, tem no máximo 20 (`AppModel.scheduledTaskLimit`) e uma execução de rotina não cria outras (um e-mail ou
  uma página lidos numa rotina não conseguem plantar tarefas que sobrevivem a ela; pausar, retomar e apagar continuam valendo).
  O "só as dele" e o "rotina não cria tarefas" valem para as chamadas da ferramenta, não contra um shell liberado (um Orb com
  shell liberado, no Automático, já faz tudo o que uma rotina faria).
- O Orb não vê as ferramentas dos conectores: usa `connector_tools` e `connector_call` (`.safe`, só leem o catálogo e
  passam o pedido). O motor troca cada `connector_call` pelo `MCPTool` de verdade (`GitHub__create_issue`) **antes** da
  política: o cartão ("Usando GitHub"), as anotações, o perigo e as regras "Sempre permitir" (`connectorKey`
  `github__create_issue`, as mesmas de antes) valem como se o modelo tivesse chamado a ferramenta direto. O histórico guarda a
  chamada original. Se a chamada não resolve (conector ou ferramenta que não existe), `connector_call` mesmo devolve o erro
  e nunca executa nada.
- O login de um conector (OAuth) não muda a política: `connector_call` continua resolvendo para a mesma `connectorKey`, e o token
  nunca passa pelo Orb nem pelo modelo. Se o servidor responde 401 ou 403 `insufficient_scope`, a ferramenta devolve uma frase
  dizendo à pessoa para clicar em **Entrar de novo** ou **Permitir mais** em Conectores: o modelo não abre o navegador nem repete a
  chamada em laço, e é a pessoa quem concede a permissão a mais (cada clique abre o login uma vez, com os escopos já dados mais os pedidos).
  O navegador abre sempre por clique dela. O app recusa um servidor de login sem PKCE `S256` ou sem HTTPS, e um conector remoto sem HTTPS (fora do loopback) não faz login nem recebe o token, e uma resposta do login
  com `iss` ou `state` errados não chega a trocar o código. O token fica só no Keychain (conta `mcp.<id>.oauth`), vai em
  `Authorization` (nunca na URL, no `state.json` nem em mensagens de erro). Apagar o conector ou "Sair da conta" apaga o login do Keychain e o revoga no serviço (melhor esforço, se o servidor anuncia `revocation_endpoint`); um login que ainda estava no navegador nessa hora é cancelado e não grava nada.
- Ferramentas de conectores (`MCPTool`) são `.sensitive`, **exceto** quando o servidor as anuncia como somente leitura
  (`readOnlyHint`), de mundo fechado (`openWorldHint` não verdadeiro) e não destrutivas. Uma ferramenta anunciada como
  destrutiva (`destructiveHint`) tem perigo: pergunta até no "Automático". O mesmo vale para a ferramenta que **envia, publica ou
  apaga** pelo nome, mesmo sem `destructiveHint` (`PermissionPolicy.connectorDanger`): uma das
  palavras `send`, `post`, `reply`, `forward`, `share`, `publish`, `comment`, `push`, `merge`, `submit`, `upload`, `notify`, `delete`,
  `remove`, `trash`, `archive`, `schedule`, `invite`, `transfer` (também `destroy`, `purge`, e `create` junto de `pull`:
  `create_pull_request`) no nome, separado por `_`, `-`, `.` ou maiúsculas (`slack_send_message`, `deleteEvent`);
  palavras parecidas (`sent`, `replies`, `schedules`) não contam. `readOnlyHint` verdadeiro vence o nome; `destructiveHint`
  verdadeiro vence tudo. Perigo nunca é coberto por "Sempre permitir". As anotações vêm do servidor, guardadas no catálogo do conector
  (`ConnectorCatalog`), que é o que o motor lê ao trocar o `connector_call` pela ferramenta de verdade.
- `ui_act` tem perigo quando o rótulo do elemento (ou o item de menu) fala em excluir, enviar, comprar ou descartar, ou
  quando preenche um campo de senha. `app_quit` com `force` tem perigo ("encerra o app à força").
- **Perigos novos do `ui_act` em segundo plano** (desenho em [USO-DO-COMPUTADOR.md](USO-DO-COMPUTADOR.md)): o perigo é recalculado na
  execução, depois de resolver o elemento real, com o rótulo vivo (o que o cartão mostrou pode estar defasado): se agora é
  perigoso e o cartão não avisou, a ação é recusada e o modelo é orientado a repetir por `id` ou `pick_menu`. Vale também para
  Return/Enter em app de mensagem (envia), `cmd+delete` no Finder (apaga), `click` por coordenada, `key` e a primeira etapa
  perigosa de `steps`. `type`, `key` e `set_value` em campo de senha têm perigo (o valor nunca é lido de volta). **Assumir a
  tela** (`takeover`) tem perigo sempre: pergunta em "Perguntar antes" e "Automático" (o cartão lista as etapas), é recusado em "Só
  leitura" e roda em "Sem pedir permissão" com o aviso na tela. Um takeover é um por vez (`TakeoverLock.shared`: o segundo Orb a pedir recebe "ocupado" em vez de esperar), dura no máximo 10 s,
  se interrompe se o mouse real se mexer e sempre devolve o app da frente, a janela e o cursor.
- A família `appInterface` (`ui_read`, `ui_act`) só pergunta pelo `ui_act`: uma liberação antiga de Atalhos ou da área de transferência (`macApps`) não passa a
  cobrir "clicar e preencher campos em qualquer app".

## Liberações ("Sempre permitir")

Uma liberação é uma `PermissionRule`: uma família com um **escopo** (`Bot.permissionRules`, salvo no `state.json`).

| Escopo | Cobre | Exemplo no painel |
|---|---|---|
| `any` | toda chamada da família | "Qualquer comando no Terminal" |
| `commandPrefix(palavras)` | comandos que começam com essas palavras | "Rodar comandos git", "Rodar comandos npm run" |
| `folder(caminho)` | gravar em arquivos **dentro** da pasta (absoluta, nunca `/`) | "Gravar em ~/Projetos/app" |
| `host(site)` | o site e seus subdomínios | "Acessar exemplo.com" |
| `search` | pesquisar na web (`web_search`, que não tem site); nunca cobre ler uma página | "Pesquisar na web" |
| `connectorTool(chave)` | uma ferramenta de conector | "Usar create_issue (github)" |

Regras de validade (`PermissionRule.isValid`): o escopo só faz sentido para a sua família. Ao ler o arquivo, uma regra de
escopo inválido ou desconhecido é **descartada**, nunca ampliada.

As liberações, como o modo de permissão, ficam no Orb: apagar o Orb ou "Redefinir o Orb" (Ajustes → Geral) as apaga com ele. A
memória que se guarda (e o `perfil.json` dela) não leva liberações nem modo, então um Orb que começa de uma memória guardada
nasce sem nenhuma e no modo que você escolher na folha.

O mesmo vale para **Importar de outro assistente**: o importador só produz nome, papel, identidade, preferências, fatos,
procedimentos e skills. Campos como `permissionMode`, `capabilities`, `permissionRules`, `workingDirectory`, `model`,
`trustedInstructionsHash`, conectores, rotinas ou `extensions` de um arquivo são ignorados, e o Orb nasce no modo e com as
capacidades que você escolheu na folha. Uma identidade ou preferência maliciosa não libera nenhuma ferramenta (isso é imposto
por `PermissionPolicy`); por isso a prévia desmarca o que parece dar ordens, e as skills importadas só rodam quando você digita
`/comando`, limitadas ao Orb novo.

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
  `web_search` não tem site: o cartão oferece "Pesquisar na web" (escopo `search`), não "qualquer site", que
  liberaria todo `web_fetch`. Sem "Terminal e arquivos" o `web_fetch` recusa `save_to` (`ToolContext.canSaveFiles`).
- `connector`: a chave da ferramenta (`PermissionPolicy.connectorKey`, `GitHub__create_issue` vira
  `github__create_issue`; o formato antigo `mcp__github__create_issue` das liberações salvas pelo Claude Code vira o mesmo).
- `open`, `appleScript`, `macApps`, `appInterface`, `memory`, `jobs`, `schedule`: só o escopo `any`.

**Sugestões do cartão.** `PermissionPolicy.suggestions` oferece até 3 regras, da mais estreita para a mais larga:
`git push` antes de `git`; a pasta do projeto (a mais próxima com `.git`) antes da pasta do arquivo; o site. Nunca sugere
regra para interpretadores e embrulhos (`sh`, `bash`, `python3`, `node`, `xargs`, `sudo`, `find`, `awk`, `sed`, `ssh`, `open` e os
mesmos embrulhos que o detector de perigo atravessa: `env`, `nice`, `caffeinate`, `arch`, `xcrun`, `timeout`…; a lista é
`DangerousCommand.wrappers`), porque liberaria qualquer coisa. Uma regra de uma palavra só para um embrulho, já salva por uma versão
antiga, deixa de valer: o cartão volta a aparecer. Chamadas perigosas e as que mudam instruções não têm sugestões.

**Migração.** Orbs antigos tinham `allowedTools` (nomes de ferramenta, do motor próprio e do Claude Code de então). `Bot.init(from:)` converte cada
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
"usa comandos aninhados demais para conferir"). Atravessa `env` (inclusive `env -S 'rm -rf x'`, cujo valor é separado como o shell faz, com aspas: `env -S 'sh -c "rm -rf x"'`), `nohup`, `command`, `exec`, `time`, `nice`, `caffeinate`,
`stdbuf`, `ionice`, `noglob`, `nocorrect`, `arch`, `xcrun`, `timeout`/`gtimeout` e o `-` do zsh, sabendo quais opções de cada um levam
valor (`env -i rm -rf x` ainda é `rm -rf`, `timeout --kill-after 5 10 rm -rf x` também), e olha o corpo de uma definição de função
(`f(){ rm -rf x; }; f`). Uma linha que pode ser lida como definição (`rm '()' x`) é julgada **nas duas leituras**, a do corpo e a do
comando como foi escrito, e vale o primeiro motivo achado. Uma substituição `$( )` é julgada onde o shell estará depois dos `cd`
da linha (`cd ~/Documents && echo $(rm x)`).

| Padrão reconhecido | Motivo mostrado |
|---|---|
| `sudo`, `doas` | roda como administrador |
| `rm -r`/`-R` (e `--recursive`, também abreviado); `xargs rm`; `find -delete` | apaga arquivos de forma recursiva ou forçada |
| `rm`/`unlink` simples (também `rm -f` sem `-r`: o `-f` só cala o erro de arquivo que não existe) com algum alvo fora da pasta própria e fora de `/tmp`/`/var/folders` (ou sem pasta própria, ou alvo que não dá para saber, como `$VAR`) | apaga de forma definitiva (sem passar pela Lixeira) fora da pasta do Orb |
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

**`cd` antes do `rm`.** Os operandos relativos são julgados em todas as pastas onde o shell pode estar: a de partida e as que cada
`cd` poderia ter alcançado (um `cd` que falha deixa o shell onde estava). `cd ~/Documents && rm x.docx` e `cd ~ && rm -rf dist`
perguntam; um `cd` de destino desconhecido (`cd $DIR`, `cd -`, `popd`) faz o operando relativo deixar de ser descartável.

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

**Escritas**: `write_file`/`edit_file`/`trash` (também no
"Automático") em arquivos de inicialização do shell
(`.zshrc`, `.zprofile`, `.bashrc`…), em `~/.ssh`, em `~/Library/LaunchAgents`, em `/Library/LaunchAgents`,
`/Library/LaunchDaemons` e `/etc` (que o sistema resolve para `/private/etc`) são perigosas. A comparação ignora maiúsculas e minúsculas, como o sistema de arquivos do Mac:
gravar `~/.ZPROFILE` (arquivo que ainda não existe) vale como `.zprofile`.

O detector é conservador sobre o que reconhece e **nunca afirma que um comando é seguro**: o que ele não conhece cai na regra
normal do modo.

## Aprovações

### O cartão

Quando `evaluate` devolve `.ask`, o motor monta um `ApprovalRequest`, abre uma entrada no `ApprovalGate` (um actor
compartilhado, seguro contra cancelamento), emite `TurnEvent.approval` e espera. O cartão aparece na
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
⌘↩ também vale a partir do campo "Diga o que fazer em vez disso", mas **não** com texto no compositor principal: ali ele é
"Parar e enviar", que recusa o pedido aberto (parar sempre recusa) e envia o que foi escrito. O "Parar e enviar" do balão da fila só envia a fila: o que está escrito e anexado no compositor fica onde está. Com o compositor vazio ou
sem foco, ⌘↩ permite.

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
respondido sozinho.

## Claude Code

Um Orb no Claude Code passa pela mesma `PermissionPolicy.evaluate` e pelo mesmo `ApprovalGate` que os outros: o motor julga a chamada,
abre o cartão se for o caso e só depois roda a ferramenta; o resultado volta ao CLI. O `claude` (`ClaudeCodeClient`) é só o cano até o
modelo e não decide nada por conta própria:

- Roda com `--tools ""` (nenhuma ferramenta dele: sem Bash, Read, Write, WebFetch, Task…), `--setting-sources ""` (não lê o
  `~/.claude/settings.json` nem o `.claude/settings.json` da pasta, então as regras `permissions.allow` dele não existem aqui),
  `--disable-slash-commands` e `--strict-mcp-config` com um servidor só, o `orb` (o binário do Orb em `--pipe-tools`), que apenas
  declara as ferramentas do turno. Os conectores do claude.ai e os servidores do `~/.claude.json` da pessoa nunca entram, e os
  conectores do Orb não vão ao CLI: o Orb os usa pelo `connector_call`, como em qualquer provedor. A pasta de trabalho do CLI é uma
  pasta vazia do app (`claude-pipe/cwd`).
- `--permission-mode default --permission-prompt-tool stdio`: o CLI pede `can_use_tool` antes de chamar uma ferramenta MCP.
  `ClaudePipeRun` só responde "permitir" depois que o motor já avaliou, perguntou (se precisava) e rodou a chamada e entregou o
  resultado na caixa de correio; qualquer outro pedido é negado na hora ("Ferramenta indisponível."). O modo do Orb não vai ao
  CLI: trocá-lo age no motor e no `ApprovalGate`, não no processo.
- O CLI roda com o mesmo ambiente do `run_command` (`ShellEnvironment`: shell de login interativo, com o PATH do `.zshrc`) e a
  pasta do `claude` na frente do PATH, menos as variáveis do provedor (`ANTHROPIC_*`, como `ANTHROPIC_API_KEY`), que trocariam em
  silêncio o login do claude.ai por cobrança da API (`ClaudeCode.isProviderVariable`).
- Não há o que o CLI aprove "por fora": sem ferramentas e sem configurações dele, tudo o que o modelo consegue fazer é chamar uma
  ferramenta do Orb, e essa passa pela política. Por isso valem para ele os mesmos modos, famílias, liberações e a mesma checagem
  de perigo e de segredos.

## Permissões do macOS (TCC)

Separadas das anteriores: dizem o que o **macOS** deixa o app fazer. Ficam em Ajustes → Permissões
(`MacPermissionsView`, `MacPermissions.swift`).

| Permissão | Como o app descobre | Quem usa |
|---|---|---|
| Automação (por app: Mail, Calendário, Notas, Lembretes, Finder, System Events, Mensagens, Safari, Música) | `AEDeterminePermissionToAutomateTarget`, sem perguntar | `applescript`, `browser_tab` |
| Acessibilidade | `AXIsProcessTrusted` | `ui_read`, `ui_act` |
| Gravação do Áudio do Sistema e da Tela | `CGPreflightScreenCaptureAccess` | `screenshot` |
| Acesso Total ao Disco | **estimativa**: tenta abrir `~/Library/Mail` ou `~/Library/Safari/Bookmarks.plist` | pastas protegidas |
| Calendários e Lembretes (acesso completo, EventKit) | `EKEventStore.authorizationStatus`, sem perguntar; **só o "Conectar" da galeria pede** | conectores Google Agenda e Lembretes |

- **Conectores do Mac** (Google Agenda, Lembretes, Gmail). Cada um se liga pelo botão "Conectar" da galeria (`LocalConnectorSetup`),
  que é o único lugar que mostra o diálogo do macOS: Calendários (`requestFullAccessToEvents`), Lembretes
  (`requestFullAccessToReminders`) ou a Automação do Mail (abre o Mail escondido e pede). Estados: sem permissão, negado (só os
  Ajustes mudam isso: o sheet leva ao painel), sem conta Google (guia curto com "Abrir Contas de Internet") e pronto; Mail
  fechado conta como "não dá para saber", não como problema. Sem a chave do `Info.plist` (`swift run` puro) o EventKit não é
  pedido, porque o macOS encerraria o processo: o sheet manda empacotar com `scripts/bundle.sh`. Dentro dos conectores, ler não
  pergunta; criar evento, lembrete e rascunho seguem o modo do Orb; **alterar evento, apagar evento e enviar e-mail perguntam sempre**
  (`update_event` é marcado destrutivo porque o Google avisa os convidados da mudança; o evento mostra quantos convidados tem).
  Um período dado só por datas inclui o dia final inteiro (`to`/`until` "2026-10-10" vai até o fim do dia 10). Um evento repetido não é alterado nem apagado. Os conectores rodam dentro do app (`LocalTransport`), com a identidade dele, e não perguntam nada ao macOS por conta própria.
- A aba nunca pede nada sozinha; cada linha tem um botão: "Pedir agora" mostra o aviso do macOS onde ele existe, "Abrir <app> e
  pedir" cobre a Automação de um app fechado e "Abrir Ajustes do Sistema" leva ao painel certo. Atualiza ao voltar ao app. Gravação do Áudio do Sistema e da Tela e Acesso Total só valem depois de reabrir o Orb.
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
  ligada mostra o atalho **Permissões**.
- `ui_read` e `ui_act` só são oferecidos ao modelo com a Acessibilidade concedida (o prompt avisa quando ficam de fora).
- As permissões valem para a identidade de assinatura do app. Com assinatura ad-hoc (o padrão de `scripts/bundle.sh`), cada
  compilação é "outro app" para o macOS; `scripts/make-signing-identity.sh` cria o certificado local "Orb Local" que mantém
  a identidade (veja [Assinatura estável](../README.md#assinatura-estável-recomendado) no README).

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

## Instruções da pasta

`ORB.md`, senão `AGENTS.md`, senão `CLAUDE.md` na pasta do Orb é **material de referência**, não ordem: qualquer pasta
baixada pode trazer um. "Confiar nas instruções desta pasta" (painel, aba "Pasta e acessos") guarda o SHA-256 completo do
arquivo em `Bot.trustedInstructionsHash`; se o arquivo mudar, volta a ser referência até confiar de novo. O texto da pasta e da memória não consegue
fechar as tags `<orb_context>`/`<workspace_snapshot>` (`Fence.neutralize`).

## Onde está no código

| Arquivo | Papel |
|---|---|
| `Models.swift` | `PermissionMode`, `Capability`, `ApprovalRequest`/`ApprovalDecision`, `Bot.permissionRules` |
| `Engine/PermissionPolicy.swift` | famílias, regras e escopos, `evaluate`, `isCovered`, pasta própria, sugestões, migração |
| `Engine/DangerousCommand.swift`, `Engine/ShellCommandLine.swift` | perigo em shell, AppleScript e escritas; segredos que não se leem sem perguntar (`SensitiveFiles`); análise da linha de comando |
| `Engine/ReadOnlyCommand.swift` | quais linhas de shell só olham (sem cartão no "Perguntar antes", rodam no "Só leitura") |
| `Engine/ApprovalGate.swift`, `Engine/ApprovalBatch.swift` | cartões abertos, resposta, grupos, troca de modo |
| `Engine/AgentEngine.swift` | `execute` / `confirmBatch`: onde o motor pergunta |
| `Engine/ClaudePipe/ClaudeCodeClient.swift`, `Engine/ClaudeCodeProtocol.swift` | `can_use_tool` (`ClaudePipeRun.answer`), as linhas de controle do CLI |
| `AppModel.swift`, `AppModel+Approvals.swift` | `permissionState`, `decide`, `permissionModeChanged`, banners |
| `ApprovalNotifications.swift`, `Views/ApprovalKeyboard.swift` | notificações com ações, ⌘↩ / Esc |
| `Views/TranscriptViews.swift` (`ApprovalCard`), `Views/QuickAskView.swift` | os cartões |
| `Views/ComposerChips.swift`, `Views/BotInspector.swift`, `Views/PermissionConfirmation.swift` | seletor de modo, "Liberações", confirmação do bypass |
| `MacPermissions.swift`, `Views/MacPermissionsView.swift` | TCC, pré-voo, tradução de erros |
| Testes | `PermissionPolicyTests`, `ReadOnlyCommandTests`, `PermissionModelTests`, `DangerousCommandTests`, `ApprovalNotificationTests`, `MacPermissionsTests`, `AgentEngineTests`, `ClaudeCodeClientTests` |
