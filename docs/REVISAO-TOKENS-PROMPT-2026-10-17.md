# Revisão de tokens, frente A: o custo fixo de cada turno (2026-10-17)

Escopo: prompt de sistema em cada contexto, descrições e parâmetros das ferramentas, estabilidade para o cache de prompt e memória e skills injetadas. Fora do escopo (frente B, de outro agente): contagem de tokens e custo, compactação, histórico e clientes de provedor. O que apareceu nessas áreas está só anotado.

Método: um teste temporário montou o prompt real (`SystemPrompt.make`, `OrbsPrompt`, `GroupPrompt`, `BrowserPrompt`, `RoutinePrompt`) e as ferramentas reais (`ToolBox.offered`) com um Orb típico (Atlas, todas as capacidades, modo Perguntar, quatro colegas, um grupo). Não ficou no commit; o que ficou são tetos (`ToolSpecEconomyTests`, `SystemPromptTests`). Tokens estimados em caracteres / 4 (ordem de grandeza, não faturamento).

## Resumo

- O custo fixo já estava perto do piso: as revisões anteriores (docs/REVISAO-NAVEGADOR, REVISAO-USO-DO-COMPUTADOR, `ToolSpecEconomyTests`) enxugaram o que dava para enxugar sem perder capacidade. O prompt de sistema de um Orb com tudo ligado tem ~1.350 tokens; as ferramentas oferecidas, ~7.300. **As ferramentas pesam cinco vezes o prompt.**
- Cache: não achei nada que quebre o prefixo sem necessidade dentro de um turno. Data, hora, estado da pasta, memória relacionada e plano vão no preface da mensagem, nunca no sistema (`TurnPrompt.swift:222-238`). Dois pontos de quebra ficam como proposta (P2): skills e modo de permissão.
- Corrigido (seguro, com testes): a ferramenta `schedule` passa a ir em forma curta nas execuções que ninguém acompanha (rotina, pedido de outro Orb, turno de grupo), onde o app só aceita listar e pausar; mais duas frases duplicadas do prompt. Ganho: ~290 tokens por requisição em cada rotina, pedido e turno de grupo; ~45 tokens em todo chat de Orb com Mac; ~35 tokens com colegas.

## Medições

### Prompt de sistema por parte (Orb típico, `SystemPrompt.make`, sem memória nem skills)

| Parte | Caracteres | Tokens (~) |
|---|---:|---:|
| identidade, pasta, idioma, comportamento | 1.272 | 318 |
| ambiente (`## Environment`) | 122 | 30 |
| permissões, modo Perguntar / Automático / Sem pedir / Só leitura | 945 / 970 / 781 / 894 | 236 / 242 / 195 / 223 |
| conteúdo não confiável | 341 | 85 |
| hábitos de trabalho | 454 | 113 |
| dicas de ferramentas (`nativeToolHints`, tudo ligado) | 1.193 | 298 |
| `## Mac apps` (só com Controlar apps) | 1.120 → 1.075 | 280 → 269 |
| skills (6, com resumo de 160 caracteres) | 1.096 | 274 |
| **total, tudo ligado** | **5.458 → 5.413** | **1.364 → 1.353** |
| total, sem capacidades | 3.581 | 895 |

### Seções que se juntam ao prompt, por contexto

| Contexto | Seções somadas ao prompt base | Caracteres antes → depois |
|---|---|---:|
| chat próprio | base; `## Your browser` (761) se o navegador está instalado; `## Teammates` (4 colegas) 861 → 728; `## Your groups` (1 grupo) 567 | base 5.413 (+ até 2.100) |
| rotina | base + `[Automatic run]` no turno (759, vai na mensagem, não no sistema) | 5.413 |
| pedido de outro Orb | base + Teammates; o envelope (`OrbEnvelopeText`) vai na mensagem | 5.413 + 728 |
| turno de grupo | base + Teammates (membros) + `## Group` (orquestrador 536, membro 402); preface `<group>` com membros, fio (até 8.000) e quadro, na mensagem | 5.413 + 728 + ~500 |
| assistente de criação | prompt próprio (`WizardPrompt`, ~2.300) + só `orb_draft` | ~2.300 |
| revisão de skills | o mesmo prompt e as mesmas ferramentas do turno (cache quente, de propósito: `AppModel+SkillReview.swift:33-53`); só a mensagem muda, e só `recall`/`remember` rodam | sem custo novo de prefixo |

