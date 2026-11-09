package app.orb.android

sealed interface NotifyEvent {
    val bot: Bot

    data class NeedsYou(override val bot: Bot) : NotifyEvent
    data class Responded(override val bot: Bot) : NotifyEvent
}

object NotifyLogic {
    /**
     * Compares two consecutive `bots` frames. [previous] null means the first frame after connecting: nothing is
     * announced then, otherwise every old unread would ring at once. [visibleBot] is the conversation the user is
     * looking at right now, which never notifies.
     */
    fun diff(previous: List<Bot>?, current: List<Bot>, visibleBot: String?): List<NotifyEvent> {
        if (previous == null) return emptyList()
        val before = previous.associateBy { it.id }
        val out = ArrayList<NotifyEvent>()
        for (bot in current) {
            val old = before[bot.id] ?: continue
            if (bot.id == visibleBot) continue
            if (bot.needsYou && !old.needsYou) {
                out += NotifyEvent.NeedsYou(bot)
            } else if (!bot.working && bot.unread > 0 && (bot.unread > old.unread || old.working) && bot.unread >= old.unread) {
                // Turn ended with something new to read. A drop in unread means the user read it elsewhere.
                out += NotifyEvent.Responded(bot)
            }
        }
        return out
    }

    /** Notification buttons are only offered for a plain, non-dangerous permission card. */
    fun canActFromNotification(approval: ApprovalInfo?): Boolean =
        approval != null && approval.kind == "permission" && !approval.dangerous && approval.decision == null
}
