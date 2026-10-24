# Revisão de UI/UX: componentes e coexistência (23/10/2026)

Levantamento de leitura sobre `72c9bcf`. Quatro recortes foram lidos em paralelo: casca e Ajustes, chat e compositor,
painel do Orb com multi-Orb e grupos, e o Espaço de trabalho (Rotinas, Conectores, Skills). Os achados de maior peso
foram reconferidos no código pela sessão principal e estão marcados **[conferido]**.

Limites: nada foi compilado nem visto na tela (sem `--snapshot`, que rouba o foco). Larguras, contraste real,
truncamento e VoiceOver ficam como **suspeita** até uma captura. Não repete o que as revisões de 14/10
(`REVISAO-INTERFACE`) e 21/10 (`REVISAO-FLUIDEZ`) já resolveram.

Notação: impacto **A/M/B**, esforço **P/M/G**.

## Andamento (23/10)

O bloco de segurança de decisão está feito (itens 1, 3, 4 e 12, e "Conectar assim mesmo"):

- **⌘↩ no compositor:** com um pedido aberto, ⌘↩ no compositor não faz mais nada. A dica pede "responda ao pedido acima". Parar de propósito continua pelo botão de parar e pelo "Parar e enviar" da bolha, que dizem que recusam.
- **Apagar Orb:** o diálogo agora nomeia os grupos que serão desfeitos. Os botões passam a dizer "Apagar tudo, inclusive a memória" e "Apagar, guardando a memória".
- **Objetivo do grupo:** grava também ao sair do campo e ao fechar o quadro.
- **"Conectar assim mesmo":** sai do vermelho. O `SheetFooter` ganhou `leadingIsDestructive`.

---

## 1. As 12 que eu atacaria primeiro

| # | Proposta | Onde | Imp. | Esf. |
|---|---|---|---|---|
| 1 | Com um pedido de permissão aberto, ⌘↩ digitado no compositor **recusa** o pedido e envia, e só uma dica de 11 pt avisa (escondida do VoiceOver). O botão de enviar deve passar a dizer "Recusar e enviar", ou o ⌘↩ deve ser bloqueado nesse caso até o usuário escolher. **[conferido]** | `ApprovalKeyboard.swift:3-22`, `ComposerView.swift:350-361, 802-811` | A | M |
| 2 | No chat de grupo, pedidos de permissão não aparecem: a linha `.approval` vira `EmptyView`. A faixa só diz "X está esperando você" e não é clicável. Ela precisa virar um botão que abre o cartão do Orb, ou o cartão precisa entrar no fio do grupo. **[conferido]** | `GroupChatView.swift:235`, `GroupPresenceStrip.swift:39` | A | M |
| 3 | Apagar um Orb desfaz os grupos de 2 membros (conversa e quadro somem), e o diálogo só fala em "a participação em N grupos". Ele precisa avisar "o grupo X será desfeito". **[conferido]** | `AppModel+Groups.swift:204`, `DeleteOrbDialog.swift:17` | A | P |
| 4 | Os botões "Apagar com a memória" e "Apagar e guardar a memória" são ambíguos, porque "com" pode ser lido como "levando junto". Troque por "Apagar tudo, inclusive a memória" e "Apagar, guardando a memória". **[conferido]** | `DeleteOrbDialog.swift:117-120` | A | P |
| 5 | O wizard de Novo Orb descarta minutos de conversa sem confirmar (Esc ou Cancelar), e ao bater o limite pede "toque em Criar Orb" mesmo sem nome, o que é um beco sem saída. **[conferido]** | `SheetsAndSettings.swift:234`, `WizardChatView.swift:120`, `WizardFooter.swift:15,29` | A | M |
| 6 | Skills propostas pelo Orb só se abrem pelo aviso no chat. Se o aviso passa, a proposta fica órfã. Falta uma seção "Aguardando sua revisão (N)" na página Skills. **[conferido]** | `AppModel+SkillReview.swift:46-55`, `SkillsView.swift` | A | M |
| 7 | O rodapé da lateral tem Rotinas, Conectores, Skills e Ajustes só como ícones, sem rótulo nem título de seção. Conectores e Skills quase não são descobertos. **[conferido]** | `SidebarView.swift:119-133` | A | P |
| 8 | A paleta ⌘K promete "um Orb, uma conversa ou uma ação" mas não indexa conversas, e também não tem "Ajustes". **[conferido]** | `CommandPalette.swift:176, 95-153` | A | M |
| 9 | Ajustes → Geral está sobrecarregada (perfil, cerca de 8 interruptores, Orbs, memória, dados e cerca de 30 linhas de atalhos que repetem o sheet de atalhos). Separe em "Geral", "Orbs" e um botão "Ver atalhos". | `SettingsView.swift:157-297` | A | M |
| 10 | "Refazer" só existe no hover: falta no menu de contexto e nas ações de acessibilidade da resposta. **[conferido]** | `TranscriptViews.swift:434-443` | A | P |
| 11 | O compositor do grupo está bem abaixo do individual: sem Esc para fechar menções, sem Tab, sem foco inicial, sem parar embutido e sem anexos (`attachmentCount` existe, mas nunca é desenhado). | `GroupComposer.swift:33-47`, `GroupMessageBubble.swift:158` | A | M |
| 12 | O objetivo do grupo é multilinha mas grava só no ↩. Sair do campo perde o texto, e ↩ não quebra linha. **[conferido]** | `GroupBoardView.swift:38-44` | A | P |

