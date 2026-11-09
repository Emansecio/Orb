# Usar o navegador do Orb quando eu quiser — viabilidade e plano

Investigação só de leitura, 2026-11-08, sobre `main` em `81dc956`. Caminhos de código relativos a `Sources/Orb/`.

**Pedido.** Abrir o navegador de um Orb (o perfil dele, com os logins) e usá-lo por conta própria, sem o Orb ter pedido;
depois, se quiser, pedir ao Orb que "continue daqui", na página em que parei. Hoje só dá para assumir pela janela ampliada
da tela ao vivo, e só enquanto o Orb usa o navegador num turno.

**Veredito: viável, com condições.** O código já tem quase tudo: a janela real do mesmo perfil (`setHeaded`, usado pelo
`browse_show`), a trava que faz as ferramentas do Orb esperarem a pessoa (`BrowserControl`) e as abas por conversa
(`TabBook`). Faltam três coisas, nenhuma delas grande: (1) abrir sem turno; (2) uma regra para rotinas e pulso, que hoje
esperariam a pessoa sem prazo; (3) um aviso visível de "o navegador está com você", com devolver e continuar daqui. Duas
condições pedem medição antes da etapa 1 (etapa 0): se o tempo ocioso do agent-browser fecha a janela enquanto a pessoa
navega, e se as ações do Orb com a janela visível trazem o Chrome para a frente.

**Estado (2026-11-08):** etapas 0 e 1 feitas na opção A, com as recomendações das perguntas 2, 3, 4, 5 e 7 aplicadas
(a janela some ao devolver; rotina e pulso não esperam; sem atalho; página em branco; encerrar fecha direto). Etapa 2
("Continuar daqui") e etapa 3 em aberto.

**Medido com o agent-browser 0.39.1** (perfil temporário, sem janela, sockets próprios):
- um comando a cada 9 s manteve vivo um daemon com ocioso de 20 s; sem comandos, ele fechou. A vigia de 15 s cobre isso;
- `tab close` na última aba é recusado ("Cannot close the last tab");
- com o Chrome encerrado (como ⌘Q), o próximo comando **relança** o Chrome sozinho (`lifecycle.launched: true`). Por
  isso a vigia olha primeiro o `SingletonLock` (sem processo novo) e só depois pergunta as abas;
- o `SingletonLock` aponta para o processo principal do Chrome (`<host>-<pid>`): é esse pid que vem para a frente.
- Não medido (exige janela ou mão na tela): se o uso da pessoa na janela conta como atividade para o daemon (a vigia
  torna isso irrelevante); o que `tab` responde com o Chrome vivo e sem janela; e a barra de "controlado por software".

---

## 1. Como o navegador do Orb nasce, de quem é a sessão e quando fecha

- **Nasce no primeiro uso, nunca antes.** `BrowserHub.session(botID:mode:)` (`Engine/Browser/BrowserHub.swift:599`) cria a
  `BrowserSession` e o driver na primeira ferramenta `browse_*`. O Chrome só sobe no primeiro `open`: entre os comandos,
  só o `open` lança (`launching`, `AgentBrowserDriver.swift:251-271`), e qualquer outro sem processo em segundo plano dá
  `noPage` em vez de abrir um Chrome sem perfil (`:280-289`).
- **Dono.** O `BrowserHub` guarda uma sessão por Orb (`sessions`, `BrowserHub.swift:489`). O processo é o daemon do
  agent-browser com o nome `orb-<8 do id>-chrome` (`AgentBrowserConfig.sessionName`, `AgentBrowserDriver.swift:34`),
  que vive além do app e por isso é sempre fechado pelo nome (`BrowserHub.swift:719-752`). Cada conversa vê o mesmo
  navegador pela sua aba (`scoped`, `:360`; escopo = `gatewaySessionID` da conversa, `AppModel.swift:1943-1949`), e todo
  comando passa pelo `exclusive`, que troca para a aba da conversa sob uma trava única (`:363-378`, `TabBook.activate`
  `:164`).
