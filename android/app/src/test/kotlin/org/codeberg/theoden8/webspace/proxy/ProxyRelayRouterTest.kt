package org.codeberg.theoden8.webspace.proxy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.fakeOrigin
import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.fakeServer
import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.readPreamble
import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.spliceTo
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Router mode: one relay fronting N per-site upstreams at once, picking
 * per connection from the credential the WebView presents (PROXY-013).
 *
 * Two properties are under test and they are not the same thing:
 *
 *  - **Routing.** A connection bearing site A's credential reaches site
 *    A's upstream and nothing else, concurrently with site B doing the
 *    same. This is what buys Android the per-site concurrency iOS gets
 *    from `WKWebsiteDataStore.proxyConfigurations`.
 *  - **Admission.** A connection bearing no credential, or one we do not
 *    recognise, reaches *no* upstream at all. Android shares the loopback
 *    interface across every installed app and offers no way to identify
 *    the peer of a local TCP connection, so this credential is the only
 *    admission control the relay's socket can have (LEAK-009).
 *
 * Every assertion about a request NOT being routed is made against a
 * counting upstream, so "the relay answered 407" and "the relay answered
 * 407 after quietly opening a tunnel" cannot pass as the same result.
 */
class ProxyRelayRouterTest {

    /** A fake HTTP proxy that counts inbound connections and records auth. */
    private class CountingUpstream(originPort: Int) {
        val connections = AtomicInteger(0)
        val seenAuth = ConcurrentLinkedQueue<String>()
        val server: ServerSocket = fakeServer { sock ->
            connections.incrementAndGet()
            val preamble = readPreamble(sock.getInputStream())
            preamble.headers
                .filter { it.startsWith("Proxy-Authorization:", true) }
                .forEach { seenAuth.add(it) }
            sock.getOutputStream().write(
                "HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray()
            )
            sock.getOutputStream().flush()
            spliceTo(sock, originPort)
        }
        val port: Int get() = server.localPort
        fun close() = server.close()
    }

    private fun credential(user: String, token: String): String =
        ProxyRelay.base64("$user:$token".toByteArray())

    private fun httpUpstream(port: Int, user: String?, pass: String?) =
        ProxyRelay.UpstreamConfig(ProxyRelay.UpstreamType.HTTP, "127.0.0.1", port, user, pass)

    /**
     * Open a CONNECT to the relay, optionally authenticated, and return
     * the relay's status line. Deliberately raw: the point is to behave
     * like any local process that found the port, not like a WebView.
     */
    private fun connectThrough(
        relayPort: Int,
        credential: String?,
        host: String = "example.com",
        dstPort: Int = 443,
    ): Pair<String, List<String>> {
        Socket().use { c ->
            c.connect(InetSocketAddress("127.0.0.1", relayPort), 3000)
            c.soTimeout = 5000
            val sb = StringBuilder()
            sb.append("CONNECT $host:$dstPort HTTP/1.1\r\nHost: $host:$dstPort\r\n")
            if (credential != null) sb.append("Proxy-Authorization: Basic $credential\r\n")
            sb.append("\r\n")
            c.getOutputStream().write(sb.toString().toByteArray())
            c.getOutputStream().flush()
            val p = readPreamble(c.getInputStream())
            return Pair(p.requestLine, p.headers)
        }
    }

    @Test
    fun unauthenticatedConnection_gets407AndNeverReachesAnyUpstream() {
        val origin = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        val upstream = CountingUpstream(origin.localPort)
        val relay = ProxyRelay()
        try {
            val port = relay.startRouter("deadbeef")
            relay.setRoutes(
                mapOf(
                    credential("ws-a", "token-a") to
                        ProxyRelay.Route("a", httpUpstream(upstream.port, "u", "p"))
                )
            )

            val (status, headers) = connectThrough(port, credential = null)

            assertTrue("expected a 407 challenge, got: $status", status.contains("407"))
            assertTrue(
                "challenge must name the configured realm",
                headers.any { it.contains("Proxy-Authenticate: Basic realm=\"deadbeef\"", true) },
            )
            assertEquals(
                "an unauthenticated caller must not reach any upstream",
                0, upstream.connections.get(),
            )
        } finally {
            relay.stop(); upstream.close(); origin.close()
        }
    }

