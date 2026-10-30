package org.codeberg.theoden8.webspace.proxy

import org.codeberg.theoden8.webspace.Guarded
import java.io.IOException
import java.nio.Buffer
import java.nio.ByteBuffer
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.nio.channels.SocketChannel

/**
 * Copies bytes both ways between established socket pairs on one thread,
 * so a tunnel that sits open holds no thread of its own.
 *
 * A relay worker does a connection's handshake with blocking I/O, then
 * [adopt]s the pair; from then on only the splice thread touches it. The
 * thread runs while it has pairs and exits once the last one closes, so an
 * idle relay keeps none. Each direction ends on its own: one side's end of
 * stream shuts the other side's output once what it sent has been written,
 * and the pair closes when both directions have ended or either side fails.
 *
 * Each pair carries the lease it was let through on, and a pair whose lease
 * went [stale] is closed: at registration, and at each [sweep] the relay asks
 * for when its route table moves (PROXY-028).
 */
internal class Splicer(
    private val log: (String) -> Unit,
    private val stale: (ProxyRelay.Lease) -> Boolean,
) {

    private class Handoff(
        val a: SocketChannel,
        val b: SocketChannel,
        val aFirst: ByteArray,
        val bFirst: ByteArray,
        val lease: ProxyRelay.Lease,
    )

    /** Handed over by workers, drained by the splice thread (BUG-007). */
    private class Inbox {
        val pending = ArrayDeque<Handoff>()
        var running = false
        var selector: Selector? = null
        var sweep = false
    }

    private val inbox = Guarded(Inbox())

    /**
     * Take over [a] and [b], both connected and in blocking mode, with the
     * bytes each side already sent that a worker read past its handshake.
     * The caller must not touch either channel afterwards.
     */
    fun adopt(
        a: SocketChannel,
        b: SocketChannel,
        aFirst: ByteArray = EMPTY,
        bFirst: ByteArray = EMPTY,
        lease: ProxyRelay.Lease,
    ) {
        val start = inbox.with {
            pending.addLast(Handoff(a, b, aFirst, bFirst, lease))
            if (!running) {
                running = true
                true
            } else {
                // A wakeup is a write to the selector's own pipe, never a
                // wait, and making it under the monitor is what keeps it off
                // a selector the thread has already closed.
                selector?.wakeup()
                false
            }
        }
        if (start) Thread({ run() }, "proxy-relay-splice").apply { isDaemon = true }.start()
    }

    /**
     * Close every pair whose lease went stale, on the splice thread, which
     * alone touches them. A pair still waiting to register is checked as it
     * registers.
     */
    fun sweep() {
        inbox.with {
            if (running) {
                sweep = true
                selector?.wakeup()
            }
        }
    }

    private class Flow(val from: SocketChannel, val to: SocketChannel, first: ByteArray) {
        val buf: ByteBuffer = ByteBuffer.allocate(maxOf(BUFFER, first.size)).put(first)
        var ended = false
        var shut = false

        val done: Boolean get() = shut
        val holds: Boolean get() = buf.position() > 0
    }

    private class Pair(
        val a: SocketChannel,
        val b: SocketChannel,
        aFirst: ByteArray,
        bFirst: ByteArray,
        val lease: ProxyRelay.Lease,
    ) {
        val ab = Flow(from = a, to = b, first = aFirst)
        val ba = Flow(from = b, to = a, first = bFirst)
        lateinit var keyA: SelectionKey
        lateinit var keyB: SelectionKey
    }

    private fun run() {
        var selector: Selector? = null
        var clean = false
        try {
            val open = Selector.open()
            selector = open
            inbox.with { this.selector = open }
            var live = 0
            while (true) {
                val batch = inbox.with {
                    val p = pending.toList()
                    pending.clear()
                    p
                }
                val sweeping = inbox.with {
                    val asked = sweep
                    sweep = false
                    asked
                }
                for (h in batch) {
                    if (register(open, h)) live++
                }
                if (sweeping) live -= closeStale(open)
                if (live == 0) {
                    clean = inbox.with {
                        if (pending.isEmpty()) {
                            running = false
                            this.selector = null
                            true
                        } else {
                            false
                        }
                    }
                    if (clean) return
                    continue
                }
                open.select()
                val ready = open.selectedKeys().iterator()
                while (ready.hasNext()) {
                    val key = ready.next()
                    ready.remove()
                    // A pair closed by its other key earlier in this round.
                    if (!key.isValid) continue
                    if (!step(key.attachment() as Pair)) live--
                }
            }
        } catch (e: IOException) {
            log("splice thread failed: ${e.javaClass.simpleName}")
        } finally {
            if (!clean) {
                // Whatever ended the thread, nothing it held stays open and
                // the next adopt starts a new one.
                selector?.keys()?.forEach { (it.attachment() as? Pair)?.let { p -> closeQuietly(p.a, p.b) } }
                val orphans = inbox.with {
                    val p = pending.toList()
                    pending.clear()
                    running = false
                    this.selector = null
                    p
                }
                orphans.forEach { closeQuietly(it.a, it.b) }
            }
            selector?.let { runCatching { it.close() } }
        }
    }

    /** Close the registered pairs whose lease went stale; how many it closed. */
    private fun closeStale(selector: Selector): Int {
        val gone = selector.keys()
            .filter { it.isValid }
            .mapNotNull { it.attachment() as? Pair }
            .distinct()
            .filter { stale(it.lease) }
        gone.forEach { close(it) }
        if (gone.isNotEmpty()) log("closed ${gone.size} tunnel(s) whose route changed")
        return gone.size
    }

    /** Register [h]; false when it failed, or its lease went stale, and is already closed. */
    private fun register(selector: Selector, h: Handoff): Boolean {
        if (stale(h.lease)) {
            closeQuietly(h.a, h.b)
            return false
        }
        return try {
            h.a.configureBlocking(false)
            h.b.configureBlocking(false)
            val pair = Pair(h.a, h.b, h.aFirst, h.bFirst, h.lease)
            pair.keyA = h.a.register(selector, 0, pair)
            pair.keyB = h.b.register(selector, 0, pair)
            step(pair)
        } catch (e: IOException) {
            closeQuietly(h.a, h.b)
            false
        }
    }

    /**
     * Move what can move without waiting, in both directions, and re-arm
     * the keys for what is left. False once the pair is closed.
     */
    private fun step(pair: Pair): Boolean {
        try {
            move(pair.ab)
            move(pair.ba)
        } catch (e: IOException) {
            close(pair)
            return false
        }
        if (pair.ab.done && pair.ba.done) {
            close(pair)
            return false
        }
        pair.keyA.interestOps(interest(reads = pair.ab, writes = pair.ba))
        pair.keyB.interestOps(interest(reads = pair.ba, writes = pair.ab))
        return true
    }

    private fun move(flow: Flow) {
        if (!flow.ended && flow.buf.hasRemaining()) {
            if (flow.from.read(flow.buf) < 0) flow.ended = true
        }
        if (flow.holds) {
            // Through Buffer: built against a newer SDK, ByteBuffer.flip()
            // links to an override older Android releases do not have.
            (flow.buf as Buffer).flip()
            flow.to.write(flow.buf)
            flow.buf.compact()
        }
        if (flow.ended && !flow.holds && !flow.shut) {
            // Through the socket: SocketChannel.shutdownOutput is API 24+.
            flow.to.socket().shutdownOutput()
            flow.shut = true
        }
    }

    /** A channel waits to read for the flow it feeds and to write for the one it drains. */
    private fun interest(reads: Flow, writes: Flow): Int {
        var ops = 0
        if (!reads.ended && reads.buf.hasRemaining()) ops = ops or SelectionKey.OP_READ
        if (writes.holds) ops = ops or SelectionKey.OP_WRITE
        return ops
    }

    private fun close(pair: Pair) {
        pair.keyA.cancel()
        pair.keyB.cancel()
        closeQuietly(pair.a, pair.b)
    }

    private fun closeQuietly(a: SocketChannel, b: SocketChannel) {
        runCatching { a.close() }
        runCatching { b.close() }
    }

    companion object {
        private const val BUFFER = 32 * 1024
        private val EMPTY = ByteArray(0)
    }
}
