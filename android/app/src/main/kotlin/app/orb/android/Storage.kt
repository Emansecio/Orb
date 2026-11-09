package app.orb.android

import android.content.Context
import android.graphics.BitmapFactory
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import java.io.File

/** Pairing and settings in private SharedPreferences (backup is disabled in the manifest). */
class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("orb", Context.MODE_PRIVATE)

    fun loadPairing(): Pairing? {
        val host = prefs.getString("host", null) ?: return null
        val token = prefs.getString("token", null) ?: return null
        return Pairing(host, prefs.getInt("port", PairingLink.DEFAULT_PORT), token, prefs.getString("mac", null) ?: "Mac")
    }

    fun savePairing(p: Pairing) {
        prefs.edit().putString("host", p.host).putInt("port", p.port).putString("token", p.token).putString("mac", p.mac).apply()
    }

    fun clearPairing() {
        prefs.edit().remove("host").remove("port").remove("token").remove("mac").apply()
    }

    var keepAlive: Boolean
        get() = prefs.getBoolean("keepAlive", true)
        set(v) = prefs.edit().putBoolean("keepAlive", v).apply()
}

/** Avatar PNGs cached on disk by hash, so a changed look (new hash) is the only reason to download again. */
class AvatarStore(context: Context) {
    private val dir = File(context.cacheDir, "avatars").apply { mkdirs() }

    private fun file(hash: String) = File(dir, hash.filter { it.isLetterOrDigit() }.take(80).ifEmpty { "x" } + ".png")

    fun has(hash: String) = file(hash).exists()

    fun load(hash: String): ImageBitmap? = runCatching {
        file(hash).takeIf { it.exists() }?.let { BitmapFactory.decodeFile(it.path)?.asImageBitmap() }
    }.getOrNull()

    /** Stores and decodes [png]; returns null when the bytes are not a valid image. */
    fun save(hash: String, png: ByteArray): ImageBitmap? {
        val bmp = BitmapFactory.decodeByteArray(png, 0, png.size) ?: return null
        runCatching { file(hash).writeBytes(png) }
        // Drop stale files so the cache does not grow with every appearance change.
        dir.listFiles()?.sortedByDescending { it.lastModified() }?.drop(64)?.forEach { it.delete() }
        return bmp.asImageBitmap()
    }
}
