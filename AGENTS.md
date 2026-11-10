# Instruções do projeto

Orb é um app nativo de macOS em SwiftUI e Swift 6, organizado como pacote SwiftPM, sem dependências externas. Ele roda vários agentes, os Orbs, cada um com modelo, pasta, memória, permissões e avatar próprios.

Este arquivo é a fonte única das instruções do projeto; o `CLAUDE.md` só o importa. As regras fixas valem em toda tarefa. Antes de alterar uma área, ache-a no índice por responsabilidade de `docs/ARQUITETURA.md` ("Mapa dos módulos") e leia apenas os arquivos e testes relacionados.

## Regras fixas

Correções que o usuário já fez mais de uma vez e decisões dele que já estão fechadas. Valem em toda tarefa, inclusive para subagentes. Regra nova entra no fim da seção dela, com o próximo número do prefixo; as existentes não são renumeradas.

### Interface

- **UI-1.** Controle novo copia o estilo das linhas vizinhas da mesma seção (tipo de linha, `Picker`/`Toggle` nativo, tamanho, alinhamento). Não invente um estilo próprio para um controle só.
- **UI-2.** Todo cartão usa `.card()`/`CardSurface` (no painel, `PanelSection`); nunca um fundo chapado com fio. Link em texto usa `LinkTextStyle`.
- **UI-3.** Cor tem função: laranja só para aviso ou risco; vermelho só na confirmação de uma ação destrutiva, que fica no menu `⋯`, não exposta na linha.
- **UI-4.** Mudança visual só está pronta depois de conferida por `--snapshot` em 460 e 1100 pt (com `ORB_DATA_DIR` temporário). O `--snapshot` não tira o foco; rode um por vez, não em lote longo.

### Textos da interface

- **TXT-1.** pt-BR com acentuação correta e caixa de sentença; nada de Title Case em rótulos, títulos ou botões.
- **TXT-2.** Sem jargão na tela: nenhum slug, id ou nome técnico (ex.: "agent-browser"); use o nome falado ("o controle do navegador").
- **TXT-3.** Pasta, grupo, espaço e categoria já têm significado na lateral; não reutilize essas palavras para outra coisa.
- **TXT-4.** Não corte a parte útil: caminho trunca no meio (`.truncationMode(.middle)`); texto que pode ser cortado ganha `.help` com o texto inteiro.

### Foco e máquina

- **MAQ-1.** Não roube o foco do usuário: nada de trazer apps para a frente, abrir abas do Chrome por AppleScript/`open` ou ativar janelas enquanto ele trabalha. Para links, entregue um arquivo ou a lista clicável.
- **MAQ-2.** Nada pago: nenhuma API ou serviço cobrado sem pedido explícito. Erro 429 significa esperar, não trocar para uma API paga.
- **MAQ-3.** Antes de algo que ocupe a máquina por minutos (render, benchmark, lote longo), diga o que muda e quanto leva, e espere o ok. Itere com testes curtos e encerre no fim todo loop de CPU que um benchmark abriu.
- **MAQ-4.** Imagem para o usuário vai por link ou anexo (`SendUserFile` com `display: "attach"`), nunca por algo que abra janela ou painel sozinho.

### Testes e esperas

- **TESTE-1.** A suíte padrão pode rodar com o Orb aberto; só os testes ligados por `ORB_REAL_BROWSER_TESTS=1` exigem o Orb fechado (ele limpa os navegadores ao sair). No dia a dia, rode apenas as suítes filtradas da área.
- **TESTE-2.** Espere com `waitUntil`, `TestGate`, `Monitor` ou um processo em segundo plano; nunca com `sleep N` (nem em subagentes, que deixam `sleep` órfãos).
- **TESTE-3.** Suíte que passa de ~2 min está presa: rode `sample` no `swiftpm-testing-helper` para achar o teste, encerre, rode de novo com `--skip` nele, rode-o sozinho e diga no relatório que foi pulado. Rode a suíte com `caffeinate -i`.
- **TESTE-4.** Depois de cada feature implementada ou alterada, rode as suítes afetadas (`scripts/test.sh --filter`) antes de passar à próxima.
- **TESTE-5.** Toda correção de bug ganha um teste de regressão, e você confere que ele falha sem a correção (dois testes já passavam mesmo sem ela). Lógica nova com ramificação, laço ou parsing ganha testes do caminho principal e dos casos de borda.
- **TESTE-6.** Rode só os testes que cobrem o que você alterou ou implementou (`scripts/test.sh --filter` com as suítes dessa área). A suíte completa fica para quando for de fato necessária: mudança em código compartilhado por muitas áreas (ex.: `AppModel`, `BotSession`, `Engine`, `TestSupport`) ou falha que só aparece no conjunto. Quando rodá-la, diga no relatório por quê.

