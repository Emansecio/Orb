# Investigação do navegador e das rotinas — 27/10/2026

Há uma correção pequena e bem sustentada para o navegador: recuperar uma falha de escopo com uma única leitura sem seletor, dentro da própria ferramenta. Nas rotinas, a oportunidade depende do tipo de tarefa: o atendimento já tem uma consulta resumida aproveitável; o analisador do site ainda tem divergências que impedem usá-lo para dispensar revisão; a análise diária de campanhas deve continuar completa.

Foram analisados código, instruções atuais das três rotinas habilitadas e históricos retidos. Reproduzi os erros no **agent-browser 0.39.1**, com Chrome for Testing **155.0.8059.39**, perfil e sockets temporários e uma página HTML local. Testei os auxiliares das rotinas exclusivamente com entradas sintéticas. Foram produzidos documentos e reprodutores, sem alterar motor, agendamentos, políticas ou scripts operacionais.

## Navegador: causa e recuperação

[Contagens, índices das mensagens, seletores e erros literais](/Users/thiagomacbookpro/Orb/docs/evidencias/navegador-rotinas-2026-10-27/investigation.json).

| Dado do histórico de campanhas | Resultado |
| --- | ---: |
| Chamadas de `browse_snapshot` | 397 |
| Com `selector` | 261 |
| Falha por seletor sem elemento DOM | 34 |
| Falha por seletor sem nó de acessibilidade | 20 |
| Falhas em chamadas sem seletor | 0 |
| Chamadas com `query` ignorado | 74 |

As 54 falhas correspondem a **20,7% das chamadas com seletor**. Nessa amostra, a causa não foi timeout ou navegador fechado. Os dois formatos de erro foram:

```text
Error: Selector 'main' did not match any element
Error: No accessibility node found for selector '[role=dialog]'
```

O Orb repassa o CSS diretamente ao driver e devolve a falha ao modelo: [BrowseTools.swift:234](/Users/thiagomacbookpro/Orb/Sources/Orb/Engine/Tools/BrowseTools.swift:234), [AgentBrowserDriver.swift:420](/Users/thiagomacbookpro/Orb/Sources/Orb/Engine/Browser/AgentBrowserDriver.swift:420). O modelo então decide como recuperar a observação, usando outra chamada de modelo com todo o contexto correspondente.

No histórico, depois dessas falhas:

- **32** respostas seguintes do modelo pediram outro snapshot;
- **27** obtiveram sucesso nessa nova leitura;
- **19** obtiveram sucesso com um snapshot sem seletor;
- em **14** desses casos, a única ferramenta solicitada na resposta seguinte foi esse snapshot sem seletor.

Os 14 casos são a evidência mais limpa de uma recuperação que poderia ocorrer dentro da ferramenta. Não são uma medição de economia total: não há uso por requisição ligado a esses eventos, e algumas tentativas ocorreram em períodos ou versões anteriores do app.

### O teste local confirmou a diferença entre CSS e acessibilidade

Uma página com controles `<div role="button">` mostrou botões normalmente no snapshot completo. O seletor CSS `button` não encontrou esses controles. Um elemento existente no DOM com `aria-hidden="true"` produziu literalmente:

```text
No accessibility node found for selector '#hidden'
```

O seletor `[ref=e3]` falhou: a referência do snapshot não é um atributo DOM. Isso também aparece nas tentativas históricas com `button[ref]` e `[ref=e265]`.

Outro detalhe: `[role=button]`, com dois botões na página, devolveu **apenas o primeiro botão**. O seletor define a raiz do recorte; ele não funciona como uma busca que junta todos os controles correspondentes. Os schemas e exemplos devem deixar essa diferença clara, especialmente para listas CSS separadas por vírgula.

O teste de um wrapper `display:contents` não reproduziu a ausência de nó acessível: o driver conseguiu mostrar seus descendentes. Portanto não se deve atribuir todas as 20 falhas históricas a wrappers estruturais ou elementos ocultos. A classe do erro está confirmada; o DOM original de cada falha histórica não está disponível.

[Comandos, timestamps, saídas e códigos de saída do teste real](/Users/thiagomacbookpro/Orb/docs/evidencias/navegador-rotinas-2026-10-27/browser-raw.json).

### Mudança recomendada

No `BrowseSnapshotTool`, quando uma primeira leitura com seletor retornar exatamente uma dessas duas classes de erro:

1. Fazer **uma** nova leitura sem seletor, mantendo o modo interativo/completo e os limites de saída solicitados.
2. Executar tentativa e recuperação na mesma exclusão mútua e na mesma aba da conversa.
3. Atualizar árvore, referências e paginação com a leitura efetivamente obtida.
4. Devolver o snapshot com uma nota curta e explícita de que o seletor falhou e o escopo foi ampliado.
5. Se a leitura ampla também falhar, devolver ambos os diagnósticos; cancelamento, falta de página, diálogo e outros erros continuam sendo tratados pelos caminhos existentes.

