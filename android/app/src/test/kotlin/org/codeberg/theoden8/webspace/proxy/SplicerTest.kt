package org.codeberg.theoden8.webspace.proxy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketException
import java.nio.channels.ServerSocketChannel
import java.nio.channels.SocketChannel
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * A pair the [Splicer] holds lasts no longer than its lease: a pair whose
 * lease went stale before it registered is closed as it registers, and one
 * registered before is closed by the next sweep (PROXY-028). Each pair's end
 * logs which side ended it, with what error, and what each side sent, and a
 * side that failed ends the other with a reset (PROXY-033).
 */
class SplicerTest {

    private val lease = ProxyRelay.Lease(
        credential = "c",
        route = ProxyRelay.Route(
            "a",
            ProxyRelay.UpstreamConfig(ProxyRelay.UpstreamType.DIRECT, "", 0, null, null),
        ),
    )

    /** Two connected loopback sockets: the channel a splicer takes, and the peer a test drives. */
    private class Link(server: ServerSocketChannel) : AutoCloseable {
        val peer: Socket = Socket().apply {
            connect(server.socket().localSocketAddress, 3000)
            soTimeout = 5000
        }
        val channel: SocketChannel = server.accept()

        fun closedUnanswered(): Boolean = try {
            peer.getInputStream().read() == -1
        } catch (e: SocketException) {
            true
        }

        /** How the peer saw its side end: a close or a reset. */
        fun ending(): String = try {
            if (peer.getInputStream().read() == -1) "closed" else "data"
        } catch (e: SocketException) {
            "reset"
        }

        override fun close() {
            runCatching { peer.close() }
            runCatching { channel.close() }
        }
    }

    private fun server(): ServerSocketChannel =
        ServerSocketChannel.open().apply { bind(InetSocketAddress(InetAddress.getLoopbackAddress(), 0)) }

    @Test(timeout = 20_000)
    fun aPairLastsNoLongerThanItsLease() {
        val stale = AtomicBoolean(false)
        val logged = LinkedBlockingQueue<String>()
        val splicer = Splicer(log = { logged.add(it) }, stale = { stale.get() })
        server().use { server ->
            Link(server).use { a ->
                Link(server).use { b ->
                    splicer.adopt(a.channel, b.channel, lease = lease, label = LABEL)
                    a.peer.getOutputStream().write("ping".toByteArray())
                    val back = ByteArray(4)
                    var off = 0
                    while (off < back.size) off += b.peer.getInputStream().read(back, off, back.size - off)
                    assertEquals("ping", back.toString(Charsets.ISO_8859_1))

                    stale.set(true)
                    splicer.sweep()
                    assertTrue("a sweep must close a pair whose lease went stale", a.closedUnanswered())
                    assertTrue(b.closedUnanswered())
                    assertEquals("its route changed", cause(ended(logged)))
                }
            }
        }
    }

    @Test(timeout = 20_000)
    fun aPairWhoseLeaseWentStaleBeforeItRegistersIsClosed() {
        val splicer = Splicer(log = {}, stale = { true })
        server().use { server ->
            Link(server).use { a ->
                Link(server).use { b ->
                    splicer.adopt(a.channel, b.channel, lease = lease, label = LABEL)
                    assertTrue("registering must close a pair whose lease is stale", a.closedUnanswered())
                    assertTrue(b.closedUnanswered())
                }
            }
        }
    }

    @Test(timeout = 20_000)
    fun aTunnelsEndNamesTheSideThatClosedFirst() {
        val logged = LinkedBlockingQueue<String>()
        val splicer = Splicer(log = { logged.add(it) }, stale = { false })
        server().use { server ->
            Link(server).use { a ->
                Link(server).use { b ->
                    splicer.adopt(a.channel, b.channel, aFirst = "he".toByteArray(), lease = lease, label = LABEL)
                    a.peer.getOutputStream().write("llo".toByteArray())
                    val got = ByteArray(5)
                    var off = 0
                    while (off < got.size) off += b.peer.getInputStream().read(got, off, got.size - off)
                    assertEquals("hello", got.toString(Charsets.ISO_8859_1))
                    b.peer.close()
                    assertEquals("the upstream's close reaches the client as one", "closed", a.ending())
                    a.peer.close()
                    val line = ended(logged)
                    assertEquals(line, "the upstream closed first", cause(line))
                    assertTrue(line, line.endsWith("client sent 5 B, upstream sent 0 B"))
                }
            }
        }
    }

    @Test(timeout = 20_000)
    fun anUpstreamResetIsPassedOnAndNamedWithItsError() {
        val logged = LinkedBlockingQueue<String>()
        val splicer = Splicer(log = { logged.add(it) }, stale = { false })
        server().use { server ->
            Link(server).use { a ->
                Link(server).use { b ->
                    splicer.adopt(a.channel, b.channel, lease = lease, label = LABEL)
                    b.peer.setSoLinger(true, 0)
                    b.peer.close()
                    assertEquals("the upstream's reset reaches the client as one", "reset", a.ending())
                    val line = ended(logged)
                    assertTrue(line, cause(line).startsWith("reading from the upstream failed ("))
                    assertTrue(line, line.endsWith("client sent 0 B, upstream sent 0 B"))
                }
            }
        }
    }

    /** The end line the splicer logged for [LABEL], waiting for it. */
    private fun ended(logged: LinkedBlockingQueue<String>): String {
        while (true) {
            val line = logged.poll(5, TimeUnit.SECONDS) ?: throw AssertionError("no tunnel end was logged")
            if (line.startsWith("tunnel $LABEL ended after ")) return line
        }
    }

    /** What an end line gives as the reason the tunnel ended. */
    private fun cause(line: String): String =
        line.substringAfter(" ms: ").substringBeforeLast("; client sent")

    private companion object {
        const val LABEL = "CONNECT example.com:443 for a"
    }
}
