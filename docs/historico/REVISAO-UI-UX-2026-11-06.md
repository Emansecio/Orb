# Revisão de UI/UX do Orb — 06/11/2026

Auditoria só de leitura: nada no app ou no código foi alterado.

**Estado em 06/11:** as recomendações foram aplicadas em ondas nos commits que seguem este relatório.
- **Pendente:** o item 12 (a ordem de "Outros" muda os atalhos ⌘1…⌘9 e o Orb que abre ao iniciar o app) espera decisão.
- **Descartados por não se sustentarem no código:** os itens 13, 16 e 53.
- **Errado neste relatório:** o item 51. O modo escolhido no editor de rotina vale só para a rotina, não para o Orb.

**Como foi feita**
- 208 cenas renderizadas pelo próprio app (`--snapshot`), com dados de exemplo, cobrindo todas as telas que têm cena.
- O Orb aberto, navegado em segundo plano: lateral, Início, Rotinas, Conectores, Skills, as 5 abas do painel de um Orb trabalhando, as 6 abas de Ajustes e os menus.
- Cinco revisores em paralelo, um por área. Os achados mais fortes foram conferidos de novo nas imagens.
- Os números de linha são aproximados (achados por grep): confira antes de editar.

**Prioridade**
- **Alta:** atrapalha decidir, esconde risco ou parece defeito.
- **Média:** custa atenção ou quebra consistência.
- **Baixa:** acabamento.

---

## Parte 1 — Padrões que se repetem (corrigir uma vez vale para várias telas)

1. **[Alta] Ação destrutiva sem um padrão único.** Hoje convivem quatro formas:
   - "Remover…" em vermelho, fixo e repetido em cada provedor de Ajustes › Modelos e nos dois itens de Ajustes › Navegador;
   - "Apagar Gestor de Campanha AcessosFit…" em cinza, truncado, colado ao fim do painel do Orb;
   - "Apagar" escondido num "⋯" sem rótulo no cartão da rotina;
   - dois vermelhos disputando o mesmo rodapé no diálogo de apagar Orb.

   **Trocar:** uma regra só. A ação destrutiva fica no menu "⋯" da linha, ou num rodapé separado por divisor, com texto neutro ("Apagar este Orb…", sem o nome). O vermelho aparece só no botão de confirmação do diálogo.
   **Onde:** `ProviderSettings.swift:260`, `BrowserSettings.swift:105`, `BotInspector.swift:559-570`, `RoutinesView.swift:362-376`, `DeleteOrbDialog.swift:134-137`.
   **Por quê:** vermelho fixo ao lado de "Atualizar modelos" convida ao clique errado. Ação perigosa sem pista não é encontrada quando é preciso.

2. **[Alta] Truncamento que corta justamente a parte útil.** Exemplos no app real:
   - painel: a descrição do Orb, a permissão ("Sem pedir permiss…") e a lista de skills ("Resumir, Organizar pasta e Revisar t…");
   - caminho da pasta cortado duas vezes ("Gestor de Campan…cessosFit" / "…mpanha AcessosFit");
   - arquivos cortados no começo, perdendo a data ("…-05-D628EFC2-grande.png");
   - legenda do gráfico de Uso;
   - nome no rodapé da lateral ("Thiago Emanuel Vel…");
   - campo "O que faz" da proposta de skill.

   **Trocar:**
   - caminhos e arquivos: `.truncationMode(.middle)`, que mantém o começo e a extensão;
   - frases: `lineLimit(2)` com `.help` do texto inteiro;
   - listas: uma contagem ("3 skills · Gerenciar"), com a lista no tooltip;
   - nomes de pessoa: forma curta ("Thiago V.").

   **Onde:** `BotInspector.swift:262-273, ~533, ~555, ~659-664, ~938-943`, `UsageSettings.swift:249-253`, `SidebarView.swift:~465`, `SkillsView.swift:694`.
   **Por quê:** o texto truncado é a informação que identifica a coisa, e a reticência no lugar errado parece defeito.

3. **[Alta] "Carregando" parece "desabilitado".** "Usar meu Claude Code — Procurando o Claude Code neste Mac…" aparece esmaecido e com o chevron de navegação. Aparece no cartão do primeiro uso, em Ajustes › Modelos e no chat sem modelo.
   **Trocar:** `ProgressView().controlSize(.small)` no lugar do chevron enquanto procura. Só o texto secundário fica esmaecido. Se não achar, "Não encontrado · Como instalar".
   **Onde:** `FirstRunCard.swift:~626-720` e os cartões de "Conecte um modelo" em `ProviderSettings.swift`.
   **Por quê:** quem vê cinza acha que não pode usar e desiste da opção recomendada.

4. **[Alta] Laranja usado para coisas que não são aviso.**
   - Usos legítimos: "Sem pedir permissão", "Roda tudo sem perguntar", "Atrasada".
   - Usos errados: o selo e a estrela de "Orquestrador" no Novo grupo.
   - Sinais fracos demais: "Sem resposta" da delegação, que pede decisão, sai em cinza `faint`; numa janela estreita, o modo sem permissão vira só o ícone de raio.

   **Trocar:**
   - fixar a semântica: laranja = atenção/risco, acento azul = destaque neutro, cinza = informação;
   - "Orquestrador" passa para o acento;
   - "Sem resposta" passa para `Palette.warn`;
   - o chip do modo sem permissão mantém o texto mesmo compacto (e os outros chips perdem o texto antes dele).

   **Onde:** `NewGroupSheet.swift:91-105`, `OrbMessageRow.swift:169-172`, `ExchangeSheet.swift:158-161`, `ComposerChips.swift:60-62` (`showsName`).
   **Por quê:** se laranja também quer dizer "papel especial", o aviso real perde força.