---

## 2. Por componente

### 2.1 Casca: lateral, paleta, menus, barra de menus

- **Lateral.**
  - Ações das linhas ("+" de conversa, recolher, ⌘1–9) só aparecem no hover (`SidebarView.swift:363, 564-583`).
  - O não lido é um ponto de 7 pt, sem número (`:611`). Proposta: badge numérico a partir de 2 (M/P).
  - Os três menus de contexto não batem: Orb não tem "Renomear" (só "Personalizar…"), Grupo também não, e Categoria não pode ser reordenada (M/P).
- **Contraste.** `Palette.hint` (opacidade 0,36, documentado como "decorativo, ~3:1" em `Theme.swift:43`) é usado em texto: a hora das conversas e "Nova conversa" em repouso (`SidebarChatList.swift:109, 144`) **[conferido]**. Trocar por `faint` (M/P).
- **Paleta.**
  - A entrada "Nova categoria…" usa a keyword "pasta", que é vocabulário reservado.
  - Grupos aparecem na seção "Espaço de trabalho". Melhor ter uma seção "Grupos" própria.
  - O estado vazio não oferece nada (ex.: "Criar Orb chamado x").
  - Hover e seleção de teclado são dois destaques independentes (suspeita: dois itens acesos ao mesmo tempo).
- **Menus.**
  - Há um `Toggle` dentro do menu "Orbs" para o atalho global (`OrbApp.swift:250`), fora do padrão do macOS. Ele cabe melhor em Ajustes.
  - O sheet de atalhos não tem atalho próprio. Proposta: ⌘/ (B/P).
- **Painel da barra de menus (QuickAsk).**
  - Não tem botão de enviar, só ↩ (ruim para VoiceOver).
  - Não lista grupos.
  - O erro "modelo não conectado" não tem botão.
  - "Abrir Ajustes" usa `SettingsRouter.show` sem aba, enquanto o FirstRunCard usa `.open(.models)`, e os dois podem cair em abas diferentes (M/P).

### 2.2 Ajustes

