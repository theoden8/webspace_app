package org.codeberg.theoden8.webspace.proxy

import java.io.BufferedInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/** Where an HTTP/1.1 message body ends (RFC 9112 section 6.3). */
internal sealed class BodyLength {
    object None : BodyLength()
    data class Fixed(val bytes: Long) : BodyLength()
    object Chunked : BodyLength()

    /** A response with no length: its body runs to the end of the connection. */
    object UntilClose : BodyLength()
}

/**
 * A buffered stream whose unread buffer can be taken whole, so a connection
 * handed from a worker to the splicer loses none of what the worker read
 * past its handshake. One worker owns it for the connection's life and
 * drains it as it hands the connection over, so no other thread reads it.
 */
internal class DrainableInput(source: InputStream) : BufferedInputStream(source) {
    fun drainBuffered(): ByteArray {
        val unread = buf.copyOfRange(pos, count)
        pos = count
        return unread
    }
}

/** A message whose framing cannot be read, which the relay answers 400 or 502. */
internal class MalformedMessage(why: String) : IOException(why)

/**
 * The HTTP/1.1 framing the relay needs to carry several plain-http requests
 * over one connection: where each body ends, whether the connection
 * survives the exchange, and a copy of a body that stops exactly at its end.
 * Pure over streams, so it is tested without sockets.
 */
internal object HttpFraming {

    /** The value of the first [name] header, or null. */
    fun header(headers: List<String>, name: String): String? =
        headers.firstOrNull { it.startsWith("$name:", ignoreCase = true) }
            ?.substringAfter(':')?.trim()

    /** The comma-separated tokens of every [name] header, lowercased. */
    fun tokens(headers: List<String>, name: String): Set<String> =
        headers.filter { it.startsWith("$name:", ignoreCase = true) }
            .flatMap { it.substringAfter(':').split(',') }
            .map { it.trim().lowercase() }
            .filter { it.isNotEmpty() }
            .toSet()

    /**
     * A request has a body only when it says so (RFC 9112 section 6.3, rule
     * 6). One that names both lengths is refused rather than forwarded: the
     * next hop may frame it by the other one, which is request smuggling.
     */
    fun requestBody(headers: List<String>): BodyLength {
        val encodings = tokens(headers, "Transfer-Encoding")
        if (encodings.isNotEmpty()) {
            if (encodings.last() != "chunked") throw MalformedMessage("request not chunked last")
            if (header(headers, "Content-Length") != null) throw MalformedMessage("request has both lengths")
            return BodyLength.Chunked
        }
        return when (val length = contentLength(headers)) {
            null, 0L -> BodyLength.None
            else -> BodyLength.Fixed(length)
        }
    }

    /** A response's body, given the request it answers (RFC 9112 section 6.3). */
    fun responseBody(method: String, status: Int, headers: List<String>): BodyLength {
        if (method == "HEAD" || status in 100..199 || status == 204 || status == 304) {
            return BodyLength.None
        }
        val encodings = tokens(headers, "Transfer-Encoding")
        if (encodings.isNotEmpty()) {
            return if (encodings.last() == "chunked") BodyLength.Chunked else BodyLength.UntilClose
        }
        return when (val length = contentLength(headers)) {
            null -> BodyLength.UntilClose
            0L -> BodyLength.None
            else -> BodyLength.Fixed(length)
        }
    }

    /** Whether the side that sent [version] and [headers] keeps the connection. */
    fun keepsAlive(version: String, headers: List<String>): Boolean {
        val connection = tokens(headers, "Connection") + tokens(headers, "Proxy-Connection")
        if ("close" in connection) return false
        return version.equals("HTTP/1.1", ignoreCase = true) || "keep-alive" in connection
    }

    /** The status code of a response's start line, or null. */
    fun status(startLine: String): Int? =
        startLine.split(' ').getOrNull(1)?.toIntOrNull()?.takeIf { it in 100..999 }

    /** The version of a response's start line, or of a request's (its last word). */
    fun responseVersion(startLine: String): String = startLine.substringBefore(' ')

    fun requestVersion(requestLine: String): String = requestLine.substringAfterLast(' ')

    /**
     * Copy one body of [length] from [from] to [to], stopping at its end and
     * never reading past it. A body cut short is a [MalformedMessage].
     */
    fun copyBody(length: BodyLength, from: InputStream, to: OutputStream) {
        when (length) {
            BodyLength.None -> Unit
            is BodyLength.Fixed -> copyExactly(length.bytes, from, to)
            BodyLength.Chunked -> copyChunked(from, to)
            BodyLength.UntilClose -> {
                val buf = ByteArray(BUFFER)
                while (true) {
                    val n = from.read(buf)
                    if (n < 0) break
                    to.write(buf, 0, n)
                }
            }
        }
        to.flush()
    }

    private fun contentLength(headers: List<String>): Long? {
        val values = headers.filter { it.startsWith("Content-Length:", ignoreCase = true) }
            .flatMap { it.substringAfter(':').split(',') }
            .map { it.trim() }
            .distinct()
        if (values.isEmpty()) return null
        // Differing lengths are request smuggling's shape; refuse them.
        val only = values.singleOrNull() ?: throw MalformedMessage("conflicting Content-Length")
        return only.toLongOrNull()?.takeIf { it >= 0 } ?: throw MalformedMessage("bad Content-Length")
    }

    private fun copyChunked(from: InputStream, to: OutputStream) {
        while (true) {
            val sizeLine = readLine(from)
            to.write(sizeLine.toByteArray(Charsets.ISO_8859_1)); to.write(CRLF)
            val size = sizeLine.substringBefore(';').trim().toLongOrNull(16)
                ?.takeIf { it >= 0 } ?: throw MalformedMessage("bad chunk size")
            if (size == 0L) {
                // Trailers, then the empty line that ends the message.
                while (true) {
                    val trailer = readLine(from)
                    to.write(trailer.toByteArray(Charsets.ISO_8859_1)); to.write(CRLF)
                    if (trailer.isEmpty()) return
                }
            }
            copyExactly(size, from, to)
            if (readLine(from).isNotEmpty()) throw MalformedMessage("chunk not followed by CRLF")
            to.write(CRLF)
        }
    }

    private fun copyExactly(bytes: Long, from: InputStream, to: OutputStream) {
        val buf = ByteArray(BUFFER)
        var left = bytes
        while (left > 0) {
            val n = from.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
            if (n < 0) throw MalformedMessage("body ended ${left}B short")
            to.write(buf, 0, n)
            left -= n
        }
    }

    /** One CRLF- or LF-terminated line, without its terminator. */
    private fun readLine(from: InputStream): String {
        val sb = StringBuilder()
        while (true) {
            val b = from.read()
            if (b < 0) throw MalformedMessage("message ended mid-line")
            if (b == '\n'.code) break
            if (sb.length >= MAX_LINE) throw MalformedMessage("line too long")
            sb.append(b.toChar())
        }
        if (sb.endsWith('\r')) sb.setLength(sb.length - 1)
        return sb.toString()
    }

    private val CRLF = byteArrayOf('\r'.code.toByte(), '\n'.code.toByte())
    private const val BUFFER = 16 * 1024
    private const val MAX_LINE = 8 * 1024
}