5. **[Alta] Check (✓) em itens que ainda não aconteceram.** O cartão de acesso ao Mac e a folha "Conectar Google Agenda" ("O que acontece") listam passos futuros com `checkmark.circle`.
   **Trocar:** números (1, 2, 3) ou um ícone neutro (`circle`, `arrow.right.circle`). O ✓ fica reservado para o que está concluído.
   **Onde:** o cartão de acesso (procurar "precisa de acesso" em `Views/`) e o editor do Google em `CatalogParts.swift`/`ConnectorEditors`.
   **Por quê:** o ✓ diz "feito" e o usuário pula o passo.

6. **[Média] Folhas com altura fixa: vazio grande ou duas rolagens.**
   - "Conectar Google Agenda" e a prévia de skill: ~40% de vazio antes do rodapé.
   - Editor de skill e lista do Marketplace: uma rolagem dentro de outra.
   - "Conversa da rotina" vazia: ~730 pt de preto.

   **Trocar:** a altura da folha acompanha o conteúdo (`fixedSize(vertical:)` até um teto), com uma única rolagem por folha. O `TextEditor` cresce com o texto.
   **Onde:** `SheetKit.swift` (contêiner das folhas), `SkillsView.swift:~694-735`, `MarketplaceGallery.swift`, `RoutinesView.swift` (conversa da rotina).
   **Por quê:** o vazio faz a folha parecer incompleta, e rolagens aninhadas brigam com o trackpad.

7. **[Média] A mesma informação dita duas ou três vezes.**
   - "Início" no título da janela e como H1.
   - O plano no chip "Plano" do turno e no cartão "Plano", que repete o título.
   - "Conecte um modelo" no cartão, no botão e no chip "Sem modelo".
   - O nome do Orb no cabeçalho da seção e de novo em cada cartão de Rotinas.
   - O domínio no cartão "Ao vivo" e na linha de resumo logo abaixo.
   - O H1 "Documentos" dentro da prévia, igual ao título da folha.
   - O nome do Orb em quase toda linha da paleta de comandos.
   - Compactação marcada duas vezes (pílula "N mensagens anteriores foram resumidas" e divisor "Conversa compactada").

   **Trocar:** dizer uma vez, no lugar mais alto da hierarquia. Os itens 13, 22, 26, 37, 46 e 72 detalham cada caso.
   **Por quê:** cada repetição custa leitura e faz procurar uma diferença que não existe.

8. **[Média] Jargão técnico na interface.** Exemplos:
   - "agent-browser" e "Chrome for Testing 155.0.8059.39";
   - nomes de ferramenta em mono negrito (`get_me`, `list_issues`);
   - skills com nome de slug ("Publicar lp docker", chip "Melhoria de /publicar-lp-docker");
   - temas em minúsculas ("pdf", "seo");
   - "Memória (grafo)" e "Pensamento em etapas" apresentados como se fossem serviços externos.

   **Trocar:**
   - nomes de produto: "Controle do navegador", "Chrome do Orb";
   - versão e identificador em texto secundário pequeno;
   - nome de skill em frase com maiúscula inicial, e siglas em maiúscula ("PDF", "SEO").

   **Onde:** `BrowserSettings.swift`, `ConnectorsView.swift` (folha de ferramentas), `SkillsView.swift:182-205, :368`, `ConnectorGallery.swift:~43-51`.
   **Por quê:** o app fala com quem não programa; o termo técnico fica para o tooltip.

9. **[Média] Links e ações que não parecem clicáveis.**
   - Links em cinza, no tom do texto: "Gerenciar", "Instalar em Ajustes", "Ver mais" (no Início), "Personalizar…" (minúsculo).
   - "⋯" sem rótulo (Memória, Rotinas).
   - Campos sem borda, só com o placeholder à direita: Nome e "Como te chamar" em Ajustes, Nome no editor de rotina.

   **Trocar:**
   - um estilo de link único em `Palette.accentText` (já usado em "Mais opções em Ajustes" e "Obter chave");
   - "⋯" com `.help("Mais ações")` e área ≥ 24 pt;
   - campos com o fundo/borda de input do app.

   **Onde:** `BotInspector.swift:~480-560`, `InicioView.swift:177`, `MemoryViews.swift`, `ProfileSettings.swift`, editor em `RoutinesView.swift:~1021-1100`.
   **Por quê:** affordance. O que é ação tem que parecer ação.

10. **[Média] Listas longas sem estrutura nem ação em lote.**
    - Início › Novidades: 87 itens planos.
    - Skills: 9 revisões idênticas, cada uma com seu "Revisar".
    - "Acompanhamentos em aberto" de rotina: texto técnico, com um "Concluir" por item.
    - Uso › "Por Orb": três textos empilhados à direita.

    **Trocar:** agrupar (por dia, por Orb, por skill de origem), mostrar contagens e oferecer ação em lote quando a ação se repete. Os itens 17, 43, 55 e 70 detalham cada caso.
    **Por quê:** a lista vira tarefa; sem estrutura, a pessoa rola em vez de decidir.

