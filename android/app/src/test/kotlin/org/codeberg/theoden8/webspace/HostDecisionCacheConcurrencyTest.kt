// FastSubresourceInterceptor's per-host cache under the load it really sees
// (BUG-007 attempt 3): chromium runs checkUrl on several sub-resource IO
// threads at once while the plugin clears the cache from the main thread.
// Pins no throw, no deadlock and no wrong verdict. A HotSpot LinkedHashMap
// rarely corrupts visibly under this load even unlocked, so the lock itself
// is pinned by SiteEventInboxTest's stress (same Guarded, fails without its
// monitor) and the cache's use of Guarded by native_shared_state.test.js.
package org.codeberg.theoden8.webspace

import com.pichillilorenzo.flutter_inappwebview_android.types.WebResourceRequestExt
import com.pichillilorenzo.flutter_inappwebview_android.webview.in_app_webview.InAppWebView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.mockito.kotlin.mock
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger

class HostDecisionCacheConcurrencyTest {

    @Test
    fun concurrentChecksEvictionsAndClearsKeepEveryVerdict() {
        val trackers = (0 until 64).map { "t$it.tracker.example" }
        val blocklist = DnsHostBlocklist().apply {
            replaceFromBlob("#1\n" + trackers.joinToString("\n"))
        }
        val wrong = AtomicInteger()
        val checked = AtomicInteger()
        val interceptor = FastSubresourceInterceptor(
            dnsBlocklist = blocklist,
            dnsLevel = 1,
            cdnTables = LocalCdnTables(),
            onBlockChecked = { event ->
                checked.incrementAndGet()
                if (event.blocked != event.host.endsWith(".tracker.example")) {
                    wrong.incrementAndGet()
                }
            },
            onCdnReplaced = {},
        )
        val webView: InAppWebView = mock()
        val failures = ConcurrentLinkedQueue<Throwable>()

        fun worker(body: () -> Unit) = Thread(body).apply {
            setUncaughtExceptionHandler { _, e -> failures += e }
        }

        // More distinct allowed hosts than the cache holds, so every thread
        // is evicting while the others read.
        val checkers = (0 until 8).map { t ->
            worker {
                repeat(PER_THREAD) { i ->
                    val host = if (i % 2 == 0) trackers[i % trackers.size]
                    else "h${(t * PER_THREAD + i) % HOSTS}.example.org"
                    interceptor.checkUrl(webView, WebResourceRequestExt(
                        "https://$host/x.js", emptyMap(), false, false, false, "GET"))
                }
            }
        }
        val clearer = worker {
            repeat(1_000) {
                interceptor.clearHostDecisionCache()
                Thread.yield()
            }
        }
        (checkers + clearer).forEach { it.start() }
        (checkers + clearer).forEach { it.join(30_000) }
        (checkers + clearer).forEach { assertFalse("thread stuck", it.isAlive) }

        assertEquals(emptyList<Throwable>(), failures.toList())
        assertEquals(8 * PER_THREAD, checked.get())
        assertEquals(0, wrong.get())
    }

    private companion object {
        const val PER_THREAD = 10_000
        const val HOSTS = 4_000
    }
}