- **"Sair" quer dizer desconectar a conta** (`ProviderSettings.swift:298,306`, `ClaudeCodeSettings.swift:26,52`) **[conferido]**. Num app de Mac, "Sair" lembra encerrar o app. Use "Desconectar" (M/P).
- **A aba "Permissões" é do macOS, mas o Orb também tem permissões próprias.** Renomeie para "Acesso ao Mac" (M/P).
- **"Pasta dos Orbs" e "Pasta de dados" colidem com "Pasta"** (`SettingsView.swift:254,262`). Use "Local dos dados" e "Local padrão das pastas" (B/P).
- **A chave de busca na web fica na aba Navegador, longe das outras chaves.** Deixe ao menos uma frase apontando para lá (B/P).
- **A janela tem largura fixa de 640 pt e todas as abas têm 720 de altura.** Os textos `.caption` longos rolam.

### 2.3 Chat

- **Linha de trabalho invisível ao VoiceOver.** Tempo, contagem para tentar de novo e gasto estão em `accessibilityHidden` ou `children: .ignore` (`ChatView.swift:1013,1129`). Leve isso para o `accessibilityValue` (M/P).
- **Confirmação de Editar/Refazer.** Ela sempre abre um diálogo modal. Basta confirmar quando houve passos com efeito no Mac depois da mensagem (M/M).
- **Erro com duas aparências.** O `NoticeRow` tem "Tentar de novo", "Trocar modelo" e "Detalhes". O erro de envio do compositor é um `Label` `.caption` sem ação (`ComposerView.swift:88-96`). Unificar (B/P).
- **Plano.** O anel do plano some quando o turno acaba e não sobra resumo. Ele também usa a mesma forma de anel do medidor de contexto, com outro significado (M/M e B/P).
- **Pergunta.** Uma pergunta pulada aparece como "Sem resposta". Melhor "Pulada" (B/P).

### 2.4 Compositor

- **Dica de teclas.** Ela está em `accessibilityHidden` (`ComposerView.swift:72`), e é lá que moram ↩, ⇥ e ⌘↩. Leve para o `accessibilityHint` do campo (A/P).
- **Pilha de faixas acima do campo.** Rotina ou outro chat, processos, edição, anexos, erro e sugestões de `/` podem se empilhar e comer a altura do transcript. Funda numa linha com contagem (M/M).
- **⇥ não tem botão.** Quem nunca digitou durante um turno não descobre a fila. Opção: um menu no botão enviar ("Orientar agora" / "Depois da tarefa") (M/M).
- **Chip de permissão só com ícone.** Mostre o nome do modo quando for diferente do padrão (M/P).
- **Microcopy.** "Ver" na faixa de outro chat deve virar "Voltar para a conversa". Na tela ao vivo, "Privado" e "Mostrar" devem virar "Ocultar tela" e "Mostrar tela", e "Parar", que para o Orb inteiro, deve virar "Parar Orb" (M/P).

### 2.5 Painel do Orb

- **"Apagar Orb…" escondido.** Ele mora no rodapé do card "Pode usar", que vem fechado (`BotInspector.swift:420,496`). Leve para o fim da aba Geral ou para um menu "⋯" no cabeçalho (M/P).
- **Renomear falha em silêncio.** Quando dá errado, o campo volta ao nome antigo sem dizer por quê (`:934`) (M/P).
- **O link "Como funciona" da Memória** é `onTapGesture`, e o Tab não chega nele (`MemoryViews.swift:87`). Use `Button(.link)` (M/P).
- **A aparência abre numa folha sem "Cancelar".** Falta "Restaurar o que estava" (M/M).
- **Cinco abas numa coluna de 244 pt** com `minimumScaleFactor(0.85)` (suspeita de corte).

### 2.6 Criar Orb (wizard, Orb cria Orb, importar)