---

## Parte 2 — Por área

### Lateral esquerda e navegação

11. **[Alta] Rotinas, Conectores e Skills ficam no meio da lista de conteúdo.** São destinos do app, como Início, mas ficam abaixo de Orbs e Grupos, sem separador e no mesmo peso dos nomes. Com muitos Orbs, rolam para fora da tela.
    **Trocar:** subir os três para junto de Início, como navegação principal. Orbs e Grupos ficam embaixo, como conteúdo. Se ficarem onde estão, pelo menos um `Divider` e peso `.medium`.
    **Onde:** `SidebarView.swift` (bloco depois de Grupos).
    **Por quê:** separa "para onde vou" de "com quem falo", e os destinos fixos não somem.

12. **[Média] A categoria "Outros" vem antes das categorias criadas pelo usuário** ("Outros" acima de "AcessosFit").
    **Trocar:** "Outros" depois da última categoria.
    **Onde:** `SidebarView.swift:50-80`.
    **Por quê:** o balde do resto vem por último; o usuário procura primeiro o que ele mesmo nomeou.

13. **[Média] Dois padrões de dobrar na mesma coluna.** "Orbs" tem o chevron à direita do texto; as categorias têm o chevron à esquerda.
    **Trocar:** o mesmo lado para todos.
    **Onde:** `SidebarView.swift:290-340` (`SidebarFoldHeader`), `SidebarCategoryViews.swift`.
    **Por quê:** consistência de affordance.

14. **[Média] "Grupos" vazio é um título com "+" e ~60 pt de nada.**
    **Trocar:** uma linha em `Palette.faint`, "Junte Orbs para trabalharem juntos", no mesmo padrão de "Arraste um Orb para cá". Ou esconder a seção com menos de 2 Orbs.
    **Onde:** `SidebarView.swift` (seção Grupos), `SidebarCategoryViews.swift:43`.
    **Por quê:** estado vazio explica e convida.

15. **[Média] "Não lido" e "trabalhando" diferem só pelo preenchimento do ponto.**
    **Trocar:** não lido = ponto cheio de 8 pt com `accessibilityLabel("Não lido")`; trabalhando = indicador animado ou o texto de estado na cor de acento. Os dois "+" (Novo Orb, Novo grupo) ganham `.help` distintos.
    **Onde:** `SidebarView.swift:801, 202, 285, 336`.
    **Por quê:** estados diferentes, formas diferentes.

16. **[Baixa] O chevron que aparece no hover de uma linha de Orb não fez nada visível** num Orb com uma conversa só (visto ao vivo no Atendente).
    **Trocar:** mostrar o chevron só quando há mais de uma conversa para expandir.
    **Onde:** `SidebarChatList.swift`.
    **Por quê:** affordance que não responde ensina a não confiar.

### Início

17. **[Alta] "Novidades" é um feed plano.** No app real são 87 itens, cada um com até 3 linhas, todos com o mesmo peso.
    **Trocar:**
    - agrupar por dia ("Hoje", "Ontem", "Esta semana");
    - filtro por Orb no cabeçalho;
    - título com `lineLimit(2)` e detalhe com 1 linha;
    - "Ver mais 9 itens" com contagem, como link.

    **Onde:** `InicioView.swift:167, 177, 252-253`.
    **Por quê:** permite varrer e parar no que importa.

18. **[Alta] O que pede você tem o mesmo peso que o histórico.** "Em andamento" e "Precisa de você" usam o mesmo cartão das Novidades.
    **Trocar:**
    - "Precisa de você" com borda de 1 pt em `Palette.warn` e contagem em pílula;
    - "Em andamento" recolhido numa linha quando não há decisão;
    - Novidades sem borda, só com separadores.

    **Onde:** `InicioView.swift:~90-110`.
    **Por quê:** o olhar cai primeiro no que bloqueia um Orb.

19. **[Média] Título duplicado e linhas longas demais.** "Início" aparece na barra e no H1. Numa janela larga, "Ontem ›" fica a ~1000 px do texto.
    **Trocar:**
    - um título só (sugestão: manter o H1 e esvaziar a barra);
    - coluna com `maxWidth` ~860 pt;
    - a hora junto do texto, em `Palette.muted`, não `faint`.

    **Onde:** `InicioView.swift:50, 90, 255`; `Theme.swift:42`.
    **Por quê:** recupera ~70 pt no topo, e a linha curta lê melhor.

20. **[Baixa] As linhas de acompanhamento juntam três fatos com "·"** ("E-mail · Verificar resposta… · Sem verificação registrada").
    **Trocar:** o canal como pílula à esquerda, o detalhe como texto e o estado em outra linha.
    **Onde:** `InicioView.swift:190-215`.

### Conversa (transcrição)

21. **[Alta] Um turno longo empilha camadas demais.** Na ordem:
    1. pílula de mensagens resumidas;
    2. cartão do turno, com título truncado, chip "Plano" e duração;
    3. "Trabalhou · N ações";
    4. divisor "Conversa compactada" dentro do cartão;
    5. cartão "Ao vivo";
    6. "Executando ações";
    7. cartão "Plano" separado, que repete o título.

    **Trocar:**
    - o plano fica num lugar só (o cartão, sem repetir o título do turno, sem o chip quando o cartão está visível), com a mesma largura do cartão do turno;
    - o divisor de compactação nunca entra dentro de um turno: fecha o cartão e abre outro depois do divisor.

    **Onde:** `ChatView.swift:451`, `TurnTrailView.swift:60-97`, `TaskPlanRing.swift:65-67, 127`, `TranscriptViews.swift:1536-1545`.
    **Por quê:** a mesma informação com dois pesos e duas larguras parece erro.

