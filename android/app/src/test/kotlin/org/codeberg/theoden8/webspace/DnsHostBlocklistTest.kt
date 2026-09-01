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
    fun fqdnRootDotDoesNotBypassTheSet() {
        // `https://ads.doubleclick.net./collect` resolves and renders exactly
        // like the dotless form. The suffix walk has no notion of a root
        // label — it would try `ads.doubleclick.net.`, `doubleclick.net.`,
        // `net.` and return ALLOWED — so normalization has to land in the
        // extractor, before the set is ever consulted.
        val b = DnsHostBlocklist()
        b.replaceFromBlob("doubleclick.net")
        assertTrue(b.isBlocked(hostOf("https://ads.doubleclick.net./collect")))
        assertTrue(b.isBlocked(hostOf("https://doubleclick.net.:443/x")))
        assertTrue(b.isBlocked(hostOf("https://DoubleClick.NET./x")))
        assertFalse(b.isBlocked(hostOf("https://notdoubleclick.net./x")))
    }

    private fun hostOf(url: String): String =
        FastSubresourceInterceptor.extractHost(url)!!

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
    fun awaitReadyReturnsImmediatelyWhenNothingBuilding() {
        // A site with no DNS blocklist never calls beginBuild, so readers must
        // not wait at all.
        val b = DnsHostBlocklist()
        val t0 = System.nanoTime()
        assertTrue(b.awaitReady(5_000))
        val ms = (System.nanoTime() - t0) / 1_000_000
        assertTrue("awaitReady should be instant, took ${ms}ms", ms < 500)
    }

    @Test
    fun awaitReadyBlocksUntilBackgroundBuildCompletes() {
        val b = DnsHostBlocklist()
        b.beginBuild()
        val t = Thread {
            Thread.sleep(150)
            b.replaceFromBlob("ads.example.com")
        }
        t.start()
        val t0 = System.nanoTime()
        assertTrue(b.awaitReady(5_000)) // blocks ~150ms until the build lands
        val ms = (System.nanoTime() - t0) / 1_000_000
        t.join()
        assertTrue("should have waited for the build, waited ${ms}ms", ms >= 100)
        assertTrue(b.isBlocked("ads.example.com"))
    }

    @Test
    fun awaitReadyTimesOutWhenBuildNeverCompletes() {
        val b = DnsHostBlocklist()
        b.beginBuild() // started, never completed
        val t0 = System.nanoTime()
        assertFalse(b.awaitReady(120))
        val ms = (System.nanoTime() - t0) / 1_000_000
        assertTrue("should wait ~timeout, waited ${ms}ms", ms >= 100)
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

    // --- per-site levels (DNS-020) ---------------------------------------

    @Test
    fun unmarkedBlobLoadsAtLevelOne() {
        val b = DnsHostBlocklist()
        b.replaceFromBlob("ads.example\ntracker.example")
        assertEquals(1, b.tierOf("ads.example"))
        assertEquals(listOf(1), b.levels)
    }

    @Test
    fun markersPartitionTheBlobByLevel() {
        val b = DnsHostBlocklist()
        b.replaceFromBlob("#1\nlight.example\n#3\npro.example\n#5\nultimate.example")
        assertEquals(3, b.size)
        assertEquals(1, b.tierOf("light.example"))
        assertEquals(3, b.tierOf("pro.example"))
        assertEquals(5, b.tierOf("ultimate.example"))
        assertEquals(0, b.tierOf("safe.example"))
        assertEquals(listOf(1, 3, 5), b.levels)
    }

    @Test
    fun aSiteBlocksItsOwnTierAndEveryTierBelow() {
        val b = DnsHostBlocklist()
        b.replaceFromBlob("#1\nlight.example\n#3\npro.example")
        assertTrue(b.isBlockedAt("light.example", 1))
        assertFalse(b.isBlockedAt("pro.example", 1))
        assertTrue(b.isBlockedAt("pro.example", 3))
        assertTrue(b.isBlockedAt("pro.example", 5))
    }

    @Test
    fun levelZeroBlocksNothing() {
        val b = DnsHostBlocklist()
        b.replaceFromBlob("#1\nads.example")
        assertFalse(b.isBlockedAt("ads.example", 0))
    }

    @Test
    fun subdomainsInheritTheirParentTier() {
        val b = DnsHostBlocklist()
        b.replaceFromBlob("#3\nads.example")
        assertEquals(3, b.tierOf("a.b.ads.example"))
        assertFalse(b.isBlockedAt("a.b.ads.example", 2))
        assertTrue(b.isBlockedAt("a.b.ads.example", 3))
    }

    @Test
    fun theLowestMatchingSuffixWins() {
        // The parent enters at 2, the child at 4: a site at level 2 already
        // blocks the parent, so it blocks the child too.
        val b = DnsHostBlocklist()
        b.replaceFromBlob("#2\nexample.co.uk\n#4\ndeep.example.co.uk")
        assertEquals(2, b.tierOf("deep.example.co.uk"))
    }

    @Test
    fun anOutOfRangeMarkerKeepsThePreviousLevel() {
        val b = DnsHostBlocklist()
        b.replaceFromBlob("#2\na.example\n#9\nb.example")
        assertEquals(2, b.tierOf("a.example"))
        assertEquals(2, b.tierOf("b.example"))
    }

}
