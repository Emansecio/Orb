package app.orb.android.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.orb.android.Bot
import app.orb.android.Conn

/** Material 3 "emphasized" curve, used for every short transition. */
val EmphasizedEasing = CubicBezierEasing(0.2f, 0f, 0f, 1f)

fun parseColor(hex: String?, fallback: Color = Color(0xFF5B5BF0)): Color = try {
    val h = hex?.trim()?.removePrefix("#") ?: ""
    when (h.length) {
        6 -> Color(0xFF000000 or h.toLong(16))
        8 -> Color(h.toLong(16))
        else -> fallback
    }
} catch (_: NumberFormatException) {
    fallback
}

/**
 * Round Orb picture. Until the PNG arrives it draws the Orb's colour as a glossy ball with two eyes, so the list
 * never shows an empty hole.
 */
@Composable
fun OrbAvatar(bot: Bot, image: ImageBitmap?, size: Dp, modifier: Modifier = Modifier) {
    val desc = "Avatar de ${bot.name}"
    if (image != null) {
        Image(
            bitmap = image, contentDescription = desc, contentScale = ContentScale.Crop,
            modifier = modifier.size(size).clip(CircleShape),
        )
    } else {
        val base = remember(bot.color) { parseColor(bot.color) }
        Canvas(modifier.size(size).clip(CircleShape).semantics { contentDescription = desc }) {
            val r = this.size.minDimension / 2f
            drawCircle(
                Brush.radialGradient(
                    listOf(lerpColor(base, Color.White, 0.35f), base, lerpColor(base, Color.Black, 0.45f)),
                    center = Offset(r * 0.8f, r * 0.7f), radius = r * 1.5f,
                ),
            )
            val ey = r * 1.02f
            val ex = r * 0.28f
            for (dx in listOf(-ex, ex)) {
                drawOval(Color.White, Offset(r + dx - r * 0.07f, ey - r * 0.10f), androidx.compose.ui.geometry.Size(r * 0.14f, r * 0.22f))
            }
        }
    }
}

private fun lerpColor(a: Color, b: Color, t: Float) = androidx.compose.ui.graphics.lerp(a, b, t)

/** Soft highlight sweeping over text/content, drawn in the draw phase so it never recomposes. */
fun Modifier.shimmer(active: Boolean = true): Modifier = if (!active) this else composed {
    if (LocalReduceMotion.current) return@composed Modifier
    val t = rememberInfiniteTransition(label = "shimmer")
    val x by t.animateFloat(-0.4f, 1.4f, infiniteRepeatable(tween(1800, easing = LinearEasing)), label = "x")
    Modifier
        .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
        .drawWithContent {
            drawContent()
            val w = size.width
            val start = x * w
            drawRect(
                Brush.horizontalGradient(
                    listOf(Color.Transparent, Color.White.copy(alpha = 0.85f), Color.Transparent),
                    startX = start - w * 0.25f, endX = start + w * 0.25f,
                ),
                blendMode = BlendMode.SrcAtop,
            )
        }
}

/** Slow "breathing" scale for working Orbs (1 -> 1.04 in 2.4 s). */
fun Modifier.breathing(active: Boolean): Modifier = if (!active) this else composed {
    if (LocalReduceMotion.current) return@composed Modifier
    val t = rememberInfiniteTransition(label = "breath")
    val s by t.animateFloat(1f, 1.04f, infiniteRepeatable(tween(2400, easing = EmphasizedEasing), RepeatMode.Reverse), label = "s")
    Modifier.graphicsLayer { scaleX = s; scaleY = s }
}

/** White pill with dark text: the one primary action on a screen. */
@Composable
fun PrimaryPill(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    Box(
        modifier
            .defaultMinSize(minHeight = 48.dp)
            .clip(CircleShape)
            .background(Color.White.copy(alpha = if (enabled) 1f else 0.3f))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 22.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = OrbColors.OnPrimary, fontSize = 16.sp, fontWeight = FontWeight.Medium, maxLines = 1)
    }
}

@Composable
fun TextAction(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, color: Color = OrbColors.InkSecondary) {
    Box(
        modifier.defaultMinSize(minHeight = 48.dp).clip(RoundedCornerShape(12.dp)).clickable(onClick = onClick).padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center,
    ) { Text(text, color = color, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) }
}

/** Slim strip shown while the Mac is unreachable. */
@Composable
fun ConnectionBanner(conn: Conn, hasPairing: Boolean, modifier: Modifier = Modifier) {
    if (!hasPairing || conn == Conn.Connected || conn == Conn.Idle) return
    val ctx = LocalContext.current
    Row(
        modifier.background(OrbColors.Raised).padding(start = 16.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(Modifier.size(8.dp).background(OrbColors.Warn, CircleShape))
        Text(
            "Sem conexão com o Mac. Confira se o Tailscale está ligado.",
            color = OrbColors.InkSecondary, fontSize = 13.sp, lineHeight = 17.sp,
            modifier = Modifier.weight(1f).padding(vertical = 8.dp),
        )
        TextAction("Abrir o Tailscale", { openTailscale(ctx) }, color = OrbColors.Link)
    }
}

fun openTailscale(context: Context) {
    val launch = context.packageManager.getLaunchIntentForPackage("com.tailscale.ipn")
    try {
        if (launch != null) {
            context.startActivity(launch)
        } else {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=com.tailscale.ipn")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    } catch (_: ActivityNotFoundException) {
        runCatching {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=com.tailscale.ipn"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }
}

@Composable
fun UnreadDot(count: Int) {
    Box(
        Modifier.defaultMinSize(minWidth = 20.dp, minHeight = 20.dp).background(OrbColors.Accent, CircleShape)
            .padding(horizontal = 6.dp).semantics { contentDescription = "$count não lidas" },
        contentAlignment = Alignment.Center,
    ) { Text(if (count > 99) "99+" else count.toString(), color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.SemiBold) }
}
