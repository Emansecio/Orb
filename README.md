<div align="center">

<img src="docs/readme/icon.png" width="128" alt="Ícone do Orb">

# Orb

**Assistentes que conversam com você e fazem o trabalho no seu Mac.**

Cada Orb tem o seu modelo, a sua pasta, a sua memória e as suas permissões. Ele lê e escreve arquivos, roda comandos, navega
na web e usa os seus apps, sempre pedindo antes do que mexe nas suas coisas.

[![Testes](https://github.com/Emansecio/Orb/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/Emansecio/Orb/actions/workflows/tests.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-nativo-1084FE)
![Dados no seu Mac](https://img.shields.io/badge/dados-no%20seu%20Mac-6E5CFF)

[**Instalar**](#instalar) · [**Primeiro uso**](#primeiro-uso) · [**O que ele faz**](#o-que-ele-faz) ·
[**Manual**](docs/MANUAL.md) · [**Privacidade**](#privacidade) · [**Para quem desenvolve**](#para-quem-desenvolve)

<br>

<img src="docs/readme/app.png" width="100%" alt="A janela do Orb: seis Orbs na barra lateral e uma conversa em que o Atlas organizou a pasta de Downloads">

</div>

## O que ele faz

<div align="center">

### Faz o trabalho, não só responde

Lê e organiza arquivos, roda comandos, abre apps e páginas da web. Você vê cada passo numa linha só<br>
("Trabalhou por 1 min 35 s · rodou 3 comandos") e recebe o resultado pronto, com tabelas, listas e código.

<br>

### Pede antes de agir

Tudo que mexe nas suas coisas passa por você: **Permitir** só aquela vez, só nesta tarefa ou sempre,<br>
**Não permitir**, ou **Dizer o que fazer em vez disso**. Comandos perigosos perguntam sempre.

<img src="docs/readme/permission.png" width="820" alt="Cartão de permissão: o Orb pede para rodar brew upgrade no Terminal">

<br>

### Crie um Orb conversando

Conte para que você quer ajuda e ele monta o resto: nome, papel, instruções e o que pode fazer.<br>
Depois escolha a cara dele, com cor, olhos, boca, cabelo e acessórios.

<img src="docs/readme/create.png" width="49%" alt="Criar um Orb conversando: o assistente pergunta e a prévia se monta ao lado"> <img src="docs/readme/appearance.png" width="49%" alt="Aparência do Orb: grade de cores com a prévia em cima">

<br>

### Orbs que trabalham juntos

Num grupo, um Orb orquestra: divide o pedido, chama quem sabe cada parte e junta tudo para você.

<img src="docs/readme/group.png" width="820" alt="Grupo Lançamento: o Atlas orquestra o Pesquisador e o Revisor">

<br>

### Rotinas que rodam sozinhas

Resumo da manhã, revisão da semana, metas com progresso. O Orb faz no horário e você lê o resultado depois.

<img src="docs/readme/routines.png" width="820" alt="Página de Rotinas com quatro rotinas, duas delas com metas e progresso">

<br>

### Conectado aos seus serviços

Gmail, Google Agenda, Slack, Notion, GitHub e outros, mais qualquer servidor do registro oficial do MCP<br>
e as skills do catálogo aberto Skills.sh.

<img src="docs/readme/connectors.png" width="820" alt="Galeria de conectores: Gmail, Google Agenda, Slack, Notion, GitHub, Supabase, Linear, Atlassian e Sentry">

<br>

### Da barra de menus, e sem surpresa no custo

Pergunte a um Orb sem abrir o app e acompanhe quanto cada Orb e cada modelo gastou.

<img src="docs/readme/quickask.png" height="420" alt="Pergunta rápida na barra de menus com a resposta do Atlas"> <img src="docs/readme/usage.png" height="420" alt="Uso e custos: gasto por dia, por Orb">

<br>

### Um jeito para cada Orb

Cada Orb tem a sua cara e mostra o que está fazendo: falando, pensando, no Terminal, buscando,<br>
precisando de você, feliz com o resultado ou dormindo.

<img src="docs/readme/orbs.png" width="820" alt="Sete Orbs diferentes em nove expressões: parado, falando, pensando, terminal, buscando, precisa de você, feliz, erro e dormindo">

</div>

## Instalar

O Orb ainda não tem versão pronta para baixar: você gera o app no seu Mac. O app roda no **macOS 14 ou mais novo** (o ditado
pede o macOS 26); para compilar, precisa do **Xcode 26 ou mais novo** (Swift 6.2+), porque o código usa APIs do SDK do macOS 26.

```bash
git clone https://github.com/Emansecio/Orb.git
cd Orb
./scripts/bundle.sh && open build/Orb.app
```

Se tiver mais de um Xcode, confira qual está ativo com `xcodebuild -version` (troque com `sudo xcode-select -s
/Applications/Xcode.app`). A primeira compilação leva alguns minutos.

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

## Primeiro uso

<p align="center"><img src="docs/readme/welcome.png" width="720" alt="Tela de boas-vindas: três Orbs e os caminhos para conectar um modelo"></p>

Na primeira abertura já existe um Orb, o **Atlas**. Para ele começar, conecte um modelo pelo cartão que aparece no chat:

| Caminho | Para quem |
|---|---|
| **Usar meu Claude Code** | tem Claude Pro ou Max e o `claude` instalado |
| **Entrar com ChatGPT** | tem ChatGPT Plus ou Pro |
| **Ollama ou LM Studio** | quer o modelo rodando no Mac, sem a conversa sair dele |
| **Colar uma chave de API** | OpenAI, Claude, xAI ou OpenRouter |

OpenCode, Command Code e gateways próprios ficam em Ajustes → Modelos. Veja a [lista completa de provedores](docs/MANUAL.md#primeiro-uso-conectar-um-modelo).

## Manual

O passo a passo de cada tela está em **[docs/MANUAL.md](docs/MANUAL.md)**.

| Assunto | O que tem lá |
|---|---|
| [Boas-vindas](docs/MANUAL.md#a-tela-de-boas-vindas) e [a janela](docs/MANUAL.md#a-janela) | a primeira tela, a barra lateral, o estado de cada Orb e o painel dele |
| [Criar um Orb](docs/MANUAL.md#criar-um-orb) | criar conversando, aparência, pasta, modelo, navegador e pesquisa |
| [Conversar](docs/MANUAL.md#conversar) | anexos, ditado, respostas em Markdown, editar e refazer, buscar na conversa |
| [Permissões](docs/MANUAL.md#permissões) | modos, cartões de aprovação, liberações, instruções da pasta |
| [Permissões do macOS](docs/MANUAL.md#permissões-do-macos) | Automação, Acessibilidade, Tela, apps em segundo plano |
| [Memória](docs/MANUAL.md#memória) | o que cada Orb lembra, "memorize isso", esquecer e desfazer |
| [Conversas e rotinas](docs/MANUAL.md#conversas-e-rotinas) | a conversa de cada Orb e as tarefas agendadas |
| [Contexto](docs/MANUAL.md#contexto-da-conversa) e [Uso e custos](docs/MANUAL.md#uso-e-custos) | quando a conversa é resumida e quanto cada Orb gastou |
| [Conectores e skills](docs/MANUAL.md#conectores-e-skills) | galeria de serviços, MCP, skills do Skills.sh |
| [Atalhos](docs/MANUAL.md#atalhos) e [Barra de menus](docs/MANUAL.md#barra-de-menus-e-pergunta-rápida) | teclado, pergunta rápida e permissões sem abrir o app |
| [Redefinir o Orb](docs/MANUAL.md#redefinir-o-orb) e [Problemas comuns](docs/MANUAL.md#problemas-comuns) | começar do zero e o que fazer em cada aviso |

## Privacidade

- **Tudo fica no seu Mac**: conversas, memórias e ajustes são arquivos em `~/Library/Application Support/Orb`, e as chaves ficam
  no Keychain. O Orb não envia estatísticas nem relatórios de erro.
- **O modelo vê a conversa**: cada mensagem vai ao provedor que você escolheu, com o histórico e o que as ferramentas leram.
  Com Ollama ou LM Studio, ela não sai do Mac.
- **Nada acontece sem você**: o que muda coisas ou sai do Mac passa pelas permissões (a não ser no modo "Sem pedir
  permissão"), e o que vem de páginas e arquivos é tratado como dado, nunca como ordem.

Em detalhe, inclusive cada conexão que o app faz: [Privacidade no manual](docs/MANUAL.md#privacidade).

## Para quem desenvolve

```bash
swift build          # compila o executável
swift test           # mais de 3.900 testes (motor, provedores, Claude Code, ferramentas, MCP, Orbs, dados)
./scripts/bundle.sh  # monta e assina build/Orb.app
./scripts/readme-shots.sh  # refaz as imagens deste README (docs/readme), com dados inventados
```

| Documento | Assunto |
|---|---|
| [docs/ARQUITETURA.md](docs/ARQUITETURA.md) | mapa dos módulos, caminho de um turno, persistência, concorrência, desempenho, testes e ferramentas de desenvolvimento |
| [docs/CONTEXTO.md](docs/CONTEXTO.md) | orçamento, compactação, resumo estruturado, medidor, economia de tokens e o registro de uso |
| [docs/PERMISSOES.md](docs/PERMISSOES.md) | modos, liberações com escopo, comandos perigosos, aprovações, o Claude Code como cano e permissões do macOS |
| [docs/MEMORIA.md](docs/MEMORIA.md) | a memória por Orb |
| [docs/ORBS.md](docs/ORBS.md) | o avatar: atividades, jeito, animação e desempenho |
| [docs/MOVIMENTO.md](docs/MOVIMENTO.md) | especificação do movimento da interface |
| [art/README.md](art/README.md) | a arte dos Orbs e o gerador |

Variáveis úteis: `ORB_DATA_DIR` (pasta de dados alternativa, para testar sem tocar nos seus Orbs), `ORB_SEND` (envia um prompt ao
abrir), `ORB_STATIC`, `ORB_ANIMATE_INACTIVE`, `ORB_MEMORY_IDLE`, `ORB_CLAUDE_PATH`, `ORB_DEBUG_USAGE`. O modelo falso
`scripts/fake-llm.py` e os modos de `--snapshot` estão em [docs/ARQUITETURA.md](docs/ARQUITETURA.md).
