// JVM unit test of what the Android interceptor decides for each sub-resource
// and what it reports for the site's counts (CB-003, CB-012): the DNS list
// first, the engine asked of a DNS block only to say whether it would stop it
// too, an engine block reported with the request its rule matched, and a
// redirect looked up for that same request. The native library does not load
// on the JVM, so the engine is a fake that records what it was asked.
package org.codeberg.theoden8.webspace

import com.pichillilorenzo.flutter_inappwebview_android.types.WebResourceRequestExt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class InterceptorDecisionTest {

    private class FakeEngine(
        private val blocks: Set<String>,
        override val active: Boolean = true,
    ) : RequestEngine {
        val asked = mutableListOf<AbpRequest>()
        val redirectsAsked = mutableListOf<AbpRequest>()

        override fun checkUrl(url: String, sourceUrl: String, requestType: String): Boolean {
            asked += AbpRequest(url, sourceUrl, requestType)
            return url in blocks
        }

        override fun redirectFor(url: String, sourceUrl: String, requestType: String): String? {
            redirectsAsked += AbpRequest(url, sourceUrl, requestType)
            return null
        }
    }

    private val events = mutableListOf<BlockEvent>()

    private fun interceptor(engine: RequestEngine, abpEnabled: Boolean = true) =
        FastSubresourceInterceptor(
            dnsBlocklist = DnsHostBlocklist().apply { replaceFromBlob("#1\ntracker.example") },
            dnsLevel = 1,
            abpEnabled = abpEnabled,
            localCdnEnabled = false,
            cdnTables = LocalCdnTables(),
            onBlockChecked = { events += it },
            onCdnReplaced = {},
            engine = engine,
        )

    private fun request(url: String) = WebResourceRequestExt(
        url, mapOf("Sec-Fetch-Dest" to "script", "Referer" to PAGE),
        /* isRedirect = */ false, /* hasGesture = */ false, /* isForMainFrame = */ false, "GET",
    )

    @Test
    fun anEngineBlockReportsTheRequestItsRuleMatched_CB012() {
        val engine = FakeEngine(blocks = setOf(AD))
        assertNotNull("the request is answered with no body", interceptor(engine).check(request(AD)))
        val judged = AbpRequest(AD, PAGE, "script")
        assertEquals(listOf(BlockEvent("ads.example", true, "abp", abp = judged)), events)
        assertEquals("a redirect is looked up for the request judged", listOf(judged), engine.redirectsAsked)
    }

    @Test
    fun aDnsBlockTheEngineWouldAlsoStopSaysSo_CB012() {
        interceptor(FakeEngine(blocks = setOf(TRACKER))).check(request(TRACKER))
        assertEquals(listOf(BlockEvent("tracker.example", true, "dns", alsoAbp = true)), events)
    }

    @Test
    fun aDnsBlockTheEngineLetsThroughIsDnsAlone_CB012() {
        val engine = FakeEngine(blocks = emptySet())
        assertNotNull(interceptor(engine).check(request(TRACKER)))
        assertEquals(listOf(BlockEvent("tracker.example", true, "dns")), events)
        assertEquals("never a redirect for a DNS block", emptyList<AbpRequest>(), engine.redirectsAsked)
    }

    @Test
    fun anAllowedRequestGoesOutAndIsReportedByHost_CB012() {
        val engine = FakeEngine(blocks = emptySet())
        assertNull(interceptor(engine).check(request(LIB)))
        assertEquals(listOf(BlockEvent("cdn.example", false, null)), events)
        assertEquals(listOf(AbpRequest(LIB, PAGE, "script")), engine.asked)
    }

    @Test
    fun withContentBlockingOffTheEngineIsNeverAsked_CB003() {
        val engine = FakeEngine(blocks = setOf(AD, TRACKER))
        val off = interceptor(engine, abpEnabled = false)
        assertNull(off.check(request(AD)))
        assertNotNull(off.check(request(TRACKER)))
        assertEquals(
            listOf(BlockEvent("ads.example", false, null), BlockEvent("tracker.example", true, "dns")),
            events,
        )
        assertEquals(emptyList<AbpRequest>(), engine.asked)
    }

    @Test
    fun anEngineThatHasNoRulesYetIsNeverAsked_CB003() {
        val engine = FakeEngine(blocks = setOf(AD), active = false)
        assertNull(interceptor(engine).check(request(AD)))
        assertEquals(listOf(BlockEvent("ads.example", false, null)), events)
        assertEquals(emptyList<AbpRequest>(), engine.asked)
    }

    private companion object {
        const val PAGE = "https://site.example/"
        const val AD = "https://ads.example/a.js"
        const val TRACKER = "https://tracker.example/t.js"
        const val LIB = "https://cdn.example/lib.js"
    }
}
