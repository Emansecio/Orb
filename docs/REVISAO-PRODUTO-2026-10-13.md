# Melhorias e funcionalidades relevantes para o Orb — 13/10/2026

## Base e conclusão

Revisão estática do código e da documentação do checkout `a770a65`, incluindo as alterações locais já presentes. Nenhum dado pessoal, conversa real, provedor ou conector foi consultado. As recomendações abaixo são propostas; não foram implementadas nem validadas em uso real nesta revisão.

O Orb já tem ditado local, Quick Look, anexos com extração de texto, busca na conversa, paleta de comandos, rotinas com metas, execução única e cron, jobs visíveis, memória, skills, grupos e delegação. O maior ganho agora está em **encontrar resultados, acompanhar trabalho sem vigiar o chat e levar conteúdo do Mac até o Orb com menos passos**.

“Nativo” aqui significa tanto recursos próprios do Orb, integrados às suas permissões e persistência, quanto entradas e ações familiares no macOS. As propostas reutilizam a base SwiftUI/AppKit existente. Estimativas de esforço são relativas, não prazos.

## Ordem recomendada

| Ordem | Entrega | Ganho principal | Esforço relativo |
|---|---|---|---|
| 1 | Entregas por Orb | Encontrar o arquivo que o Orb fez, com a conversa de origem | Médio |
| 2 | Avisos de rotina por resultado | Saber quando algo falhou ou precisa de atenção | Pequeno para falhas; médio para resultados estruturados |
| 3 | Busca global local | Encontrar informação sem lembrar qual Orb a recebeu | Médio |
| 4 | Enviar ao Orb pelo Mac | Trabalhar sobre texto, arquivos e URLs sem copiar e alternar janelas | Médio; maior com extensão de compartilhamento |
| 5 | Exportação e restauração | Preservar e transportar o investimento em cada Orb | Médio a grande |
| 6 | Limites de uso para rotinas | Controlar consumo antes da próxima execução | Médio |
| 7 | Rotina disparada por arquivo | Agir quando chega algo novo, sem consultas periódicas ao modelo | Grande |

## 1. Entregas: uma lista persistente dos resultados

**Lacuna observada.** `ProducedFile` guarda caminho e indicação de novo/alterado, associado à ferramenta. O motor reconhece os destinos de `write_file` e `edit_file` e as imagens retornadas; arquivos gerados por comandos não entram nesse mecanismo. O painel de arquivos lista até oito alterações/recentes da pasta, o que ajuda a navegar, mas não constitui um histórico de entregas.

**Experiência proposta.** Uma aba **Entregas** no painel do Orb: arquivo, data, pedido de origem e ações de Quick Look, abrir, mostrar no Finder e arrastar. “A planilha que o Atlas fez ontem” deve estar ali mesmo que a conversa tenha milhares de mensagens. Incluir também os relatórios de rotina que o app já salva.

**MVP.** Indexar os arquivos que já são conhecidos pelo app e ligar cada entrada ao item da conversa ou à execução da rotina. Distinguir “arquivo alterado” de “entrega fixada”: nem todo arquivo intermediário de um build é um resultado útil. Permitir fixar e remover da lista sem apagar o arquivo.

**Etapa seguinte.** Dar ao Orb um modo explícito de registrar arquivos produzidos pelo Terminal. Conferir existência e resolver o caminho antes de exibir. Uma simples comparação da pasta não permite atribuir com certeza a autoria de uma alteração ao Orb.

**Aceitação.** Um resultado continua localizável após reiniciar; arquivo ausente aparece como ausente; abrir a origem leva ao turno correto; cadastrar uma entrega não aumenta o prompt de toda conversa.

Base: [ProducedFile](../Sources/Orb/AttachmentInfo.swift), [registro no motor](../Sources/Orb/Engine/AgentEngine.swift), [arquivos da pasta](../Sources/Orb/OrbFolder.swift), [relatórios de rotina](../Sources/Orb/AppModel.swift).

## 2. Rotinas que avisam pelo resultado

**Lacuna observada.** `BotSession.finishTurn` chama `notify` no ramo de sucesso. A falha de uma rotina fica no histórico e no aviso do chat, mas esse caminho não dispara o mesmo banner de término. No sucesso, a prévia da resposta pode gerar aviso mesmo quando a checagem não encontrou novidade. `Routine` não guarda uma política de notificação por resultado.

**Primeira entrega.** Avisar falha de rotina em segundo plano, identificando a rotina e levando à execução correspondente, respeitando a preferência atual de notificações. Deduplicar o aviso por execução. Preservar os cartões de aprovação existentes.

