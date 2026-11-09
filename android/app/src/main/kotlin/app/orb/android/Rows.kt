package app.orb.android

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** What the conversation list actually draws: consecutive tool items collapse into one row, dates get separators. */
sealed interface Row {
    val key: String

    data class Date(override val key: String, val millis: Long) : Row
    data class User(val item: Item, val showLabel: Boolean) : Row { override val key get() = item.id }
    data class BotText(val item: Item, val showAvatar: Boolean) : Row { override val key get() = item.id }
    // The key is the first action's id so an expanded group stays expanded when new actions are appended.
    data class Tools(override val key: String, val items: List<Item>) : Row
    data class Approval(val item: Item) : Row { override val key get() = item.id }
    data class Note(val item: Item) : Row { override val key get() = item.id }

    /** Optimistic message not yet confirmed by the Mac. */
    data class Pending(val ref: String, val text: String, val confirmed: Boolean, val showLabel: Boolean) : Row {
        override val key get() = "pending-$ref"
    }

    /** Footer line "● status" with the stop button. */
    data class Working(val status: String?) : Row { override val key get() = "working" }
}

object Rows {
    const val DATE_GAP_MS = 15 * 60 * 1000L

    /** Builds rows in chronological order (the UI reverses them for a bottom-anchored list). */
    fun build(items: List<Item>): List<Row> {
        val out = ArrayList<Row>(items.size + 4)
        var lastDate = Long.MIN_VALUE
        var prev: Row? = null
        var i = 0
        while (i < items.size) {
            val item = items[i]
            if (lastDate == Long.MIN_VALUE || item.date - lastDate > DATE_GAP_MS) {
                if (item.date > 0) {
                    val sep = Row.Date("date-${item.id}", item.date)
                    out += sep; prev = sep
                }
            }
            val row: Row
            if (item.kind == "tool") {
                var j = i
                val group = ArrayList<Item>()
                while (j < items.size && items[j].kind == "tool") { group += items[j]; j++ }
                row = Row.Tools(group.first().id, group)
                lastDate = group.last().date
                i = j
            } else {
                row = when (item.kind) {
                    "user" -> Row.User(item, showLabel = prev !is Row.User)
                    "bot" -> Row.BotText(item, showAvatar = prev !is Row.BotText)
                    "approval" -> if (item.approval != null) Row.Approval(item) else Row.Note(item)
                    else -> Row.Note(item)
                }
                lastDate = item.date
                i++
            }
            out += row; prev = row
        }
        return out
    }
}

/** Pure time formatting, with the clock and zone injected so it is testable. */
object Times {
    private val pt = Locale.forLanguageTag("pt-BR")
    private val hm = DateTimeFormatter.ofPattern("HH:mm", pt)
    private val weekday = DateTimeFormatter.ofPattern("EEE", pt)
    private val dayMonth = DateTimeFormatter.ofPattern("d 'de' MMM", pt)
    private val shortDate = DateTimeFormatter.ofPattern("dd/MM/yy", pt)

    /** List column: "18:33", "ontem", "seg.", then a short date. */
    fun relative(millis: Long, now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): String {
        val t = Instant.ofEpochMilli(millis).atZone(zone)
        val days = daysBetween(t.toLocalDate(), Instant.ofEpochMilli(now).atZone(zone).toLocalDate())
        return when {
            days <= 0 -> hm.format(t)
            days == 1L -> "ontem"
            days < 7 -> weekday.format(t)
            else -> shortDate.format(t)
        }
    }

    /** Separator inside a conversation: "Hoje, 18:33", "Ontem, 18:33", "seg., 18:33", "3 de nov., 18:33". */
    fun separator(millis: Long, now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): String {
        val t = Instant.ofEpochMilli(millis).atZone(zone)
        val days = daysBetween(t.toLocalDate(), Instant.ofEpochMilli(now).atZone(zone).toLocalDate())
        val time = hm.format(t)
        return when {
            days <= 0 -> "Hoje, $time"
            days == 1L -> "Ontem, $time"
            days < 7 -> "${weekday.format(t)}, $time"
            else -> "${dayMonth.format(t)}, $time"
        }
    }

    private fun daysBetween(a: LocalDate, b: LocalDate) = b.toEpochDay() - a.toEpochDay()
}
