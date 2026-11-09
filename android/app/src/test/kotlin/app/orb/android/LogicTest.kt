package app.orb.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId
import java.time.ZonedDateTime

class RowsTest {
    private fun item(id: String, kind: String, date: Long = 1_000_000, text: String = id) =
        Item(id = id, date = date, kind = kind, text = text, tool = if (kind == "tool") ToolInfo() else null,
            approval = if (kind == "approval") ApprovalInfo() else null)

    @Test fun consecutiveToolsCollapseIntoOneRowKeyedByFirstId() {
        val rows = Rows.build(listOf(item("u", "user"), item("t1", "tool"), item("t2", "tool"), item("t3", "tool"), item("b", "bot")))
        val kinds = rows.filterNot { it is Row.Date }
        assertEquals(3, kinds.size)
        val group = kinds[1] as Row.Tools
        assertEquals("t1", group.key)
        assertEquals(3, group.items.size)
    }

    @Test fun groupKeyIsStableWhenActionsAreAppended() {
        val a = Rows.build(listOf(item("t1", "tool"), item("t2", "tool"))).filterIsInstance<Row.Tools>().single()
        val b = Rows.build(listOf(item("t1", "tool"), item("t2", "tool"), item("t3", "tool"))).filterIsInstance<Row.Tools>().single()
        assertEquals(a.key, b.key)
    }

    @Test fun toolsSeparatedByAMessageStaySeparate() {
        val rows = Rows.build(listOf(item("t1", "tool"), item("b", "bot"), item("t2", "tool")))
        assertEquals(2, rows.filterIsInstance<Row.Tools>().size)
    }

    @Test fun dateSeparatorOnlyAfterMoreThanFifteenMinutes() {
        val t0 = 1_700_000_000_000
        val rows = Rows.build(listOf(
            item("1", "user", t0), item("2", "bot", t0 + 15 * 60_000), item("3", "bot", t0 + 15 * 60_000 + 15 * 60_000 + 1),
        ))
        assertEquals(2, rows.count { it is Row.Date }) // before the first item and before the third
        assertTrue(rows.first() is Row.Date)
    }

    @Test fun avatarOnlyOnFirstBotRowOfASequence() {
        val rows = Rows.build(listOf(item("b1", "bot"), item("b2", "bot"), item("t", "tool"), item("b3", "bot"))).filterIsInstance<Row.BotText>()
        assertEquals(listOf(true, false, true), rows.map { it.showAvatar })
    }

    @Test fun userLabelOnlyOnFirstOfASequence() {
        val rows = Rows.build(listOf(item("u1", "user"), item("u2", "user"))).filterIsInstance<Row.User>()
        assertEquals(listOf(true, false), rows.map { it.showLabel })
    }

    @Test fun approvalWithoutPayloadFallsBackToNote() {
        val rows = Rows.build(listOf(Item("x", 1, "approval", "texto")))
        assertTrue(rows.last() is Row.Note)
    }
}

class TimesTest {
    private val zone = ZoneId.of("America/Sao_Paulo")
    private fun ms(y: Int, m: Int, d: Int, h: Int, min: Int) = ZonedDateTime.of(y, m, d, h, min, 0, 0, zone).toInstant().toEpochMilli()

    @Test fun relativeLabels() {
        val now = ms(2025, 11, 12, 20, 0) // quarta-feira
        assertEquals("18:33", Times.relative(ms(2025, 11, 12, 18, 33), now, zone))
        assertEquals("ontem", Times.relative(ms(2025, 11, 11, 23, 59), now, zone))
        assertEquals("seg.", Times.relative(ms(2025, 11, 10, 9, 0), now, zone))
        assertEquals("01/11/25", Times.relative(ms(2025, 11, 1, 9, 0), now, zone))
    }

    @Test fun separatorLabels() {
        val now = ms(2025, 11, 12, 20, 0)
        assertEquals("Hoje, 18:33", Times.separator(ms(2025, 11, 12, 18, 33), now, zone))
        assertEquals("Ontem, 07:05", Times.separator(ms(2025, 11, 11, 7, 5), now, zone))
    }
}