**Evolução.** No editor, oferecer **Avisar sempre**, **Só quando houver novidade ou precisar de mim** e **Só em falhas**. Registrar um resultado estruturado: sem novidade, houve mudança, precisa de atenção ou falhou. Quando possível, identificar novidade por IDs, datas ou hashes dos itens monitorados; comparar apenas a redação das respostas produz falsos alertas. Resultado ausente ou inválido não deve ser classificado silenciosamente como “sem novidade”.

**Exemplo.** A checagem de e-mails roda a cada 30 minutos e avisa ao chegar um item relevante; uma conexão recusada continua visível como falha.

**Aceitação.** Falha gera um único aviso; checagem sem novidade obedece à política escolhida; sucesso técnico e meta concluída permanecem estados distintos; o histórico continua disponível mesmo sem banner.

Base: [fim do turno](../Sources/Orb/BotSession+Turn.swift), [execução e término das rotinas](../Sources/Orb/AppModel.swift), [dados da rotina](../Sources/Orb/Models.swift).

## 3. Busca global, local e com origem

**Lacuna observada.** A busca atual encontra texto na conversa aberta. A paleta encontra Orbs, páginas, skills, rotinas e ações pelos seus metadados, mas não pesquisa o conteúdo de todas as conversas.

**Experiência proposta.** **Buscar no Orb** com resultados de todos os Orbs, conversas de rotinas, memórias e entregas; filtros por Orb, tipo e período. Cada resultado mostra trecho, autor/Orb, data e botão para abrir a origem.

**MVP.** Busca textual local, reaproveitando a normalização de acentos e maiúsculas. Começar pelas mensagens e relatórios; adicionar memórias e entregas depois. Não precisa de chamada ao modelo. Para históricos grandes, indexar mudanças incrementalmente em vez de reler todos os arquivos a cada tecla.

Essa busca é para o usuário: não deve dar automaticamente a um Orb acesso às memórias de outro.

**Aceitação.** Encontrar um trecho sem saber quem o disse; abrir a mensagem exata; excluir do índice conteúdo apagado; manter a interface responsiva com histórico grande.

Base: [motor de busca](../Sources/Orb/ConversationSearch.swift), [controle da busca](../Sources/Orb/ConversationFind.swift), [paleta](../Sources/Orb/Views/CommandPalette.swift).

## 4. “Enviar ao Orb” a partir do Mac

**Lacuna observada.** O app recebe arquivos por escolha, colagem e arraste. Já oferece pergunta rápida com atalho global. As ferramentas de Atalhos permitem que o Orb execute os atalhos do usuário; não encontrei uma entrada equivalente para um atalho do usuário solicitar trabalho ao Orb.

**Experiência proposta.** Selecionar texto ou arquivos, escolher **Enviar ao Orb**, escolher o assistente e ver o conteúdo preparado no compositor. Exemplos: revisar um trecho, resumir um PDF do Finder e analisar uma URL.

**MVP.** Uma entrada pelo menu Serviços para seleção e arquivos. Reutilizar o preparo de anexos e o compositor existentes. A seleção deve ser explícita e o conteúdo recebido deve aparecer antes do envio.

**Etapas seguintes.** Entrada no menu Compartilhar e ações no app Atalhos: **Preparar mensagem para Orb** e **Executar rotina existente**. Começar por preparar o pedido evita ter de definir já o retorno síncrono de uma tarefa longa. A extensão de compartilhamento exige trabalho adicional de empacotamento; o projeto atual tem um executável principal e um executável de testes.

**Aceitação.** Funciona com app fechado e aberto; não perde o rascunho anterior; um Orb ocupado usa a fila existente; recebe somente o conteúdo escolhido e conserva as permissões do Orb.

Base: [anexos](../Sources/Orb/AppModel+Attachments.swift), [pergunta rápida](../Sources/Orb/Views/QuickAskView.swift), [ferramentas de Atalhos](../Sources/Orb/Engine/Tools/MacAppTools.swift), [alvos do pacote](../Package.swift), [empacotamento](../scripts/bundle.sh).

## 5. Exportar e restaurar um Orb completo

**Lacuna observada.** Há importação de outros assistentes, preservação de memórias e cópias de arquivos corrompidos. Não encontrei um fluxo de exportação e restauração completa de um Orb na interface. Gravação atômica e recuperação de corrupção não substituem uma cópia recuperável após exclusão ou troca de Mac.

**Experiência proposta.** **Exportar Orb…** com perfil, aparência, memória, skills próprias, rotinas e conversas opcionais. Restaurar apresenta uma prévia e permite criar um novo Orb, sem sobrescrever o existente.

