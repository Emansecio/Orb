package app.orb.android.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.PredictiveBackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.orb.android.Bot
import app.orb.android.ChatUi
import app.orb.android.ConnectionService
import app.orb.android.OrbRepository
import app.orb.android.Pairing
import app.orb.android.PairingException
import app.orb.android.PairingLink
import app.orb.android.UiEvent
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.CancellationException

@Composable
fun OrbRoot(
    repo: OrbRepository,
    externalLink: String?,
    onExternalLinkHandled: () -> Unit,
    onScan: ((String) -> Unit, (String) -> Unit) -> Unit,
    authenticate: (onOk: () -> Unit) -> Unit,
) {
    val ctx = LocalContext.current
    val s by repo.state.collectAsStateWithLifecycle()
    val chat by repo.chat.collectAsStateWithLifecycle()
    var settingsOpen by remember { mutableStateOf(false) }
    var pairError by remember { mutableStateOf<String?>(null) }
    var confirmLink by remember { mutableStateOf<Pairing?>(null) }
    val snack = remember { SnackbarHostState() }
    val paired = s.pairing != null

    fun tryPair(raw: String, confirm: Boolean) {
        try {
            val p = PairingLink.parse(raw)
            pairError = null
            if (confirm) confirmLink = p else repo.pair(p)
        } catch (e: PairingException) {
            pairError = e.message
        }
    }

    LaunchedEffect(externalLink) {
        if (externalLink != null) { tryPair(externalLink, confirm = true); onExternalLinkHandled() }
    }
    LaunchedEffect(Unit) {
        repo.events.collect { e ->
            when (e) {
                is UiEvent.Message -> snack.showSnackbar(e.text)
                is UiEvent.RestoreText -> snack.showSnackbar(e.note)
            }
        }
    }

    // Background connection: a foreground service while paired and enabled, plus the notification permission.
    LaunchedEffect(paired, s.keepAlive) {
        if (paired && s.keepAlive) ConnectionService.start(ctx) else ConnectionService.stop(ctx)
    }
    val askNotifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    LaunchedEffect(paired) {
        if (paired && Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    if (!paired) {
        PairingScreen(
            notice = s.notice, error = pairError,
            onScan = { onScan({ tryPair(it, confirm = false) }, { pairError = it }) },
            onLink = { tryPair(it, confirm = false) },
        )
    } else {
        val bannerVisible = s.conn == app.orb.android.Conn.Offline
        Box(Modifier.fillMaxSize().background(OrbColors.Chrome)) {
            Column(Modifier.fillMaxSize()) {
                if (bannerVisible) ConnectionBanner(s.conn, true, Modifier.statusBarsPadding())
                Box(Modifier.weight(1f).then(if (bannerVisible) Modifier.consumeWindowInsets(WindowInsets.statusBars) else Modifier)) {
                    BotListScreen(
                        bots = s.bots, avatars = s.avatars, mac = s.mac, loaded = s.botsLoaded,
                        onOpen = { repo.openChat(it.id) }, onSettings = { settingsOpen = true },
                    )
                    ChatOverlay(repo, s.openBot, s.bots, s.avatars, chat, authenticate)
                    SettingsOverlay(
                        settingsOpen, s.mac, s.pairing?.let { "${it.host}:${it.port}" }.orEmpty(), s.keepAlive,
                        repo::setKeepAlive, { settingsOpen = false; repo.unpair() }, { settingsOpen = false },
                    )
                }
            }
            SnackbarHost(
                snack, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().imePadding().padding(bottom = 76.dp),
            ) { Snackbar(it) }
        }
    }

    confirmLink?.let { p ->
        AlertDialog(
            onDismissRequest = { confirmLink = null },
            title = { Text("Parear com ${p.mac}?") },
            text = { Text("O celular vai se conectar a ${p.host}:${p.port}. Só continue se você mesmo gerou esse código no Mac.") },
            confirmButton = { TextButton({ confirmLink = null; repo.pair(p) }) { Text("Parear") } },
            dismissButton = { TextButton({ confirmLink = null }) { Text("Cancelar") } },
        )
    }
}

@Composable
private fun ChatOverlay(
    repo: OrbRepository,
    openBot: String?,
    bots: List<Bot>,
    avatars: Map<String, androidx.compose.ui.graphics.ImageBitmap>,
    chat: ChatUi?,
    authenticate: (onOk: () -> Unit) -> Unit,
) {
    // Remember the last conversation so the exit animation still has something to draw.
    var lastBot by remember { mutableStateOf<Bot?>(null) }
    var lastChat by remember { mutableStateOf<ChatUi?>(null) }
    if (openBot != null) {
        lastBot = bots.firstOrNull { it.id == openBot } ?: lastBot?.takeIf { it.id == openBot } ?: Bot(id = openBot, name = "Orb")
        lastChat = chat
    }
    var backProgress by remember { mutableFloatStateOf(0f) }
    // Predictive back (Android 14+): the screen shrinks and slides while the gesture is dragged.
    PredictiveBackHandler(enabled = openBot != null) { progress ->
        try {
            progress.collect { backProgress = it.progress }
            repo.closeChat()
        } catch (_: CancellationException) {
            backProgress = 0f
        }
    }
    LaunchedEffect(openBot) { if (openBot == null) backProgress = 0f }

    val actions = remember(repo, authenticate) {
        ChatActions(
            onBack = { repo.closeChat() },
            onSend = { text -> repo.currentChatBot()?.let { repo.send(it, text) } },
            onStop = { repo.currentChatBot()?.let { repo.stop(it) } },
            onDecide = { id, decision, reply, note -> repo.currentChatBot()?.let { repo.decide(it, id, decision, reply, note) } },
            authenticate = authenticate,
        )
    }
    val restore = remember(repo, openBot) {
        repo.events.filterIsInstance<UiEvent.RestoreText>().filter { it.bot == openBot }.map { it.text }
    }
    AnimatedVisibility(
        openBot != null,
        enter = slideInHorizontally(tween(250, easing = EmphasizedEasing)) { it / 8 } + fadeIn(tween(200)),
        exit = slideOutHorizontally(tween(200, easing = EmphasizedEasing)) { it / 8 } + fadeOut(tween(150)),
    ) {
        val bot = lastBot ?: return@AnimatedVisibility
        ChatScreen(
            bot = bot, avatar = bot.avatar?.let(avatars::get), chat = lastChat, stream = repo.stream, restore = restore,
            actions = actions,
            modifier = Modifier.graphicsLayer {
                val p = backProgress
                scaleX = 1f - 0.1f * p; scaleY = 1f - 0.1f * p; translationX = size.width * 0.06f * p
            },
        )
    }
}

@Composable
private fun SettingsOverlay(
    visible: Boolean, mac: String, host: String, keepAlive: Boolean,
    onKeepAlive: (Boolean) -> Unit, onUnpair: () -> Unit, onBack: () -> Unit,
) {
    AnimatedVisibility(
        visible,
        enter = slideInHorizontally(tween(250, easing = EmphasizedEasing)) { it / 8 } + fadeIn(tween(200)),
        exit = slideOutHorizontally(tween(200, easing = EmphasizedEasing)) { it / 8 } + fadeOut(tween(150)),
    ) {
        BackHandler(onBack = onBack)
        SettingsScreen(mac, host, keepAlive, onKeepAlive, onUnpair, onBack)
    }
}