- **Perfil.** `<dados>/navegador/<orb id>/chrome` (`profileFolder`, `BrowserHub.swift:551`), passado com `--profile`
  (`AgentBrowserDriver.swift:165`). `adoptOldProfile` renomeia o antigo `cloak` para `chrome` quando falta este
  (`BrowserHub.swift:574-582`). Ao lado: `estado/` (`browse_page state_save`, `:556`) e a nota `limpeza-de-cache`.
- **Quando fecha** (o perfil sempre fica; só `deleteData` o apaga, `:852-863`, ao apagar o Orb):
  - `browse_close` (`Engine/Tools/BrowseTools.swift:890-895`) → `hub.close` (`BrowserHub.swift:772`);
  - mudança de modo, proxy ou "Navegar na web" desligado (`AppModel.swift:1314-1323`); sessão trocada por outro modo
    (`BrowserHub.swift:621-623`);
  - Orb apagado, redefinição, `state.json` recarregado (`AppModel.swift:1543`, `:2946`);
  - saída do app: `terminateAllNow` fecha tudo o que é deste app (`AppModel.swift:625`, `BrowserHub.swift:805`);
  - sozinho, após 30 min sem uso: `AGENT_BROWSER_IDLE_TIMEOUT_MS=1800000` (`AgentBrowserDriver.swift:144`). O `--help` do
    0.39.1 diz "Shut down daemon after inactivity"; **não está medido se o uso da pessoa na janela conta como atividade**.
- **Limpeza semanal.** Uma vez, 60 s depois de abrir o app (`AppModel.swift:500-505`). `cleanCachesIfDue` não roda com
  sessão guardada, com sessão do Orb na lista do agent-browser nem com o `SingletonLock` do perfil vivo
  (`BrowserHub.swift:785-798`, `BrowserProfileCache.isInUse` `:61-68`); durante a limpeza, `session` espera
  (`BrowserHub.swift:604`). Cookies e logins nunca entram (`BrowserProfileCache.swift:9-14`).

## 2. Abrir o mesmo perfil fora de um turno

O Chromium aceita um processo por user-data-dir. O próprio driver registra o efeito: um Chrome aberto num perfil em uso
"passa para ele e sai, sem escrever DevToolsActivePort" (`AgentBrowserDriver.swift:564-565`), e por isso o `setHeaded`
fecha, espera sumir e reabre (`:562-582`).

**Caminho A — reusar a sessão do Orb (`setHeaded(true)`).** É o que o `browse_show` faz hoje: `exclusive` +
`relaunchKeepingTabs` (`BrowseTools.swift:813-816`, `BrowserHub.swift:431-436`), que guarda as páginas das outras
conversas e as reabre depois do relançamento. Fora de um turno funciona do mesmo jeito: `hub.session(...)` e
`session.exclusive { ... }` não dependem de `ToolContext`. O que quebra ou pede cuidado:
- o relançamento recarrega a página atual e as das outras conversas; o que foi digitado e não enviado se perde (o
  protocolo já avisa, `BrowserDriver.swift:86-88`);
- com o navegador fechado, o caminho é um `open` com `headed = true` (o `setHeaded` faz isso, `:573-576`), sem relançar;
- **bug latente:** `markClosed` (`AgentBrowserDriver.swift:273-278`) não devolve `headed` ao padrão; só `close()` o faz
  (`:629`). Se a pessoa fechar o Chrome (⌘Q) com a janela aberta, o próximo `open` do Orb sobe **com janela**, contra a
  regra 24. Já acontece hoje depois de um `browse_show`; a feature deixa mais provável;
- o Orb em "Visível" já tem janela (`BrowseTools.swift:806-810`): não relança, só a traz para a frente;
- trazer para a frente: o agent-browser 0.39.1 não tem comando para isso (`--help` sem "front"). O pid do Chrome está no
  `SingletonLock` do perfil (`BrowserProfileCache.isInUse` já o lê, `:61-68`), então `NSRunningApplication(processIdentifier:)`
  serve, **só no gesto da pessoa**.

**Caminho C — um Chrome à parte no mesmo perfil.** Quebra em quase todo cenário:
- com o navegador do Orb aberto, o Chrome novo entrega a URL à instância sem janela e sai: não aparece nada;
- com ele fechado, o próximo `open` do Orb bate na trava e falha ("DevToolsActivePort"); o Orb fica preso até a pessoa
  fechar o Chrome dela;