### Subagentes

- **AG-1.** Subagentes que escrevem código são Sonnet, cada um em sua worktree, no máximo 3 compilando ao mesmo tempo (com `nice -n 15`). A worktree nasce de `origin/main`: o agente roda `git merge --ff-only main` antes de começar. A revisão final dos diffs é da sessão principal.
- **AG-2.** Lance os agentes de worktree um por vez, esperando cada lançamento voltar: cinco criados na mesma mensagem já colidiram no `git worktree` e um deles falhou.
- **AG-3.** Depois de levar o commit do agente para a `main`, remova a worktree e o branch dele.
- **AG-4.** Nenhum subagente Opus, a menos que o usuário peça o modelo pelo nome. Agentes só de leitura podem ir em maior número; o teto de 3 vale para quem compila, mesmo quando o pedido é "paralelize o quanto puder".

### Forma de trabalho

- **TRAB-1.** Não repita o que o usuário já recusou ou desfez (ex.: a janela de Ajustes mudando de altura entre abas). Antes de corrigir, confirme a causa no código e nas capturas, não na suposição.
- **TRAB-2.** Opção técnica com recomendação clara: escolha, registre a decisão e siga. Pergunte ao usuário só o que é gosto dele ou exige ação dele (login, instalação, pagamento).

### Git e CI

- **GIT-1.** Trabalho direto na `main`, com push liberado. Use worktree quando outra sessão estiver mexendo na `main`.
- **GIT-2.** Push só depois de passarem os testes da área alterada (TESTE-6) e o bundle; a suíte completa só entra nos casos da TESTE-6. Nunca encadeie o push aos testes com `&&` frouxo (já subiu push com teste falhando).
- **GIT-3.** O CI usa Swift 6.3.3, mais estrito que o Swift local: erros que passam aqui quebram lá. Depois do push, confira com `gh run list --branch main`.
- **GIT-4.** Teste que já falhava na `main` antes da sua mudança não libera o push. Confirme numa worktree sem a sua mudança que a falha é anterior; depois corrija-a num commit próprio ou pare e pergunte. Nunca pule nem desligue o teste para o push passar.
- **GIT-5.** O repositório é público: nenhum segredo, token, dado pessoal ou descrição de falha de segurança ainda aberta vai para commit, mensagem de commit ou issue. Auditorias e planos com esse conteúdo ficam fora do git.

### Decisões de produto

- **PROD-1.** Recurso que mexe em janela, app ou navegador trabalha em segundo plano por padrão; vai para a frente só com pedido explícito ou quando a tarefa não anda de outro jeito.
- **PROD-2.** Entregas arredondadas: cada etapa é usável sozinha, com padrão seguro (sem a pré-condição, o comportamento é o de hoje), avisos, travas e um toggle em Ajustes quando houver custo ou risco. Nunca obrigue a etapa seguinte.
- **PROD-3.** O Claude Code é só o cano até o modelo (`Engine/ClaudePipe/`), com o motor do Orb no comando: nunca reintroduza o harness dele (prompt, ferramentas, sessões, compactação) nem OAuth direto.
- **PROD-4.** Não mude como a memória trata páginas escritas fora do padrão sem pedido: Orbs antigos do usuário dependem disso.
- **PROD-5.** Nunca remova um recurso existente sem pedido explícito (as várias conversas por Orb saíram em `e3f90ba` sem aval e tiveram de voltar).

### Qualidade de código

