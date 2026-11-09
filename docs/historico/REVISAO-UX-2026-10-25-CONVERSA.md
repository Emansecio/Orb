# Revisão de UI/UX: área de conversa (25/10/2026)

Leitura do código sobre `674bad6`, conferida com 56 capturas `--snapshot` em 1100 e 760 pt:
- conversa: `showcase`, `chat-working`, `chat-working-streaming`, `chat-plan-done`, `chat-attachments`, `chat-slash`;
- transcript: `transcript-tools`, `-tools-open`, `-work`, `-work-open`, `-approvals`, `-question`, `-quote`, `-outputs`, `-notices`, `-compacted`, `-failed`, `-skill-proposal`, `-browser-live`, `-retry`, `-screen-steps`, `-long-command`, `-attachments`, `-interrupted`;
- grupos e outros: `group-chat`, `delegation-exchange`, `approvals`, `quickask-reply`.

Pedido: a conversa deve ficar **menos pesada para ler**. O foco é tirar caixas, rótulos e espaços que não carregam informação, e pôr o que sobra numa borda e numa escala só. Nada aqui acrescenta recurso.

Notação:
- **Impacto e esforço:** A/M/B e P/M/G.
- **[conferido]:** visto no código e na captura.
- **[decisão]:** muda a cara do app; precisa do seu ok antes.

Os caminhos são relativos a `Sources/Orb/Views/`: `TV` = `TranscriptViews.swift`, `CV` = `ChatView.swift`, `MD` = `MarkdownBlockViews.swift`, `SP` = `SelectableProse.swift`.

## 0. O que pesa hoje, em números

- **Caixa dentro de caixa.** Toda resposta é um balão preenchido (`agentBubble`, raio 16), e tabela e código dentro dela são outra caixa com borda (`raised` + `line`). Numa resposta com código e tabela, o leitor atravessa três contornos para chegar ao texto (`transcript-notices`).
- **Quatro bordas à esquerda.** O texto da resposta começa em 58 pt (44 + 14 de padding), avisos e eventos em 44, ferramentas abertas em 66 e a linha "trabalhando" em 40 (`TV:105-131`, `CV:966`).
- **Dez tamanhos de texto** no transcript: 10, 11, 12, 12,5, 13, 14, 14,5, 15, 15,5 e 17. Só cinco vêm de token. Há três chevrons para a mesma função (8, 9 e 10 pt) e dois "11" (regular e medium) lado a lado.
- **Ritmo único de 12 pt** entre tudo. Por isso uma lista de ferramentas aberta mede cerca de 27 pt por linha (texto de 12 pt + 12 de vão) e se espalha pela tela (`transcript-work-open`), enquanto usuário→Orb também ganha só 12 pt.
- **Compositor mais largo que o texto.** O card tem 760 pt e o conteúdo do transcript, 704. A ordem de `frame` e `padding` é invertida (`ComposerView.swift:74-75` contra `CV:332-335`), e o card passa 28 pt de cada lado.

## 1. Etapa 1: ler mais leve (o maior efeito)