**MVP.** Pacote versionado com manifesto. Explicitar se os arquivos da pasta de trabalho estão incluídos: copiar automaticamente um repositório grande seria uma surpresa. Contas, chaves, tokens e cookies ficam fora; conectores precisam ser reconectados. Rotinas importadas começam pausadas e os acessos são revistos na restauração.

**Aceitação.** Exportar e restaurar reproduz o conteúdo selecionado; nenhum segredo entra no pacote; caminho que não existe no novo Mac pede remapeamento; formato incompatível não altera os dados existentes.

Base: [persistência e recuperação](../Sources/Orb/Store.swift), [importação](../Sources/Orb/Import/OrbImportReader.swift), [preservação no reset](../Sources/Orb/Reset/ResetPlan.swift).

## 6. Limite de consumo antes da próxima chamada

**Lacuna observada.** O registro de uso centraliza consumo, separa origens e alimenta o relatório de custos. Existem orçamentos de tokens em grupos e delegação; não encontrei um limite diário/mensal de custo por Orb ou rotina na tela de Uso.

**Experiência proposta.** Definir um teto estimado para rotinas e receber aviso ao aproximar-se dele. Ao atingir o limite, adiar a próxima execução e explicar o motivo no cartão da rotina.

**MVP.** Aplicar inicialmente a novas execuções automáticas. Depois, conferir o orçamento antes de cada nova chamada, incluindo as auxiliares. Com vários Orbs simultâneos, reservar margem para chamadas em andamento. Um limite baseado em uso reportado e preços estimados não garante uma fatura exata.

**Aceitação.** Não inicia novas chamadas após o bloqueio; registra o motivo; contabiliza auxiliares; diferencia API paga, plano e execução local; modelo sem preço aparece como consumo desconhecido, nunca como custo zero.

Base: [ponto central do registro](../Sources/Orb/Usage/AppModel+Usage.swift), [relatório de uso](../Sources/Orb/Views/UsageSettings.swift), [classificação de preços](../Sources/Orb/Usage/ModelPricing.swift).

## 7. Rotinas quando um arquivo chega

**Lacuna observada.** `Schedule` oferece disparos por tempo. Não há um disparo por entrada de arquivo na pasta escolhida.

**Experiência proposta.** “Quando chegar um PDF nesta pasta, peça ao Atlas para conferir e gerar o relatório.” O evento local dispara o trabalho, sem chamar o modelo repetidamente para perguntar se apareceu um arquivo.

**MVP.** Uma pasta escolhida, filtro por extensão e espera até o arquivo estabilizar. Processar por uma fila persistente, com deduplicação. Excluir os próprios resultados da rotina para evitar ciclos. Definir o que acontece com arquivos encontrados após reabrir o app.

**Aceitação.** Cópia incompleta não dispara análise; o mesmo arquivo não gera execuções simultâneas; reabrir não perde itens pendentes; pastas de saída não realimentam o disparo; fila obedece às permissões e aos limites de consumo.

É a proposta de maior complexidade desta lista. Deve vir depois dos estados de rotina e da identificação das entregas.

Base: [tipos de agendamento](../Sources/Orb/Models.swift), [fila e execução das rotinas](../Sources/Orb/AppModel.swift).

## Duas melhorias menores que acompanham essas entregas

- **Preservar anexos importantes.** Hoje arquivos comuns ficam referenciados pelo caminho original, enquanto imagens têm armazenamento próprio. Oferecer “Guardar cópia com a conversa” evita que mover ou apagar o original quebre a consulta futura. Distinguir cópia enviada de arquivo de trabalho vivo, com controle de espaço. Base: [anexos](../Sources/Orb/AppModel+Attachments.swift) e [texto anexado](../Sources/Orb/AttachmentText.swift).
- **Retomar após fechar o app.** Já existe continuação de tarefa pausada por limite de passos. Ao reabrir, uma tarefa interrompida é encerrada no histórico. Uma melhoria diferente é mostrar “Revisar e retomar” com o último passo confirmado; reconferir os efeitos antes de continuar, especialmente envio e publicação. Base: [encerramento de interrupções](../Sources/Orb/Models.swift) e [carregamento da conversa](../Sources/Orb/BotSession+Conversation.swift).

## Primeiro ciclo sugerido

Implementar **Entregas**, **aviso de falha de rotina** e **busca global de mensagens/relatórios**. São três resultados complementares: o usuário encontra o que foi feito, fica sabendo quando algo não terminou e recupera o contexto sem procurar Orb por Orb.

Avaliar com tarefas concretas: localizar uma planilha antiga; descobrir uma rotina que falhou em segundo plano; encontrar uma decisão sem saber em qual conversa está. Não há medição de frequência desses problemas nesta revisão; a priorização estima valor a partir dos fluxos e das lacunas observadas no código.