    @Test
    fun unknownCredential_gets502AndNeverReachesAnyUpstream() {
        val origin = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        val upstream = CountingUpstream(origin.localPort)
        val relay = ProxyRelay()
        try {
            val port = relay.startRouter("cafe1234")
            relay.setRoutes(
                mapOf(
                    credential("ws-a", "token-a") to
                        ProxyRelay.Route("a", httpUpstream(upstream.port, "u", "p"))
                )
            )

            val (status, headers) = connectThrough(port, credential("ws-a", "guessed"))

            // 502 and not a second 407: a caller that is guessing must not
            // be handed a fresh challenge to iterate against.
            assertTrue("expected 502, got: $status", status.contains("502"))
            assertFalse(
                "an unknown credential must not be re-challenged",
                headers.any { it.startsWith("Proxy-Authenticate", true) },
            )
            assertEquals(
                "a caller with a bad credential must not reach any upstream",
                0, upstream.connections.get(),
            )
        } finally {
            relay.stop(); upstream.close(); origin.close()
        }
    }

    @Test
    fun eachCredentialRoutesToItsOwnUpstream() {
        val originA = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nA")
        val originB = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nB")
        val upstreamA = CountingUpstream(originA.localPort)
        val upstreamB = CountingUpstream(originB.localPort)
        val relay = ProxyRelay()
        try {
            val port = relay.startRouter("aaaa1111")
            val credA = credential("ws-a", "token-a")
            val credB = credential("ws-b", "token-b")
            relay.setRoutes(
                mapOf(
                    credA to ProxyRelay.Route("a", httpUpstream(upstreamA.port, "ua", "pa")),
                    credB to ProxyRelay.Route("b", httpUpstream(upstreamB.port, "ub", "pb")),
                )
            )

            assertTrue(connectThrough(port, credA).first.contains("200"))
            assertEquals("site A must reach upstream A", 1, upstreamA.connections.get())
            assertEquals("site A must not touch upstream B", 0, upstreamB.connections.get())

            assertTrue(connectThrough(port, credB).first.contains("200"))
            assertEquals("site B must reach upstream B", 1, upstreamB.connections.get())
            assertEquals("site B must not touch upstream A", 1, upstreamA.connections.get())
        } finally {
            relay.stop(); upstreamA.close(); upstreamB.close(); originA.close(); originB.close()
        }
    }

    @Test
    fun concurrentSites_holdTunnelsToDistinctUpstreamsAtTheSameTime() {
        // The whole point of router mode: two sites with different proxies
        // are live simultaneously, rather than one being unloaded so the
        // process-wide override can flip (PROXY-008's cost on Android).
        val originA = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nA")
        val originB = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nB")
        val bothConnected = CountDownLatch(2)
        val aCount = AtomicInteger(0)
        val bCount = AtomicInteger(0)

        fun gatedUpstream(originPort: Int, counter: AtomicInteger) = fakeServer { sock ->
            counter.incrementAndGet()
            readPreamble(sock.getInputStream())
            // Do not answer until BOTH upstreams have a live inbound
            // connection. If the relay serialised the two sites this
            // deadlocks and the latch times out.
            bothConnected.countDown()
            assertTrue(
                "both upstreams must be connected concurrently",
                bothConnected.await(10, TimeUnit.SECONDS),
            )
            sock.getOutputStream().write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray())
            sock.getOutputStream().flush()
            spliceTo(sock, originPort)
        }

