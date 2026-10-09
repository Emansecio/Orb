# Orb para macOS

O Orb é um app nativo (SwiftUI, macOS 14 ou mais novo) para conversar com **Orbs**: assistentes animados que agem no seu
Mac. Cada Orb tem o seu modelo, a sua pasta, a sua memória, as suas permissões e as suas rotinas. Eles leem e escrevem
arquivos, rodam comandos, abrem apps, leem páginas da web e usam conectores, sempre dentro das permissões que você der.

Os seus dados ficam neste Mac: conversas, memórias e ajustes são arquivos na sua pasta, e as chaves ficam no Keychain. O que cada
mensagem envia ao provedor do modelo está em [Privacidade](#privacidade).

- [Instalar](#instalar)
- [Primeiro uso](#primeiro-uso-conectar-um-modelo)
- [A janela](#a-janela) · [Criar um Orb](#criar-um-orb) · [Conversar](#conversar)
- [Permissões](#permissões) · [Permissões do macOS](#permissões-do-macos)
- [Memória](#memória) · [Conversas e rotinas](#conversas-e-rotinas) · [Contexto](#contexto-da-conversa)
- [Uso e custos](#uso-e-custos) · [Conectores e skills](#conectores-e-skills) · [Atalhos](#atalhos) · [Barra de menus](#barra-de-menus-e-pergunta-rápida)
- [Redefinir o Orb](#redefinir-o-orb) · [Privacidade](#privacidade) · [Problemas comuns](#problemas-comuns) · [Para quem desenvolve](#para-quem-desenvolve)

## Instalar

O Orb ainda não tem versão pronta para baixar: você gera o app aqui. Precisa do macOS 14+ e do Swift 6 (Xcode 16 ou mais novo).

```bash
./scripts/bundle.sh && open build/Orb.app
```

O script compila, monta `build/Orb.app` (com o ícone) e assina o app só para uso neste Mac. Arraste `build/Orb.app` para a
pasta Aplicativos se quiser. Para ter um app de depuração: `./scripts/bundle.sh debug`.

### Assinatura estável (recomendado)

Sem configuração, o app é assinado de forma temporária (*ad-hoc*), e a identidade dele é um resumo do arquivo. A cada
compilação o macOS acha que é **outro app** e esquece as permissões de Automação, Acessibilidade e Acesso Total ao Disco. Para
ele lembrar, crie uma vez um certificado local:

```bash
./scripts/make-signing-identity.sh   # cria o certificado "Orb Local" no chaveiro de login (pede a sua senha)
./scripts/bundle.sh                  # daqui em diante assina com ele sozinho
```

O certificado vale só neste Mac (não serve para distribuir o app). Outra identidade: `ORB_SIGN_IDENTITY="Nome do certificado"
./scripts/bundle.sh`. Depois da primeira compilação assinada, libere as permissões do macOS mais uma vez.

> Veio do OpenBot? Na primeira abertura do Orb (app instalado, `app.orb.mac`), os dados e as preferências de
> `~/Library/Application Support/OpenBot` são copiados, menos a pasta de saídas grandes `saidas/` (os originais ficam onde estavam) e as chaves do Keychain são copiadas uma
> a uma quando usadas (as do OpenBot ficam como backup e, se você remover uma chave no Orb, ela não volta de lá). Como o identificador mudou, o macOS pede de novo as permissões e "Abrir ao iniciar sessão" precisa ser ligado de novo.

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
**ao vivo** do provedor (ao abrir e a cada 6 h; uma lista que falha é tentada de novo depois de 5 min, 10 min e assim por diante, sem travar as rotinas) e valem para qualquer Orb.

| Grupo | Provedor | Como conectar | Observações |
|---|---|---|---|
| Assinatura (sem chave) | **Claude Code (sua assinatura)** | "Entrar" abre o navegador (roda `claude auth login --claudeai`) | Precisa do `claude` instalado ([como instalar](https://code.claude.com/docs/en/setup)). O login é o do próprio Claude Code: o Orb nunca lê, copia nem guarda os tokens. "Sair" desconecta o Claude Code no Mac inteiro, inclusive no Terminal. Os modelos são os que a sua conta oferece |
| | **ChatGPT (sua assinatura)** | "Entrar com ChatGPT" (login oficial para apps locais) | Precisa do ChatGPT Plus ou Pro; usa o limite do seu plano |
| Chave de API | **OpenAI**, **Claude** (API da Anthropic), **xAI (Grok)**, **OpenRouter** | colar a chave | Cobrança por uso, direto no provedor |
| | **OpenCode Zen** | colar a chave de [opencode.ai/auth](https://opencode.ai/auth) | Gateway pré-pago: cobra do seu saldo pelo uso, sem margem sobre o preço do modelo. Modelos gratuitos (que podem usar seus dados) e os Gemini ficam fora da lista |
| | **OpenCode Go** | a mesma chave da OpenCode | Assinatura da OpenCode (Go US$ 10/mês, Go Plus US$ 40/mês) com modelos abertos (GLM, Kimi, DeepSeek, Qwen…). O uso tem limite por modelo em janelas de 5 horas, semana e mês; passando do limite, os modelos gratuitos seguem funcionando, e o saldo do Zen cobre se você ativar "Use balance" no console |
| | **Command Code** | colar a chave de [commandcode.ai/settings/keys](https://commandcode.ai/settings/keys) | Precisa de um plano com acesso à API: Provider (pago por uso), GOAT, Pro, Max ou Team. **O plano Go não inclui a API** (o app avisa se for o caso). Modelos gratuitos ou promocionais ficam fora da lista |
| No seu Mac | **Ollama**, **LM Studio** | abra o app e deixe o servidor ligado | Nada sai do Mac. Endereços padrão `http://localhost:11434/v1` e `http://localhost:1234/v1` (dá para trocar). Sem modelo baixado ou carregado, a linha avisa |
| Avançado | **Gateway próprio** | URL base (`http://` ou `https://`), formato e, se precisar, cabeçalhos | Formatos: Chat (OpenAI), Responses (OpenAI) ou Messages (Anthropic / Claude). Os modelos vêm da lista do servidor ou você os adiciona pelo id |

Os preços e planos acima são os que o app descreve hoje; confira no site do provedor, que pode mudar.

O **modelo padrão** (Ajustes → Modelos) vale para os Orbs sem modelo próprio. Cada Orb pode ter o seu: na aba Geral do painel
dele ou no botão de modelo do compositor (⇧⌘M, com busca e os recentes). "Desativar este provedor" (reticências da linha) tira o
provedor das listas sem apagar a chave; "Remover…" apaga a chave (ou sai da conta, no ChatGPT).

## A tela de boas-vindas

Sem nenhum Orb na lista (se você apagou todos), a janela mostra a **tela de boas-vindas** em vez de um chat vazio: três Orbs que
piscam e olham para o ponteiro, o que o app faz em três pontos ("Conversa e faz", "Pede antes de agir", "Lembra de você") e o
caminho mais curto até o primeiro Orb. Sem modelo conectado, o cartão "Primeiro, conecte um modelo" aparece ali mesmo (os
mesmos caminhos do primeiro uso). Com um modelo pronto, são duas opções:

- **Criar meu primeiro Orb** (⌘N, ou Return): abre a folha Novo Orb.
- **ou comece com o Atlas, pronto para usar**: cria o Atlas na hora, com uma pasta própria em `~/Orbs`.

Com [memórias guardadas](#memória) de Orbs apagados, um cartão "Começar de uma memória guardada" lista as três mais novas
("Continuar" abre a folha Novo Orb já com a memória escolhida; "Ver todas" mostra a lista completa). Depois de criar um Orb
e apagar todos, o título vira "Hora de um Orb novo". A barra lateral mostra "Criar seu primeiro Orb" onde os Orbs ficam, e o
clique nela traz a tela de volta. Com Orbs, o app sempre abre em um deles ("Escolha um Orb" deixou de existir). Sob os botões,
"ou importe de outro assistente" abre a folha Novo Orb já no painel de [importação](#criar-um-orb).

## A janela

A **barra lateral** tem os seus Orbs, o **Espaço de trabalho** (Rotinas, Conectores, Skills), **Novo Orb** e **Ajustes**. Uma
linha mostra o que o Orb está fazendo ("Pensando…"), "Precisa de você" quando ele espera uma permissão e um ponto quando há
mensagens não lidas; o botão direito abre o menu do Orb (nova conversa, conversas anteriores, abrir pasta, personalizar, ver
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

No alto do painel: nome e papel (clique para editar; mudar o nome não renomeia a pasta), "Personalizar…" (aparência), "Abrir
pasta", "Terminal" e "Nova conversa". O painel se recolhe sozinho em janelas estreitas (menos de 1180 pt) e volta quando há espaço.

As chaves de "O que pode usar" desligam grupos inteiros de ferramentas para aquele Orb: sem **Terminal e arquivos** ele não roda
comandos nem lê, escreve, procura ou apaga arquivos (no Claude Code sobra só o `Read`, que abre as imagens que você anexa); sem **Navegar na web** não lê páginas (nem baixa arquivos com `save_to`, que também precisa de **Terminal e arquivos**); sem **Controlar apps do Mac** não usa
AppleScript, Atalhos, área de transferência, captura de tela nem controla outros apps; sem **Conectores** não usa os conectores.

## Conversar

- **Escrever.** ↩ envia, ⌥↩ pula de linha. Digite `/` para ver as skills (↑↓ escolhem, ↩ ou ⇥ completam, Esc fecha).
- **Respostas** vêm em Markdown de verdade: títulos, listas (inclusive de tarefas), tabelas, citações e blocos de código com
  botão "Copiar". Passe o mouse sobre uma resposta para "Copiar" ou "Copiar como Markdown".
- **Anexos.** O botão `+` (ou arrastar para a janela, ou ⌘V) anexa. Imagens (PNG, JPEG, HEIC, GIF, WebP, TIFF; até 20 MB cada)
  são reduzidas (um chip "Preparando imagem…" aparece e o envio espera) e enviadas ao modelo se ele enxerga; se ele não enxerga, só o caminho vai e o app avisa. Outros arquivos
  vão como caminho: o Orb os lê com as ferramentas (precisa de "Terminal e arquivos"). A captura de tela que o Orb tira
  também chega a ele como imagem, quando o modelo enxerga.
  No chat, os anexos aparecem do mesmo jeito na mensagem enviada, na fila e no compositor: imagens numa grade de largura fixa
  (uma, duas ou três colunas; "+N" quando passam de nove) e arquivos como cartões com o ícone do tipo, o nome cortado no meio
  (a extensão fica à vista) e "PDF · 2,1 MB". Arquivo que sumiu ou anexo antigo, que guardou só o nome, aparecem como tal.
  Clicar abre o Quick Look (← e → passam de um anexo para o outro); o botão direito oferece Abrir, Mostrar no Finder, Copiar e Copiar
  caminho; dá para arrastar o arquivo para fora. O que o Orb cria ou altera com as ferramentas de arquivo (e as capturas de
  tela dele) aparece sob a linha da ferramenta, como cartão "novo" ou "alterado" ou como miniatura, uma vez só por turno.
  Arquivos criados por comandos do Terminal não entram.
- **Escrever com o Orb trabalhando.** O compositor continua livre: a mensagem entra como "Na fila" e chega ao Orb no próximo
  passo dele (no Claude Code, assim que a resposta termina). **⌘↩ para e envia agora**; com um pedido de permissão aberto,
  isso recusa o pedido (parar sempre recusa) e envia. Se o Orb espera sua resposta a um pedido, a fila só anda depois dela.
  Dá para tirar uma mensagem da fila ("Editar"). Se o turno falhar ou for parado, o que estava na fila volta para o campo.
- **Parar.** O botão Parar ou **⌘.**; o Orb avisa "Você interrompeu esta resposta".
- **O que o Orb está fazendo.** Uma linha no fim da conversa, ao lado dele, diz o verbo e o alvo ("Rodando `swift build`",
  "Lendo README.md", "Procurando “TODO”", "Abrindo github.com") com o tempo do turno e, a partir da segunda ferramenta,
  quantas ações ele já fez ("16 s · 3 ações"). Entre um passo e outro ela diz "Pensando…". Quando espera por você, ela fica
  parada em laranja ("Esperando sua resposta"); quando espera para tentar de novo, mostra a contagem ("Conexão caiu ·
  tentando de novo", "em 8 s"). A barra lateral e o painel da barra de menus dizem a mesma coisa. As linhas de ferramenta
  acima dela são o histórico do turno. Cada frase fica ao menos 0,7 s na tela, e com o VoiceOver ligado ela é anunciada
  com educação (no máximo uma vez a cada 8 s). Com "Reduzir movimento" as frases só trocam de opacidade.
- **Quando algo dá errado**, a mensagem vem com a ação: "Tentar de novo" (reenvia, se nada tinha sido feito; se já tinha
  respondido, pede para continuar), "Continuar", "Abrir Ajustes" (chave inválida, sem modelo) ou, numa conversa grande demais, "Compactar
  e tentar de novo" (resume o começo e reenvia; só aparece quando há o que resumir) e "Nova conversa". Limite de uso (429) e instabilidade do provedor são tentados de novo sozinhos algumas vezes, com a espera à vista.
- **Tarefas longas.** Um turno tem até 30 passos (60 numa rotina). Ao chegar lá o Orb deixa um registro do que fez e avisa
  "Pausei depois de 30 passos…": diga **"continua"**.
- **Skills.** `/resumir`, `/organizar` e `/revisar` vêm prontas; veja [Conectores e skills](#conectores-e-skills).

## Permissões

Cada Orb tem um **modo** (botão no compositor, aba Geral do painel, ou ao criar). Ler e pesquisar não pergunta, em modo nenhum,
com duas exceções: **chaves e senhas** (`~/.ssh`, `~/.aws`, `.env`, `*.pem`…) perguntam até no Automático e são recusadas no Só
leitura; e comandos que só olham (`ls`, `git status`, `git log`, `cat`…) não pedem cartão no Perguntar antes e rodam no Só leitura.

| Modo | O que acontece |
|---|---|
| **Perguntar antes** (padrão) | O que muda algo, roda código, abre algo, acessa a web ou guarda memória **pede a sua aprovação**, a menos que você já tenha liberado aquilo ("Sempre permitir") ou seja escrita na pasta própria do Orb |
| **Automático** | Faz tudo sozinho, **menos** comandos destrutivos (`rm -rf`, `rm` de arquivo fora da pasta do Orb, `sudo`, `git push --force`, formatar disco…) e mudanças nas instruções dele (identidade e preferências da memória), que ainda perguntam |
| **Só leitura** | Só lê e pesquisa arquivos e apps do Mac e roda comandos que só olham (`ls`, `git status`, `git log`). Tudo o mais é recusado, **inclusive a web** (`web_fetch`), **mesmo com "Sempre permitir"** |
| **Sem pedir permissão** | Nunca pergunta, nem os comandos destrutivos. Ligar exige uma confirmação ("Rodar sem pedir permissão?"). Use só com Orbs e pastas em que você confia |

### Cartões de aprovação

Quando o Orb precisa de você, aparece um cartão na conversa e o Orb espera ("Esperando sua resposta").

- **Permitir** (**⌘↩**) libera só aquela ação. **Não permitir** (**Esc**) nega e o Orb não tenta de novo. Os atalhos valem para o
  cartão mais novo do Orb aberto; o Esc não vale enquanto você digita.
- **Dizer o que fazer em vez disso** nega e manda a sua instrução ao Orb ("use a lixeira").
- O menu ao lado de Permitir: **Só nesta tarefa** (até o Orb terminar) e **Sempre permitir…**, com até três regras de
  tamanhos diferentes (por exemplo "comandos `git push`", "comandos `git`", "gravar em `~/Projetos/app`", "acessar
  `exemplo.com`"). A regra fica salva no Orb.
- **Vários pedidos do mesmo passo viram um cartão só** ("4 ações precisam da sua permissão"): "Permitir as 4", "Revisar uma a
  uma" ou "Não permitir". Comandos perigosos nunca entram no grupo.
- **Comandos perigosos** (apagar em massa, `sudo`, forçar push, baixar e executar script, desligar o Mac, mexer em `~/.ssh` ou
  nos arquivos de inicialização do shell…) mostram um aviso de "Comando arriscado" e **sempre perguntam**, no Perguntar antes
  e no Automático, e nenhum "Sempre permitir" os cobre. (No "Só leitura" são recusados e no "Sem pedir permissão" não há pergunta.)
- No **Claude Code**, o "Automático" também passa pela política do Orb (o CLI roda em modo `default` e cada pedido chega ao
  Orb): uma edição em `~/.zshrc` ou `~/.ssh` pergunta, como no motor nativo.
- Trocar o modo com cartões abertos responde a eles: "Sem pedir permissão" permite, "Só leitura" nega, "Automático" permite
  os que não são perigosos.
- **Pela notificação.** Se o app está em segundo plano, ou outro Orb está aberto, o pedido chega como banner com **Permitir** e
  **Não permitir**; nos perigosos, o Permitir exige desbloquear o Mac. A **barra de menus** lista os pedidos de todos os Orbs
  (um perigoso só se resolve no app) e a barra lateral marca o Orb que espera.

### Liberações

Painel do Orb → **Pasta e acessos** → **Liberações** lista cada "Sempre permitir" ("Rodar comandos git", "Gravar em
~/Projetos/app", "Usar create_issue (github)"), com **Remover** e **Remover todas**. Valem no "Perguntar antes"; remover uma vale
já para a próxima ação do Orb, mesmo no meio de uma tarefa. O compositor mostra o número ("Perguntar antes · 4").

### Instruções da pasta

Se a pasta do Orb tem um `ORB.md`, `AGENTS.md` ou `CLAUDE.md`, ele a lê como **material de referência**, não como ordem (qualquer pasta
baixada pode trazer um). Para valer como instruções, ligue **"Confiar nas instruções desta pasta"** na aba Pasta e acessos; se o
arquivo mudar depois, volta a ser só referência até você confiar de novo.

## Permissões do macOS

Ajustes (**⌘,**) → **Permissões do Mac** mostra o que o macOS já deixa o Orb fazer, com o estado de cada uma:

- **Essenciais**: Acessibilidade (ler e operar a interface de outros apps), Gravação do Áudio do Sistema e da Tela, Acesso Total ao Disco (é uma
  estimativa: o macOS não informa; o Orb tenta abrir uma pasta protegida) e **Notificações**.
- **Apps que o Orb controla** (Automação): Mail, Calendário, Notas, Lembretes, Finder, System Events, Mensagens, Safari e Música.

Cada linha mostra o estado (Liberado, Negado, Não pedido…) e **um** botão: **Pedir agora** (o macOS mostra o aviso dele),
**Abrir `<app>` e pedir** (Automação de um app fechado) ou **Abrir Ajustes do Sistema** (leva ao painel certo). A aba só olha,
atualiza quando você volta ao app e tem **Verificar de novo**. Gravação do Áudio do Sistema e da Tela e Acesso Total ao Disco só valem depois de
**reabrir o Orb**.

- Antes de rodar um AppleScript, o Orb mostra o aviso de Automação dos apps que o script usa e espera você responder (um app
  conhecido que está fechado é aberto escondido antes, para o aviso não cair dentro do tempo do script). App recusado falha na hora.
- No **Automático**, enviar e-mail ou mensagem por AppleScript (ou apertar Return no WhatsApp/Telegram…), apagar vários itens de
  uma vez e abrir scripts, instaladores ou links que rodam Atalhos perguntam antes, como os outros comandos perigosos.
- O Orb recebe receitas curtas para as tarefas comuns do Mac (datas sem depender do idioma, rascunho no Mail, Lembretes, Notas,
  Calendário, Música) e conselhos para os erros típicos do AppleScript. No Claude Code, a captura de tela chega como imagem.
- No painel do Orb, a chave "Controlar apps do Mac" ligada traz o atalho **Permissões do Mac**.
- Quando uma ferramenta falha por falta de permissão, o Orb não tenta de novo: diz o que ligar e onde, e a linha da ferramenta
  ganha o botão **Permitir…** (pede ao macOS ou abre o painel certo).
- As permissões valem para esta cópia do app; veja [Assinatura estável](#assinatura-estável-recomendado).

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
- **Ao apagar um Orb**, o diálogo mostra o que some (a conversa atual, as arquivadas, as rotinas) e o que fica (a pasta), e
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
- No **Claude Code**, a memória chega por um servidor de ferramentas que o próprio app oferece; o histórico do Claude Code
  (`~/.claude/projects/`) é dele, e "Esquecer" no Orb não o apaga.

Detalhes: [docs/MEMORIA.md](docs/MEMORIA.md).

## Conversas e rotinas

### Conversas

**Nova conversa** (⇧⌘N) guarda a atual e começa outra, sem perder nada (uma conversa em que você não disse nada não é guardada). O que está escrito no campo (e as mensagens que estavam na fila) segue para a conversa nova.
**Conversas** (botão da barra do chat, **⌘Y**) lista as anteriores deste Orb, agrupadas em Hoje, Ontem, Esta semana e Mais
antigas, com busca a partir de 5. ↩ reabre (a atual é arquivada antes); Delete pede para apagar ("Apagar de vez? Não dá para
desfazer."; ↩ confirma, Esc cancela). Apagar uma conversa apaga também as imagens que só ela usava; uma imagem que outra conversa
do mesmo Orb (a atual, outra arquivada ou de uma rotina) ainda usa fica.

### Rotinas

Uma **rotina** é uma tarefa que um Orb faz sozinho, no horário, **enquanto o app está aberto** (página **Rotinas**,
⌥⌘R; também na aba Rotinas do painel). Há modelos prontos: "Resumo da manhã", "Organizar arquivos" e "Revisar a semana".

- **Quando**: todo dia, toda semana (com o dia), a cada X horas ou a cada X minutos (no mínimo 15); o editor mostra a próxima
  execução.
- **Peça no chat.** "Verifique meus e-mails a cada 30 minutos" ou "todo dia às 9h me mande um resumo das notícias": o Orb cria a
  rotina sozinho (ferramenta `schedule`, nos dois motores) e também lista, pausa, retoma e apaga as dele quando você pede. Nada
  disso passa em branco: em "Perguntar antes" o cartão mostra o nome, quando roda e o que será pedido; em "Só leitura" só dá
  para listar. A rotina roda no modo do próprio Orb (nunca num mais permissivo), cada Orb tem no máximo 20 e só mexe nas suas, e
  uma rotina em execução não cria outras. A nova aparece na aba Rotinas do painel (que abre sozinha se estiver à vista), com um
  destaque suave; ali cada uma tem o interruptor Ativa/Pausada e o botão de apagar (com confirmação na própria linha).
- **Conversa própria.** Cada rotina roda numa conversa só dela, nunca no seu chat: o chat ganha só uma linha no fim ("Rotina
  'Resumo da manhã' terminou: …"). Em **Ver conversa** você lê a execução. Fica o histórico das últimas 10 execuções, com
  relatório, e a próxima execução sabe o que a anterior encontrou.
- **Relatório em arquivo.** Se o Orb tem pasta própria, cada execução grava `Rotinas/<nome>/<aaaa-mm-dd hhmm>.md` nela.
- **Permissões.** Ninguém está lá para responder, então uma rotina em "Perguntar antes" **espera por você** (o editor avisa e
  oferece "Usar Automático" e "Usar Só leitura"). Em Avançado: "Permissões da rotina" (Igual ao Orb, Automático ou Só leitura).
- Se o Orb está ocupado, a rotina entra na fila ("Na fila") e roda quando ele terminar. "Rodar agora" e "Rodar uma vez
  agora, para testar" ao criar. O mesmo vale para "Rodar agora" no painel do Orb. Rotina desativada fica "Pausada".

## Contexto da conversa

Os modelos têm uma janela limitada. O Orb mede quanto da janela a conversa ocupa e, quando enche, **resume o começo** em vez de
esquecer: o pedido original, as decisões, os arquivos mexidos, os erros em aberto e as pendências sobrevivem, e o que sai da
janela vai antes para a memória do Orb. As mensagens continuam salvas na conversa.

- **O anel** no compositor mostra a porcentagem da janela (some quando não há histórico). Clique para o painel "Contexto desta
  conversa": quanto está em uso, o que é mantido palavra por palavra (contado em pedidos seus), quanto veio do cache do provedor e quanto "Compactar
  agora" liberaria.
- **Compactar agora** (ou `/compactar` e, se quiser, um foco: `/compactar decisões sobre o banco`) resume já. Não roda com o
  Orb respondendo. O resultado vira um aviso na conversa: "Compactei a conversa: os 5 primeiros pedidos viraram um resumo (≈ 58
  mil → 19 mil tokens)."
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
- Se um provedor recusa uma conversa por tamanho, o Orb aprende a janela real daquele modelo (**Janelas aprendidas**, com
  "Esquecer", útil depois de aumentar o limite do servidor).
- No **Claude Code** o contexto é do próprio Claude Code, que se resume sozinho; "Compactar agora" faz um resumo e **a próxima
  mensagem começa uma sessão nova** a partir dele.

Detalhes técnicos: [docs/CONTEXTO.md](docs/CONTEXTO.md).

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
| Assinatura (login do ChatGPT, Claude Code, OpenCode Go) | **Incluído no plano**, com os tokens. O "≈ US$ x pela API" é o que o Claude Code informa de cada turno, ou o que a tabela de preços daria. Não entra no total |
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
  **Resolver** quando falta algo, **Desligado**, **Em breve**). O ícone é um símbolo ou uma letra na cor da marca (nada é baixado).
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
    Client ID e o Client Secret de um app seu, para serviços que não deixam o Orb se registrar. Com o Claude Code, o token vai
    renovado (com pelo menos 30 minutos de vida, quando o serviço dá refresh token) para cada turno; se o serviço recusar a renovação, o cartão passa a dizer **Sessão expirou** na hora. Só entra em conectores HTTPS.
  - **GitHub** e **Supabase** (`mcp.supabase.com/mcp`, token de acesso pessoal; começa com `read_only=true`) pedem uma chave.
- **Carregam sob demanda.** Um conector não liga com o app nem manda as suas ferramentas a cada mensagem: o Orb recebe só duas
  ferramentas fixas, uma para ver o que cada conector oferece e outra para usá-lo. O servidor sobe na primeira vez que um Orb
  precisa dele (a conversa mostra "Conectando a GitHub…") e desliga sozinho depois de 10 minutos sem uso (um servidor local que fica sem responder, duas chamadas seguidas, é desligado e sobe de novo na próxima; ao fechar o app, os servidores locais são encerrados). O cartão em
  *Instalados* mostra **Pronto** (desligado, liga quando precisar), **Em uso**, **Conectando…**, **Erro** ou **Desligado**, e o
  menu tem **Testar conexão** ("Conectou: 12 ferramentas em 0,8 s"; se falhar, o motivo aparece no cartão), **Ver ferramentas…** (com "Só leitura" e "Destrutiva"),
  **Editar…** e **Apagar…**. Uma falha traz "Tentar de novo". Com o Claude Code os conectores vão como sempre, e ele mesmo
  adia as ferramentas.
- **Quem usa.** Cada conector e cada skill tem **"Usar com"**: todos os Orbs (padrão) ou só os que você marcar. O Orb também
  precisa estar com a chave **Conectores** ligada (marcar o Orb em "Usar com" liga sozinho). Uma ferramenta de conector pede
  aprovação como as demais, a menos que o servidor a anuncie como somente leitura. Uma que **envia, publica ou apaga** (pelo
  nome: send, post, reply, forward, share, publish, delete, remove, trash, archive, schedule, invite, transfer) pergunta até no
  Automático, a não ser que o servidor a declare só de leitura. O que vem de um conector não vira memória de longo prazo: a
  página de sessão guarda só que o conector foi usado. O Claude Code roda sempre com `--strict-mcp-config`: os conectores do
  claude.ai e os servidores do `~/.claude.json` não entram, só os conectores do Orb.
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
  usa uma chamada extra ao modelo, quase toda em cache.

## Atalhos

| Tecla | Faz |
|---|---|
| ⌘N | Novo Orb |
| ⇧⌘N | Nova conversa |
| ⌘K | **Ir para…**: paleta para chegar a um Orb, uma conversa anterior, uma página ou uma ação (↑↓ escolhem, ↩ abre, Esc fecha) |
| ⌘L | Escrever uma mensagem (foca o compositor) |
| ⌘Y | Conversas anteriores do Orb aberto |
| ⌘. | Parar a resposta |
| ⇧⌘O | Abrir a pasta do Orb no Finder |
| ⌥⌘B | Mostrar ou ocultar o painel do Orb |
| ⌥↑ / ⌥↓ | Orb anterior / próximo |
| ⌘1 … ⌘9 | Ir para o Orb de mesmo número na barra lateral |
| ⌥⌘R / ⌥⌘C / ⌥⌘K | Rotinas / Conectores / Skills |
| ⌘, | Ajustes |
| ↩ / ⌥↩ | Enviar / nova linha |
| ⌘↩ | Com o Orb trabalhando e algo escrito: parar e enviar agora (recusa o pedido aberto, se houver). Num cartão de aprovação, com o campo de mensagem vazio: permitir. No painel de contexto: compactar |
| Esc | Num cartão de aprovação: não permitir (não vale enquanto você digita). Também fecha a paleta e a lista de skills |
| ⇧⌘M | Escolher o modelo do Orb |
| ⌘Z | Desfazer "Esquecer" da memória (enquanto o aviso está na tela) |
| ⌘F | Buscar, em Skills e Conectores (fora da aba Explorar leva ao catálogo, em Explorar) |
| ⌃⌥Espaço | De **qualquer app**: abre o painel da barra de menus. Opcional, desligado por padrão |

A mesma lista, completa, está em **Ajuda → Atalhos do teclado** e em Ajustes → Geral (as duas leem o mesmo catálogo, `Shortcuts.swift`).
O atalho global liga no menu **Orbs** ("Abrir o painel da barra de menus com ⌃⌥Espaço") ou em Ajustes → Geral. Se outro app
já usa essas teclas, o Orb avisa e deixa desligado.

## Barra de menus e pergunta rápida

O ícone do Orb na barra de menus muda quando algum Orb trabalha (cheio) e ganha um ponto quando algum espera por você. O
painel dele deixa **perguntar a um Orb sem abrir o app** (escolha o Orb, escreva, ↩ envia, ⌥↩ pula de linha), ler o fim da
resposta e **responder pedidos de permissão** de todos os Orbs. Se o Orb escolhido já está trabalhando, a mensagem entra na fila,
como no chat (numa rotina, o painel avisa que ela precisa terminar). "Ver conversa" continua no app. A conversa é a mesma do chat.

Em Ajustes → Geral: **Abrir ao iniciar sessão**, **Me avisar quando um Orb terminar ou precisar de mim** (banners só aparecem com o
app em segundo plano), a **Pasta de dados**, as **Memórias guardadas**, a **Pasta dos Orbs** com "Mostrar no Finder" e
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

Sempre somem: os Orbs, as conversas (atuais, anteriores e de rotinas), os anexos e as saídas de ferramentas, o seu perfil (texto e
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
  abrir com `web_fetch`, os serviços dos conectores que você instalar e o login do ChatGPT.
- **Notificações** mostram o começo da resposta do Orb (até 180 caracteres) e o comando de um pedido de permissão; quem vê sua
  tela de bloqueio pode ver isso, conforme as suas configurações de notificação do macOS.
- **Importar de outro assistente** não faz rede e não lê o seu Mac sem você pedir (colar, escolher ou "Ler"); o que entra
  vira dado na memória do Orb novo, depois da sua prévia.
- **Segurança das ações**: um texto malicioso numa página ou arquivo não consegue fazer o Orb agir sem você. O que sai do Mac
  (`web_fetch`, `open`, guardar memória) e o que muda coisas passam pelas permissões; o prompt do Orb trata o que vem de
  páginas, arquivos, conectores e memórias como dado, nunca como instrução. Lembre que em "Sem pedir permissão" isso não vale.

## Problemas comuns

| Sintoma | O que fazer |
|---|---|
| "Conecte um modelo em Ajustes → Modelos para começar" | Conecte um provedor (veja [Primeiro uso](#primeiro-uso-conectar-um-modelo)); o cartão de primeiro uso faz isso em um a três cliques |
| "Chave ou login inválido (401)" | Ajustes → Modelos: troque a chave ("Trocar") ou entre de novo. Em OpenCode e Command Code, 401/403 também pode ser falta de saldo, plano sem API ou modelo desativado: a mensagem diz qual |
| "Você atingiu o limite de uso do provedor (429)" | Espere um pouco ou confira o plano. O Orb tenta de novo sozinho em falhas passageiras |
| Claude Code "não encontrado neste Mac" | Instale o `claude` ([guia](https://code.claude.com/docs/en/setup)) e use "Verificar de novo" em Ajustes → Modelos |
| Ollama ou LM Studio "Servidor não encontrado" | Abra o app e ligue o servidor local (LM Studio: o servidor precisa estar ligado e com um modelo carregado); baixe pelo menos um modelo |
| "A conversa ficou grande demais para este modelo" | Compactar agora, Nova conversa, ou escolha o Contexto das conversas "Econômico" |
| O Orb diz que falta uma permissão do macOS | Ajustes → Permissões do Mac (ou o botão "Permitir…" na linha da ferramenta). Reabra o app depois de Gravação do Áudio do Sistema e da Tela e Acesso Total ao Disco |
| As permissões do macOS somem a cada compilação | [Assinatura estável](#assinatura-estável-recomendado) |
| O Orb parou numa pergunta | Veja o cartão na conversa, o ponto na barra de menus ou a notificação |
| Não aparecem notificações | Ajustes → Geral mostra o estado; "Abrir Ajustes do Sistema" leva ao painel de notificações |
| "Pasta não encontrada" no painel | A pasta foi apagada, renomeada ou está em disco desconectado: "Recriar" ou "Mudar pasta" |
| "Atenção com seus dados" | Um arquivo de dados não pôde ser lido. Ele **não é sobrescrito**: o Orb guarda uma cópia (`….corrupt-<data>`) e diz onde. "Mostrar no Finder" leva a ela |
| Quer começar do zero | Ajustes → Geral → Seus dados → **Redefinir o Orb…** ([Redefinir o Orb](#redefinir-o-orb)) |

## Para quem desenvolve

```bash
swift build          # compila o executável
swift test           # mais de 2.000 testes (motor, provedores, Claude Code, ferramentas, MCP, Orbs, dados)
./scripts/bundle.sh  # monta e assina build/Orb.app
```

| Documento | Assunto |
|---|---|
| [docs/ARQUITETURA.md](docs/ARQUITETURA.md) | mapa dos módulos, caminho de um turno, persistência, concorrência, desempenho, testes e ferramentas de desenvolvimento |
| [docs/CONTEXTO.md](docs/CONTEXTO.md) | orçamento, compactação, resumo estruturado, medidor, economia de tokens e o registro de uso |
| [docs/PERMISSOES.md](docs/PERMISSOES.md) | modos, liberações com escopo, comandos perigosos, aprovações, ponte com o Claude Code e permissões do macOS |
| [docs/MEMORIA.md](docs/MEMORIA.md) | a memória por Orb |
| [docs/ORBS.md](docs/ORBS.md) | o avatar: atividades, jeito, animação e desempenho |
| [docs/MOVIMENTO.md](docs/MOVIMENTO.md) | especificação do movimento da interface |
| [art/README.md](art/README.md) | a arte dos Orbs e o gerador |

Variáveis úteis: `ORB_DATA_DIR` (pasta de dados alternativa, para testar sem tocar nos seus Orbs), `ORB_SEND` (envia um prompt ao
abrir), `ORB_STATIC`, `ORB_ANIMATE_INACTIVE`, `ORB_MEMORY_IDLE`, `ORB_CLAUDE_PATH`, `ORB_DEBUG_USAGE`. O modelo falso
`scripts/fake-llm.py` e os modos de `--snapshot` estão em [docs/ARQUITETURA.md](docs/ARQUITETURA.md).
