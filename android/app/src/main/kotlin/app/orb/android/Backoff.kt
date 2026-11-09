package app.orb.android

import kotlin.math.min

object Backoff {
    const val BASE_MS = 1_000L
    const val MAX_MS = 30_000L

    /**
     * Delay before reconnect attempt number [attempt] (0-based): doubles from 1 s up to 30 s, then "equal jitter"
     * ([random] in 0..1 picks a point in the upper half) so many phones do not retry in lockstep.
     */
    fun delayMs(attempt: Int, random: Double): Long {
        val exp = min(MAX_MS, BASE_MS shl attempt.coerceIn(0, 20))
        val ceiling = min(MAX_MS, exp)
        return (ceiling / 2 + (ceiling / 2 * random.coerceIn(0.0, 1.0))).toLong()
    }
}
