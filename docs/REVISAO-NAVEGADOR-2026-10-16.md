# Revisão do navegador do Orb (16/10/2026)

Decisão do usuário: encolher o sistema de navegador para **um Chromium com dois modos**, segundo plano (padrão e prioridade) e visível; sair o Obscura, o CloakBrowser e o seletor de motores. Este documento registra a **etapa 0** (a medição que escolhe a base) e o que foi feito em cada etapa.

## Etapa 0: medição

Tudo foi medido neste Mac (Apple M1 Pro, macOS 27), em 16/10/2026, com perfis em pasta temporária e `AGENT_BROWSER_SOCKET_DIR` temporário (as sessões do app e o Brave do Orb "Atendente AcessosFit 2" não foram vistos nem tocados). O foco foi vigiado a cada 0,2 s (`lsappinfo`), a lista de janelas pelo `CGWindowListCopyWindowInfo` e o Dock/ícone pelo `ApplicationType` do `lsappinfo`. Versões: agent-browser 0.39.0, Google Chrome 155.0.8059.84, Chrome for Testing 155.0.8059.39 (o que o app baixava), CloakBrowser 145.0.7632.109.2.

Páginas: bot.sannysoft.com, CreepJS e browserscan.net/bot-detection (mais o httpbin.org/headers para ver o `Sec-Ch-Ua`). Memória: soma do RSS de todos os processos da montagem (conta páginas compartilhadas mais de uma vez, então vale só para comparar uma com a outra, medida em branco e depois das três páginas, CreepJS incluído).

| Montagem | Foco | Abertura | Memória (branco / fim) | sannysoft (falhas) | CreepJS (headless / parece headless) | browserscan |
|---|---|---|---|---|---|---|
| **A** hoje: agent-browser, Chrome for Testing headless, UA por `--user-agent` (CDP) + `--disable-blink-features` | não mexeu | 1,2 s | 1.127 / 1.807 MB | 0 | 33% / 38% (o UA do service worker diz HeadlessChrome) | Normal |
| A com o Google Chrome instalado (mesmos flags) | não mexeu | 1,0 s | 1.431 / 2.378 MB | 0 | 33% / 38% | Normal |
| A sem UA (padrão do agent-browser) | não mexeu | 1,7 s | 1.223 / 1.488 MB | 3 (UA antigo, HEADCHR_UA, CHR_MEMORY) | 67% / 31% | **Robot** |
| A sem `--disable-blink-features` | não mexeu | 0,9 s | 1.119 / 1.680 MB | 2 (`navigator.webdriver` presente) | 33% / 31% | **Robot** (`webdriver` = true) |
| A com script de init para esconder o `webdriver` | não mexeu | 1,9 s | 1.140 / 1.512 MB | 1 ("WebDriver (New) present") | 67% / 38% | **Robot** (piorou) |
| **B** agent-browser `--headed` com a janela fora da tela | **tirou o foco** (Chrome for Testing na frente por cerca de 0,4 s, duas vezes) | abortada | n/d | n/d | n/d | n/d |
| **C** `open -g -j -n -a "Google Chrome"` + `--cdp` | **tirou o foco** (Google Chrome na frente por cerca de 0,3 s; repetido, deu igual) | abortada | n/d | n/d | n/d | n/d |
| **D** Google Chrome executado direto com `--headless=new` + `--cdp` | não mexeu | 0,6 s | n/d / 1.603 MB | 3 (UA diz HeadlessChrome) | 67% / 31% | **Robot** |
| D com `--user-agent` como flag do Chrome | não mexeu | 1,0 s | 1.211 / 1.725 MB | 0 | **0%** / 31% | Normal |
| **E** CloakBrowser 145 pelo agent-browser | não mexeu | 1,4 s | 870 / 1.763 MB | 0 | 0% / 25% (UA Chrome/145) | Normal |
| **Escolhida**: agent-browser + Google Chrome headless por um lançador de uma linha que acrescenta o `--user-agent` completo | não mexeu | 2,5 s (primeira, com a máquina ocupada; 1 a 1,3 s nas outras) | 1.482 / 1.479 MB | 0 | **0%** / 31% | Normal |

Outros fatos medidos:

