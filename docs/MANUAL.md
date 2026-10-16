# Manual do Orb

Tudo o que o app faz, tela por tela. A apresentação e a instalação estão no [README](../README.md); o lado de dentro
(módulos, decisões, testes) está em [ARQUITETURA.md](ARQUITETURA.md).

[Primeiro uso: conectar um modelo](#primeiro-uso-conectar-um-modelo) · [A tela de boas-vindas](#a-tela-de-boas-vindas) · [A janela](#a-janela) · [Criar um Orb](#criar-um-orb) · [Conversar](#conversar) · [Permissões](#permissões) · [Permissões do macOS](#permissões-do-macos) · [Memória](#memória) · [Conversas e rotinas](#conversas-e-rotinas) · [Orbs juntos](#orbs-juntos) · [Contexto da conversa](#contexto-da-conversa) · [Uso e custos](#uso-e-custos) · [Conectores e skills](#conectores-e-skills) · [Atalhos](#atalhos) · [Barra de menus e pergunta rápida](#barra-de-menus-e-pergunta-rápida) · [Redefinir o Orb](#redefinir-o-orb) · [Privacidade](#privacidade) · [Problemas comuns](#problemas-comuns)

## Primeiro uso: conectar um modelo

Na primeira abertura já existe um Orb, o **Atlas**. Sem modelo conectado, o chat mostra o cartão "Vamos preparar Atlas"
com os caminhos mais curtos (se você escrever antes, o texto fica no campo e o cartão pisca):

| Opção | O que faz |
|---|---|
| Usar meu Claude Code | usa a assinatura Claude Pro/Max pelo Claude Code instalado |
| Entrar com ChatGPT | abre o navegador para entrar com a sua conta Plus ou Pro |
| Usar o Ollama / LM Studio que já está rodando aqui | só aparece se o servidor estiver respondendo |
| Colar uma chave de API | OpenAI, Claude, xAI ou OpenRouter |

"Mais opções em Ajustes" (⌘, → **Modelos**) leva à lista completa. Os provedores aparecem em grupos; os modelos de cada um vêm
**ao vivo** do provedor (ao abrir e a cada 6 h; se a lista falha, o app tenta de novo depois de 5 min, 10 min, 20 min… até 6 h, e uma chave recusada espera as 6 h) e valem para qualquer Orb.

| Grupo | Provedor | Como conectar | Observações |
|---|---|---|---|
| Assinatura (sem chave) | **Claude Code (sua assinatura)** | "Entrar" abre o navegador (roda `claude auth login --claudeai`) | Precisa do `claude` instalado ([como instalar](https://code.claude.com/docs/en/setup)). O login é o do próprio Claude Code: o Orb nunca lê, copia nem guarda os tokens. O `claude` é só o cano até o modelo (sem ferramentas, memória nem configurações dele): o prompt, as ferramentas, as permissões, a memória e o contexto são os do Orb, iguais aos de qualquer outro provedor, e o uso sai do limite do seu plano. "Sair" desconecta o Claude Code no Mac inteiro, inclusive no Terminal. Os modelos são os que a sua conta oferece |
| | **ChatGPT (sua assinatura)** | "Entrar com ChatGPT" (login oficial para apps locais) | Precisa do ChatGPT Plus ou Pro; usa o limite do seu plano |
| Chave de API | **OpenAI**, **Claude** (API da Anthropic), **xAI (Grok)**, **OpenRouter** | colar a chave | Cobrança por uso, direto no provedor |
| | **OpenCode Zen** | colar a chave de [opencode.ai/auth](https://opencode.ai/auth) | Gateway pré-pago: cobra do seu saldo pelo uso, sem margem sobre o preço do modelo. Modelos gratuitos (que podem usar seus dados) e os Gemini ficam fora da lista |
| | **OpenCode Go** | a mesma chave da OpenCode | Assinatura da OpenCode (Go US$ 10/mês, Go Plus US$ 40/mês) com modelos abertos (GLM, Kimi, DeepSeek, Qwen…). O uso tem limite por modelo em janelas de 5 horas, semana e mês; passando do limite, os modelos gratuitos seguem funcionando, e o saldo do Zen cobre se você ativar "Use balance" no console |
| | **Command Code** | colar a chave de [commandcode.ai/settings/keys](https://commandcode.ai/settings/keys) | Precisa de um plano com acesso à API: Provider (pago por uso), GOAT, Pro, Max ou Team. **O plano Go não inclui a API** (o app avisa se for o caso). Modelos gratuitos ou promocionais ficam fora da lista |
| No seu Mac | **Ollama**, **LM Studio** | abra o app e deixe o servidor ligado | Nada sai do Mac. Endereços padrão `http://localhost:11434/v1` e `http://localhost:1234/v1` (dá para trocar). Sem modelo baixado ou carregado, a linha avisa |
| Avançado | **Gateway próprio** | URL base (`http://` ou `https://`), formato e, se precisar, cabeçalhos | Formatos: Chat (OpenAI), Responses (OpenAI) ou Messages (Anthropic / Claude). Os modelos vêm da lista do servidor ou você os adiciona pelo id (o primeiro vira o padrão se o atual não serve). A chave é opcional: salva, a linha diz "Chave salva" e "Apagar" tira só a chave |

Os preços e planos acima são os que o app descreve hoje; confira no site do provedor, que pode mudar.

O **modelo padrão** (Ajustes → Modelos) vale para os Orbs sem modelo próprio. Cada Orb pode ter o seu: na aba Geral do painel
dele ou no botão de modelo do compositor (⇧⌘M, com busca e os recentes). "Desativar este provedor" (reticências da linha) tira o
provedor das listas sem apagar a chave; "Remover…" apaga a chave (ou sai da conta, no ChatGPT).
Ao conectar um provedor (chave, login, modelo do gateway adicionado à mão ou "Atualizar modelos"), se o modelo padrão não
serve (login revogado, provedor sem chave), os modelos novos assumem o lugar; um padrão que funciona nunca muda. Nas listas
de Ollama e LM Studio, modelos de embedding (`bge-m3`, `all-minilm`, `nomic-embed-text`…) não são escolhidos como padrão.
Nos primeiros segundos de cada abertura, enquanto o app confere as conexões (Keychain, ChatGPT, `claude auth status`), o
cartão e o banner de "Conecte um modelo" não aparecem e Return no compositor espera a conferência em vez de recusar.
Depois dela, o cartão e o banner só aparecem se nem o modelo do Orb nem o padrão servem (conectar pelo cartão define o padrão); um Orb cujo modelo próprio caiu, com o padrão funcionando, recebe o aviso para trocar em Ajustes.

## A tela de boas-vindas

Sem nenhum Orb na lista (se você apagou todos), a janela mostra a **tela de boas-vindas** em vez de um chat vazio: três Orbs que
piscam e olham para o ponteiro, o que o app faz em três pontos ("Conversa e faz", "Pede antes de agir", "Lembra de você") e o
caminho mais curto até o primeiro Orb. Sem modelo conectado, o cartão "Primeiro, conecte um modelo" aparece ali mesmo (os
mesmos caminhos do primeiro uso). Se o **Claude Code** já está instalado e com login, o cartão dá lugar a um botão só,
**Usar meu Claude Code e começar** (com a conta que ele achou, por exemplo "Claude Max"): um clique conecta, cria o Atlas e
abre a conversa com ele. As outras formas ficam em "Outras formas de conectar", fechadas. Nos primeiros segundos a tela só
guarda o lugar da ação (o app confere as conexões e procura o Claude Code), então o botão nunca aparece e some. Havendo
memórias guardadas, o botão só conecta e a tela segue para elas. Com um modelo pronto, são duas opções:

- **Criar meu primeiro Orb** (⌘N, ou Return): abre a folha Novo Orb.
- **Começar com o Atlas**: cria o Atlas na hora, pronto para usar, com uma pasta própria em `~/Orbs`.

Com [memórias guardadas](#memória) de Orbs apagados, um cartão "Começar de uma memória guardada" lista as três mais novas
("Continuar" abre a folha Novo Orb já com a memória escolhida; "Ver todas" mostra a lista completa). Depois de criar um Orb
e apagar todos, o título vira "Hora de um Orb novo". A barra lateral mostra "Criar seu primeiro Orb" onde os Orbs ficam, e o
clique nela traz a tela de volta (e "Novo Orb" no pé da barra lateral só aparece quando há Orbs: sem eles, a linha
"Criar seu primeiro Orb" é o caminho; o ⌘N continua valendo). Com Orbs, o app sempre abre em um deles ("Escolha um Orb" deixou de existir). Sob os botões,
"Importar de outro assistente" abre a folha Novo Orb já no painel de [importação](#criar-um-orb).

## A janela

A **barra lateral** tem os seus Orbs, o **Espaço de trabalho** (Rotinas, Conectores, Skills), **Novo Orb** (só com Orbs na lista) e **Ajustes**. Uma
linha mostra o que o Orb está fazendo ("Pensando…"), "Precisa de você" quando ele espera uma permissão e um ponto quando há
mensagens não lidas; um anel em volta do rosto diz o mesmo de relance (azul trabalhando, âmbar esperando você). O título da
janela traz, sob o nome do Orb, o que ele está fazendo, ou o modelo quando está livre. O botão direito abre o menu do Orb (abrir pasta, personalizar, ver
rotinas, apagar). No meio fica o chat; à direita, o painel do Orb.

No canto inferior esquerdo da barra lateral fica a **sua foto** (um círculo; sem foto, a inicial do seu nome ou uma silhueta):
um clique abre **Ajustes → Geral → Você**, onde você diz **Nome**, **Como te chamar** e um texto **Sobre você** (até 400
caracteres) e escolhe ou arrasta (só arquivos do seu Mac) uma **foto**. O Orb recorta a foto em quadrado, reduz e guarda no seu Mac. Todos os Orbs leem o
nome, como te chamar e o texto em cada conversa (assim eles sabem como te chamar sem perguntar); a foto nunca sai do Mac.

## Criar um Orb

**⌘N** (ou "Novo Orb" na barra lateral):

- **Começar de** (só aparece quando há [memórias guardadas](#memória)): "Nenhuma (Orb novo)" ou a memória de um Orb que você
  apagou ou redefiniu; escolher uma preenche nome, papel e aparência e dá ao novo Orb o que o antigo aprendeu.
  Logo abaixo (sempre, com ou sem memórias guardadas) fica **Importar de outro assistente**; os dois se excluem.
- **Nome** e **Papel** (o papel é uma frase de quem ele é: "Cuida da minha agenda").
- **Inteligência**: o modelo deste Orb (ou o padrão do app).
- **Pasta**: por padrão cada Orb ganha **uma pasta só dele**, `~/Orbs/<Nome>` (se o nome já existe, `~/Orbs/<Nome> 2`). É a
  base de trabalho dele e onde ele escreve **sem perguntar** quando está em "Perguntar antes". Em "Mudar…" dá para escolher
  outra pasta, usar a pasta pessoal ou criar a própria depois. A pasta **não confina** o Orb: ele continua podendo ler e agir
  no resto do Mac dentro das permissões. Apagar o Orb não apaga a pasta.
- **Opções avançadas**: as permissões (veja abaixo), "Como funciona" (as instruções dele, que vão em toda conversa) e
  "Na primeira conversa, me fazer perguntas" (ligado por padrão: o Orb conhece você).
- O **editor de aparência** ao lado: Cor (18), Jeito (calmo, equilibrado, animado, tímido, curioso: como ele se mexe e reage
  ao mouse, não o que faz), Olhos, Boca, Sobrancelhas, Bochechas, Bigode, Cabelo e Acessórios (vários ao mesmo tempo), com
  **Sortear**. Os olhos seguem o cursor; o Orb mostra o que está fazendo (pensando, digitando no terminal, lendo, precisando de
  você, feliz ao terminar) e "fala" enquanto a resposta chega.

O **painel do Orb** (⌥⌘B mostra ou esconde) tem quatro abas:

| Aba | O que tem |
|---|---|
| Geral | modelo, **Permissões** (modo) e "O que `<Orb>` pode usar" (as chaves: Terminal e arquivos, Navegar na web, Controlar apps do Mac, Conectores), "Apagar…" |
| Memória | o que o Orb sabe de você (veja [Memória](#memória)) |
| Pasta e acessos | a pasta (abrir no Finder ou no Terminal, mudar, recriar se sumiu), "Confiar nas instruções desta pasta", as **Liberações** e os arquivos alterados e recentes |
| Rotinas | as rotinas deste Orb: ativar e pausar, editar, apagar, rodar agora (veja [Rotinas](#rotinas)) |

No alto do painel: nome e papel (clique para editar; mudar o nome não renomeia a pasta), "Personalizar…" (aparência), "Pasta"
e "Terminal". O painel se recolhe sozinho em janelas estreitas (menos de 1180 pt) e volta quando há espaço.

As chaves de "O que pode usar" desligam grupos inteiros de ferramentas para aquele Orb: sem **Terminal e arquivos** ele não roda
comandos nem lê, escreve, procura ou apaga arquivos; sem **Navegar na web** não lê nem pesquisa páginas, não usa o navegador do Orb (nem baixa arquivos com `save_to`, que também precisa de **Terminal e arquivos**); sem **Controlar apps do Mac** não usa
AppleScript, Atalhos, área de transferência, captura de tela nem controla outros apps; sem **Conectores** não usa os conectores.

### Navegador

**Navegar na web** dá ao Orb três coisas: ler páginas (`web_fetch`), pesquisar (`web_search`) e, com um navegador instalado, **usar um navegador de verdade** em segundo plano (`browse_open`, `browse_snapshot`, `browse_click`, `browse_fill`, `browse_read`, `browse_screenshot`…). Funciona com qualquer modelo. O navegador é do Orb: abre páginas com JavaScript, clica, preenche formulários e **guarda os logins entre uma conversa e outra** (uma pasta de perfil por Orb, em `navegador/` na pasta de dados). Quem dirige é o [agent-browser](https://github.com/vercel-labs/agent-browser). **Você instala os navegadores em Ajustes → Navegador, com um botão**: não precisa de Homebrew, de Node nem de Terminal, e o Orb nunca roda nada com `sudo`.

Cada Orb escolhe o motor (padrão **Chrome**, também nos Orbs que já tinham "Navegar na web"). A escolha fica no painel do Orb, aba **Geral**, logo abaixo da chave **Navegar na web**: dois seletores, **Navegador** (com a descrição de cada motor) e **Pesquisa**, cada um com o estado na hora ("Pronto", ou "Não instalado: falta Chrome" com o botão **Instalar em Ajustes**; TinyFish sem chave diz "Sem chave" e leva a **Adicionar em Ajustes**). Trocar de motor fecha o navegador que o Orb tinha aberto (o perfil e os logins ficam):

| Motor | O que é | O que o botão Instalar baixa |
|---|---|---|
| **Leitura simples** | só `web_fetch`: sem JavaScript, sem login | nada |
| **Chrome** | Chrome for Testing dirigido pelo agent-browser; logins guardados | o agent-browser (15 MB) e o Chrome for Testing (cerca de 180 MB, pelo próprio `agent-browser install`) |
| **Obscura** | [motor leve em Rust](https://github.com/h4ckf0r0day/obscura) com JavaScript, na versão `stealth`; sem perfil guardado e sem janela | o agent-browser e o Obscura (70 MB) |
| **CloakBrowser** | [Chromium modificado](https://github.com/CloakHQ/CloakBrowser) para não parecer automação; o Orb o usa pelo agent-browser, com a mesma identidade a cada vez | o agent-browser e o pacote Python do CloakBrowser num ambiente virtual só dele, que baixa o Chromium (cerca de 140 MB) |

**Instalação.** Em **Ajustes → Navegador** há uma linha por motor, com o estado (não instalado, instalando com a barra e os megabytes, instalado com as versões), **Instalar**, **Cancelar**, **Atualizar** (quando há versão mais nova; o app olha no máximo uma vez por dia) e **Remover…** (que pergunta se os logins dos Orbs também saem). Tudo vai para `navegador/` na pasta de dados do Orb, nada fora dela: `bin/` (agent-browser e Obscura), `chrome/`, `cloak/`, `instalados.json` (versão de cada peça), `agent-browser.json` (a configuração vazia do app) e `sessoes/` (com que opções cada navegador foi lançado). O agent-browser e o Obscura vêm das versões publicadas no GitHub, para o Mac certo (Apple silicon ou Intel), com o SHA-256 conferido contra o que o GitHub publica; o que falha na conferência não é instalado, e uma versão que não publica soma nenhuma é instalada **sem se passar por conferida**: a linha do motor em Ajustes mostra "(sem soma de verificação)" ao lado dela. Os downloads só seguem redirecionamentos para `https`, e o pacote do Obscura só pode trazer `obscura` e `obscura-worker` como **arquivos comuns** (atalho ou link no pacote cancela a instalação). O CloakBrowser é instalado na versão do pacote com que o app foi testado (`cloakbrowser==0.6.0`, gravada em `instalados.json`), e uma versão mais nova só aparece quando um app mais novo trouxer outra. A instalação é atômica: baixa numa pasta de trabalho, confere, testa se abre e só então troca o que já existia, então cancelar ou falhar deixa tudo como estava (o CloakBrowser antigo fica de lado até o novo abrir no lugar dele e ser gravado em `instalados.json`; se não abrir, o antigo volta). Remover o Obscura ou o CloakBrowser não leva o agent-browser embora enquanto o motor Chrome puder funcionar (um Chrome do app, ou um Chrome do Mac que o agent-browser encontra). A procura por versões novas fica gravada mesmo quando parte dela falha (no máximo uma rodada de consultas por dia, e o limite do GitHub para a rodada na hora). Os erros dizem o que fazer (sem rede, disco cheio, soma que não confere, sem Python). Um Chrome ou um agent-browser que você já tinha (Homebrew, npm, Applications) continua valendo, mas o instalado pelo Orb tem preferência.

O CloakBrowser precisa de Python 3.9 ou mais novo: o do macOS (`/usr/bin/python3`) só funciona depois de instalar as Ferramentas de Linha de Comando do Xcode (`xcode-select --install`, no Terminal, uma vez); o app avisa se faltar. O binário grátis dele (Chromium 145) não pede conta nem chave; uma chave grátis em cloakbrowser.dev/free dá o Chromium mais novo, e é opcional.

Se o motor escolhido não estiver instalado, o Orb fica só com `web_fetch` e `web_search`, e **avisa uma vez** para instalar em Ajustes → Navegador. As ferramentas do navegador só aparecem quando o motor está pronto. Ao sair do app, ao trocar o motor de um Orb, ao desligar "Navegar na web", ao apagar o Orb e ao atualizar ou remover um motor em Ajustes, os navegadores abertos são fechados (nenhum Chrome fica para trás), **inclusive os que uma execução anterior do app deixou** (fecham pelo nome da sessão do Orb, `orb-<id>-<motor>`); um navegador esquecido por 30 minutos se fecha sozinho. Um comando que não é `browse_open` **nunca inicia um navegador**: se o processo em segundo plano do Orb morreu (30 minutos parado, `browse_close` em outro turno, troca de motor no meio de um turno), `browse_snapshot`, `browse_read` e os outros respondem que não há página e pedem `browse_open` (que lança o navegador com o perfil e as opções do Orb); e uma sessão que ficou rodando com outras opções (uma versão antiga do app, outro perfil) é fechada antes de a página abrir. O agent-browser roda com um arquivo de configuração vazio do app e dentro de `navegador/` (nada de `~/.agent-browser/config.json` nem de `./agent-browser.json` da pasta pessoal) e sem as variáveis `AGENT_BROWSER_*` do seu shell; os proxies do shell de login (`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`) continuam valendo, para quem precisa deles.

**Pesquisa.** A chave do TinyFish (grátis, sem cartão: agent.tinyfish.ai/api-keys) também se guarda em Ajustes → Navegador. `web_search` devolve títulos, endereços e trechos. O provedor é uma escolha do Orb: **DuckDuckGo** (padrão, sem conta; pelo navegador do Orb ou, no motor Leitura simples, pela página simples dele), **Google** (sempre pelo navegador do Orb, nunca por API; sem navegador cai no DuckDuckGo e o resultado diz isso) ou **TinyFish** (API com cota gratuita; precisa da sua chave, guardada no Keychain, uma para o app todo). Se o TinyFish recusar a chave, acabar a cota do dia ou limitar o ritmo, a busca vai para o DuckDuckGo e o resultado avisa; nada é cobrado nem tentado de novo em plano pago.

**Quando é com você.** Login, código de verificação (2FA), captcha, aviso de cookies que bloqueia ou qualquer coisa que só uma pessoa faz: o Orb **não tenta resolver nem digita senha ou número de cartão** (campos de senha são recusados). Ele chama `browse_show`, que reabre a mesma sessão numa janela visível e põe um **cartão no chat**: "Atlas abriu o navegador para você", com **Pronto** (⌘↩) e **Cancelar** (esc). O turno **espera** como espera uma permissão ("Esperando sua resposta"; o Orb fica em "precisa de você" na barra lateral e na barra de menus, e chega o aviso do macOS com os mesmos dois botões). Você faz o que falta na janela e clica em Pronto: a ferramenta devolve sucesso, a janela fica aberta e o Orb continua tirando um `browse_snapshot` novo. Cancelar fecha a janela e diz ao Orb que você recusou (ele não insiste). Parar (⌘.) cancela o cartão como cancela qualquer pedido, e trocar o modo de permissão **não** responde por você. O motor Obscura não tem janela: nesse caso o Orb pede para você trocar de motor.

**Permissões.** Abrir uma página e pesquisar perguntam como `web_fetch` (Sempre permitir por site, ou "Pesquisar na web"); clicar, preencher, escolher e apertar teclas perguntam no Perguntar antes (`browse_press` aperta só teclas com nome: Enter, Tab, Shift+Tab, Escape, setas, PageUp/PageDown, Home, End, Backspace, Delete e Space, nunca um caractere nem Control/Meta+V, e recusa qualquer tecla enquanto um campo de senha ou de cartão está em foco) e têm a sua própria liberação ("Clicar e preencher páginas no navegador do Orb"); olhar a página que já está aberta não pergunta. No **Só leitura** nada disso roda. As regras são do Orb, com qualquer modelo, e o cartão de `browse_show` ("Pronto / Cancelar") vem depois do pedido de permissão, quando o modo pergunta.

## Conversar

- **Escrever.** ↩ envia, ⇧↩ (ou ⌥↩) pula de linha. Digite `/` para ver as skills (↑↓ escolhem, ↩ ou ⇥ completam, Esc fecha).
- **Respostas** vêm em Markdown de verdade: títulos, listas (inclusive de tarefas), tabelas, citações e blocos de código com
  botão "Copiar". O Orb também **mostra imagens do seu Mac na resposta**: uma captura que ele tirou, um gráfico que gerou, uma
  imagem que você anexou (`![o que mostra](/caminho/da/imagem.png)` numa linha só; aparece inteira, com a legenda embaixo, e o
  clique abre no Quick Look). Endereço da web nunca é carregado: só arquivos que já estão no Mac. Passe o mouse sobre uma resposta para "Copiar" ou "Copiar como Markdown". Para copiar só um trecho, clique e arraste: a seleção atravessa parágrafos, títulos e listas da resposta (blocos de código e tabelas têm a sua).
- **Citar um trecho.** Com um trecho de uma resposta selecionado, **Citar** (ao lado de Copiar, ou no clique direito) põe o
  trecho no começo da sua mensagem como citação (`> …`), e o cursor vai para o campo. Na conversa, a citação aparece em cima
  do que você escreveu; um clique nela volta à resposta de onde veio, com o trecho marcado por um instante.
- **Hora na conversa.** Uma linha discreta ("Hoje, 14:05", "Ontem, 09:12", "Quinta-feira, 10:00", "3 de outubro, 14:05")
  marca o começo da conversa, cada dia novo e cada retomada depois de 15 minutos ou mais de silêncio.
- **Anexos.** O botão `+`, ⌘V ou soltar em qualquer ponto do chat (a conversa toda vira o alvo, sem abrir nada; vale também imagem arrastada direto do navegador) anexa. Imagens (PNG, JPEG, HEIC, GIF, WebP, TIFF; até 20 MB cada)
  são reduzidas (um chip "Preparando imagem…" aparece e o envio espera), entram na ordem em que foram anexadas (até 20 por mensagem) e são enviadas ao modelo se ele enxerga; se ele não enxerga, só o caminho vai e o app avisa. Outros arquivos
  vão com o texto deles dentro da mensagem, lido pelo app assim que são anexados: PDF, Word (.docx, .doc, .rtf, .odt), Excel (.xlsx e o .xls antigo, inclusive o que é página da web salva como .xls), PowerPoint (.pptx), CSV, Markdown, TXT, JSON e qualquer arquivo de texto. Assim qualquer Orb os lê, mesmo sem "Terminal e arquivos"; o que passa de uma página por arquivo (cerca de 24 mil caracteres, três páginas por mensagem, menos num modelo local de janela pequena) é cortado com a indicação de onde continuar, e o que não dá para ler aqui (zip, binários) segue só como caminho, para o Orb abrir com as ferramentas; um arquivo sozinho, sem texto, já pode ser enviado (o Orb recebe "Veja o(s) arquivo(s) anexado(s).") ou colocado na fila. A captura de tela que o Orb tira
  também chega a ele como imagem, quando o modelo enxerga.
  No chat, os anexos aparecem do mesmo jeito na mensagem enviada, na fila e no compositor: imagens numa grade de largura fixa
  (uma, duas ou três colunas; "+N" quando passam de nove) e arquivos como cartões com o ícone do tipo, o nome cortado no meio
  (a extensão fica à vista) e "PDF · 2,1 MB". Arquivo que sumiu ou anexo antigo, que guardou só o nome, aparecem como tal.
  Clicar abre o Quick Look (← e → passam de um anexo para o outro); o botão direito oferece Abrir, Mostrar no Finder, Copiar e Copiar
  caminho; dá para arrastar o arquivo para fora. O que o Orb cria ou altera com as ferramentas de arquivo (e as capturas de
  tela dele) aparece sob a linha da ferramenta, como cartão "novo" ou "alterado" ou como miniatura ("Captura", quando é o que
  ele viu na tela ou na página), uma vez só por turno. As capturas ficam ali, recolhidas com as ações; a que importa para
  você ele põe na resposta.
  Quando um trecho de ações recolhido tirou duas ou mais capturas (no navegador ou num app do Mac), ele mostra uma tira com
  todas, em ordem, cada uma com o que a antecedeu ("Adicionar ao carrinho"); o clique abre o Quick Look, onde ← e → vão de
  passo em passo.
  Arquivos criados por comandos do Terminal não entram.
- **Ditar.** O microfone ao lado de Enviar (macOS 26 ou mais novo) abre o reconhecimento de fala do próprio Mac: grátis,
  sem internet e sem o áudio sair do Mac. O texto aparece no campo enquanto você fala, e a versão pontuada toma o lugar das
  palavras a cada trecho; clique de novo (ou Esc) para parar e revisar, ou dê ↩ para parar e enviar. Ao parar, o modelo do
  Orb (o menor do mesmo fabricante: Haiku no Claude Code) lê o texto com as últimas mensagens da conversa e os nomes dos Orbs
  e skills, e acerta pontuação, acentos e palavras ouvidas errado, sem resumir nem responder; o ↩ espera esse ajuste (alguns
  segundos) e Esc durante ele mantém o texto como foi ditado. Só o texto vai ao modelo, nunca o áudio, e o custo aparece em
  Uso como chamada auxiliar; desliga em Ajustes → Geral. Digitar no campo encerra o ditado. Na primeira vez o macOS pede o
  microfone e, se faltar, baixa o modelo de fala do idioma (uma vez só).
- **Escrever com o Orb trabalhando.** O compositor continua livre, com dois modos, e a dica sob o campo mostra as teclas:
  **↩ direciona** (a mensagem chega ao Orb no próximo passo da tarefa, sem interrompê-la), **⇥ põe na fila** (ela espera a
  tarefa terminar e segue como o próximo pedido; várias juntas, na ordem em que você enviou) e **⌘↩ para e envia agora** (leva
  as duas); com um pedido de permissão aberto, isso recusa o pedido (parar sempre recusa) e envia. O ⇥ só vale com o Orb
  trabalhando e algo no campo; com as sugestões de skill abertas ele completa a skill, como antes. Cada mensagem pendente
  diz para onde vai ("Entra no próximo passo", "Depois da tarefa"), e o balão tem ícones para editar, trocar o modo depois
  de enviada (relógio: pôr na fila; seta: direcionar) e parar e enviar; passar o mouse sobre um ícone diz o que ele faz na
  linha do balão. Parar e enviar também leva a mensagem que acabou de entrar na tarefa e ainda não teve resposta (ela sai
  da tarefa parada e vai como o novo pedido, sem repetir). Uma mensagem que entrou no meio da tarefa aparece no chat onde o Orb a recebeu, com a
  marca "Durante a tarefa" (guardada na conversa) e, enquanto o Orb ainda não agiu sobre ela, o botão "Parar e enviar" ao lado
  (o balão da fila some quando ela entra, muitas vezes em menos de um segundo). Parar sozinho (botão ou ⌘.) devolve essa
  mensagem ao campo, em vez de deixá-la numa tarefa que não vai respondê-la. Se o Orb espera sua
  resposta a um pedido, o que ia entrar no próximo passo só entra depois dela.
  Dá para tirar uma mensagem da espera ("Editar"). Se o turno falhar ou for parado, o que estava esperando (nos dois modos) volta para o campo. O que está no campo (texto, arquivos e imagens anexados) e o que voltou da fila ficam guardados em `rascunhos.json` ao fechar o app e voltam na próxima abertura (arquivos que sumiram ficam de fora).
- **Buscar na conversa.** **⌘F** (ou a lupa da barra do chat, ou "Buscar na conversa" em ⌘K) abre uma barra no alto do chat:
  digite e ela mostra "3 de 12", leva você à mensagem e marca o trecho. **↩** / **↓** / **⌘G** vão para o próximo resultado,
  **⇧↩** / **↑** / **⇧⌘G** para o anterior (dá a volta), o botão de lista mostra um trecho de cada resultado para escolher, e **Esc** fecha.
  Não importa maiúscula nem acento ("acao" acha "Ação"). A busca lê o texto guardado das mensagens (as suas, as do Orb, os avisos e a
  linha de cada ferramenta, não a saída delas), fora da thread principal e só depois de uma pausa na digitação; nenhuma mensagem é
  desenhada por causa dela, só a que você escolhe aparece (a lista de mensagens já desenha só as que estão à vista). Enquanto você
  olha um resultado, o chat não vai sozinho para o fim com a resposta que chega; enviar uma mensagem volta a seguir. Até 1000
  resultados aparecem ("3 de 1000+"). A resposta que ainda está sendo escrita fica de fora até terminar. VoiceOver lê "3 de 12 resultados".
- **Parar.** O botão Parar ou **⌘.**; o Orb avisa "Você interrompeu esta resposta". O que ele já tinha escrito fica na conversa,
  marcado "[resposta interrompida]", e o próximo pedido o leva em conta. Ler um PDF ou planilha longa, esperar um conector que
  demora a iniciar ou uma captura de tela travada também param na hora.
- **Refazer e Editar** (com o Orb parado). Passe o mouse sobre a **última resposta**: ao lado de "Copiar" há o botão
  **Refazer**, que descarta a resposta e tudo o que o pedido acrescentou (linhas de ferramenta, avisos) e faz o mesmo pedido de novo, como se
  fosse a primeira vez. Sobre **qualquer mensagem sua** aparece o lápis **Editar**: a mensagem (e os anexos que ainda existem) vai para o
  campo, sob a faixa "Editando mensagem · Esc cancela" (o Esc vale com o cursor no campo; com a lista de skills aberta ele fecha a lista
  primeiro; o botão "Cancelar" da faixa também desiste), e o que estava no campo espera e volta ao enviar ou cancelar. Qualquer outro envio
  que comece com a edição aberta (um "Continuar" de aviso, uma resposta da saudação, o painel da barra de menus) desiste da edição e
  devolve o que estava no campo; ⌘↩ "parar e enviar" fica desligado durante a edição. Ao enviar, a mensagem é
  trocada e **tudo o que veio depois sai da conversa** (do chat e do histórico do modelo); as linhas que saem esmaecem e o Orb responde a partir dali. Se o que sai inclui ações que podem ter mudado algo (arquivo gravado,
  comando que não é só de olhar), o app confirma antes: "Os passos depois desta mensagem saem da conversa; o que o Orb já fez no Mac não é
  desfeito." Conversa só de texto não pergunta. Os botões não aparecem com o Orb trabalhando, esperando permissão ou numa rotina; uma
  mensagem que já virou parte do resumo da conversa (depois de compactar) ou que entrou no meio de uma tarefa fica apagada, com o motivo na
  dica (para esta, edite o pedido que começou a tarefa; "Refazer" também pede isso se houve mensagens no meio). Cada mensagem sua guarda a
  ligação com a cópia que o modelo recebeu, então mensagens repetidas ("2", "sim") e pedidos que falharam antes de chegar ao modelo não
  se confundem; numa conversa de antes disso, a ligação é feita pelas palavras e, se não der para ter certeza, o botão fica apagado
  ("Não consegui ligar esta mensagem ao histórico do Orb"). O uso e o custo já registrados ficam como estão, e **o que já foi para a
  memória do Orb também continua lá** (a página da conversa, o que ele guardou com "lembre"): o corte não apaga memória, e o aviso de
  confirmação lembra disso quando o trecho que sai já foi guardado.
- **O que o Orb está fazendo.** Uma linha no fim da conversa, ao lado dele, diz o verbo e o alvo ("Rodando `swift build`",
  "Lendo README.md", "Procurando “TODO”", "Abrindo github.com") com o tempo do turno e, a partir da segunda ferramenta,
  quantas ações ele já fez ("16 s · 3 ações"). Entre um passo e outro ela diz "Pensando…". Quando espera por você, ela fica
  parada em laranja ("Esperando sua resposta"); quando espera para tentar de novo, mostra a contagem ("Conexão caiu ·
  tentando de novo", "em 8 s"). A barra lateral e o painel da barra de menus dizem a mesma coisa. As linhas de ferramenta
  acima dela são o histórico do turno: ações seguidas, sem nada dito entre elas (e os cartões de permissão já
  respondidos no meio delas), ficam numa linha só ("Rodou 7 comandos e leu 1 arquivo", com "1 falhou" se algo falhou e o
  tempo do conjunto) que abre com um clique; os arquivos que elas fizeram continuam à vista. Quando o pedido termina, o
  trabalho até a resposta (o que o Orb foi dizendo e as ações) vira uma linha ("Trabalhou por 1 min 05 s · rodou 11
  comandos e leu 1 arquivo") e a resposta fica à vista logo abaixo; avisos do meio do trabalho também. Enquanto ele
  trabalha, tudo fica aberto. A busca (⌘F) abre essas linhas quando o resultado está dentro. Cada frase fica ao menos 0,7 s na tela, e com o VoiceOver ligado ela é anunciada
  com educação (no máximo uma vez a cada 8 s). Com "Reduzir movimento" as frases só trocam de opacidade.
- **Quando algo dá errado**, a mensagem vem com a ação: "Tentar de novo" (reenvia, se nada tinha sido feito; se já tinha
  respondido, pede para continuar), "Continuar", "Abrir Ajustes" (chave inválida, sem modelo) ou, numa conversa grande demais, "Compactar
  e tentar de novo" (resume o começo e reenvia; só aparece quando há o que resumir). Limite de uso (429) e instabilidade do provedor são tentados de novo sozinhos algumas vezes, com a espera à vista (num limite de uso,
  esperas de 5, 15, 30 e 60 s antes de desistir). Um provedor que fica 10 min mandando só sinais de vida, sem texto, é dado como
  parado ("Provedor sem resposta") e tentado mais uma vez. Se a resposta cai no meio do texto, o Orb grava o que saiu e segue dali uma
  vez; se cair de novo, avisa "O provedor cortou a resposta no meio" e você pede "continua".
  **Outro modelo** refaz o pedido uma vez com o modelo padrão do app ou um dos usados há pouco, sem mudar o do Orb. A frase do
  aviso é do Orb; a mensagem do provedor fica recolhida em **Detalhes**. Uma resposta vazia ganha uma nova tentativa sozinha
  antes de virar falha.
- **Quando o Orb anda em círculos** (a mesma chamada com o mesmo resultado três vezes, ou três falhas seguidas), o próprio
  resultado avisa o modelo para mudar de caminho ou dizer o que o bloqueia, e a linha de trabalho mostra "Mudando de abordagem".
  É uma contagem, sem chamar outro modelo; horários, IDs e caminhos de saídas salvas não contam como diferença. Se isso se repete
  (9 voltas no mesmo turno), a conversa ganha um aviso, uma vez, e, se você não está olhando esse Orb, chega um banner com **Parar**.
  O Orb não para sozinho: a decisão é sua.
- **Tarefas longas.** Um turno não tem limite de passos, nem numa rotina, num pedido de outro Orb ou num grupo: o Orb trabalha
  até terminar ou até você parar (botão ou ⌘.). A partir de 50 mil tokens a linha de trabalho mostra o que o turno já gastou
  ("4 min · 30 ações · 180 mil tokens", com o valor em dólares quando o modelo é pago por uso e o preço é conhecido). Um pedido de
  outro Orb que passa de 3 h trabalhando gera um banner com **Parar**; ele não é encerrado sozinho.
- **Skills.** `/resumir`, `/organizar` e `/revisar` vêm prontas; veja [Conectores e skills](#conectores-e-skills).

## Permissões

Cada Orb tem um **modo** (botão no compositor, aba Geral do painel, ou ao criar). Ler e pesquisar não pergunta, em modo nenhum,
com duas exceções: **chaves e senhas** (`~/.ssh`, `~/.aws`, `.env`, `*.pem`…) perguntam até no Automático e são recusadas no Só
leitura; e comandos que só olham (`ls`, `git status`, `git log`, `cat`…) não pedem cartão no Perguntar antes e rodam no Só leitura.

| Modo | O que acontece |
|---|---|
| **Perguntar antes** (padrão) | O que muda algo, roda código, abre algo, acessa a web ou guarda memória **pede a sua aprovação**, a menos que você já tenha liberado aquilo ("Sempre permitir") ou seja escrita na pasta própria do Orb |
| **Automático** | Faz tudo sozinho, **menos** comandos destrutivos (`rm -rf`, `rm` de arquivo fora da pasta do Orb, `sudo`, `git push --force`, formatar disco…) e mudanças nas instruções dele (identidade e preferências da memória), que ainda perguntam |
| **Só leitura** | Só lê e pesquisa arquivos e apps do Mac e roda comandos que só olham (`ls`, `git status`, `git log`). Tudo o mais é recusado, **inclusive a web** (`web_fetch`, `web_search` e o navegador do Orb), **mesmo com "Sempre permitir"** |
| **Sem pedir permissão** | Nunca pergunta, nem os comandos destrutivos. Ligar exige uma confirmação ("Rodar sem pedir permissão?"). Use só com Orbs e pastas em que você confia |

### Cartões de aprovação

Quando o Orb precisa de você, aparece um cartão na conversa e o Orb espera ("Esperando sua resposta").

- **Permitir** (**⌘↩**) libera só aquela ação. **Não permitir** (**Esc**) nega e o Orb não tenta de novo. Os atalhos valem para o
  cartão mais novo do Orb aberto; o Esc não vale enquanto você digita. Um comando longo mostra o começo e as últimas
  linhas, com **Mostrar tudo (mais N linhas)** para o meio; um comando arriscado aparece sempre inteiro.
- **Dizer o que fazer em vez disso** nega e manda a sua instrução ao Orb ("use a lixeira").
- O menu ao lado de Permitir: **Só nesta tarefa** (até o Orb terminar) e **Sempre permitir…**, com até três regras de
  tamanhos diferentes (por exemplo "comandos `git push`", "comandos `git`", "gravar em `~/Projetos/app`", "acessar
  `exemplo.com`"). A regra fica salva no Orb.
- **Vários pedidos do mesmo passo viram um cartão só** ("4 ações precisam da sua permissão"): "Permitir as 4", "Revisar uma a
  uma" ou "Não permitir". Comandos perigosos nunca entram no grupo.
- **Comandos perigosos** (apagar em massa, `sudo`, forçar push, baixar e executar script, desligar o Mac, mexer em `~/.ssh` ou
  nos arquivos de inicialização do shell…) mostram um aviso de "Comando arriscado" e **sempre perguntam**, no Perguntar antes
  e no Automático, e nenhum "Sempre permitir" os cobre. (No "Só leitura" são recusados e no "Sem pedir permissão" não há pergunta.)
- Trocar o modo com cartões abertos responde a eles: "Sem pedir permissão" permite, "Só leitura" nega, "Automático" permite
  os que não são perigosos.
- **Pela notificação.** Se o app está em segundo plano, ou outro Orb está aberto, o pedido chega como banner com **Permitir** e
  **Não permitir**; nos perigosos, o Permitir exige desbloquear o Mac. A **barra de menus** lista os pedidos de todos os Orbs
  (um perigoso só se resolve no app) e a barra lateral marca o Orb que espera.
- **Pedido esquecido.** Um cartão sem resposta por 1 hora manda mais um aviso ("Esperando há 1 h"); depois de 24 horas o Orb
  para de esperar, interrompe a tarefa e diz na conversa por quê, para não prender o chat nem as rotinas da fila.

### Perguntas do Orb

No seu chat com ele, o Orb pode **perguntar** em vez de adivinhar: uma escolha que só você faz, um detalhe que ele não tem como
descobrir. A pergunta chega num cartão com as opções que ele sugeriu (um clique responde), uma linha para responder com as suas
palavras e **Pular** (**Esc**), que o deixa seguir com o que der para decidir sozinho. Escrever no campo de mensagem normal
também responde. Respondida, a pergunta fica na conversa com a sua resposta marcada. Rotinas e pedidos de outros Orbs não
perguntam: dizem no relatório o que falta.

### Liberações

Painel do Orb → **Pasta e acessos** → **Liberações** lista cada "Sempre permitir" ("Rodar comandos git", "Gravar em
~/Projetos/app", "Usar create_issue (github)"), com **Remover** e **Remover todas**. Valem no "Perguntar antes"; remover uma vale
já para a próxima ação do Orb, mesmo no meio de uma tarefa. O compositor mostra o número ao lado da mão (no modo padrão o chip é só o ícone; outro modo aparece por extenso).

### Instruções da pasta

Se a pasta do Orb tem um `ORB.md`, `AGENTS.md` ou `CLAUDE.md`, ele a lê como **material de referência**, não como ordem (qualquer pasta
baixada pode trazer um). Para valer como instruções, ligue **"Confiar nas instruções desta pasta"** na aba Pasta e acessos; se o
arquivo mudar depois, volta a ser só referência até você confiar de novo.

## Permissões do macOS

Ajustes (**⌘,**) → **Permissões** mostra o que o macOS já deixa o Orb fazer, com o estado de cada uma:

- **Essenciais**: Acessibilidade (ler e operar a interface de outros apps), Gravação do Áudio do Sistema e da Tela, Acesso Total ao Disco (é uma
  estimativa: o macOS não informa; o Orb tenta abrir uma pasta protegida) e **Notificações**.
- **Apps que o Orb controla** (Automação): Mail, Calendário, Notas, Lembretes, Finder, System Events, Mensagens, Safari e Música.

Cada linha mostra o estado (Liberado, Negado, Não pedido…) e o botão que resolve: **Pedir agora** (o macOS mostra o aviso dele),
**Abrir `<app>` e pedir** (Automação de um app fechado) ou **Abrir Ajustes do Sistema** (leva ao painel certo). A aba só olha,
atualiza quando você volta ao app (e a cada 2 s enquanto está aberta, para a chave virada em Ajustes do Sistema aparecer na hora) e tem
**Verificar de novo**. Gravação do Áudio do Sistema e da Tela e Acesso Total ao Disco só valem depois de **reabrir o Orb**.

Acessibilidade e Gravação do Áudio do Sistema e da Tela liberadas ganham **Testar**, que usa a permissão de verdade sem mexer em
nada: uma captura pequena da tela (nunca salva) e a leitura do Dock. O resultado é **Funcionando** ou o conserto: captura vazia
oferece **Reabrir o Orb**; Acessibilidade recusada apesar de liberada (sobra de uma compilação antiga) pede para remover o Orb da
lista e adicionar de novo. Depois de "Pedir agora" ou de ir aos Ajustes do Sistema pela gravação de tela, a linha também oferece
**Reabrir o Orb** em vez de pedir de novo.

- Antes de rodar um AppleScript, o Orb mostra o aviso de Automação dos apps que o script usa e espera você responder (um app
  conhecido que está fechado é aberto escondido antes, para o aviso não cair dentro do tempo do script). App recusado falha na hora.
- No **Automático**, enviar e-mail ou mensagem por AppleScript (ou apertar Return no WhatsApp/Telegram…), apagar vários itens de
  uma vez e abrir scripts, instaladores ou links que rodam Atalhos perguntam antes, como os outros comandos perigosos.
- O Orb recebe receitas curtas para as tarefas comuns do Mac (datas sem depender do idioma, rascunho no Mail, Lembretes, Notas,
  Calendário, Música) e conselhos para os erros típicos do AppleScript.
- No painel do Orb, a chave "Controlar apps do Mac" ligada traz o atalho **Permissões**.
- Quando uma ferramenta falha por falta de permissão, o Orb não tenta de novo: diz o que ligar e onde, e a linha da ferramenta
  ganha o botão **Permitir…** (pede ao macOS ou abre o painel certo).
- As permissões valem para esta cópia do app; veja [Assinatura estável](../README.md#assinatura-estável-recomendado).

### Apps em segundo plano

Com "Controlar apps do Mac" ligado e a Acessibilidade liberada, o Orb opera outros apps **sem tomar a sua tela**: você continua
usando o Mac e o app da frente, o foco e o cursor ficam onde estavam.

- **O que funciona em segundo plano**: ler a interface do app (mesmo coberto, em outro Espaço ou minimizado), apertar botões,
  preencher campos, digitar, atalhos de teclado (pelo menu do app), escolher itens de menu, selecionar linhas, rolar e clicar em
  um ponto da janela quando o app aceita o primeiro clique. A captura de tela vem da própria janela, também quando está coberta.
  Se um app não responde no prazo, o Orb diz isso e **não** faz depois o que tinha pedido (nada de clique atrasado); um
  Parar no meio de um clique sempre solta o botão. Em tabelas muito longas, escolher uma linha pelo texto olha as primeiras
  500 e diz até onde olhou; o Orb então usa a busca (`query`) da leitura.
- **O cartão "Usar a tela"**: o que só funciona com o mouse e o teclado de verdade (arrastar e soltar, menus de contexto, passar o
  mouse, apps sem Acessibilidade) o Orb **pede** antes. Você aprova o cartão (ele lista as etapas), o Orb traz o app para a frente
  por até 10 s, faz o que precisa e **devolve** o app que estava na frente, a janela e o cursor. Um aviso "Orb está usando a tela
  — mexa o mouse para parar" fica na tela; mexer o mouse interrompe. Só um Orb usa a tela por vez, em todo o Mac. Em "Só leitura"
  o Orb não assume a tela.
- **Limites conhecidos**: arrastar e soltar só vale assumindo a tela; apps que desenham tudo num canvas (jogos, alguns editores)
  não expõem elementos, então o Orb olha a captura e precisa de coordenadas; popups e menus de contexto abertos aparecem à parte
  e pedem a tela; menus dinâmicos (Recentes, Janela, Serviços) só se preenchem abertos; apps travados respondem "não respondeu"
  em poucos segundos em vez de segurar o Orb; conteúdo de páginas web vai para o navegador do Orb, não para a leitura de interface.
- **macOS 15 e Gravação de Tela**: o macOS volta a pedir a confirmação de Gravação da Tela de tempos em tempos. Sem ela o Orb ainda
  lê a interface e usa a legenda numerada, só não vê a imagem; confirme em Ajustes do Sistema → Privacidade e Segurança →
  Gravação de Tela e reabra o Orb se a captura voltar a falhar.

## Memória

Cada Orb tem a **sua** memória, que nasce com ele e cresce a cada conversa: nada é compartilhado entre Orbs. São arquivos
`.md` em `~/Library/Application Support/Orb/memoria/<id do Orb>/` (dá para abrir no Obsidian).

| O que guarda | Exemplo |
|---|---|
| **Identidade** (como ele deve funcionar) | "Seja direto e me lembre de fazer pausas" |
| **Preferências** | "Respostas curtas, em português" |
| **Fatos** | "Moro em São Paulo; meu cachorro é o Thor" |
| **Procedimentos** | "Para publicar: rode os testes e depois o script de deploy" |
| **Resumos de conversas** | um resumo de cada trecho de conversa (pedidos, decisões, o que foi feito, pendências) |

- **Pedir para guardar.** Diga "memorize que…", "lembra que…", "guarda na memória…", "anota aí que…" ou "não esquece que…".
  O pedido vale como a sua aprovação para fatos e procedimentos; identidade e preferências ainda pedem o cartão. Se o
  Orb não guardar, o app guarda o que você disse e avisa na conversa, com "Ver na memória" para abrir a página (e esquecê-la, se
  o pedido foi entendido errado). Se você negou o cartão, o app respeita o "não". "Memorize isso" sozinho guarda o que veio antes.
- **Primeira conversa.** Ao nascer, o Orb cumprimenta no chat com o próprio nome (texto do app, sem gastar o modelo; vindo de
  memória guardada, "Que bom te ver de novo!") e oferece três respostas rápidas: "Vou te contar o que preciso" (começa a
  mensagem para você), "Me entreviste" e "O que você sabe fazer?". Elas somem ao escolher uma ou ao começar a escrever. Com a
  entrevista ligada, ele faz 2 a 4 perguntas; uma conversa nova e vazia também oferece "Me conheça". Na aba Memória, o
  menu "Mais opções" tem "Fazer a entrevista de novo".
- **A aba Memória** do painel mostra as páginas por tipo (com busca, quando há muitas). **Editar…** muda a identidade.
  **Esquecer** apaga uma página; um aviso "`<Orb>` esqueceu isso" com **Desfazer** (ou **⌘Z**) fica por cerca de 10 segundos.
  **Abrir pasta da memória** mostra os arquivos.
- **O que ele usa.** Identidade e preferências vão em toda conversa. O resto ele busca quando precisa (ferramenta `recall`) e
  lembranças ligadas à sua mensagem chegam sozinhas. Ao começar uma conversa nova, ele sabe "onde vocês pararam".
- **Segredos não entram.** Chaves de API, tokens, senhas em URLs e variáveis do tipo `SENHA=…` são removidos antes de qualquer
  coisa ser gravada.
- **O tempo.** Conversas antigas (mais de 30 dias e pouco usadas) são compactadas, nunca apagadas sozinhas. Só você apaga.
- **Ao apagar um Orb**, o diálogo mostra o que some (a conversa, as rotinas) e o que fica (a pasta), e
  oferece **Apagar e guardar a memória** (o botão principal: a memória vai para `memoria/_guardadas/<nome> – <data>`, com
  "Mostrar no Finder") ou **Apagar com a memória**. Ajustes → Geral → "Memórias guardadas" diz quantas há e abre essa pasta.
  Junto da memória fica um pequeno `perfil.json` com o nome, o papel e a aparência do Orb (nunca permissões, modo ou segredos).
- **Começar de uma memória guardada.** Em **Novo Orb**, quando há memórias guardadas, o primeiro cartão ("Começar de") tem um
  menu **Memória**: "Nenhuma (Orb novo)" ou uma por memória ("Atlas · 08/10/2026 · 12 lembranças"). Escolher uma preenche o
  nome, o papel e a aparência (dá para mudar; voltar a "Nenhuma" desfaz o que a memória trouxe e mantém o que você digitou). Ao criar, a pasta guardada **é movida** para ser a memória do novo Orb (ela sai
  das guardadas) e, como já tem identidade ou preferências, ele não refaz a entrevista. Pastas guardadas antes dos perfis
  também aparecem; delas só vem o nome.
- **Importar de outro assistente.** Em **Novo Orb** → "Começar de" → "Importar de outro assistente" (também por ⌘K, "Importar
  de outro assistente…", e pelo link da tela de boas-vindas). O formulário dá lugar a um painel de três passos, ainda dentro da
  folha: **1.** "Copiar prompt" (o texto pronto, em "Ver o prompt") para colar no ChatGPT, Gemini, Claude, Copilot ou no GPT,
  Gem ou Projeto que já conhece você; **2.** colar a resposta, "Escolher arquivo…" ou soltar um arquivo ou pasta (a leitura
  é automática, sem botão "Analisar"; em "Neste Mac" aparecem, só se existirem, `~/.hermes` e `~/.openclaw/workspace`, e nada
  é lido antes do "Ler"); **3.** a **prévia**, com o texto inteiro e uma caixa de seleção por item, em grupos: "Como funciona",
  "Preferências", "Sobre você", "Procedimentos" e "Skills" (com "Ver"); quando fica pronta, a prévia rola até a vista, mesmo
  numa janela baixa. O que parece dar ordens ao Orb ("ignore as instruções",
  "sem pedir permissão", `sudo`, `rm -rf`, "envie para"…) vem **desmarcado** e marcado "Revise: parece dar ordens ao Orb".
  Apagar o texto colado tira a prévia que veio dele (a de um arquivo ou pasta fica). Subtítulos dentro de "Sobre você" ou
  "Preferências" não viram itens, e texto solto em "Procedimentos" vira um procedimento só. Um cartão JSON colado dentro de um
  bloco de código também é lido.
  Texto colado sem títulos pergunta "Isto é: Instruções do assistente | Lembranças sobre você". "Usar esta importação" volta ao
  formulário, que mostra "ChatGPT · 1 instrução, 9 lembranças, 2 skills" com **Revisar** e **Remover** (nome e papel que vieram
  da importação só entram em campos vazios, e "Remover" os tira se você não os mudou). Nada é criado até **Criar Orb**.
  - *O que se lê.* O "Cartão do Orb" (Markdown, o formato do prompt, mesmo dentro de um bloco de código ou com conversa em
    volta, com títulos em inglês também), **Character Card** em JSON (V1, V2 e V3: só persona e lorebook ativo), uma **pasta
    do Hermes ou do OpenClaw** (só `SOUL.md`, `IDENTITY.md`, `USER.md`, `MEMORY.md`, `AGENTS.md`, `memories/` e
    `skills/**/SKILL.md`, sem abrir `.env`, `auth.json`, `config.yaml`, sessões, logs nem rotinas, sem seguir links, pulando as
    skills que vieram com o app ou de um hub) e texto livre. O `conversations.json` do ChatGPT e cartões em PNG são
    reconhecidos e recusados com orientação; arquivos acima de 1 MB também.
  - *O que entra.* Só nome, papel, identidade, preferências, fatos, procedimentos e skills; **nunca** permissões, modo,
    capacidades, pasta, modelo, conectores nem rotinas, mesmo que o arquivo traga esses campos. Chaves e senhas são removidas.
    A identidade vai até 1.500 caracteres no prompt; quando o texto é maior, ele inteiro também vira fatos de até 2.000
    caracteres ("Instruções completas de ChatGPT (1/3)"…), que o Orb consulta quando precisa. Lê-se até 6.000 caracteres de
    instruções; o que passa disso fica de fora e a prévia diz quanto. Preferências até 40, 240
    caracteres cada e 1.500 no total (o resto também vira fato); até 60 fatos, 12 procedimentos e 5 skills, que valem só para o
    Orb novo e só rodam quando você digita `/comando`. A entrevista da primeira conversa deixa de ser pedida quando entra
    identidade ou preferências, e o Orb novo continua se apresentando como sempre; a conversa ganha antes uma linha "Importei
    de ChatGPT: 1 instrução, 9 lembranças e 2 skills. Veja na aba Memória." O que a importação traz de "Sobre você" fica na
    memória do Orb novo (o perfil de Ajustes → Você é seu e não é tocado).
  - *Nada sai do Mac.* Importar não faz rede: lê o que você colou ou escolheu, e o resultado vai para a memória local.
  Na aba **Marketplace do Grok Bot**, em vez do prompt, uma galeria com os bots do marketplace do Grok Bot
  (x.ai/bot/marketplace): busca por nome, assunto ou autor, as categorias do marketplace ("Do time do Grok Bot", "Marketing",
  "Vendas"…) e um clique no bot lê a página dele para a mesma prévia (instruções, memórias, skills; as rotinas viram
  procedimentos para ler e as integrações um lembrete). Também dá para colar o link de um bot ou do botão Add. A lista é lida
  uma vez e guardada por 15 minutos.
- No **Claude Code** a memória é a mesma: `remember` e `recall` rodam no Orb, e o `claude` não guarda histórico (a conversa vai
  num arquivo temporário que é apagado ao fim do turno), então "Esquecer" no Orb não deixa cópia nele.

Detalhes: [docs/MEMORIA.md](MEMORIA.md).

## Conversas e rotinas

### Conversas

Cada Orb tem **uma conversa só**, que nunca some: tudo o que vocês disseram, as anotações e os avisos ficam nela, em ordem.
Quando ela cresce, o começo vira um resumo para o modelo (veja [Contexto da conversa](#contexto-da-conversa)), mas as mensagens continuam
no chat para você ler e buscar (⌘F). Conversas guardadas por versões antigas do Orb (o antigo "Nova conversa") voltam para
dentro dela na primeira abertura, na ordem em que aconteceram.

### Rotinas

Uma **rotina** é uma tarefa que um Orb faz sozinho, no horário, **enquanto o app está aberto** (página **Rotinas**,
⌥⌘R; também na aba Rotinas do painel). Há modelos prontos: "Resumo da manhã", "Organizar arquivos", "Revisar a semana" e
a meta "Mesa em ordem". O chat vazio de um Orb sem rotinas também sugere uma ou duas ideias marcadas "Cria uma rotina" ou
"Cria uma meta": o clique abre o editor já preenchido, e nada é criado antes de você salvar.
Sem nenhum Orb, "Nova rotina" e os modelos continuam valendo: com um modelo conectado o app cria o Atlas (como "Começar com o
Atlas") e abre o editor para ele, sem sair de Rotinas; sem modelo, abre a tela de boas-vindas no cartão que conecta um, com um
aviso dizendo por quê.

- **Quando**: todo dia, toda semana (com o dia), a cada X horas ou a cada X minutos (no mínimo 15); o editor mostra a próxima
  execução.
- **Mac acordado.** Com alguma rotina ligada, o app avisa o macOS para não colocá-lo em App Nap (os horários não atrasam com a
  janela fechada); durante uma execução, o Mac também não entra em repouso sozinho. Enquanto a execução espera uma
  aprovação sua, o Mac volta a poder dormir. Terminada a execução, ou sem rotinas ligadas, o app não pede nada.
- **Peça no chat.** "Verifique meus e-mails a cada 30 minutos" ou "todo dia às 9h me mande um resumo das notícias": o Orb cria a
  rotina sozinho (ferramenta `schedule`) e também lista, pausa, retoma e apaga as dele quando você pede. Nada
  disso passa em branco: em "Perguntar antes" o cartão mostra o nome, quando roda e o que será pedido; em "Só leitura" só dá
  para listar. A rotina roda no modo do próprio Orb (nunca num mais permissivo), cada Orb tem no máximo 20 e só mexe nas suas, e
  uma rotina em execução não cria outras. A nova aparece na aba Rotinas do painel (que abre sozinha se estiver à vista), com um
  destaque suave; ali cada uma tem o interruptor Ativa/Pausada e o botão de apagar (com confirmação na própria linha).
- **Conversa própria.** Cada rotina roda numa conversa só dela, nunca no seu chat: o chat ganha só uma linha no fim ("Rotina
  'Resumo da manhã' terminou: …"). Em **Ver conversa** você lê a execução. Fica o histórico das últimas 10 execuções, com
  relatório, e a próxima execução sabe o que a anterior encontrou.
- **Metas.** No editor, "Acompanhar uma meta" pede "como saber que deu certo". A cada execução o Orb confere onde a meta
  está, dá um pequeno passo só se for seguro e reversível, e termina o relatório com uma linha como
  `Progresso: 35% · em dia · faltam 26 arquivos` ("em dia", "atenção" ou "concluída"). O cartão mostra uma barra fina (azul,
  laranja com uma bandeira quando pede atenção, verde quando concluída) e o histórico vira a linha do tempo da meta. Sem a
  linha, o progresso fica como estava; meta concluída pausa a rotina e o chat avisa. O Orb também cria rotinas com meta pela
  ferramenta `schedule` (campo `goal`).
- **Relatório em arquivo.** Se o Orb tem pasta própria, cada execução grava `Rotinas/<nome>/<aaaa-mm-dd hhmm>.md` nela.
- **Permissões.** Ninguém está lá para responder, então uma rotina em "Perguntar antes" **espera por você** (o editor avisa e
  oferece "Usar Automático" e "Usar Só leitura"). Em Avançado: "Permissões da rotina" (Igual ao Orb, Automático ou Só leitura).
- Se o Orb está ocupado, a rotina entra na fila ("Na fila") e roda quando ele terminar. "Rodar agora" e "Rodar uma vez
  agora, para testar" ao criar. O mesmo vale para "Rodar agora" no painel do Orb. Rotina desativada fica "Pausada".
- **Pedir a outro Orb.** Uma rotina que pede algo a outro Orb (`orbs ask`) espera a resposta: a execução segue na conversa
  dela quando a resposta chega, e só então entra no histórico, com o relatório final (o banner também espera). Seu chat não ganha
  turno com isso. Enquanto ela espera, o próximo horário não dispara outra execução. Se você para a conversa entre Orbs, ou se o
  app fecha antes da resposta, a execução termina como falha, com o motivo. Rotinas não acionam grupos.

## Orbs juntos

Com **Orbs podem conversar entre si** ligado em Ajustes → Geral, um Orb pede ajuda a outro sozinho, com a ferramenta `orbs`:
- **`ask`** acorda o outro Orb, que trabalha numa conversa à parte; a resposta volta como mensagem e acorda quem pediu. Quem
  pediu a vários é acordado **uma vez**, quando todas as respostas chegaram: cada linha marca ✓ assim que a sua resposta chega,
  e a linha de trabalho mostra quem falta ("Esperando Revisor").
- **`tell`** só deixa um aviso: não acorda ninguém nem espera resposta. O aviso aparece na hora no chat do destino, e o Orb o lê
  no topo da próxima mensagem que receber. Num grupo, o aviso é um post no fio.
- **`list`** mostra os colegas e se estão livres, ocupados ou esperando a sua aprovação. Num grupo, mostra o que cada membro
  está fazendo ("trabalhando em “…” (pedido de Atlas, há 4 min)", "na fila", "esperando Revisor"). Fora do grupo, mostra
  também os grupos de que o Orb faz parte, que ele já conhece pelo prompt.
- **Conversas abertas.** Em Ajustes, sob os interruptores, "Conversas abertas entre Orbs" lista os pedidos em andamento fora
  de grupo: quem pediu a quem, o quê, em que pé está e há quanto tempo, com **Parar** para a conversa inteira. Os de um grupo
  ficam na tela do grupo.
- **Criar um grupo pelo chat.** Com **Orbs podem acionar grupos** ligado (padrão), peça ao Orb: "cria um grupo Lançamento com
  o Pesquisador e o Revisor". Ele cria o grupo com o orquestrador que você disser (ou o primeiro da lista), o chat mostra "Atlas
  criou o grupo Lançamento com 3 Orbs" (a linha abre o grupo) e cada membro ganha "entrou no grupo". O nome não pode repetir o
  de um Orb ou de outro grupo.
- **Acionar um grupo pelo chat.** No mesmo interruptor, você pode pedir no chat de um Orb que ele mande algo a um grupo de que
  faz parte ("peça ao grupo Lançamento…"). O pedido vai ao orquestrador, o fio mostra "Pesquisador pediu ao Atlas, a seu
  pedido: …" e a resposta final do grupo volta ao chat ("O grupo Lançamento respondeu"). Dentro do grupo, o orquestrador pode
  passar parte do trabalho ao próprio Orb que pediu. Se o grupo já está trabalhando, o pedido entra no que está em andamento e o
  orquestrador o pega depois do turno atual. Isso vale só quando você pede, no chat do Orb: uma rotina ou um pedido de outro
  Orb não criam nem acionam grupos. Parar o chat que espera para o grupo também.
- **Quadro do grupo no chat.** No chat pessoal, o Orb consulta o quadro dos grupos de que faz parte (`group_recall`): as
  decisões e notas que os membros guardaram. Guardar no quadro continua sendo só nos turnos do grupo.
- **Mensagens seguidas ao grupo.** Se você manda uma segunda mensagem antes de o turno da primeira começar, as duas vão juntas
  no mesmo turno.
- **Só leitura num grupo.** O painel do grupo e a criação avisam quando um membro está em Só leitura: ele não pede nada aos
  colegas nem altera arquivos; um orquestrador em Só leitura não consegue distribuir o trabalho, e o aviso oferece **Trocar
  orquestrador**.
- Quando um Orb não pode fazer algo (outro Orb não existe, o nome é de um grupo, o grupo só deixa o orquestrador distribuir), a
  recusa diz o que aconteceu e o que fazer em seguida, e o Orb explica isso a você.

## Contexto da conversa

Os modelos têm uma janela limitada. O Orb mede quanto da janela a conversa ocupa e, quando enche, **resume o começo** em vez de
esquecer: o pedido original, as decisões, os arquivos mexidos, os erros em aberto e as pendências sobrevivem, e o que sai da
janela vai antes para a memória do Orb. As mensagens continuam salvas na conversa.

- **O anel** no compositor mostra quanto da janela está em uso (some quando não há histórico); a porcentagem aparece ao lado dele
  a partir de 70%, ou ao passar o mouse. Clique para o painel "Contexto desta
  conversa": quanto está em uso, o que é mantido palavra por palavra (contado em pedidos seus), quanto veio do cache do provedor e quanto "Compactar
  agora" liberaria.
- **Compactar agora** (ou `/compactar` e, se quiser, um foco: `/compactar decisões sobre o banco`) resume já. Não roda com o
  Orb respondendo. O resultado vira um aviso na conversa: "Compactei a conversa: os 5 primeiros pedidos viraram um resumo (≈ 58
  mil → 19 mil tokens)."
- Depois de compactar (por você ou sozinho), o que virou resumo se recolhe numa faixa no alto da conversa: "47 mensagens
  anteriores foram resumidas · Mostrar". Nada é apagado: "Mostrar" traz as mensagens de volta logo acima da faixa, "Ocultar"
  recolhe de novo, e a busca (⌘F) abre a faixa sozinha quando o resultado está lá dentro. Ao voltar para o Orb ela está
  recolhida, e a conversa abre mais rápido por isso.
- Você não precisa decidir nada: o anel só informa, e o Orb sabe a hora e o jeito de compactar. Ele dobra o começo quando a
  conversa passa do que cabe e também quando você volta depois de uns 5 minutos (o cache do provedor já esfriou, então dobrar
  não custa nada a mais). Antes da dobra, em segundo plano, ele pede ao modelo mais barato do mesmo fabricante (um "haiku" na
  Claude, um "mini" na OpenAI; num modelo aberto, num servidor local ou quando nada é mais barato, o próprio modelo do Orb)
  uma nota curta do trecho que vai sair: o que foi pedido, feito, decidido, aprendido e o que ficou em aberto. Num servidor
  local (Ollama, LM Studio) a nota cede a vez à sua próxima mensagem. A nota vai para o resumo, ao lado do pedido original, das
  decisões e dos arquivos, e para a memória do Orb. É uma chamada pequena por trecho, não aparece na conversa, e sem rede
  ou com o modelo ocupado o Orb resume do jeito de sempre.
- **Ajustes → Geral → Contexto das conversas**: *Econômico* (cerca de 40 mil tokens palavra por palavra, gasta menos por
  mensagem), *Equilibrado* (80 mil, o padrão) ou *Amplo* (até 60% da janela, nunca menos que o Equilibrado; custa mais por mensagem). Vale para todos os Orbs.
- Um resultado de ferramenta que não se pede de novo igual (um comando, uma página, um conector; não a leitura de um arquivo)
  e passa de 4 mil caracteres é salvo também num arquivo, em `saidas/`. Quando a conversa mais tarde o encurta, o caminho fica
  e o Orb relê o miolo com `read_file` em vez de rodar tudo de novo.
- Se um provedor recusa uma conversa por tamanho, o Orb aprende a janela real daquele modelo (**Janelas aprendidas**, com
  "Esquecer", útil depois de aumentar o limite do servidor).

Detalhes técnicos: [docs/CONTEXTO.md](CONTEXTO.md).

## Uso e custos

Ajustes (**⌘,**) → **Uso** mostra o que os seus Orbs gastaram, em dólares estimados. O **período** é Hoje, 7 dias, 30 dias ou Este
mês, e a página mostra:

- **O total** do período (grande), com os tokens e os pedidos. Abaixo, o que os planos cobriram, pelo preço da API, e um aviso
  se parte do uso é de um modelo sem preço.
- **O gráfico** por dia (por hora em "Hoje"), com as cores por Orb (a cor de cada um) ou por modelo.
- **Por Orb** e **Por modelo**: custo, tokens, pedidos e a porcentagem do total. Um Orb apagado continua na lista, com o nome que
  tinha.
- **Por horário**: 24 barras com os tokens de cada hora do dia, somados no período, e a hora em que você mais usa.
- A nota "Estimativa pelos preços públicos de 9 de outubro de 2026; o valor cobrado pelo provedor pode variar".

Como o custo é dito:

| Modelo | Aparece como |
|---|---|
| Chave de API (OpenAI, Claude, xAI, OpenRouter, OpenCode Zen, Command Code, gateway) | o valor em dólares, pelos tokens de cada pedido: o cache lido custa o preço do cache, não o da entrada |
| Assinatura (login do ChatGPT, Claude Code, OpenCode Go) | **Incluído no plano**, com os tokens. O "≈ US$ x pela API" é o que a tabela de preços daria para esses tokens. Não entra no total |
| Ollama, LM Studio, gateway em `localhost` | **Grátis** |
| Modelo que ninguém conhece o preço | os tokens e **Sem preço** (e o aviso no alto) |

O preço vem, em ordem, da sua correção, da lista do próprio provedor (OpenRouter e OpenCode dizem o preço de cada modelo) e de uma
tabela do app, lida nas páginas oficiais de preço da Anthropic, OpenAI, Google, DeepSeek, xAI e OpenCode. O lápis na linha de um modelo
**corrige o preço** (entrada, entrada do cache, gravação no cache e saída, em dólares por milhão de tokens); a correção vale também para
o que já foi gasto, e "Restaurar" volta ao preço de antes. Salvar sem mudar nada não cria correção. A tabela usa a faixa de preço normal
(prompts de até 200 ou 272 mil tokens). Na Anthropic o app separa a gravação de cache de 5 minutos (1,25 vez a entrada) da de 1 hora (2 vezes;
é a do prefixo estável em `api.anthropic.com`). A DeepSeek cobra metade fora do pico (dias úteis, 01h-04h e 06h-10h UTC; feriados chineses
contam como pico aqui, então erra para cima) e o Gemini 3.6, 3.7 e 3.8 Flash dobram em 1/1/2027: o preço é escolhido pela hora de cada
linha. Um modelo cujo id só combina com a tabela por um nome que muda o preço (`-pro`, `-deep-research`, `-mini`) fica **sem preço**. Ainda
assim o valor é uma estimativa.

O registro fica em `uso/aaaa-mm.json` (um arquivo por mês, linhas por hora, Orb, modelo e origem: conversa, rotina ou chamada do app) na pasta
de dados e só tem números: nada do que foi dito. **Redefinir o Orb** apaga o histórico de uso. Apagar um Orb não apaga: o dinheiro foi gasto.

## Conectores e skills

Páginas **Conectores** (⌥⌘C) e **Skills** (⌥⌘K) na barra lateral. Skills tem as abas **Explorar** e **Instaladas**; Conectores
tem a **Galeria**, os **Instalados** e **Explorar**.

- **Conectores** dão ferramentas novas aos Orbs (ler o Gmail, a Agenda, o Slack, o GitHub, uma pasta…). A **Galeria** é uma grade
  de serviços: cada cartão diz o que o serviço faz e como conecta, e o botão diz onde ele está (**Conectar**, **Conectado**,
  **Resolver** quando falta algo, **Desligado**, **Em breve**). O ícone é o logotipo da marca (Gmail, Google Agenda, Slack, Notion, GitHub, Supabase, Linear, Atlassian e Sentry; vêm embutidos no app, nada é baixado) ou, nos conectores genéricos e da Apple, um símbolo na cor da marca. Os instalados e as folhas de conexão usam o mesmo ícone.
  *Explorar* busca no [registro oficial do MCP](https://registry.modelcontextprotocol.io) os demais servidores, com aviso de que os
  não marcados "Oficial" são código de terceiros. Em "Adicionar manualmente" dá para informar o comando ou a URL.
  - **Google pelo Mac** (Gmail, Google Agenda, Lembretes): conectores **locais**, sem servidor e sem projeto no Google. A conta
    Google entra em *Ajustes do Sistema → Contas de Internet* (o login é da Apple, o Orb nunca vê a senha). **Conectar** pede a
    permissão do macOS (Calendários, Lembretes ou Automação do Mail) e, se não achar a conta Google no Mac, mostra um guia com
    o botão **Abrir Contas de Internet** (numa conta Google Workspace, que a Agenda nomeia pelo endereço, vale **Conectar assim
    mesmo**, que o Orb lembra). Agenda (EventKit): listar agendas, buscar (um período dado só por datas inclui o último dia),
    ler, criar, alterar e apagar eventos (não altera evento repetido; não convida pessoas nem cria link do Meet; **alterar e
    apagar perguntam sempre**, porque o Google avisa os convidados). Lembretes: listar e criar. Gmail (pelo Mail,
    AppleScript): listar caixas, buscar por caixa, período e texto no assunto ou remetente (sem os operadores do Gmail), ler
    mensagem, criar rascunho e **enviar**, que sempre pergunta. O Mail precisa ter baixado a mensagem.
  - **Slack (oficial)** (`mcp.slack.com/mcp`): **Criar meu app do Slack** abre o link de manifesto do Slack com o MCP ligado,
    escopos de usuário (*Só leitura* ou *Leitura e envio*) e PKCE; você instala o app no seu workspace e cola o **User OAuth
    Token** (`xoxp-…`), que vai para o Keychain. Só funciona onde o workspace deixa instalar apps (e o admin pode exigir
    aprovação). O Slack antigo (pacote `server-slack`, arquivado) e o Notion por npm saíram da galeria; quem já os instalou continua
    usando.
  - **Notion**, **Linear**, **Atlassian** (Jira e Confluence) e **Sentry** entram **com a sua conta**, em um clique: *Entrar com
    Notion* abre o navegador, você termina o login lá e volta; o Orb se registra sozinho no serviço (nenhuma chave para copiar).
    **Slack** usa o mesmo app criado pelo manifesto: cole só o **Client ID** (Basic Information → App Credentials) e clique em
    *Entrar com Slack*; colar o token continua valendo como alternativa. O login segue o OAuth 2.1 do MCP (PKCE obrigatório: um
    serviço sem PKCE é recusado). O token fica no Keychain, nunca no arquivo de dados, e **Sair da conta** (no menu do cartão)
    o apaga (e pede ao serviço que o revogue, quando o servidor de login anuncia o endereço da revogação; o `auth.revoke` do Slack ainda não é chamado, então o token dele só deixa de valer ao expirar ou ao desinstalar o app). O cartão mostra **Entrar**, **Sessão expirou** (a renovação foi recusada) ou **Precisa de mais permissão** (o
    servidor pediu um escopo a mais: **Permitir mais** abre o login de novo, uma vez por clique, e o botão fica até a permissão ser liberada). Um login que ficou esperando o navegador é do app, não do cartão: sair da tela não o prende, e um novo clique em *Entrar* substitui o anterior. Em **Avançado** dá para dar o
    Client ID e o Client Secret de um app seu, para serviços que não deixam o Orb se registrar. Só entra em conectores HTTPS.
  - **GitHub** e **Supabase** (`mcp.supabase.com/mcp`, token de acesso pessoal; começa com `read_only=true`) pedem uma chave.
- **Carregam sob demanda.** Um conector não liga com o app nem manda as suas ferramentas a cada mensagem: o Orb recebe só duas
  ferramentas fixas, uma para ver o que cada conector oferece e outra para usá-lo. O servidor sobe na primeira vez que um Orb
  precisa dele (a conversa mostra "Conectando a GitHub…") e desliga sozinho depois de 10 minutos sem uso (um servidor local que fica sem responder, duas chamadas seguidas, é desligado e sobe de novo na próxima; ao fechar o app, os servidores locais são encerrados). O cartão em
  *Instalados* mostra **Pronto** (desligado, liga quando precisar), **Em uso**, **Conectando…**, **Erro** ou **Desligado**, e o
  menu tem **Testar conexão** ("Conectou: 12 ferramentas em 0,8 s"; se falhar, o motivo aparece no cartão), **Ver ferramentas…** (com "Só leitura" e "Destrutiva"),
  **Editar…** e **Apagar…**. Uma falha traz "Tentar de novo".
- **Quem usa.** Cada conector e cada skill tem **"Usar com"**: todos os Orbs (padrão) ou só os que você marcar. O Orb também
  precisa estar com a chave **Conectores** ligada (marcar o Orb em "Usar com" liga sozinho). Uma ferramenta de conector pede
  aprovação como as demais, a menos que o servidor a anuncie como somente leitura. Uma que **envia, publica ou apaga** (pelo
  nome: send, post, reply, forward, share, publish, delete, remove, trash, archive, schedule, invite, transfer) pergunta até no
  Automático, a não ser que o servidor a declare só de leitura. O que vem de um conector não vira memória de longo prazo: a
  página de sessão guarda só que o conector foi usado. O Claude Code não vê os conectores: o `claude` roda só com o servidor mínimo do cano
  (`--strict-mcp-config`), então os conectores do claude.ai e os servidores do `~/.claude.json` não entram, e os do Orb passam pela política do Orb como
  com qualquer modelo.
- **Chaves e tokens** dos conectores (inclusive o login, conta `mcp.<id>.oauth`) ficam no **Keychain**, não no arquivo de dados;
  apagar o conector ou redefinir o Orb apaga também o login.
- **Skills** são instruções reutilizáveis no formato aberto `SKILL.md`. *Explorar* busca no catálogo [Skills.sh](https://skills.sh)
  e lê o `SKILL.md` no GitHub de quem publicou, com **prévia completa antes de instalar** (instale só de fontes em que você
  confia: a skill vira instrução para o Orb). Use com `/comando` no começo da mensagem, ou pelo botão "Usar". "Nova skill" cria a sua.
  O Orb também lê sozinho a skill que serve para a tarefa.
- **Skills aprendidas.** Depois de uma tarefa longa, o Orb revisa o que fez e, se aprendeu algo que vale repetir (uma técnica,
  uma correção sua, uma skill que estava errada), **propõe** uma skill, ou uma melhoria de uma que você já tem. O chat mostra
  "Skill proposta: /nome" com o botão **Revisar**: abre o texto inteiro, que você edita, e **Salvar skill** ou **Descartar**.
  Nada é salvo sem você, e a proposta rasa (genérica, sem passos concretos, armadilhas e como verificar, com data do dia ou segredo) nem chega a você.
  A skill aprendida fica marcada "Aprendida por <Orb>" e vale só para ele até você ampliar em "Usar com". Você também pode
  pedir "transforme isso numa skill". Em Ajustes → Geral dá para desligar ("Propor skills com o que os Orbs aprendem"); a revisão
  costuma usar uma chamada extra ao modelo (até 6 quando propõe algo: ler, procurar, propor e responder), quase toda em cache.

## Atalhos

| Tecla | Faz |
|---|---|
| ⌘N | Novo Orb |
| ⌘K | **Ir para…**: paleta para chegar a um Orb, uma página ou uma ação (↑↓ escolhem, ↩ abre, Esc fecha) |
| ⌘L | Escrever uma mensagem (foca o compositor) |
| ⌘. | Parar a resposta |
| ⇧⌘O | Abrir a pasta do Orb no Finder |
| ⌥⌘B | Mostrar ou ocultar o painel do Orb |
| ⌥↑ / ⌥↓ | Orb anterior / próximo |
| ⌘1 … ⌘9 | Ir para o Orb de mesmo número na barra lateral |
| ⌥⌘R / ⌥⌘C / ⌥⌘K | Rotinas / Conectores / Skills |
| ⌘, | Ajustes |
| ↩ / ⇧↩ | Enviar (com o Orb trabalhando, direciona a tarefa) / nova linha |
| ⇥ | Com o Orb trabalhando e algo escrito: pôr na fila para depois da tarefa. Com a lista de skills aberta: completar a skill |
| ⌘↩ | Com o Orb trabalhando e algo escrito: parar e enviar agora (recusa o pedido aberto, se houver; desligado durante a edição de uma mensagem). Num cartão de aprovação, com o campo de mensagem vazio: permitir. No painel de contexto: compactar |
| Esc | Num cartão de aprovação: não permitir (não vale enquanto você digita). Também fecha a paleta e a lista de skills; com o cursor no campo, desiste da edição de uma mensagem (depois de fechar a lista de skills, se estiver aberta) |
| ⇧⌘M | Escolher o modelo do Orb |
| ⌘Z | Desfazer "Esquecer" da memória (enquanto o aviso está na tela) |
| ⌘F | Buscar na conversa aberta. Em Skills e Conectores: buscar no catálogo (fora da aba Explorar leva ao catálogo, em Explorar) |
| ⌘G / ⇧⌘G | Com a busca da conversa aberta: próximo resultado / anterior (também ↩ ou ↓ e ⇧↩ ou ↑ no campo; Esc fecha) |
| ⌃⌥Espaço | De **qualquer app**: abre o painel da barra de menus. Opcional, desligado por padrão |

A mesma lista, completa, está em **Ajuda → Atalhos do teclado** e em Ajustes → Geral (as duas leem o mesmo catálogo, `Shortcuts.swift`).
O atalho global liga no menu **Orbs** ("Abrir o painel da barra de menus com ⌃⌥Espaço") ou em Ajustes → Geral. Se outro app
já usa essas teclas, o Orb avisa e deixa desligado.

## Barra de menus e pergunta rápida

O ícone do Orb na barra de menus muda quando algum Orb trabalha (cheio) e ganha um ponto quando algum espera por você. O
painel dele deixa **perguntar a um Orb sem abrir o app** (escolha o Orb, escreva, ↩ envia, ⇧↩ pula de linha), ler o fim da
resposta e **responder pedidos de permissão** de todos os Orbs. Se o Orb escolhido já está trabalhando, a mensagem entra na fila,
como no chat (numa rotina, o painel avisa que ela precisa terminar). "Ver conversa" continua no app. A conversa é a mesma do chat.

Em Ajustes → Geral: **Abrir ao iniciar sessão**, **Me avisar quando um Orb terminar ou precisar de mim** (banners só aparecem com o
app em segundo plano; também avisam quando uma rotina não termina, com o motivo, e quando um Orb parece andar em círculos ou passa
de 3 h num pedido, com **Parar**), a **Pasta de dados**, as **Memórias guardadas**, a **Pasta dos Orbs** com "Mostrar no Finder" e
**Redefinir o Orb…**.

## Redefinir o Orb

Ajustes → Geral → Seus dados → **Redefinir o Orb…** volta o app ao primeiro uso. A folha é irmã de "Apagar Atlas?": diz o que some ("3 Orbs, 42 conversas,
5 rotinas, 2 conectores, 4 skills, o seu perfil e os ajustes") e o que fica (a pasta `~/Orbs` com os arquivos que os Orbs criaram, que
**nunca** é apagada, e, se você quiser, as memórias), e pede duas escolhas:

- **Guardar as memórias** (padrão): cada Orb é apagado, mas o que ele aprendeu vai para Memórias guardadas (com o último trecho
  da conversa, gravado antes), e um Orb novo pode [começar de uma delas](#memória). **Apagar tudo, inclusive as memórias** apaga também as que
  já estavam guardadas; não dá para desfazer.
- **Também sair dos provedores** (desligado): apaga as chaves de API e o login do ChatGPT guardados no Keychain do Orb e a
  configuração dos provedores. Desligado, provedores, chaves e modelo padrão continuam. O login do Claude Code no Terminal
  nunca é tocado.

Sempre somem: os Orbs, as conversas (atuais, anteriores e de rotinas), os rascunhos não enviados, os anexos e as saídas de ferramentas, o seu perfil (texto e
foto; nunca vai para as memórias guardadas), o histórico de uso e custos, as rotinas, os
conectores e os segredos deles no Keychain, as skills instaladas ou criadas, as liberações ("Sempre permitir") e os ajustes do
app (voltam ao padrão, inclusive o primeiro uso). Nada fora da pasta de dados e do Keychain do app é tocado (dentro da pasta de
dados, só o que o Orb mesmo grava), e a migração do OpenBot não roda de novo: as chaves que o Orb apagou não voltam do Keychain
antigo. Se `ORB_DATA_DIR` aponta para uma pasta que não parece do Orb (sem `state.json`) ou para `~/Orbs`, a redefinição recusa.

**Redefinir…** (a pílula branca do rodapé, como nas outras folhas) abre um alerta ("Redefinir o Orb agora?") com **Redefinir e reabrir**; Esc cancela e Return
não confirma. O app
para tudo (conversas em andamento, rotinas, pedidos de permissão, conectores, processos em segundo plano), cobre a janela
enquanto trabalha (nada de mensagem nova nem de Novo Orb), apaga e abre de novo.
Se algo da pasta de dados não puder ser removido, movido ou gravado, o Orb avisa antes de fechar e abrir de novo ("A redefinição
não removeu tudo"): lista os itens (até 5, mais a contagem do resto) e indica Ajustes → Geral → Pasta de dados, para apagá-los à mão.
Rodando pelo SwiftPM (sem um `.app`), ele só fecha: abra de novo. Nos modos de desenvolvedor (`--snapshot`…) a redefinição nunca roda.

## Privacidade

- **Local.** Conversas, memórias, ajustes, anexos, saídas de ferramentas e o histórico de uso (só números, por hora) são arquivos comuns, sem criptografia própria, em
  `~/Library/Application Support/Orb` (Ajustes → Geral → Pasta de dados → Mostrar no Finder). O Orb não envia estatísticas de
  uso nem relatórios de erro.
- **Logotipos.** Os logotipos dos serviços (galeria de conectores) vêm do [Simple Icons](https://simpleicons.org) 16.34.0 (o do Slack, da 13.21.0, a última que o tinha; CC0, domínio público), embutidos no código: o app não baixa imagem nenhuma para isso. As marcas pertencem aos seus donos e aparecem só para dizer a que serviço o conector se liga; o Orb não tem vínculo nem aprovação deles.
- **Chaves.** As chaves de API, o login do ChatGPT e os segredos dos conectores ficam no **Keychain** do macOS (no arquivo de dados
  fica só um marcador). O login do Claude Code é do próprio Claude Code: o Orb nunca o lê.
- **O que vai para o provedor que você escolheu**, a cada mensagem: o que você escreveu, os anexos (imagens reduzidas; arquivos
  como caminho e o conteúdo que o Orb ler), o histórico recente (ou o resumo), o que as ferramentas devolverem (arquivos,
  saídas de comandos, páginas, capturas de tela com o texto lido por OCR), as instruções do Orb, as memórias que se aplicam, as
  skills ativas, o seu perfil (nome, como te chamar e o texto “Sobre você”; a foto não sai do Mac), o seu nome de usuário e a pasta pessoal, o idioma e a versão do macOS, a hora, e uma foto da pasta de trabalho
  (nomes de arquivos do primeiro nível, arquivos mexidos há pouco, branch, mudanças e títulos dos últimos commits do git).
  **Com Ollama ou LM Studio o modelo roda no seu Mac e a conversa não sai dele** (as ferramentas que você liberar, como
  `web_fetch` e os conectores, continuam falando com a rede). **Com o Claude Code, o conteúdo vai à Anthropic por ele.**
- **Outras conexões**: as listas de modelos de cada provedor (e a `models.dev`, para os modelos do OpenCode), o
  [Skills.sh](https://skills.sh) e o GitHub quando você explora ou instala uma skill, o registro do MCP, as páginas que o Orb
  abrir com `web_fetch` ou no navegador dele, as pesquisas (o DuckDuckGo ou o Google recebem o que o Orb pesquisa), os serviços dos conectores que você instalar e o login do ChatGPT.
- **Navegador e pesquisa.** O navegador do Orb guarda cookies e logins numa pasta de perfil por Orb (`navegador/`, na pasta de dados), no seu Mac, e ela some com o Orb. **Com o TinyFish como provedor de pesquisa, o que o Orb pesquisa vai para os servidores do TinyFish** (com a sua chave, guardada no Keychain); com DuckDuckGo ou Google, vai para eles.
- **Notificações** mostram o começo da resposta do Orb (até 180 caracteres) e o comando de um pedido de permissão; quem vê sua
  tela de bloqueio pode ver isso, conforme as suas configurações de notificação do macOS.
- **Importar de outro assistente** não lê o seu Mac sem você pedir (colar, escolher ou "Ler") e só usa a rede na aba do
  marketplace do Grok Bot (as páginas públicas de x.ai, sem login); o que entra vira dado na memória do Orb novo, depois da
  sua prévia.
- **Segurança das ações**: um texto malicioso numa página ou arquivo não consegue fazer o Orb agir sem você. O que sai do Mac
  (`web_fetch`, `web_search`, o navegador, `open`, guardar memória) e o que muda coisas passam pelas permissões; o prompt do Orb trata o que vem de
  páginas, arquivos, conectores e memórias como dado, nunca como instrução. Lembre que em "Sem pedir permissão" isso não vale.

## Problemas comuns

| Sintoma | O que fazer |
|---|---|
| "Conecte um modelo em Ajustes → Modelos para começar" | Conecte um provedor (veja [Primeiro uso](#primeiro-uso-conectar-um-modelo)); o cartão de primeiro uso faz isso em um a três cliques |
| "Chave ou login inválido (401)" | Ajustes → Modelos: troque a chave ("Trocar") ou entre de novo. Em OpenCode e Command Code, 401/403 também pode ser falta de saldo, plano sem API ou modelo desativado: a mensagem diz qual |
| "Você atingiu o limite de uso do provedor (429)" | Espere um pouco ou confira o plano. O Orb tenta de novo sozinho em falhas passageiras |
| Claude Code "não encontrado neste Mac" | Instale o `claude` ([guia](https://code.claude.com/docs/en/setup)) e use "Verificar de novo" em Ajustes → Modelos |
| Ollama ou LM Studio "Servidor não encontrado" | Abra o app e ligue o servidor local (LM Studio: o servidor precisa estar ligado e com um modelo carregado); baixe pelo menos um modelo |
| "A conversa ficou grande demais para este modelo" | Compactar agora, ou escolha o Contexto das conversas "Econômico" |
| O Orb diz que falta uma permissão do macOS | Ajustes → Permissões (ou o botão "Permitir…" na linha da ferramenta). Reabra o app depois de Gravação do Áudio do Sistema e da Tela e Acesso Total ao Disco |
| As permissões do macOS somem a cada compilação | [Assinatura estável](../README.md#assinatura-estável-recomendado) |
| O Orb parou numa pergunta | Veja o cartão na conversa, o ponto na barra de menus ou a notificação |
| Não aparecem notificações | Ajustes → Geral mostra o estado; "Abrir Ajustes do Sistema" leva ao painel de notificações |
| "Pasta não encontrada" no painel | A pasta foi apagada, renomeada ou está em disco desconectado: "Recriar" ou "Mudar pasta" |
| "Atenção com seus dados" | Um arquivo de dados não pôde ser lido. Ele **não é sobrescrito**: o Orb guarda uma cópia (`….corrupt-<data>`) e diz onde. "Mostrar no Finder" leva a ela |
| Quer começar do zero | Ajustes → Geral → Seus dados → **Redefinir o Orb…** ([Redefinir o Orb](#redefinir-o-orb)) |

## Veio do OpenBot?

> Na primeira abertura do Orb (app instalado, `app.orb.mac`), os dados e as preferências de
> `~/Library/Application Support/OpenBot` são copiados, menos a pasta de saídas grandes `saidas/` (os originais ficam onde estavam) e as chaves do Keychain são copiadas uma
> a uma quando usadas (as do OpenBot ficam como backup e, se você remover uma chave no Orb, ela não volta de lá). Como o identificador mudou, o macOS pede de novo as permissões e "Abrir ao iniciar sessão" precisa ser ligado de novo.
