# Navegador do Orb: velocidade e tela ao vivo — análise e proposta (2026-11-09)

Pedido: descobrir por que o uso do navegador integrado parece lento, se vale trocar de navegador, e como fazer a tela ao
vivo parecer contínua (sensação de 60 quadros por segundo, com cursor, clique e carregamento visíveis). Nada foi alterado
no código durante a análise; este arquivo foi a única coisa criada.

Depois: as três etapas da seção 5 foram implementadas em 2026-11-10 (`fefce13`, `0f9c319`, `088ea9b`). Ficaram de fora o
texto digitado letra a letra, as várias ações em uma chamada e a atualização do agent-browser.

## Resumo

1. **O navegador não é o gargalo.** Um clique leva 0,08 s (mediana em 895 cliques reais). O tempo vai para o modelo: entre
   uma ação e a próxima passam 3,1 s (mediana), e isso soma 75 % do tempo de uma sequência de navegação.
2. **Trocar de navegador não resolve** e piora a tela ao vivo: as alternativas mais rápidas não desenham pixels ou perdem
   compatibilidade com sites. A recomendação é manter o Chrome com o agent-browser.
3. **A tela ao vivo está limitada pelo próprio Orb a 10 quadros por segundo.** A mesma fonte entrega 60 sem custo a mais
   no Chrome (medido). Só isso não acaba com o efeito de slides: o Orb age aos saltos, uma vez a cada ~3 s. O que falta é
   movimento entre os saltos (cursor que viaja, rolagem suave, sinal de espera).
4. **Proposta em três etapas**, cada uma usável sozinha: (1) 60 quadros; (2) movimento natural quando alguém está olhando;
   (3) menos idas ao modelo por tarefa, que é o que de fato acelera a navegação.

## 1. Como funciona hoje

- `AgentBrowserDriver` roda um processo `agent-browser` (0.39.1, instalado pelo Orb) por comando; um processo de fundo
  por Orb mantém o Chrome aberto e fala CDP com ele. Chrome for Testing 155, em segundo plano (headless).
- Um `browse_click` dispara até quatro processos: `session list` (se o último comando foi há mais de 3 s), `get box`
  (para o cursor da tela ao vivo, só com alguém olhando), `click` e `get url`.
- O modelo trabalha por árvore de acessibilidade (`browse_snapshot`), não por captura de tela.
- Tela ao vivo: o processo de fundo expõe um WebSocket local com quadros JPEG (960 px, qualidade 60). O Orb conecta com
  `?maxFps=10` (`LiveStreamRunner.maxFps`), decodifica fora da thread principal e desenha numa camada. O cursor do Orb é
  uma camada por cima, que desliza 0,25 s até o elemento; o clique é enviado no mesmo instante, sem esperar o cursor chegar.

## 2. Medições

### 2.1 Histórico real (todas as conversas salvas: 9.624 ações de navegador)

| Ação | Quantas | Mediana | p90 | Soma |
|---|---:|---:|---:|---:|
| Esperar (`browse_wait`) | 350 | 6,07 s | 12,06 s | 2.650 s |
| Abrir página | 650 | 2,18 s | 5,25 s | 1.830 s |
| Olhar a página (snapshot) | 2.794 | 0,07 s | 0,13 s | — |
| Ver as abas | 1.301 | 0,06 s | — | — |
| Clicar | 895 | 0,08 s | 0,32 s | 413 s |
| Ler o texto | 922 | 0,25 s | 0,52 s | 343 s |
| Preencher | 129 | 0,07 s | 0,18 s | 15 s |
| **Todas as ações** | 9.624 | 0,08 s | 1,68 s | **8.414 s (25 %)** |
| **Entre uma ação e a próxima** | 6.456 | 3,12 s | 7,33 s | **24.911 s (75 %)** |

"Entre uma ação e a próxima" é o intervalo do fim de uma ferramenta ao começo da seguinte: resposta do modelo, mais o
envio e, em alguns casos, uma aprovação. Intervalos acima de 120 s ficaram de fora.

O que o modelo faz com essas idas e vindas:

