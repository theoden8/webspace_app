package org.codeberg.theoden8.webspace.proxy

import java.io.IOException
import org.codeberg.theoden8.webspace.describe
import java.net.Socket
import java.net.SocketException

/** How one direction of a tunnel stopped. */
internal sealed interface Ending {
    /** Its sender closed its side. */
    data object Closed : Ending

    /** Reading from its sender failed. */
    class ReadFailed(val error: IOException) : Ending

    /** Writing to its receiver failed. */
    class WriteFailed(val error: IOException) : Ending
}

/**
 * One direction of a tunnel as its end reports it: what the [sender] sent,
 * counting what a worker read past the handshake, and how and when it
 * stopped. Touched by one thread at a time: the splice thread, or the
 * worker pumping it and then the one that joins it.
 */
internal class Direction(val sender: String, val receiver: String, first: Int) {
    var bytes: Long = first.toLong()
    var ending: Ending? = null
        private set
    private var endedAt = 0L

    /** It stopped on an error rather than its sender's close: the tunnel ends abortively. */
    val failed: Boolean get() = ending is Ending.ReadFailed || ending is Ending.WriteFailed

    /** The first ending is the one kept: a close after a failure is its consequence. */
    fun end(how: Ending) {
        if (ending != null) return
        ending = how
        endedAt = System.nanoTime()
    }

    companion object {
        /**
         * The line a tunnel's end logs: how long it lasted, why it ended, and
         * what each side sent. The first failure names the side and the
         * error, since a failure ends the other direction too; with none, the
         * side that closed first. [cause] overrides both, for an end the
         * relay chose.
         */
        fun ended(label: String, startedAt: Long, up: Direction, down: Direction, cause: String? = null): String {
            val ms = (System.nanoTime() - startedAt) / 1_000_000
            val firstFailed = listOf(up, down).filter { it.failed }.minByOrNull { it.endedAt }
            val why = cause ?: firstFailed?.let(::failure) ?: closed(up, down)
            return "tunnel $label ended after $ms ms: $why; " +
                "${up.sender} sent ${up.bytes} B, ${down.sender} sent ${down.bytes} B"
        }

        private fun failure(d: Direction): String? = when (val e = d.ending) {
            is Ending.ReadFailed -> "reading from the ${d.sender} failed (${describe(e.error)})"
            is Ending.WriteFailed -> "writing to the ${d.receiver} failed (${describe(e.error)})"
            Ending.Closed, null -> null
        }

        private fun closed(up: Direction, down: Direction): String {
            val ended = listOf(up, down).filter { it.ending == Ending.Closed }
            val first = ended.minByOrNull { it.endedAt } ?: return "neither side closed"
            return if (ended.size == 2) "the ${first.sender} closed first" else "the ${first.sender} closed"
        }
    }
}

/**
 * Make each socket's close a reset (zero linger), for a tunnel whose one
 * side failed: a reset the far side sent reaches the WebView as one, as it
 * would with no relay between them, rather than as a close. Chromium names
 * the two apart (`ERR_CONNECTION_RESET`, `ERR_CONNECTION_CLOSED`).
 */
internal fun abortOnClose(vararg sockets: Socket, log: (String) -> Unit) {
    for (s in sockets) {
        try {
            s.setSoLinger(true, 0)
        } catch (e: SocketException) {
            log("could not make a close a reset: ${describe(e)}")
        }
    }
}

