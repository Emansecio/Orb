# Revisão de interface do Orb — 14/10/2026

Auditoria visual feita com olho de frontender exigente, sobre o build de `46df30b`. Base: o app real (Chat, Rotinas,
Conectores, Skills, Ajustes nas 5 abas, painel do Orb nas 4 abas, busca, Novo Orb) e 103 cenas do modo `--snapshot`
(1100×760 @2x, tema escuro). Nenhum código foi alterado.

Prioridades: **P0** defeito visível ou erro; **P1** inconsistência de sistema (o mesmo conceito com caras diferentes);
**P2** polimento; **P3** texto e microcopy.

---

## As 10 coisas que eu atacaria primeiro

1. **Folhas que esticam até 560 pt com conteúdo curto** (Apagar Orb, Memória, prévia de skill, instalar conector):
   metade da folha é vazio preto. Causa única em `SheetKit.swift:72` (`.frame(maxHeight: .infinity)` no conteúdo).
2. **"em 0 seg."** em itens recém-salvos (memória do grupo, combinados): futuro para algo do passado. `RelativeTime`
   (`BotInspector.swift:1059`) não trata a janela de poucos segundos — devia dizer "agora".
3. **Três estilos de controle segmentado** convivendo (Ajustes, Novo Orb com segmentado dentro de segmentado,
   "Todos os Orbs / Só alguns" do conector). Escolher um.
4. **Ações destrutivas com cara de ação primária** (cartão "Apagando arquivos" com "Permitir" branco, "Redefinir…").
5. **Avisos centralizados num transcript alinhado à esquerda** (rodadas, delegações, notas do sistema) e cartões
   desalinhados do texto (x≈412 vs 427).
6. **Typo "Login com app seu"** (`ConnectorGallery.swift:71`).
7. **Formato de tempo relativo em três dialetos**: "há 39 min." (com ponto), "há 2 h", "em 9 h 57 min".
8. **Botões "Abrir no Fin…" / "Abrir no Term…" truncados** no painel, repetindo Finder/Terminal do topo
   (`BotInspector.swift:469-471`).
9. **Cores de severidade sem regra**: erro em laranja aqui, "falhou" em vermelho ali, atenção em laranja também.
10. **Acessibilidade das abas do painel**: os frames AX das abas estão errados (clique por coordenada cai na aba
    vizinha) e o rótulo "Pasta e acessos" não bate com o visível "Pasta".

---

## P0 — Defeitos visíveis