- 43 % das chamadas só olham: 2.794 snapshots e 1.301 listagens de abas.
- 816 sequências começam listando as abas, antes de qualquer outra coisa.
- Depois de um clique, 53 % das vezes a chamada seguinte é um snapshot; depois de abrir, 36 % snapshot e 25 % espera;
  depois de rolar, 47 % snapshot.
- As esperas quase sempre terminam bem (343 de 350); a mediana de 6 s é o site demorando, não erro.

### 2.2 Comando a comando (sessão isolada, página local leve, M1 Pro)

| Comando | Mediana |
|---|---:|
| Iniciar o processo (`--version`) | 6 ms |
| Abrir (navegador frio) | 2.112 ms |
| `session list` / `get url` / `get box` | 6 / 7 / 8 ms |
| `snapshot` interativo (124 elementos) | 19 ms |
| `click` | 22 ms |
| `fill` | 12 ms |
| Clique completo como o Orb faz (4 processos) | 44 ms |
| Os mesmos passos em um `batch` | 17 ms |

Conclusão: o custo de "um processo por comando" existe, mas é de dezenas de milissegundos num passo de 3 s.

### 2.3 Tela ao vivo (página com animação contínua, 960 px, qualidade 60)

| Limite pedido | Quadros/s recebidos | Intervalo (mediana) | Chrome | Processo de fundo |
|---|---:|---:|---:|---:|
| sem ninguém conectado | — | — | 21 % | 0 % |
| `maxFps=10` (hoje) | 10,0 | 102 ms | 34 % | 2 % |
| `maxFps=30` | 28,5 | 35 ms | 41 % | 2 % |
| `maxFps=60` | 55,0 | 18 ms | 35 % | 2 % |
| sem limite | 60,3 | 17 ms | — | — |

Percentuais de um núcleo. O Chrome gasta o mesmo em 10, 30 ou 60: ele gera todos os quadros e o processo de fundo
descarta os que passam do limite. Página parada: 0 % e 2 quadros em 6 s, em qualquer limite. Quadro: ~53 KB.
No lado do Orb, cada quadro custa 1,07 ms (JSON 0,19 + base64 0,03 + JPEG 0,86), fora da thread principal: a 60 quadros,
cerca de 6 % de um núcleo enquanto a página se mexe.

## 3. Por que parece slides

1. **Dez quadros por segundo** em tudo que se mexe de verdade (carregamento, rolagem, animação da página).
2. **O Orb age aos saltos.** Um clique é um evento instantâneo, a rolagem pula de uma vez, o texto de um campo entra
   inteiro. Cada ação muda a página em um ou dois quadros, e depois vêm ~3 s parados enquanto o modelo decide. Nenhuma
   taxa de quadros conserta isso: falta movimento entre as ações.
3. **O cursor chega depois do clique.** A página reage antes de o cursor terminar de deslizar, então o efeito não lê
   como "ele foi lá e clicou".

## 4. Navegadores e ferramentas alternativas

Pesquisa na web feita por um agente; nem tudo foi confirmado em fonte, e está marcado.

| Opção | Desenha pixels? | Avaliação |
|---|---|---|
| agent-browser (atual) | Sim | Processo de fundo persistente em Rust sobre CDP, stream pronto, 60 quadros medidos. Mantém. |
| Lightpanda (Zig) | **Não** (sem motor gráfico) | ~9× mais rápido em raspagem segundo o próprio projeto, mas sem imagem não há tela ao vivo; compatibilidade com sites reais menor. Descartado. |
| WKWebView embutido | Sim, 60 quadros nativos | Sem CDP, eventos de script marcados como não confiáveis, mais bloqueio por anti-robô, uploads e popups por conta própria. Perde os logins e perfis de hoje. Descartado. |
| Playwright MCP / CLI | Sim | Acrescenta um processo Node entre o Orb e o CDP; browser-use e Stagehand saíram do Playwright por esse motivo. Não ganha nada aqui. |
| browser-use, Stagehand | Sim | São motores de agente (Python e TypeScript), não só navegador: trariam o harness deles, contra a decisão PROD-3. |
| CDP direto no Orb, sem agent-browser | Sim | Economiza ~40 ms por ação e exige reescrever o driver (650 linhas) e o stream. Não compensa. |
| Capturar uma janela real (ScreenCaptureKit) | Sim | Janela minimizada pausa a captura e uma janela visível tira o foco; o stream atual já dá 60 quadros em segundo plano. Desnecessário. |

