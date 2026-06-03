package org.codeberg.theoden8.webspace.proxy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * JVM unit tests for [ProxyRelay] — no Android framework, no emulator.
 * Each test stands up a fake upstream (HTTP proxy / SOCKS5) and a fake
 * origin on loopback, drives a client through the relay, and asserts the
 * upstream saw the right credentials.
 */
class ProxyRelayTest {

    @Test
    fun base64_matchesKnownVectors() {
        assertEquals("", ProxyRelay.base64("".toByteArray()))
        assertEquals("Zg==", ProxyRelay.base64("f".toByteArray()))
        assertEquals("Zm8=", ProxyRelay.base64("fo".toByteArray()))
        assertEquals("Zm9v", ProxyRelay.base64("foo".toByteArray()))
        assertEquals("dXNlcjpwYXNz", ProxyRelay.base64("user:pass".toByteArray()))
    }

    @Test
    fun randomPort_distinctInstancesGetIndependentLoopbackPorts() {
        val a = ProxyRelay()
        val b = ProxyRelay()
        try {
            val cfg = ProxyRelay.UpstreamConfig(ProxyRelay.UpstreamType.HTTP, "127.0.0.1", 1, null, null)
            val pa = a.start(cfg)
            val pb = b.start(cfg)
            assertTrue("port must be a real ephemeral port", pa in 1..65535)
            assertTrue(pb in 1..65535)
            assertNotEquals("two relays must not share a port", pa, pb)
            assertTrue(a.isRunning())
            // Idempotent: same config returns the same port without rebinding.
            assertEquals(pa, a.start(cfg))
        } finally {
            a.stop(); b.stop()
        }
    }

