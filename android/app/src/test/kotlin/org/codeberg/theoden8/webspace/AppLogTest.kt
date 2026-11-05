// DEVTOOLS-014: every line the Android code writes reaches each engine's Dart
// side once it listens, in the order written, the lines it missed first. A
// list sink stands in for the engine's channel.
package org.codeberg.theoden8.webspace

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class AppLogTest {
    private val got = mutableListOf<String>()
    private val sink = AppLog.Sink { lines -> synchronized(got) { lines.forEach { got += it.message } } }

    @Before
    fun reset() = AppLog.resetForTest()

    @After
    fun clean() = AppLog.resetForTest()

    @Test
    fun aListenerIsSentWhatItMissedOnceItListens() {
        AppLog.info(AppLog.Tag.backgroundTask, "before the engine")
        val attached = AppLog.listen(sink)
        AppLog.info(AppLog.Tag.backgroundTask, "before Dart listens")
        assertEquals(emptyList<String>(), got)
        attached.ready()
        AppLog.info(AppLog.Tag.backgroundTask, "after")
        assertEquals(listOf("before the engine", "before Dart listens", "after"), got)
    }

    @Test
    fun aFailureNamesWhatWasDoneAndItsCauses() {
        AppLog.listen(sink).ready()
        AppLog.failed(
            AppLog.Tag.htmlImport,
            "reading a shared file",
            IllegalStateException("closed", java.io.IOException("EPIPE")),
        )
        assertEquals(
            listOf("reading a shared file failed: IllegalStateException: closed, caused by IOException: EPIPE"),
            got,
        )
    }

    @Test
    fun aDetachedListenerIsSentNothing() {
        val attached = AppLog.listen(sink)
        attached.ready()
        attached.detach()
        AppLog.info(AppLog.Tag.contentBlocker, "gone")
        assertEquals(emptyList<String>(), got)
    }

    @Test
    fun onlyTheLatestLinesAreKeptForALateListener() {
        repeat(250) { AppLog.debug(AppLog.Tag.surfaceDiag, "line $it") }
        AppLog.listen(sink).ready()
        assertEquals(200, got.size)
        assertEquals("line 50", got.first())
        assertEquals("line 249", got.last())
    }

    // Lines written from many threads while a listener comes up reach it each
    // once, in the order the sink was given them (BUG-007: one monitor).
    @Test
    fun linesFromManyThreadsArriveOnceEach() {
        val attached = AppLog.listen(sink)
        val pool = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        repeat(8) { t ->
            pool.execute {
                start.await()
                repeat(20) { AppLog.debug(AppLog.Tag.contentBlocker, "$t:$it") }
            }
        }
        start.countDown()
        attached.ready()
        pool.shutdown()
        pool.awaitTermination(10, TimeUnit.SECONDS)
        assertEquals(160, got.size)
        assertEquals(160, got.toSet().size)
        for (t in 0 until 8) {
            val mine = got.filter { it.startsWith("$t:") }
            assertEquals((0 until 20).map { "$t:$it" }, mine)
        }
    }
}
