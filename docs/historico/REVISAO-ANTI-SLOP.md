# Revisão anti-slop (03/11/2026)

Auditoria manual com a skill anti-slop: o portão automático dela lê React/HTML e recusa SwiftUI, então os sinais de
`signs.md` foram procurados no código e nas telas abertas no app (em segundo plano, 1292 pt). Modo: só auditoria, nada
foi alterado.

## Resultado

O Orb está limpo nos sinais clássicos: sem emoji na interface, sem rótulos em caixa alta espaçada, sem pesos 800/900, sem
itálico, sem palavras de propaganda, sem exclamação em botões e rótulos, um só material (`ModelPicker.swift:193`) e
animação em laço só onde algo está vivo (ditado gravando, presença no grupo). Os achados úteis estão em ruído e em um
brilho roxo.

| # | Achado | Onde | Tipo | Superfície | Variável |
|---|---|---|---|---|---|
| 1 | Markdown cru no Início: o resumo aparece com crases e asteriscos ("O wacli fica em \`~/.local/bin/wacli\`") | `Views/InicioView.swift:243`, `Text(title)` com `String` é literal | defeito | B trabalho | leitura do que mudou |
| 2 | Novidades viram lista de rodadas vazias: 163 itens, a maioria "Rodada das 23:00 concluída: nenhuma fala…, nada enviado" | `InicioView.eventRow` e o diário do Início | ruído | B trabalho | atenção: o que pede você some no meio |
| 3 | Acompanhamentos no Início repetem avatar e nome do Orb em cada linha (53 vezes "Atendente AcessosFit") | `Views/InicioView.swift:191` e `row` | ruído | B trabalho | varredura da lista |
| 4 | Brilho violeta `stageGlow` (#6E5CFF): mancha elíptica atrás do herói das boas-vindas, halo no botão grande, sombra roxa no "Criar Orb" e halo atrás do Orb proposto | `Theme.swift:79` e `:513`, `Views/WelcomeView.swift:645`, `Views/Multi/WizardFooter.swift:42`, `Views/Multi/OrbProposalCard.swift:193-195` | sinal de slop | A primeiro uso | primeira impressão |
| 5 | Título de boas-vindas em saudação com exclamação: "Olá! Este é o Orb." | `Views/WelcomeView.swift:58` | copy | A primeiro uso | primeira impressão |
| 6 | Nome das skills propostas sai do slug só com a primeira letra maiúscula: "Atendimento acessosfit", "Publicar lp docker" | `Memory/SkillProposal.swift:52` | copy | B trabalho | reconhecer a skill |

## Propostas

1. **Defeito, corrigir:** passar o resumo por `MarkdownBlocks.plainText(of:)` (já existe) ou por
   `AttributedString(markdown:options: .inlineOnlyPreservingWhitespace)` nas linhas do Início. O segundo mantém código e
   negrito com estilo.
2. Rodada de rotina sem mudança não entra em Novidades, ou entra como uma linha só por rotina ("12 rodadas sem novidade
   desde ontem"). O resultado continua no histórico da rotina.
3. Agrupar os acompanhamentos do Início por Orb, com o avatar e o nome uma vez no cabeçalho, como a página Rotinas faz.
4. Trocar o violeta por luz neutra, como `OrbEditor.swift:131` e `WizardPreviewPane.swift:129` já fazem (branco a 7%).
   O Orb já tem cor própria; o palco não precisa de outra. O halo no hover vira mudança de superfície.
5. "Este é o Orb" ou só o subtítulo como título. As saudações das personas (`EmptyChatContent.swift:139-143`) são a voz
   do Orb e ficam.
6. Pedir ao modelo um título junto do slug, ou preservar siglas e marcas do texto de origem.

## Aplicado (03/11/2026)

1. `InicioView.row` desenha título e detalhe com `MarkdownCache.attributed` (o cache do chat).
2. `InicioNews.folded` (`InicioHistory.swift`): rodadas concluídas ou puladas dobram na mais recente da rotina, com
   "a última de N rodadas"; falha e atenção ficam. O rótulo de rodada pulada virou "Pulada" (pré-checagem ou horário
   perdido). Teste: `InicioHistoryTests.runsThatWentAsPlannedFoldIntoTheNewestOfTheirRoutine`.
3. Acompanhamentos ordenados por Orb; avatar e nome só na primeira linha de cada Orb (`row(showsOrb:)`).
4. `stageGlow` saiu: luz branca neutra nas boas-vindas e no Orb proposto, hover do `HeroPillStyle` por superfície,
   `WizardFooter` sem halo (e sem `isReady`, que só servia a ele). O Início vazio perdeu o ícone `sparkles`.
5. "Este é o Orb".
6. `SkillProposal.name` recupera caixa e acentos das palavras do resumo ("Diagnosticar Quality Score", "Revisar memória
   Orb"). Melhorias de skill instalada mantêm o nome salvo. Teste: `theNameTakesCaseAndAccentsFromTheSummary`.

Conferido no app: Início (novidades dobradas, código em mono, acompanhamentos por Orb) e Skills; por `--snapshot`:
`welcome-ready` e `orb-proposal`. Restam `sparkle` em "Começar com o Atlas" (`WelcomeView.swift:404`) e o símbolo padrão
de aviso (`TranscriptViews.swift:1615`).

## Fora de propósito

- `→` em caminhos de Ajustes ("Ajustes → Modelos") contraria a regra da skill, mas é a convenção de caminho do macOS em
  texto corrido. Fica.
- Os avatares dos Orbs são esferas brilhantes por decisão de produto (Orbs acetinados), não sinal de slop.
- O retrato em gradiente de `ProfileSettings.swift:210` é dado de exemplo do `--snapshot`, fora do app de produção.

## Não verificado

- Tela de boas-vindas e assistente de criação: lidos só no código (abrir pede lista vazia ou `--snapshot`, que rouba o
  foco).
- Ajustes, Grupos, painel da barra de menus, tema claro e largura de 460 pt.
- Nenhum script da skill rodou: `killer-scan` recusa SwiftUI e `copy-lint` não lê `.swift`.