class BackoffTest {
    @Test fun growsExponentiallyWithinJitterBounds() {
        assertEquals(500L, Backoff.delayMs(0, 0.0))
        assertEquals(1000L, Backoff.delayMs(0, 1.0))
        assertEquals(1000L, Backoff.delayMs(1, 0.0))
        assertEquals(2000L, Backoff.delayMs(1, 1.0))
        assertEquals(8000L, Backoff.delayMs(3, 1.0))
    }

    @Test fun capsAtThirtySeconds() {
        for (a in 5..100) {
            assertEquals(30_000L, Backoff.delayMs(a, 1.0))
            assertEquals(15_000L, Backoff.delayMs(a, 0.0))
        }
    }

    @Test fun neverExceedsBoundsForAnyRandom() {
        for (a in 0..40) for (r in listOf(-1.0, 0.0, 0.3, 1.0, 5.0)) {
            val d = Backoff.delayMs(a, r)
            assertTrue(d in 500L..30_000L)
        }
    }
}

class NotifyLogicTest {
    private fun bot(id: String = "a", working: Boolean = false, needs: Boolean = false, unread: Int = 0) =
        Bot(id = id, name = id.uppercase(), working = working, needsYou = needs, unread = unread)

    @Test fun firstFrameNeverNotifies() {
        assertTrue(NotifyLogic.diff(null, listOf(bot(needs = true, unread = 3)), null).isEmpty())
    }

    @Test fun needsYouTransitionNotifiesOnce() {
        val e = NotifyLogic.diff(listOf(bot()), listOf(bot(needs = true)), null)
        assertTrue(e.single() is NotifyEvent.NeedsYou)
        assertTrue(NotifyLogic.diff(listOf(bot(needs = true)), listOf(bot(needs = true)), null).isEmpty())
        assertTrue(NotifyLogic.diff(listOf(bot(needs = true)), listOf(bot()), null).isEmpty())
    }

    @Test fun unreadIncreaseAfterTurnNotifies() {
        val e = NotifyLogic.diff(listOf(bot(working = true)), listOf(bot(unread = 1)), null)
        assertTrue(e.single() is NotifyEvent.Responded)
        assertTrue(NotifyLogic.diff(listOf(bot(unread = 1)), listOf(bot(unread = 2)), null).single() is NotifyEvent.Responded)
    }

    @Test fun noNotificationWhileStillWorkingOrWhenUnreadDrops() {
        assertTrue(NotifyLogic.diff(listOf(bot(working = true)), listOf(bot(working = true, unread = 1)), null).isEmpty())
        assertTrue(NotifyLogic.diff(listOf(bot(unread = 2)), listOf(bot(unread = 1)), null).isEmpty())
        assertTrue(NotifyLogic.diff(listOf(bot(working = true, unread = 1)), listOf(bot(unread = 0)), null).isEmpty())
    }

    @Test fun turnEndsWithUnreadBumpedEarlierStillNotifies() {
        assertTrue(NotifyLogic.diff(listOf(bot(working = true, unread = 1)), listOf(bot(unread = 1)), null).single() is NotifyEvent.Responded)
    }

    @Test fun visibleConversationIsSilent() {
        assertTrue(NotifyLogic.diff(listOf(bot("a"), bot("b")), listOf(bot("a", needs = true), bot("b", needs = true)), "a")
            .map { it.bot.id } == listOf("b"))
    }

    @Test fun newBotAppearingIsIgnored() {
        assertTrue(NotifyLogic.diff(listOf(bot("a")), listOf(bot("a"), bot("n", needs = true, unread = 1)), null).isEmpty())
    }

    @Test fun notificationButtonsOnlyForPlainPermission() {
        assertTrue(NotifyLogic.canActFromNotification(ApprovalInfo(kind = "permission")))
        assertFalse(NotifyLogic.canActFromNotification(ApprovalInfo(kind = "permission", dangerous = true)))
        assertFalse(NotifyLogic.canActFromNotification(ApprovalInfo(kind = "question")))
        assertFalse(NotifyLogic.canActFromNotification(ApprovalInfo(kind = "permission", decision = "once")))
        assertFalse(NotifyLogic.canActFromNotification(null))
    }
}