- Nenhuma montagem headless criou janela na tela (`onscreen` = 0), nem ícone no Dock (o processo principal aparece como `BackgroundOnly` e o auxiliar como `UIElement`).
- `navigator.webdriver` fica `false` só com `--disable-blink-features=AutomationControlled` (o agent-browser liga a automação; sem o flag, sannysoft e browserscan acusam). Script de init para esconder piora: o próprio script é detectado.
- O agent-browser já passa `--use-mock-keychain --password-store=basic`: nenhum aviso de Keychain, e o perfil não depende de qual Chrome o abriu.
- O `--args` do agent-browser separa **por vírgula e por quebra de linha**, sem como escapar: o UA do Chrome tem "(KHTML, like Gecko)" e chegava cortado em "(KHTML" (medido). O `--user-agent` do agent-browser vai por CDP e deixa o UA do service worker como HeadlessChrome (o CreepJS lê esse). A saída é um lançador (`--executable-path` aponta para um script curto que faz `exec` no Chrome real e acrescenta `--user-agent=<UA completo>`): o UA vale em tudo, inclusive `Sec-Ch-Ua` ("Google Chrome" 155, medido no httpbin), e o agent-browser segue dono do processo.
- O que sobra no CreepJS (31% "parece headless") e o `CHR_MEMORY` do sannysoft em algumas montagens são marcas do próprio headless; nenhuma montagem testada tirou isso, nem o CloakBrowser (25%).
- O CloakBrowser 145 não ficou à frente: 25% contra 31% de "parece headless", e o grátis parou no Chromium 145/146 (a 148 em diante é paga; a 154 grátis permite uma sessão por vez).
- Os trocos de foco que aparecem nos registros das montagens que não foram abortadas (Ghostty, Safari, WhatsApp, Claude, Unity Hub…) são do próprio usuário, trabalhando no Mac; nenhum foi de navegador.

### Decisão

Ordem pedida: nunca tirar o foco, depois menos detecção, depois confiabilidade e simplicidade.

1. **B e C saem pelo foco**: qualquer janela de verdade (`--headed`, `open`) mostrou o navegador na frente por uma fração de segundo. Por isso o modo visível só existe quando a pessoa pede (`browse_show`) ou escolhe "Visível" no painel do Orb; o segundo plano é sempre headless.
2. Entre as headless sobram A, D e E. **A pura** (como estava) deixa o CreepJS ver o service worker como HeadlessChrome; **D e a escolhida** passam a 0%; **E** não é melhor e está parado na 145. O CloakBrowser sai.
3. Entre D e a escolhida, a escolhida mantém o agent-browser dono do processo (abrir, fechar, ociosidade, sockets, perfil, `--proxy` e `--headed` já resolvidos) e acrescenta só o lançador. D exigiria o Orb gerenciar porta, ciclo de vida e limpeza do Chrome: mais código e mais jeitos de deixar processo para trás, para o mesmo resultado.

**Base escolhida: agent-browser + Google Chrome instalado (depois Brave, Chromium, Chrome Canary; o Chrome for Testing só como reserva), headless, com `--disable-blink-features=AutomationControlled` e o lançador com o `--user-agent` completo.** O Brave não foi medido (o Brave deste Mac é de um Orb real do usuário e não podia ser usado): entra na ordem como segunda opção por ser Chromium com o mesmo UA, e a primeira vez que alguém o usar vale conferir.

Limites da medição: uma rodada por montagem (um Mac, uma rede), páginas públicas de teste mudam; B e C ficaram sem números de detecção porque a regra de foco as interrompeu; o tempo de abertura da escolhida foi medido com a máquina compilando em outro processo.

## O que foi feito

(Por etapa, na ordem em que foram feitas; a revisão do código, depois, está no fim.)

### Etapa 1: um navegador, dois modos

- Saem o seletor de motores, o Obscura, o CloakBrowser (e a semente, o venv e o Python) e a "Leitura simples" como motor (`web_fetch` continua). `BrowserEngineKind` virou `BrowserMode` (`background` padrão, `visible`); `BrowserEngine.swift` virou `BrowserLocator.swift` (Chrome, depois Brave, Chromium e Canary em Applications; o Chrome for Testing só como reserva).
- `Bot.browserMode` no lugar de `browserEngine`: Orbs salvos com `chrome`, `cloak`, `obscura` ou `simple` (e valores desconhecidos) decodificam sem erro, em segundo plano e com "Navegar na web" como estava; o perfil `cloak` de um Orb é adotado como `chrome` (`BrowserHub.adoptOldProfile`).
- O lançamento leva o lançador `navegador/lancadores/<navegador>-<versão>.sh` (user agent de um Chrome com janela) e `--disable-blink-features=AutomationControlled`, as duas coisas que a medição mostrou necessárias.
- `browse_show`: do segundo plano ao visível e volta como antes; num Orb em modo Visível a janela já está aberta e a ferramenta só espera o cartão.
- Instalador: agent-browser fixo em 0.39.1, SHA-256 por arquitetura gravado no app (`BrowserPlatform.pinnedHashes`); nada de "latest"; Chrome for Testing só reserva; `removeLegacyEngines` apaga o Obscura e o CloakBrowser antigos do app (os logins ficam). Ajustes: duas linhas (agent-browser e Navegador) e, no painel do Orb, o seletor Segundo plano / Visível.
- Testes: `BrowserLocatorTests` (ex-`BrowserEngineTests`), `BrowserInstallerTests`, `BrowserSetupTests`, `BrowserPickerTests`, `BrowserCleanupTests`, `AgentBrowser*Tests`, `BrowseToolTests`, `WebSearchTests` e os fakes adaptados.

