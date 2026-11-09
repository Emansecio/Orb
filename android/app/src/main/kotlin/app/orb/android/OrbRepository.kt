package app.orb.android

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.util.Base64
import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.ImageBitmap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

enum class Conn { Idle, Connecting, Connected, Offline }

@Immutable
data class AppState(
    val pairing: Pairing? = null,
    val conn: Conn = Conn.Idle,
    val mac: String = "",
    val bots: List<Bot> = emptyList(),
    val botsLoaded: Boolean = false,
    val avatars: Map<String, ImageBitmap> = emptyMap(),
    val openBot: String? = null,
    /** Shown on the pairing screen after the Mac revoked this phone. */
    val notice: String? = null,
    val keepAlive: Boolean = true,
)

@Immutable
data class PendingMsg(val ref: String, val text: String, val sentOk: Boolean, val baseCount: Int)

@Immutable
data class ChatUi(
    val botId: String,
    val rows: List<Row> = emptyList(),
    val working: Boolean = false,
    val status: String? = null,
    val loaded: Boolean = false,
    val pending: List<PendingMsg> = emptyList(),
    /** Card ids already answered from this phone, waiting for the Mac to confirm. */
    val submitted: Set<String> = emptySet(),
)

data class StreamState(val bot: String, val item: String, val text: String)

sealed interface UiEvent {
    data class Message(val text: String) : UiEvent
    data class RestoreText(val bot: String, val text: String, val note: String) : UiEvent
}

/** Receives what should become a system notification; implemented by [Notifier]. */
interface NotifySink {
    fun notify(event: NotifyEvent)
    fun cancelAll()
}

