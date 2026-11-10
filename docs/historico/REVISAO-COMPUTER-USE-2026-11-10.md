# Revisão do uso do computador — 10/11/2026

Pedido: rever a qualidade do uso do computador (`ui_read`, `ui_act`, `screenshot`, `open`, `applescript`), com foco em
velocidade, eficiência e uso pleno em segundo plano. Nada foi alterado no código; este arquivo foi a única coisa criada.

Depois: os itens 1 a 3 da seção 4 foram implementados no mesmo dia (`d2a852e`, `a8930ce`, `a31b8b6`, e a revisão em
`b887d0e`). Na revisão foi medido que o Chrome sem janela do Orb tem quatro janelas na lista do servidor de janelas,
nenhuma na tela e nenhuma pela Acessibilidade; a recusa usa "nenhuma na tela". O item 4 (outra Mesa) segue aberto.

Método: leitura do código da área, das duas revisões anteriores (16/10 e 26/10) e, pela primeira vez, do **histórico real**:
todas as conversas salvas, onde há 51 chamadas de `ui_act`, `ui_read` e `screenshot` (contra ~9.600 do navegador).

## Resumo

1. **O uso real nunca funcionou.** `ui_act` falhou 27 de 27 vezes e `ui_read` não devolveu nada útil em 14 de 14. Nenhuma
   ação por Acessibilidade chegou a um app. A causa não é o motor (bem protegido), é a escolha da ferramenta e do app.
2. **O caminho de Acessibilidade não toma a tela.** `activate`, `AXRaise`, `.cghidEventTap` e mover o cursor só existem em
   `ScreenTakeover.swift`. Quem tomou a tela no histórico foram `open` com `front: true`, `applescript` com `activate` e a
   captura da tela inteira.
3. **A velocidade da ferramenta não é o gargalo.** As chamadas levam dezenas de milissegundos; o tempo vai para as idas ao
   modelo, e cada falha acima custou uma.

## 1. Eficiência (medido no histórico)

| Ferramenta | Chamadas | Úteis | O que aconteceu |
|---|---:|---:|---|
| `ui_act` | 27 | 0 | 8 sem leitura antes, 8 nome ambíguo ou app não achado, 5 id do navegador, 5 sem `action`, 1 app reaberto |
| `ui_read` | 14 | 0 | 7 leram o navegador sem janela do próprio Orb, 3 app não achado, 2 nome ambíguo, 2 o próprio Orb |
| `screenshot` | 10 | 6 | 3 da tela inteira, 3 de janela; 2 app não achado, 1 processo errado, 1 permissão |

### 1.1 Navegador do Orb confundido com app do Mac (cerca de 30 das 41 falhas)

O modelo pegou refs do `browse_snapshot` (`e7586`) e os passou ao `ui_act`, com `app: "Chrome"`, `"browser"` ou nenhum.
As respostas não desfazem o engano:

- `Id inválido "e7586": use um id de ui_read` (`AccessibilityTools.swift:742`): não diz que aquilo é um ref do navegador.
- `ui_read` no Chrome que o Orb roda sem janela devolve "O app está aberto mas não tem janelas visíveis. Dá para usar os
  menus" (`:374`), sete vezes, convidando a insistir.

Correção proposta: um id no formato `eN` e um app que é o navegador do próprio Orb (o pid que segura o perfil,
`BrowserProfileCache.holder`) respondem "isso é do navegador do Orb: use browse_click / browse_snapshot".

### 1.2 Nome do app

- **Processo auxiliar vira ambiguidade (8 vezes):** `"Chrome"` casa com "Google Chrome" e "Google Chrome Helper (…)".
  `RunningAppMatcher.match` (`MacAppTools.swift:313-316`) conta qualquer processo. Correção: descartar o candidato cujo
  bundle id é filho do de outro candidato e preferir o app regular.
- **Nome em inglês contra nome traduzido (3 capturas):** `open` e AppleScript aceitam "Preview"; `ui_*` e `screenshot` só
  casam o nome traduzido ("Pré-Visualização"). Na busca parcial, "Preview" casou com `QLPreviewGenerationExtension`.
  Correção: casar também o nome do `.app` em disco; `liveProcesses` (`AccessibilityElements.swift:545-547`) hoje nem
  preenche `bundleURL`.

