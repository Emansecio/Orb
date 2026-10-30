# Orb

App nativo de macOS (SwiftUI, Swift 6, sem dependências externas) que roda vários agentes, os Orbs, cada um com modelo, pasta, memória, permissões e avatar próprios.

## Documentação

- `docs/ARQUITETURA.md` é o mapa do código: módulos, o caminho de um turno, persistência, concorrência, testes e flags. Antes de criar ferramenta, provedor, campo persistido, tela ou atalho, siga a receita da seção "Como estender".
- Por tema: `docs/CONTEXTO.md`, `PERMISSOES.md`, `MEMORIA.md`, `ORBS.md`, `MOVIMENTO.md`. Manual do usuário: `docs/MANUAL.md`.
- `docs/REVISAO-*.md`, `AUTONOMIA-*.md`, `OTIMIZACAO.md` e `docs/historico/` são relatórios datados: confira no código antes de tratá-los como estado atual.

## Build, testes e app

- Requer Xcode 26+ (Swift 6.2 e SDK do macOS 26), mesmo com o alvo em macOS 14.
- Compile em debug e em release (`swift build` e `swift build -c release`): as telas de revisão ficam em `#if DEBUG || ORB_DEV_TOOLS`, e um símbolo de produção preso nesse bloco só quebra no release.
- Testes: `ORB_SKIP_REAL_BROWSER_TESTS=1 swift test --no-parallel --filter 'SuiteA|SuiteB'`, com as suítes afetadas. A suíte inteira (~3.900 testes) rouba o foco e disputa com o Orb aberto; localmente rode as filtradas e diga no relatório que a completa não rodou. `ORB_AX_SMOKE=1` liga os testes de Acessibilidade e `ORB_LIVE_TESTS=1` os que usam internet.
- Após cada build solicitado, gere a versão release com `./scripts/bundle.sh release` e abra `build/Orb.app`, que está fixado no Dock neste Mac. O script não abre nem fecha o app: se o Orb estiver aberto, encerre-o normalmente e reabra o bundle para que o processo atualizado possa acessar o Keychain; respeite diálogos e trabalho em andamento, sem forçar o encerramento. Confirme o processo e o bundle, conforme `AGENTS.md`.
- Conferência visual: `<binário> --snapshot <modo> out.png` renderiza uma tela sem abrir o app. Tela nova ganha um `case` em `Snapshot.render`, com dados de exemplo. Confira em 460 e 1100 pt.
- `ORB_DATA_DIR` troca a pasta de dados (`~/Library/Application Support/Orb`) para testes manuais.
- `python3 scripts/fake-llm.py [porta] [--long]` sobe um servidor falso compatível com OpenAI, para testar sem chave.
- Arte: `swift run -c release --package-path art/orbgen orbgen all` (~2 min) regrava `Sources/Orb/Resources/Orbs`.
- As pastas `~/` e `.slim/` na raiz são resíduo de ferramenta, não fazem parte do projeto.

## Convenções

- Comentários em inglês, explicando o porquê. Docs, textos da interface e commits em pt-BR. Texto de ferramenta enviado ao modelo: inglês e curto, porque vai em toda requisição.
- Concorrência estrita: `AppModel`, `BotSession` e as telas são `@MainActor`; o turno recebe um `TurnRequest` `Sendable`.
- Telas recebem o id do Orb, não o `Bot`. Grave propriedades com `writeIfChanged` e mantenha o `body` livre de trabalho.
- Decodificação tolerante: campo novo tem valor padrão; renomear ou remover chave exige migração. `init(from:)` fica numa `extension` no mesmo arquivo, e o `init` memberwise é o gerado pelo compilador.
- Testes esperam com `waitUntil` ou `TestGate`, guardam `TempFolder` como propriedade da suíte e usam `#expect(throws:)`. Helper usado em dois arquivos vai para `Tests/OrbAppTests/TestSupport/`.
- Commits: assunto "Área: o que muda, e por quê", sem prefixo convencional. O corpo lista o que mudou, os testes que rodaram (dizendo se a suíte completa rodou) e o que foi conferido por `--snapshot`.
