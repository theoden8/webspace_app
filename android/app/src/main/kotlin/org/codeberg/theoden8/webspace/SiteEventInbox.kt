package org.codeberg.theoden8.webspace

/**
 * Per-site events recorded on chromium IO threads for Dart to drain on the
 * main thread: counted per distinct event, announced by one wake per batch.
 *
 * A site is woken when an event lands and none of its wakes is outstanding.
 * [take] retires the outstanding wake along with the batch, so an event
 * recorded after a drain wakes again even while Dart is still answering the
 * wake that drained. The answer retires its wake only when no drain has, so a
 * wake Dart failed to drain cannot leave the site mute.
 *
 * [E] needs value equality (a data class): equal events share one count.
 */
class SiteEventInbox<E : Any>(
    private val wake: (siteId: String, answered: () -> Unit) -> Unit,
) {
    private class Batch<E> : LinkedHashMap<E, Int>() {
        var wake: Any? = null
    }

    private val batches = Guarded(HashMap<String, Batch<E>>())

    fun record(siteId: String, event: E) {
        val token = batches.with {
            val batch = getOrPut(siteId) { Batch() }
            batch[event] = (batch[event] ?: 0) + 1
            if (batch.wake != null) null else Any().also { batch.wake = it }
        } ?: return
        wake(siteId) {
            batches.with { get(siteId)?.takeIf { it.wake === token }?.wake = null }
        }
    }

    /**
     * Everything recorded for [siteId] since the last take, event to count.
     * The batch leaves the inbox, so the caller reads it without the lock.
     */
    fun take(siteId: String): Map<E, Int> = batches.with { remove(siteId) } ?: emptyMap()
}