- **"Toque" num app de Mac.** Aparece em 4 lugares (`WizardChatView.swift:120-121`, `WizardPreviewPane.swift:338,357`) **[conferido]**. Troque por "clique" (M/P).
- **O cartão de proposta não chega ao formulário completo.** Ele não escolhe modelo nem pasta. Proposta: um "Abrir no assistente" que reaproveite `passDraftToForm` (M/M).
- **O botão "Criar" do cartão é desenhado à mão** (`OrbProposalCard.swift:456-481`) em vez de usar `PrimaryPillStyle` (B/P).
- **A folha do wizard tem 820 pt fixos e o texto diz "revise ao lado".** Suspeita de folha maior que a janela no mínimo.

### 2.7 Grupos

- **Membros sem ação principal.** Clicar num membro não abre o Orb (`GroupPanel.swift:129-183`) (M/P).
- **Menções pobres.** O `MentionPicker` não mostra avatar nem papel (M/P).
- **"Adicionar Orb" desabilitado com motivo errado.** O help diz "até 8 Orbs" mesmo quando o motivo é "todos já estão" (`GroupPanel.swift:83`) (M/P).
- **Novo grupo com menos de 2 Orbs.** ⌥⌘G e a paleta abrem a folha, que não tem como ser concluída (M/P).
- **A faixa de presença aparece e some** (0 ↔ 30 pt), empurrando o compositor. Reserve a altura (M/P).
- **`Palette.warn` com três sentidos.** É alerta, orquestrador e "esperando você" ao mesmo tempo (B/P).

### 2.8 Rotinas

- **"Expressão cron" exposta.** Mostre a regra em português sob o campo ("Segunda a sexta, às 9h") e renomeie para "Agenda avançada" (A/M).
- **Fuso em texto livre.** O erro não diz que o problema é o fuso (M/M).
- **O cartão não leva ao Orb dono.** A falha só aparece dentro da folha. Proposta: selo "Falhou" no cabeçalho do cartão (M/P).
- **Pausada = opacidade 0,6 no cartão inteiro.** O contraste cai. Atenue só o avatar e o título (M/P).
- **Sem ordem nem agrupamento.** Ordene pela próxima execução ou agrupe por Orb (M/M).

### 2.9 Conectores

- **"Testar conexão" escondido.** Ele fica no menu "…". O resultado some em 6 s, até quando é falha (M/P).
- **"Conectar assim mesmo" em vermelho.** Ele usa o slot `destructiveTitle` sem destruir nada (`LocalConnectorSheet.swift:189`) **[conferido]**. Proposta: um `secondaryTitle` neutro no `SheetFooter` (M/P).
- **"Desligado" com dois sentidos.** O mesmo texto vale para o interruptor e para o servidor parado. Proposta: "Desativado" para o interruptor e "Parado" para o servidor (M/P).
- **Galeria e Instalados gerenciam o mesmo conector.** A galeria deveria só mostrar "Instalado ✓" e levar à aba Instalados (M/M).
- **O "+" da barra abre direto o formulário técnico.** Proposta: um menu com "Da galeria", "Do registro" e "Manualmente" (M/P).
- **O caminho de erro depende de texto.** Ele faz `message.contains("app registrado")` (`ConnectorsView.swift:935`), o que é frágil (M/P).

### 2.10 Skills

- **Skill desligada só fica translúcida (0,55), sem selo** (M/P).
- **Clicar na linha não faz nada.** Para ler, é preciso "Editar…", que avisa nada sobre descolar da origem (M/P).
- **⌘F vai sempre para Explorar.** Não há como buscar nas instaladas (M/M).
- **Erro cru na prévia.** A prévia mostra `localizedDescription` (`SkillsView.swift:420,461`), enquanto o cartão usa `CatalogError.cardText` (M/P).

---

## 3. Coexistência

### 3.1 Teclas que mudam de sentido

- **⌘↩ tem quatro sentidos:** enviar, parar e enviar, permitir o pedido e, com pedido aberto e texto no compositor, recusar e enviar. O caso perigoso é o item 1 da tabela.
- **Esc tem seis donos:** recusar o cartão, pular a pergunta, fechar `/`, cancelar a edição, cancelar a entrega da tela ao vivo e fechar a busca. A precedência é coerente no código, mas invisível. No banner "Editando · Esc cancela", às vezes é preciso apertar Esc duas vezes (`ComposerView.swift:692`).