### Ferramentas oferecidas por contexto (descrição + schema, em caracteres)

| Contexto | Ferramentas | Antes | Depois | Tokens (~) |
|---|---:|---:|---:|---:|
| chat próprio, tudo ligado, navegador instalado | 56 | 29.132 | 29.132 | 7.283 |
| chat próprio, sem navegador instalado | 36 | 22.122 | 22.122 | 5.531 |
| chat próprio, sem time | 52 | 26.499 | 26.499 | 6.625 |
| **rotina / pedido de outro Orb (execução sem ninguém)** | 52 | 26.448 | **25.290** | 6.322 |
| **turno de grupo** | 54 | 27.216 | **26.058** | 6.515 |
| sem capacidades (memória, agenda, plano, open, notify, ask_user) | 7 | 4.601 | 4.601 | 1.150 |

Por ferramenta (as 12 maiores; `ToolBox.all` sem navegador soma 18.861, teto 18.900; navegador, 20 ferramentas, 7.010, teto 7.200; multi-Orb com `ask_user`, 3.705, teto novo 3.800):

| Ferramenta | Total | Descrição | Schema |
|---|---:|---:|---:|
| `ui_act` | 1.723 | 546 | 1.177 |
| `schedule` (completa) | 1.476 | 541 | 935 |
| `schedule` (execução sem ninguém) | ~330 | ~190 | ~140 |
| `screenshot` | 1.137 | 460 | 677 |
| `run_command` | 1.055 | 677 | 378 |
| `orb_propose` | 993 | 206 | 787 |
| `grep` | 957 | 423 | 534 |
| `ui_read` | 904 | 315 | 589 |
| `web_fetch` | 835 | 405 | 430 |
| `applescript` | 788 | 549 | 239 |
| `read_file` | 737 | 437 | 300 |
| `browse_page` | 635 | 263 | 372 |
| `ask_user` | 628 | 381 | 247 |

## Achados

### P1 (grande, fica como proposta)

1. **As ferramentas são o custo fixo dominante** (7.300 de ~8.650 tokens num chat com tudo ligado). `ToolBox.offered` já filtra por capacidade, acessibilidade, navegador instalado e multi-Orb (`ToolBox.swift:15-33`), e os conectores já são sob demanda (`ConnectorGateway`, dois fixos). O que resta para encolher sem esconder é carregar sob demanda, como o manual do `browse_run`:
   - **Interface de apps** (`ui_read` 904 + `ui_act` 1.723 + `screenshot` 1.137 = 3.764 caracteres, ~940 tokens): manter nome, ação e alvo no schema e levar os detalhes (marcas, espera, `precisa_assumir_tela`, OCR, passos) para um manual devolvido por `ui_read` sem argumentos. Ganho estimado: ~500 tokens por requisição de um Orb com Controlar apps. Risco: modelos pequenos erram mais sem o detalhe à vista; precisa de um teste com os modelos reais antes.
   - **Navegador** (20 ferramentas, 7.010 caracteres, ~1.750 tokens): o `browse_run` já é a porta para o resto. Uma segunda rodada poderia mover `browse_find`, `browse_dialog`, `browse_wait`, `browse_files`, `browse_proxy` (2.031 caracteres) para dentro do manual, ficando como comandos do `browse_run`. Ganho: ~450 tokens com o navegador instalado. A revisão do navegador separou essas ferramentas de propósito (permissões por família: `browse_files` e `browse_proxy` perguntam), então mover exige manter as mesmas recusas; fica para uma etapa própria.
   - Somando as duas: ~950 tokens por requisição, ~13% das ferramentas. Como o prefixo fica em cache, o ganho de dinheiro é menor que o de tokens (leitura em cache custa uma fração); o ganho maior é na primeira mensagem e a cada quebra de cache.

### P2