| # | O quê | Onde | Imp. | Esf. |
|---|---|---|---|---|
| 1 | **Resposta do Orb sem balão.** O texto fica direto no fundo, com o avatar ao lado. Só a mensagem do usuário continua em balão, como no Claude e no ChatGPT. Tira a caixa de fora das tabelas e do código, e o texto passa a começar em 44 pt, na mesma borda das ferramentas e dos avisos. [decisão] [conferido] | `TV:117-131` (`replyBubble`, `ReplyBubble`) | A | M |
| 2 | **Sem o rótulo "Você"** sobre cada mensagem sua. O balão à direita já diz de quem é, e o VoiceOver continua lendo "Você". No grupo, os Orbs têm nome e você fica à direita, sem rótulo. [conferido] | `TV:190-194` | A | P |
| 3 | **Ferramentas abertas mais juntas.** As linhas de dentro de um grupo passam de 12 para 4 pt de vão, perto de 20 pt por linha. O vão de 12 fica entre blocos diferentes (resposta, ferramenta, aviso). [conferido] | `TV:975, 1169, 1203` | A | P |
| 4 | **Mais ar entre turnos que dentro deles.** Hoje é 12 pt para tudo. Proposta: 24 pt antes de cada mensagem sua e 12 pt dentro da resposta do Orb, para o olho achar onde cada troca começa. [conferido] | `CV:275`, `CV:422` | M | P |
| 5 | **Mensagem sua com a mesma entrelinha da resposta.** Com duas linhas ela fica apertada (sem `lineSpacing`), enquanto a resposta tem 5 pt (`group-chat`). [conferido] | `TV:202-203` | M | P |
| 6 | **Dica "↩ envia · ⇧↩ nova linha" só quando ensina algo.** A versão parada (enviar e nova linha) é a convenção de todo chat e ocupa 20 pt sob o compositor o tempo todo. Fica a dica com fila ("⇥ depois da tarefa"), edição, ditado e pedido aberto, que são do Orb. [conferido] | `ComposerView.swift:259-273` | M | P |

## 2. Etapa 2: uma borda, uma escala

| # | O quê | Onde | Imp. | Esf. |
|---|---|---|---|---|
| 7 | **Compositor na largura do texto** (704 pt), com o `FirstRunBanner` junto. [conferido] | `ComposerView.swift:74-75`; `FirstRunCard.swift:774-775` | M | P |
| 8 | **Uma borda à esquerda:** a linha "trabalhando" sobe de 40 para 44, e as ferramentas abertas recuam a partir do mesmo `gutter`. Com o item 1, resposta, aviso, evento, cartão e ferramenta começam todos em 44. [conferido] | `CV:966-972`; `TV:110-112` | M | P |
| 9 | **Uma largura de cartão.** Aprovação, pergunta e proposta têm 516 pt, a tela ao vivo 560 e a troca entre Orbs 560 com recuo à direita. Proposta: todos com 560 a partir do `gutter`. [conferido] | `TV:1591-1592`; `LiveScreenViews.swift:72-73`; `Multi/OrbMessageRow.swift` | M | P |
| 10 | **Escala de texto com seis tamanhos:** 11, 12, 13, 14, 15,5 e 17. Para isso: o 12,5 do nome de arquivo vira 12; 14,5 e 15 viram 15,5; o "11 medium" ganha token (`Typography.smallMedium`); e os chevrons ficam todos com 9 pt. [conferido] | `TV:191, 551, 599, 628, 850, 1023, 1188, 1881`; `AV:142`; `MD:64` | M | M |
| 11 | **Um padding e uma borda por tipo de cartão:** 14 pt nos cartões que pedem ação (aprovação, pergunta, proposta) e 12 nos de leitura (saída de ferramenta, troca, oferta). A oferta de skill deixa `Color.primary.opacity(0.05)` e usa `Palette.ghostHover`. [conferido] | `TV:910, 1335-1361, 1653`; `QuestionCard.swift:97`; `Multi/OrbProposalCard.swift:162`; `CV:141` | B | P |
| 12 | **Raio da bolha como token** (16 pt, usado em três lugares) e o raio 20 do compositor também. [conferido] | `TV:129, 207`; `QueuedMessages.swift:90`; `ComposerView.swift:911` | B | P |
| 13 | **Placeholder do compositor em `Palette.faint`**, como o `Theme` documenta. Hoje vem da cor do sistema. [conferido] | `ComposerView.swift:157` | B | P |

## 3. Etapa 3: agrupar o que se repete

