package org.codeberg.theoden8.webspace.proxy

import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import java.io.File
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.security.KeyStore
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.TrustManagerFactory

/**
 * Loopback scaffolding shared by the [ProxyRelay] test classes: fake
 * origins, fake HTTP/SOCKS5/TLS upstreams, and a raw proxy client.
 *
 * Extracted so the router tests drive the same fakes the single-upstream
 * tests do rather than growing a second, subtly different set.
 */
object RelayTestSupport {

    const val KEY_ALIAS = "upstream"
    const val KEY_PASS = "changeit"

    fun generateKeyStore(dname: String, san: String): KeyStore {
        val dir = Files.createTempDirectory("proxy-relay-tls").toFile()
        val file = File(dir, "upstream.p12")
        val keytool = File(File(System.getProperty("java.home"), "bin"), "keytool")
        val proc = ProcessBuilder(
            keytool.absolutePath,
            "-genkeypair", "-alias", KEY_ALIAS,
            "-keyalg", "RSA", "-keysize", "2048", "-sigalg", "SHA256withRSA",
            "-validity", "1",
            "-dname", dname,
            "-ext", "san=$san",
            "-keystore", file.absolutePath, "-storetype", "PKCS12",
            "-storepass", KEY_PASS, "-keypass", KEY_PASS,
        ).redirectErrorStream(true).start()
        val output = proc.inputStream.readBytes().toString(Charsets.UTF_8)
        assertTrue("keytool timed out", proc.waitFor(60, TimeUnit.SECONDS))
        assertTrue("keytool failed: $output", proc.exitValue() == 0)
        val ks = KeyStore.getInstance("PKCS12")
        file.inputStream().use { ks.load(it, KEY_PASS.toCharArray()) }
        file.delete(); dir.delete()
        return ks
    }

    fun serverContext(ks: KeyStore): SSLContext {
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(ks, KEY_PASS.toCharArray())
        return SSLContext.getInstance("TLS").apply { init(kmf.keyManagers, null, null) }
    }

    fun clientContext(ks: KeyStore): SSLContext {
        val trust = KeyStore.getInstance("JKS")
        trust.load(null, null)
        trust.setCertificateEntry(KEY_ALIAS, ks.getCertificate(KEY_ALIAS))
        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        tmf.init(trust)
        return SSLContext.getInstance("TLS").apply { init(null, tmf.trustManagers, null) }
    }

    /**
     * The relay reaches TLS through `SSLSocketFactory.getDefault()`, which
     * resolves `SSLContext.getDefault()` on every call — so swapping the
     * default is how a test gets its own trust anchors in without the relay
     * growing a seam that production would never use. Global JVM state:
     * restore it or every later test inherits this trust store.
     */
    fun <T> withDefaultSslContext(ctx: SSLContext, body: () -> T): T {
        val previous = SSLContext.getDefault()
        SSLContext.setDefault(ctx)
        try {
            return body()
        } finally {
            SSLContext.setDefault(previous)
        }
    }

    fun fakeTlsServer(ctx: SSLContext, handler: (Socket) -> Unit): ServerSocket {
        val server = ctx.serverSocketFactory.createServerSocket() as SSLServerSocket
        server.bind(InetSocketAddress(InetAddress.getByName("localhost"), 0))
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

    data class Preamble(val requestLine: String, val headers: List<String>)

    fun readPreamble(ins: InputStream): Preamble {
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

    data class Response(val statusLine: String, val headers: List<String>, val body: String) {
        val status: Int get() = statusLine.split(' ').getOrNull(1)?.toIntOrNull() ?: 0
        fun header(name: String): String? =
            headers.firstOrNull { it.startsWith("$name:", ignoreCase = true) }?.substringAfter(':')?.trim()
        override fun toString() = "$statusLine\r\n${headers.joinToString("\r\n")}\r\n\r\n$body"
    }

    /**
     * One response off a connection that may stay open after it: the body
     * by its Content-Length or chunks, else to the end of the stream.
     */
    fun readResponse(ins: InputStream, method: String = "GET"): Response {
        val head = readPreamble(ins)
        val r = Response(head.requestLine, head.headers, "")
        val status = r.status
        if (method == "HEAD" || status in 100..199 || status == 204 || status == 304) return r
        val body = java.io.ByteArrayOutputStream()
        val length = r.header("Content-Length")?.toInt()
        when {
            r.header("Transfer-Encoding")?.lowercase()?.endsWith("chunked") == true -> {
                while (true) {
                    val size = readLine(ins).substringBefore(';').trim().toInt(16)
                    if (size == 0) {
                        while (readLine(ins).isNotEmpty()) Unit
                        break
                    }
                    val chunk = ByteArray(size); readFully(ins, chunk); body.write(chunk)
                    readLine(ins)
                }
            }
            length != null -> { val b = ByteArray(length); readFully(ins, b); body.write(b) }
            else -> body.write(ins.readBytes())
        }
        return r.copy(body = body.toString(Charsets.ISO_8859_1.name()))
    }

    fun readLine(ins: InputStream): String {
        val sb = StringBuilder()
        while (true) {
            val b = ins.read()
            if (b < 0 || b == '\n'.code) break
            sb.append(b.toChar())
        }
        return sb.toString().removeSuffix("\r")
    }

    fun readFully(ins: InputStream, buf: ByteArray) {
        var off = 0
        while (off < buf.size) {
            val n = ins.read(buf, off, buf.size - off)
            if (n < 0) throw IllegalStateException("eof")
            off += n
        }
    }

    fun clientConnectThenGet(
        relayPort: Int,
        host: String,
        port: Int,
        relayHost: String = "127.0.0.1",
    ): String {
        Socket().use { c ->
            c.connect(InetSocketAddress(relayHost, relayPort), 3000)
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

    fun fakeOrigin(response: String): ServerSocket {
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

    fun fakeServer(handler: (Socket) -> Unit): ServerSocket {
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

    fun spliceTo(client: Socket, originPort: Int) {
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