22. **[Média] A compactação tem duas representações** (a pílula no topo, com link azul, e o divisor com `info.circle`).
    **Trocar:** um componente só, no ponto da compactação: "Conversa compactada · N mensagens resumidas · Ver resumo".
    **Onde:** `ChatView.swift:190-240`, `TranscriptViews.swift:1536-1545`.
    **Por quê:** um conceito, uma forma.

23. **[Alta] A voz do sistema se mistura à do agente.** O aviso de cache ("O provedor não está reaproveitando o início…") e o "Pausei depois de 100 passos" aparecem no peso do texto da resposta, colados nela.
    **Trocar:** uma linha de aviso com ícone (`exclamationmark.circle` / `pause.circle`) em `Typography.small` e 12 a 16 pt de espaço acima. Texto mais curto: "Cache do provedor desligado: cada passo custa mais. Ver Ajustes › Modelos".
    **Onde:** `TranscriptViews.swift:1515-1580`.
    **Por quê:** quem fala tem que ser óbvio.

24. **[Alta] A árvore de ações repete texto.**
    - O título do passo é igual à primeira frase aberta.
    - Cinco linhas "Rodou" repetem o mesmo caminho truncado.
    - "Falhou" se perde no meio.

    **Trocar:**
    - esconder a frase quando ela é igual ao título;
    - no resumo, só script e argumento (caminho no tooltip);
    - linha de falha tingida com `danger` a 8%;
    - agrupar a repetição ("Falhou, depois funcionou").

    **Onde:** `TranscriptViews.swift:927-957, 1297-1331`.
    **Por quê:** em turnos longos, o erro precisa saltar.

25. **[Média] Os cartões de aprovação têm alvos assimétricos.** "Não permitir" é texto solto ao lado de um botão cheio, e o cartão destrutivo só se distingue por um triângulo.
    **Trocar:**
    - "Não permitir" com contorno de 1 pt (vira botão);
    - borda do cartão destrutivo em `danger` a 35%;
    - `.help` no chevron do "Permitir as 3".

    **Onde:** `TranscriptViews.swift:1895-1990, 2055-2075`; `PermissionConfirmation.swift`.
    **Por quê:** a decisão mais arriscada do app precisa de dois botões claros.

26. **[Média] O cartão "Ao vivo" deixa "Parar Orb" com o mesmo peso de Ampliar e Ocultar.** O status "Conectando…" não tem indicador de atividade.
    **Trocar:**
    - "Parar Orb" com ícone de stop e texto em `danger`, separado à direita;
    - um ponto pulsante ao lado do status;
    - tirar o domínio repetido da linha de resumo.

    **Onde:** `TranscriptViews.swift` (procurar "Ocultar tela"), `LiveScreen/LiveScreenViews.swift:170-185`.

27. **[Média] Nas perguntas, as opções parecem campos de texto** (a mesma borda do campo "Outra resposta…") e nada indica que um clique já responde.
    **Trocar:** numerar as opções (1, 2, 3, com atalho) com fundo `Palette.raised` sem borda; a borda fica só no campo.
    **Onde:** `QuestionCard.swift:116, 181-191, 266`.

28. **[Média] No erro de autenticação (401), "Tentar de novo" é oferecido mesmo sabendo que vai falhar**, e o texto repete o botão.
    **Trocar:** esconder "Tentar de novo" em erros de chave ou login; texto "A chave ou o login foi recusado (401)."
    **Onde:** `TranscriptViews.swift:1565-1580` e o mapeamento de erros do provedor.

29. **[Baixa] O trilho de marcas à direita (pular entre pedidos) é quase invisível** (traços em `Palette.hint`) e parece artefato da barra de rolagem.
    **Trocar:** traço 14×2 em `Palette.muted`, o pedido atual em `ink`, tooltip imediato.
    **Onde:** `TurnTrailView.swift:36-54`.

30. **[Baixa] O spinner do passo em curso é um asterisco cinza de 10 pt.**
    **Trocar:** 12 pt em `ink` ou `accentText`, e o chevron alinhado à borda do cartão.
    **Onde:** `TranscriptViews.swift:1297-1331`.

31. **[Baixa] No relatório de rotina, "Precisa de você" ainda tem o mesmo peso das outras seções.**
    **Trocar:** uma barra de 3 pt em `Palette.warn` à esquerda da seção, ou uma pílula de contagem.
    **Onde:** `MarkdownBlockViews.swift` (títulos).
    **A conferir:** a resposta visível do Atendente às 23:30 ainda saiu no formato antigo, provavelmente de uma rodada anterior ao bundle novo. Veja a das 08:00.

### Composer

32. **[Alta] Parar e enviar são o mesmo círculo branco.** Muda só o glifo.
    **Trocar:** manter o círculo, com um anel sutil de acento enquanto o Orb trabalha e `.help("Parar ⌘.")`. Encurtar o placeholder para "Oriente o Orb enquanto ele trabalha" (o atual corta em janela estreita).
    **Onde:** `ComposerView.swift:262, 350-365`.
    **Por quê:** a ação que interrompe tem que ser distinguível da que envia.