- `terminateAllNow` não o conhece: ele sobrevive à saída do app e trava o perfil no próximo uso;
- com o Google Chrome da pessoa em vez do programa do app (`status.program`), um perfil gravado por versão mais nova
  pode ser recusado pela mais velha ("perfil de versão mais nova").

Conclusão: **reusar a sessão** (caminho A, ou B abaixo, que também a reusa). Chrome à parte, não.

## 3. Quem tem a vez

**Mecanismo que já existe.** `BrowserControl` (`Engine/Browser/BrowserControl.swift`): `take`/`giveBack` (`:26`, `:31`);
toda `browse_*` espera na entrada (`BrowseSupport.session`, `BrowseTools.swift:25-31`), assim como `web_search` pelo
navegador (`WebSearchTool.swift:395`) e `browse_proxy` (`BrowseProxyTool.swift:55`). Parar encerra a espera. Ao voltar, a
ferramenta devolve `handedBack` ("tire um browse_snapshot novo") em vez de agir com refs velhas (`BrowserControl.swift:10`,
`:41`). Para cliques, isso basta: com a pessoa no controle, o Orb não manda comando nenhum, e a ação já em andamento
termina antes (a trava `exclusive`).

**O que muda com a pessoa usando por conta própria:**

| Situação | Hoje | Proposta |
|---|---|---|
| Turno de chat começa enquanto a pessoa usa | a 1ª `browse_*` espera sem prazo | igual: espera, e o compositor mostra "O Orb espera você devolver o navegador" |
| Rotina, pulso (`unattended`, `AppModel.swift:1993`) | espera sem prazo: a rodada trava | não espera: erro curto ao modelo ("the person is using your browser now; skip the web step and say so in the report"); `web_search` cai na busca por HTTP |
| Pedido de outro Orb | idem | segue a regra da rotina se a rodada for `unattended`; **conferir** como a delegação marca isso |
| Pessoa abre enquanto o Orb age | — | `take` antes do relançamento: a ação em curso termina, as próximas esperam |
| Mudar o modo no painel com a pessoa usando | `update` fecha o navegador (`AppModel.swift:1314-1323`) | seletor "Navegador" desativado enquanto está com a pessoa, com `.help` |
| Limpeza semanal | pula se há sessão ou trava | nada a mudar: a sessão aberta pela pessoa é uma `existingSession` |
| Sair do app | fecha tudo | fecha também a janela da pessoa; os logins ficam (pergunta 7) |
| Pessoa fecha a janela ou dá ⌘Q no Chrome | — | vigia devolve a vez sozinha e zera `headed` |

**Vigia.** Enquanto a pessoa tem o navegador, um laço no `AppModel` (não no `body`) pergunta `tab` a cada ~15 s pela
`exclusive`: lista vazia ou `noPage` significa que a janela foi fechada, e a vez volta ao Orb. Se a etapa 0 mostrar que
o tempo ocioso só conta comandos, a mesma chamada também mantém o daemon vivo. O laço acaba no `giveBack`.

## 4. Como a pessoa usaria

**Janela real do Chrome (recomendado).** Tem barra de endereço, abas, passkey, preenchimento de senha, janelas de OAuth,
menus `<select>`, envio de arquivo e copiar e colar: o que a pessoa espera de "usar o navegador". Vem para a frente uma
vez, no gesto de abrir (regra 24: ela pediu). Custo: um relançamento quando o Orb estava sem janela, com a página
recarregando. Se as ações do Orb trouxerem o Chrome para a frente, isso só acontece com a janela aberta, ou seja, com a
pessoa usando; mesmo assim, a etapa 0 mede.

**Janela ampliada da tela ao vivo (`LiveScreenWindow`).** Não tira o foco, não relança e já tem Assumir e Devolver
(`LiveScreen/LiveScreenWindow.swift:197-215`, `LiveFeedHub.swift:197-215`). Mas hoje ela só serve com o Orb em turno: no
estado ocioso diz "O Orb não está usando o navegador agora" e não deixa assumir (`LiveScreenWindow.swift:44-45`, `:114`);
o stream só conecta com sessão existente (`LiveBrowserSource.swift:12`, `LiveStream.swift:307`). Para ser um navegador de
uso, faltam barra de endereço, Voltar, Recarregar e abas (o teclado vai para a página, não para uma omnibox: o Chrome sem
janela não tem uma). Ficam de fora: passkey, `<select>` nativo (a medir no screencast), seletor de arquivo, copiar
(⌘C) e extensões. A imagem é um JPEG de 960 px a 10 qps, com ~27 % de um núcleo numa página animada
(`docs/TELA-AO-VIVO.md` 7). Serve para olhar e dar um clique, não para navegar de verdade.

