# Testes

Parte do mapa do código: veja [ARQUITETURA.md](ARQUITETURA.md) para a visão geral.


```bash
scripts/test.sh                                         # a suíte inteira, em 4 processos com todos os núcleos (~1 min num Mac de 8)
scripts/test.sh --filter 'ContextWindowTests|WaitingTests'   # as suítes afetadas (expressão regular)
ORB_LIVE_TESTS=1 scripts/test.sh --filter LiveCatalogTests   # catálogos reais (internet)
ORB_REAL_BROWSER_TESTS=1 scripts/test.sh --filter RealBrowser # Chrome real, sem janela (internet)
ORB_RICH_RENDER_TESTS=1 scripts/test.sh --filter PageSandboxLiveTests # WebKit real: desenho e ataques à sandbox, sem rede
```

São cerca de 5.000 testes em `Tests/OrbAppTests`, em Swift Testing (`@Test`, `@Suite`, `#expect`, `#require`).

- **Paralelismo.** Sem limite, o `swift test` roda tantos testes de uma vez quanto há núcleos, e num Mac de 8 núcleos uns 25
  testes que esperam um relógio ou a main actor falham: num processo só há uma main actor, e os testes `@MainActor` fazem fila
  nela. Por isso `scripts/test.sh` faz assim (`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`, que o Swift Testing lê; o
  `--num-workers` do SwiftPM só vale para XCTest):
  - **Com `--filter`**: um processo, com metade dos núcleos.
  - **Sem filtro (a suíte inteira)**: compila uma vez e divide as suítes em `ORB_TEST_SHARDS` processos (4 por padrão), que
    dividem entre si um teste por núcleo; cada processo tem a sua main actor. Uma suíte nunca é partida, então `.serialized`
    e o que ela compartilha continuam valendo. A divisão equilibra o tempo de cada suíte medido em série, guardado em
    `scripts/test-times.txt` (suíte nova conta 0,04 s por teste); para refazer a tabela, `swift test --no-parallel 2>&1 |
    scripts/test.sh --record-times`. O resumo no fim mostra o que falhou e uma linha por parte; os logs completos ficam na
    pasta temporária que ele indica.
  - `ORB_TEST_WIDTH=<n>` muda o total de testes de uma vez (1 é o mesmo que `--no-parallel`), `ORB_TEST_SHARDS=1` volta a um
    processo só, e `ORB_TEST_SHARD=<i>/<n>` roda só a parte i de n neste processo (o CI usa assim).

  Medido em 2026-11-10 (8 núcleos): um processo com 4 de uma vez, ~82 s; 4 processos com 2 cada, ~60 s, sem falha a mais em
  quatro rodadas; em série, ~4 min. Mais que um teste por núcleo não ganhou nada: a suíte é limitada pela CPU.
- **CI.** Cada push roda a suíte em 4 jobs ao mesmo tempo (`ORB_TEST_SHARD=i/4`), em série dentro de cada um, porque o runner
  tem 3 núcleos e os testes que esperam algo estouram o tempo em paralelo. Antes, num job só, eram ~8 min de testes.
- **Build dos testes.** O alvo `OrbAppTests` compila sem informação de depuração (`-gnone`, no `Package.swift`): qualquer mudança
  numa declaração do app recompila os ~290 arquivos de teste, e um terço desse tempo era informação de depuração que ninguém
  lê (falhas do Swift Testing vêm com arquivo e linha pelo macro, não por ela). Medido: de ~113 s para ~90 s depois de mudar
  uma declaração do app. Mudar só o corpo de uma função leva ~17 s, quase todo na emissão do módulo `Orb` (que confere as
  declarações dos ~450 arquivos); só dividir o módulo baixaria esse piso.
- **Tela.** A suíte padrão não traz nada para a frente de quem usa o Mac: o processo de teste não pode se ativar (sem ícone no
  Dock), as janelas que alguns testes desenham são transparentes e não recebem clique, e o que mexe no Mac de verdade
  (navegador real e internet, Acessibilidade, captura, tomada de tela) só roda com a variável própria. Nas rodadas de
  2026-11-02 o app da frente, a área de transferência e o cursor não mudaram por causa dos testes.
- **Determinismo.** Nada de dormir um tempo fixo para "dar tempo": `waitUntil(_:timeout:poll:_:)` (em `TestSupport/Waiting.swift`)
  espera uma **condição** (com limite generoso e `Issue` descritiva se estourar). Para afirmações negativas, espere primeiro
  um sinal positivo de que o sistema assentou. Os testes do modelo chamam `flushText` direto em vez de esperar os 33 ms.
- **Isolamento.** Cada suíte usa pastas temporárias próprias (`Store(directory:)` tem a sua fila de escrita), e
  `AppModel(store:runsBackgroundWork: false, asyncLoading:, secretVault:)` (e `devRun: true`, que também pula os conectores) não inicia agendador, Keychain nem observadores
  do app (o cofre de segredos é um `MemoryVault`). `QuietNotifications.hold()` impede banners do processo de teste.