- **COD-1.** Escreva o mínimo de código que resolve, e de forma eficiente. Antes de criar algo, procure o que já existe no projeto, na biblioteca padrão ou na plataforma. Sem overcoding: nenhuma abstração, camada, opção ou caso hipotético que a tarefa não pede. Ser enxuto não justifica cortar validação, tratamento de erro, proteção de dados ou acessibilidade.
- **COD-2.** Antes de dar por pronto, revise o diff inteiro procurando bug, caso de borda, código morto ou duplicado e gargalo (trabalho no `body`, loop ou leitura repetida, I/O na thread principal). Corrija o que achar e diga no relatório o que a revisão encontrou.

Numeração anterior (1 a 32, até 2026-11-09), ainda citada em `docs/historico/`: 1–4 = UI-1 a UI-4; 5–8 = TXT-1 a TXT-4; 9 = MAQ-1; 10 = TESTE-1; 11 = MAQ-2; 12 = TESTE-2; 13 = MAQ-3; 14 = TESTE-3; 15 = MAQ-4; 16 = AG-1; 17 = AG-3; 18 = TRAB-1; 19 = AG-4; 20 = TRAB-2; 21–23 = GIT-1 a GIT-3; 24–28 = PROD-1 a PROD-5; 29 = COD-1; 30 = TESTE-4; 31 = TESTE-5; 32 = COD-2.

## Build, testes e app

- Requer Xcode 26+ (Swift 6.2 e SDK do macOS 26), mesmo com o alvo em macOS 14.
- Compile em debug e em release (`swift build` e `swift build -c release`): as telas de revisão ficam em `#if DEBUG || ORB_DEV_TOOLS`, e um símbolo de produção preso nesse bloco só quebra no release.
- Testes: `scripts/test.sh --filter 'SuiteA|SuiteB'`, com as suítes afetadas. Filtrado, o script roda um processo com metade dos núcleos (sem limite, testes de tempo falham; em série, a suíte leva ~4 min). Sem filtro, divide a suíte em 4 processos que usam todos os núcleos: a suíte inteira (~5.800 testes) leva ~1 min, não toma o foco, mas ocupa a máquina com o Orb aberto: diga no relatório se ela rodou. Depois de mudar uma declaração do app, o build refaz os ~290 arquivos de teste (~1,5 min); mudar só o corpo de uma função custa ~17 s. `ORB_AX_SMOKE=1` liga os testes de Acessibilidade, `ORB_LIVE_TESTS=1` os que usam internet e `ORB_REAL_BROWSER_TESTS=1` os do navegador real (o que abre janela pede também `ORB_REAL_BROWSER_WINDOW=1`).
- App do Dock: sempre que executar um build para o usuário, conclua gerando a versão release com `./scripts/bundle.sh release` e abrindo `build/Orb.app`, que é o aplicativo fixado no Dock neste Mac; um `swift build` sozinho não o atualiza. O script não abre nem fecha o app: se o Orb estiver aberto, encerre-o normalmente e reabra o bundle, para que o processo corresponda à assinatura e continue acessando o Keychain; respeite diálogos e trabalho em andamento, sem forçar o encerramento. Confirme que o bundle foi gerado e que o processo aberto corresponde a `build/Orb.app`. Não rode o bundling a cada compilação intermediária do mesmo trabalho: atualize o Dock ao final do build solicitado.
- Conferência visual: `<binário> --snapshot <modo> out.png` renderiza uma tela sem abrir o app, em debug e com dados isolados; confira em 460 e 1100 pt (UI-4). Tela nova ganha um `case` em `Snapshot.render` (`OrbApp.swift`), com dados de exemplo; os cenários do chat ficam em `Views/TranscriptSamples.swift`.
- `ORB_DATA_DIR` troca a pasta de dados (`~/Library/Application Support/Orb`) para testes manuais.
- `python3 scripts/fake-llm.py [porta] [--long]` sobe um servidor falso compatível com OpenAI, para testar sem chave.
- Arte: `swift run -c release --package-path art/orbgen orbgen all` (~2 min) regrava `Sources/Orb/Resources/Orbs`.
- `build/` e `.build/` são saídas de compilação. As pastas `~/` e `.slim/` na raiz são resíduo de ferramenta, não fazem parte do projeto.