## 5. "Continua daqui"

**O que o Orb recebe:** uma linha, no prompt do pedido seguinte, em inglês e curta, montada pelo mesmo caminho que já
reescreve o prompt (`unattendedPrompt`, `AppModel.swift:1835`):

> `[Browser: the person left your browser on <host+path> — “<title>”. Earlier refs are stale; take browse_snapshot before acting.]`

- **URL sem query nem fragmento** (pode ter token). Página protegida (`pageLooksSensitive`, `BrowserHub.swift:696`, ou o
  veredito do `notePage`): só o host, como faz o fim do cartão (`BotSession+LiveScreen.swift:51-53`).
- **Sem snapshot nem texto da página.** Fica em ~30–50 tokens, uma vez só. O modelo tira o `browse_snapshot` se precisar,
  e precisaria de qualquer jeito, porque as refs morreram.
- **A aba vira da conversa.** Antes do turno, a visão `scoped` da conversa adota a aba ativa (`adoptCurrentTab`,
  `BrowserHub.swift:385-388`). Sem isso, a primeira `browse_*` voltaria à aba antiga da conversa (`TabBook.activate`).
- **Sem tropeço na primeira ferramenta.** Ao montar a linha, o app consome o `handedBack` (`consumeHandBack`): o aviso já
  está no prompt, e a primeira `browse_*` não falha à toa só para dizer o mesmo (hoje ela lança `ToolError`,
  `BrowseTools.swift:29`).
- **Na tela:** um chip no compositor, "Página do navegador · <host>", removível como um anexo; a linha só vai se o chip
  estiver lá no envio.

## 6. Por onde a pessoa abre e devolve

Seguindo os controles e as palavras que já existem (regras 1, 5, 6, 7; "pasta", "grupo", "espaço" e "categoria" ficam
de fora):

- **Menu do Orb na lateral** (`Views/SidebarView.swift:545-565`): "Abrir o navegador", com o ícone de
  `Capability.browser.symbol`, logo depois de "Abrir pasta do Orb no Finder" (`CommandName.openFolder`). Só aparece com
  "Navegar na web" ligado e o navegador instalado; desativado durante instalação ou atualização (`maintenance`).
- **Painel, cartão "Pode usar" → "Navegar na web"** (`Views/BrowserPickers.swift:105-158`): um link "Abrir o navegador"
  no estilo `QuietTextStyle` do "Remover" do proxy (`:264-278`), abaixo dos seletores.
- **Compositor, enquanto o navegador está com a pessoa:** um chip em `ComposerChipStyle` (`Views/ComposerChips.swift:8`),
  "Navegador com você", cujo menu tem "Continuar daqui", "Devolver ao Orb" e "Mostrar a janela". É o único lugar novo,
  e copia os chips vizinhos.
