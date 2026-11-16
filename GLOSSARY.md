# Orb — Glossário de Domínio

Vocabulário compartilhado do produto e do código de colaboração entre agentes no Orb. Termos de interface mantêm caixa de sentença em português sem jargão técnico.

## Linguagem

**Orb**:
Agente pessoal permanente do usuário, com identidade, modelo, memória, pasta e rotinas próprias, listado na seção `Orbs` da barra lateral.
_Avoid_: Bot (em textos novos de domínio/interface), agente avulso

**Grupo**:
Conversa conjunta que reúne de 2 a 8 Orbs já existentes na lista pessoal do usuário, sob um orquestrador, listada na seção `Grupos` da barra lateral.
_Avoid_: Time, squad, sala

**Time**:
Unidade autônoma criada a partir de uma ideia para executar uma Missão completa em conjunto, listada em uma ala própria (`Times`) da barra lateral.
_Avoid_: Grupo, enxame, swarm, Modo Teams

**Integrante**:
Agente criado exclusivamente para compor um Time; existe apenas dentro dele (invisível na lista pessoal de Orbs) e é removido junto quando o Time é encerrado, salvo promoção explícita para Orb pessoal.
_Avoid_: Orb (quando se refere a agente exclusivo de um Time), subagente, worker

**Missão**:
Objetivo estruturado em etapas, contratos e critérios verificáveis de pronto que orienta a execução autônoma contínua de um Time até a conclusão ou pausa pelo usuário.
_Avoid_: Prompt do grupo, tarefa solta, sprint

**Olheiro**:
Agente preparatório cujo modelo é escolhido na tela da ideia para inspecionar o pedido e a pasta do projeto e gerar (e refinar em conversa) a proposta editável de composição do Time, seus Integrantes e a Missão inicial.
_Avoid_: Scouter, wizard, gerador genérico

**Portão de qualidade**:
Trava verificável no motor que impede o encerramento de uma etapa ou Missão sem evidência executada após a última edição e sem revisão independente aprovada contra os critérios de pronto.
_Avoid_: Checklist informal, prompt de revisão

**Quadro**:
Banco de memória compartilhada de um Grupo ou Time; em Times, mantém quatro blocos vivos sincronizados (Missão e critérios, etapas e donos, contratos e decisões, log de verificações).
_Avoid_: Contexto global, wiki, scratchpad

**Pulso**:
Agendador periódico em segundo plano que acorda planos ou grupos parados dentro de um teto diário de tokens.
_Avoid_: Loop contínuo de Time, cron