2. **`schedule` inteira (1.476 caracteres) em execuções onde só listar e pausar funcionam.** `AppModel+Schedule.swift:102-115` (`sideRunRefusal`) recusa criar, alterar, retomar, rodar e apagar numa rotina, num pedido de outro Orb e num turno de grupo; a ferramenta, porém, ia inteira. **Corrigido** (abaixo).
3. **Skills não são congeladas por conversa como a memória.** `AppModel.swift:1536` lê `skills(for:)` a cada turno e `SystemPrompt.skills` (`SystemPrompt.swift:199-208`) entra no sistema. Aprovar uma skill proposta pela revisão (ou ligar ou desligar uma) muda o prompt da conversa em andamento: o prefixo muda, e o histórico inteiro depois dele é reescrito no cache uma vez. A memória resolve isso com `Conversation.memoryInPrompt` e `TurnPreface.memoryUpdate`; skills poderiam fazer o mesmo (congelar a lista por conversa, avisar a mudança no preface). Não corrigi: precisa de campo novo na `Conversation` (persistido) e de mexer no `DeliveryMarks`, mudança maior que "claramente segura". Ganho: uma reescrita de cache (~tudo o que está no histórico) por skill aprovada.
4. **Lista de skills sem teto.** Cada linha é cortada em 160 caracteres, mas o número de linhas não tem limite: 30 skills são ~5.500 caracteres (~1.400 tokens) em todo turno, dobrando o prompt. Proposta: depois de ~25 linhas, uma linha final "outras N: recall \"/\" lista" (a capacidade continua: o `recall "/nome"` já carrega qualquer uma). Não apliquei porque o Orb precisa saber o que sabe fazer; só com a nota e o teste que prove que `recall` as acha.
5. **Modo de permissão no sistema.** Trocar de modo no meio da conversa (Perguntar para Automático) reescreve `## What you may do` (~240 tokens) e, como o sistema vem antes do histórico, o cache do histórico inteiro. É comum na prática ("deixa em automático"). Proposta: manter o texto do modo no sistema só como ponteiro curto e levar o texto completo do modo atual para o preface (como a memória), ou aceitar a quebra. Muda comportamento de segurança (o modelo precisa saber o modo atual): fica como proposta.
6. **Membros do grupo duas vezes por turno.** O sistema tem `## Teammates` com o papel de cada membro (`SystemPrompt.swift:243-260`) e o preface repete "Members: Nome (papel até 80)" em toda mensagem (`GroupPrompt.swift:60-65`), que fica no histórico. O preface é o único lugar com o aviso "waiting for the user's approval" e o único quando o membro não tem `orbs` (sem a seção Teammates), e `GroupRunTests.swift:77` e `GroupSupportTests.swift:164,179` fixam o formato com papel. Proposta: omitir o papel no preface quando o sistema já o lista. Ganho: até ~60 caracteres por membro por mensagem de grupo.
7. **Plano de tarefas repetido em cada mensagem enquanto há passo aberto** (`TurnPrompt.swift:236`, `plan.compact()`): fica no preface de cada mensagem do histórico até a condensação as apagar. Pertence à frente B (condensação); anotado.

### P3

8. **Dicas do prompt que repetem a descrição da ferramenta** (cada uma com teste que a fixa): "(app_dictionary before scripting one you do not know well)" (~60 caracteres; a descrição de `applescript` diz o mesmo, `MacTools.swift:267`), "Long commands can run in the background (job_output)" (~55; `run_command`), ", not to read a page" (~20; `open`), "(offset or find for long ones; no JavaScript)" (~45; `web_fetch`). Somam ~180 caracteres (~45 tokens). **Não cortei:** as revisões anteriores as adicionaram de propósito (TurnContextTests.swift:133-146, SystemPromptTests.swift:99-101 contam que o prompt cresceu "para dizer web_fetch, browser_tab e open uns dos outros"), porque modelos pequenos escolhem a ferramenta pelo prompt, não pela descrição. Cortar é decisão de qualidade, não de economia.
9. **Sobreposição de comportamento** entre `announce`, `persist`, `workHabits` e o texto do modo Perguntar (dizer o plano, conferir o resultado, terminar com o que mudou): ~100 a 150 caracteres. Todas são instruções de comportamento ligadas a falhas observadas (`SystemPrompt.swift:21-25`); ficam.
10. **`orb_propose`**: o parâmetro `look` expande oito propriedades `{"type":"string"}` (~200 caracteres, `OrbProposeTool.swift:24-27`). Resumir em um objeto sem propriedades e listar as chaves na descrição economizaria ~130 caracteres, mas objetos sem `properties` são rejeitados por alguns provedores (Gemini); não vale o risco.
11. **Ordem das seções dentro do sistema** (`AppModel.swift:1645-1649`: base, nota de acessibilidade, navegador, colegas, grupo): trocar a ordem não rende nada, porque o sistema inteiro vem antes do histórico no prefixo: qualquer mudança nele reescreve o histórico, esteja onde estiver. O que importa é não mudar. Hoje só mudam, dentro de uma conversa: skills (achado 3), modo de permissão (5), colegas e papéis editados, modo do navegador e proxy, e a nota de acessibilidade quando a permissão muda. Todos raros ou deliberados.