| # | Onde | O que | Correção sugerida |
|---|------|-------|-------------------|
| 1 | Folhas (`SheetKit.swift:72`) | Conteúdo com `maxHeight: .infinity` faz toda folha `orbSheet` crescer até `SheetSize.maxHeight` (560). Apagar Orb, Memória vazia, prévia de skill e instalar conector ficam com 40–60% de vazio. | Deixar a folha abraçar o conteúdo (`fixedSize(vertical:)` ou `maxHeight` só como teto), rolar só quando passar de 560. |
| 2 | Tempo relativo (`BotInspector.swift:1059-1071`) | `localizedString(for:relativeTo:)` devolve "em 0 seg." quando a data é igual ou um tico depois de `now`. | `abs(diff) < 60` → "agora"; nunca futuro para coisa já gravada. |
| 3 | Galeria de conectores (`ConnectorGallery.swift:71`) | "Login com app seu". | "Login com seu app" (ou "Entrar pelo app"). |
| 4 | Skills | Descrições com "...." (quatro pontos) vindas do catálogo. | Normalizar reticências no texto vindo de fora. |
| 5 | Painel → Pasta (`BotInspector.swift:469-471`) | "Abrir no Fin…" / "Abrir no Term…" truncados, e duplicam os botões Finder/Terminal do cabeçalho. | Tirar a dupla ou usar só ícone + tooltip. |
| 6 | Painel → Arquivos (`BotInspector.swift:796-801`) | `Text(file.marker?.rawValue ?? "").frame(width: 22)` deixa uma calha vazia de 22 pt em toda linha sem marcador git. | Calha só quando a pasta é repositório, ou marcador à direita. |
| 7 | Painel (abas) | Frames de acessibilidade das abas deslocados; rótulo AX "Pasta e acessos" ≠ texto "Pasta". VoiceOver e automação erram de aba. | Rótulo AX igual ao visível; conferir o frame de cada aba. |
| 8 | Transcript → comandos longos | Truncamento no fim esconde justamente os argumentos que distinguem um comando do outro. | Truncar no meio, ou quebrar em 2 linhas com o resto em tooltip. |
| 9 | Chat sem modelo | Cartão "Conecte um modelo" é cortado pelo composer quando a janela é baixa. | Reservar espaço ou rolar o cartão junto com o transcript. |
| 10 | Ajustes → Aparência | Grade de ícones cortada na borda; rótulos truncados; duas células destacadas ao mesmo tempo (hover + seleção com o mesmo tratamento). | Estados distintos para hover e selecionado; grade que respeita a largura. |
| 11 | Ajustes → Geral | Versão "e9cde71-dirty" exposta para a usuária. | Mostrar versão de marketing; hash só com ⌥ ou em Sobre. |
| 12 | Aprovações | Vários cartões de aprovação ao mesmo tempo, todos anunciando ⌘↩ / esc. Qual responde? | Atalho só no cartão em foco (o primeiro), os outros sem dica. |
| 13 | Pop-over de permissões | Título contradiz a opção marcada "Perguntar antes". | Título neutro ("Permissões") e o estado só na opção. |
| 14 | Importação (Novo Orb → Prévia) | Itens de "Como funciona" mostram o markdown cru ("- Responda…") dentro do rótulo do checkbox. | Tirar o marcador de lista ao montar o item. |
| 15 | Modo snapshot | Mostra o e-mail real da conta do Claude Code apesar da pasta de dados isolada. | Isolar também a leitura da conta do CLI em `DevRun`. |

### Situação dos P0 (14/10, depois da rodada de correções)

| # | Situação | O que foi feito / por quê |
|---|----------|---------------------------|
| 1 | Falso positivo | Efeito do `--snapshot`, que dá à janela um frame fixo e estica a folha. No app, a folha toma a altura ideal. |
| 2 | Corrigido | `RelativeTime.text`: menos de 1 minuto, para frente ou para trás, vira "agora". |
| 3 | Corrigido | "Login com seu app". |
| 4 | Corrigido | Não eram 4 pontos: era ponto final + "…" do corte. `MemoryText.clip` corta na palavra e tira pontuação solta antes do "…"; `tidyEllipsis` arruma resumos já gravados (cartão de skill). |
| 5 | Corrigido | Os botões duplicados saíram da aba Pasta; Finder/Terminal ficam só acima das abas. |
| 6 | Corrigido | A calha do marcador só aparece quando algum arquivo da lista tem marcador. |
| 7 | Corrigido em parte | A barra de abas virou um grupo AX "Seções do painel", com cada aba como botão próprio. O rótulo "Pasta e acessos" é intencional (descreve a aba inteira) e ficou. |
| 8 | Corrigido | Linhas de ferramenta truncam no meio: o verbo e o fim do comando aparecem. |
| 9 | Não reproduzido | Não apareceu nas capturas novas nem no app. Ficou como está; vale rever se voltar a aparecer. |
| 10 | Não reproduzido | O corte da grade não apareceu de novo. Hover e seleção com o mesmo tratamento seguem para o P1. |
| 11 | Intencional | O "-dirty" só aparece em builds locais com mudanças por commitar. |
| 12 | Corrigido | `showsApprovalKeys`: só o cartão que ⌘↩/esc respondem (o pedido pendente mais novo) mostra as teclas. Vale para aprovações, perguntas e propostas de Orb. |
| 13 | Corrigido | Título trocado para "Quando este Orb pede sua permissão". |
| 14 | Corrigido | `ImportRow.shown` troca "- " e "* " por "• ", mantendo o recuo. |
| 15 | Corrigido | `FirstRunCard.detect()` não consulta o CLI quando `DevRun` está ativo. |

---

## P1 — Consistência (o mesmo conceito com caras diferentes)

