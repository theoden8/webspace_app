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
import java.util.concurrent.atomic.AtomicBoolean

/**
 * A pair the [Splicer] holds lasts no longer than its lease: a pair whose
 * lease went stale before it registered is closed as it registers, and one
 * registered before is closed by the next sweep (PROXY-028).
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
        val splicer = Splicer(log = {}, stale = { stale.get() })
        server().use { server ->
            Link(server).use { a ->
                Link(server).use { b ->
                    splicer.adopt(a.channel, b.channel, lease = lease)
                    a.peer.getOutputStream().write("ping".toByteArray())
                    val back = ByteArray(4)
                    var off = 0
                    while (off < back.size) off += b.peer.getInputStream().read(back, off, back.size - off)
                    assertEquals("ping", back.toString(Charsets.ISO_8859_1))

                    stale.set(true)
                    splicer.sweep()
                    assertTrue("a sweep must close a pair whose lease went stale", a.closedUnanswered())
                    assertTrue(b.closedUnanswered())
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
                    splicer.adopt(a.channel, b.channel, lease = lease)
                    assertTrue("registering must close a pair whose lease is stale", a.closedUnanswered())
                    assertTrue(b.closedUnanswered())
                }
            }
        }
    }
}