### 1.3 Saída grande e idas a mais

- `apps_list` com `include_background` devolve ~9.000 caracteres (90 processos) e foi chamado 6 vezes na mesma conversa.
  É o P3-8 da revisão de 16/10, ainda aberto.
- `ui_act` devolve só o que mudou (até 600 caracteres) e o prompt manda "read again after it changes": duas idas ao
  modelo por passo. É a mesma etapa 3 já feita no navegador (`088ea9b`). Aqui é por analogia: nenhuma ação passou, então
  não há medida própria.

## 2. Segundo plano

Sem vazamento no caminho N0/N1: o `grep` da revisão final continua limpo e `open` abre com `activates = false` e vigia a
frente por 800 ms. O que tomou a tela no histórico:

1. **`open` com `front: true` em 9 de 12 aberturas** (imagens para a pessoa ver). É escolha do modelo e pode ser o pedido,
   mas na prática virou o padrão.
2. **`applescript` com `activate` (2 vezes) e `open -a` pelo shell (1 vez)** para "ler um print": abriu o app na frente,
   esperou 2 s e capturou a tela inteira com OCR, quando `read_file` da imagem já faz o OCR sem abrir nada. O `applescript`
   não tem a vigia de frente que o `open` tem, e nada no prompt fala de `activate` (`MacTools.swift:277-285`).
3. **Captura da tela inteira** (3 das 6 capturas boas): 3024×1964 com OCR `.accurate`, de 0,65 s a 5,9 s, e mostra o que a
   pessoa está fazendo, não o app alvo.

Correção proposta: a mesma vigia do `open` no `applescript` (devolve a frente se a pessoa não mexeu no Mac) e uma frase em
`PromptParts.appControl` (sem `activate`; imagem se lê com `read_file`). As specs têm 28 caracteres de folga
(20.822 de 20.850), então o texto vai no prompt.

**Risco não verificado:** `AXWindows` costuma listar só as janelas da Mesa atual. Se for assim aqui, um app em tela cheia
ou em outra Mesa cai em "não tem janelas visíveis", embora `USO-DO-COMPUTADOR.md` prometa a leitura em outro Space. No
momento da revisão todos os apps estavam na mesma Mesa; testar exige mover uma janela.

Continuam pedindo a tela, por desenho: pop-up cujo menu só existe aberto (`:2789`), menu de contexto, clique e arrasto em
Chromium/Electron, atalhos que puxam o foco e captura de janela minimizada.

## 3. Velocidade

| Medida | Valor | Fonte |
|---|---|---|
| Chamada `ui_*` (as que falharam) | 10 a 140 ms | histórico |
| Captura de janela | 250 a 330 ms | histórico |
| Captura da tela inteira com OCR | 0,65 a 5,9 s | histórico |
| `applescript` | 0,3 a 14,6 s | histórico |
| `AXWindows` de um app | 15 a 47 ms | medido agora em 7 apps, só leitura |

Depois de cada passo o `ui_act` espera a primeira notificação por até 400 ms e mais 60 ms de silêncio (`UISettle`,
`AccessibilityEvents.swift:426-431`), também entre os `steps`. Sem uso real não dá para dizer quanto pesa: o item 4 da
revisão de 26/10 segue aberto.

## 4. Ordem sugerida

1. Redirecionar o engano navegador × app e consertar o casamento de nomes (1.1 e 1.2). Pequeno, com teste por fakes.
2. Vigia de frente no `applescript` e a frase no prompt (seção 2).
3. `ui_act` devolver o estado novo quando a janela muda (1.3).
4. Testar a leitura de app em outra Mesa e em tela cheia.

## 5. O que não foi feito

- Nenhum teste rodou (nada mudou no código) e o `AXSmokeTests` não rodou: ele abre uma janela de app real.
- Latência de `ui_read` e `ui_act` em apps reais continua sem medida.
- O histórico vem de poucas conversas: mostra o que deu errado, não a frequência em outro uso.