        val upA = gatedUpstream(originA.localPort, aCount)
        val upB = gatedUpstream(originB.localPort, bCount)
        val relay = ProxyRelay()
        try {
            val port = relay.startRouter("beef0000")
            val credA = credential("ws-a", "token-a")
            val credB = credential("ws-b", "token-b")
            relay.setRoutes(
                mapOf(
                    credA to ProxyRelay.Route("a", httpUpstream(upA.localPort, "ua", "pa")),
                    credB to ProxyRelay.Route("b", httpUpstream(upB.localPort, "ub", "pb")),
                )
            )

            val results = ConcurrentLinkedQueue<String>()
            val done = CountDownLatch(2)
            for (cred in listOf(credA, credB)) {
                Thread {
                    runCatching { results.add(connectThrough(port, cred).first) }
                    done.countDown()
                }.apply { isDaemon = true }.start()
            }

            assertTrue("both sites should complete", done.await(20, TimeUnit.SECONDS))
            assertEquals(2, results.size)
            assertTrue("both CONNECTs should succeed: $results", results.all { it.contains("200") })
            assertEquals("upstream A saw exactly one site", 1, aCount.get())
            assertEquals("upstream B saw exactly one site", 1, bCount.get())
        } finally {
            relay.stop(); upA.close(); upB.close(); originA.close(); originB.close()
        }
    }

    @Test
    fun clientCredentialIsNeverForwardedUpstream() {
        // The per-site token authenticates the WebView to us. The upstream
        // gets the user's real proxy credentials and must never see ours,
        // or the proxy operator learns a value that admits its bearer to
        // every site's route.
        val origin = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        val upstream = CountingUpstream(origin.localPort)
        val relay = ProxyRelay()
        try {
            val port = relay.startRouter("f00dbabe")
            val cred = credential("ws-a", "super-secret-token")
            relay.setRoutes(
                mapOf(cred to ProxyRelay.Route("a", httpUpstream(upstream.port, "realuser", "realpass")))
            )

            assertTrue(connectThrough(port, cred).first.contains("200"))

            val forwarded = upstream.seenAuth.toList()
            assertTrue("upstream should see the user's own proxy auth", forwarded.isNotEmpty())
            val joined = forwarded.joinToString("\n")
            assertFalse(
                "the per-site token must not be forwarded upstream: $joined",
                joined.contains(cred),
            )
            assertTrue(
                "upstream should see the configured upstream credentials",
                joined.contains(ProxyRelay.base64("realuser:realpass".toByteArray())),
            )
        } finally {
            relay.stop(); upstream.close(); origin.close()
        }
    }

    @Test
    fun revokedCredentialStopsRouting() {
        val origin = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        val upstream = CountingUpstream(origin.localPort)
        val relay = ProxyRelay()
        try {
            val port = relay.startRouter("12345678")
            val cred = credential("ws-a", "token-a")
            relay.setRoutes(
                mapOf(cred to ProxyRelay.Route("a", httpUpstream(upstream.port, "u", "p")))
            )
            assertTrue(connectThrough(port, cred).first.contains("200"))
            assertEquals(1, upstream.connections.get())

            // Site deleted / proxy changed: its credential must stop working
            // immediately, without restarting the relay.
            relay.setRoutes(emptyMap())

            assertTrue(connectThrough(port, cred).first.contains("502"))
            assertEquals(
                "a revoked credential must not reach the upstream",
                1, upstream.connections.get(),
            )
        } finally {
            relay.stop(); upstream.close(); origin.close()
        }
    }

    @Test
    fun stoppingRelayClearsRoutesAndRealm() {
        val relay = ProxyRelay()
        val port = relay.startRouter("00ff00ff")
        relay.setRoutes(
            mapOf(credential("ws-a", "t") to ProxyRelay.Route("a", httpUpstream(1, null, null)))
        )
        relay.stop()
        assertFalse(relay.isRunning())
        // The port is released; nothing answers on it any more.
        val failure = runCatching {
            Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 500) }
        }.exceptionOrNull()
        assertNotNull("the relay port must be released on stop", failure)
    }

    @Test
    fun startRouter_rejectsRealmThatIsNotANonce() {
        val relay = ProxyRelay()
        try {
            // The realm is interpolated into a response header. Anything
            // but a hex nonce could carry a quote or CRLF into it.
            for (bad in listOf("", "has space", "quote\"", "crlf\r\nX: y", "UPPER")) {
                val thrown = runCatching { relay.startRouter(bad) }.exceptionOrNull()
                assertTrue(
                    "realm '$bad' should be rejected",
                    thrown is IllegalArgumentException,
                )
            }
        } finally {
            relay.stop()
        }
    }

    @Test
    fun directRouteReachesOriginWithoutAProxy() {
        // A site the user left on the system default still arrives here,
        // because ProxyController points every WebView at the relay. It
        // has to reach its origin unproxied.
        val origin = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\ndirect")
        val relay = ProxyRelay()
        try {
            val port = relay.startRouter("0d1acc70")
            val cred = credential("ws-plain", "token-plain")
            relay.setRoutes(
                mapOf(
                    cred to ProxyRelay.Route(
                        "plain",
                        ProxyRelay.UpstreamConfig(
                            ProxyRelay.UpstreamType.DIRECT, "", 0, null, null,
                        ),
                    )
                )
            )
            assertTrue(
                connectThrough(port, cred, host = "127.0.0.1", dstPort = origin.localPort)
                    .first.contains("200"),
            )
        } finally {
            relay.stop(); origin.close()
        }
    }

    @Test
    fun proxiedSiteNeverFallsBackToACoResidentDirectRoute() {
        // The regression that DIRECT makes possible: site A is configured
        // with a proxy that is down, site B is configured direct, and both
        // routes live in the same relay. A must get a 502 -- borrowing B's
        // direct path would hand A's origin the device's real IP, which is
        // exactly what A's proxy setting exists to prevent.
        val origin = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        val deadPort = ServerSocket(0).use { it.localPort }
        val relay = ProxyRelay()
        try {
            val port = relay.startRouter("dead0002")
            val credProxied = credential("ws-a", "token-a")
            val credDirect = credential("ws-b", "token-b")
            relay.setRoutes(
                mapOf(
                    credProxied to ProxyRelay.Route("a", httpUpstream(deadPort, "u", "p")),
                    credDirect to ProxyRelay.Route(
                        "b",
                        ProxyRelay.UpstreamConfig(
                            ProxyRelay.UpstreamType.DIRECT, "", 0, null, null,
                        ),
                    ),
                )
            )

            assertTrue(
                "a site with a dead proxy must fail closed, not go direct",
                connectThrough(port, credProxied, host = "127.0.0.1", dstPort = origin.localPort)
                    .first.contains("502"),
            )
            // ...while the genuinely-direct site is unaffected.
            assertTrue(
                connectThrough(port, credDirect, host = "127.0.0.1", dstPort = origin.localPort)
                    .first.contains("200"),
            )
        } finally {
            relay.stop(); origin.close()
        }
    }

    @Test
    fun backgroundSiteKeepsRoutingWithNoFurtherConfiguration() {
        // A notification / background-audio site polls while it is not the
        // visible one. The relay runs on daemon threads independent of the
        // Flutter engine, so once its route is installed it must keep
        // serving that site with no further Dart round-trip -- otherwise a
        // background poll would arrive while the engine is paused and be
        // answered 502.
        val originFg = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nF")
        val originBg = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nB")
        val upFg = CountingUpstream(originFg.localPort)
        val upBg = CountingUpstream(originBg.localPort)
        val relay = ProxyRelay()
        try {
            val port = relay.startRouter("bacc0001")
            val credFg = credential("ws-fg", "token-fg")
            val credBg = credential("ws-bg", "token-bg")
            relay.setRoutes(
                mapOf(
                    credFg to ProxyRelay.Route("fg", httpUpstream(upFg.port, "uf", "pf")),
                    credBg to ProxyRelay.Route("bg", httpUpstream(upBg.port, "ub", "pb")),
                )
            )

            // Interleave several polls from the background site with
            // foreground traffic, with no reconfiguration in between.
            repeat(5) {
                assertTrue(connectThrough(port, credBg).first.contains("200"))
                assertTrue(connectThrough(port, credFg).first.contains("200"))
            }

            assertEquals("every background poll reached its own upstream", 5, upBg.connections.get())
            assertEquals(5, upFg.connections.get())
        } finally {
            relay.stop(); upFg.close(); upBg.close(); originFg.close(); originBg.close()
        }
    }

    @Test
    fun probeIsAnsweredLocallyAndNeverReachesAnUpstream() {
        // The self-test must not be able to egress. If a probe could reach
        // an upstream it would be a new leak path opened by the very thing
        // meant to prove there is none.
        val origin = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        val upstream = CountingUpstream(origin.localPort)
        val relay = ProxyRelay()
        try {
            val port = relay.startRouter("9999aaaa")
            val cred = credential("ws-a", "token-a")
            relay.setRoutes(
                mapOf(cred to ProxyRelay.Route("a", httpUpstream(upstream.port, "u", "p")))
            )

            val status = connectThrough(
                port, cred, host = "n0nce${ProxyRelay.PROBE_SUFFIX}", dstPort = 80,
            ).first
            assertTrue("probe should be answered 200: $status", status.contains("200"))
            assertEquals(
                "a probe must never open an upstream connection",
                0, upstream.connections.get(),
            )
            assertEquals(mapOf("n0nce" to "a"), relay.probeObservations())
        } finally {
            relay.stop(); upstream.close(); origin.close()
        }
    }

    @Test
    fun probesRecordTheSiteWhoseCredentialCarriedThem() {
        // This is the attribution assertion itself, at the relay boundary:
        // nonce -> the site whose credential arrived with it. On a device
        // where Chromium replayed one site credential for both containers,
        // BOTH nonces would map to the same siteId and the app refuses to
        // activate router mode.
        val relay = ProxyRelay()
        try {
            val port = relay.startRouter("abcd0001")
            val credA = credential("ws-a", "token-a")
            val credB = credential("ws-b", "token-b")
            relay.setRoutes(
                mapOf(
                    credA to ProxyRelay.Route("a", httpUpstream(1, null, null)),
                    credB to ProxyRelay.Route("b", httpUpstream(1, null, null)),
                )
            )

            connectThrough(port, credA, host = "aaa${ProxyRelay.PROBE_SUFFIX}", dstPort = 80)
            connectThrough(port, credB, host = "bbb${ProxyRelay.PROBE_SUFFIX}", dstPort = 80)

            assertEquals(mapOf("aaa" to "a", "bbb" to "b"), relay.probeObservations())
        } finally {
            relay.stop()
        }
    }

    @Test
    fun probeFromAnUnknownCredentialRecordsNothing() {
        val relay = ProxyRelay()
        try {
            val port = relay.startRouter("abcd0002")
            relay.setRoutes(
                mapOf(credential("ws-a", "t") to ProxyRelay.Route("a", httpUpstream(1, null, null)))
            )
            val status = connectThrough(
                port, credential("ws-a", "guessed"),
                host = "xxx${ProxyRelay.PROBE_SUFFIX}", dstPort = 80,
            ).first
            assertTrue("expected 502, got $status", status.contains("502"))
            assertTrue(
                "an unadmitted caller must not be able to write probe observations",
                relay.probeObservations().isEmpty(),
            )
        } finally {
            relay.stop()
        }
    }

    @Test
    fun stoppingClearsProbeObservations() {
        val relay = ProxyRelay()
        val port = relay.startRouter("abcd0003")
        val cred = credential("ws-a", "t")
        relay.setRoutes(mapOf(cred to ProxyRelay.Route("a", httpUpstream(1, null, null))))
        connectThrough(port, cred, host = "zzz${ProxyRelay.PROBE_SUFFIX}", dstPort = 80)
        assertTrue(relay.probeObservations().isNotEmpty())
        relay.stop()
        assertTrue(relay.probeObservations().isEmpty())
    }

    @Test
    fun routerModeIsIdempotentForTheSameRealm() {
        val relay = ProxyRelay()
        try {
            val first = relay.startRouter("abcdef01")
            assertEquals("same realm must not rebind", first, relay.startRouter("abcdef01"))
            assertTrue(relay.isRunning())
        } finally {
            relay.stop()
        }
    }
}
