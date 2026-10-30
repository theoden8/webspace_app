package org.codeberg.theoden8.webspace.proxy

import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.Response
import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.clientContext
import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.fakeServer
import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.fakeTlsServer
import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.generateKeyStore
import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.readFully
import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.readLine
import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.readPreamble
import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.readResponse
import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.serverContext
import org.codeberg.theoden8.webspace.proxy.RelayTestSupport.withDefaultSslContext
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.BufferedInputStream
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * What a connection through the router costs and carries once admitted
 * (PROXY-013). A tunnel belongs to the one splice thread rather than to
 * workers of its own, and plain-http requests share one connection each
 * way, every request still admitted on its own credential, so reuse never
 * carries a request past the checks the first one met. A connection lasts
 * no longer than the route it was let through on (PROXY-028).
 */
class ProxyRelayConnectionsTest {

    private fun credential(user: String, token: String): String =
        ProxyRelay.base64("$user:$token".toByteArray())

    private val direct = ProxyRelay.UpstreamConfig(ProxyRelay.UpstreamType.DIRECT, "", 0, null, null)

    private fun httpUpstream(port: Int, user: String, pass: String) =
        ProxyRelay.UpstreamConfig(ProxyRelay.UpstreamType.HTTP, "127.0.0.1", port, user, pass)

    /** A router whose direct routes reach the loopback fakes with no system proxy. */
    private fun router(routes: Map<String, ProxyRelay.Route>): Pair<ProxyRelay, Int> {
        val relay = ProxyRelay(systemProxy = { Proxy.NO_PROXY })
        val port = relay.startRouter("c0ffee01")
        relay.setRoutes(routes)
        return Pair(relay, port)
    }

    /** A raw client of the relay, reading every response through one buffer. */
    private class Client(relay: ProxyRelay, port: Int) : AutoCloseable {
        val socket = Socket().apply {
            connect(InetSocketAddress(relay.host, port), 3000)
            soTimeout = 5000
        }
        val input: InputStream = BufferedInputStream(socket.getInputStream())

        fun send(text: String) {
            socket.getOutputStream().write(text.toByteArray(Charsets.ISO_8859_1))
            socket.getOutputStream().flush()
        }

        fun request(
            url: String,
            credential: String?,
            method: String = "GET",
            headers: List<String> = emptyList(),
            body: String = "",
        ): Response {
            val sb = StringBuilder("$method $url HTTP/1.1\r\nHost: ${java.net.URI(url).authority}\r\n")
            if (credential != null) sb.append("Proxy-Authorization: Basic $credential\r\n")
            headers.forEach { sb.append(it).append("\r\n") }
            if (body.isNotEmpty() && headers.none { it.startsWith("Transfer-Encoding:", true) }) {
                sb.append("Content-Length: ${body.length}\r\n")
            }
            sb.append("\r\n").append(body)
            send(sb.toString())
            return readResponse(input, method)
        }

        fun connect(authority: String, credential: String, payload: String = ""): String {
            send(
                "CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n" +
                    "Proxy-Authorization: Basic $credential\r\n\r\n$payload"
            )
            return readPreamble(input).requestLine
        }

        /** Send [text] and read it back, as an echoing origin answers. */
        fun echo(text: String) {
            send(text)
            val back = ByteArray(text.length)
            readFully(input, back)
            assertEquals(text, back.toString(Charsets.ISO_8859_1))
        }

        /** True when the relay closed this connection without another byte. */
        fun closedUnanswered(): Boolean = try {
            input.read() == -1
        } catch (e: SocketException) {
            true
        }

        override fun close() {
            runCatching { socket.close() }
        }
    }