**Controles**
- **Segmentados**: pelo menos 3 desenhos (Ajustes; "Quem ele é / Aparência" + "Criar conversando / Formulário" aninhados
  no Novo Orb; "Todos os Orbs / Só alguns" no conector). Segmentado dentro de segmentado é o pior caso: vira um só
  nível com abas ou passos.
- **Pull-down nativo com chevron azul** ("Mudar pasta", "Mudar…" no Novo Orb) no meio de pickers no estilo do app.
  Pela regra da casa (controle novo copia a linha vizinha), devia ser o mesmo picker de Modelo/Esforço.
- **Ações da mesma linha com pesos diferentes**: "Sair" com borda, "Trocar"/"Remover" sem borda (Ajustes → Modelos).
- **Links azuis** só em alguns lugares ("Abrir o app", "Abrir Ajustes" no Pergunta rápida, "Ajustar o contexto das
  conversas…" no pop-over de contexto, "Importar de outro assistente" no formulário). O resto do app usa botões
  cinza/brancos. Escolher: ou link azul é um padrão, ou some.
- **Botão primário branco demais**: Conectores tem 11 botões brancos na mesma tela; primário vira ruído. Primário só
  para a ação da tela; nos cards, botão secundário.
- **Destrutivo × primário**: "Permitir" em "Apagando arquivos", "Redefinir…" e "Apagar e guardar a memória" aparecem
  como pílula branca de primário. Destrutivo merece vermelho (ou ao menos não ser o branco de "faça isso").

**Cores de estado**
- Erro laranja (rodada falhou, conector não respondeu) vs "falhou" vermelho vs atenção laranja vs meta verde. Definir
  uma escala: vermelho = falhou, laranja = precisa de você, verde = ok, e usar em todo lugar.
- Gráficos de Uso: barras azuis num, brancas no outro.

**Tempo e números**
- "há 39 min." (com ponto, `.short` do `RelativeDateTimeFormatter`) vs "há 2 h" vs "em 9 h 57 min" vs "1 min".
  Um formatador só, sem ponto final de abreviação.
- "Próxima" em ordem diferente na página Rotinas e no painel do Orb.
- Coluna numérica de tabela centralizada (devia alinhar à direita, com `monospacedDigit`).

**Separadores e caixa**
- "·" em uns metadados, dois espaços em outros.
- Capitalização de badges e cabeçalhos: "INSTRUÇÕES QUE O ORB VAI SEGUIR" é o único cabeçalho em caixa alta do app
  (`SkillsView.swift:441`, `.textCase(.uppercase)`); o resto é bold em caixa normal ("Chave", "Usar com", "Quando").
- Cabeçalho de seção "Rotinas" repete o nome da aba "Rotinas" logo acima, no painel.

**Transições**
- Crossfade que sobrepõe conteúdo velho e novo ao trocar de aba/tela; por um instante as duas telas se misturam.
  Preferir troca seca ou fade-out → fade-in.
- Altura da janela de Ajustes pula a cada aba.

### Situação do P1 (14/10, depois da rodada de correções)

Regras que ficaram valendo, para o próximo controle já nascer certo:

- **Segmentado nativo** escolhe um valor dentro de um formulário ("Criar conversando | Formulário", "Todos os Orbs | Só
  alguns", Período). **Pílula** (`CatalogTabBar`, `PillTabs`) troca de parte da tela (Galeria/Instalados/Explorar,
  "Quem ele é | Aparência"). As abas do painel do Orb seguem com o próprio desenho (ícone sobre texto). Nunca um
  segmentado dentro de outro.
- **Menu de ações** num botão (`Menu` com `.menuStyle(.button)`) sem a seta azul do sistema (`.menuIndicator(.hidden)`),
  com "…" no título.
- **Primário branco** só para a ação principal da tela. Em cards repetidos, pílula secundária. **Destrutivo** é vermelho:
  `PrimaryPillStyle(isDestructive:)`, `SheetFooter(primaryIsDestructive:)` e o "Permitir" de pedido arriscado.
- **Cores de estado**: vermelho (`Palette.danger`) = algo rodou e falhou, ou destrói; laranja (`Palette.warn`) = nada
  falhou, mas precisa de você ou pede cuidado; verde (`Palette.ok`) = deu certo. Documentado nos próprios tokens.
- **Tempo relativo**: um formato só, sem ponto de abreviação ("há 39 min", "há 1 semana", "em 3 h"), igual ao das rotinas.
- **Links azuis** ficam como padrão para ação de texto que leva a outro lugar ou abre algo ("Abrir Ajustes",
  "Gerenciar", "Importar de outro assistente"); ação no próprio lugar é botão.
- **Separadores**: "·" entre itens de uma lista de metadados; dois espaços só entre rótulo e detalhe em cores diferentes
  (as linhas de ferramenta: "Rodando no Terminal  python3 …").

| Item | Situação | O que foi feito |
|------|----------|-----------------|
| Segmentados | Corrigido | Novo Orb: "Quem ele é \| Aparência" virou pílula (`PillTabs`); o segmentado de dentro ficou sozinho no seu nível. |
| Pull-down com seta azul | Corrigido | "Mudar…" (Novo Orb) e "Mudar pasta…" (painel) sem a seta do sistema, com a cara dos botões vizinhos. |
| Pesos na mesma linha | Corrigido | "Sair" (Ajustes → Modelos) sem borda, como "Trocar" e "Remover…". |
| Links azuis | Mantido como regra | Ver regras acima. |
| Primário branco demais | Corrigido | "Conectar" nos cards da galeria virou pílula secundária; "Resolver" segue laranja. |
| Destrutivo × primário | Corrigido | "Redefinir…", "Apagar e guardar a memória" e "Permitir" de ação arriscada em vermelho. |
| Cores de estado | Corrigido | Falhas que estavam em laranja passaram a vermelho (conector que não conectou, selo "Erro", "Não deu certo" no chat, relatório de rodada que falhou, login/chave/importação/foto com erro, "Não funciona" nas permissões). O que pede você segue laranja. |
| Gráficos de Uso | Corrigido | "Por horário" no azul do gráfico de cima (horário de pico cheio, os outros esmaecidos), em vez de branco. |
| Formato de tempo | Corrigido | `RelativeTime` escrito à mão, sem "min." nem "sem."; testes novos. |
| "Próxima" em ordem diferente | Corrigido | Dia primeiro, depois quanto falta, na página Rotinas, no painel e no editor. |
| Coluna numérica centralizada | Não encontrado | Os números de Uso já alinham à direita com `monospacedDigit`; não há outra tabela numérica. |
| "·" vs dois espaços | Mantido como regra | Ver regras acima. |
| Caixa alta | Corrigido | "Instruções que o Orb vai seguir" em caixa normal; os grupos de categorias do editor de aparência também. |
| "Rotinas" repetido | Corrigido | A aba Rotinas do painel não repete o título. |
| Crossfade misturando telas | Corrigido | `AnyTransition.pageSwap`: a tela nova entra em 0,18 s e a velha sai em 0,08 s (páginas, abas do catálogo e do painel, troca de Orb, categorias do editor). `docs/MOVIMENTO.md` §2.13 atualizado. |
| Altura dos Ajustes pulando | Corrigido | Uma altura só (720) para todas as abas; a mais alta rola. |
| Aparência: hover × selecionado (P0 #10) | Já distintos | Hover é só um fundo de 5%; selecionado tem fundo de 9%, contorno e rótulo em negrito. A captura antiga pegou o ponteiro parado sobre uma célula. |

---

## P2 — Polimento

**Chat e transcript**
- Notas do sistema, delegações ("Atlas pediu ajuda ao Revisor") e "2 mensagens com Pesquisador" centralizadas num
  transcript alinhado à esquerda: o olho pula de eixo. Alinhar ao recuo do texto da resposta.
- Ícones de estado das delegações (…, ⚠, relógio) pequenos e sem rótulo; precisam de tooltip ou palavra.
- Estado "trabalhando" ambíguo: spinner + botão de enviar cinza. O botão devia virar "parar" de forma explícita.
- Dica do composer sempre visível e com jargão; mostrar só no foco vazio.
- Corte duro do conteúdo sob a barra segmentada flutuante e sob a busca (falta máscara/gradiente).
- Cartões no transcript com recuo diferente do texto (x≈412 vs 427).

**Barra lateral**
- Linhas com alturas diferentes conforme tem ou não subtítulo; badge "…" cortado.
- Coluna "Liberado" com borda direita irregular.

**Folhas e formulários**
- Editor de rotina: o `TextEditor` de "O que fazer" mostra uma barra de rolagem interna mesmo com 1 linha; o aviso
  laranja do topo é repetido no rodapé ("Atlas vai esperar sua aprovação.").
- Memória vazia: subtítulo "Nada guardado ainda" e corpo "Ainda não guardou nada." dizem a mesma coisa; o filtro
  "Mostrar: Tudo" aparece sem nada para filtrar.
- Prévia de skill: instrução em monoespaçada crua; ler como Markdown renderizado seria mais honesto.
- Instalar conector: "Authorization" e "Bearer" em fonte mono como rótulos de campo — jargão HTTP na cara da usuária.
  "Token do GitHub" basta; o cabeçalho vai em Avançado.
- Novo Orb (importação): a prévia à direita continua "Seu Orb aparece aqui conforme você preenche" mesmo com nome e
  papel já vindos da importação; botão "Ver" solto à direita da skill; área de texto vazia com barra de rolagem.
- Pop-over de contexto: campo "No que focar no resumo?" com a borda nativa, diferente dos outros campos do app.
- Pop-over de modelo com espaço morto.
- Notas de rodapé longas em Ajustes (paredes de texto cinza); cortar para uma linha + "Saiba mais".

**Telas de catálogo**
- Skills: cards com pouca densidade.
- Categorias de Aparência só com ícone, sem rótulo.
- "Aleatório" aparece duas vezes no Novo Orb.
- Chips de capacidade ("Terminal e arquivos", "Perguntar antes") com cara de botão, mas não clicáveis.

**Paleta de comandos**
- Ícone de "Novo grupo…" mais largo que os outros desalinha a coluna de títulos.

**Pergunta rápida**
- Avatar sozinho numa linha inteira acima do nome; daria para pôr na mesma linha de "Atlas · Assistente do seu Mac".


### Situação do P2 (14/10, depois da rodada de correções)

| Item | Situação | O que foi feito |
|------|----------|-----------------|
| Linhas fora do eixo | Corrigido | Avisos, eventos, delegações, "2 mensagens com…" e rodadas de rotina começam no x do texto da resposta (`alignedWithReplyText()`). No chat de grupo, que tem bolhas e avisos centralizados, os eventos seguem centralizados. |
| Estados das delegações | Corrigido | Palavra ao lado do ícone: "Aguardando", "Não deu certo" (vermelho), "Recusado", "Cancelado", "Sem resposta". "Respondido" fica só com o ✓. |
| Botão "trabalhando" | Já existia | Com o campo vazio o botão já vira Parar (quadrado, dica com o atalho); com texto, um Parar redondo aparece ao lado. A linha de teclas perdeu o jargão: "↩ envia agora · ⇥ depois da tarefa · ⌘↩ para a tarefa e envia" (também na Pergunta rápida). |
| Dica do composer | Já existia | "↩ envia · ⇧↩ nova linha" já aparecia só com o campo focado e vazio; o jargão era o da linha acima. |
| Corte sob as pílulas | Corrigido | Esmaecimento de 14 pt na cor do fundo sob a barra de Skills/Conectores. A busca de Explorar rola junto com o conteúdo. Não visto rolando (as capturas não rolam). |
| Recuo dos cartões | Corrigido | Uma margem só (`gutter` = 44) para texto, linhas de ferramenta, plano e cartões de aprovação, pergunta e proposta. |
| Barra lateral | Corrigido | Altura mínima igual para linhas com e sem subtítulo. O "…" cortado era a presença do grupo: com vários Orbs ativos vira "2 Orbs trabalhando…", com a frase inteira na dica. |
| Coluna "Liberado" | Corrigido | Linhas sem "Testar" reservam o espaço do botão; todos os estados terminam no mesmo x. |
| Editor de rotina | Corrigido | Texto curto (uma linha) sem barra nem trilho em qualquer `PlaceholderTextEditor`; o aviso de aprovação fica só no topo. |
| Memória vazia | Corrigido | Sem itens, a folha esconde busca e filtro e explica como a memória cresce. |
| Prévia de skill | Corrigido | Instruções renderizadas como Markdown (`MarkdownChunk`). |
| Instalar conector | Corrigido em parte | "Authorization"/"Bearer" viraram "Chave de acesso" em fonte normal; o prefixo é posto ao salvar. Um rótulo por serviço ("Token do GitHub") ficou para depois: o campo não sabe o nome do serviço. |
| Importação no Novo Orb | Corrigido | A prévia mostra nome e papel importados; "Ver" logo abaixo da skill; campo vazio sem trilho de rolagem. |
| Pop-over de contexto | Corrigido | Campo no fundo `Palette.raised` com canto 8, como os outros campos (a busca de modelo também). |
| Pop-over de modelo | Corrigido | Altura segue a lista (até 320) em vez de 380 fixos. |
| Rodapés de Ajustes | Corrigido | Textos dos interruptores de Geral em uma frase; Privacidade, chave de pesquisa, Uso e permissões do Mac com uma frase e "Saiba mais" (`LearnMoreNote`). |
| Cards de Skills | Corrigido | Menos espaço entre linhas e cards, nas instaladas e em Explorar. |
| Categorias de Aparência | Corrigido | Nome sob o ícone quando cabe; sem espaço, volta ao desenho com o nome só na escolhida. |
| "Aleatório" duas vezes | Mantido | Um está em "Quem ele é", o outro em "Aparência"; nunca aparecem juntos e fazem a mesma coisa. |
| Chips de capacidade | Corrigido | Viraram etiqueta, sem fundo de botão (o fundo só pisca quando o assistente muda algo). |
| Ícone de "Novo grupo…" | Corrigido | `person.2` no lugar de `person.3`, que estourava a coluna de 22 pt. |
| Avatar da Pergunta rápida | Corrigido | Na mesma linha de "Atlas · Assistente do seu Mac"; com muitos Orbs, volta aos avatares acima. |

---

## P3 — Texto e microcopy

- "Login com app seu" → "Login com seu app" (P0, repetido aqui pela lista).
- "Sem chave" como tipo de conexão soa como erro; "Não precisa de chave".
- "Padrão (modelo)": quando a conta do modelo padrão não está ligada, o rótulo mostra o id cru
  (`ModelPicker.swift:16-19`). Mostrar "Padrão" sozinho nesse caso.
- Atalho em Ajustes → Geral diz "(opcional, no menu Orbs ou em Ajustes → Geral)" — dentro da própria Geral
  (`Shortcuts.swift:180`).
- Apagar Orb: "Some: a conversa." / "Fica: tudo…" lê como telegrama; "Vai embora: a conversa." / "Continua: …" ou
  frases completas.
- Templates de rotina cortados em "…" na 3ª linha justamente na parte que explica o que fazem; 4 linhas ou tooltip.


### Situação do P3 (14/10, depois da rodada de correções)

| Item | Situação | O que foi feito |
|------|----------|-----------------|
| "Sem chave" | Corrigido | "Não precisa de chave" na galeria e nos modelos de conector. |
| "Padrão (modelo)" | Corrigido | Sem a conta do modelo padrão ligada, mostra só "Padrão". |
| Atalho em Geral | Corrigido | Dentro de Geral: "(opcional, ligue na seção acima)"; a folha de atalhos mantém o texto original. |
| Apagar Orb | Corrigido | Frases completas: "A conversa e 2 rotinas vão embora." / "Tudo o que está no seu Mac continua lá e, se você quiser, a memória também." |
| Modelos de rotina | Corrigido | Até 5 linhas no cartão e o texto inteiro na dica. |

---

## O que está bom e deve ficar

- Hierarquia tipográfica das folhas (título 17 semibold + subtítulo 12 muted) é limpa e consistente.
- Estados vazios de Rotinas com modelos prontos: bom caminho para começar.
- Rodapés de folha com motivo do botão desabilitado ("Preencha a chave.", "Dê um nome ao Orb para criar.").
- Paleta de comandos com grupos, atalhos e rodapé de teclas: no nível de apps nativos bons.
- Pop-over de contexto: explica o custo da compactação antes de fazer.
