package app.orb.android

import java.net.URLDecoder
import okhttp3.HttpUrl

data class Pairing(val host: String, val port: Int, val token: String, val mac: String) {
    // Never print the token: toString ends up in logs and crash reports.
    override fun toString() = "Pairing(host=$host, port=$port, mac=$mac)"
}

class PairingException(message: String) : Exception(message)

object PairingLink {
    const val DEFAULT_PORT = 47821
    private val TOKEN = Regex("^[A-Za-z0-9_-]{43}$")

    /** Parses `orb://parear?host=…&port=…&token=…&mac=…`; throws [PairingException] with a user-facing message. */
    fun parse(raw: String): Pairing {
        val link = raw.trim()
        val q = link.indexOf('?')
        val base = if (q >= 0) link.substring(0, q) else link
        if (!base.trimEnd('/').equals("orb://parear", ignoreCase = true)) {
            throw PairingException("Esse não é um link de pareamento do Orb.")
        }
        val params = HashMap<String, String>()
        if (q >= 0) {
            link.substring(q + 1).substringBefore('#').split('&').forEach { pair ->
                if (pair.isEmpty()) return@forEach
                val k = decode(pair.substringBefore('=')) ?: return@forEach
                val v = decode(pair.substringAfter('=', "")) ?: return@forEach
                params.putIfAbsent(k, v)
            }
        }
        val host = params["host"]?.trim()?.removePrefix("[")?.removeSuffix("]").orEmpty()
        if (host.isEmpty() || host.any { it.isWhitespace() || it == '/' || it == '?' || it == '#' || it == '@' }) {
            throw PairingException("O link não traz o endereço do Mac.")
        }
        // The same builder `connectOnce` uses: a host it refuses would crash the connection loop at every launch.
        try {
            HttpUrl.Builder().scheme("http").host(host).port(1).build()
        } catch (e: IllegalArgumentException) {
            throw PairingException("O link não traz um endereço válido do Mac.")
        }
        val port = params["port"]?.let { p ->
            p.trim().toIntOrNull()?.takeIf { it in 1..65535 } ?: throw PairingException("A porta do link é inválida.")
        } ?: DEFAULT_PORT
        val token = params["token"]?.trim().orEmpty()
        if (!TOKEN.matches(token)) throw PairingException("O código do link é inválido.")
        val mac = params["mac"]?.trim()?.takeIf { it.isNotEmpty() } ?: "Mac"
        return Pairing(host, port, token, mac.take(80))
    }

    private fun decode(s: String): String? = try {
        // Raw "+" is a literal in a query value produced by percent-encoding encoders; keep it.
        URLDecoder.decode(s.replace("+", "%2B"), "UTF-8")
    } catch (_: IllegalArgumentException) {
        null
    }
}
