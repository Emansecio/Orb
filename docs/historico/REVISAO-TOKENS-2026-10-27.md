# Revisão do consumo de tokens — 27/10/2026

Há espaço para otimizar preservando o modelo principal, a memória e as verificações finais. A primeira prioridade é descobrir por que o caminho ChatGPT reaproveita tão pouco cache. Em seguida, reduzir ciclos de recuperação do navegador e trabalho auxiliar que relê contexto amplo. Não há evidência suficiente para prometer um percentual de economia sem perda de qualidade.

Esta foi uma revisão: o motor, os modelos escolhidos, o contexto e os agendamentos não foram alterados.

A [investigação posterior do navegador e das rotinas](/Users/thiagomacbookpro/Orb/docs/INVESTIGACAO-NAVEGADOR-ROTINAS-2026-10-27.md) reproduziu as duas classes de erro de seletor, identificou parâmetros `query` ignorados e conferiu as pré-checagens com dados sintéticos. Também confirmou que o prompt de atendimento pede meia hora explicitamente; o nome “horária” está desatualizado.

## Escopo e evidências

- Código do checkout, incluindo as alterações locais existentes; HEAD e hashes dos arquivos em [source-state.json](/Users/thiagomacbookpro/Orb/docs/evidencias/tokens-2026-10-27/source-state.json).
- Consumo registrado entre 11 e 27/10/2026, até a coleta às **03:26 de 27/10**, em America/Sao_Paulo: **8.214 chamadas**.
- **25 conversas com mensagens**, incluindo quatro chats principais e conversas de rotinas e pedidos entre Orbs; **9.305 mensagens** persistidas.
- **1.851 registros** do pipe Claude Code, de `2026-10-19T07:19:45Z` a `2026-10-26T07:50:15Z`. Esse recorte não cobre todo o histórico mensal nem o uso recente via ChatGPT.
- Dados agregados, configurações relevantes e hashes dos insumos: [metrics-final.json](/Users/thiagomacbookpro/Orb/docs/evidencias/tokens-2026-10-27/metrics-final.json). Não foram copiados corpos de conversas ou credenciais para esse artefato.

O app continuou funcionando durante a leitura. Cada arquivo foi lido integralmente uma vez por execução e identificado por SHA-256; a coleta não é uma transação entre arquivos.

## O que os números mostram

| Categoria | Tokens |
| --- | ---: |
| Entrada sem cache (`input`) | 32.848.300 |
| Leitura de cache | 436.641.814 |
| Escrita de cache | 66.170.426 |
| Prompt total | 535.660.540 |
| Saída | 4.138.766 |

A leitura de cache representa **81,5%** do prompt agregado. Esse número esconde uma diferença grande entre provedores. Saída representa apenas **0,77%** de todos os tokens registrados; encurtar respostas finais tem um teto de benefício muito menor que melhorar a entrada ou evitar chamadas desnecessárias.

`cacheWrite1h` já está incluído em `cacheWrite`; somá-lo novamente duplicaria o consumo. Tokens de cache continuam sendo tokens: maior acerto não significa menor prompt, nem comprova como uma assinatura calcula suas cotas. Esta revisão não converteu esses números em dinheiro ou limites da conta.

| Origem | Chamadas | Prompt total | Entrada sem leitura de cache¹ |
| --- | ---: | ---: | ---: |
| Chat | 4.214 | 367.561.008 | 74.131.537 |
| Rotinas | 3.325 | 128.678.014 | 14.386.025 |
| Auxiliares | 428 | 29.475.831 | 9.119.331 |
| Delegação | 154 | 5.544.919 | 555.456 |
| Grupos | 93 | 4.400.768 | 826.377 |

¹ `input + cacheWrite`, sem aplicar preços diferentes. Rotinas representam **40,5% das chamadas**; auxiliares respondem por **9,2%** dessa entrada sem leitura de cache. Nenhum dos dois blocos deve ser considerado desperdício por inteiro.

## 1. Prioridade alta: diagnosticar o cache do ChatGPT

