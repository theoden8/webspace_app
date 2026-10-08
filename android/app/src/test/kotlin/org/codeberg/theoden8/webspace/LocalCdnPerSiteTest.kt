// JVM unit tests for the per-site LocalCDN gate (LCDN-007): the cache is
// app-wide, so the interceptor's own flag is the only thing that keeps a site
// that turned LocalCDN off from being served from it.
package org.codeberg.theoden8.webspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.io.File

class LocalCdnPerSiteTest {

    private val url = "https://cdn.jsdelivr.net/npm/jquery@3.7.1/dist/jquery.min.js"
    private val pattern =
        Regex("""^https://cdn\.jsdelivr\.net/npm/([^@/]+)@([^/]+)/(.+)$""")
    private val tables = LocalCdnTables()
    private val replaced = mutableListOf<String>()

    @Before
    fun cacheOneFile() {
        val cached = File.createTempFile("jquery", ".js").apply {
            writeText("/* cached */")
            deleteOnExit()
        }
        tables.patterns = listOf(pattern)
        tables.index = mapOf("jquery/3.7.1/dist/jquery.min.js" to cached.path)
    }

    private fun interceptor(localCdnEnabled: Boolean) = FastSubresourceInterceptor(
        dnsBlocklist = DnsHostBlocklist(),
        localCdnEnabled = localCdnEnabled,
        cdnTables = tables,
        onBlockChecked = {},
        onCdnReplaced = { replaced += it.cacheKey },
        onLog = { _, _ -> },
    )

    @Test
    fun enabledSite_isServedFromTheCache() {
        assertNotNull(interceptor(localCdnEnabled = true).localCdnResponse(url))
        assertEquals(listOf("jquery/3.7.1/dist/jquery.min.js"), replaced)
    }

    @Test
    fun disabledSite_goesToTheNetwork() {
        assertNull(interceptor(localCdnEnabled = false).localCdnResponse(url))
        assertEquals(emptyList<String>(), replaced)
    }

    @Test
    fun aSettingsEdit_movesAnAttachedInterceptor() {
        val attached = interceptor(localCdnEnabled = true)
        attached.localCdnEnabled = false
        assertNull(attached.localCdnResponse(url))
        attached.localCdnEnabled = true
        assertNotNull(attached.localCdnResponse(url))
    }

    @Test
    fun emptyTables_goToTheNetwork() {
        tables.index = emptyMap()
        assertNull(interceptor(localCdnEnabled = true).localCdnResponse(url))
    }

    @Test
    fun uncachedUrl_goesToTheNetwork() {
        assertNull(interceptor(localCdnEnabled = true)
            .localCdnResponse("https://cdn.jsdelivr.net/npm/vue@3.4.0/dist/vue.js"))
    }
}
