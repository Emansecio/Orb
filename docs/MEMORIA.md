# Memória dos Orbs

Cada Orb nasce com a sua própria memória e ela cresce a cada conversa. Não há servidor nem nada compartilhado entre
Orbs: é uma pasta por Orb dentro do app. O desenho segue o [ai-memory do Akita](https://github.com/akitaonrails/ai-memory),
reduzido a um Orb e rodando dentro do app, sem precisar de LLM (a página de uma conversa compactada pode levar a nota que o
modelo escreveu sobre o trecho, veja abaixo; sem ela, a página é a mesma).

O lado de quem usa (aba "Memória" do painel, "memorize isso", esquecer e desfazer) está no [manual](MANUAL.md#memória). Este
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
    _propostas/<comando>.md   skills que o Orb propôs e esperam a sua decisão (não são páginas de memória)
    _skills.json              cópia das skills que o Orb pode usar, escrita pelo app (não é página de memória)
    _arquivo/                 texto completo das páginas de sessão compactadas (mesmos caminhos)
    _arquivo/atualizacoes/<página>/<ms>.md   o texto anterior de cada página que uma correção substituiu
    index.sqlite              índice de busca (+ -wal e -shm; o -wal volta a no máximo 1 MB a cada checkpoint, de hora em hora); reconstruível a partir dos .md
  _guardadas/<nome> – <aaaa-mm-dd hh.mm>/    memória de Orbs apagados ou redefinidos com "guardar a memória"
    perfil.json               quem era o Orb: nome, papel e aparência (OrbConfig). Sem liberações, modo nem segredos
    …o resto igual à pasta de um Orb (nucleo/, fatos/, …); com " (2)" no fim se o nome já existia
```

Os arquivos `.md` são a fonte da verdade: dá para abrir no Obsidian, editar à mão ou apagar. A cada ~20 s de uso (e quando
o app volta para a frente) o índice confere as datas dos arquivos e se atualiza (`MemoryBank.reconcile`). O resumo de cada
mensagem (`brief`) não espera essa conferência: usa o índice como está, e a edição feita por fora entra no fim do turno. Uma
pasta que existe mas não lista (sem permissão) não tem as páginas tiradas do índice: elas ficam, com a contagem de uso. Se o `index.sqlite`
sumir ou corromper, ele é refeito a partir das páginas (só se perde a contagem de uso). Só a corrupção apaga o arquivo: um
índice que outro processo está usando (por exemplo, o app reconstruindo) ou uma pasta que não
abre não são apagados, e abrir um índice já certo não escreve nada, então não espera a trava. Se não abriu, o banco tenta de
novo a cada 30 s (`indexRetryInterval`) em vez de ficar sem busca a sessão inteira.

O painel lê a memória por `MemoryBank.snapshot()`. No fim de cada turno o app pede `snapshotIfChanged()`: o banco compara uma
chave barata (quantas páginas, somas de datas e da marca de compactada, e a identidade) com a do último snapshot e só relê
e manda as páginas, com o corpo, quando algo mudou; com milhares de páginas de sessão, o resto do tempo não custa nada.

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
(o tipo vem da pasta, o título da primeira linha). Notas de outros programas também são lidas: com BOM no início, em
Latin-1/Windows (regravadas em UTF-8 só se o app reescrever a página) ou com data sem hora (`criado: 2026-10-07` é esse dia
no fuso do Mac). Uma régua `---` no topo só abre o bloco de campos se houver pelo menos uma linha `chave: valor`; uma régua
seguida de lista fica no texto. Um título que começa e termina com aspas é gravado com um par a mais, para voltar igual.

## Tipos

| Tipo (`MemoryKind`) | Rótulo | Pasta | Vai sempre ao prompt | Envelhece |
|---|---|---|---|---|
| `identidade` | Identidade | `nucleo/` | sim (instrução fixa) | não |
| `preferencia` | Preferência | `preferencias/` | sim (instrução fixa) | não |
| `fato` | Fato | `fatos/` | só títulos e o que for relacionado à mensagem | não |
| `procedimento` | Procedimento | `procedimentos/` | só títulos e o que for relacionado | não |
| `sessao` | Conversa | `sessoes/` | só "onde paramos" e o que for relacionado | sim |

No painel os grupos se chamam Preferências, Fatos, Procedimentos e "Resumos de conversas"; a identidade tem bloco próprio
("Como <Orb> funciona"). Uma conversa fechada mostra só o título; aberta, mostra embaixo, em texto pequeno, o último resumo,
as últimas decisões ("Decidido: …") e o que ficou pendente (`MemoryRow.details(of:)`, até 3 de cada). As notas crescem com o que o Orb aprende (cada nota até 2.000 caracteres), então o editor aceita até
12.000 caracteres (`MemoryBank.identityMaximumLength`) e, passando disso, avisa e bloqueia o Salvar em vez de cortar o fim.

## Ciclo de vida

| Momento | O que acontece |
|---|---|
| Criar o Orb | Nasce a pasta com `identidade.md` (o texto de "Como funciona", se você escreveu). Com "Na primeira conversa, me fazer perguntas" (ligado por padrão), a identidade fica com `entrevista: pendente` |
| Primeira conversa | Nas primeiras mensagens (até a 4ª sua) o Orb (já cumprimentado pelo app) faz 2–4 perguntas (ou ajuda primeiro, se você já chegou pedindo algo) e guarda as respostas com `remember` (`identidade` ou `preferencia`). Ao criar o Orb, o chat mostra a saudação dele (`TranscriptItem.Kind.greeting`, escrita pelo app: não vai ao modelo, não conta no contexto nem vira página de sessão) com a resposta rápida "Me entreviste", que envia o mesmo pedido do atalho "Me conheça" do chat vazio de uma conversa nova; o menu "Mais opções" da aba Memória tem "Fazer a entrevista de novo". A entrevista termina quando uma identidade ou preferência é guardada, ou quando uma página de sessão com resposta do Orb é salva. Uma primeira conversa sem resposta (sem rede, chave errada) não gasta a entrevista |
| Cada mensagem | `MemoryBank.brief` monta o resumo de memória (abaixo) e o app o entrega ao modelo; uma busca por mensagem, sem processo extra |
| Durante a conversa | `remember` guarda e `recall` busca (veja "Ferramentas") |
| Você pede para guardar | "memorize…", "lembra que…" etc. (`MemoryIntent`, abaixo) |
| 30 min sem mensagens, abrir o app, **ou quando a conversa é compactada** | O trecho ainda não salvo (`Conversation.memorySavedCount`) vira uma página em `sessoes/`. Quando o começo da conversa vira resumo para caber na janela do modelo (sozinho ou em "Compactar agora"), o que ele continha é gravado **antes**, uma vez, com a nota do modelo sobre o trecho quando existe (vale também para a dobra feita no meio de um turno, gravada no fim dele). Execuções de rotinas não viram sessões |
| Uma vez por dia (durante o uso) | Varredura de envelhecimento (`MemoryBank.sweep`), no fim de um turno, nunca antes dele: sessões frias são compactadas (abaixo), no máximo 50 por passada (`sweepBatch`); o resto fica para o turno seguinte |
| Fim de um turno concluído, com mais de 30 notas e preferências fixadas | `MemoryConsolidation`, em segundo plano e sem aviso: uma chamada sem ferramentas ao modelo barato do Orb junta as que dizem o mesmo, fica com a mais nova quando duas discordam e larga o que era de uma conversa só. As listas antigas vão para `_arquivo/consolidacoes/<ts>.md`; uma passagem que não deu em nada só tenta de novo no dia seguinte |
| Fim de um turno concluído, com 40 fatos e procedimentos escritos pelo Orb (e depois a cada 20 a mais) | `MemoryMerge` **propõe** juntar páginas parecidas. Agrupa só páginas do mesmo tipo, parecidas com a primeira do grupo (`MemoryText.similarity` ≥ 0,25, sem encadear; até 5 por grupo e 6 grupos), e manda cada grupo ao modelo barato, que responde `KEEP` quando os assuntos diferem ou as páginas se contradizem. Uma fusão que perde um caminho, URL, código ou número de 2+ dígitos, ou fica maior que as fontes juntas, é recusada (nunca cortada). Nada muda até você clicar **Unificar** no aviso “Unificação de memória proposta: …” (a proposta fica em `_unificacao.json` por 7 dias e bloqueia outra; o botão só aparece no aviso que mostra a proposta que ainda espera, e uma proposta que a rotina pegaria no meio não é gravada). Ao aplicar, cada grupo cuja página mudou ou sumiu desde a proposta é pulado; os originais vão inteiros para `_arquivo/consolidacoes/unificacao-<ts>-<n>-<título>.md` e a página nova guarda a data de criação da mais antiga. Páginas que você escreveu, sessões e preferências ficam de fora. Não roda durante uma rotina nem num Orb só leitura |
| Criar um Orb a partir de uma importação | Em "Novo Orb" → "Começar de" → "Importar de outro assistente". `OrbImportReader` (`Import/`, sem UI, fora da main thread) lê o que foi colado, escolhido ou solto (Cartão do Orb em Markdown, Character Card V1/V2/V3, pasta do Hermes/OpenClaw por lista fechada, texto livre) e a prévia mostra cada item com caixa de seleção; os suspeitos (`ImportGuard`) vêm desmarcados. `OrbImport.plan()` aplica a seleção e os limites: a identidade vai até 1.500 caracteres (`identityShare`; acima disso o texto inteiro também vira fatos de até `maximumLength` (2.000) caracteres, "Instruções completas de <origem> (1/3)", dentro do teto de 60; a leitura vai até 6.000 e a prévia diz quanto ficou de fora), as preferências até 40 de 240 caracteres e 1.500 no total (`preferencesShare`; o resto vira fato), no máximo 60 fatos, 12 procedimentos e 5 skills. `AppModel.createBot(importing:)` soma a identidade ao que você digitou, grava as páginas por `MemoryBank.importPages` (o mesmo `remember`: dedup e segredos, origem `voce`, porque a prévia é a sua aprovação) e cria as skills com `orbIDs = [novo Orb]` e `source: "importado"`. **A entrevista conta como feita** quando entrou identidade ou preferências. Com uma memória guardada escolhida, a importação é ignorada. Nada de permissões, modo, capacidades, conectores ou rotinas vem do arquivo |
| Apagar o Orb | O diálogo oferece **Apagar com a memória** ou **Apagar e guardar a memória** (grava o último trecho, escreve `perfil.json` e move a pasta para `_guardadas/`; a barra lateral avisa "Guardando a memória de <Orb>…" e, quando a pasta já foi movida, "Memória de <Orb> guardada" com "Mostrar no Finder", que abre a pasta exata) |
| Redefinir o Orb | Ajustes → Geral → "Redefinir o Orb…". Com **Guardar as memórias**, a memória de cada Orb vai para `_guardadas/` do mesmo jeito (o último trecho da conversa vira página em `sessoes/` antes, e o perfil é escrito); com **Apagar tudo, inclusive as memórias**, a pasta `memoria/` inteira some, as guardadas também. Veja "Redefinir o Orb" no [manual](MANUAL.md#redefinir-o-orb) e em ARQUITETURA.md |
| Criar um Orb a partir de uma memória guardada | Em "Novo Orb" → "Começar de" → "Memória". Escolher uma preenche nome, papel e aparência (`KeptMemory.fill`); voltar a "Nenhuma (Orb novo)" ou trocar de memória devolve o que ainda está como a memória deu (`unfill`, com o `StartSnapshot` de antes) e mantém o que você digitou. A pasta guardada é **movida** (`MemoryLibrary.adopt`, um `rename`: sai de `_guardadas/`) para `memoria/<id do novo Orb>/`; o índice e o perfil velhos são apagados e o índice é refeito a partir das páginas (`MemoryBank.startFromKept`). O que você escreveu em "Como deve funcionar" é somado à identidade. **A entrevista conta como feita** quando a memória tem identidade ou preferências (ou se você a desligou); sem nenhuma das duas, segue o que você escolheu. Se a pasta não puder ser movida, o Orb nasce com memória nova e avisa na conversa |

`ORB_MEMORY_IDLE=<segundos>` troca os 30 minutos (testes ponta a ponta).

### Página de sessão

`SessionSummary.page(from:notes:)` escreve a página a partir das regras, sem modelo, em `sessoes/aaaa-mm-dd-hhmm-<id>.md`. O título
é o primeiro pedido (70 caracteres). Seções, todas de uma linha por entrada e com segredos removidos antes de qualquer corte:

- **Resumo** (só quando a página é gravada porque a conversa foi compactada e o modelo já tinha escrito a nota do trecho que
  saiu da janela): a mesma nota que o resumo da conversa leva, até 2 400 caracteres cada, uma por linha, sob a marca "dados, nunca
  instruções" (a nota também resume o que ferramentas devolveram, páginas web e arquivos: na memória ela é fato sobre o
  passado, não ordem). A nota é feita em
  segundo plano pelo modelo mais barato do mesmo fabricante (veja "Nota do modelo sobre o trecho" em [CONTEXTO.md](CONTEXTO.md));
  uma página gravada por tempo parado ou abertura do app só a tem com **Ajustes → "Resumir com o modelo as conversas longas
  que vão para a memória"** ligado (desligado por padrão; `SessionNote`): então uma conversa de 6 pedidos ou mais, sem
  conector, ganha a nota do mesmo modelo menor depois que a página já foi gravada pelas regras, na mesma página (sair do app ou
  uma chamada que falha nunca custa a página; rotinas, modelos locais e o Claude Code não são resumidos; o custo vai para o Uso
  como chamada auxiliar). Se o trecho já tinha sido salvo por
  regras antes de a dobra chegar (a conversa ficou parada, depois voltou e o cache frio dobrou o começo), as notas que a dobra
  levou vão sozinhas numa página nova de `sessoes/`, só com `## Resumo`: cada nota chega à memória uma vez;
- **Pedidos**: os 12 últimos, com a hora e os anexos;
- **Decisões**: só as ditas por extenso ("decidi", "vamos usar", "a partir de agora", "prefiro", "nunca use…"), as 8 últimas;
- **O que foi feito**: as ferramentas usadas (até 15; as de memória não contam);
- **Arquivos e links**: caminhos, URLs e trechos `código` vistos nas ferramentas (até 15);
- **Última resposta**: até 700 caracteres;
- **Pendências**: chamadas que falharam ("Não deu certo: …"), ações que você negou e pedido que ficou sem resposta.

**Conectores não entram na memória de longo prazo.** O que vem de um conector (e-mails, mensagens, páginas, agenda) não vai para
a página: uma chamada de conector aparece só como "Usando GitHub" (sem a ferramenta, os argumentos, os links ou o resultado), e
um trecho que usou conector fica sem "Última resposta", que repetiria o conteúdo. Um cartão de conector que você negou entra em "Pendências" só pelo título ("Você negou: Usando Gmail"), sem a ferramenta nem
os argumentos. Seus pedidos continuam como são. O resumo de
passos da janela de contexto (`ToolDigest`) segue a mesma regra: de uma chamada de conector fica o nome e se deu certo. O que o
próprio modelo guarda com `remember` continua sob as permissões do Orb (identidade e preferências sempre perguntam).

## O que entra no prompt

`MemoryBank.brief(for:conversationIsNew:…)` devolve um `MemoryBrief` de **até 6 000 caracteres** (~1 700 tokens),
qualquer que seja o tamanho da memória. Ele se divide em duas partes, por causa do cache do provedor:

| Parte | Vai em | Conteúdo |
|---|---|---|
| `stable` | prompt do sistema (igual de uma mensagem para outra) | o perfil da usuária (veja abaixo; nada quando vazio), identidade (até 1 500 caracteres: saem primeiro as notas mais antigas, com a marca "(+N older notes left out of this prompt)"; só o seu texto, quando não cabe sozinho, vira começo e fim), preferências (até 1 500, entre as 200 mais novas: cada uma cortada em `max(240, 1 500 ÷ N)`, e as que não cabem viram a linha "(+N older preferences not shown here; recall finds them)"; o painel avisa quantas não cabem inteiras e se a consolidação vai juntá-las, que agora roda também quando elas não cabem, mirando 1 200 caracteres) e a linha de como usar `remember`/`recall` |
| `interview` | prefácio da mensagem, fora de `<memory_notes>` | a entrevista enquanto pendente (até a 4ª mensagem sua). Fica fora do prompt do sistema: o fim dela mudaria a memória congelada ali e mandaria toda a memória de novo (`memory_update`) |
| `notes` | prefácio da mensagem (`<orb_context>`), dentro de `<memory_notes>` | até **3 lembranças ligadas à mensagem** (220 caracteres cada, 900 no total); "onde paramos" (até 900, **só ao começar uma conversa nova**: Resumo, Pedidos sem repetir o que virou decisão, Decisões, Pendências, o que foi feito (só quando não há Resumo, que já diz isso em menos palavras) e a última resposta em 200 caracteres); títulos de outros fatos (12) e procedimentos (8), em que uma série de títulos que só mudam nos números ("Diário 15/10 rodada 23:21", "… 22:21") ocupa uma linha só, a mais nova com "(+N like it)" (`MemoryBank.titleLines`). Os títulos saem de todas as páginas do tipo (até 2 000, só título, `titleItems`), não das mais novas, e as linhas vão pela retenção (usos e recência; a série vale pela sua melhor página), para que um diário de hora em hora não tire da lista os fatos mais usados |

Detalhes que importam:

- **Perfil da usuária** (Ajustes → Geral → Você; `UserProfile.promptSection`, passado em `brief(profile:)`): nome, como te
  chamar e "Sobre você", em até ~750 caracteres e **zero quando vazio**. Entra no começo do `pinned`, não em `SystemPrompt`
  (a base está no teto do `SystemPromptTests`), e vale para todos os Orbs. Não é uma memória: não é
  indexado, o `recall` não o acha e não vai para `_guardadas`. A divisão é: **perfil = quem você é** (global, você edita num
  formulário); **identidade e preferências = como este Orb trabalha com você** (por Orb, o Orb escreve com `remember`). O bloco
  diz ao modelo que, no jeito de trabalhar, identidade e preferências vencem, e para não perguntar o que o perfil já diz.
  Passa por `MemoryText.flatten` e `MemorySanitizer.scrub` (colar uma chave não a envia). Editar o perfil custa uma falha de
  cache (como editar uma preferência).

- **Relacionadas** (`MemoryBank.related`): a busca roda em toda mensagem, então é seletiva. Agradecimentos e saudações não
  buscam nada; verbos e palavras de pergunta ("você lembra…", "quantos…") não contam como assunto; `nome` e `anos` só valem
  se forem tudo o que há. Numa mensagem de 3 palavras ou mais, o `NLTagger` (dos primeiros 2 000 caracteres) separa os
  substantivos e nomes (`MemoryText.topicNouns`): só eles contam no requisito "com 3 ou mais palavras de assunto, a página
  precisa ter pelo menos 2", e com 2 ou mais deles a página precisa casar pelo menos um (um verbo em comum não basta).
  Prefixo na busca só a partir de 4 letras ou com número ("10" acha "10h"); uma palavra de 3 letras acha também o plural
  ("voo" acha "voos"), e "sp" não acha "sprint".
- **Uma vaga por série**: fatos e procedimentos com data ou hora no título que só mudam nos números ("Diário 15/10 rodada
  14:21", "… 15:21") ocupam uma vaga só, no lugar do que melhor casou, com a página mais nova da série que casa com a
  mensagem; as outras ficam para o `recall`. Títulos sem data ("Fato 1 …", "Fato 2 …") e sessões não são série.
- **Pela tarefa em andamento**: uma mensagem que só aponta para trás ("faz igual ao anterior", "continua", "de novo") e
  tem menos de 2 palavras de assunto próprias pega emprestados até 6 termos da tarefa (`MemoryText.lookupTerms`):
  `TurnPreface.taskContext` junta os 2 últimos pedidos da conversa (o mais novo primeiro) e a meta do resumo. Uma mensagem
  com assunto próprio busca só por ele.
- **Sem repetir**: cada linha leva um id curto da página (`- [Fato, 07/10/2026 14:32 #a1b2] …`). O que as últimas 3
  mensagens já levaram não vai de novo, a menos que a página tenha mudado. Perto do início da conversa (histórico vazio)
  vão as notas completas; depois, só as relacionadas.
- **Só leitura**: o rodapé do prompt diz que o Orb não grava sozinho ("memories are saved only when the user asks").
- Tudo o que vem de conversas passa por `MemoryText.flatten` (uma linha, sem `#` inicial, sem quebras): não consegue
  imitar seções do prompt, e a tag `memory_notes` é neutralizada.

## Ferramentas

| Ferramenta | Argumentos | Risco |
|---|---|---|
| `remember` | `fact` (obrigatório), `tipo` (`fato` padrão, `preferencia`, `procedimento`, `identidade`, `skill`), `titulo` | `fato`/`procedimento`: `.sensitive`. `identidade`/`preferencia`: `.instructs`. `skill`: `.safe` |
| `recall` | `query` (com `/nome`: carrega a skill), `limite` (padrão 5, máximo 10) | `.safe` |

`remember` com `fato` ou `procedimento` pede aprovação em "Perguntar antes". **Identidade e preferências pedem também em
"Automático"**, e nem "Sempre permitir" pula esse cartão (só "Sem pedir permissão"), porque viram instruções permanentes
de toda conversa. `recall` não pede. Veja [PERMISSOES.md](PERMISSOES.md).

Guardar algo quase igual a uma lembrança existente do mesmo tipo (≥ 75% das palavras, contando números) **atualiza** a
existente com o texto novo: correções vencem ("Node 20" → "Node 22", "às 10h" → "às 11h"). Não é correção, e vira página nova,
quando uma palavra que só um dos dois tem é um nome (com maiúscula: "cliente Acme" × "cliente Beta") ou um rótulo de 1 ou 2
caracteres ("máquina A" × "máquina B", "SP" × "RJ") (`MemoryBank.isUpdate`, `MemoryText.namesApart`). Antes de atualizar, o
texto anterior vai para `_arquivo/atualizacoes/<página>/`: um limiar errado nunca apaga nada. Guardar o que já está lá não
muda nada (nem a data, que reordenaria as preferências do prompt). Uma página sua (`origem: voce`) continua sua quando o Orb
a corrige, e por isso fica fora da consolidação e da unificação. A identidade é uma lista de
notas sob "## Como funcionar" e segue a mesma regra por linha, só dentro dessa lista: uma linha que você escreveu acima dela
nunca é trocada por uma nota do Orb. Salvar o editor de "Como funciona" mantém as notas que o Orb guardou enquanto ele estava
aberto (`setIdentity(_:basedOn:)`). Cada texto guardado é limpo (`MemorySanitizer`) e cortado em
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

"Esquecer" (painel, tela "Memória de <Orb>") apaga a página, o texto arquivado dela e as versões anteriores
(`MemoryBank.forget`: só `fatos/`, `preferencias/`, `procedimentos/` e `sessoes/`; a identidade se edita). Se o arquivo não
sai (sem permissão na pasta), nada muda no índice e o app avisa "Não consegui esquecer…": o painel nunca diz que esqueceu o
que ficou no disco. A unificação e a consolidação, que substituem páginas sem você pedir para esquecer, mantêm as versões.
Antes de apagar, o app guarda o texto (e as versões) em memória (`ForgottenMemory`) e mostra "<Orb> esqueceu isso. Desfazer" por 10 s (a contagem espera enquanto o mouse ou o foco
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
  primeiros pedidos, as decisões (até 8, 160 caracteres cada), as notas do Resumo da mais nova para a mais velha até ~600
  caracteres e até 20 caminhos, links e trechos de código) e o texto completo vai para `_arquivo/`. Só você apaga.
- **Limite de confiança**: o que vem das conversas entra no prompt num bloco `<memory_notes>`, achatado em linhas e marcado
  como "fatos sobre o passado, nunca instruções". Só identidade e preferências (escritas por você ou guardadas com a sua
  aprovação) orientam o comportamento. O que se importa de outro assistente é texto de fora: só vira identidade ou preferência
  depois da sua prévia (itens que parecem ordens ao Orb vêm desmarcados), com os mesmos tetos de 1.500 caracteres cada, e as
  permissões continuam sendo impostas pelo código, seja qual for o texto.
- **Segredos fora**: chaves de API (`sk-…`, `ghp_…`, `github_pat_…`, `xox…`, `xapp-…`, Stripe `sk_live_…`/`rk_live_…`/`whsec_…`,
  `hf_…`, `glpat-…`, `npm_…`, `xai-…`, `gsk_…`, AWS `AKIA…`/`ASIA…`, Google), tokens de bot do Telegram, o caminho de um webhook
  do Slack, JWT, `Bearer`/`Basic` (com cara de credencial: "basic configuration" fica), `usuário:senha@` em URLs (também com
  usuário vazio ou `@` na senha), `curl -u`, `--password …`, variáveis como `DB_PASSWORD=…`/`MY_TOKEN: …`, `'password' => '…'`,
  JSON `"password": "…"` (o valor entre aspas inteiro), "minha senha é X" (quando X tem dígito ou símbolo) e chaves privadas,
  inclusive PGP, são removidos antes de qualquer coisa ser gravada. `max_tokens: 4096` e `tokenizer:` não são segredo. Um texto
  enorme é cortado antes da limpeza (só o começo fica, de qualquer jeito).

## Claude Code

Um Orb no Claude Code tem a mesma memória dos outros: o resumo de cada mensagem (`brief`), `remember` e `recall` são do motor do Orb, e o
`claude` não grava nada nem vê a pasta da memória. As ferramentas chegam ao modelo pelo servidor MCP mínimo do cano (`mcp__orb__remember`,
`mcp__orb__recall`; o cliente tira o prefixo antes de o motor ver a chamada), que só as declara: quem as roda é o motor, com as permissões
de sempre (`recall` liberada sem pedir; `remember` segue as permissões do Orb, e identidade e preferências sempre perguntam). O CLI também
não guarda histórico: a conversa vai num arquivo de sessão temporário que é apagado quando o processo termina (e o `--no-session-persistence`
impede o resto), então "Esquecer" no Orb não deixa cópia no `~/.claude/projects/`.

## Skills aprendidas

Uma skill é o fluxo inteiro de uma classe de tarefa (passos, armadilhas, como verificar); um procedimento é uma regra curta e
solta ("para publicar: rode os testes e depois o deploy"). O Orb **propõe** skills e você aprova com um clique: nada vira skill
sozinho, porque uma skill vira instrução. Não há ferramenta nova (o teto de caracteres das especificações não comporta): a
skill vai dentro de `remember` e `recall`.

- **Propor.** `remember` com `tipo` `skill` recebe um `SKILL.md` inteiro em `fact` e grava `_propostas/<comando>.md`, sem mudar
  nenhuma memória. A mesma `name` sobrescreve a proposta (e uma skill sua ou aprendida com esse comando é *melhorada*: as
  instruções novas substituem as atuais depois que você aprova). No máximo 5 propostas esperam ao mesmo tempo.
- **A validação recusa proposta rasa** (`SkillProposal.validate`) e devolve ao modelo **todos** os motivos mais o formato, para
  ele melhorar ou desistir: frontmatter com `name` (minúsculas, dígitos e hífens, até 32 caracteres, nome da classe de tarefa, não
  de um incidente: `fix-`/`debug-`, um número com cara de ticket (segmento de 3 dígitos ou mais, 4 dígitos em qualquer lugar,
  `bug123`), `-hoje`; `exportar-x265` e `mp3-para-wav` passam; nem largo demais: "geral", "qualquer", "misc" em qualquer posição, e
  "ajuda", "help" ou "tudo" só quando são o nome inteiro ou "ajuda-geral": `ajuda-declaracao-irpf` e `help-desk-chamados` passam)
  e `description` (20 a 160 caracteres, o que o prompt lista); corpo de 500 a 12 000 caracteres com as seções **Quando usar**,
  **Passos** (3 ou mais itens numerados, 150+ caracteres, **pelo menos 2 concretos** e **pelo menos 1 âncora forte** no
  conjunto), **Armadilhas** (2 ou mais itens, cada um regra e motivo) e **Como verificar** (títulos em português ou em inglês,
  fora de blocos de código). Passo concreto: uma âncora forte (`comando`, arquivo ou caminho, URL, ferramenta do Orb como
  `run_command`, opção, literal entre aspas com 2 palavras ou mais ou com cara de saída esperada: `"Ok"` sozinho não conta, `"Tudo certo"`, `"PASS"` e `"ok: 3"` sim), um número com unidade ou formato (`5 minutos`, `4 linhas`, `80%`; um dígito solto
  não conta) ou uma decisão "Se X, faça Y" cuja condição diga algo ("se necessário", "se houver dúvida", "caso algo dê errado" e
  "if needed" não dizem, nem as que falam da própria tarefa ou texto: "caso a tarefa seja grande", "se o texto for longo"). Os números e as decisões só ajudam ao lado de uma âncora forte: "reserve 5 minutos, revise 2 vezes" e
  "planeje, execute, revise" não passam. Sem narrar um dia: datas, ids de sessão, número de PR ou ticket, "ontem", "nesta sessão"
  (a palavra solta "hoje", uma cor `#333` ou "desta vez" não contam: "agenda de hoje" é uma classe de tarefa), nem o relato em
  primeira pessoa no passado ("eu rodei", "a usuária me pediu", "hoje de manhã", "às 14h30"; formas só do passado contam mesmo sem o "eu": "primeiro rodei", "rodamos"; "a usuária pediu" depois de "o que", "que", "se" ou "quando" é regra no presente e não conta): um desses sinais pode ser exemplo
  de uma regra, **dois** são um relato. Sem segredos **literais** (o que o `MemorySanitizer` mudaria; uma referência como
  `$TOKEN`, `$(security find-generic-password …)` ou `<chave>` diz onde a credencial mora e passa). Nunca sobre uma skill do app
  ou do catálogo; e sem repetir uma skill que já existe: nome e descrição parecidos, **corpo** com vocabulário parecido
  (similaridade 0,4 ou mais) ou **os mesmos comandos** (50% ou mais dos trechos de código da proposta, comparados pelas duas
  primeiras palavras, como `npm publish`, aparecem numa skill existente; comandos de todo dia como `git status` não contam; **um só** comando em comum já basta se o corpo tiver similaridade de 0,25 ou mais). A
  recusa manda melhorar a existente com o mesmo nome (`Improve it… name: <existente>`).
- **Carregar.** O app grava `_skills.json` (slug, nome, resumo, instruções, se pode ser melhorada) a cada mensagem, só quando muda,
  pelo actor da memória. `recall "/nome"` devolve as instruções dessa skill. A seção "Skills" do prompt continua com uma linha por skill e diz para ler a que serve com `recall "/nome"`
  antes de começar; sem skills o prompt não muda.
- **Revisão em segundo plano** (`SkillReview`, `AppModel+SkillReview`). Cada **passo** do modelo que pede ferramentas,
  em conversa (não em rotina), sobe `BotSession.stepsSinceSkill` (como o `_iters_since_skill` do Hermes: dez leituras
  paralelas numa resposta são um passo); uma proposta zera. Quando um turno bem-sucedido termina com 10 ou mais, e não parou no
  limite de passos, o app pergunta ao Orb, em segundo plano, se o trabalho ensinou algo que valha uma skill. É a mesma requisição
  do turno (mesmo system, mesmas ferramentas, o histórico que o turno mandou, já resumido ou condensado, mais o que o turno
  acrescentou, e o prompt de revisão no fim), então o prefixo é o da última chamada do turno e o cache do provedor segue quente,
  também em conversa compactada. Só `recall` e `remember` com `tipo` `skill` funcionam (`TurnRequest.onlyTools`; as outras
  respondem "Not available in this review." sem rodar; `remember` de outro tipo, que pediria um cartão que ninguém veria, é
  recusado na hora com "This review only proposes skills"; `ToolContext.skillReview` repete a recusa dentro da ferramenta). Até 6
  chamadas ao modelo. Nada aparece no chat nem no histórico, mas o que ela gasta é registrado na página Uso com a origem `auxiliary` (cada
  `requestUsage`, no modelo do turno). É cancelada quando você escreve (ou uma rotina começa) ou quando o Orb
  é redefinido, nunca roda junto com um turno, nem num Orb "Só leitura". O aviso de proposta não cai na conversa de uma rotina: espera o fim do próximo turno. O prompt pede skill no nível da classe de tarefa, "lições, não
  registros", melhorar antes de criar, incorporar o procedimento da memória sobre o mesmo assunto e responder "Nothing to save."
  quando não há técnica não trivial, correção sua ou skill errada. Em Ajustes → Geral dá para desligar.
- **Aprovar.** Depois do turno ou da revisão, o chat ganha **um** aviso por proposta nova ("Skill proposta: /x — Nome" ou "Melhoria
  proposta para /x") com o botão **Revisar**, que abre o editor de skills com o texto inteiro e editável. **Salvar skill** cria a
  skill (origem `aprendida`, `learnedBy` e escopo só o Orb que propôs; você amplia em "Usar com") ou troca as instruções da que
  existe, mantendo id, usos e escopo. **Descartar** apaga a proposta; fechar o editor a deixa esperando. Quem apaga o procedimento
  que a skill absorveu é você.
- **Segredos.** `MemorySanitizer.scrub` tira o valor literal de chaves, tokens, `usuário:senha@` em URL, `curl -u` e `CHAVE=valor`. Só
  é referência (e passa) `$(…)`, `${…}`, uma variável inteira (`$NOME` em maiúsculas ou `$nome` em minúsculas, seguida de fim,
  aspas, crase, espaço, `;`, `)`, `/`, vírgula, ponto, `&`, `]` ou `}`; numa URL, `$NOME` em maiúsculas seguido de `@`) e um `<…>` fechado. Um valor que só *começa*
  com `$` ou `<` (`$enh@F0rte!`, `$3cr3t`, `$Lit3ral`, `<abc123def`) é segredo e sai.
- Adotar uma memória guardada num Orb novo não leva `_propostas/` nem `_skills.json`.

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
| `UserProfile.swift` | o perfil da usuária e o seu `promptSection` (entra por `brief(profile:)`) |
| `Memory/MemoryBank.swift` | a memória de um Orb (actor): identidade, `remember`, `recall`, `related`, `brief`, sessões, envelhecimento, `forget`, `startFromKept`; `MemoryLibrary` (uma por Orb, apagar/guardar/adotar, `seal` na redefinição) |
| `Import/` | `OrbImport` (o que foi lido, `plan()`, limites, `ImportGuard`, `ImportSanitizer`), `OrbImportReader` (arquivos, pastas, `detectLocal`) e `OrbImportFormats` (cartão, JSON, texto livre), `ImportPrompt` (o prompt para copiar) |
| `Memory/KeptMemories.swift` | `_guardadas`: `KeptProfile` (`perfil.json`), `KeptMemory` (o que o menu "Começar de" e Ajustes listam), guardar, listar, contar, adotar |
| `Memory/SessionSummary.swift` | trecho de conversa → página de sessão, por regras (mais a nota do modelo, se houver); `idleGap` |
| `Memory/MemoryIntent.swift` | reconhece "memorize…" e o que guardar |
| `Memory/MemoryConsolidation.swift`, `Memory/MemoryMerge.swift`, `AppModel+MemoryConsolidation.swift` | a memória fixada encurtada; a unificação proposta de fatos e procedimentos parecidos (grupos, validação, `_unificacao.json`, aplicar); os gatilhos no fim do turno e o botão "Unificar" |
| `Memory/SkillProposal.swift`, `Memory/MemoryBank+Skills.swift` | a proposta de skill e a validação; `_propostas/`, `_skills.json`, `skillText` |
| `Engine/SkillReview.swift`, `AppModel+SkillReview.swift` | o prompt e o gatilho da revisão, avisos, editor |
| `Engine/Tools/MacTools.swift` | ferramentas `remember` e `recall` |
| `BotSession+Conversation.swift` | `pendingStretch`, `saveMemory` (com as notas da dobra), `keepRequestedMemory`, `scheduleMemorySave`, `announce` |
| `AppModel.swift` (MARK: Memory) | criar, migrar (`prepareMemory`), esquecer, identidade, entrevista |
| `AppModel+MemoryUI.swift` | `ForgottenMemory`, `MemoryUndo` |
| `Views/MemoryViews.swift`, `Views/InspectorSupport.swift` | aba Memória, tela de memória, grupos e busca |
| `Tests/OrbAppTests/MemoryTests.swift`, `RelatedMemoryTests.swift`, `PanelUITests.swift`, `SkillProposalTests.swift`, `SkillFlowTests.swift`, `MemoryConsolidationTests.swift`, `MemoryMergeTests.swift` | testes |

Versões anteriores guardavam uma lista simples em `state.json` (`Bot.memory`); na abertura (`prepareMemory`) ela vira páginas
em `fatos/` e só sai do `state.json` quando todas foram gravadas.