33. **[Média] O menu "/" abre dentro do composer, num cartão dentro do cartão**, e a seleção quase não contrasta.
    **Trocar:** um popover acima do composer, com a mesma largura; seleção com `Palette.raised` e um marcador de 2 pt de acento; descrição em `small`/`muted`.
    **Onde:** `ComposerView.swift` (`slashSuggestions`).

34. **[Média] O banner "Conecte um modelo" ocupa ~190 pt mesmo com a conversa em andamento** (e ~320 pt em janela estreita).
    **Trocar:** com a conversa iniciada, uma linha de ~44 pt ("Sem modelo conectado · Conectar…"); o cartão grande só no chat vazio.
    **Onde:** `FirstRunCard.swift:755-823`.
    **Por quê:** é a terceira vez que a tela diz a mesma coisa (item 7).

35. **[Baixa] Anexos: o "x" de remover tem 14 pt e some sobre miniaturas escuras.** O erro não diz qual arquivo falhou.
    **Trocar:** "x" de 18 pt em círculo com fundo; borda `danger` na miniatura que falhou; mensagem "Não foi possível ler foto.png".
    **Onde:** `ComposerView.swift` (`attachmentStrip`).

36. **[Baixa] No ditado, a dica "Ouvindo… ↩ envia · Esc encerra" fica fora do cartão** e o microfone vermelho cheio disputa com o enviar.
    **Trocar:** a dica dentro do composer; o microfone com anel vermelho, não cheio.
    **Onde:** `DictationButton.swift:57`.

### Painel do Orb (direita)

37. **[Alta] O painel some ao ir para Início e voltar ao Orb** (visto ao vivo), e só volta pelo menu Visualizar.
    **Trocar:** restaurar a visibilidade ao voltar para o Orb (guardar o estado global ou por Orb).
    **Onde:** `BotInspector.swift:~142-216` e o ponto onde a seleção Início/Orb mexe em `showInspector`.
    **Por quê:** o usuário perde o contexto a cada navegação.

38. **[Alta] O risco do modo "Sem pedir permissão" fica escondido dentro de "Modelo e permissões"** recolhido, que mostra só "Padrão".
    **Trocar:** quando o modo é arriscado, o cabeçalho recolhido mostra um chip laranja curto ("Sem pedir"); dentro, o valor quebra linha em vez de truncar.
    **Onde:** `BotInspector.swift:340-356`.
    **Por quê:** a configuração mais perigosa é a que mais precisa aparecer.

39. **[Média] A aba Tela é só a miniatura, uma frase e ~60% de vazio**, sem "Parar Orb" nem "Ampliar".
    **Trocar:** as mesmas ações do cartão "Ao vivo" sob a miniatura, status com ponto colorido e, sem navegação, um estado vazio que diz como começar.
    **Onde:** `LiveScreen/LiveScreenViews.swift:170-185, 330`.

40. **[Média] O cabeçalho do painel gasta uma linha inteira com "Personalizar…" minúsculo** e trunca a descrição em 1 linha.
    **Trocar:** descrição com `lineLimit(2)` e "Personalizar" como ícone no canto do cabeçalho, com `.help`.
    **Onde:** `BotInspector.swift:262-273`.

41. **[Média] Na aba ativa do painel, o fundo cinza tem ~1,2:1 de contraste** sobre o fundo.
    **Trocar:** um indicador de 2 pt de acento sob a aba ativa (ou um fundo mais claro); as inativas em `Palette.secondary`.
    **Onde:** `BotInspector.swift:~280-330`.

42. **[Média] Pasta: duas regras de permissão em texto corrido, uma no cartão e outra no rodapé de Liberações**, e "Mudar…" numa linha separada dos botões do Finder e do Terminal.
    **Trocar:** os três botões na mesma linha; cada regra numa linha curta com ⓘ; o rodapé de Liberações absorvido pelo estado vazio.
    **Onde:** `BotInspector.swift` (aba Pasta).

43. **[Média] Rotinas (aba): 4 linhas de status com ícones diferentes, e "Atrasada" na mesma cor de "Próxima".**
    **Trocar:** estados anormais em `Palette.warn`; cadência e próxima execução numa linha só ("Todo dia às 08:30 · próxima amanhã"); "Editar" como texto e "Rodar agora" como pílula, igual à página.
    **Onde:** `BotInspector.swift:~1100-1170, 1229-1249`.

44. **[Baixa] Memória: itens que são frases cortados em 1 linha**, e o "⋯" sem rótulo.
    **Trocar:** `lineLimit(2)` com `.help`; a contagem ("2 lembranças · 49 resumos") logo sob o título; "Abrir pasta" como link.
    **Onde:** `MemoryViews.swift`.

### Rotinas (página)

45. **[Alta] Com uma rotina por Orb, a página vira uma coluna de ~340 pt centrada num canvas largo** (ao vivo). Na grade, os cartões ficam com alturas iguais e vazio no meio.
    **Trocar:** sem `maxHeight: .infinity` no corpo do cartão; a grade com `adaptive(minimum: 340, maximum: 460)` dentro de uma coluna de ~1100 pt; com um cartão por seção, uma lista de linhas mais largas.
    **Onde:** `RoutinesView.swift:56, 234`.