## Estabilidade do cache (verificado, sem achado novo)

- `SystemPrompt.make` não leva data, hora, fuso, contagem, estado da pasta nem memória relacionada; o teste `staysTheSameAcrossTheTurnsOfAConversation` trava isso. Listas: colegas na ordem de `bots`, grupos na ordem de `groups(containing:)`, skills na ordem do array, capacidades por `Capability.allCases` (nunca iteração de `Set`).
- A memória fixa (`MemoryBrief.stable`: identidade + preferências + rodapé, teto `briefBudget` 6.000 caracteres, identidade 1.500, preferências 1.500) fica congelada na conversa (`Conversation.memoryInPrompt`); o que muda vai no preface uma vez (`memoryUpdate`). As notas completas só na primeira mensagem; depois só o que combina com a mensagem (`relatedShare` 900, 3 itens), sem repetir o que já está nas últimas três mensagens (`relatedWindow`). Sem duplicação nem falta de teto.
- Instruções da pasta (`ORB.md`/`AGENTS.md`/`CLAUDE.md`): teto de 6.000 caracteres (`FolderInstructions.limit`), no sistema, estável.
- Lista de ferramentas: ordem fixa de `ToolBox.all`; os conectores entram por duas ferramentas fixas; as da interface só mudam quando a permissão de Acessibilidade muda.
- Conversas de criação e revisão de skills não usam o prompt do Orb: criação tem prompt próprio e uma ferramenta; revisão reaproveita de propósito o prefixo do turno.

## Corrigido

| Mudança | Onde | Ganho |
|---|---|---|
| `schedule` em forma curta (list e pause, ~330 caracteres) quando a execução é uma rotina, um pedido de outro Orb ou um turno de grupo. A ferramenta é a mesma (mesma execução, mesmas recusas); só a descrição e o schema mudam, e o texto diz o que o Orb pode fazer ali e para onde vai o resto ("proponha na mensagem final"). Novo `MultiOrbOffering.sideRun`, ligado em `multiOrbOffering(for:)`. | `ScheduleTool.swift`, `ToolBox.swift:19-21`, `MultiOrbOffering.swift`, `AppModel+Delegation.swift` | 1.158 caracteres (~290 tokens) por requisição em toda rotina, pedido e turno de grupo |
| `## Teammates`: saiu a frase entre parênteses sobre ask e tell, que a descrição de `orbs` já dá palavra por palavra (a ferramenta é oferecida sempre que a seção aparece). | `SystemPrompt.swift` (`OrbsPrompt.section`) | 133 caracteres (~33 tokens) em todo chat com colegas |
| `## Mac apps`: saiu "No AppleScript support: ui_read then ui_act", que `nativeToolHints` já diz na mesma condição (Controlar apps). | `SystemPrompt.swift` (`macApps`) | 45 caracteres (~11 tokens) em todo chat com Controlar apps |

Nenhuma instrução de segurança, de permissão ou de comportamento foi cortada, e nenhum limite removido em c3d8029 voltou.

## Tetos novos (travam o ganho)

- `ToolSpecEconomyTests.theMultiOrbToolSpecsStayWithinTheirOwnCeiling`: multi-Orb + `ask_user` até 3.800 caracteres (medido 3.705; não tinha teto).
- `ToolSpecEconomyTests.aRunNobodyWatchesGetsTheShortScheduleTool`: a lista oferecida numa execução sem ninguém tem os mesmos nomes na mesma ordem, só `schedule` muda (menos de 400 caracteres contra mais de 1.400), e a lista fica mais de 1.000 caracteres menor.
- `SystemPromptTests.staysShortAndKeepsEveryRuleThatChangesBehaviour`: teto do prompt de 5.600 para 5.550 (o Orb do teste é maior que o da medição; o ganho real foi de 45 caracteres).
- `DelegationHubTests`: o Orb que roda um pedido recebido tem `sideRun`; o chat próprio, não.
- O teto de `ToolBox.all` sem navegador (18.900) e o do navegador (7.200) ficaram: a medição é 18.861 e 7.010, e nenhuma delas mudou.