| # | O quê | Onde | Imp. | Esf. |
|---|---|---|---|---|
| 14 | **"Dizer o que fazer em vez disso" sem azul nem ícone.** Cada cartão de permissão tem esse link azul com ícone de balão, e três cartões abertos mostram três links azuis acima dos botões. Ele vira texto discreto ao lado de "Não permitir", que é o lugar da recusa, com o `QuietTextStyle` do painel levado para o `Theme`. [conferido] | `TV:1632-1640`; `BotInspector.swift:1464` | M | P |
| 15 | **Mensagens na fila sem barra de botões por bolha.** Hoje cada bolha tem uma linha de estado ("Entra no próximo passo", "Depois da tarefa") e dois ou três botões de ícone. Proposta: o estado fica na primeira bolha da fila, e editar, mandar agora e tirar aparecem no hover e no foco, como as ações da resposta. [conferido] | `QueuedMessages.swift:111-170` | M | M |
| 16 | **Avisos longos em uma linha.** O aviso de cache tem duas linhas de 12 pt em muted no meio do trabalho (`transcript-work-open`). Ele fica com a primeira frase e "Detalhes", como a falha já faz. [conferido] | `TV:1299-1316` | M | P |
| 17 | **Código e tabela sem borda.** Com o item 1, eles ficam só com o fundo `raised` (a borda `line` some), porque o fundo já separa do texto. [decisão] | `MD:159-260, 274-330` | B | P |

## 4. O que fica como está

- **Avatar em cada resposta.** Com o balão fora (item 1), ele é o que marca quem fala, e no grupo diz qual Orb.
- **Narração em 13 pt `secondary`.** Ela já se distingue da resposta final, e com o item 1 essa diferença fica mais clara.
- **Corpo em 14 pt com entrelinha 5.** Está na faixa de leitura longa (13 a 16 pt), e a coluna de 704 pt dá cerca de 85 caracteres por linha.
- **Tabela em 13 pt e código em 12 pt monoespaçado.** É o padrão, e o tamanho menor ajuda a caber.

## 5. Ordem sugerida

1. **Etapa 1, sem o item 1:** "Você", ferramentas juntas, ar entre turnos, entrelinha e dica. São mudanças pequenas e se veem logo.
2. **Item 1 (balão) e item 17:** é a maior mudança de cara. Primeiro uma captura de antes e depois para você decidir.
3. **Etapa 2:** alinhamento e escala, que dependem do item 1 para fechar a borda em 44.
4. **Etapa 3.**

## 6. Andamento

Revisados linha a linha antes de implementar:
- **Entraram:** 1 a 9, 11 a 15 e 17.
- **10, reduzido ao que muda na tela:** H2 em 15 e H3 em diante em 14, nome de arquivo em 12, legenda dos passos em 11 e chevrons do chat em 9. Literais que já têm o valor de um token ficam como estão.
- **16, recusado:** a segunda frase dos avisos costuma ser a instrução ("feche e reabra…"), e o aviso de cache passaria de uma linha mesmo cortado.
- **17:** o quadro das instruções em Skills passou de `raised` para `canvas`, para o código de dentro continuar visível sem a borda.
- **4:** são 12 pt a mais antes de cada mensagem sua, menos na primeira. A mensagem que sai da fila não ganha esse vão enquanto está na fila.
- **Defeito anterior, achado na conferência:** sem o balão, a tabela passou a caber sem rolagem em 760 pt, e "Documentos" quebrava em "Documento / s". A coluna era medida pela palavra com mais letras ("Instaladores"), não pela mais larga. Agora mede a largura; antes o mesmo erro aparecia como "Document…" dentro da rolagem.
- **Revisão com `/simplify`:** o balão do usuário e o cartão do chat viraram modificadores (`userBubble(fill:)` e `chatCard()`), `TurnGap` perdeu uma função, e o chevron de 10 pt que tinha ficado no grupo foi para 9. Fica para depois: um token de chevron, um contêiner para a coluna de 704 pt e um `ReplyRow` que derive a posição do avatar da fonte.

## 7. Não verificado

- A conversa em andamento com texto chegando (streaming) só foi vista parada (`chat-working-streaming`).
- QuickAsk e a janela estreita abaixo de 760 pt não foram revisados item por item.
- VoiceOver não foi testado.
