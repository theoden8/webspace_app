// JVM unit tests for FastSubresourceInterceptor.extractHost /
// stripRootDot — the host normalization every blocking layer on Android
// funnels through.
//
// The Dart mirror lives in test/host_lookup_test.dart; the two extractors
// are hand-kept in sync, so a case added on one side belongs on the other.
package org.codeberg.theoden8.webspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ExtractHostTest {

    private fun host(url: String): String? =
        FastSubresourceInterceptor.extractHost(url)

    private fun strip(url: String): String =
        FastSubresourceInterceptor.stripRootDot(url)

    @Test
    fun extractsPlainHosts() {
        assertEquals("example.com", host("https://example.com/path"))
        assertEquals("example.com", host("https://example.com"))
        assertEquals("example.com", host("https://example.com?q=1"))
        assertEquals("example.com", host("https://example.com:8080/path"))
        assertEquals("example.com", host("https://user:pass@example.com/"))
        assertEquals("example.com", host("HTTPS://EXAMPLE.COM/"))
        assertEquals("[2001:db8::1]", host("https://[2001:db8::1]:8443/foo"))
        assertNull(host("about:blank"))
        assertEquals("", host("file:///etc/hosts"))
    }

    @Test
    fun dropsTheFqdnRootDot() {
        assertEquals("tracker.example.com", host("https://tracker.example.com./collect"))
        assertEquals("tracker.example.com", host("https://tracker.example.com."))
        assertEquals("tracker.example.com", host("https://tracker.example.com.:8443/x"))
        assertEquals("tracker.example.com", host("https://user:pass@Tracker.Example.COM./x"))
    }

    @Test
    fun dropsAtMostOneRootDot() {
        // `example.com..` is not a valid FQDN form, so it stays unmatched
        // rather than folding onto `example.com`.
        assertEquals("example.com.", host("https://example.com../x"))
        assertEquals("https://example.com./x", strip("https://example.com../x"))
        assertEquals("", host("https://./x"))
    }

    @Test
    fun leavesIpv6LiteralsAlone() {
        assertEquals("[2001:db8::1]", host("https://[2001:db8::1]./"))
    }

    @Test
    fun stripRootDotRewritesOnlyTheHost() {
        // The engine parses the URL itself, so the dot has to come out of
        // the URL and nothing else may move — a path or query dot that
        // shifted would change what path-anchored rules match.
        assertEquals("https://tracker.example.com/collect",
            strip("https://tracker.example.com./collect"))
        assertEquals("https://example.com:8443/a./b.?q=x.",
            strip("https://example.com.:8443/a./b.?q=x."))
        assertEquals("https://user:pass@example.com/x",
            strip("https://user:pass@example.com./x"))
    }

    @Test
    fun stripRootDotLeavesUnaffectedUrlsAlone() {
        val plain = "https://example.com/path?q=1#f."
        assertEquals(plain, strip(plain))
        assertEquals("https://[2001:db8::1]./", strip("https://[2001:db8::1]./"))
        assertEquals("about:blank", strip("about:blank"))
    }
}
