# Otimização, correção e polimento (madrugada de 21/10/2026)

Workflow noturno: 7 auditores Sonnet (somente leitura) em duas rodadas e uma pesquisa nas docs dos provedores. Depois,
11 corretores Sonnet em worktrees, em levas de até 3. Revisão final e integração na sessão principal (Opus). Cada lote
foi revisado no diff antes de entrar na `main` e testado com `swift test --filter` das áreas tocadas. A suíte inteira
não rodou localmente (rouba o foco, e o Orb estava aberto) e não houve push.

Uma linha por lote: o commit tem os detalhes.

## O que entrou

| Área | Commit | O que muda |
|---|---|---|
| Tokens | cb7af0b | Anexos (até 72 mil caracteres por mensagem) e blocos "desde a última vez" das mensagens antigas encolhem na condensação: 800 caracteres e o caminho para `read_file`. Era o maior gasto que sobrava no histórico. |
| Tokens / cache | 2268a62 | Instruções da pasta, skills e modo de permissão congelados no prompt de sistema por conversa, como a memória. Uma mudança vai uma vez no prefácio, e o cache do provedor não é reescrito inteiro. A permissão real continua sendo aplicada no gate. |
| Motor | 5052ae7, 53c43aa | `ToolCallAccumulator` deixa de ser quadrático em argumentos grandes (OpenAI e compatíveis). O SSE do MCP passa pelo `SSEDecoder` (último evento sem linha em branco, CR solitário, CRLF). `Retry-After: 0` espera pelo menos 1 s. O cache do snapshot da pasta conta a partir do fim do scan. |
| Motor | 8dd5dec | O grep pula arquivos sem acerto antes de partir em linhas (pré-filtro conservador). O corpo JSON do MCP HTTP checa o teto a cada 64 KB e recusa um Content-Length grande antes de ler. |
| Estado | 514ab78 | Os lembretes de cartão (1 h e 24 h) são cancelados ao responder. Desfazer um "Esquecer" avisa quando falha. As notas esquecidas do grupo têm teto. Rascunhos são gravados 2 s depois da última mudança. Apagar um Orb remove a memória fora da main. |
| Delegação | 7f5c321 | Uma resposta ou cancelamento para um Orb com a conversa descarregada não lê mais o JSON inteiro na main. A mudança espera na fila da sessão e é aplicada e gravada quando a conversa carrega, ou ao fechar o app. |
| Ferramentas web | 15e6d7b, 28df73a | **Segurança:** `browse_find fill` confere o tipo real do campo (antes digitava em senha achada por placeholder). Downloads e PDF só contam se o arquivo é novo. O prazo do download não consulta mais o relógio a cada byte. |
| Ferramentas arquivo/shell/Mac | e1e2bb0, c1c173a | glob/grep não entram em pacotes nem em `~/Library`. A leitura e edição de arquivos saem do pool cooperativo. `list_directory` tem teto. `run_command` em segundo plano volta quando a saída para. `job_output` fica mais curto, `apps_list` tem menos tokens, `isBlank` usa miniatura. |
| Navegador / outros | d89f393 | Um ⌘. durante uma ação do navegador não apaga mais a aba da conversa (antes ficavam abas órfãs). A migração antiga devolve a pasta se falhar. Sem login, o Keychain é lido uma vez só. Os caches do catálogo de skills têm teto. |
| Limpeza | cdc3700 | −94 linhas líquidas: 5 declarações mortas fora; `DateFormatter.make`, `withoutControlCharacters`, `TitledSection` e `CopyButton` no lugar de cópias; as rotinas do Store reusam as funções laterais. |

## Correções feitas na revisão final

- O primeiro `browse_find fill` usava `find … focus`, ação que o agent-browser 0.39 não tem (o `--help` lista click, fill,
  check, hover e text). Todo fill teria falhado. Agora clica no campo antes de conferir o tipo.
- O SSE novo do MCP pulava o LF de um CRLF antes de chegar ao decoder, que ficava com o estado de CR preso.
- O teste novo de "saída quieta" cobrava menos de 950 ms numa janela de 1 s, o que ficaria instável no CI. Ganhou janela
  própria.

## Avaliado e deixado de fora (com motivo)

- Snapshots do navegador superados ainda "frescos": a janela fresca existe para o cache não recomeçar a cada passo.
- `tool_choice: none` no último passo (Anthropic): a doc confirma que invalida o cache das mensagens, mas só acontece
  quando o turno chega a `maxSteps`. A alternativa (instrução em texto) deixa o modelo livre para chamar ferramenta.
- Raciocínio antigo do Responses: a doc diz que modelos anteriores ao GPT-5.6 o descartam. Cortar fora do lote quebra o
  cache, então só com medição.
- `prompt_cache_retention: "24h"`: já é o padrão em organizações sem ZDR, e o backend do ChatGPT não documenta o campo.
- Duplicações de UI (layouts de chips, abas do catálogo, folhas somente leitura, rodapé de folha) e o `AsyncMutex`:
  precisam de captura de tela ou mexem em concorrência.
- Pistas para a frente de fluidez: `OrbImportReader.read(text:)` no `body` de `SheetsAndSettings.swift:642` e
  `OrbFolder.availableURL` (faz `fileExists`) no `body` de `BotInspector.swift:660`.

## Antes do push

1. Fechar o Orb e rodar a suíte inteira (`caffeinate -i swift test`), ou deixar para o CI (Swift 6.3.3, mais rígido).
2. `scripts/bundle.sh` com o app fechado (com ele aberto, o Keychain quebra até reabrir).
3. Conferir no app: `browse_find fill` num campo comum e num de senha.