46. **[Alta] O nome do Orb aparece duas vezes por cartão** (título da seção e cabeçalho do cartão, com avatar).
    **Trocar:** sob o título da seção, o cartão começa pelo nome da rotina, com o toggle à direita.
    **Onde:** `RoutinesView.swift:46-54, ~290-300`.
    **Por quê:** ~50 pt a menos por cartão, e sem ruído.

47. **[Alta] "Acompanhamentos em aberto" tem o peso do título**, com texto técnico de até 3 linhas e um "Concluir" sem cara de botão por item.
    **Trocar:**
    - título da seção em `label`/`secondary`;
    - "Concluir" com `checkmark.circle` e um `accessibilityLabel` que diz o item;
    - no máximo 3 itens com "Ver todos (N)";
    - `lineLimit(2)`.

    **Onde:** `RoutinesView.swift:329, 340-345, 355`.

48. **[Média] "Desde a execução anterior: 0 novos · 0 concluídos · 3 em aberto" aparece mesmo zerado.**
    **Trocar:** esconder quando não há novos nem concluídos; omitir os termos com zero.
    **Onde:** `RoutinesView.swift:546`.

49. **[Média] O resumo da última execução corta sem "Ver mais" na página** (no painel existe), e a seta não parece clicável.
    **Trocar:** o mesmo componente do painel.
    **Onde:** `RoutinesView.swift:542, 567-590`.

50. **[Média] No relatório da execução, "Fechar" é a pílula branca** e o texto do relatório é cinza.
    **Trocar:** o texto do relatório em `ink`, com espaço entre parágrafos; "Ver conversa" como ação principal quando existir; "Fechar" discreto (Esc).
    **Onde:** `RoutinesView.swift:~640-710`.

51. **[Média] Editor de rotina:**
    - "O que fazer", o coração da rotina, fica abaixo de "Quando";
    - o cron não mostra se é válido;
    - o aviso laranja de permissão muda o Orb inteiro sem dizer isso.

    **Trocar:**
    - ordem: Nome/Orb → O que fazer → Quando;
    - "válida ✓" ou uma mensagem ao lado da expressão;
    - botões "Rodar no modo Automático" / "Só leitura" com a frase "Isso muda o Orb, não só esta rotina".

    **Onde:** `RoutinesView.swift:~1021-1100`.

52. **[Baixa] O estado vazio de Rotinas corta frases dos modelos no meio** (`lineLimit(5)`).
    **Trocar:** descrição de ~90 caracteres e "com meta" como selo.
    **Onde:** `RoutinesView.swift:172-196, 231`.

### Criação de Orb, proposta e multi-Orbs

53. **[Alta] Assistente de criação (folha estreita): o cartão "Tudo pronto: Maia" cobre "Como funciona"**, e o texto fica pela metade atrás dele (conferido na imagem).
    **Trocar:** o cartão entra na pilha normal, ou o painel rolável recebe um respiro inferior igual à altura do cartão.
    **Onde:** `Multi/WizardPreviewPane.swift:330-361`.
    **Por quê:** conteúdo sobreposto parece defeito.

54. **[Alta] O erro do assistente ("Não deu certo") fica cortado no pé da conversa.** O placeholder manda "Clique em Tentar de novo", mas o botão não aparece na captura.
    **Trocar:** fixar o aviso de falha acima do campo de resposta, fora da rolagem, ou rolar até ele.
    **Onde:** `Multi/WizardChatView.swift:123, 215-245`.
    **A conferir:** confirmar no app, porque a captura não rola sozinha.

55. **[Média] Importar aparece de duas formas** (link azul longo, "Importar um bot do Grok Bot ou de outro assistente", e uma linha com borda no Formulário).
    **Trocar:** o mesmo componente nas duas abas, com o título "Importar de outro assistente" ("Grok Bot" só na legenda). Na folha de importação, o título neutro "Importar um Orb" e uma rolagem só.
    **Onde:** `ImportPanel.swift:11-14`, `SheetsAndSettings.swift`, `MarketplaceGallery.swift`.

56. **[Média] A prévia lista as capacidades sem distinguir o que está ligado.**
    **Trocar:** as ativas com ícone cheio e as desligadas esmaecidas, ou "Pode:" / "Pergunta antes:".
    **Onde:** `Multi/WizardPreviewPane.swift`.

57. **[Média] O cartão de proposta de Orb tem o título fraco** ("Atlas quer criar um Orb" no peso do texto secundário), e os atalhos dentro dos botões (⌘↩, esc) quase não se leem.
    **Trocar:** o título em semibold; atalhos a ~60% de opacidade; em largura estreita, as capacidades como texto corrido ("Terminal · Web · Pergunta antes").
    **Onde:** `Multi/OrbProposalCard.swift:244-293, ~526`.

58. **[Média] A aparência no assistente e no editor de Orb usa disposições diferentes para os mesmos controles** (Sortear, Desfazer, estados). "Pular" não diz o que faz, e duas cores não têm nome.
    **Trocar:** o mesmo componente nas duas telas; "Pular" vira "Dar um pulo" com `.help`; todas as cores com nome.
    **Onde:** `Orbs/OrbEditor.swift:258` e o catálogo de cores do editor.

59. **[Média] Delegação: "Aguardando" e "Sem resposta" têm o peso dos itens concluídos** (ver item 4). A linha "2 mensagens com Pesquisador" não segue o formato das linhas de eventos.
    **Trocar:** "Sem resposta" em `warn`; "Aguardando" com um indicador discreto; o formato "Atlas pediu ajuda ao Pesquisador ›" igual ao de `events`.
    **Onde:** `Multi/OrbMessageRow.swift`, `Multi/ExchangeSheet.swift`.

