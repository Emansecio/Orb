package app.orb.android.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.graphics.Color

/** Palette mirrored from the macOS app (Sources/Orb/Theme.swift). The app is dark-only, like the Mac one. */
object OrbColors {
    val Canvas = Color(0xFF070707)
    val Chrome = Color(0xFF111111)
    val Surface = Color(0xFF181818)
    val Raised = Color(0xFF222222)
    val UserBubble = Color(0xFF323232)
    val Ink = Color(0xFFFCFCFC)
    val InkSecondary = Ink.copy(alpha = 0.74f)
    val Muted = Ink.copy(alpha = 0.60f)
    val Faint = Ink.copy(alpha = 0.52f)
    val Hint = Ink.copy(alpha = 0.36f)
    val Line = Color.White.copy(alpha = 0.10f)
    val LineStrong = Color.White.copy(alpha = 0.15f)
    val Accent = Color(0xFF1084FE)
    val Link = Color(0xFF459FFE)
    val Ok = Color(0xFF00C972)
    val Danger = Color(0xFFFF263C)
    val Warn = Color(0xFFFF9800)
    val OnPrimary = Color(0xFF141414)
}

/** True when the system turned animations off ("Remover animações"): no shimmer, no breathing. */
val LocalReduceMotion = compositionLocalOf { false }

private val scheme = darkColorScheme(
    primary = OrbColors.Ink,
    onPrimary = OrbColors.OnPrimary,
    background = OrbColors.Canvas,
    onBackground = OrbColors.Ink,
    surface = OrbColors.Surface,
    onSurface = OrbColors.Ink,
    surfaceVariant = OrbColors.Raised,
    onSurfaceVariant = OrbColors.InkSecondary,
    surfaceContainer = OrbColors.Surface,
    surfaceContainerHigh = OrbColors.Raised,
    outline = OrbColors.LineStrong,
    outlineVariant = OrbColors.Line,
    error = OrbColors.Danger,
    secondaryContainer = OrbColors.Raised,
    onSecondaryContainer = OrbColors.Ink,
)

@Composable
fun OrbTheme(reduceMotion: Boolean = false, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalReduceMotion provides reduceMotion) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