Isso automatiza somente observação. Não remapeia uma referência antiga para clicar em algo parecido e não repete uma ação que possa ter sido aplicada.

Os **74 `query`** são outra falha de contrato: o schema de `browse_snapshot` oferece `offset`, `max_chars`, `full` e `selector`, e a implementação não lê `query`. A paginação compartilhada também não faz essa busca: [WebTools.swift:257](/Users/thiagomacbookpro/Orb/Sources/Orb/Engine/Tools/WebTools.swift:257). O modelo acredita estar restringindo o resultado por texto, mas recebe outro recorte. Recomendo uma busca textual declarada e implementada, preservando referências e contexto dos controles, com indicação de continuação. Não interpretar `query` como regex implicitamente: os históricos incluem intenções ambíguas com `|`.

### Deltas existem, mas não basta ligar uma flag

O binário fixado já oferece `snapshot --delta`. A página estável retornou `kind: "unchanged"`; uma mudança pequena na fixture retornou uma nova árvore completa. Isso confirma a capacidade, sem demonstrar uma taxa geral de economia.

Com `--delta`, `data.snapshot` é um **objeto** com revisão, árvore ou indicação de ausência de mudança. Hoje o driver espera uma **string** em `data.snapshot` e referências em `data.refs`. Ligar a flag faria a árvore chegar vazia ao código atual. Uma integração futura precisa reconstruir a árvore, manter a base por aba/conversa e reenviar uma base completa quando ela deixar o contexto após compactação. A recuperação dos seletores é a primeira mudança menor e mais segura.

## Rotinas: onde existe trabalho evitável

O número de **40,5%** se refere às chamadas de modelo do histórico mensal, não ao percentual de tokens economizáveis. No mesmo recorte, rotinas representavam cerca de **24% do prompt total** e **14,5% da entrada sem leitura de cache**. O histórico por hora não contém identificador da rotina: não dá para atribuir esses tokens precisamente a cada uma das três rotinas atuais.

Em 26/10, foram 195 chamadas de rotinas de um total de 479. Em 27/10, até esta coleta, não havia uso com origem `routine`. Não se trata de um gasto constante ou automaticamente dispensável.

### A acumulação de conversa já foi resolvida no código

`startingRoutineRun` esvazia mensagens, resumo, plano, compactações e identificador de sessão antes da execução seguinte: [ConversationHistory.swift:22](/Users/thiagomacbookpro/Orb/Sources/Orb/ConversationHistory.swift:22). Os itens antigos ficam apenas na apresentação. O modelo recebe o último relatório em até 1.200 caracteres e um bloco limitado do chat recente, não dez execuções completas.

Não há evidência de que cortar mais esse histórico seja o próximo ganho seguro.

### Atendimento: triagem menor, preservando meia hora

O prompt vigente pede expressamente **a cada 30 minutos**. A palavra “horária” do nome está desatualizada; a frequência configurada é intencional. Há também uma instrução explícita para **não atender às 23:30**. O último histórico desse horário registrou um turno com uma leitura de arquivo antes de encerrar. Essa condição pode ser resolvida por uma pré-condição estruturada de horário antes de chamar o modelo, preservando os demais horários, inclusive 23:00.

Nas dez execuções retidas, incluindo interrompidas e a das 23:30, contei **329 ferramentas**, das quais **143 leituras de arquivo**. Ler a skill e as regras vigentes é uma exigência do prompt; não considero essas leituras dispensáveis por padrão.

Existe um caminho concreto de triagem no auxiliar atual:

```text
puxar.py --peek --summary --json
```

Ele consulta a fila local sem buscar contexto individual de cada chat nem avançar o marcador. Inspecionei a implementação e testei `main` com todas as consultas substituídas por respostas sintéticas; esse comando **não foi executado contra a conta real**.

Os testes confirmaram dois limites importantes:

- **Fila vazia e `success: true` podem vir com `sync_recent_observed: false`.** O próprio resultado informa `continuous_reception_confirmed: false`. “Sucesso da consulta” não comprova recebimento atualizado das mensagens.
- Um pedido antigo ainda pendente continua na fila com `new: false`. Filtrar apenas `new`, usar somente timestamp ou só o indicador de não lida pode perder trabalho em aberto.

**Pré-checagem recomendada:** manter a frequência, consultar saúde e fila resumida, verificar pendências do painel e prazos de retorno, e invalidar a comparação quando skill ou política comercial mudarem. Registrar identificador de trabalho processado separadamente do marcador de leitura. Resultado incompleto, sincronização incerta, mídia pendente, prazo vencido ou estado desconhecido deve levar à análise normal. Só dispensar o modelo quando houver evidência suficiente de ausência de trabalho acionável, mantendo uma reconciliação completa periódica.