### Etapa 2: comandos de cara e `browse_run`

- Ferramentas por ação, para o custo não crescer uma por comando: `browse_click` (click, dblclick, hover, check, uncheck, focus, scrollintoview, drag), `browse_press` (com `text`/`insert`), `browse_scroll` (com `ref`), e seis novas: `browse_wait`, `browse_find`, `browse_dialog`, `browse_files`, `browse_page` (frame, pdf, state save/load, mouse) e `browse_run` (qualquer comando, manual sob demanda). `BrowserDriver` ganhou `command(_:text:)` e `manual(_:)`.
- Custo das especificações das ferramentas do navegador (descrição mais esquema, em caracteres): 13 ferramentas antes, até o teto de 4.200 (medidas na etapa 1 abaixo dele); 19 agora, 7.519 (as 13 viraram 4.519; wait 447, find 634, dialog 295, files 373, page 659, run 592). O teto do `ToolEconomyTests` foi para 7.600. Elas só aparecem com o navegador pronto.
- `browse_run`: o manual é o `--help` do agent-browser (a versão 0.39.1 não traz as skills), sem as seções do que é recusado; recusa os comandos e opções que trocariam o navegador; leitura é `.safe`, o resto `.sensitive`; arquivos citados no comando passam pelas mesmas regras de `save_to` e de leitura de chaves (e por Terminal e arquivos).
- Um diálogo JavaScript aberto trava todos os comandos: o erro vira "A JavaScript confirm dialog (...) is open... call browse_dialog" e o `browse_click` o relata em vez de dar erro no endereço.
- Testes: `BrowseMoreToolTests`; `BrowserLocatorTests` e `ToolEconomyTests` ajustados.

### Etapa 3: proxy escolhido pelo Orb

- `browse_proxy` (`status`, `set`, `clear`): o Orb dá o endereço (`BrowserProxy.normalized`: http, https, socks4, socks5, host e porta; senha embutida aceita e nunca mostrada), o hub reabre a sessão com `--proxy` (o perfil é o mesmo, então os logins ficam), abre uma página que diz o IP de saída e devolve o endereço para o Orb contar ao usuário. Se a página não responde com um endereço, o proxy anterior volta e o erro diz por quê. A página que estava aberta é reaberta.
- `Bot.browserProxy` (opcional; Orbs salvos antes decodificam sem proxy); o `AppModel` o copia para o `BrowserHub` no começo de cada turno e `browse_proxy` o grava de volta (`BrowserAccess.saveProxy`) sem fechar o navegador recém-aberto. `--proxy` entra na impressão digital do lançamento: um navegador aberto com outro proxy não é reaproveitado.
- O painel do Orb mostra "Proxy: …" com **Remover** (fecha o navegador); o prompt cita o proxy atual. O app não gerencia túneis; o exemplo do Orb "Atendente AcessosFit 2" (Mullvad com wireproxy em `socks5://127.0.0.1:1080`, `scripts/proxy_ip.py`) é do próprio Orb e fica como está.
- Custo: `browse_proxy` soma 414 caracteres (20 ferramentas, 7.933; teto 8.000).
- Testes: `BrowserProxyTests` e `BrowserProxyModelTests`.

### Etapa 4: uma aba por conversa e limpeza do cache

