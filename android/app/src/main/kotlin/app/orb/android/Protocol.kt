package app.orb.android

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** Protocol version spoken with the Mac (see docs/CELULAR.md). */
const val PROTOCOL_VERSION = 1

@Serializable
data class LastMessage(val text: String? = null, val date: Long = 0)

@Serializable
data class Bot(
    val id: String,
    val name: String = "",
    val role: String? = null,
    val avatar: String? = null,
    val color: String? = null,
    val working: Boolean = false,
    val needsYou: Boolean = false,
    val status: String? = null,
    val unread: Int = 0,
    val last: LastMessage? = null,
    /** Newest open approval card; the Mac sends it only while [needsYou]. */
    val card: Item? = null,
)

@Serializable
data class ToolInfo(
    val kind: String = "shell",
    val title: String = "",
    val detail: String? = null,
    val state: String = "done",
)

@Serializable
data class QuestionInfo(
    val text: String = "",
    val options: List<String> = emptyList(),
    val multiple: Boolean = false,
)

@Serializable
data class ApprovalInfo(
    val kind: String = "permission",
    val title: String = "",
    val command: String? = null,
    val reason: String? = null,
    val decision: String? = null,
    val dangerous: Boolean = false,
    val canAlways: Boolean = false,
    val count: Int = 1,
    val question: QuestionInfo? = null,
)

@Serializable
data class Item(
    val id: String,
    val date: Long = 0,
    val kind: String = "notice",
    val text: String = "",
    val streaming: Boolean = false,
    val tool: ToolInfo? = null,
    val approval: ApprovalInfo? = null,
)

/** Frames the Mac sends to the phone. */
sealed interface Frame {
    data class Welcome(val mac: String, val protocol: Int) : Frame
    data class Bots(val bots: List<Bot>) : Frame
    data class Chat(val bot: String, val items: List<Item>, val working: Boolean, val status: String?) : Frame
    data class Stream(val bot: String, val item: String, val text: String) : Frame
    data class Sent(val ref: String, val ok: Boolean, val queued: Boolean, val note: String?) : Frame
    data class AvatarImage(val bot: String, val hash: String, val png: String) : Frame
    data object Pong : Frame
    data class Error(val code: String, val message: String) : Frame
}

object Protocol {
    // Unknown fields are ignored and absent optionals become null/defaults, as the contract requires.
    val json = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        explicitNulls = false
        isLenient = true
    }

    /** Parses one text frame; returns null for malformed JSON, an unknown `type` or missing required fields. */
    fun parse(text: String): Frame? {
        return try {
        val o = json.parseToJsonElement(text).jsonObject
        when (o.str("type")) {
            "welcome" -> Frame.Welcome(o.str("mac") ?: "", o.int("protocol") ?: PROTOCOL_VERSION)
            "bots" -> Frame.Bots(o.list("bots") { json.decodeFromJsonElement(Bot.serializer(), it) })
            "chat" -> Frame.Chat(
                bot = o.str("bot") ?: return null,
                items = o.list("items") { json.decodeFromJsonElement(Item.serializer(), it) },
                working = o.bool("working") ?: false,
                status = o.str("status"),
            )
            "stream" -> Frame.Stream(o.str("bot") ?: return null, o.str("item") ?: return null, o.str("text") ?: "")
            "sent" -> Frame.Sent(o.str("ref") ?: return null, o.bool("ok") ?: false, o.bool("queued") ?: false, o.str("note"))
            "avatar" -> Frame.AvatarImage(o.str("bot") ?: return null, o.str("hash") ?: "", o.str("png") ?: return null)
            "pong" -> Frame.Pong
            "error" -> Frame.Error(o.str("code") ?: "", o.str("message") ?: "")
            else -> null
        }
        } catch (_: Exception) {
            null
        }
    }

    // One broken element must not discard the whole list, so each is decoded on its own.
    private fun <T> JsonObject.list(key: String, decode: (JsonElement) -> T): List<T> =
        (this[key] as? JsonArray)?.mapNotNull { runCatching { decode(it) }.getOrNull() } ?: emptyList()

    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
    private fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull
    private fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.contentOrNull?.toIntOrNull()

    fun hello(token: String, device: String): String = buildJsonObject {
        put("type", "hello"); put("token", token); put("device", device); put("protocol", PROTOCOL_VERSION)
    }.toString()

    fun open(bot: String): String = buildJsonObject { put("type", "open"); put("bot", bot) }.toString()
    fun close(): String = buildJsonObject { put("type", "close") }.toString()
    fun stop(bot: String): String = buildJsonObject { put("type", "stop"); put("bot", bot) }.toString()
    fun avatar(bot: String): String = buildJsonObject { put("type", "avatar"); put("bot", bot) }.toString()

    fun send(bot: String, text: String, ref: String): String = buildJsonObject {
        put("type", "send"); put("bot", bot); put("text", text); put("ref", ref)
    }.toString()

    fun decide(bot: String, approval: String, decision: String, reply: String? = null, note: String? = null): String =
        buildJsonObject {
            put("type", "decide"); put("bot", bot); put("approval", approval); put("decision", decision)
            if (reply != null) put("reply", reply)
            if (note != null) put("note", note)
        }.toString()
}