**Verificado:** `chatgpt/gpt-6.1-sol` registrou **358 chamadas**, prompt médio de **47.094 tokens** e **10,54%** de acerto ponderado de cache. No dia 26 foram **10,94%**; no trecho de 27/10 presente nesta coleta, **5,48%**, em 28 chamadas. O valor de 1,5% observado no início da inspeção pertencia a uma coleta anterior e parcial desse mesmo dia.

Os modelos `gpt-5.6-luna` e `gpt-6-luna` ficaram em **26,54%** e **25,21%**, respectivamente. São cargas diferentes; isso não demonstra que trocar de modelo corrigiria o cache.

O cliente já envia chave por conversa e histórico stateless com `store: false`: [ResponsesClient.swift:23](/Users/thiagomacbookpro/Orb/Sources/Orb/Engine/ResponsesClient.swift:23), [ResponsesClient.swift:119](/Users/thiagomacbookpro/Orb/Sources/Orb/Engine/ResponsesClient.swift:119). A normalização subtrai corretamente os tokens lidos do cache da entrada integral: [ResponsesClient.swift:269](/Users/thiagomacbookpro/Orb/Sources/Orb/Engine/ResponsesClient.swift:269). Não encontrei duplicação nessa fórmula.

**Hipóteses ainda abertas:** alteração do prefixo após transformação do histórico; mudança do sistema ou das ferramentas entre turnos; roteamento ou comportamento do backend. Há transformações reais: saídas e argumentos deixam de ser frescos no próximo turno; imagens antigas saem; condensações e dobras alteram o começo. O código controla essas alterações, mas os logs disponíveis não registram qual delas precedeu cada falha de cache do ChatGPT.

**Direção:** estender a métrica numérica existente para todos os clientes, com identificador de requisição, modelo, origem, duração, tamanho por componente e hashes das seções estáveis. Registrar também dobra/condensação, primeiro índice alterado e contagens do provedor. Sem corpos de mensagens. Comparar duas chamadas consecutivas que apenas acrescentam uma mensagem com chamadas que compactaram. Isso distingue problema do Orb de comportamento do backend.

**Teste de falsificação:** se chamadas sem mudanças no prefixo continuarem sem cache, a hipótese de instabilidade local não explica esses casos. Não implementar `previous_response_id`, retirar raciocínio ou mudar a persistência remotamente como suposta correção sem validar o contrato desse endpoint.

## 2. Prioridade alta: reduzir recuperação e observações redundantes no navegador

**Verificado**, no histórico principal de campanhas:

| Ferramenta | Chamadas | Falhas | Caracteres de saída persistidos |
| --- | ---: | ---: | ---: |
| `browse_snapshot` | 397 | 54 | 465.085 |
| `browse_read` | 79 | 0 | 206.828 |
| `browse_run` | 144 | 3 | 132.388 |
| `browse_screenshot` | 358 | 7 | 72.634 |

Entre as falhas estão, literalmente, `Error: Selector 'button' did not match any element` e `Error: Selector 'main' did not match any element`. Cliques também falharam por referências antigas e elementos cobertos. Isso demonstra fricção operacional, mas não prova que todas as falhas poderiam ser evitadas.

Uma chamada ao modelo frequentemente carrega dezenas de milhares de tokens. Evitar um ciclo dispensável de observar → errar → observar pode economizar mais que encurtar sua saída em algumas linhas. Capturas também carregam imagens; os 72.634 caracteres acima não representam seu custo visual.

O `LoopWatch` já detecta falhas e repetições. Por segurança contra falsos positivos, ferramentas `browse_*` bem-sucedidas ficam fora da detecção de resultado repetido: [LoopWatch.swift:46](/Users/thiagomacbookpro/Orb/Sources/Orb/Engine/LoopWatch.swift:46). Essa exceção tem razão de existir: a página pode mudar mesmo com argumentos idênticos.

**Direção:** recuperação determinística e limitada para referências inválidas e seletores opcionais; indicar ao modelo quando já dispõe de snapshot suficiente; observações menores por região quando a região é conhecida; combinar leituras independentes numa resposta do modelo. Preservar captura para conferir layout, gráficos ou controles não descritos pelo snapshot. Preservar confirmação após ações relevantes.