- Desenho mais simples que `--pin-tab`: o navegador do Orb continua um só; `BrowserAccess.scope` leva o id da conversa (chat, rotina, grupo) e `hub.session(botID:mode:scope:)` devolve uma visão (`BrowserSession.scoped`) com o mesmo driver, o mesmo bloqueio de uma chamada por vez e a memória própria dos elementos (um ref pertence à aba em que foi lido). Dentro do `exclusive` o `TabBook` leva ao rótulo `c<id>` da conversa (`tab <rótulo>`; a primeira conversa fica com `t1`; `tab new --label` para as outras) somente quando mudou quem chama. Medido com o agent-browser 0.39.1 real: `tab new --label`, `tab <rótulo>` e `tab <id>` funcionam, e um rótulo desconhecido dá erro claro.
- Navegador fechado ou aba sumida: o livro recomeça (a próxima chamada fica com `t1`) ou a conversa ganha uma aba nova. Máximo de 6 abas de conversas; a usada há mais tempo é fechada. A aba escolhida com `browse_tabs` passa a ser da conversa.
- Limpeza (`BrowserProfileCache`): uma vez por semana por Orb, um minuto depois de o app abrir e só com o navegador do Orb fechado, esvazia Cache, Code Cache, GPUCache, Dawn, Cache Storage e ScriptCache de service workers, shader e GPU persistente, quando passa de 20 MB; nunca cookies, Login Data, Local Storage, IndexedDB nem preferências; não segue links simbólicos. Um perfil real tinha 412 MB, quase tudo Cache Storage (só lido, nada apagado). A data fica em `<Orb>/limpeza-de-cache`.
- agent-browser 0.39.1 com SHA-256: feito na etapa 1.
- Testes: `BrowserTabsPerConversationTests` e `BrowserProfileCacheTests`.

## Revisão do código (16/10/2026)

As quatro etapas foram relidas contra o agent-browser 0.39.1 de verdade (headless, perfil e sockets temporários, com o foco vigiado a cada 0,2 s; ficou sempre no app da pessoa). O que estava acima mudou assim:

- **`browse_run` (etapa 2)**: as opções do agent-browser valem em qualquer lugar do comando e só exatas, então a recusa compara palavra por palavra; um primeiro termo que começa com `-` é recusado (escondia o comando: `--debug session`), assim como `tab`, `batch`, `profiles`, `clipboard`, `doctor`, `confirm`, `deny`, `--params @arquivo`, `--all` e as opções que trocam o navegador, o perfil, os downloads, os scripts de início, o user agent, os certificados e as políticas. `addinitscript` pergunta sempre, até no Automático (`danger`: o script roda em toda página até o navegador fechar). `browse_run` e `browse_files` saem da família "Clicar e preencher": fora do Automático cada chamada que não é só leitura (o `eval` incluído) é pedida de novo, sem "Sempre permitir".
- **Proxy (etapa 3)**: o proxy vai ao agent-browser pela variável `AGENT_BROWSER_PROXY`, não por `--proxy` (a senha aparecia no `ps` e no arquivo da impressão digital, que agora guarda só um hash). A senha vai para o Keychain (conta `browser.proxy.<id do Orb>`, pelo mesmo cofre das chaves de provedor); o arquivo do Orb guarda o endereço sem ela; Redefinir e apagar o Orb a removem. Erros do navegador passam por `BrowserProxy.redacting`, com a senha nova e a anterior. A leitura do IP tem prazo próprio (40 s) e roda dentro do bloqueio do navegador, na aba da conversa; a volta ao proxy anterior reabre as páginas.
- **Abas (etapa 4)**: o `TabBook` ganhou estado por geração do navegador (um navegador que recomeça não confunde as abas antigas com as novas), a aba da conversa é fechada quando a conversa termina (a rotina e o pedido entre Orbs ao terminar; o chat e o grupo continuam, e a aba deles é a usada há mais tempo a sair quando passa de 6) e reaberta com a página depois de trocar o proxy ou de passar para o modo visível. `browse_tabs` mostra só as abas da conversa atual e uma linha com quantas são das outras, sem os endereços. Com proxy com login o agent-browser 0.39.1 derruba o navegador num `tab close` ("Failed to install browser network controls"): nesse caso as abas ficam abertas e são reaproveitadas, e `browse_tabs close` é recusado.
- **Cache (etapa 4)**: a limpeza confere o `SingletonLock` do perfil (o processo que o Chromium grava ali está vivo?) além do hub, e o hub não abre o navegador de um Orb enquanto o cache dele é limpo. A lista do que nunca sai ganhou o armazenamento das extensões.
- **Custo**: as descrições das 20 ferramentas foram enxugadas (o que o enum do esquema e o nome do parâmetro já dizem, exemplos repetidos): de 7.939 para 7.010 caracteres; o teto do `ToolEconomyTests` foi de 8.000 para 7.200.
- **Acabamentos**: a atualização do agent-browser compara com o pin do app, não com a checagem guardada; a linha do proxy no painel segue a linha de estado vizinha.
- Testes novos ou ampliados: `BrowseMoreToolTests`, `PermissionPolicyTests`, `BrowserProxyTests`, `BrowserProxyModelTests`, `BrowserTabsPerConversationTests`, `BrowserProfileCacheTests`, `BrowserInstallerTests`, `AgentBrowserDriverTests`.
- Fica para o app aberto: o `browse_show` e o modo Visível na tela, o Keychain de verdade pedindo permissão na primeira senha de proxy, um proxy real com login e a aparência do painel.
