# Memória dos Orbs

Cada Orb nasce com a sua própria memória e ela cresce a cada conversa. Não há servidor nem nada compartilhado entre
Orbs: é uma pasta por Orb dentro do app. O desenho segue o [ai-memory do Akita](https://github.com/akitaonrails/ai-memory),
reduzido a um Orb e rodando dentro do app, sem precisar de LLM.

O lado de quem usa (aba "Memória" do painel, "memorize isso", esquecer e desfazer) está no [README](../README.md). Este
documento descreve o que existe no código. Como a memória se combina com a compactação da conversa: [CONTEXTO.md](CONTEXTO.md).

## Onde fica

```
~/Library/Application Support/Orb/memoria/
  <id do Orb>/
    nucleo/identidade.md      como ele deve funcionar com você (fixa)
    preferencias/*.md         suas preferências com ele (fixas)
    fatos/*.md                fatos sobre você e seu trabalho (não envelhecem)
    procedimentos/*.md        como fazer as tarefas que se repetem (não envelhecem)
    sessoes/*.md              um resumo de cada trecho de conversa (envelhecem e são compactadas)
    _arquivo/                 texto completo das páginas de sessão compactadas (mesmos caminhos)
    index.sqlite              índice de busca (+ -wal e -shm); reconstruível a partir dos .md
  _guardadas/<nome> – <aaaa-mm-dd hh.mm>/    memória de Orbs apagados ou redefinidos com "guardar a memória"
    perfil.json               quem era o Orb: nome, papel e aparência (OrbConfig). Sem liberações, modo nem segredos
    …o resto igual à pasta de um Orb (nucleo/, fatos/, …); com " (2)" no fim se o nome já existia
```

Os arquivos `.md` são a fonte da verdade: dá para abrir no Obsidian, editar à mão ou apagar. A cada ~20 s de uso (e quando
o app volta para a frente) o índice confere as datas dos arquivos e se atualiza (`MemoryBank.reconcile`); se o `index.sqlite`
sumir ou corromper, ele é refeito a partir das páginas (só se perde a contagem de uso).

Uma página é um `.md` com um bloco de campos no topo:

```
---
tipo: fato
titulo: Mora em São Paulo
criado: 2026-10-07T14:32:00Z
atualizado: 2026-10-07T14:32:00Z
origem: orb            (voce | orb | automatico)
compactado: sim        (só sessões compactadas)
entrevista: pendente   (só a identidade: pendente | feita)
---

Texto da página.
```

Campos extras (como `tags` do Obsidian) são mantidos quando o app reescreve a página. Um `.md` sem esse bloco também é lido
(o tipo vem da pasta, o título da primeira linha).

## Tipos

| Tipo (`MemoryKind`) | Rótulo | Pasta | Vai sempre ao prompt | Envelhece |
|---|---|---|---|---|
| `identidade` | Identidade | `nucleo/` | sim (instrução fixa) | não |
| `preferencia` | Preferência | `preferencias/` | sim (instrução fixa) | não |
| `fato` | Fato | `fatos/` | só títulos e o que for relacionado à mensagem | não |
| `procedimento` | Procedimento | `procedimentos/` | só títulos e o que for relacionado | não |
| `sessao` | Conversa | `sessoes/` | só "onde paramos" e o que for relacionado | sim |

No painel os grupos se chamam Preferências, Fatos, Procedimentos e "Resumos de conversas"; a identidade tem bloco próprio
("Como <Orb> funciona").

## Ciclo de vida

| Momento | O que acontece |
|---|---|
| Criar o Orb | Nasce a pasta com `identidade.md` (o texto de "Como funciona", se você escreveu). Com "Na primeira conversa, me fazer perguntas" (ligado por padrão), a identidade fica com `entrevista: pendente` |
| Primeira conversa | Nas primeiras mensagens (até a 4ª sua) o Orb se apresenta, faz 2–4 perguntas (ou ajuda primeiro, se você já chegou pedindo algo) e guarda as respostas com `remember` (`identidade` ou `preferencia`). O chat vazio mostra o atalho "Me conheça"; o menu "Mais opções" da aba Memória tem "Fazer a entrevista de novo". A entrevista termina quando uma identidade ou preferência é guardada, ou quando uma página de sessão com resposta do Orb é salva. Uma primeira conversa sem resposta (sem rede, chave errada) não gasta a entrevista |
| Cada mensagem | `MemoryBank.brief` monta o resumo de memória (abaixo) e o app o entrega ao modelo; uma busca por mensagem, sem processo extra |
| Durante a conversa | `remember` guarda e `recall` busca (veja "Ferramentas") |
| Você pede para guardar | "memorize…", "lembra que…" etc. (`MemoryIntent`, abaixo) |
| 30 min sem mensagens, "Nova conversa", reabrir outra conversa, abrir o app, **ou quando a conversa é compactada** | O trecho ainda não salvo (`Conversation.memorySavedCount`) vira uma página em `sessoes/`. Quando o começo da conversa vira resumo para caber na janela do modelo (sozinho ou em "Compactar agora"), o que ele continha é gravado **antes**, uma vez. Execuções de rotinas não viram sessões |
| Uma vez por dia (durante o uso) | Varredura de envelhecimento (`MemoryBank.sweep`): sessões frias são compactadas (abaixo) |
| Apagar o Orb | O diálogo oferece **Apagar com a memória** ou **Apagar e guardar a memória** (grava o último trecho, escreve `perfil.json` e move a pasta para `_guardadas/`; a barra lateral avisa "Guardando a memória de <Orb>…" e, quando a pasta já foi movida, "Memória de <Orb> guardada" com "Mostrar no Finder", que abre a pasta exata) |
| Redefinir o Orb | Ajustes → Geral → "Redefinir o Orb…". Com **Guardar as memórias**, a memória de cada Orb vai para `_guardadas/` do mesmo jeito (o último trecho da conversa vira página em `sessoes/` antes, e o perfil é escrito); com **Apagar tudo, inclusive as memórias**, a pasta `memoria/` inteira some, as guardadas também. Veja "Redefinir o Orb" no [README](../README.md#redefinir-o-orb) e em ARQUITETURA.md |
| Criar um Orb a partir de uma memória guardada | Em "Novo Orb" → "Começar de" → "Memória". Escolher uma preenche nome, papel e aparência (`KeptMemory.fill`); voltar a "Nenhuma (Orb novo)" ou trocar de memória devolve o que ainda está como a memória deu (`unfill`, com o `StartSnapshot` de antes) e mantém o que você digitou. A pasta guardada é **movida** (`MemoryLibrary.adopt`, um `rename`: sai de `_guardadas/`) para `memoria/<id do novo Orb>/`; o índice e o perfil velhos são apagados e o índice é refeito a partir das páginas (`MemoryBank.startFromKept`). O que você escreveu em "Como deve funcionar" é somado à identidade. **A entrevista conta como feita** quando a memória tem identidade ou preferências (ou se você a desligou); sem nenhuma das duas, segue o que você escolheu. Se a pasta não puder ser movida, o Orb nasce com memória nova e avisa na conversa |

`ORB_MEMORY_IDLE=<segundos>` troca os 30 minutos (testes ponta a ponta).

### Página de sessão

`SessionSummary.page(from:)` escreve a página a partir das regras, sem modelo, em `sessoes/aaaa-mm-dd-hhmm-<id>.md`. O título
é o primeiro pedido (70 caracteres). Seções, todas de uma linha por entrada e com segredos removidos antes de qualquer corte:

- **Pedidos**: os 12 últimos, com a hora e os anexos;
- **Decisões**: só as ditas por extenso ("decidi", "vamos usar", "a partir de agora", "prefiro", "nunca use…"), as 8 últimas;
- **O que foi feito**: as ferramentas usadas (até 15; as de memória não contam);
- **Arquivos e links**: caminhos, URLs e trechos `código` vistos nas ferramentas (até 15);
- **Última resposta**: até 700 caracteres;
- **Pendências**: chamadas que falharam ("Não deu certo: …"), ações que você negou e pedido que ficou sem resposta.

## O que entra no prompt

`MemoryBank.brief(for:conversationIsNew:…)` devolve um `MemoryBrief` de **até 6 000 caracteres** (~1 700 tokens),
qualquer que seja o tamanho da memória. Ele se divide em duas partes, por causa do cache do provedor:

| Parte | Vai em | Conteúdo |
|---|---|---|
| `stable` | prompt do sistema (igual de uma mensagem para outra) | identidade (até 1 500 caracteres: o começo e o fim, onde ficam as notas mais novas), preferências (até 1 500: as 40 mais novas, 240 caracteres cada), a entrevista enquanto pendente (até a 4ª mensagem sua) e a linha de como usar `remember`/`recall` |
| `notes` | prefácio da mensagem (`<orb_context>`), dentro de `<memory_notes>` | até **3 lembranças ligadas à mensagem** (220 caracteres cada, 900 no total); "onde paramos" (até 900, **só ao começar uma conversa nova**); títulos de outros fatos (12) e procedimentos (8) |

Detalhes que importam:

- **Relacionadas** (`MemoryBank.related`): a busca roda em toda mensagem, então é seletiva. Agradecimentos e saudações não
  buscam nada; verbos e palavras de pergunta ("você lembra…", "quantos…") não contam como assunto; `nome` e `anos` só valem
  se forem tudo o que há; com 3 ou mais palavras de assunto, a página precisa ter pelo menos 2.
- **Sem repetir**: cada linha leva um id curto da página (`- [Fato, 07/10/2026 14:32 #a1b2] …`). O que as últimas 3
  mensagens já levaram não vai de novo, a menos que a página tenha mudado. Perto do início da conversa (histórico vazio)
  vão as notas completas; depois, só as relacionadas.
- **Só leitura**: o rodapé do prompt diz que o Orb não grava sozinho ("memories are saved only when the user asks").
- Tudo o que vem de conversas passa por `MemoryText.flatten` (uma linha, sem `#` inicial, sem quebras): não consegue
  imitar seções do prompt, e a tag `memory_notes` é neutralizada.

## Ferramentas

| Ferramenta | Argumentos | Risco |
|---|---|---|
| `remember` | `fact` (obrigatório), `tipo` (`fato` padrão, `preferencia`, `procedimento`, `identidade`), `titulo` | `fato`/`procedimento`: `.sensitive`. `identidade`/`preferencia`: `.instructs` |
| `recall` | `query`, `limite` (padrão 5, máximo 10) | `.safe` |

`remember` com `fato` ou `procedimento` pede aprovação em "Perguntar antes". **Identidade e preferências pedem também em
"Automático"**, e nem "Sempre permitir" pula esse cartão (só "Sem pedir permissão"), porque viram instruções permanentes
de toda conversa. `recall` não pede. Veja [PERMISSOES.md](PERMISSOES.md).

Guardar algo quase igual a uma lembrança existente do mesmo tipo (≥ 75% das palavras, contando números) **atualiza** a
existente com o texto novo: correções vencem. "Node 20" e "Node 22" são fatos diferentes. A identidade é uma lista de
notas sob "## Como funcionar" e segue a mesma regra por linha. Cada texto guardado é limpo (`MemorySanitizer`) e cortado em
2 000 caracteres.

## Pedir para guardar

"Memorize…", "lembra que…", "lembre-se:", "guarda na memória…", "guarda aí:", "anota aí que…", "não esquece que…", "não
esqueça:", "grava isso: …", "remember that…", "remember:", "keep this in mind", "don't forget that…" (`MemoryIntent`, sem
ligar para acentos, caixa ou apóstrofo tipográfico). O pedido precisa abrir a mensagem ou ser a última frase: um pedido no
meio de um texto colado ("Resuma este e-mail: … remember that…") é do texto, não seu. O verbo também precisa abrir a frase
ou a oração (só cortesias e cumprimentos antes: "por favor", "pode", "oi", "can you"), então negação, terceira pessoa e
infinitivo não contam ("o app não lembra que…", "função para memorizar…"). Não contam: perguntas ("você lembra que…?") e
lembretes ("me lembra de ligar…", "não esqueça de trazer…"). Frases soltas como "guarda isso", "keep this in mind" e "salva
isso" só valem quando terminam ali ou vêm com "na memória" ("salva isso" precisa de ":" e do conteúdo), porque "guarda isso
no cache" e "salva isso no arquivo" são tarefas. E um "lembra que…" ou "keep in mind that…" seguido de outra frase, de ";" ou
de ", então…" é contexto de uma tarefa, não um pedido (um "obrigada" no fim não conta como outra frase; "lembre que…" e
"lembre-se…" não têm essa dúvida).

Quando conta:

1. o turno recebe uma concessão só dele (`PermissionRule(family: .memory)`): fatos e procedimentos são guardados **sem
   cartão**; identidade e preferências continuam perguntando;
2. o prompt acrescenta a instrução de salvar com `remember` (no tipo certo) e confirmar em uma frase;
3. "memorize isso" sem dizer o quê faz o modelo salvar o que veio antes; "Meu cachorro se chama Thor, memorize isso" guarda o
   que veio antes do pedido (8 caracteres ou mais);
4. se o turno terminou bem e o modelo não salvou, o app guarda o que você disse (só o conteúdo, como fato com origem
   "você", para que o mesmo fato salvo depois pelo modelo seja reconhecido) e escreve na conversa "Guardado na memória: …" (com o botão "Ver na memória", que abre a aba Memória do painel);
   se não deu para saber o quê, avisa "Não deu para saber o que guardar na memória. Diga, por exemplo: "memorize que …"".
   Isso vale também em "Só leitura", onde o `remember` do modelo seria recusado: o pedido é seu. Se você negou o cartão do
   `remember`, o app respeita o "não" e só avisa "Não guardei na memória: você negou.".

O prompt de uma rotina nunca é lido como pedido para guardar. Uma mensagem que você escreve com o Orb trabalhando e que
contém o pedido leva a mesma instrução (e o app a trata como mensagem própria se ela só for enviada depois do turno).

## Esquecer e desfazer

"Esquecer" (painel, tela "Memória de <Orb>") apaga a página e o texto arquivado dela (`MemoryBank.forget`: só
`fatos/`, `preferencias/`, `procedimentos/` e `sessoes/`; a identidade se edita). Antes de apagar, o app guarda o texto em
memória (`ForgottenMemory`) e mostra "<Orb> esqueceu isso. Desfazer" por 10 s (a contagem espera enquanto o mouse ou o foco
estão no aviso); ⌘Z também desfaz, a menos que um campo de texto tenha algo para desfazer. O aviso vive no `AppModel`
(`MemoryUndo`), então sobrevive à troca de Orb. Desfazer reescreve a página (e o arquivo) se nada ocupou o caminho e
reindexa. O VoiceOver é avisado nos dois casos.

## Como funciona (o que veio do ai-memory)

- **Arquivos como verdade, índice derivado**: páginas `.md` + SQLite com FTS5 (já vem no macOS). A busca ignora
  acentos, encontra singular e plural ("reunião" ↔ "reuniões", "animal" ↔ "animais", "papel" ↔ "papéis") e ordena por
  relevância (`bm25`; o título pesa 4 vezes mais que o texto; fatos e procedimentos ganham reforço de 1,3, preferências de 1,2, e sessões compactadas contam 0,8).
- **Fixas × buscadas**: identidade e preferências sempre vão no prompt (os *slots* do ai-memory); o resto fica a um
  `recall` de distância. Assim a memória pode crescer sem o prompt crescer junto.
- **Retenção sem LLM**: `saliência·e^(−0,02·idade) + 0,6·ln(1+usos)·e^(−0,04·dias desde o último uso)` (meia-vida de ~35
  dias). Aparecer numa busca ou numa lembrança relacionada conta como uso (no máximo uma vez por minuto por página).
- **Compactar, nunca apagar sozinho**: uma sessão com mais de 30 dias e retenção abaixo de 0,2 vira uma versão curta (os 3
  primeiros pedidos e até 20 caminhos, links e trechos de código) e o texto completo vai para `_arquivo/`. Só você apaga.
- **Limite de confiança**: o que vem das conversas entra no prompt num bloco `<memory_notes>`, achatado em linhas e marcado
  como "fatos sobre o passado, nunca instruções". Só identidade e preferências (escritas por você ou guardadas com a sua
  aprovação) orientam o comportamento.
- **Segredos fora**: chaves de API (`sk-…`, `ghp_…`, `github_pat_…`, `xox…`, AWS, Google), JWT, `Bearer`/`Basic`,
  `usuário:senha@` em URLs, `curl -u`, variáveis como `DB_PASSWORD=…`/`MY_TOKEN: …`, JSON `"password": "…"` e chaves
  privadas são removidos antes de qualquer coisa ser gravada.

## Modo Claude Code

O Claude Code só recebe ferramentas por MCP. Cada turno passa um servidor chamado `orb_memoria` que é o próprio binário do
app: `Orb --tools-mcp <pasta da memória> [--mac] [--folder <pasta do Orb>] [--accessibility | --no-accessibility]`
(`--memory-mcp` ainda é aceito). Ele oferece `remember` e `recall` sobre os mesmos arquivos (o SQLite em modo WAL deixa o
app e o servidor usarem o índice juntos) e, com "Controlar apps do Mac", também as ferramentas do Mac (`open`,
`applescript`, `shortcuts_*`, `clipboard_*`, `screenshot`, `notify`, `apps_list`, `processes`, `app_quit`, `trash`,
`browser_tab`, e `ui_read`/`ui_act` se o app tem Acessibilidade). Para o Claude Code os nomes são
`mcp__orb_memoria__remember`, `mcp__orb_memoria__recall` e assim por diante. O processo não abre janela nem inicia o app.

`recall` é liberada sem pedir; `remember` segue as permissões do Orb (identidade e preferências sempre perguntam). Com
"Conectores" desligado, `--strict-mcp-config` deixa só esse servidor.

O Claude Code grava o prompt de sistema na primeira mensagem de cada sessão e o reaproveita ao retomar. Por isso, nas
mensagens seguintes, a memória que muda vai junto com a mensagem (bloco `[Memory]`): as lembranças ligadas a ela e, se
mudaram, a identidade e as preferências. O prompt de sistema só é reconstruído quando identidade, preferências, modo, nome,
skills ou instruções da pasta mudam. O histórico do próprio Claude Code (`~/.claude/projects/`) guarda o que já foi dito;
"Esquecer" no Orb não apaga esse histórico.

## Concorrência e custo

Cada Orb tem um `MemoryBank` (actor), então todas as escritas daquele Orb passam por uma fila só. `MemoryLibrary.at(pasta)`
devolve uma biblioteca única por pasta de dados, compartilhada por todo o processo. Apagar o Orb ou guardar a memória
**fecha** o banco (`close()`): uma tarefa atrasada não recria a pasta. O índice abre na primeira vez que é usado, fora da
thread principal. Não há processo nem timer extra: o trabalho acontece no começo de cada mensagem (resumo), no fim de cada
trecho de conversa (página de sessão), na varredura diária e na conferência dos arquivos a cada ~20 s de uso.

## Mapa do código

| Arquivo | Papel |
|---|---|
| `Memory/MemoryPage.swift` | `MemoryKind`, formato `.md`, `MemoryText` (palavras, semelhança, busca, achatar), `MemorySanitizer` (segredos) |
| `Memory/MemoryIndex.swift` | SQLite (tabela + FTS5 + gatilhos, esquema versionado) |
| `Memory/MemoryBank.swift` | a memória de um Orb (actor): identidade, `remember`, `recall`, `related`, `brief`, sessões, envelhecimento, `forget`, `startFromKept`; `MemoryLibrary` (uma por Orb, apagar/guardar/adotar, `seal` na redefinição) |
| `Memory/KeptMemories.swift` | `_guardadas`: `KeptProfile` (`perfil.json`), `KeptMemory` (o que o menu "Começar de" e Ajustes listam), guardar, listar, contar, adotar |
| `Memory/SessionSummary.swift` | trecho de conversa → página de sessão, sem LLM; `idleGap` |
| `Memory/MemoryIntent.swift` | reconhece "memorize…" e o que guardar |
| `Memory/OrbToolsMCPServer.swift` | servidor MCP stdio (`--tools-mcp`) para o Claude Code |
| `Engine/Tools/MacTools.swift` | ferramentas `remember` e `recall` |
| `BotSession+Conversation.swift` | `pendingStretch`, `saveMemory`, `keepRequestedMemory`, `scheduleMemorySave`, `announce` |
| `AppModel.swift` (MARK: Memory) | criar, migrar (`prepareMemory`), esquecer, identidade, entrevista |
| `AppModel+MemoryUI.swift` | `ForgottenMemory`, `MemoryUndo` |
| `Views/MemoryViews.swift`, `Views/InspectorSupport.swift` | aba Memória, tela de memória, grupos e busca |
| `Tests/OrbAppTests/MemoryTests.swift`, `RelatedMemoryTests.swift`, `PanelUITests.swift` | testes |

Versões anteriores guardavam uma lista simples em `state.json` (`Bot.memory`); na abertura (`prepareMemory`) ela vira páginas
em `fatos/` e só sai do `state.json` quando todas foram gravadas.
