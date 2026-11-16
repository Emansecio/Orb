# 0001. Times como entidade irmã de Grupos sobre a infraestrutura existente

- Status: accepted

Decidimos manter **Grupos** (`OrbGroup`) intacto para a reunião manual de Orbs pessoais já existentes e construir **Times** como uma entidade irmã em sua própria ala da barra lateral, reaproveitando `GroupHub`, `GroupBoard` e o isolamento em worktrees git (`WorkFolders`).

Substituir Grupos por Times removeria um fluxo já usado para conversas pontuais entre Orbs permanentes e violaria a preservação de recursos existentes, enquanto construir um motor paralelo do zero duplicaria mensageria, persistência de fio, memória compartilhada e merge de worktrees. A extensão irmã evita essa duplicação mantendo a separação clara de ciclo de vida: Orbs de um Grupo continuam independentes, enquanto Integrantes de um Time nascem de uma proposta e só existem dentro dele.
