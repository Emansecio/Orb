package app.orb.android

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

const val EXTRA_BOT = "bot"
private const val EXTRA_APPROVAL = "approval"
private const val EXTRA_DECISION = "decision"
private const val ACTION_DECIDE = "app.orb.android.DECIDE"
private const val CH_STATUS = "status"
private const val CH_ALERTS = "alerts"
private const val FG_ID = 1

class Notifier(private val context: Context) : NotifySink {
    private val nm = NotificationManagerCompat.from(context)

    init {
        val sys = context.getSystemService(NotificationManager::class.java)
        sys.createNotificationChannel(
            NotificationChannel(CH_STATUS, "Conexão", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Aviso fixo enquanto o celular fica conectado ao Mac."
                setShowBadge(false)
            },
        )
        sys.createNotificationChannel(
            NotificationChannel(CH_ALERTS, "Avisos dos Orbs", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Quando um Orb precisa de você ou termina uma resposta."
            },
        )
    }

    private fun canPost() = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun openIntent(botId: String): PendingIntent = PendingIntent.getActivity(
        context, botId.hashCode(),
        Intent(context, MainActivity::class.java)
            .putExtra(EXTRA_BOT, botId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    fun foregroundNotification(text: String): Notification =
        NotificationCompat.Builder(context, CH_STATUS)
            .setSmallIcon(R.drawable.ic_stat_orb)
            .setContentTitle(text)
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(PendingIntent.getActivity(
                context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
            ))
            .build()

    override fun notify(event: NotifyEvent) {
        if (!canPost()) return
        val bot = event.bot
        val b = NotificationCompat.Builder(context, CH_ALERTS)
            .setSmallIcon(R.drawable.ic_stat_orb)
            .setAutoCancel(true)
            .setContentIntent(openIntent(bot.id))
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
        when (event) {
            is NotifyEvent.NeedsYou -> {
                b.setContentTitle("${bot.name} precisa de você").setColor(0xFFFF9800.toInt())
                val card = bot.card
                val approval = card?.approval
                val text = approval?.title?.takeIf { it.isNotBlank() } ?: card?.text?.takeIf { it.isNotBlank() }
                if (text != null) b.setContentText(text)
                if (card != null && NotifyLogic.canActFromNotification(approval)) {
                    b.addAction(0, "Permitir", decideIntent(bot.id, card.id, "once"))
                    b.addAction(0, "Não permitir", decideIntent(bot.id, card.id, "deny"))
                }
            }
            is NotifyEvent.Responded -> {
                b.setContentTitle("${bot.name} respondeu")
                bot.last?.text?.takeIf { it.isNotBlank() }?.let {
                    b.setContentText(it).setStyle(NotificationCompat.BigTextStyle().bigText(it))
                }
            }
        }
        runCatching { nm.notify(bot.id, if (event is NotifyEvent.NeedsYou) 1 else 2, b.build()) }
    }

    private fun decideIntent(botId: String, approvalId: String, decision: String): PendingIntent = PendingIntent.getBroadcast(
        context, (approvalId + decision).hashCode(),
        Intent(context, ActionReceiver::class.java).setAction(ACTION_DECIDE)
            .putExtra(EXTRA_BOT, botId).putExtra(EXTRA_APPROVAL, approvalId).putExtra(EXTRA_DECISION, decision),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    fun cancelFor(botId: String) {
        nm.cancel(botId, 1); nm.cancel(botId, 2)
    }

    override fun cancelAll() = nm.cancelAll()
}

class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_DECIDE) return
        val bot = intent.getStringExtra(EXTRA_BOT) ?: return
        val approval = intent.getStringExtra(EXTRA_APPROVAL) ?: return
        val decision = intent.getStringExtra(EXTRA_DECISION)?.takeIf { it == "once" || it == "deny" } ?: return
        // Keep the receiver alive until the send result is known; cancel the notification only if it went out.
        val pending = goAsync()
        OrbRepository.get(context).decide(bot, approval, decision) { sent ->
            if (sent) {
                Notifier(context).cancelFor(bot)
            } else {
                Handler(Looper.getMainLooper()).post {
                    Toast.makeText(context, "Sem conexão com o Mac. Tente de novo.", Toast.LENGTH_LONG).show()
                }
            }
            pending.finish()
        }
    }
}

/** Keeps the process (and the WebSocket) alive in the background; the notification is its only visible trace. */
class ConnectionService : Service() {
    private var scope: CoroutineScope? = null
    private var job: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val repo = OrbRepository.get(this)
        val notifier = (repo.notifier as? Notifier) ?: Notifier(this).also { repo.notifier = it }
        val mac = repo.state.value.mac.ifBlank { "Mac" }
        val n = notifier.foregroundNotification("Conectado ao $mac")
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(FG_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
        } else {
            startForeground(FG_ID, n)
        }
        repo.onServiceActive(true)
        if (job == null) {
            val s = CoroutineScope(SupervisorJob() + Dispatchers.Main).also { scope = it }
            job = s.launch {
                repo.state.map { Triple(it.pairing != null && it.keepAlive, it.conn, it.mac) }.distinctUntilChanged().collect { (keep, conn, name) ->
                    if (!keep) { stopSelf(); return@collect }
                    val label = name.ifBlank { "Mac" }
                    val text = if (conn == Conn.Connected) "Conectado ao $label" else "Reconectando ao $label…"
                    runCatching { NotificationManagerCompat.from(this@ConnectionService).notify(FG_ID, notifier.foregroundNotification(text)) }
                }
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        OrbRepository.get(this).onServiceActive(false)
        scope?.cancel()
        super.onDestroy()
    }

    companion object {
        fun start(context: Context) {
            // Starting from the background can be refused on newer Android; the app still works while visible.
            runCatching { ContextCompat.startForegroundService(context, Intent(context, ConnectionService::class.java)) }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ConnectionService::class.java))
        }
    }
}