    /**
     * An HTTP/1.1 server (an origin, or a proxy taking absolute-form
     * requests) that keeps each connection for as many requests as it is
     * sent, recording each with the connection it came on.
     */
    private class KeepAliveServer(
        /** Requests served on connection n before it is closed unannounced. */
        private val servesOn: (connection: Int) -> Int = { Int.MAX_VALUE },
        private val reply: (Seen) -> String = { okWith("ok") },
    ) : AutoCloseable {
        data class Seen(val connection: Int, val requestLine: String, val headers: List<String>, val body: String) {
            fun header(name: String): String? =
                headers.firstOrNull { it.startsWith("$name:", true) }?.substringAfter(':')?.trim()
        }

        val seen = ConcurrentLinkedQueue<Seen>()
        val connections = AtomicInteger(0)
        private val server: ServerSocket = fakeServer { sock -> serve(sock) }
        val port: Int get() = server.localPort

        private fun serve(sock: Socket) {
            val n = connections.incrementAndGet()
            val input = BufferedInputStream(sock.getInputStream())
            var served = 0
            while (served < servesOn(n)) {
                val head = readPreamble(input)
                if (head.requestLine.isEmpty()) return
                val request = Seen(n, head.requestLine, head.headers, readBody(input, head.headers))
                seen.add(request)
                val response = reply(request)
                sock.getOutputStream().write(response.toByteArray(Charsets.ISO_8859_1))
                sock.getOutputStream().flush()
                served++
                if (response.contains("Connection: close")) return
            }
        }

        private fun readBody(input: InputStream, headers: List<String>): String {
            val te = headers.firstOrNull { it.startsWith("Transfer-Encoding:", true) }
            val cl = headers.firstOrNull { it.startsWith("Content-Length:", true) }
                ?.substringAfter(':')?.trim()?.toInt()
            val out = StringBuilder()
            if (te != null) {
                while (true) {
                    val size = readLine(input).substringBefore(';').trim().toInt(16)
                    if (size == 0) {
                        while (readLine(input).isNotEmpty()) Unit
                        break
                    }
                    val chunk = ByteArray(size); readFully(input, chunk)
                    out.append(chunk.toString(Charsets.ISO_8859_1))
                    readLine(input)
                }
            } else if (cl != null) {
                val b = ByteArray(cl); readFully(input, b)
                out.append(b.toString(Charsets.ISO_8859_1))
            }
            return out.toString()
        }

        override fun close() {
            runCatching { server.close() }
        }

        companion object {
            fun okWith(body: String) = "HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n\r\n$body"
        }
    }

    /** An origin that echoes what it reads and ends its side when the client ends its own. */
    private fun echoOrigin(): ServerSocket = fakeServer { sock ->
        sock.getInputStream().copyTo(sock.getOutputStream())
        sock.getOutputStream().flush()
        sock.shutdownOutput()
    }

    /** Ids of relay worker threads running relay code, i.e. holding a connection. */
    private fun busyWorkers(): Set<Long> =
        Thread.getAllStackTraces().filter { (t, stack) ->
            t.name == "proxy-relay-worker" &&
                stack.any { it.className.startsWith(ProxyRelay::class.java.name) }
        }.keys.map { it.id }.toSet()

    private fun spliceThreads(): Set<Thread> =
        Thread.getAllStackTraces().keys.filter { it.name == "proxy-relay-splice" && it.isAlive }.toSet()

    private fun <T> eventually(timeoutMs: Long = 3000, read: () -> T, done: (T) -> Boolean): T {
        val deadline = System.currentTimeMillis() + timeoutMs
        var value = read()
        while (!done(value) && System.currentTimeMillis() < deadline) {
            Thread.sleep(20)
            value = read()
        }
        return value
    }

    // --- Tunnels ---

    @Test(timeout = 30_000)
    fun openTunnelsHoldNoWorkerThreadAndTheSpliceThreadEndsWithTheLast() {
        val origin = echoOrigin()
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        val before = busyWorkers()
        val splicersBefore = spliceThreads()
        val clients = mutableListOf<Client>()
        try {
            repeat(16) { i ->
                val c = Client(relay, port)
                clients.add(c)
                val status = c.connect("127.0.0.1:${origin.localPort}", cred)
                assertTrue(status, status.contains("200"))
                c.send("ping$i")
                val echo = ByteArray("ping$i".length)
                readFully(c.input, echo)
                assertEquals("ping$i", echo.toString(Charsets.ISO_8859_1))
            }
            val held = eventually(read = { busyWorkers() - before }) { it.isEmpty() }
            assertTrue("16 open tunnels must hold no worker; ${held.size} do", held.isEmpty())
            val splicers = spliceThreads() - splicersBefore
            assertEquals("one splice thread carries every tunnel", 1, splicers.size)

            clients.forEach { it.close() }
            val left = eventually(read = { splicers.filter { it.isAlive } }) { it.isEmpty() }
            assertTrue("the splice thread must end with its last tunnel", left.isEmpty())
        } finally {
            clients.forEach { it.close() }
            relay.stop(); origin.close()
        }
    }