## Como trabalhar em cada área

- Preserve alterações locais existentes. Mantenha a mudança na categoria responsável, sem reorganizar arquivos ou criar abstrações sem necessidade.
- Fluxo principal: `Views` → `AppModel`/`BotSession` → `Engine`; eventos retornam para `BotLive`/`OrbTranscript` e atualizam as telas. Não mova execução ou persistência para o `body` de uma view.
- Agrupamento do chat: preserve os itens originais e seus IDs, a busca, os limites de pedidos e de compactação. Perguntas, aprovações pendentes, avisos e navegador ao vivo precisam continuar acessíveis. Não feche detalhes abertos ao chegar uma nova ação.
- Desempenho visual: comece em `Orbs/OrbDriver.swift` e `OrbAnimationView.swift` (relógios/camadas), `Views/TextFade.swift` e `SelectableProse.swift` (texto), `Views/ImageThumbnails.swift` (imagens) ou `LiveScreen/` (frames). Preserve a pausa por visibilidade, os limites de cache/concorrência e a decodificação fora da thread principal. O inventário e as medições estão em `docs/historico/REVISAO-RENDERIZACAO-2026-10-26.md`; valide conclusões históricas no código atual.
- Nas demais telas visuais, consulte `docs/historico/REVISAO-VISUAL-COMPLEMENTAR-2026-10-26.md` para o inventário por arquivo. Buscas canceladas não podem encerrar o loading da consulta seguinte; leituras assíncronas devem conferir cancelamento antes de publicar estado. Avatares decorativos ociosos podem reutilizar `SettlingOrb`; mudanças de layout por largura devem observar limites, sem guardar cada pixel em `@State`.

## Convenções

- Comentários em inglês, explicando o porquê. Docs, textos da interface e commits em pt-BR. Texto de ferramenta enviado ao modelo: inglês e curto, porque vai em toda requisição.
- Concorrência estrita: `AppModel`, `BotSession` e as telas são `@MainActor`; o turno recebe um `TurnRequest` `Sendable`.
- Telas recebem o id do Orb, não o `Bot`. Grave propriedades com `writeIfChanged` e mantenha o `body` livre de trabalho.
- Decodificação tolerante: campo novo tem valor padrão; renomear ou remover chave exige migração. `init(from:)` fica numa `extension` no mesmo arquivo, e o `init` memberwise é o gerado pelo compilador.
- Testes esperam com `waitUntil` ou `TestGate`, guardam `TempFolder` como propriedade da suíte e usam `#expect(throws:)`. Helper usado em dois arquivos vai para `Tests/OrbAppTests/TestSupport/`.
- Commits: assunto "Área: o que muda, e por quê", sem prefixo convencional. O corpo lista o que mudou, os testes que rodaram (dizendo se a suíte completa rodou) e o que foi conferido por `--snapshot`.

## Documentação

- `docs/ARQUITETURA.md` é o mapa do código: o índice por responsabilidade (onde procurar cada área), os módulos, o caminho de um turno, concorrência, desempenho e a receita "Como estender". Antes de criar ferramenta, provedor, campo persistido, tela ou atalho, siga essa receita.
- Detalhe por assunto: persistência em `docs/PERSISTENCIA.md`, testes em `docs/TESTES.md`, argumentos, variáveis, `--snapshot` e scripts em `docs/DESENVOLVIMENTO.md`, ferramentas em `docs/FERRAMENTAS.md` e colaboração entre Orbs em `docs/COLABORACAO.md`.
- Por tema: `docs/CONTEXTO.md`, `PERMISSOES.md`, `MEMORIA.md`, `ORBS.md`, `MOVIMENTO.md`, `TELA-AO-VIVO.md`, `USO-DO-COMPUTADOR.md` e `CELULAR.md`. Manual do usuário: `docs/MANUAL.md`.
- `docs/historico/` guarda os relatórios datados (revisões, investigações, planos já executados): confira no código antes de tratá-los como estado atual. Relatório novo nasce lá; na raiz de `docs/` fica só o que descreve o projeto como ele é hoje.
- `docs/mocks/` e `docs/readme/` contêm referências visuais.