### 3.2 Chat individual × chat de grupo

| | Individual | Grupo |
|---|---|---|
| Pedido de permissão | cartão com ⌘↩/Esc | some do fio |
| Compositor | anexos, ditado, `/`, fila, parar | só texto e menções |
| Bolha do usuário | Copiar, Editar | sem menu |
| Mensagem entre Orbs | `OrbMessageRow` com estado e "Ver troca" | `GroupAssignmentLine` sem estado |
| Fala de outro Orb | `OrbSpeechBubble` (nome a 45% de luz, Markdown só inline) | `GroupMessageBubble` (contraste WCAG, Markdown completo) |
| Margem direita da resposta | 90 | 40 |

A proposta é um só componente para cada linha: o `ExchangeSheet` passa a usar `GroupMessageBubble`, e a linha do grupo
reaproveita `ExchangeStateMark`.

### 3.3 Painel do Orb × painel do grupo

Os dois ocupam a mesma coluna, mas o Orb usa abas com ícone e `Form`, e o grupo usa `Picker` segmentado e `ScrollView`.
O nome do Orb grava ao perder o foco, e o objetivo do grupo só no ↩. Apagar o Orb abre uma folha, e apagar o grupo
abre um `confirmationDialog`, copiado em dois lugares (`SidebarGroupRow.swift:119`, `GroupPanel.swift:237`).
Padronize o momento de gravar e a forma de confirmar.

### 3.4 Rotinas × Conectores × Skills: três telas irmãs, três padrões

| | Rotinas | Conectores | Skills |
|---|---|---|---|
| Layout | grade de cartões | grade de cartões | lista de linhas |
| Ações | botões visíveis, sem "…" | tudo no "…" | "Usar" visível, resto no "…" |
| Apagar | só dentro do editor | pelo "…" | pelo "…" (o editor não tem) |
| "+" da barra | menu com modelos | formulário manual | "Nova skill" |
| Estado desligado | "Pausada" + opacidade | "Desligado" | só opacidade |
| Vazio | modelos prontos | um botão | um botão |
| Espaçamento/raio | `Spacing.card*`, raio 12 | 14/12, raio 14 | 14/11, raio 14 |

A proposta é um padrão único: uma ação principal visível, o menu "…" com Editar e Apagar, "+" com "Do catálogo / Do
zero / Modelo" e o par "Ativa/Pausada" nas três telas.

### 3.5 Ligação com o Orb

- **Rotina:** aparece na aba do painel do Orb, mas o cartão da página não leva de volta ao Orb.
- **Conector:** o painel do Orb só mostra "N ativos", sem dizer quais.
- **Skill:** não aparece no painel do Orb em lugar nenhum. Só chega ao Orb pelo `/` do compositor.

A proposta é uma seção "Skills e conectores deste Orb", só de leitura, no painel, com link para a página (A/M).

### 3.6 Caminhos duplicados que divergem

- **Novo Orb** tem quatro entradas: ⌘N, "+" da lateral, paleta e convite da lateral. O convite se comporta de jeito diferente conforme a tela atual, e o "+" escreve o atalho no rótulo (`SidebarView.swift:191`).
- **Ajustes** abre de cinco formas, e só `SettingsRouter.open(aba)` garante a aba certa.
- **Atalhos** aparecem em três listas: o sheet, Ajustes → Geral e o menu.
- **Criar Orb** tem três fluxos (wizard, cartão de proposta, importar) com campos diferentes.
- **Apagar** usa quatro formas de confirmação (folha, `confirmationDialog`, só no editor, e categoria vazia sem perguntar).

### 3.7 Vocabulário

