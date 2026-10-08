// The signal-then-pull protocol between chromium IO threads and Dart
// (BUG-007): IO threads record, the main thread is woken once per batch and
// drains. The wake hook stands in for mainHandler.post + invokeMethod; its
// `answered` is the MethodChannel.Result the plugin hands Dart.
package org.codeberg.theoden8.webspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class SiteEventInboxTest {

    private class Wake(val siteId: String, val answered: () -> Unit)

    private val wakes = mutableListOf<Wake>()
    private val inbox = SiteEventInbox<String> { siteId, answered ->
        wakes += Wake(siteId, answered)
    }

    @Test
    fun aBurstWakesOnceAndCountsRepeats() {
        repeat(100) { inbox.record("a", "cdn.example") }
        inbox.record("a", "tracker.example")
        assertEquals(1, wakes.size)
        assertEquals(mapOf("cdn.example" to 100, "tracker.example" to 1), inbox.take("a"))
        assertEquals(emptyMap<String, Int>(), inbox.take("a"))
    }

    @Test
    fun sitesWakeIndependently() {
        inbox.record("a", "x")
        inbox.record("b", "x")
        assertEquals(listOf("a", "b"), wakes.map { it.siteId })
    }

    @Test
    fun anEventAfterTheDrainWakesBeforeDartAnswers() {
        // Dart's handler drains, then returns; the answer arrives after the
        // drain. An event landing in between used to find the wake still
        // outstanding and stay pending until some later event woke the site,
        // which on a page that had gone quiet was never.
        inbox.record("a", "first")
        inbox.take("a")
        inbox.record("a", "between")
        assertEquals(2, wakes.size)
        wakes[0].answered()
        assertEquals(mapOf("between" to 1), inbox.take("a"))
    }

    @Test
    fun aStaleAnswerDoesNotRetireANewerWake() {
        inbox.record("a", "first")
        inbox.take("a")
        inbox.record("a", "second")
        wakes[0].answered()
        inbox.record("a", "third")
        assertEquals(2, wakes.size)
    }

    @Test
    fun anUndrainedWakeIsRetiredByItsAnswer() {
        // An error reply (Dart threw before fetching) must not leave the site
        // mute: the next event wakes again and the batch is still there.
        inbox.record("a", "first")
        wakes[0].answered()
        inbox.record("a", "second")
        assertEquals(2, wakes.size)
        assertEquals(mapOf("first" to 1, "second" to 1), inbox.take("a"))
    }

    @Test
    fun oneHostAllowedAndBlockedKeepsBothVerdicts() {
        // The engine decides per URL, so a host's page assets pass while its
        // ad paths are blocked. Keyed by host alone, every request in the
        // window took the first verdict and the blocks were counted allowed.
        val blocks = SiteEventInbox<BlockEvent> { _, _ -> }
        blocks.record("a", BlockEvent("www.example.com", false, null))
        repeat(3) { blocks.record("a", BlockEvent("www.example.com", true, "abp")) }
        blocks.record("a", BlockEvent("www.example.com", false, null))
        val rows = blocks.take("a").map { (event, count) -> event.toChannel(count) }
        assertEquals(
            listOf(
                mapOf("host" to "www.example.com", "blocked" to false, "count" to 2),
                mapOf("host" to "www.example.com", "blocked" to true, "source" to "abp", "count" to 3),
            ),
            rows,
        )
    }

    @Test
    fun concurrentRecordersLoseNothingAndLeaveNoSiteMute() {
        // The production shape: several IO threads record across sites while
        // the main thread answers each wake by draining. Every event recorded
        // must come out of exactly one drain, and once the recorders stop no
        // event may be left behind without a wake to fetch it.
        val sites = listOf("a", "b", "c", "d")
        val queue = LinkedBlockingQueue<Wake>()
        val stressed = SiteEventInbox<Int> { siteId, answered -> queue.put(Wake(siteId, answered)) }
        val drained = HashMap<String, Int>()
        val main = Thread {
            while (true) {
                val wake = queue.poll(2, TimeUnit.SECONDS) ?: break
                val batch = stressed.take(wake.siteId)
                drained.merge(wake.siteId, batch.values.sum(), Int::plus)
                wake.answered()
            }
        }
        val recorders = (0 until 8).map { t ->
            Thread {
                repeat(5_000) { i -> stressed.record(sites[(t + i) % sites.size], i % 37) }
            }
        }
        main.start()
        recorders.forEach { it.start() }
        recorders.forEach { it.join(10_000) }
        recorders.forEach { assertFalse("recorder stuck", it.isAlive) }
        main.join(30_000)
        assertFalse("drainer stuck", main.isAlive)
        assertEquals(sites.associateWith { 10_000 }, drained)
    }
}
