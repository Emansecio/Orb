# 0002. Execução contínua sem teto automático e recuperação autônoma de impasses

- Status: accepted

Decidimos que um **Time** executa sua Missão continuamente em segundo plano sem teto automático de turnos ou tokens por execução (parando apenas ao concluir todos os critérios, por pausa explícita do usuário ou por bloqueio físico externo impossível de contornar) e opera por padrão no modo **Sem pedir permissão** (`.bypass`).

Essa escolha contrasta com os Orbs individuais (cujo padrão é perguntar antes) e com o Pulso (limitado por teto diário de tokens), mas atende à natureza autônoma de um Time trabalhando em paralelo até o fim sem interromper o fluxo por confirmações. Para evitar ciclos infinitos ou desperdício cego quando surgir um erro ou loop, o motor passa a detectar estagnação (repetição da mesma assinatura de erro ou ausência de progresso verificável) e injeta recuperação autônoma — forçando o Integrante ou o líder a trocar de abordagem, acionar outro especialista ou replanejar a etapa. A reversão posterior dessa política exigiria introduzir orçamentos por Time, mas deixaria de atender ao comportamento contínuo desejado.