- **Atalho:** nenhum na etapa 1 (pergunta 4). Se vier, segue a receita de `docs/ARQUITETURA.md` ("Novo comando de
  teclado": `CommandName`, `AppShortcut`, `AppCommands`, `ShortcutCatalog`).
- Texto: "o navegador do Orb", nunca "agent-browser" nem "sessão" (regra 6). A janela é do Chrome; o app não a renomeia.

---

## Opções

| | A. Janela real, mesma sessão | B. Dentro do app (`LiveScreenWindow`) | C. Chrome à parte |
|---|---|---|---|
| Logins, passkey, OAuth, arquivos | tudo | sem passkey, arquivo e copiar | tudo |
| Foco | vem à frente no gesto | nunca sai do app | vem à frente |
| Relança e recarrega a página | sim, se estava sem janela | não | — |
| Conflito de perfil | nenhum (mesmo processo) | nenhum | trava o Orb ou não abre |
| Código novo | pequeno (reusa `browse_show`) | médio (barra de endereço, abas, comandos) | pequeno, mas frágil |

**Recomendação: A**, com B como etapa opcional para quem quer só dar uma olhada sem sair do app. C fica descartada.

## Etapas (regra 25: cada uma usável sozinha; sem a pré-condição, tudo fica como hoje)

**Etapa 0 — medições e o bug do `headed`** (sem interface).
- Medir com `ORB_REAL_BROWSER_TESTS=1` e o Orb fechado: (a) com a janela aberta e só a pessoa clicando, o daemon fecha
  em 30 min? (rodar com `--idle-timeout 2m` para ver em minutos); (b) `tab <id>`, `click` e `open` do Orb com a janela
  visível trazem o Chrome para a frente?; (c) fechar a última janela e dar ⌘Q: o que `tab` e `session list` respondem?;
  (d) a barra "controlado por software de teste" aparece?
- Corrigir: o navegador que sumiu volta ao modo do Orb (`headed = visibleByDefault` em `markClosed`).
- Arquivos: `Engine/Browser/AgentBrowserDriver.swift`; testes em `AgentBrowserDriverTests`; anotar as medições em
  `docs/TELA-AO-VIVO.md`.

**Etapa 1 — "Abrir o navegador" (janela real).**
- `BrowserHub`: `openForPerson(botID:mode:)`, que dá `control.take`, cria a sessão, faz `open` com janela se estava fechado
  ou `relaunchKeepingTabs { setHeaded(true) }` se estava sem janela (nada no "Visível"), marca `setShowingWindow(true)` e
  ativa o pid do `SingletonLock`; `giveBackFromPerson`, que dá `giveBack` e volta a esconder a janela (fora do
  "Visível"). O driver expõe `isHeaded` (padrão `false` no protocolo).
- Rotina e pulso não esperam (`BrowseSupport.session`, `WebSearchTool`, `BrowseProxyTool`, com `context.unattended`).
- Vigia de 15 s; seletor de modo desativado enquanto está com a pessoa; chip do compositor com "Devolver ao Orb" e
  "Mostrar a janela".
- Entradas: menu da lateral e link no painel.
- Arquivos: `Engine/Browser/BrowserHub.swift`, `BrowserDriver.swift`, `AgentBrowserDriver.swift`,
  `BrowserProfileCache.swift` (ler o pid), `Engine/Tools/BrowseTools.swift`, `WebSearchTool.swift`, `BrowseProxyTool.swift`,
  `AppModel+Browser.swift`, `Views/SidebarView.swift`, `Views/BrowserPickers.swift`, `Views/ComposerChips.swift`,
  `Tips.swift`, `OrbApp.swift` (`Snapshot.render`), `docs/MANUAL.md`, `docs/TELA-AO-VIVO.md`.
- Toggle em Ajustes: não; o recurso só age quando a pessoa clica, e o padrão é o de hoje.

**Etapa 2 — "Continuar daqui".**
- No chip: devolve, faz a conversa adotar a aba ativa, consome o `handedBack` e põe o chip "Página do navegador" no
  compositor; no envio, a linha do item 5 entra no prompt.
- Arquivos: `AppModel+Browser.swift`, `AppModel.swift` (montagem do prompt, junto de `unattendedPrompt`),
  `Engine/Browser/BrowserHub.swift` (adotar a aba fora de uma ferramenta), `Views/ComposerChips.swift` ou
  `Views/ComposerView.swift`, `LiveScreen/LiveScreenLogic.swift` (`LiveScreenText`, para host e caminho), `OrbApp.swift`.

**Etapa 3 (opcional) — usar dentro do app.**
- `LiveScreenWindow` ociosa ganha "Abrir o navegador": sobe o navegador sem janela e assume. A barra ganha campo de
  endereço, Voltar e Recarregar (`open`, `back` e `reload` pela `exclusive`).
- Arquivos: `LiveScreen/LiveScreenWindow.swift`, `LiveFeedHub.swift`, `LiveBrowserSource.swift`,
  `LiveScreen/LiveScreenSnapshots.swift`.

## Testes de regressão previstos

Cada correção conferida falhando sem ela (regra 31). Suítes: `AgentBrowserDriverTests`, `BrowserTabsPerConversationTests`,
`BrowserHubReplacementTests`, `LiveScreenControlTests`, `BrowserPickerTests`, `BrowserProfileCacheTests`,
`BrowserCleanupTests`, mais uma nova `BrowserForPersonTests`.

- Etapa 0: depois de `setHeaded(true)` e da sessão sumir (`noPage`), o próximo `open` sai **sem** `--headed` (runner falso).
- Etapa 1:
  - com o navegador fechado, `openForPerson` lança com `--headed` e deixa `isHeld`;
  - sem janela, relança mantendo as abas das outras conversas;
  - no "Visível", não relança;
  - em `maintenance`, dá erro e não segura nada;
  - `giveBack` esconde a janela fora do "Visível" e é idempotente;
  - corrida: uma `browse_*` em andamento termina antes do relançamento, e a seguinte espera;
  - `unattended` com o navegador segurado responde na hora, sem esperar (`TestGate`), e o chat espera;
  - `web_search` em `unattended` com o navegador segurado vai por HTTP;
  - a vigia com `tab` vazio ou `noPage` devolve a vez e zera `headed` (`waitUntil`);
  - o seletor de modo fica desativado enquanto segurado;
  - a limpeza de cache pula a sessão aberta pela pessoa;
  - `terminateAllNow` fecha a sessão aberta pela pessoa;
  - snapshots do chip e do painel em 460 e 1100 pt.
- Etapa 2:
  - a linha tira query e fragmento; página protegida dá só o host;
  - a linha entra uma vez e tem teto de caracteres (sem snapshot);
  - a conversa adota a aba ativa, e a primeira `browse_snapshot` não lança `handedBack`;
  - sem o chip no envio, o prompt fica igual ao de hoje.
- Etapa 3: a janela ociosa sobe o navegador e assume; o campo de endereço recusa o que não for http(s)
  (`BrowseSupport.address`).

## Riscos

- **Tempo ocioso** fechar a janela no meio do uso (etapa 0a). A vigia mitiga, se o comando contar como atividade.
- **Foco:** ações do Orb trazendo a janela para a frente (0b). Com a etapa 1 escondendo a janela ao devolver, só
  aconteceria com a pessoa já na janela.
- **Página recarrega** ao abrir (sem janela → com janela) e ao devolver (volta): formulário não enviado se perde, nas
  conversas também. Mitigação: só relançar quando preciso; avisar no `.help` do item.
- **O que a pessoa loga, o Orb usa.** É o objetivo, mas vale dizer no manual: cookies e sessões do perfil ficam ao alcance
  das ferramentas do Orb, dentro das permissões dele.
- **Proxy:** a janela da pessoa sai pelo proxy do Orb, se houver (`proxyRow`).
- **Rotinas** puladas sem a pessoa saber: o relatório da rodada diz o motivo; nada fica preso.
- **Sair do app** fecha a janela e as abas (não são restauradas no próximo uso).

## Perguntas que só você pode responder

1. **Janela real do Chrome ou só dentro do app?** Recomendo a janela real (opção A), com a do app como etapa 3 opcional.
2. **Ao devolver, a janela some ou fica aberta enquanto o Orb continua?** Recomendo que suma (volta ao segundo plano,
   regra 24); quem quiser vê-lo trabalhando já tem o cartão ao vivo e o modo "Visível".
3. **Rotina ou pulso enquanto você usa: pula o passo da web ou espera?** Recomendo pular e dizer no relatório. Esperar
   prende a rodada pelo tempo em que você estiver navegando.
4. **Atalho de teclado para abrir?** Recomendo nenhum por enquanto (menu e painel bastam); fica fácil de pôr depois.
5. **Com o navegador fechado, abrir em quê?** Recomendo página em branco; a alternativa é a última página da conversa
   aberta.
6. **"Continuar daqui" também para a página que o próprio Orb deixou** (item no "+" do compositor, sem você ter usado)?
   Recomendo deixar para depois da etapa 2.
7. **Ao encerrar o Orb com o navegador em uso por você: fecha direto ou pergunta?** Recomendo fechar direto (os logins
   ficam no perfil), sem diálogo novo.