60. **[Baixa] Eventos: ícones de larguras diferentes desalinham a coluna de texto.**
    **Trocar:** `frame(width: 20)` no ícone.
    **Onde:** `Multi/` (linha de evento).

### Grupos

61. **[Média] Painel do grupo:**
    - estrelas vazias sem rótulo em todos os membros;
    - o ícone de remover quase invisível;
    - "Adicionar Orb" como texto pequeno, fora do ritmo da lista.

    **Trocar:** o selo "Orquestrador" só no membro ativo, com as estrelas no hover; remover em `secondary`, vermelho no hover; "Adicionar Orb" como uma linha de 44 pt com avatar tracejado.
    **Onde:** `Groups/GroupPanel.swift:86, 170-195`.

62. **[Média] Quadro do grupo: os títulos "Objetivo" e "Combinados" têm o peso do texto auxiliar.** O "↩ salva" só existe no placeholder, que some ao digitar.
    **Trocar:** cabeçalhos em `label` semibold e um botão "Adicionar" visível quando há texto.
    **Onde:** `Groups/GroupBoardView.swift:55`.

63. **[Baixa] O grupo vazio não avisa quando falta modelo** (o chat individual avisa), e o título "Fale com o grupo." tem ponto final, diferente dos outros títulos.
    **Onde:** `Groups/GroupComposer.swift:50`.

### Skills

64. **[Alta] A revisão de melhoria substitui as instruções sem mostrar o que muda.**
    **Trocar:** um alternador "Nova / Atual / Mudanças", com diff simples. "Fechar" vira "Decidir depois" e "Descartar" vira "Descartar proposta".
    **Onde:** `SkillsView.swift:~700-735`.
    **Por quê:** aprovar uma substituição às cegas é arriscado.

65. **[Alta] "Aguardando sua revisão (9)": nove cartões idênticos** (mesmo ícone, nome de slug, um "Revisar" cada).
    **Trocar:** o nome formatado; o ícone com a inicial ou o avatar do Orb de origem; agrupar por skill de origem; "Revisar uma a uma" no cabeçalho.
    **Onde:** `SkillsView.swift:182-205`.

66. **[Média] Instaladas: selos repetidos em todas as linhas** ("Incluída no app") e três controles de pesos diferentes à direita. Em janela estreita, a linha dobra de altura.
    **Trocar:** selo só quando foge do padrão; "Usar" no hover; o toggle e o "⋯" na primeira linha.
    **Onde:** `SkillsView.swift:298`, `CatalogParts.swift` (`InstalledSkillRow`).

67. **[Baixa] A prévia de skill repete o título da folha como H1** e deixa ~40% de vazio (item 6).
    **Onde:** `SkillsView.swift` (prévia).

### Conectores

68. **[Alta] "Pensamento em etapas" e "Memória (grafo)" aparecem como serviços, com "Conectar".**
    **Trocar:** uma seção própria, "Recursos do Orb", com toggle.
    **Onde:** `Catalog/ConnectorGallery.swift:~43-51`, `ConnectorGalleryView.swift:199`.
    **Por quê:** "Conectar" promete uma conta que não existe.

69. **[Média] Os cartões da galeria têm altura fixa, com vazio entre a descrição e o rodapé.** A descrição repete o selo ("Você entra com a sua conta" + "Login com a conta"), e "Conectar" é pequeno.
    **Trocar:** tirar a frase repetida, reduzir a altura mínima e dar ao botão ≥ 28 pt de altura.
    **Onde:** `ConnectorGalleryView.swift:199-204`.

70. **[Média] Ferramentas do conector: só dois níveis de risco** ("Só leitura" / "Destrutiva"). O que escreve sem destruir (`create_issue`, `merge_pull_request`) fica sem selo.
    **Trocar:** um selo "Altera dados"; o nome em texto normal, com o identificador técnico em cinza pequeno.
    **Onde:** `ConnectorsView.swift` (folha de ferramentas).

71. **[Média] Editor de instalação (GitHub): dois avisos quase iguais no rodapé**, o campo de chave sem placeholder e "Onde conseguir a chave" longe do campo.
    **Trocar:** uma frase só; "Cole o token aqui"; o link na linha do campo, como "Obter chave" em Ajustes › Navegador.
    **Onde:** os editores de conector (`ConnectorEditors*`, `SheetFooter`).

### Ajustes

72. **[Alta] Modelos: "Gateway próprio" diz "Desativado" e mostra todos os campos.**
    **Trocar:** desativado, só o toggle "Usar este provedor"; os campos aparecem ao ligar.
    **Onde:** `ProviderSettings.swift:214-215`.
    **Por quê:** estado e conteúdo se contradizem.

73. **[Média] Uso: dois controles segmentados em estilos diferentes, o título "Por Orb" repetido**, "e uso sem preço" em laranja em cada linha e um aviso que pede ação sem link.
    **Trocar:**
    - "Por Orb / Por modelo" ao lado de "Gasto por dia";
    - a lista de baixo como "Detalhes por Orb";
    - um ícone de aviso com `.help` no lugar do texto laranja;
    - o aviso vira o botão "Definir preços";
    - legenda com mínimo de ~160 pt;
    - eixo X curto ("31/10").

    **Onde:** `UsageSettings.swift:~100-116, 106, 207, 216, 249-253, 338-395`.