- **Modelo falso e auxiliares.** Os testes injetam um `LLMClient` próprio: `AppModel.clientOverride`, ou um modelo passado
  direto ao `AgentEngine.run`. O que mais de um arquivo precisa mora em `TestSupport/`, e só lá: antes de escrever um fake,
  um portão ou uma limpeza, procure. A convenção:
  1. **Modelo falso roteirizado é sempre `CallScript` (+ `CallScriptModel`).** O roteiro dá as respostas em ordem
     (`ModelReply.say`, `.calling`, `.failing`), diz o que fazer quando acabam (`whenExhausted`: `.repeatLast` ou `.fim`, sempre
     explícito), pode esperar (`holdsCall`, `before:`) e grava o que recebeu (`calls`, `received`). Um tipo novo só se
     testar algo que o roteiro não expressa (um modelo que nunca termina, portão por chave, rota pelo prompt), com um
     comentário dizendo o quê.
  2. **Esperar um passo é `TestGate`; esperar um estado é `waitUntil`** (`TestSupport/Waiting.swift`). Nada de laço com
     `Task.sleep` calado.
  3. **Pasta temporária é `TempFolder`, como propriedade da suíte** (apaga no `deinit` com `removeTestFolder`, selando as
     gravações tardias). Nunca como variável local nem em tupla: o ARC solta o objeto no meio do teste. Nada de
     `defer { removeTestFolder }` por teste numa suíte que já tem a raiz.
  4. **Erro esperado é `#expect(throws:)`** (`#expect(throws: Tipo.self)` ou `#expect(throws: valor)`), nunca
     `do { …; Issue.record } catch`. Para conferir a mensagem: `let error = try #require(await #expect(throws: ToolError.self) { … })`.
  5. **O que um segundo arquivo precisar vai para `TestSupport/` na hora.** A segunda cópia de um helper já é motivo
     para subir; a terceira não passa na revisão.

  Estão lá, entre outros: `LockedBox`, `utcCalendar`/`utcDate`, `failureMessage`, `writeExecutable`, `notices`, `FakePreferences`, `StoreFixtures`, `RaisedFlag`,
  `notifies(reading:whenYouDo:)`, `hasPython` e as visões do `AppModel` que só os testes leem. O Claude Code é testado com um `claude` falso, um script que o
  próprio teste grava e passa ao `ClaudeCodeClient` (`ORB_CLAUDE_PATH` faz o app usar outro executável).
- **Fixtures sem binários**: PDFs e PNGs são desenhados na hora (`Fixtures`), e o AX (Acessibilidade) é uma árvore falsa
  injetável (`AccessibilitySystem`, com `TestSupport/AccessibilityFakes.swift`; a tomada de tela tem o seu mundo falso em
  `ScreenTakeoverTests`).
- **Smoke de Acessibilidade** (`AXSmokeTests`, desligado por padrão): `ORB_AX_SMOKE=1` roda `ui_read`/`ui_act`/`screenshot` contra o app
  `OrbAXFixture` (AppKit, nunca se ativa, registra em JSON no stdout o que recebeu) e confere que o app da frente e o cursor não
  mudam; precisa da Acessibilidade para quem roda os testes (o Terminal do Mac, não um terminal sem ela). `ORB_AX_TAKEOVER=1` liga
  os que assumem a tela de verdade, `ORB_AX_SMOKE_SYSTEM=1` uma leitura do Finder, e a captura exige Gravação de Tela. Não mexa no
  mouse enquanto rodam.
- **Navegador real** (`RealBrowser*Tests`, `BrowserCleanupTests`, desligados por padrão): `ORB_REAL_BROWSER_TESTS=1` roda o
  `agent-browser` e o Chrome (ou Brave) instalados contra páginas locais, example.com, DuckDuckGo e Google, sem janela; o teste
  que abre a janela do `browse_show` e toma o foco pede também `ORB_REAL_BROWSER_WINDOW=1`. `ORB_INSTALL_BROWSERS=all` instala
  os componentes de verdade na pasta do app.
- **Contratos de fio**: `ProviderWireGoldenTests` fixa a requisição e os eventos de cada formato.

## Modelo falso para uso manual

`scripts/fake-llm.py [porta] [--long]` serve uma API compatível com OpenAI em `http://127.0.0.1:8765/v1`: cada mensagem
recebe um texto curto, uma chamada `run_command` (para ver o cartão de aprovação) e, depois do resultado, uma resposta final
(`--long`: ~2 000 palavras de Markdown, uma a cada 15 ms, para medir o streaming). Ele também informa o uso de cada chamada
(1 200 tokens de prompt, 800 do cache, 30 de saída), então a aba Uso tem números. Para usar: abra o app com dados isolados e
aponte um provedor "Gateway próprio" para a URL.

```bash
python3 scripts/fake-llm.py 8765 --long
open -n build/Orb.app --env ORB_DATA_DIR=/tmp/orb-teste --env ORB_SEND="Como está meu Mac?"
# Ajustes → Modelos → Adicionar provedor → Gateway próprio → http://127.0.0.1:8765/v1 → modelo fake-model
```

