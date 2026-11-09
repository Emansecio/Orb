# Orb no celular

O app Android (`android/`) mostra os Orbs do Mac, abre a conversa de cada um, manda mensagens, acompanha a resposta ao vivo,
para um turno e responde aos pedidos de permissão e às perguntas. O Mac continua fazendo todo o trabalho: o celular é só uma
janela para ele.

## Como o celular chega ao Mac

Pelo **Tailscale** (gratuito para uso pessoal): o Mac e o celular entram na mesma rede privada, criptografada pelo WireGuard,
sem abrir porta no roteador. O Orb escuta numa porta TCP (`47821`) e só aceita conexões vindas de endereços do Tailscale
(`100.64.0.0/10` e `fd7a:115c:a1e0::/48`) e do próprio Mac (loopback, para testes). Qualquer outro endereço é recusado antes de
ler um byte.

Ligar: Ajustes → Celular → "Acessar pelo celular". Desligado (o padrão), o Orb não abre porta nenhuma.

## Pareamento

O Mac gera um token aleatório de 32 bytes (base64url, 43 caracteres), guardado no Keychain, e mostra um QR code com o link:

```
orb://parear?host=100.101.102.103&port=47821&token=<token>&mac=<nome do Mac>
```

`host` é o endereço do Mac no Tailscale (o primeiro IPv4 da faixa `100.64.0.0/10` entre as interfaces), ou o nome MagicDNS
quando houver. O celular lê o QR (ou recebe o link colado) e guarda host, porta, token e nome. "Gerar novo código" troca o
token e derruba os celulares pareados com o antigo.

## Protocolo

WebSocket em `ws://<host>:<port>/`, quadros de texto com um objeto JSON cada, sempre com `"type"`. Datas em milissegundos
desde 1970 (número). Ids são UUIDs em texto. Versão do protocolo: `1`. Campos desconhecidos são ignorados dos dois lados;
um campo opcional ausente vale `null`.

### Do celular para o Mac

| `type` | Campos | O que faz |
| --- | --- | --- |
| `hello` | `token`, `device` (nome do aparelho), `protocol` | Primeiro quadro, em até 10 s. Token errado: `error` `unauthorized` e a conexão fecha. |
| `open` | `bot` | Passa a acompanhar a conversa desse Orb (uma por vez; outro `open` troca). Resposta: `chat` e, enquanto houver resposta em andamento, `stream`. Enquanto aberta, o que chega nela não conta como não lido no Mac. |
| `close` | | Deixa de acompanhar a conversa (voltou para a lista ou o app foi para o segundo plano). |
| `send` | `bot`, `text`, `ref` (UUID do celular) | Manda uma mensagem. Com o Orb livre, começa um turno; trabalhando, entra na tarefa como no painel rápido do Mac. Resposta: `sent`. |
| `decide` | `bot`, `approval` (o `id` do `Item` do cartão), `decision` (`once`, `task`, `always`, `deny`), `reply?`, `note?` | Responde a um cartão. `reply` é a resposta a uma pergunta (com `once`); `note`, o que fazer em vez disso (com `deny`). |
| `stop` | `bot` | Para o turno do Orb (o "Parar" do Mac). |
| `avatar` | `bot` | Pede a imagem do Orb. Resposta: `avatar`. |
| `ping` | | Resposta: `pong`. |

### Do Mac para o celular

| `type` | Campos | Quando |
| --- | --- | --- |
| `welcome` | `mac` (nome), `protocol` | Depois de um `hello` válido, seguido de `bots`. |
| `bots` | `bots`: lista de `Bot`, na ordem da lateral | Sempre que algo de algum Orb muda (no máximo a cada 300 ms). |
| `chat` | `bot`, `items`: os últimos 80 `Item` (mais os cartões abertos fora deles), `working`, `status?` | No `open` e a cada mudança da conversa aberta (no máximo a cada 150 ms). |
| `stream` | `bot`, `item`, `text` (o texto inteiro até agora) | Enquanto a resposta é escrita (no máximo a cada 150 ms). Quando ela termina, o `chat` seguinte traz o texto final. |
| `sent` | `ref`, `ok`, `queued`, `note?` | Resposta ao `send`. `ok: false` traz em `note` o motivo, para mostrar ao usuário. |
| `avatar` | `bot`, `hash`, `png` (base64, 256×256) | Resposta ao pedido. |
| `pong` | | |
| `error` | `code`, `message` | `unauthorized`, `bad_request`, `unknown_bot`, `too_large`. |

### `Bot`

```json
{
  "id": "…", "name": "Atlas", "role": "Assistente do seu Mac",
  "avatar": "9f2c…",          // muda quando a aparência muda: peça `avatar` de novo
  "color": "#5B5BF0",         // cor principal do Orb, para detalhes da interface
  "working": true,            // há um turno rodando
  "needsYou": false,          // há um cartão esperando resposta
  "status": "Lendo package.json", // o que ele está fazendo agora (null quando parado)
  "unread": 2,                // respostas que chegaram sem você ver
  "last": { "text": "Pronto: separei 214 arquivos…", "date": 1762700000000 }, // ou null
  "card": { …Item de kind "approval"… } // o cartão aberto mais novo, só com needsYou; senão null
}
```

### `Item`

```json
{ "id": "…", "date": 1762700000000, "kind": "user" | "bot" | "tool" | "approval" | "notice" | "event" | "orb", "text": "…" }
```

- `user`: sua mensagem. `bot`: resposta do Orb em Markdown; `streaming: true` enquanto é escrita (o texto vivo vem por `stream`).
- `tool`: uma ação. `tool`: `{ "kind": "shell"|"browser"|"file"|"search"|"computer"|"connector"|"memory"|"schedule"|"orbs"|"plan", "title", "detail", "state": "running"|"done"|"failed" }`.
  O `text` é a frase curta da ação. Ações seguidas se juntam numa linha ("3 ações") que abre.
- `approval`: um cartão. `approval`:
  ```json
  { "kind": "permission" | "question" | "handoff" | "proposal" | "access",
    "title": "Rodando no Terminal", "command": "brew upgrade", "reason": "…",
    "decision": null | "once" | "task" | "always" | "deny" | "review",
    "dangerous": false, "canAlways": true, "count": 1,
    "question": { "text": "…", "options": ["…"], "multiple": false } | null }
  ```
  Pelo celular: `permission` aceita `once`, `task`, `always` (só com `canAlways`) e `deny`; com `dangerous`, o app pede a
  digital ou a senha do aparelho antes de permitir. `question` aceita `once` com `reply` (uma opção ou texto livre) e `deny`
  (pular). `handoff`, `proposal` e `access` só aceitam `deny` pelo celular; o resto é no Mac.
- `notice`, `event`, `orb`: avisos, acontecimentos e mensagens entre Orbs, em uma linha.

## Segurança

- Só Tailscale e loopback; token comparado em tempo constante; mais de 5 `hello` errados em um minuto vindos do mesmo endereço
  fecham as conexões seguintes dele por um minuto.
- Quadros de entrada acima de 64 KB são recusados (`too_large`); mensagens acima de 20.000 caracteres também.
- O token nunca vai para log nem para a tela depois do pareamento. O QR só aparece enquanto Ajustes → Celular está aberto.
- Se o Keychain não deixa ler o código, o Orb mostra o erro e não gera outro sozinho; gerar um novo é uma ação da pessoa
  (Ajustes → Celular → Gerar novo código).
- Se o servidor para, ele tenta de novo com espera de 2 s a 60 s e também ao acordar o Mac.
