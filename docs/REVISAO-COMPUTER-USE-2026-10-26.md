# Revisão do uso do computador — 26/10/2026

## Objetivo e escopo

Examinar capacidade, velocidade e interferência no uso do Mac. A revisão foi estática, com testes usando dublês; não houve medição em aplicativos reais nem teste de usabilidade. `USO-DO-COMPUTADOR.md` descreve o desenho existente, não comprova as metas de tempo no Mac atual.

## Prioridades

### 1. Preservar a escolha de foco da pessoa — corrigido

`ScreenTakeover.swift`: ao interromper uma tomada de tela porque outro aplicativo veio à frente, a restauração voltava ao aplicativo anterior e movia o cursor, mesmo que a pessoa tivesse escolhido outro aplicativo. A restauração agora conserva o foco e o cursor quando detecta outra escolha, também se a troca ocorrer depois da última ação. A associação do cursor é restabelecida e o erro continua chegando ao agente. Testes em `ScreenTakeoverTests.swift` cobrem a troca durante a operação, para o aplicativo original e após a última ação. Ainda existe uma janela de corrida entre conferir o foco e pedir a restauração: as APIs do sistema não tornam essas operações atômicas.

### 2. Confirmar a devolução de foco em segundo plano — implementado

`UIActTool.restoreFront` em `AccessibilityTools.swift` agora distingue foco restaurado, não confirmado, mudança de foco e escolha da pessoa. Depois do pedido AX, verifica por até 200 ms qual PID ficou na frente e informa quando não consegue confirmar; não ativa o aplicativo à força. Testes simulam recusa AX, ausência de mudança e outro aplicativo vindo à frente. A verificação e o pedido não são atômicos; um aplicativo lento pode voltar depois do prazo e ser informado como não confirmado.

### 3. Evitar que esperas AX atrasem ações de outros aplicativos — investigar com medições

`AXSessions` limita a quatro chamadas em voo e serializa por PID. Isso protege o pool e o Mac de um aplicativo travado, mas chamadas enfileiradas para um mesmo PID também ocupam vagas globais antes de iniciar na fila daquele aplicativo. Várias chamadas ao mesmo aplicativo podem atrasar outros aplicativos. Medir espera por vaga, tempo de fila por PID e duração de IPC em cargas concorrentes sintéticas; só então considerar uma fila por PID que adquira a vaga global quando for executar. Preservar prazos, cancelamento e a garantia de que uma ação vencida nunca sai depois do timeout. Testar justiça entre PIDs, concorrência máxima e cancelamento antes de iniciar. Não elevar o limite global sem dados: isso pode piorar a responsividade do Mac.

### 4. Reduzir latência de sequências sem perder verificação — medir primeiro

`UIActTool.perform` assina eventos, espera estabilização e captura o estado depois de cada etapa, inclusive nos `steps`. O custo por etapa favorece diagnóstico, mas pode acumular latência. Medir p50/p95 separando AX, espera e captura, em apps nativos e Electron, com e sem mudanças. Se a espera dominar, estudar uma política específica para etapas intermediárias que só avance após uma confirmação observável; manter parada na primeira falha, relatório de efeitos parciais e verificação antes de ação perigosa. Não remover a espera às cegas.

### 5. Aumentar capacidade com seleção do caminho certo — validar por aplicação

Já existem leitura AX, ações semânticas, eventos por PID, captura de janela, OCR, dicionário AppleScript e tomada de tela explícita. A compatibilidade real varia entre aplicativos e controles; não há evidência nesta revisão de que todos aceitem eventos em segundo plano. Criar uma matriz reproduzível por aplicativo e tarefa (ler, preencher, atalhos, menus, tabelas, canvas), registrando método, sucesso, foco/cursor antes e depois e latência. Priorizar API, AppleScript e AX quando disponíveis, depois eventos direcionados; manter takeover como exceção explícita. Usar a matriz para melhorar mensagens e orientações ao agente, sem prometer suporte genérico a aplicativos com AX fraco.

### 6. Entrada de teclado durante mudança de foco — proteção implementada

`send` verifica novamente a atividade humana imediatamente antes de enviar atalhos, e a digitação também verifica após focar o alvo, antes do primeiro trecho. Testes simulam a pessoa começando a usar o aplicativo durante o foco e confirmam que nenhum evento é enviado. O envio continua por PID e sem área de transferência. A checagem reduz, mas não elimina, a corrida com entrada humana.

## Verificação segura

Os testes unitários substituem Acessibilidade, eventos e captura; não demonstram o comportamento do WindowServer. `AXSmokeTests` usa aplicativo real e pode alterar foco e cursor: executar apenas em momento combinado, sem uso simultâneo do Mac. A suíte completa também não é adequada durante o uso normal, conforme `CLAUDE.md`. Nenhuma promessa de ganho de velocidade deve ser feita sem medições comparáveis antes/depois.