Isso exige configuração explícita da pré-checagem e um estado estruturado de pendências. Não cabe um gate genérico “zero mensagens novas → não fazer nada”.

### Site: pré-checagem determinística é viável, mas o analisador precisa de correção

As verificações de HTTP, containers, túnel e limites de logs são boas candidatas a um coletor determinístico que devolva um resumo curto e encaminhe anomalias ao modelo. As dez execuções retidas registraram 51 ferramentas. Isso não demonstra que todas poderiam ser dispensadas.

O script existente [analisa.py](</Users/thiagomacbookpro/Orbs/LP AcessosFit/Rotinas/analisa.py>) **não equivale integralmente às regras do prompt atual**. Entradas sintéticas demonstraram:

| Caso | Regra vigente | Resultado observado do analisador |
| --- | --- | --- |
| Um `curl` na home | Não satisfaz o critério de UA: exige mais de cinco requisições fora de home/checkout/assets | Emite candidato |
| Três POSTs de criação separados por horas | Não satisfaz três POSTs em dez minutos | Emite candidato |
| UA `Googlebot` em IP sintético fora das faixas permitidas, sondando `/.env` | Satisfaz o critério de crawler alegado com sondagem | Não emite candidato |

O código usa `any` para UA de ferramenta, conta POSTs sobre todo o arquivo e não implementa o critério específico do crawler alegado. Esses testes demonstram divergência do auxiliar; **não demonstram bloqueio indevido efetivamente aplicado nem incidente perdido em uma execução real**, porque o modelo pode ter conferido os critérios depois.

Antes de usar “nenhum candidato” para pular o modelo, corrigir e testar todas as regras, janelas temporais, exceções, cobertura de logs e rotação. Manter reparos, bloqueios, backup, validação e rollback no fluxo autorizado existente. O pré-flight inicial deve coletar e classificar, não ampliar automaticamente o que a rotina pode modificar.

### Campanhas: manter a análise diária

A tarefa pede métricas de **hoje**, comparação com ontem e cruzamento com leads e vendas. Mesmo sem edição da campanha, essas métricas evoluem. “A configuração não mudou” não permite dispensar essa análise. Nas dez execuções retidas houve 170 ferramentas, com interrupções e falhas; o ganho mais seguro é melhorar observação e extração de dados e reutilizar procedimentos corretos de navegação.

## Validação, limites e sequência recomendada

- O navegador foi exercitado em uma fixture local com perfil próprio. O encerramento da sessão isolada foi confirmado em `browser-raw.json`; os perfis e sockets temporários foram removidos ao fim do script.
- Os **sete casos sintéticos das rotinas** confirmam os comportamentos descritos, incluindo divergências existentes; não significam que esses auxiliares foram corrigidos. [Resultados brutos](/Users/thiagomacbookpro/Orb/docs/evidencias/navegador-rotinas-2026-10-27/routines-raw.json).
- A tentativa inicial de abrir a fixture falhou por caminho de socket longo: `Socket path would be 108 bytes (max 103)`. Foi preservada em [browser-attempt-01.json](/Users/thiagomacbookpro/Orb/docs/evidencias/navegador-rotinas-2026-10-27/browser-attempt-01.json); a execução seguinte usou `/tmp` e uma sessão curta. A primeira fixture bem-sucedida está em [browser-attempt-02.json](/Users/thiagomacbookpro/Orb/docs/evidencias/navegador-rotinas-2026-10-27/browser-attempt-02.json).
- Uma leitura exploratória das contagens diárias falhou com `NameError: name 'datetime' is not defined`; a coleta corrigida está no reprodutor e em `investigation.json`.
- Não houve nova chamada a modelo, build ou atualização do Dock. A suíte Swift não rodou; os testes realizados foram os reprodutores locais e sintéticos.
- Contagens, resultados dos reprodutores, links locais e `git diff --check` foram conferidos: [validation.json](/Users/thiagomacbookpro/Orb/docs/evidencias/navegador-rotinas-2026-10-27/validation.json).

Ordem de implementação proposta: **recuperação de snapshot e contrato de busca textual → pré-condição explícita das 23:30 → pré-checagem estruturada do atendimento → correção e validação do coletor do site**. Deltas ficam para uma etapa separada, com controle de base e compactação.

Não há percentual de economia global comprovado. Já há evidência de chamadas de recuperação potencialmente evitáveis e condições exatas para não trocar economia por omissão de trabalho.

Reprodução:

```sh
python3 docs/evidencias/navegador-rotinas-2026-10-27/investigate.py
python3 docs/evidencias/navegador-rotinas-2026-10-27/repro_browser.py
python3 docs/evidencias/navegador-rotinas-2026-10-27/repro_routines.py
```
