# Orb para Android

Controle os Orbs do seu Mac pelo celular: veja quem está trabalhando, leia as respostas, mande mensagens, pare um turno e
responda a pedidos de permissão e perguntas. O Mac faz todo o trabalho; o celular é só uma janela. O protocolo está em
[`docs/CELULAR.md`](../docs/CELULAR.md).

## Instalar o app

1. Copie `build/Orb-celular.apk` (na raiz do repositório) para o celular, por cabo, Drive ou AirDrop equivalente.
2. Abra o arquivo no celular e permita "instalar apps desconhecidos" para o app que você usou para abri-lo.
3. Android 8 (API 26) ou mais novo.

Para gerar o APK: `cd android && ./gradlew assembleRelease` (JDK 17). O APK sai em `app/build/outputs/apk/release/`.
Se existir `~/.android/orb-release.properties`, o release é assinado com a chave de `~/.android/orb-release.jks`; sem
ele, sai assinado com a chave de debug, que também instala.

## Tailscale (Mac e celular)

O celular chega ao Mac pelo Tailscale, gratuito para uso pessoal, sem abrir porta no roteador.

1. Instale o Tailscale no Mac e no celular e entre **na mesma conta** nos dois.
2. No Mac, abra o Orb → Ajustes → Celular e ligue "Acessar pelo celular".

## Parear e usar

1. No Mac, em Ajustes → Celular, aparece um QR code.
2. No celular, abra o Orb e toque em "Ler QR code" (não pede permissão de câmera). Se preferir, toque em "Colar link" e
   cole o link `orb://parear?...`.
3. A lista mostra os seus Orbs. No topo ficam os que estão trabalhando ou precisando de você. Toque num Orb para abrir a
   conversa.
4. Na conversa: escreva em "Pergunte ao <nome>", toque no quadrado para parar um turno, e responda aos cartões de
   permissão ("Permitir", "Só nesta tarefa", "Sempre permitir", "Não permitir"). Ações arriscadas pedem a digital ou a senha
   do celular.
5. Com "Manter conectado em segundo plano" ligado (Ajustes, na engrenagem), o app avisa quando um Orb precisa de você ou
   termina uma resposta. Se o código for trocado no Mac ("Gerar novo código"), o app volta ao pareamento.

Sem conexão, uma faixa no topo avisa e tem o botão "Abrir o Tailscale".

## Desenvolvimento

- `./gradlew testDebugUnitTest`: testes JVM (link de pareamento, quadros, agrupamento de ações, notificações, backoff) e
  renderização das telas com Paparazzi em 411 dp e 360 dp.
- `./gradlew recordPaparazziDebug`: regrava as capturas em `app/src/test/snapshots/` (ignorada pelo git); as versões
  publicadas estão em `docs/capturas/`.
- `compileSdk` é 35 porque o Paparazzi 1.3.5 não conhece o 36; `targetSdk` continua 36.
