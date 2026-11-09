package app.orb.android.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.foundation.layout.defaultMinSize
import kotlinx.coroutines.launch
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.orb.android.Bot
import app.orb.android.ChatUi
import app.orb.android.Item
import app.orb.android.Row as ChatRow
import app.orb.android.StreamState
import app.orb.android.Times
import com.mikepenz.markdown.m3.Markdown
import com.mikepenz.markdown.model.markdownDimens
import com.mikepenz.markdown.m3.markdownColor
import com.mikepenz.markdown.m3.markdownTypography
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

class ChatActions(
    val onBack: () -> Unit,
    val onSend: (String) -> Unit,
    val onStop: () -> Unit,
    /** approvalId, decision, reply, note */
    val onDecide: (String, String, String?, String?) -> Unit,
    /** Runs [onOk] after the device lock / biometrics, used before allowing a dangerous action. */
    val authenticate: (onOk: () -> Unit) -> Unit,
)

/** Newest first, because the list is reversed to stay glued to the bottom without manual scrolling. */
fun displayRows(chat: ChatUi): List<ChatRow> {
    val out = ArrayList<ChatRow>(chat.rows.size + chat.pending.size + 1)
    if (chat.working) out += ChatRow.Working(chat.status)
    val lastIsUser = chat.rows.lastOrNull() is ChatRow.User
    for (i in chat.pending.indices.reversed()) {
        val p = chat.pending[i]
        out += ChatRow.Pending(p.ref, p.text, p.sentOk, showLabel = i == 0 && !lastIsUser)
    }
    for (i in chat.rows.indices.reversed()) out += chat.rows[i]
    return out
}

@Composable
fun ChatScreen(
    bot: Bot,
    avatar: ImageBitmap?,
    chat: ChatUi?,
    stream: StateFlow<StreamState?>,
    restore: Flow<String>,
    actions: ChatActions,
    modifier: Modifier = Modifier,
    now: Long = System.currentTimeMillis(),
) {
    val display = remember(chat) { chat?.let(::displayRows).orEmpty() }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    var draft by rememberSaveable(bot.id) { mutableStateOf("") }
    LaunchedEffect(restore) {
        restore.collect { text -> draft = if (draft.isBlank()) text else "$text\n$draft" }
    }

    val atBottom by remember { derivedStateOf { listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset < 48 } }
    // "Follow" is true while the user is at the end; a manual scroll up turns it off until they come back.
    var follow by remember { mutableStateOf(true) }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress to atBottom }.collect { (scrolling, bottom) ->
            if (scrolling) follow = bottom else if (bottom) follow = true
        }
    }
    val newest = display.firstOrNull()?.key
    LaunchedEffect(newest) { if (follow && listState.firstVisibleItemIndex != 0) listState.animateScrollToItem(0) }

    Column(modifier.fillMaxSize().background(OrbColors.Canvas)) {
        ChatTopBar(bot, avatar, actions.onBack)
        Box(Modifier.weight(1f).fillMaxWidth()) {
            if (chat == null || !chat.loaded && display.isEmpty()) {
                Text(
                    "Abrindo a conversa…", color = OrbColors.Faint, fontSize = 14.sp, textAlign = TextAlign.Center,
                    modifier = Modifier.align(Alignment.Center),
                )
            }
            LazyColumn(
                state = listState,
                reverseLayout = true,
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.Top),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(display, key = { it.key }, contentType = { it::class }) { row ->
                    Box(Modifier.animateItem()) {
                        RowContent(row, bot, avatar, stream, chat?.submitted.orEmpty(), actions, now)
                    }
                }
            }
            ScrollToEnd(!atBottom, Modifier.align(Alignment.BottomEnd).padding(end = 16.dp, bottom = 8.dp)) {
                follow = true
                scope.launch { listState.animateScrollToItem(0) }
            }
        }
        Composer(bot.name, draft, { draft = it }, onSend = {
            val t = draft.trim()
            if (t.isNotEmpty()) { draft = ""; actions.onSend(t) }
        })
    }
}