    @Test(timeout = 30_000)
    fun aTunnelCarriesMegabytesBothWaysPastAReaderThatFallsBehind() {
        val origin = echoOrigin()
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                c.socket.soTimeout = 15_000
                assertTrue(c.connect("127.0.0.1:${origin.localPort}", cred).contains("200"))
                val sent = ByteArray(8 * 1024 * 1024) { (it * 31 + (it shr 13)).toByte() }
                val writer = Thread {
                    c.socket.getOutputStream().write(sent)
                    c.socket.getOutputStream().flush()
                    c.socket.shutdownOutput()
                }.apply { isDaemon = true; start() }
                // Every buffer on the way fills before this side reads.
                Thread.sleep(500)
                val received = c.input.readBytes()
                writer.join(5000)
                assertEquals(sent.size, received.size)
                assertArrayEquals(sent, received)
            }
        } finally {
            relay.stop(); origin.close()
        }
    }

    @Test(timeout = 20_000)
    fun eachDirectionOfATunnelEndsOnItsOwn() {
        val heard = AtomicReference<String?>(null)
        val origin = fakeServer { sock ->
            sock.getOutputStream().write("bye".toByteArray())
            sock.getOutputStream().flush()
            sock.shutdownOutput()
            heard.set(sock.getInputStream().readBytes().toString(Charsets.ISO_8859_1))
        }
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                assertTrue(c.connect("127.0.0.1:${origin.localPort}", cred).contains("200"))
                assertEquals("bye", c.input.readBytes().toString(Charsets.ISO_8859_1))
                // The origin is done sending; what this side sends still arrives.
                c.send("late")
                c.socket.shutdownOutput()
                assertEquals("late", eventually(read = { heard.get() }) { it != null })
            }
        } finally {
            relay.stop(); origin.close()
        }
    }

    @Test(timeout = 20_000)
    fun bytesSentWithTheConnectReachTheOrigin() {
        val origin = echoOrigin()
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                // One write: the relay's buffer takes the payload with the preamble.
                val status = c.connect("127.0.0.1:${origin.localPort}", cred, payload = "hello")
                assertTrue(status, status.contains("200"))
                val echo = ByteArray(5)
                readFully(c.input, echo)
                assertEquals("hello", echo.toString(Charsets.ISO_8859_1))
            }
        } finally {
            relay.stop(); origin.close()
        }
    }

    // --- Plain http on one connection ---

    @Test(timeout = 20_000)
    fun requestsToOneOriginShareOneUpstreamConnection() {
        val origin = KeepAliveServer(reply = { KeepAliveServer.okWith(it.requestLine.split(' ')[1]) })
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                val base = "http://127.0.0.1:${origin.port}"
                val first = c.request("$base/a?x=1", cred)
                val second = c.request("$base/b", cred)
                assertEquals("/a?x=1", first.body)
                assertEquals("/b", second.body)
                assertEquals("keep-alive", first.header("Connection"))
            }
            assertEquals("one upstream connection for both", 1, origin.connections.get())
            assertEquals(listOf("GET /a?x=1 HTTP/1.1", "GET /b HTTP/1.1"), origin.seen.map { it.requestLine })
            assertTrue(
                "the relay's credential must not reach the origin",
                origin.seen.all { it.header("Proxy-Authorization") == null },
            )
        } finally {
            relay.stop(); origin.close()
        }
    }

    @Test(timeout = 20_000)
    fun aRequestToAnotherOriginOpensItsOwnUpstream() {
        val one = KeepAliveServer(reply = { KeepAliveServer.okWith("one") })
        val two = KeepAliveServer(reply = { KeepAliveServer.okWith("two") })
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                assertEquals("one", c.request("http://127.0.0.1:${one.port}/", cred).body)
                assertEquals("two", c.request("http://127.0.0.1:${two.port}/", cred).body)
                assertEquals("one", c.request("http://127.0.0.1:${one.port}/", cred).body)
            }
            assertEquals(2, one.seen.size)
            assertEquals(1, two.seen.size)
        } finally {
            relay.stop(); one.close(); two.close()
        }
    }

    @Test(timeout = 20_000)
    fun everyRequestOnAKeptConnectionIsAdmittedOnItsOwnCredential() {
        val origin = KeepAliveServer()
        val proxy = KeepAliveServer()
        val a = credential("ws-a", "token-a")
        val b = credential("ws-b", "token-b")
        val (relay, port) = router(
            mapOf(
                a to ProxyRelay.Route("a", direct),
                b to ProxyRelay.Route("b", httpUpstream(proxy.port, "user-b", "pass-b")),
            )
        )
        try {
            Client(relay, port).use { c ->
                assertEquals(200, c.request("http://127.0.0.1:${origin.port}/", a).status)
                assertEquals(200, c.request("http://127.0.0.1:${origin.port}/", b).status)
                val probe = c.request("http://n0nce${ProxyRelay.PROBE_SUFFIX}/", a)
                assertEquals(200, probe.status)
                assertEquals(mapOf("n0nce" to "a"), relay.probeObservations())
            }
            Client(relay, port).use { c ->
                assertEquals(200, c.request("http://127.0.0.1:${origin.port}/", a).status)
                assertEquals(502, c.request("http://127.0.0.1:${origin.port}/", credential("ws-x", "guess")).status)
                assertTrue(c.closedUnanswered())
            }
            Client(relay, port).use { c ->
                assertEquals(200, c.request("http://127.0.0.1:${origin.port}/", a).status)
                assertEquals(407, c.request("http://127.0.0.1:${origin.port}/", null).status)
            }
            assertEquals("only a's three requests reach the origin", 3, origin.seen.size)
            val viaProxy = proxy.seen.single()
            assertEquals("GET http://127.0.0.1:${origin.port}/ HTTP/1.1", viaProxy.requestLine)
            assertEquals(
                "Basic ${ProxyRelay.base64("user-b:pass-b".toByteArray())}",
                viaProxy.header("Proxy-Authorization"),
            )
        } finally {
            relay.stop(); origin.close(); proxy.close()
        }
    }

    @Test(timeout = 20_000)
    fun aProxyUpstreamCarriesRequestsForAnyHostOnOneConnection() {
        val proxy = KeepAliveServer(reply = { KeepAliveServer.okWith(it.requestLine.split(' ')[1]) })
        val cred = credential("ws-b", "token-b")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("b", httpUpstream(proxy.port, "u", "p"))))
        try {
            Client(relay, port).use { c ->
                assertEquals("http://one.test/x", c.request("http://one.test/x", cred).body)
                assertEquals("http://two.test/y", c.request("http://two.test/y", cred).body)
            }
            assertEquals(1, proxy.connections.get())
            val auth = "Basic ${ProxyRelay.base64("u:p".toByteArray())}"
            assertTrue(proxy.seen.all { it.header("Proxy-Authorization") == auth })
        } finally {
            relay.stop(); proxy.close()
        }
    }

    @Test(timeout = 20_000)
    fun bodiesAreFramedByLengthAndByChunks() {
        val origin = KeepAliveServer(
            reply = {
                when (it.requestLine.split(' ')[1]) {
                    "/chunked" -> "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
                        "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"
                    else -> KeepAliveServer.okWith("got:${it.body}")
                }
            },
        )
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                val base = "http://127.0.0.1:${origin.port}"
                assertEquals("got:abc", c.request("$base/len", cred, method = "POST", body = "abc").body)
                val chunkedBody = "4\r\nwxyz\r\n0\r\n\r\n"
                assertEquals(
                    "got:wxyz",
                    c.request(
                        "$base/up", cred, method = "POST",
                        headers = listOf("Transfer-Encoding: chunked"), body = chunkedBody,
                    ).body,
                )
                assertEquals("abcde", c.request("$base/chunked", cred).body)
                assertEquals("got:", c.request("$base/after", cred).body)
            }
            assertEquals(1, origin.connections.get())
            assertEquals(listOf("abc", "wxyz", "", ""), origin.seen.map { it.body })
        } finally {
            relay.stop(); origin.close()
        }
    }

    @Test(timeout = 20_000)
    fun responsesWithNoBodyEndWithTheirHead() {
        val origin = KeepAliveServer(
            reply = {
                when (it.requestLine.split(' ')[1]) {
                    "/head" -> "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n"
                    "/none" -> "HTTP/1.1 204 No Content\r\n\r\n"
                    "/same" -> "HTTP/1.1 304 Not Modified\r\nContent-Length: 50\r\n\r\n"
                    else -> KeepAliveServer.okWith("next")
                }
            },
        )
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                val base = "http://127.0.0.1:${origin.port}"
                assertEquals(200, c.request("$base/head", cred, method = "HEAD").status)
                assertEquals(204, c.request("$base/none", cred).status)
                assertEquals(304, c.request("$base/same", cred).status)
                assertEquals("next", c.request("$base/next", cred).body)
            }
            assertEquals(1, origin.connections.get())
        } finally {
            relay.stop(); origin.close()
        }
    }

    @Test(timeout = 20_000)
    fun aResponseWithNoLengthEndsTheConnection() {
        val origin = fakeServer { sock ->
            readPreamble(sock.getInputStream())
            sock.getOutputStream().write("HTTP/1.1 200 OK\r\nConnection: keep-alive\r\n\r\nstreamed".toByteArray())
            sock.getOutputStream().flush()
        }
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                val r = c.request("http://127.0.0.1:${origin.localPort}/", cred)
                assertEquals("streamed", r.body)
                assertEquals("close", r.header("Connection"))
            }
        } finally {
            relay.stop(); origin.close()
        }
    }

    @Test(timeout = 20_000)
    fun aClientThatAsksToCloseIsClosed() {
        val origin = KeepAliveServer()
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                val r = c.request("http://127.0.0.1:${origin.port}/", cred, headers = listOf("Connection: close"))
                assertEquals("close", r.header("Connection"))
                assertTrue(c.closedUnanswered())
            }
        } finally {
            relay.stop(); origin.close()
        }
    }

    @Test(timeout = 20_000)
    fun earlyHintsReachTheClientAheadOfTheResponse() {
        val origin = KeepAliveServer(
            reply = {
                "HTTP/1.1 103 Early Hints\r\nLink: </s.css>; rel=preload\r\n\r\n" + KeepAliveServer.okWith("page")
            },
        )
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                val hints = c.request("http://127.0.0.1:${origin.port}/", cred)
                assertEquals(103, hints.status)
                assertEquals("</s.css>; rel=preload", hints.header("Link"))
                assertEquals("page", readResponse(c.input).body)
                assertEquals(103, c.request("http://127.0.0.1:${origin.port}/", cred).status)
                assertEquals("page", readResponse(c.input).body)
            }
            assertEquals(1, origin.connections.get())
        } finally {
            relay.stop(); origin.close()
        }
    }

    @Test(timeout = 20_000)
    fun aGetOnAnUpstreamThatClosedWhileIdleGoesAgainOnAFreshOne() {
        val origin = KeepAliveServer(servesOn = { n -> if (n == 1) 1 else Int.MAX_VALUE })
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                val base = "http://127.0.0.1:${origin.port}"
                assertEquals(200, c.request("$base/a", cred).status)
                Thread.sleep(200)
                assertEquals(200, c.request("$base/b", cred).status)
            }
            assertEquals(2, origin.connections.get())
            assertEquals(listOf(1 to "GET /a HTTP/1.1", 2 to "GET /b HTTP/1.1"), origin.seen.map { it.connection to it.requestLine })
        } finally {
            relay.stop(); origin.close()
        }
    }

    @Test(timeout = 20_000)
    fun aPostOnAnUpstreamThatClosedWhileIdleIsLeftToTheClient() {
        val origin = KeepAliveServer(servesOn = { n -> if (n == 1) 1 else Int.MAX_VALUE })
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                val base = "http://127.0.0.1:${origin.port}"
                assertEquals(200, c.request("$base/a", cred).status)
                Thread.sleep(200)
                c.send(
                    "POST $base/b HTTP/1.1\r\nHost: 127.0.0.1\r\nProxy-Authorization: Basic $cred\r\n" +
                        "Content-Length: 4\r\n\r\nbody"
                )
                assertTrue("closed unanswered, so the client may resend it", c.closedUnanswered())
            }
            assertEquals("a POST is never sent twice by the relay", 1, origin.connections.get())
        } finally {
            relay.stop(); origin.close()
        }
    }

    @Test(timeout = 20_000)
    fun aConnectAfterPlainRequestsTunnels() {
        val origin = KeepAliveServer()
        val echo = echoOrigin()
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                assertEquals(200, c.request("http://127.0.0.1:${origin.port}/", cred).status)
                assertTrue(c.connect("127.0.0.1:${echo.localPort}", cred).contains("200"))
                c.send("through")
                val got = ByteArray(7)
                readFully(c.input, got)
                assertEquals("through", got.toString(Charsets.ISO_8859_1))
            }
        } finally {
            relay.stop(); origin.close(); echo.close()
        }
    }

    @Test(timeout = 20_000)
    fun anUpgradeIsAskedForAndThenSpliced() {
        val asked = AtomicReference<RelayTestSupport.Preamble?>(null)
        val upgraded = CountDownLatch(1)
        val origin = fakeServer { sock ->
            val input = BufferedInputStream(sock.getInputStream())
            asked.set(readPreamble(input))
            // The first frame rides in the same write as the 101.
            sock.getOutputStream().write(
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\nfirst"
                    .toByteArray()
            )
            sock.getOutputStream().flush()
            upgraded.countDown()
            input.copyTo(sock.getOutputStream())
        }
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                c.send(
                    "GET http://127.0.0.1:${origin.localPort}/ws HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
                        "Proxy-Authorization: Basic $cred\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
                )
                val head = readPreamble(c.input)
                assertTrue(head.requestLine, head.requestLine.contains("101"))
                assertTrue(upgraded.await(5, TimeUnit.SECONDS))
                val first = ByteArray(5)
                readFully(c.input, first)
                assertEquals("first", first.toString(Charsets.ISO_8859_1))
                c.send("echo")
                val back = ByteArray(4)
                readFully(c.input, back)
                assertEquals("echo", back.toString(Charsets.ISO_8859_1))
            }
            val request = asked.get()!!
            assertTrue(request.headers.toString(), request.headers.contains("Connection: Upgrade"))
            assertTrue(request.headers.toString(), request.headers.contains("Upgrade: websocket"))
            assertFalse(request.headers.any { it.startsWith("Proxy-Authorization:", true) })
        } finally {
            relay.stop(); origin.close()
        }
    }

    @Test(timeout = 20_000)
    fun aRequestNamingBothLengthsIsRefused() {
        val origin = KeepAliveServer()
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                c.send(
                    "POST http://127.0.0.1:${origin.port}/ HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
                        "Proxy-Authorization: Basic $cred\r\n" +
                        "Transfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n0\r\n\r\n"
                )
                // Only the head: the refused body is left unread, so the close may be a reset.
                val status = readPreamble(c.input).requestLine
                assertTrue(status, status.contains("400"))
            }
            assertEquals(0, origin.seen.size)
        } finally {
            relay.stop(); origin.close()
        }
    }

    // --- A route that moves (PROXY-028) ---

    @Test(timeout = 20_000)
    fun aTunnelLastsNoLongerThanItsRoute() {
        val origin = echoOrigin()
        val moved = credential("ws-a", "token-a")
        val removed = credential("ws-b", "token-b")
        val kept = credential("ws-c", "token-c")
        val (relay, port) = router(
            mapOf(
                moved to ProxyRelay.Route("a", direct),
                removed to ProxyRelay.Route("b", direct),
                kept to ProxyRelay.Route("c", direct),
            )
        )
        val clients = listOf(moved, removed, kept).map { cred ->
            Client(relay, port).also { c ->
                assertTrue(c.connect("127.0.0.1:${origin.localPort}", cred).contains("200"))
                c.echo("before")
            }
        }
        try {
            val (a, b, c) = clients
            // The table as a proxy edit sends it: the kept route parsed anew.
            relay.setRoutes(
                mapOf(
                    moved to ProxyRelay.Route("a", httpUpstream(1, "user", "pass")),
                    kept to ProxyRelay.Route("c", direct),
                )
            )
            assertTrue("a tunnel whose credential routes elsewhere must close", a.closedUnanswered())
            assertTrue("a tunnel whose credential routes nowhere must close", b.closedUnanswered())
            c.echo("after")
            Thread.sleep(100)
            c.echo("still")
        } finally {
            clients.forEach { it.close() }
            relay.stop(); origin.close()
        }
    }

    @Test(timeout = 20_000)
    fun stoppingTheRelayClosesItsTunnels() {
        val origin = echoOrigin()
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                assertTrue(c.connect("127.0.0.1:${origin.localPort}", cred).contains("200"))
                c.echo("before")
                relay.stop()
                assertTrue("a tunnel must not outlive the relay", c.closedUnanswered())
            }
        } finally {
            relay.stop(); origin.close()
        }
    }

    @Test(timeout = 30_000)
    fun aTunnelThroughATlsUpstreamLastsNoLongerThanItsRoute() {
        // Pumped on a worker rather than spliced, since its bytes pass the
        // upstream's TLS layer. The proxy echoes, and keeps its side open
        // after the relay's half-close, so only the relay's close of the
        // upstream frees the worker.
        val pki = generateKeyStore("CN=localhost", "dns:localhost")
        val released = CountDownLatch(1)
        val proxy = fakeTlsServer(serverContext(pki)) { sock ->
            val input = sock.getInputStream()
            readPreamble(input)
            sock.getOutputStream().write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray())
            sock.getOutputStream().flush()
            val buf = ByteArray(1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                sock.getOutputStream().write(buf, 0, n)
                sock.getOutputStream().flush()
            }
            released.await(20, TimeUnit.SECONDS)
        }
        val tls = ProxyRelay.UpstreamConfig(ProxyRelay.UpstreamType.HTTPS, "localhost", proxy.localPort, "user", "pass")
        val cred = credential("ws-a", "token-a")
        withDefaultSslContext(clientContext(pki)) {
            val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", tls)))
            val before = busyWorkers()
            try {
                Client(relay, port).use { c ->
                    assertTrue(c.connect("example.com:443", cred).contains("200"))
                    c.echo("before")
                    relay.setRoutes(mapOf(cred to ProxyRelay.Route("a", direct)))
                    assertTrue("a pumped tunnel must close with its route", c.closedUnanswered())
                }
                val held = eventually(read = { busyWorkers() - before }) { it.isEmpty() }
                assertTrue("the worker pumping it must be freed; ${held.size} still held", held.isEmpty())
            } finally {
                released.countDown()
                relay.stop(); proxy.close()
            }
        }
    }

    @Test(timeout = 20_000)
    fun anUpgradedConnectionLastsNoLongerThanItsRoute() {
        val origin = fakeServer { sock ->
            val input = BufferedInputStream(sock.getInputStream())
            readPreamble(input)
            sock.getOutputStream().write(
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
                    .toByteArray()
            )
            sock.getOutputStream().flush()
            input.copyTo(sock.getOutputStream())
        }
        val cred = credential("ws-a", "token-a")
        val (relay, port) = router(mapOf(cred to ProxyRelay.Route("a", direct)))
        try {
            Client(relay, port).use { c ->
                c.send(
                    "GET http://127.0.0.1:${origin.localPort}/ws HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
                        "Proxy-Authorization: Basic $cred\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
                )
                assertTrue(readPreamble(c.input).requestLine.contains("101"))
                c.echo("before")
                relay.setRoutes(emptyMap())
                assertTrue("an upgraded connection must close with its route", c.closedUnanswered())
            }
        } finally {
            relay.stop(); origin.close()
        }
    }
}
