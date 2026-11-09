package app.orb.android.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.orb.android.Bot
import app.orb.android.Times

@Composable
fun BotListScreen(
    bots: List<Bot>,
    avatars: Map<String, ImageBitmap>,
    mac: String,
    loaded: Boolean,
    onOpen: (Bot) -> Unit,
    onSettings: () -> Unit,
    modifier: Modifier = Modifier,
    now: Long = System.currentTimeMillis(),
) {
    val active = remember(bots) { bots.filter { it.working || it.needsYou } }
    LazyColumn(
        modifier.fillMaxSize().background(OrbColors.Chrome),
        contentPadding = PaddingValues(bottom = 24.dp),
    ) {
        item(key = "header", contentType = "header") {
            Row(
                Modifier.statusBarsPadding().padding(start = 20.dp, end = 8.dp, top = 12.dp, bottom = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Orbs", color = OrbColors.Ink, fontSize = 32.sp, fontWeight = FontWeight.SemiBold)
                    if (mac.isNotBlank()) Text(mac, color = OrbColors.Faint, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                IconButton(onSettings, Modifier.size(48.dp)) {
                    Icon(Icons.Outlined.Settings, "Ajustes", tint = OrbColors.InkSecondary)
                }
            }
        }
        item(key = "active", contentType = "active") {
            AnimatedVisibility(active.isNotEmpty()) {
                LazyRow(
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 14.dp),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    items(active, key = { it.id }, contentType = { "active" }) { bot ->
                        ActiveOrb(bot, bot.avatar?.let(avatars::get), onClick = { onOpen(bot) })
                    }
                }
            }
        }
        if (bots.isEmpty()) {
            item(key = "empty", contentType = "empty") {
                Text(
                    if (loaded) "Nenhum Orb por aqui ainda. Crie um no Mac." else "Conectando ao Mac…",
                    color = OrbColors.Faint, fontSize = 15.sp, textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(top = 80.dp, start = 32.dp, end = 32.dp),
                )
            }
        }
        items(bots, key = { it.id }, contentType = { "bot" }) { bot ->
            BotRowItem(bot, bot.avatar?.let(avatars::get), now, onClick = { onOpen(bot) })
        }
        item(key = "pad", contentType = "pad") { Spacer(Modifier.navigationBarsPadding()) }
    }
}

@Composable
private fun ActiveOrb(bot: Bot, image: ImageBitmap?, onClick: () -> Unit) {
    Column(
        Modifier.width(84.dp).clickable(onClick = onClick).padding(vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // Fixed 80 dp slot for both states so names line up whether or not the orange ring is drawn.
        Box(
            Modifier.size(80.dp).breathing(bot.working && !bot.needsYou)
                .then(if (bot.needsYou) Modifier.border(3.dp, OrbColors.Warn, CircleShape) else Modifier),
            contentAlignment = Alignment.Center,
        ) { OrbAvatar(bot, image, 64.dp) }
        Spacer(Modifier.height(4.dp))
        Text(bot.name, color = OrbColors.Ink, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun BotRowItem(bot: Bot, image: ImageBitmap?, now: Long, onClick: () -> Unit) {
    val state = when {
        bot.needsYou -> "precisa de você"
        bot.working -> "trabalhando"
        else -> ""
    }
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 20.dp, vertical = 10.dp)
            .semantics(mergeDescendants = true) { contentDescription = "${bot.name}, $state" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        OrbAvatar(bot, image, 48.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(bot.name, color = OrbColors.Ink, fontSize = 17.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            when {
                bot.needsYou -> Text("Precisa de você", color = OrbColors.Warn, fontSize = 14.sp, maxLines = 1)
                bot.working && !bot.status.isNullOrBlank() ->
                    Text(bot.status, color = OrbColors.Muted, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.shimmer())
                bot.working -> Text("Trabalhando…", color = OrbColors.Muted, fontSize = 14.sp, maxLines = 1, modifier = Modifier.shimmer())
                else -> Text(
                    bot.last?.text?.replace('\n', ' ') ?: bot.role.orEmpty(),
                    color = OrbColors.Muted, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            bot.last?.takeIf { it.date > 0 }?.let {
                Text(Times.relative(it.date, now), color = if (bot.unread > 0) OrbColors.Link else OrbColors.Faint, fontSize = 12.sp)
            }
            if (bot.unread > 0) UnreadDot(bot.unread) else Spacer(Modifier.height(20.dp))
        }
    }
}