    @Test
    fun httpProxyUpstream_connectInjectsProxyAuthorization() {
        val origin = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")
        val seenAuth = AtomicReference<String?>(null)
        val proxy = fakeServer { sock ->
            val req = readPreamble(sock.getInputStream())
            seenAuth.set(req.headers.firstOrNull { it.startsWith("Proxy-Authorization:", true) })
            sock.getOutputStream().write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray())
            sock.getOutputStream().flush()
            spliceTo(sock, origin.localPort)
        }
        val relay = ProxyRelay()
        try {
            val port = relay.start(
                ProxyRelay.UpstreamConfig(
                    ProxyRelay.UpstreamType.HTTP, "127.0.0.1", proxy.localPort, "user", "pass",
                )
            )
            val body = clientConnectThenGet(port, "example.com", 443)
            assertTrue("origin response should reach the client", body.contains("hi"))
            assertEquals(
                "Proxy-Authorization: Basic ${ProxyRelay.base64("user:pass".toByteArray())}",
                seenAuth.get(),
            )
        } finally {
            relay.stop(); proxy.close(); origin.close()
        }
    }

    @Test
    fun socks5Upstream_performsUsernamePasswordHandshake() {
        val origin = fakeOrigin("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        val seenUser = AtomicReference<String?>(null)
        val seenPass = AtomicReference<String?>(null)
        val socks = fakeServer { sock ->
            val ins = sock.getInputStream()
            val out = sock.getOutputStream()
            // Greeting.
            val ver = ins.read(); val nm = ins.read()
            val methods = ByteArray(nm); readFully(ins, methods)
            assertEquals(0x05, ver)
            assertTrue("client must offer user/pass auth", methods.any { it.toInt() == 0x02 })
            out.write(byteArrayOf(0x05, 0x02)); out.flush()
            // RFC 1929 auth.
            assertEquals(0x01, ins.read())
            val ul = ins.read(); val ub = ByteArray(ul); readFully(ins, ub)
            val pl = ins.read(); val pb = ByteArray(pl); readFully(ins, pb)
            seenUser.set(String(ub)); seenPass.set(String(pb))
            out.write(byteArrayOf(0x01, 0x00)); out.flush()
            // CONNECT request.
            val head = ByteArray(4); readFully(ins, head)
            assertEquals(0x01, head[1].toInt()) // CMD=connect
            val hl = ins.read(); readFully(ins, ByteArray(hl)); readFully(ins, ByteArray(2))
            out.write(byteArrayOf(0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0)); out.flush()
            spliceTo(sock, origin.localPort)
        }
        val relay = ProxyRelay()
        try {
            val port = relay.start(
                ProxyRelay.UpstreamConfig(
                    ProxyRelay.UpstreamType.SOCKS5, "127.0.0.1", socks.localPort, "alice", "s3cret",
                )
            )
            val body = clientConnectThenGet(port, "example.com", 443)
            assertTrue(body.contains("ok"))
            assertEquals("alice", seenUser.get())
            assertEquals("s3cret", seenPass.get())
        } finally {
            relay.stop(); socks.close(); origin.close()
        }
    }

    @Test
    fun failClosed_unreachableUpstreamYields502NotDirect() {
        // Upstream points at a closed port: the relay must answer 502 and
        // never open a direct connection to the origin.
        val deadPort = ServerSocket(0).use { it.localPort }
        val relay = ProxyRelay()
        try {
            val port = relay.start(
                ProxyRelay.UpstreamConfig(
                    ProxyRelay.UpstreamType.HTTP, "127.0.0.1", deadPort, "user", "pass",
                )
            )
            Socket().use { c ->
                c.connect(InetSocketAddress("127.0.0.1", port), 2000)
                c.getOutputStream().write(
                    "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".toByteArray()
                )
                c.getOutputStream().flush()
                val status = readPreamble(c.getInputStream()).requestLine
                assertTrue("expected 502, got: $status", status.contains("502"))
            }
        } finally {
            relay.stop()
        }
    }

    // --- helpers ---

    private data class Preamble(val requestLine: String, val headers: List<String>)

    private fun readPreamble(ins: InputStream): Preamble {
        val sb = StringBuilder()
        var last4 = 0
        while (true) {
            val b = ins.read()
            if (b < 0) break
            sb.append(b.toChar())
            last4 = (last4 shl 8) or b
            if (last4 == 0x0D0A0D0A) break
        }
        val lines = sb.toString().split("\r\n").filter { it.isNotEmpty() }
        return Preamble(lines.firstOrNull() ?: "", lines.drop(1))
    }

    private fun readFully(ins: InputStream, buf: ByteArray) {
        var off = 0
        while (off < buf.size) {
            val n = ins.read(buf, off, buf.size - off)
            if (n < 0) throw IllegalStateException("eof")
            off += n
        }
    }

    private fun clientConnectThenGet(relayPort: Int, host: String, port: Int): String {
        Socket().use { c ->
            c.connect(InetSocketAddress("127.0.0.1", relayPort), 3000)
            val out = c.getOutputStream()
            out.write("CONNECT $host:$port HTTP/1.1\r\nHost: $host:$port\r\n\r\n".toByteArray())
            out.flush()
            val established = readPreamble(c.getInputStream())
            assertTrue("CONNECT should succeed: ${established.requestLine}", established.requestLine.contains("200"))
            out.write("GET / HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n".toByteArray())
            out.flush()
            return c.getInputStream().readBytes().toString(Charsets.ISO_8859_1)
        }
    }

    private fun fakeOrigin(response: String): ServerSocket {
        val server = ServerSocket()
        server.bind(InetSocketAddress(InetAddress.getLoopbackAddress(), 0))
        Thread {
            while (!server.isClosed) {
                val s = try { server.accept() } catch (e: Exception) { break }
                Thread {
                    try {
                        readPreamble(s.getInputStream())
                        s.getOutputStream().write(response.toByteArray())
                        s.getOutputStream().flush()
                    } catch (e: Exception) {
                    } finally { runCatching { s.close() } }
                }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true }.start()
        return server
    }

    private fun fakeServer(handler: (Socket) -> Unit): ServerSocket {
        val server = ServerSocket()
        server.bind(InetSocketAddress(InetAddress.getLoopbackAddress(), 0))
        Thread {
            while (!server.isClosed) {
                val s = try { server.accept() } catch (e: Exception) { break }
                Thread {
                    try { handler(s) } catch (e: Exception) { } finally { runCatching { s.close() } }
                }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true }.start()
        return server
    }

    private fun spliceTo(client: Socket, originPort: Int) {
        val origin = Socket()
        origin.connect(InetSocketAddress("127.0.0.1", originPort), 3000)
        val latch = CountDownLatch(2)
        Thread {
            runCatching { client.getInputStream().copyTo(origin.getOutputStream()); origin.getOutputStream().flush() }
            runCatching { origin.shutdownOutput() }
            latch.countDown()
        }.apply { isDaemon = true }.start()
        Thread {
            runCatching { origin.getInputStream().copyTo(client.getOutputStream()); client.getOutputStream().flush() }
            runCatching { client.shutdownOutput() }
            latch.countDown()
        }.apply { isDaemon = true }.start()
        latch.await(10, TimeUnit.SECONDS)
        runCatching { origin.close() }
    }
}