**Teste de falsificação:** comparar tarefas históricas equivalentes; se a nova recuperação aumentar cliques incorretos, tentativas, campos perdidos ou reduzir verificação, não adotar. Não deduplicar resultados somente por nome/argumentos: a mesma leitura pode ter conteúdo novo.

## 3. Prioridade média: atualizar a seleção e o orçamento dos auxiliares

**Verificado:** a seleção de modelo auxiliar reconhece somente `haiku`, `mini`, `flash`, `lite`, `nano`: [ChunkSummary.swift:176](/Users/thiagomacbookpro/Orb/Sources/Orb/Engine/ChunkSummary.swift:176). **Nenhum dos oito modelos atualmente listados na conta ChatGPT corresponde a essas palavras**, inclusive `gpt-6-luna` e `gpt-5.6-luna`.

Nesse catálogo, a seleção retorna `nil`: a nota de trecho usa o próprio modelo do Orb e o porteiro da revisão de skills não roda. A revisão completa pode rodar após dez etapas com ferramentas: [AppModel+SkillReview.swift:68](/Users/thiagomacbookpro/Orb/Sources/Orb/AppModel+SkillReview.swift:68), [SkillReview.swift:11](/Users/thiagomacbookpro/Orb/Sources/Orb/Engine/SkillReview.swift:11).

O consumo auxiliar no `gpt-6.1-sol` foi **27 chamadas, 1.247.605 tokens de prompt e 19.005 de saída**. A origem `auxiliary` agrupa notas, porteiros e revisões: não permite atribuir essas 27 chamadas a um subtipo específico.

**Direção:** seleção explícita por capacidade e custo conhecido do catálogo, com fallback conservador, em vez de depender apenas de apelidos. Separar métricas por subtipo e registrar se uma nota foi aproveitada ou se uma revisão produziu proposta útil. Nas tarefas auxiliares, testar esforço de raciocínio e contexto menores sem alterar o raciocínio do chat principal. O código atual não separa tokens de raciocínio dos demais tokens de saída em `TokenUsage`.

Trocar o modelo auxiliar pode reduzir custo ou latência, mas não garante reduzir tokens. Também não basta acrescentar `luna` à lista: a qualidade dos resumos e a taxa de falsos negativos do porteiro precisam ser comparadas.

**Teste de falsificação:** medir preservação de pedidos, decisões, nomes, números, pendências e caminhos nos resumos; rejeitar mudanças que omitam esses elementos ou façam o porteiro perder correções importantes do usuário.

## 4. Prioridade média: fazer as rotinas trabalharem sobre diferenças

**Verificado:** há três rotinas habilitadas. Uma delas tem nome de execução horária, mas usa `0,30 8-23 * * *`: são **32 horários por dia**, enquanto o app estiver disponível, e não 16. A configuração ficou preservada. Reduzir a frequência aumentaria o tempo de atendimento e não é uma economia neutra em qualidade.

O executor entra no turno do modelo em cada execução com prompt: [AppModel.swift:2074](/Users/thiagomacbookpro/Orb/Sources/Orb/AppModel.swift:2074). As conversas de rotina já têm ciclo próprio; não partem simplesmente do chat principal inteiro.

**Direção:** manter a cadência, mas testar uma leitura determinística de estado quando existir uma fonte confiável: cursor de última mensagem, identificador de evento, hash ou indicador de saúde. Só dispensar análise quando houver prova de que nenhum trabalho novo exige decisão. Pendências, falhas de leitura e verificações periódicas completas devem continuar levando ao modelo. Para atendimento, uma mensagem nova sempre reabre a análise.

**Teste de falsificação:** nenhuma mensagem, incidente ou alteração relevante pode ficar sem tratamento em comparação ao comportamento atual. Os registros não sustentam estimar quantas execuções seriam evitáveis: a rotina de atendimento também realizou trabalho real.

## 5. Preservar o que já funciona