@Composable
private fun ScrollToEnd(visible: Boolean, modifier: Modifier, onClick: () -> Unit) {
    AnimatedVisibility(visible, modifier, enter = fadeIn(tween(150)), exit = fadeOut(tween(150))) {
        Box(
            Modifier.size(44.dp).background(OrbColors.Raised, CircleShape).clickable(onClick = onClick)
                .semantics { contentDescription = "Ir para o fim da conversa" },
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Filled.ArrowDownward, null, tint = OrbColors.Ink, modifier = Modifier.size(20.dp)) }
    }
}

@Composable
private fun ChatTopBar(bot: Bot, avatar: ImageBitmap?, onBack: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().statusBarsPadding().padding(start = 4.dp, end = 16.dp, top = 4.dp, bottom = 6.dp)
            .background(OrbColors.Canvas),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onBack, Modifier.size(48.dp)) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Voltar", tint = OrbColors.Ink) }
        OrbAvatar(bot, avatar, 36.dp)
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f)) {
            Text(bot.name, color = OrbColors.Ink, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            when {
                bot.needsYou -> Text("Precisa de você", color = OrbColors.Warn, fontSize = 13.sp, maxLines = 1)
                bot.working -> Text(
                    bot.status?.takeIf { it.isNotBlank() } ?: "Trabalhando…", color = OrbColors.Muted, fontSize = 13.sp,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.shimmer(),
                )
                !bot.role.isNullOrBlank() -> Text(bot.role, color = OrbColors.Faint, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun RowContent(
    row: ChatRow,
    bot: Bot,
    avatar: ImageBitmap?,
    stream: StateFlow<StreamState?>,
    submitted: Set<String>,
    actions: ChatActions,
    now: Long,
) {
    when (row) {
        is ChatRow.Date -> Text(
            Times.separator(row.millis, now), color = OrbColors.Faint, fontSize = 12.sp, textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
        )
        is ChatRow.User -> UserBubble(row.item.text, row.showLabel, 1f)
        is ChatRow.Pending -> UserBubble(row.text, row.showLabel, if (row.confirmed) 1f else 0.6f)
        is ChatRow.BotText -> BotMessage(row.item, row.showAvatar, bot, avatar, stream)
        is ChatRow.Tools -> ToolsGroup(row)
        is ChatRow.Approval -> ApprovalRowContent(row.item, submitted, actions, Modifier.padding(start = 40.dp))
        is ChatRow.Note -> Text(
            row.item.text, color = OrbColors.Faint, fontSize = 12.sp, textAlign = TextAlign.Center, lineHeight = 16.sp,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 2.dp),
        )
        is ChatRow.Working -> WorkingLine(row.status, actions.onStop)
    }
}

@Composable
private fun UserBubble(text: String, showLabel: Boolean, alpha: Float) {
    Column(Modifier.fillMaxWidth().alpha(alpha), horizontalAlignment = Alignment.End) {
        if (showLabel) {
            Text("Você", color = OrbColors.Faint, fontSize = 12.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(end = 4.dp, bottom = 4.dp))
        }
        BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            SelectionContainer {
                Text(
                    text, color = OrbColors.Ink, fontSize = 16.sp, lineHeight = 22.sp,
                    modifier = Modifier.widthIn(max = maxWidth * 0.85f)
                        .background(OrbColors.UserBubble, RoundedCornerShape(18.dp))
                        .padding(horizontal = 14.dp, vertical = 9.dp),
                )
            }
        }
    }
}

@Composable
private fun BotMessage(item: Item, showAvatar: Boolean, bot: Bot, avatar: ImageBitmap?, stream: StateFlow<StreamState?>) {
    // Only the item that is still being written subscribes to the stream, so other rows never recompose on a frame.
    val live = if (item.streaming) stream.collectAsState().value?.takeIf { it.item == item.id }?.text else null
    val text = live ?: item.text
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        if (showAvatar) OrbAvatar(bot, avatar, 28.dp) else Spacer(Modifier.size(28.dp))
        Column(Modifier.weight(1f).animateContentSize(tween(150))) {
            SelectionContainer { MarkdownText(text) }
            AnimatedVisibility(item.streaming, enter = fadeIn(), exit = fadeOut(tween(120)) + shrinkVertically(tween(150))) {
                Cursor()
            }
        }
    }
}

@Composable
private fun Cursor() {
    val reduce = LocalReduceMotion.current
    val a = if (reduce) 1f else {
        val t = rememberInfiniteTransition(label = "cursor")
        val v by t.animateFloat(0.15f, 1f, infiniteRepeatable(tween(700), RepeatMode.Reverse), label = "a")
        v
    }
    Box(Modifier.padding(top = 4.dp).size(width = 8.dp, height = 16.dp).alpha(a).background(OrbColors.InkSecondary, RoundedCornerShape(2.dp)))
}

@Composable
fun MarkdownText(text: String, modifier: Modifier = Modifier) {
    val colors = markdownColor(
        text = OrbColors.Ink,
        codeText = OrbColors.Ink,
        inlineCodeText = OrbColors.Ink,
        linkText = OrbColors.Link,
        codeBackground = OrbColors.Raised,
        inlineCodeBackground = OrbColors.Raised,
        dividerColor = OrbColors.LineStrong,
        tableText = OrbColors.Ink,
        tableBackground = OrbColors.Surface,
    )
    val body = TextStyle(color = OrbColors.Ink, fontSize = 16.sp, lineHeight = 23.sp)
    val typography = markdownTypography(
        text = body,
        paragraph = body,
        h1 = body.copy(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.SemiBold),
        h2 = body.copy(fontSize = 20.sp, lineHeight = 26.sp, fontWeight = FontWeight.SemiBold),
        h3 = body.copy(fontSize = 18.sp, lineHeight = 24.sp, fontWeight = FontWeight.SemiBold),
        h4 = body.copy(fontWeight = FontWeight.SemiBold),
        h5 = body.copy(fontWeight = FontWeight.SemiBold),
        h6 = body.copy(fontWeight = FontWeight.SemiBold),
        code = body.copy(fontSize = 13.sp, lineHeight = 19.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace),
        inlineCode = body.copy(fontSize = 14.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace),
    )
    // The library memoizes the parse by content, so a recomposition with the same text costs nothing.
    Markdown(
        content = text, colors = colors, typography = typography, modifier = modifier,
        // Narrow cells so a typical 3-column table fits a phone; wider ones scroll sideways.
        dimens = markdownDimens(tableCellWidth = 96.dp, tableCellPadding = 10.dp),
    )
}

@Composable
private fun WorkingLine(status: String?, onStop: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(start = 40.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(
            "● ${status?.takeIf { it.isNotBlank() } ?: "Trabalhando…"}", color = OrbColors.Muted, fontSize = 14.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).shimmer(),
        )
        IconButton(onStop, Modifier.size(48.dp)) {
            Box(Modifier.size(28.dp).background(OrbColors.Raised, CircleShape), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Stop, "Parar", tint = OrbColors.Ink, modifier = Modifier.size(16.dp))
            }
        }
    }
}

@Composable
private fun Composer(name: String, value: String, onChange: (String) -> Unit, onSend: () -> Unit) {
    val canSend = value.isNotBlank()
    Row(
        Modifier.fillMaxWidth().navigationBarsPadding().imePadding().padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        Row(
            Modifier.weight(1f).background(OrbColors.Surface, RoundedCornerShape(26.dp)).padding(start = 18.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            Box(Modifier.weight(1f).defaultMinSize(minHeight = 40.dp), contentAlignment = Alignment.CenterStart) {
                if (value.isEmpty()) Text("Pergunte ao $name", color = OrbColors.Hint, fontSize = 16.sp, maxLines = 1)
                BasicTextField(
                    value = value, onValueChange = onChange,
                    textStyle = TextStyle(color = OrbColors.Ink, fontSize = 16.sp, lineHeight = 22.sp),
                    cursorBrush = SolidColor(OrbColors.Ink),
                    maxLines = 6,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Box(
                Modifier.size(40.dp).alpha(if (canSend) 1f else 0.3f).background(Color.White, CircleShape)
                    .clickable(enabled = canSend, onClick = onSend),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.ArrowUpward, "Enviar", tint = OrbColors.OnPrimary, modifier = Modifier.size(22.dp)) }
        }
    }
}
