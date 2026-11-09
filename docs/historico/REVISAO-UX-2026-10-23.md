# Revisão de UI/UX: componentes e coexistência (23/10/2026)

Levantamento de leitura sobre `72c9bcf`, com parecer item a item em 24/10 e implementação no mesmo dia. Este arquivo
guarda só o resultado. A versão completa, com cada achado, o parecer e o "como", está em
`git show 6a33911:docs/REVISAO-UX-2026-10-23.md`.

## O que foi feito

| Área | Commits | O que mudou |
|---|---|---|
| Segurança de decisão | `97c510b` | ⌘↩ no compositor não responde mais a um pedido aberto. Apagar Orb nomeia os grupos desfeitos e os botões dizem o que acontece com a memória. O objetivo do grupo grava ao sair do campo. "Conectar assim mesmo" saiu do vermelho. |
| Pedidos no grupo | `c5adf3d`, `9743e51` | Barra com os cartões de permissão e pergunta dos membros, acima da presença, na largura da conversa. |
| Lateral e paleta | `90f0e7f`, `1fd481d`, `518a88a`, `42ba264` | Rodapé "Espaço de trabalho" com rótulos. Badge de não lidas a partir de 2. Reordenar categoria. Paleta com Ajustes, grupos e conversas (só na busca). ⌘/ abre os atalhos. QuickAsk com botão de enviar e "Abrir Ajustes" na aba Modelos. |
| Painel do Orb | `afdec17`, `c35a359`, `d4cbf93` | Aviso de nome repetido. Renomear pela lateral. "Desfazer mudanças" na aparência. Skills e conectores listados. "Modelo e permissões". "Apagar Orb…" mais visível. |
| Grupo | `5d43694`, `f9925a8`, `cfa678f`, `7d26b2e`, `9743e51` | Compositor com Esc, Tab, foco inicial e anexos (a imagem chega ao modelo). Menções com avatar e papel. Diálogo único de apagar grupo. Renomear grupo. "Copiar" na mensagem. Estado da troca na linha de pedido. `ExchangeSheet` com a bolha do grupo. "Parar grupo" sem quebrar em janela estreita. |
| Chat e compositor | `b1e7537`, `d7137be`, `aa71790`, `1729c3f`, `3a1c627` | "Refazer" no menu de contexto e no VoiceOver. Medidor e dicas falados. Erro do compositor dispensável, com atalho para o microfone. Menu "enviar agora / depois" no botão. Chip de permissão com nome. Fila de tarefas com "+N". Botões da tela ao vivo com verbo. Linha "Plano concluído" com as etapas. |
| Ajustes e vocabulário | `e15c575`, `d974bdc` | Aba "Orbs" separada de Geral. Atalhos recolhidos. "Acesso ao Mac", "Local dos dados", "Sair da conta", "Permissões", "Desativado", "clique", "Sortear", "Personalizar". |
| Wizard | `8ef5880`, `b9b3fa2` | Confirma antes de descartar a conversa. Ao bater o limite, oferece ir ao formulário. |
| Skills | `99c57d0`, `9743e51` | Seção "Aguardando sua revisão". Selo "Desativada". Linha abre o editor. Filtro nas instaladas. "+" em menu. Comando sem quebrar letra a letra. |
| Rotinas e Conectores | `c75a11d`, `07db17d`, `9743e51` | Cron em palavras. Fuso inválido junto ao campo. Orb do cartão abre o Orb. Selo "Falhou". "…" com Apagar. Agrupamento por Orb (só com 2 Orbs ou mais). "Testar" visível. Galeria leva a Instalados. |
| Tokens | `f29017d`, `14cd52c`, `4419fa2`, `a4951ee` | `Radius`, `Typography.small/label/text`, `Palette.chipFill`, `Shadow.popover`, `Palette.canvasHex` e a regra das ações secundárias em `Theme.swift`. |

**Conferência (24/10).**
- Debug e release compilam.
- A suíte completa passou, com 4.848 testes e os de navegador real pulados.
- As 23 telas tocadas foram capturadas com `--snapshot` em 460 e 1100 pt. As correções que as capturas pediram estão em `9743e51`.
- No CI, só `MemorySafetyTests.aLogTakesOneRelatedPlaceWithItsNewestMatch` falha. A falha é anterior a esta rodada e não tem relação com ela.

## O que ficou de fora

**Recusado, com o motivo:**
- **Confirmar Editar/Refazer, anel do plano, "Pulada", folha de 820 pt, ⌥⌘G com menos de 2 Orbs, "Desligado com dois sentidos":** a sugestão partia de um fato errado ou já resolvido.
- **Ações da lateral só no hover:** já existem pelo VoiceOver, pelo menu de contexto e por ⇧⌘N.
- **Ajustes com altura variável:** o tamanho único é decisão documentada.
- **"Abrir no assistente" no cartão de proposta:** é esforço G. O `orb_propose` espera no gate, e o formulário perderia `createdBy`.
- **Botão "Criar" do cartão com `PrimaryPillStyle`:** perderia o estado "pressionado" do ⌘↩.
- **Trocar o prefixo "Não deu certo":** é persistido e lido com `hasPrefix`.
- **"Instruções" e "Ir ao catálogo":** colidem com termos que já têm dono.
- **Layout único para Skills, Rotinas e Conectores:** skills são texto longo e ficam em lista.
- **"Modelo" de skill:** as skills incluídas no app já cumprem esse papel.
- **Margem 90 × 40 do grupo:** os 90 pt reservam a coluna de botões de hover do chat individual.
- **Esc duplo na edição:** é raro, está documentado e fixado em teste.
- **Duas entradas de "Novo Orb":** fazem o mesmo, e a diferença de texto é intencional.

**Adiado:**
- **QuickAsk com grupos:** exige um destino de envio novo em `QuickAskSend` (G).
- **Largura mínima do painel:** não foi mexida.
- **Menu "⋯" no cabeçalho do painel do Orb:** disputaria o foco com o campo do nome.
- **Pré-preencher o nome no Novo Orb a partir da paleta:** precisa de um campo temporário no `AppModel`. Por ora, há um botão "Novo Orb" sob "Nada encontrado".
- **Busca no texto das conversas na paleta:** hoje é só pelo título.
- **Fonte que escala com o sistema:** é G.
- **Auditoria dos 16 `.link`:** conferir contra a regra das ações secundárias em `Theme.swift`.
- **Imagens repassadas de um Orb para outro no grupo:** falta um campo no `OrbEnvelope`.
- **Pesos, `design` e raios fora de 8–14:** seguem como literais.

## O que não foi verificado

- **VoiceOver:** os rótulos e ações novos foram testados por código, mas não foram ouvidos.
- **Seção "Atalhos" de Ajustes → Geral:** fica abaixo da área da captura.
- **Leitura parcial:** `ImportPanel`, `OrbEditor` (depois da linha 300), `SelectableProse`, `MarkdownBlockViews`, `AttachmentViews`, `ModelPopover`, `Tips`, `ProfileSettings` e `LiveScreenLayerView` não foram lidos.
