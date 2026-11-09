package app.orb.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.cash.paparazzi.DeviceConfig
import com.android.resources.Density
import app.cash.paparazzi.Paparazzi
import app.orb.android.ui.BotListScreen
import app.orb.android.ui.ChatActions
import app.orb.android.ui.ChatScreen
import app.orb.android.ui.ConnectionBanner
import app.orb.android.ui.OrbColors
import app.orb.android.ui.OrbTheme
import app.orb.android.ui.PairingScreen
import app.orb.android.ui.SettingsScreen
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import org.junit.Rule
import org.junit.Test

private const val T0 = 1_762_983_180_000L // fixed instant so relative labels render the same every run

private fun it(id: String, kind: String, min: Int, text: String = "", tool: ToolInfo? = null, approval: ApprovalInfo? = null, streaming: Boolean = false) =
    Item(id, T0 + min * 60_000L, kind, text, streaming, tool, approval)

private val bots = listOf(
    Bot("a", "Atlas", "Assistente do seu Mac", "h1", "#5B5BF0", working = true, status = "Lendo package.json", unread = 0,
        last = LastMessage("Pronto: separei 214 arquivos em pastas por tipo.", T0)),
    Bot("b", "Lia", "Pesquisa e resume", "h2", "#E8508F", needsYou = true, card = Item("p1", T0, "approval", "Rodando no Terminal", approval = ApprovalInfo("permission", "Rodando no Terminal", "brew upgrade", canAlways = true)), status = "Rodando no Terminal", unread = 1,
        last = LastMessage("Preciso rodar um comando.", T0 - 3_600_000)),
    Bot("c", "Bento", "Cuida das finanças da casa", "h3", "#2FB36D", unread = 0,
        last = LastMessage("Feito: 43 arquivos foram para a Lixeira e você ganhou 7,2 GB.", T0 - 86_400_000 * 1)),
    Bot("d", "Atendente", "Responde clientes no WhatsApp", "h4", "#3FA7F5", unread = 3,
        last = LastMessage("Cliente perguntou sobre o prazo de entrega do pedido 4821.", T0 - 7_200_000)),
    Bot("e", "Revisor", "Revisa textos antes de publicar", "h5", "#8A8F98", unread = 0,
        last = LastMessage("Tudo certo no texto da página de vendas.", T0 - 86_400_000 * 3)),
)

private val markdown = """
Pronto: separei **214 arquivos** em pastas por tipo. Nada foi apagado.

| Pasta | Arquivos | Tamanho |
| --- | ---: | ---: |
| Documentos | 86 | 1,2 GB |
| Imagens | 97 | 3,4 GB |
| Instaladores | 31 | 6,8 GB |

## Dá para apagar sem medo

- 31 instaladores `.dmg` de apps que já estão instalados (6,8 GB)
- 12 fotos repetidas, iguais *byte a byte* (410 MB)

```sh
trash ~/Downloads/Instaladores/*.dmg
```

Quer que eu mande esses para a Lixeira? Veja o [guia](https://example.com).
""".trimIndent()

private fun tools(vararg states: String) = states.mapIndexed { i, s ->
    it("t$i", "tool", 1, "Rodou comando $i", ToolInfo("shell", "ls -la ~/Downloads", "ls -la ~/Downloads\ntotal 4096", s))
}

private val base = listOf(
    it("u1", "user", 0, "Organiza a minha pasta de Downloads e me diz o que dá para apagar"),
) + tools("done", "done", "done") + listOf(
    it("b1", "bot", 2, markdown),
    it("u2", "user", 3, "Pode mandar"),
)

private val permission = ApprovalInfo("permission", "Rodando no Terminal", "brew upgrade", "O Atlas quer atualizar os apps do Homebrew.", canAlways = true)
private val dangerous = ApprovalInfo("permission", "Apagar arquivos", "rm -rf ~/Downloads/Antigos", "Remove 214 arquivos de forma definitiva.", dangerous = true)
private val question = ApprovalInfo(
    "question", "Pergunta do Atlas", null, null,
    question = QuestionInfo("Em qual pasta guardo os recibos?", listOf("Documentos", "Finanças", "Área de trabalho"), false),
)

private val noActions = ChatActions({}, {}, {}, { _, _, _, _ -> }, { it() })

abstract class Scenes(config: DeviceConfig, private val tag: String) {
    @get:Rule val paparazzi = Paparazzi(deviceConfig = config, theme = "android:Theme.Material.NoActionBar", showSystemUi = false)

    private fun shot(name: String, content: @Composable () -> Unit) =
        paparazzi.snapshot("$tag-$name") { OrbTheme { Box(Modifier.fillMaxSize().background(OrbColors.Canvas).padding(top = 28.dp, bottom = 16.dp)) { content() } } }