- Contexto em lotes, marca d'água baixa e duas últimas rodadas protegidas; estado atual em `balanced` (teto de 80 mil tokens de histórico).
- Sistema congelado por seções; atualizações e horário no prefácio; memória relacionada sem repetição recente.
- Conectores descobertos sob demanda, sem enviar todos os schemas a cada chamada.
- Saídas paginadas, spill com caminho de recuperação e remoção de imagens antigas.
- Notas de trechos reutilizadas na compactação e na memória.
- Claude Code com processo reutilizado e prefixo estável. Nos logs disponíveis, `resume` teve **97,47%** de cache e `idle`, **98,78%**. `fresh` teve **17,12%**; 226 processos novos responderam por **77,33% das escritas de cache** desse recorte. Isso justifica preservar a reutilização, mas não considerar todo processo novo evitável: rotinas, compactações e divergências legítimas exigem reconstrução.

Não recomendo cortar globalmente o contexto de 80 mil para 40 mil, apagar raciocínio reutilizável, reduzir as últimas rodadas preservadas ou mudar para um modelo menor em toda tarefa. São mudanças com risco direto de perda de continuidade e mais releituras. Também não recomendo variar a lista de ferramentas por mensagem: alterar um prefixo grande pode destruir o benefício do cache.

## Limites da prova e validação

- Os tokens são os que os provedores reportaram e o Orb registrou. Não houve novas chamadas de modelo ou experimento pago.
- O uso mensal é agregado por hora, Orb, modelo e origem, sem distribuição por requisição fora do pipe Claude. Não prova causalidade entre uma falha específica e consumo específico.
- **437 saídas persistidas já estavam encurtadas** por `ConversationCoding`; o histórico de disco não reconstrói todos os pedidos originais. As dimensões das sessões são caracteres armazenados, não tokens efetivamente enviados.
- O histórico já tem **63 compactações registradas** no conjunto analisado, 50 nos quatro chats principais. Não se deve confundir tamanho do JSON em disco com contexto atual enviado.
- O tamanho do raciocínio criptografado em caracteres não equivale aos tokens de raciocínio cobrados. Não o tratar como base64 que possa ser simplesmente removido.
- Não houve medição comparativa de qualidade nesta revisão. Percentuais futuros devem vir de tarefas representativas, preservando resultados, continuidade, verificações e número de tentativas; cache deve ser medido separadamente de redução do prompt.

O script executou com sucesso e conferiu que os totais por modelo e origem fecham com o consolidado. A sintaxe Python, cinco agrupamentos de oito contadores, números do relatório e links locais foram conferidos; [validation.json](/Users/thiagomacbookpro/Orb/docs/evidencias/tokens-2026-10-27/validation.json) registra os resultados. `git diff --check` passou. A suíte Swift completa e as filtradas não rodaram, pois o motor não foi alterado. Não houve build ou troca do bundle do Dock.

## Reprodução

```sh
python3 scripts/audit-token-usage.py --output /tmp/orb-token-audit.json
```

[Script](/Users/thiagomacbookpro/Orb/scripts/audit-token-usage.py). Ele lê os arquivos próprios do Orb e emite apenas metadados e contagens; não chama provedores, não executa ferramentas dos Orbs e não muda seus dados.

Comando, saída bruta, timestamp e código de saída da coleta final: [audit-command-03.json](/Users/thiagomacbookpro/Orb/docs/evidencias/tokens-2026-10-27/audit-command-03.json). A primeira execução falhou com `KeyError: '_0'` por pressupor um formato incorreto do item visual de resposta; esse cálculo opcional foi removido. A falha foi preservada em [audit-command.json](/Users/thiagomacbookpro/Orb/docs/evidencias/tokens-2026-10-27/audit-command.json), e a execução intermediária bem-sucedida em [audit-command-02.json](/Users/thiagomacbookpro/Orb/docs/evidencias/tokens-2026-10-27/audit-command-02.json). Leituras exploratórias também encontraram ausência de `~/Library/Logs/Orb` e caminhos de arquivos presumidos; a inspeção prosseguiu pelos arquivos efetivamente existentes. As ferramentas de ai-memory não estavam expostas nesta sessão; a revisão usou as sessões persistidas do próprio Orb.

Ordem recomendada: **medição por requisição → correções de recuperação do navegador e seleção auxiliar → comparação de qualidade → contexto e rotinas guiados por estado**. O primeiro ganho deve vir de manter a informação necessária e evitar seu reprocessamento desnecessário.
