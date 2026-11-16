# 0004. Integrantes armazenados com escopo do Time fora da lista global de Orbs

- Status: accepted

Decidimos armazenar cada **Integrante** com escopo exclusivo dentro do respectivo **Time** (em coleção própria separada de `AppState.bots`), em vez de gravar Integrantes em `AppState.bots` marcados por uma flag de pertencimento e filtrá-los na interface.

Se ficassem em `AppState.bots`, toda a suíte de regras pessoais — unicidade global de nomes (`AppModel.isOrbNameTaken`), categorias da lateral, `Início`, `Uso`, sugestões de delegação entre Orbs pessoais (`MultiOrbOffering`) e contagem de Orbs — teria de filtrar casos especiais em dezenas de pontos, e dois Times paralelos não poderiam repetir nomes funcionais como `"Revisor"` ou `"Executor"`. Isolar o armazenamento pelo ciclo de vida do Time simplifica remoção conjunta, evita vazamento acidental na lista pessoal e reserva `AppModel.isOrbNameTaken` apenas para o momento explícito de promoção de um Integrante para Orb pessoal. A troca posterior exigiria migração dos arquivos de estado e das pastas de sessão.
