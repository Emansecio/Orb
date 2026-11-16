# 0003. Portões programáticos de evidência e revisão independente em Times

- Status: accepted

Decidimos impor no motor de **Times** portões verificáveis de qualidade em vez de confiar apenas em instruções no prompt ou em aprovações manuais a cada etapa: nenhuma etapa é encerrada sem evidência executada após a última alteração de código/arquivo, toda revisão exige um Integrante distinto do autor com checklist por critério de pronto, e a Missão só conclui após auditoria final do conjunto integrado.

Deixar o rigor apenas no texto do prompt — como o limite simples de até três rodadas nos Grupos atuais — permite que modelos declarem conclusão prematura após edições finais ou aprovem trabalho com regressões; por outro lado, exigir aprovação humana a cada etapa quebraria a autonomia contínua. Os portões programáticos preservam o avanço autônomo enquanto forçam o ciclo construir → testar → revisar → integrar até haver prova real de conformidade.