/**
 * Single source of truth shared by the UI and the foreground service. All mutable non-flow fields are confined to
 * [serial] (a single-threaded view of the default dispatcher), so no locks are needed.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class OrbRepository private constructor(private val appContext: Context) {
    private val settings = SettingsStore(appContext)
    private val avatarStore = AvatarStore(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val serial = Dispatchers.Default.limitedParallelism(1)
    private val client = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .connectTimeout(10, TimeUnit.SECONDS)
        .build()

    private val _state = MutableStateFlow(AppState())
    val state: StateFlow<AppState> = _state.asStateFlow()
    private val _chat = MutableStateFlow<ChatUi?>(null)
    val chat: StateFlow<ChatUi?> = _chat.asStateFlow()
    private val _stream = MutableStateFlow<StreamState?>(null)
    /** Kept apart from [chat] so a streaming frame recomposes only the live item. */
    val stream: StateFlow<StreamState?> = _stream.asStateFlow()
    private val _events = MutableSharedFlow<UiEvent>(extraBufferCapacity = 16)
    val events: SharedFlow<UiEvent> = _events.asSharedFlow()

    var notifier: NotifySink? = null

    // Confined to [serial].
    private var visibleCount = 0
    private var serviceActive = false
    private var loopJob: Job? = null
    private var socket: WebSocket? = null
    private var sessionWelcomed = false
    private var sessionUnauthorized = false
    private var previousBots: List<Bot>? = null
    private val requestedAvatars = HashSet<String>()
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private var items: List<Item> = emptyList()

    private fun init() {
        val p = settings.loadPairing()
        _state.value = AppState(pairing = p, mac = p?.mac.orEmpty(), keepAlive = settings.keepAlive)
        val cm = appContext.getSystemService(ConnectivityManager::class.java)
        // Reconnect right away when the network comes back instead of waiting out the backoff.
        runCatching {
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = kick()
            })
        }
    }

    // region lifecycle hooks

    fun onAppStarted() = launchSerial {
        visibleCount++
        reconcile(); kickNow()
        // The Mac clears unread only for the open conversation, so it is opened again only while visible.
        if (visibleCount == 1) _state.value.openBot?.let { socket?.send(Protocol.open(it)) }
    }

    fun onAppStopped() = launchSerial {
        visibleCount = (visibleCount - 1).coerceAtLeast(0)
        if (visibleCount == 0 && _state.value.openBot != null) socket?.send(Protocol.close())
        reconcile()
    }
    fun onServiceActive(active: Boolean) = launchSerial { serviceActive = active; reconcile() }

    fun setKeepAlive(v: Boolean) {
        settings.keepAlive = v
        _state.update { it.copy(keepAlive = v) }
    }

    fun kick() = launchSerial { kickNow() }

    private fun kickNow() {
        if (_state.value.conn != Conn.Connected) wake.trySend(Unit)
    }

    // endregion

    // region pairing

    fun pair(p: Pairing) = launchSerial {
        settings.savePairing(p)
        _state.update { AppState(pairing = p, mac = p.mac, keepAlive = it.keepAlive, avatars = it.avatars) }
        _chat.value = null; items = emptyList()
        disconnect()
        reconcile(); kickNow()
    }

    fun unpair(notice: String? = null) = launchSerial {
        settings.clearPairing()
        disconnect()
        notifier?.cancelAll()
        _chat.value = null; _stream.value = null; items = emptyList()
        _state.update { AppState(notice = notice, keepAlive = it.keepAlive) }
    }

    // endregion

    // region UI actions

    fun openChat(botId: String) = launchSerial {
        items = emptyList()
        _stream.value = null
        _chat.value = ChatUi(botId)
        _state.update { it.copy(openBot = botId) }
        socket?.send(Protocol.open(botId))
    }

    fun closeChat() = launchSerial {
        _state.update { it.copy(openBot = null) }
        _chat.value = null; _stream.value = null; items = emptyList()
        socket?.send(Protocol.close())
    }

    fun send(botId: String, text: String) = launchSerial {
        val clean = text.trim()
        if (clean.isEmpty()) return@launchSerial
        val ref = UUID.randomUUID().toString()
        val base = items.count { it.kind == "user" && it.text == clean }
        _chat.update { it?.copy(pending = it.pending + PendingMsg(ref, clean, false, base)) }
        if (socket?.send(Protocol.send(botId, clean, ref)) != true) failPending(ref, "Sem conexão com o Mac.")
    }

    fun showMessage(text: String) { _events.tryEmit(UiEvent.Message(text)) }

    fun currentChatBot(): String? = _state.value.openBot

    fun stop(botId: String) = launchSerial { socket?.send(Protocol.stop(botId)) }

    /** Answers a card. Used by the chat and by the notification buttons. */
    fun decide(botId: String, approvalId: String, decision: String, reply: String? = null, note: String? = null,
        onResult: ((Boolean) -> Unit)? = null,
    ) =
        launchSerial {
            _chat.update { it?.copy(submitted = it.submitted + approvalId) }
            if (socket?.send(Protocol.decide(botId, approvalId, decision, reply, note)) != true) {
                _chat.update { it?.copy(submitted = it.submitted - approvalId) }
                _events.tryEmit(UiEvent.Message("Sem conexão com o Mac. Tente de novo."))
                onResult?.invoke(false)
            } else {
                onResult?.invoke(true)
            }
        }

    // endregion

    // region connection loop

    private fun reconcile() {
        val should = _state.value.pairing != null && (visibleCount > 0 || serviceActive)
        if (should && loopJob == null) {
            loopJob = scope.launch(serial) { runLoop() }
        } else if (!should && loopJob != null) {
            disconnect()
            _state.update { it.copy(conn = Conn.Idle) }
        }
    }

    private fun disconnect() {
        loopJob?.cancel(); loopJob = null
        socket?.cancel(); socket = null
        previousBots = null
        requestedAvatars.clear()
    }

    private suspend fun runLoop() {
        var attempt = 0
        while (currentCoroutineContext().isActive) {
            val p = _state.value.pairing ?: break
            _state.update { it.copy(conn = Conn.Connecting) }
            sessionWelcomed = false; sessionUnauthorized = false
            try {
                connectOnce(p)
            } catch (e: IllegalArgumentException) {
                // A saved host the HTTP client refuses would otherwise crash the app at every launch.
                unpair("O endereço salvo do Mac é inválido. Pareie de novo.")
                return
            }
            if (sessionUnauthorized) {
                unpair("O código deste celular foi trocado no Mac. Pareie de novo.")
                return
            }
            if (sessionWelcomed) attempt = 0
            socket = null
            _state.update { it.copy(conn = Conn.Offline) }
            val wait = Backoff.delayMs(attempt++, Math.random())
            withTimeoutOrNull(wait) { wake.receive() }
        }
    }

    private suspend fun connectOnce(p: Pairing) {
        val url = HttpUrl.Builder().scheme("http").host(p.host).port(p.port).build()
        val done = CompletableDeferred<Unit>()
        val ws = client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(Protocol.hello(p.token, Build.MODEL ?: "Android"))
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                scope.launch(serial) { handle(webSocket, text) }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                scope.launch(serial) { done.complete(Unit) }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                scope.launch(serial) { done.complete(Unit) }
            }
        })
        socket = ws
        try {
            done.await()
        } finally {
            ws.cancel()
        }
    }

    // endregion

    // region frames

    private fun handle(ws: WebSocket, text: String) {
        if (ws !== socket) return
        when (val f = Protocol.parse(text) ?: return) {
            is Frame.Welcome -> {
                sessionWelcomed = true
                // Keep the previous list: the first frame after a reconnect then notifies what changed during the
                // outage. It is only reset in disconnect() (user left the app or unpaired).
                requestedAvatars.clear()
                _state.update { s ->
                    val p = s.pairing
                    if (p != null && f.mac.isNotBlank() && f.mac != p.mac) {
                        val np = p.copy(mac = f.mac); settings.savePairing(np)
                        s.copy(conn = Conn.Connected, pairing = np, mac = f.mac)
                    } else s.copy(conn = Conn.Connected)
                }
                if (visibleCount > 0) _state.value.openBot?.let { ws.send(Protocol.open(it)) }
            }
            is Frame.Bots -> onBots(ws, f.bots)
            is Frame.Chat -> onChat(f)
            is Frame.Stream -> if (f.bot == _state.value.openBot) _stream.value = StreamState(f.bot, f.item, f.text)
            is Frame.Sent -> onSent(f)
            is Frame.AvatarImage -> {
                val bytes = runCatching { Base64.decode(f.png, Base64.DEFAULT) }.getOrNull() ?: return
                val bmp = avatarStore.save(f.hash, bytes) ?: return
                _state.update { it.copy(avatars = it.avatars + (f.hash to bmp)) }
            }
            Frame.Pong -> Unit
            is Frame.Error -> when (f.code) {
                "unauthorized" -> { sessionUnauthorized = true; ws.cancel() }
                else -> if (f.message.isNotBlank()) _events.tryEmit(UiEvent.Message(f.message))
            }
        }
    }

    private fun onBots(ws: WebSocket, bots: List<Bot>) {
        val s = _state.value
        val visible = if (visibleCount > 0) s.openBot else null
        val events = NotifyLogic.diff(previousBots, bots, visible)
        previousBots = bots
        _state.update { it.copy(bots = bots, botsLoaded = true) }
        for (b in bots) {
            val hash = b.avatar ?: continue
            if (hash in _state.value.avatars || !requestedAvatars.add(hash)) continue
            val cached = if (avatarStore.has(hash)) avatarStore.load(hash) else null
            if (cached != null) _state.update { it.copy(avatars = it.avatars + (hash to cached)) }
            else ws.send(Protocol.avatar(b.id))
        }
        for (e in events) notifier?.notify(e)
    }

    private fun onChat(f: Frame.Chat) {
        val s = _state.value
        if (f.bot != s.openBot) return
        items = f.items
        val live = _stream.value
        if (live != null && f.items.any { it.id == live.item && !it.streaming }) _stream.value = null
        _chat.update { cur ->
            val c = cur ?: ChatUi(f.bot)
            val users = f.items.filter { it.kind == "user" }.groupingBy { it.text }.eachCount()
            c.copy(
                rows = Rows.build(f.items), working = f.working, status = f.status, loaded = true,
                // A confirmed message is dropped only once the Mac's own copy shows up, so it never blinks away.
                pending = c.pending.filterNot { it.sentOk && (users[it.text] ?: 0) > it.baseCount },
                submitted = c.submitted.filterTo(HashSet()) { id ->
                    f.items.any { it.id == id && it.approval?.decision == null }
                },
            )
        }
    }

    private fun onSent(f: Frame.Sent) {
        if (!f.ok) {
            failPending(f.ref, f.note ?: "Não foi possível enviar a mensagem.")
            return
        }
        _chat.update { it?.copy(pending = it.pending.map { p -> if (p.ref == f.ref) p.copy(sentOk = true) else p }) }
        // Safety net in case the matching chat frame never carries the text (e.g. the Mac rewrote it).
        scope.launch(serial) {
            delay(8_000)
            _chat.update { it?.copy(pending = it.pending.filterNot { p -> p.ref == f.ref }) }
        }
    }

    private fun failPending(ref: String, note: String) {
        val chat = _chat.value ?: return
        val p = chat.pending.firstOrNull { it.ref == ref } ?: return
        _chat.update { it?.copy(pending = it.pending.filterNot { x -> x.ref == ref }) }
        _events.tryEmit(UiEvent.RestoreText(chat.botId, p.text, note))
    }

    // endregion

    private fun launchSerial(block: suspend () -> Unit) {
        scope.launch(serial) { block() }
    }

    companion object {
        @Volatile private var instance: OrbRepository? = null

        fun get(context: Context): OrbRepository =
            instance ?: synchronized(this) {
                instance ?: OrbRepository(context.applicationContext).also { instance = it; it.init() }
            }
    }
}
