// JVM unit tests for a site's service workers under the Service workers
// experiment (CB-022): their requests reach the profile's client and never
// the webview's, so that client has to be the site's own interceptor.
package org.codeberg.theoden8.webspace

import android.webkit.ServiceWorkerClient
import com.pichillilorenzo.flutter_inappwebview_android.types.WebResourceRequestExt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ServiceWorkerBlockersTest {

    /// A profile's service workers as WebView keeps them: a block flag and
    /// one client, the last one set, with the order they were set in.
    private class FakeWorkers(var blocked: Boolean) : ProfileWorkers {
        override val name = "ws-site"
        var lastClient: ServiceWorkerClient? = null
        val writes = mutableListOf<String>()
        override var blockNetworkLoads: Boolean
            get() = blocked
            set(value) {
                writes += "blockNetworkLoads=$value"
                blocked = value
            }

        override fun setClient(client: ServiceWorkerClient) {
            writes += "client"
            lastClient = client
        }
    }

    private val logs = mutableListOf<String>()
    private val events = mutableListOf<BlockEvent>()
    private val blockers = ServiceWorkerBlockers { _, message -> logs += message }

    private val interceptor = FastSubresourceInterceptor(
        dnsBlocklist = DnsHostBlocklist().apply { replaceFromBlob("#1\ntracker.example") },
        dnsLevel = 1,
        abpEnabled = false,
        localCdnEnabled = false,
        cdnTables = LocalCdnTables(),
        onBlockChecked = { events += it },
        onCdnReplaced = {},
    )

    private fun request(host: String) = WebResourceRequestExt(
        "https://$host/sw-fetch", mapOf("Sec-Fetch-Dest" to "empty"),
        /* isRedirect = */ false, /* hasGesture = */ false, /* isForMainFrame = */ false, "GET",
    )

    private fun clientOf(workers: FakeWorkers) = workers.lastClient as SiteServiceWorkerClient

    @Test
    fun cb022_experimentOn_workersMeetTheSiteBlockers() {
        blockers.enabled = true
        val workers = FakeWorkers(blocked = true)
        blockers.attach(workers, interceptor, siteId = "site")

        assertEquals("the client goes in before the network opens",
            listOf("client", "blockNetworkLoads=false"), workers.writes)
        assertFalse("a worker reaches the network", workers.blocked)
        val client = clientOf(workers)
        assertNotNull("the site's DNS level blocks it", client.check(request("cdn.tracker.example")))
        assertNull("what the site's pages may load", client.check(request("example.org")))
        assertEquals(
            listOf(BlockEvent("cdn.tracker.example", true, "dns"), BlockEvent("example.org", false, null)),
            events,
        )
        assertTrue(logs.single(), logs.single().contains("network blocked was true"))
    }

    @Test
    fun cb022_aSettingsEditReachesTheWorkers() {
        blockers.enabled = true
        val workers = FakeWorkers(blocked = false)
        blockers.attach(workers, interceptor, siteId = "site")

        interceptor.dnsLevel = 0
        assertNull(clientOf(workers).check(request("cdn.tracker.example")))
    }

    @Test
    fun cb022_reattach_handsTheWorkersToTheNewView() {
        blockers.enabled = true
        val workers = FakeWorkers(blocked = true)
        blockers.attach(workers, interceptor, siteId = "site")
        val next = FastSubresourceInterceptor(
            dnsBlocklist = DnsHostBlocklist(),
            abpEnabled = false,
            cdnTables = LocalCdnTables(),
            onBlockChecked = {},
            onCdnReplaced = {},
        )
        blockers.attach(workers, next, siteId = "site")

        assertNull("the new view's interceptor answers", clientOf(workers).check(request("cdn.tracker.example")))
    }

    @Test
    fun cb022_experimentOff_leavesTheProfileAsItWas() {
        for (blocked in listOf(true, false)) {
            logs.clear()
            val workers = FakeWorkers(blocked = blocked)
            blockers.attach(workers, interceptor, siteId = "site")

            assertSame(null, workers.lastClient)
            assertEquals(emptyList<String>(), workers.writes)
            assertTrue(logs.single(), logs.single().contains("network blocked=$blocked (experiment off)"))
        }
    }

    @Test
    fun cb022_theDefaultProfile_isLeftToTheAppWideBlock() {
        blockers.enabled = true
        blockers.attach(null, interceptor, siteId = "site")
        assertEquals(emptyList<String>(), logs)
    }
}