    private fun chat(items: List<Item>, working: Boolean = false, status: String? = null, pending: List<PendingMsg> = emptyList()) =
        ChatUi("a", Rows.build(items), working, status, true, pending)


    @Test fun lista() = shot("lista") {
        BotListScreen(bots, emptyMap(), "MacBook do Thiago", true, {}, {}, now = T0 + 600_000)
    }

    @Test fun listaSemConexao() = shot("lista-sem-conexao") {
        androidx.compose.foundation.layout.Column {
            ConnectionBanner(Conn.Offline, true)
            BotListScreen(bots, emptyMap(), "MacBook do Thiago", true, {}, {}, now = T0 + 600_000)
        }
    }

    @Test fun conversaMarkdown() = shot("conversa-markdown") {
        ChatScreen(bots[0], null, chat(base), MutableStateFlow(null), emptyFlow(), noActions, now = T0 + 600_000)
    }

    @Test fun conversaPermissao() = shot("conversa-permissao") {
        val items = listOf(
            it("u1", "user", 0, "Atualiza os apps do Homebrew"),
            it("b1", "bot", 1, "Vou atualizar tudo de uma vez; preciso da sua permissão para rodar o comando."),
            it("p1", "approval", 1, "Rodando no Terminal", approval = permission),
        )
        ChatScreen(bots[1], null, chat(items), MutableStateFlow(null), emptyFlow(), noActions, now = T0 + 600_000)
    }

    @Test fun conversaArriscada() = shot("conversa-arriscada") {
        val items = listOf(
            it("u1", "user", 0, "Limpa os arquivos antigos"),
            it("p1", "approval", 1, "Apagar arquivos", approval = dangerous),
            it("p0", "approval", 0, "Antes", approval = permission.copy(decision = "once")),
        )
        ChatScreen(bots[1], null, chat(items), MutableStateFlow(null), emptyFlow(), noActions, now = T0 + 600_000)
    }

    @Test fun conversaPergunta() = shot("conversa-pergunta") {
        val items = listOf(
            it("u1", "user", 0, "Guarda esse recibo"),
            it("p1", "approval", 1, "Pergunta", approval = question),
        )
        ChatScreen(bots[0], null, chat(items), MutableStateFlow(null), emptyFlow(), noActions, now = T0 + 600_000)
    }

    @Test fun conversaEmAndamento() = shot("conversa-andamento") {
        val items = listOf(
            it("u1", "user", 0, "Resume o PDF do contrato"),
            it("t1", "tool", 1, "Leu contrato.pdf", ToolInfo("file", "Ler contrato.pdf", null, "done")),
            it("t2", "tool", 1, "Buscando na web", ToolInfo("search", "Pesquisar cláusula de rescisão", null, "running")),
            it("t3", "tool", 1, "Falhou ao abrir", ToolInfo("browser", "Abrir site", "timeout", "failed")),
            it("b1", "bot", 2, "O contrato tem **12 cláusulas**. A mais importante é a de rescisão, que exige aviso de", streaming = true),
            it("n1", "notice", 2, "Atlas usou o navegador"),
        )
        ChatScreen(
            bots[0], null, chat(items, working = true, status = "Escrevendo a resposta", pending = listOf(PendingMsg("r", "E o prazo de aviso?", false, 0))),
            MutableStateFlow(StreamState("a", "b1", "O contrato tem **12 cláusulas**. A mais importante é a de rescisão, que exige aviso de 30 dias.")),
            emptyFlow(), noActions, now = T0 + 600_000,
        )
    }

    @Test fun pareamento() = shot("pareamento") { PairingScreen(null, null, {}, {}) }

    @Test fun pareamentoAviso() = shot("pareamento-aviso") {
        PairingScreen("O código deste celular foi trocado no Mac. Pareie de novo.", "O código do link é inválido.", {}, {}, startWithLink = true)
    }

    @Test fun ajustes() = shot("ajustes") { SettingsScreen("MacBook do Thiago", "100.101.102.103:47821", true, {}, {}, {}) }
}

// Only stock densities are supported by layoutlib, so widths are chosen in pixels at xxhdpi (3 px per dp).
class PhoneScenes : Scenes(DeviceConfig.PIXEL_5.copy(screenWidth = 1233, screenHeight = 2700, xdpi = 480, ydpi = 480, density = Density.XXHIGH), "411")
class SmallPhoneScenes : Scenes(DeviceConfig.PIXEL_5.copy(screenWidth = 1080, screenHeight = 1920, xdpi = 480, ydpi = 480, density = Density.XXHIGH), "360")