| Conceito | Termos em uso | Sugestão |
|---|---|---|
| Nível de autonomia | Modo, Permissões | "Permissões", com o modo como valor |
| Sortear aparência | Sortear, Aleatório, Sortear aparência | "Sortear" |
| Editar aparência | Personalizar…, Desenhar, aba Aparência | "Personalizar" |
| Instruções do Orb | Como funciona, Instruções do Orb, Identidade | "Instruções" |
| Preferências | Preferências (Orb), Combinados (grupo) | manter, com subtítulo no grupo |
| Desconectar conta | Sair | "Desconectar" |
| Ir ao catálogo | Abrir a galeria, Explorar catálogo, Explorar o registro | "Explorar" |
| Erro | Erro, Não conectou, Não deu certo | "Não deu certo" + motivo |
| Parar | turno, Orb inteiro (tela ao vivo), conversa entre Orbs, grupo | verbo + objeto: "Parar Orb", "Parar grupo" |
| Ação de clique | toque | "clique" |

O vocabulário reservado (Pasta, Grupo, Espaço de trabalho, Categoria) tem dois vazamentos: a keyword "pasta" na
paleta, e "Pasta dos Orbs/de dados" em Ajustes.

### 3.8 Sistema visual

Medido em `Sources/Orb`:

- **608 `.system(size:)` fixos.** Os mais comuns são 12 pt (223) e 11 pt (153). Não há token de fonte além de `conversationFont` e `narrationFont`, e nada acompanha o tamanho de texto do sistema. A proposta começa pelos dois tokens de leitura (P) e depois cria tokens de legenda e rótulo (G).
- **Cantos arredondados sem token.** Há 10 raios literais diferentes: 8 (36 usos), 10 (29), 12 (20), 14, 7, 6, 3, 16, 18. A proposta é `Radius.small/medium/card/bubble` no `Theme`.
- **25 cores literais fora do `Theme` e de `Orbs/`.** São `Color.white.opacity(…)` em CatalogParts, OrbEditor, WizardPreviewPane e WelcomeView, sombras `.black.opacity(0,3)` repetidas e `0x070707` copiado em `OrbInk`. A proposta é criar `Palette.chipFill` e `Shadow.popover`.
- **`Palette.warn` acumula três significados** (alerta, orquestrador, esperando você).
- **Três estilos para "ação secundária":** `.link`, `chipButton` e texto.
- **Pontos fortes que devem ficar:** Reduce Motion respeitado em cerca de 350 pontos, 321 `.help`, `SheetKit` unificando folhas, `OrbScopePicker` compartilhado, catálogo único de atalhos e boas-vindas em etapas.

---

## 4. Ordem sugerida

1. **Segurança de decisão (P/M):** itens 1, 3, 4 e 12, e "Conectar assim mesmo" em cor neutra.
2. **Descoberta (P):** rodapé com rótulos, "Refazer" no menu, dica de teclas no VoiceOver, propostas de skill na página e "Apagar Orb" visível.
3. **Grupo no nível do individual (M):** pedidos de permissão, compositor, menu da bolha e estado da troca.
4. **Vocabulário (P):** uma passada só pela tabela 3.7.
5. **Espaço de trabalho com padrão único (M):** tabela 3.4, mais cron legível.
6. **Tokens (M/G):** raio, `chipFill`, sombra e depois fontes escaláveis.
7. **Ajustes reorganizado e paleta com conversas (M).**

## 5. O que não foi verificado

- Nenhuma tela foi capturada. Os itens "suspeita" (corte em 244/460 pt, contraste de cartões translúcidos, dois destaques na paleta, folha de 820 pt) pedem `--snapshot` em 460 e 1100 pt.
- Leitura parcial: `ImportPanel`, `OrbEditor` depois da linha 300, `SelectableProse`, `MarkdownBlockViews`, `AttachmentViews`, `ModelPopover`, `Tips`, `ProfileSettings` e `LiveScreenLayerView`.
- Nenhum teste rodou, porque nada de código mudou.