74. **[Média] A janela de Ajustes tem altura fixa por aba:** vazio em Modelos e Acesso ao Mac, corte em Geral ("Seus dados").
    **Trocar:** a altura acompanha o conteúdo até um teto.
    **Onde:** `SettingsView.swift:94, 478, 493`.

75. **[Média] Acesso ao Mac: o status e "Testar" não estão em colunas fixas.** O aviso "só vale depois de reabrir o Orb" fica solto abaixo do cartão.
    **Trocar:** uma coluna de status alinhada e a ação sempre na mesma coluna; o aviso dentro da linha de Gravação, com o botão "Reabrir o Orb".
    **Onde:** `MacPermissionsView.swift:478-482, 597`.

76. **[Baixa] Ajustes › Orbs: descrições de 2 linhas nos três níveis de contexto**, e o radio desalinhado da primeira linha.
    **Trocar:** uma linha cada, com `.firstTextBaseline`.
    **Onde:** `ContextSettings.swift`.

77. **[Baixa] Geral: "Memórias guardadas · Mostrar no Finder" desabilitado quando não há memórias.**
    **Trocar:** esconder a linha.
    **Onde:** `SettingsView.swift` (Seus dados).

78. **[Baixa] "A chave da busca na web fica na aba Navegador" é texto solto.**
    **Trocar:** um link que troca de aba.
    **Onde:** `ProviderSettings.swift` (rodapé), `SettingsView.swift`.

### Menus, paleta e Quick Ask

79. **[Média] O menu "Orbs" mistura comandos da conversa, a lista de Orbs e "Recarregar ajustes do disco"**, que é um comando de manutenção (visto ao vivo).
    **Trocar:**
    - "Orbs" fica só com Ir para, Novo Orb e Novo grupo;
    - as ações da conversa vão para um menu "Conversa";
    - "Recarregar ajustes do disco" vai para Ajuda ou para um modo de desenvolvedor.

    **Onde:** `OrbApp.swift:214-240`, `Shortcuts.swift:34`.

80. **[Média] A paleta de comandos corta a lista sem degradê** e repete o nome do Orb em quase toda linha.
    **Trocar:** um degradê de 16 pt na borda inferior; uma seção "Ações de Atlas", com subtítulos só quando acrescentam algo; atalhos em `muted`.
    **Onde:** `CommandPalette.swift:97, 257, 381-406`.

81. **[Baixa] Quick Ask com várias aprovações repete "Atlas precisa de você" em cada cartão**, e a ação arriscada não se destaca.
    **Trocar:** um cabeçalho por Orb, e borda laranja no cartão arriscado.
    **Onde:** `QuickAskView.swift`.

### Boas-vindas e primeiro uso

82. **[Média] Boas-vindas: quatro camadas antes da ação.** O cartão "Primeiro, conecte um modelo" fica no fim, sem um primário claro.
    **Trocar:** os três pilares numa linha; "Usar meu Claude Code" como primário (já tem o selo "Recomendado") e as outras opções como secundárias; os caminhos alternativos ("Começar com o Atlas", "Importar") como links.
    **Onde:** `WelcomeView.swift:224-297, ~479-590`.

83. **[Baixa] Ícone da barra de menus:** o ponto de aviso invade o círculo com recorte irregular, e "trabalhando" difere de "ocioso" só pelo preenchimento.
    **Trocar:** um vão uniforme de 1,5 px em volta do ponto e uma marca própria para "trabalhando".
    **Onde:** o desenho do ícone de status (procurar `NSStatusItem`).

---

## Parte 3 — O que está bom e deve ficar

- A lateral é limpa: Início no topo, avatares acetinados consistentes, área de clique generosa.
- A estrutura do chat: avatar no gutter, a coluna de leitura e o composer agora alinhados, o botão único de enviar/parar.
- Os cartões de aprovação têm atalhos explícitos (esc, ⌘↩), e o destrutivo diz "não pode ser desfeita".
- Os selos de conectores ("Pelo Mac", "Login com a conta", "Chave de acesso") ensinam como cada serviço entra.
- Acesso ao Mac: o resumo "Tudo pronto" com "Verificar de novo" no topo e a divisão Essenciais / Avançado.
- Uso: o total grande e o gráfico empilhado com as cores consistentes entre Orbs.
- A criação em "Quem ele é / Aparência", com a prévia ao vivo, e o diálogo de apagar que oferece guardar a memória.

## Parte 4 — Cobertura e descartes

- **Vistas por amostragem, não uma a uma:** parte das variantes de Ajustes (perfil, redefinir, permissões testadas), os editores de conector além do GitHub e do Google, `skill-editor-new`, `connectors-lazy`, `rich-sheet-*`, `side-question` e `memory-sheet`.
- **Descartados por não se sustentarem:**
  - o corte da janela em 460 pt com a lateral aberta: o app tem largura mínima de 1000 pt;
  - os toggles cinza nas capturas: é o macOS tirando o acento de janelas fora de foco;
  - o deslocamento de ~7 pt da coluna central: é a barra de rolagem fixa das capturas.
- **A conferir no app:** o item 54 (erro do assistente cortado) e o item 31 (formato do relatório na próxima rodada do Atendente).
