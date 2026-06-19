// JVM unit tests for DnsHostBlocklist — the host-only DNS blocklist extracted
// from WebInterceptPlugin. Runs via `./gradlew :app:testFdroidDebugUnitTest`
// (no device/emulator), so the parse + subdomain-match logic and the
// cold-start set-build cost are verifiable without an APK build.
package org.codeberg.theoden8.webspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DnsHostBlocklistTest {

    @Test
    fun emptyBlobBlocksNothing() {
        val b = DnsHostBlocklist()
        b.replaceFromBlob("")
        assertEquals(0, b.size)
        assertFalse(b.isBlocked("example.com"))
    }

    @Test
    fun exactHostMatches() {
        val b = DnsHostBlocklist()
        b.replaceFromBlob("ads.example.com\ntracker.net")
        assertEquals(2, b.size)
        assertTrue(b.isBlocked("ads.example.com"))
        assertTrue(b.isBlocked("tracker.net"))
        assertFalse(b.isBlocked("example.com"))
    }

    @Test
    fun subdomainOfABlockedDomainIsBlocked() {
        val b = DnsHostBlocklist()
        b.replaceFromBlob("example.com")
        assertTrue(b.isBlocked("a.b.example.com"))
        assertTrue(b.isBlocked("sub.example.com"))
        assertTrue(b.isBlocked("example.com"))
    }

    @Test
    fun bareTldIsNeverMatched() {
        // A blocklist entry of a bare eTLD must not nuke every site under it:
        // the suffix walk stops before the final label.
        val b = DnsHostBlocklist()
        b.replaceFromBlob("com")
        assertFalse(b.isBlocked("evil.com"))
        assertFalse(b.isBlocked("example.com"))
    }

    @Test
    fun noFalsePositiveOnSuffixOverlap() {
        // "example.com" must not match a different registrable domain that
        // merely ends with the same label run.
        val b = DnsHostBlocklist()
        b.replaceFromBlob("example.com")
        assertFalse(b.isBlocked("notexample.com"))
        assertFalse(b.isBlocked("badexample.com"))
    }

    @Test
    fun blankLinesIgnored() {
        val b = DnsHostBlocklist()
        b.replaceFromBlob("a.com\n\n\nb.com\n")
        assertEquals(2, b.size)
        assertTrue(b.isBlocked("a.com"))
        assertTrue(b.isBlocked("b.com"))
    }

    @Test
    fun replaceSwapsTheSet() {
        val b = DnsHostBlocklist()
        b.replaceFromBlob("old.com")
        assertTrue(b.isBlocked("old.com"))
        b.replaceFromBlob("new.com")
        assertFalse(b.isBlocked("old.com"))
        assertTrue(b.isBlocked("new.com"))
    }

    @Test
    fun buildsAndQueriesAFullSizedBlocklist() {
        // Mirrors the real cold-start input: a newline blob of ~650k domains.
        // Proves the pre-sized build is correct and fast at scale (the JVM
        // number is a floor; ART on-device is slower but the pre-size avoids
        // the ~20 rehashes a default-capacity HashSet would do here).
        val n = 646_269
        val sb = StringBuilder(n * 16)
        for (i in 0 until n) {
            if (i > 0) sb.append('\n')
            sb.append("d").append(i).append(".example")
        }
        val blob = sb.toString()

        val b = DnsHostBlocklist()
        val t0 = System.nanoTime()
        b.replaceFromBlob(blob)
        val ms = (System.nanoTime() - t0) / 1_000_000
        println("[dns-benchmark] built $n-entry blocklist in ${ms}ms")

        assertEquals(n, b.size)
        assertTrue(b.isBlocked("d0.example"))
        assertTrue(b.isBlocked("d${n - 1}.example"))
        assertTrue(b.isBlocked("sub.d42.example")) // subdomain walk
        assertFalse(b.isBlocked("nope.example"))
        // Loose ceiling — a regression guard, not a per-machine perf gate.
        assertTrue("build took ${ms}ms", ms < 10_000)
    }
}
