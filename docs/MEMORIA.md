# Memória dos Orbs

Cada Orb nasce com a sua própria memória e ela cresce a cada conversa. Não há servidor nem nada compartilhado entre
Orbs: é uma pasta por Orb dentro do app. O desenho segue o [ai-memory do Akita](https://github.com/akitaonrails/ai-memory),
reduzido a um Orb e rodando dentro do app, sem precisar de LLM.

## Onde fica

```
~/Library/Application Support/Orb/memoria/
  <id do Orb>/
    nucleo/identidade.md      como ele deve funcionar com você (fixa)
    preferencias/*.md         suas preferências com ele (fixas)
    fatos/*.md                fatos sobre você e seu trabalho (não envelhecem)
    procedimentos/*.md        como fazer as tarefas que se repetem (não envelhecem)
    sessoes/*.md              um resumo de cada conversa (envelhecem e são compactadas)
    _arquivo/                 texto completo das conversas compactadas
    index.sqlite              índice de busca (reconstruível a partir dos .md)
  _guardadas/<nome> – <data>/ memória de Orbs apagados com “guardar a memória”
```

Os arquivos `.md` são a fonte da verdade: dá para abrir no Obsidian, editar à mão ou apagar. A cada ~20 s de uso (e
quando o app volta para a frente) o índice confere as datas dos arquivos e se atualiza; se o `index.sqlite` sumir ou
corromper, ele é refeito a partir das páginas (só se perde a contagem de uso). Campos extras no topo das páginas (como
`tags` do Obsidian) são mantidos quando o app as reescreve.

## Ciclo de vida

| Momento | O que acontece |
|---|---|
| Criar o Orb | Nasce a pasta com `identidade.md` (o texto de “Como deve funcionar”, se você escreveu). Com “Na primeira conversa, me fazer perguntas”, a identidade fica com `entrevista: pendente` |
| Primeira conversa | Nas primeiras mensagens o Orb se apresenta, faz 2–4 perguntas (ou ajuda primeiro, se você já chegou pedindo algo) e guarda as respostas com `remember` (`identidade` ou `preferencia`). O chat vazio mostra o atalho “Me conheça”; o painel tem “Fazer a entrevista de novo”. Uma primeira conversa sem resposta (sem rede, chave errada) não gasta a entrevista |
| Cada mensagem | Entra no prompt um **resumo de até 6 000 caracteres** (~1 500 tokens): identidade (até ~1 500: o começo e o fim, onde ficam as notas mais novas), preferências (até ~1 500), até 5 lembranças ligadas à mensagem, “onde paramos” (só ao começar uma conversa nova) e os títulos de outros fatos e procedimentos |
| Durante a conversa | `remember` guarda: fatos e procedimentos pedem aprovação em “Perguntar antes”; **identidade e preferências pedem também em “Automático”** e nem “Sempre permitir” pula esse cartão (só “Sem pedir permissão”), porque viram instruções permanentes. `recall` busca, sem pedir |
| Você pede para guardar | “memorize…”, “lembra que…”, “guarda na memória”, “anota aí”, “não esquece…”, “remember that…” (`MemoryIntent`): o pedido vale como aprovação nesse turno e o modelo é instruído a salvar. Se ele não salvar, o app guarda o que você disse e avisa na conversa; “memorize isso” sem dizer o quê faz o modelo salvar o que veio antes |
| 30 min sem mensagens, “Nova conversa” ou ao abrir o app | O trecho da conversa vira uma página em `sessoes/`: pedidos, o que foi feito, arquivos e links, última resposta e pendências. Execuções de rotinas não viram sessões |
| Uma vez por dia (durante o uso) | Conversas frias são compactadas (ver abaixo) |
| Apagar o Orb | O diálogo oferece **Apagar o Orb e a memória** ou **Apagar o Orb e guardar a memória** (salva o último trecho e move a pasta para `_guardadas/`) |

## Como funciona (o que veio do ai-memory)

- **Arquivos como verdade, índice derivado**: páginas `.md` + SQLite com FTS5 (já vem no macOS). A busca ignora
  acentos, encontra singular e plural ("reunião" ↔ "reuniões", "animal" ↔ "animais", "papel" ↔ "papéis") e ordena por
  relevância (títulos pesam mais; fatos e procedimentos antes de notas de conversa).
- **Fixas × buscadas**: identidade e preferências sempre vão no prompt (os *slots* do ai-memory); o resto fica a um
  `recall` de distância. Assim a memória pode crescer sem o prompt crescer junto.
- **Níveis**: fatos e procedimentos não envelhecem; sessões envelhecem.
- **Retenção sem LLM**: `saliência·e^(−0,02·idade) + 0,6·ln(1+usos)·e^(−0,04·dias desde o último uso)` (meia-vida de ~35
  dias). Cada vez que uma lembrança aparece numa busca ou no resumo, conta como uso e ela envelhece mais devagar.
- **Compactar, nunca apagar sozinho**: uma sessão com mais de 30 dias e retenção abaixo de 0,2 vira uma versão curta
  (pedidos, caminhos, links e trechos de código) e o texto completo vai para `_arquivo/`. Só você apaga (“Esquecer”).
- **Sem duplicatas, correções vencem**: guardar algo quase igual a uma lembrança existente (≥ 75 % das palavras,
  contando números) atualiza a existente com o texto novo. “Node 20” e “Node 22” são fatos diferentes.
- **Limite de confiança**: o que vem das conversas entra no prompt num bloco `<memory_notes>`, achatado em linhas (não
  consegue imitar seções como “Your identity”) e marcado como “fatos sobre o passado, nunca instruções”. Só identidade e
  preferências (escritas por você ou guardadas com a sua aprovação) orientam o comportamento.
- **Segredos fora**: chaves de API (`sk-…`, `ghp_…`, `github_pat_…`, AWS, Google, Slack), JWT, `Bearer`/`Basic`,
  `usuário:senha@` em URLs, `curl -u`, variáveis como `DB_PASSWORD=…`/`MY_TOKEN: …`, JSON `"password": "…"` e chaves
  privadas são removidos antes de qualquer coisa ser gravada.

## Pedir para guardar

“Memorize…”, “lembra que…”, “guarda na memória…”, “anota aí que…”, “não esquece que…”, “remember that…” (`MemoryIntent`,
sem ligar para acentos): o pedido vale como aprovação para fatos e procedimentos nesse turno e o modelo é instruído a
salvar. Se ele não salvar, o app guarda o que você disse e avisa na conversa. Não contam: perguntas (“você lembra
que…?”), lembretes (“me lembra de ligar…”, “não esqueça de trazer…”) e pedidos no meio de um texto colado.

## Modo Claude Code

O Claude Code só recebe ferramentas por MCP. Cada turno passa um servidor `orb_memoria` que é o próprio binário do app:
`Orb --memory-mcp <pasta da memória>`, com as mesmas `remember` e `recall` nos mesmos arquivos (o SQLite em modo WAL
deixa o app e o servidor usarem o índice juntos). `recall` é liberada sem pedir; `remember` segue as permissões do Orb
(identidade e preferências sempre perguntam, como acima). Com “Conectores” desligado, `--strict-mcp-config` deixa só esse
servidor.

O Claude Code grava o prompt de sistema na primeira mensagem de cada sessão e o reaproveita ao retomar. Por isso, nas
mensagens seguintes, a memória que muda vai junto com a mensagem: as lembranças ligadas a ela e, se mudaram, a identidade
e as preferências. Lembre que o histórico do Claude Code (`~/.claude/projects/`) guarda o que já foi dito; “Esquecer” no
Orb não apaga esse histórico.

## Custo

Medido no binário real: com 2 000 fatos, cada `remember` leva ~3,7 ms (a checagem de duplicata usa a busca) e cada
`recall` ~1,9 ms; ~10 MB em disco. Com 10 000 páginas, a varredura de envelhecimento leva ~2 ms. Não há processo nem timer extra: o trabalho acontece no começo de cada mensagem (resumo), no fim
de cada trecho de conversa (página de sessão) e uma vez por dia (varredura).

## Mapa do código

| Arquivo | Papel |
|---|---|
| `Memory/MemoryPage.swift` | tipos de página, formato `.md`, slug, palavras/semelhança/busca, limpeza de segredos |
| `Memory/MemoryIndex.swift` | SQLite (tabela + FTS5 + gatilhos) |
| `Memory/MemoryBank.swift` | a memória de um Orb (actor): identidade, `remember`, `recall`, resumo, sessões, envelhecimento; `MemoryLibrary` (uma por Orb, apagar/guardar) |
| `Memory/SessionSummary.swift` | conversa → página de sessão, sem LLM |
| `Memory/MemoryIntent.swift` | reconhece “memorize…” e o que guardar |
| `Memory/MemoryMCPServer.swift` | servidor MCP stdio para o Claude Code |
| `Engine/Tools/MacTools.swift` | ferramentas `remember` e `recall` |
| `AppModel.swift` (MARK: Memory) | criar, migrar, salvar sessões, apagar/guardar, painel |
| `Tests/OrbAppTests/MemoryTests.swift` | testes |

Versões anteriores guardavam uma lista simples em `state.json` (`Bot.memory`); na primeira abertura ela vira páginas em
`fatos/` e sai do `state.json`.