Não pesquisados a fundo: Steel, Skyvern, nanobrowser, Servo, Ladybird, Camoufox. Nenhum muda a conclusão, porque o tempo
não está no navegador.

## 5. Proposta

### Etapa 1 — 60 quadros na tela ao vivo (pequena)

- Pedir `maxFps=60` em vez de 10 (ou 60 na janela ampliada e 30 no cartão, se a medição no app pedir).
- Custo esperado: nada a mais no Chrome; ~6 % de um núcleo no Orb só enquanto a página se mexe; zero com a página parada.
- Pronto quando: CPU do app e a rolagem do chat (PanelsBench) medidos antes e depois, sem queda na rolagem.

### Etapa 2 — Movimento natural, só com alguém olhando (média)

O Orb já sabe quando a tela ao vivo está visível (é quando pede a caixa do elemento). Só nesse caso:

- O cursor viaja até o alvo em curva suave e o clique sai quando ele chega (~0,2 s de atraso por clique), com estado
  pressionado e o anel.
- Rolagem em passos suaves em vez de um salto.
- Entre as ações, o cursor fica no lugar com um sinal discreto de "pensando", e o cartão mostra o carregamento da página.
- Texto digitado aparecendo aos poucos (opcional; é o item que mais custa tempo).
- Sem ninguém olhando, nada muda e nada custa. Toggle em Ajustes, ligado por padrão, respeitando "reduzir movimento".
- Vale atualizar o agent-browser para 0.41: traz `mouse move` com duração e curva (o movimento passa a acontecer também
  dentro da página, com os efeitos de passar o mouse) e entrega de quadros com confirmação (`pacing=ack`).

### Etapa 3 — Menos idas ao modelo (é a que acelera de verdade)

- **A ação devolve o estado novo.** Clique, preencher com Enter, rolar e abrir já retornam endereço, título, aba nova
  que tenha aberto e, se a página mudou, o snapshot compacto (com o limite do `browse_snapshot`, 12.000 caracteres). Corta o snapshot
  que vem depois de 53 % dos cliques e 36 % das aberturas.
- **Abas no cabeçalho do snapshot** (uma linha, quando há mais de uma). Corta boa parte das 1.301 listagens avulsas.
- **Várias ações em uma chamada** para formulários: preencher cinco campos e clicar em uma ida só.
- **Abrir já espera o que importa**: `browse_open` aceita um texto ou elemento a esperar, cortando a espera avulsa que
  vem depois de 25 % das aberturas.
- Ganho estimado, pelo histórico: até ~2.000 idas ao modelo a menos em 6.456, perto de 30 % do tempo de modelo. É teto:
  o modelo pode continuar pedindo snapshots por conta própria. Custo: resultados de ação maiores (mediana de um
  snapshot: 1.646 caracteres).

### O que não proponho

- Trocar de navegador ou de ferramenta (seção 4).
- Juntar os processos de um clique em um `batch`: 44 ms viram 17 ms, invisível.
- Mudar o modelo dos Orbs. O tempo por passo é do modelo da conversa; trocar por um mais rápido é escolha sua, por Orb.

## 6. O que não foi medido

- CPU e fluidez do app de verdade com o cartão a 60 quadros (a medição do app foi por script, fora dele).
- Páginas pesadas reais na bancada (a página de teste é leve); o histórico cobre sites reais, mas só o tempo total.
- Quanto do intervalo de 3,1 s é modelo e quanto é envio ou aprovação.
- Navegador com janela visível; agent-browser 0.41 dentro do Orb; efeito do movimento do mouse nas checagens anti-robô.
- A pesquisa de alternativas foi parcial (seção 4).
