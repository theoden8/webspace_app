package org.codeberg.theoden8.webspace.proxy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

/**
 * Where a message ends decides what the relay reads as the next request,
 * so a framing mistake is a request one site's credential admitted reaching
 * another's route (RFC 9112 section 6.3). Each case leaves bytes after the
 * message and checks they are still unread.
 */
class HttpFramingTest {

    private fun copy(length: BodyLength, wire: String): Pair<String, String> {
        val from = ByteArrayInputStream(wire.toByteArray(Charsets.ISO_8859_1))
        val to = ByteArrayOutputStream()
        HttpFraming.copyBody(length, from, to)
        return Pair(to.toString(Charsets.ISO_8859_1.name()), from.readBytes().toString(Charsets.ISO_8859_1))
    }

    @Test
    fun aRequestHasABodyOnlyWhenItSaysSo() {
        assertEquals(BodyLength.None, HttpFraming.requestBody(listOf("Host: a")))
        assertEquals(BodyLength.None, HttpFraming.requestBody(listOf("Content-Length: 0")))
        assertEquals(BodyLength.Fixed(5), HttpFraming.requestBody(listOf("content-length: 5")))
        assertEquals(BodyLength.Fixed(5), HttpFraming.requestBody(listOf("Content-Length: 5, 5")))
        assertEquals(BodyLength.Chunked, HttpFraming.requestBody(listOf("Transfer-Encoding: gzip, chunked")))
    }

    @Test(expected = MalformedMessage::class)
    fun aRequestNamingBothLengthsIsRefused() {
        HttpFraming.requestBody(listOf("Transfer-Encoding: chunked", "Content-Length: 9"))
    }

    @Test(expected = MalformedMessage::class)
    fun aRequestWhoseLengthsDisagreeIsRefused() {
        HttpFraming.requestBody(listOf("Content-Length: 5", "Content-Length: 6"))
    }

    @Test(expected = MalformedMessage::class)
    fun aRequestNotChunkedLastIsRefused() {
        HttpFraming.requestBody(listOf("Transfer-Encoding: chunked, gzip"))
    }

    @Test(expected = MalformedMessage::class)
    fun aNegativeLengthIsRefused() {
        HttpFraming.requestBody(listOf("Content-Length: -1"))
    }

    @Test
    fun aResponseBodyDependsOnWhatItAnswers() {
        val sized = listOf("Content-Length: 100")
        assertEquals(BodyLength.None, HttpFraming.responseBody("HEAD", 200, sized))
        assertEquals(BodyLength.None, HttpFraming.responseBody("GET", 204, sized))
        assertEquals(BodyLength.None, HttpFraming.responseBody("GET", 304, sized))
        assertEquals(BodyLength.None, HttpFraming.responseBody("GET", 103, sized))
        assertEquals(BodyLength.Fixed(100), HttpFraming.responseBody("GET", 200, sized))
        assertEquals(
            BodyLength.Chunked,
            HttpFraming.responseBody("GET", 200, listOf("Transfer-Encoding: chunked")),
        )
        assertEquals(BodyLength.UntilClose, HttpFraming.responseBody("GET", 200, emptyList()))
        assertEquals(
            BodyLength.UntilClose,
            HttpFraming.responseBody("GET", 200, listOf("Transfer-Encoding: gzip")),
        )
    }

    @Test
    fun aConnectionStaysByVersionUnlessToldOtherwise() {
        assertTrue(HttpFraming.keepsAlive("HTTP/1.1", emptyList()))
        assertFalse(HttpFraming.keepsAlive("HTTP/1.1", listOf("Connection: close")))
        assertFalse(HttpFraming.keepsAlive("HTTP/1.1", listOf("Proxy-Connection: Close")))
        assertFalse(HttpFraming.keepsAlive("HTTP/1.0", emptyList()))
        assertTrue(HttpFraming.keepsAlive("HTTP/1.0", listOf("Connection: Keep-Alive")))
    }

    @Test
    fun aFixedBodyStopsAtItsEnd() {
        val (body, rest) = copy(BodyLength.Fixed(5), "hello" + "GET /next HTTP/1.1\r\n")
        assertEquals("hello", body)
        assertEquals("GET /next HTTP/1.1\r\n", rest)
    }

    @Test
    fun aChunkedBodyIsCopiedThroughItsTrailersAndNoFurther() {
        val wire = "5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: t\r\n\r\n" + "NEXT"
        val (body, rest) = copy(BodyLength.Chunked, wire)
        assertEquals(wire.removeSuffix("NEXT"), body)
        assertEquals("NEXT", rest)
    }

    @Test
    fun aBodyCutShortIsMalformed() {
        val short = runCatching { copy(BodyLength.Fixed(10), "hello") }.exceptionOrNull()
        assertTrue("$short", short is MalformedMessage)
        val badChunk = runCatching { copy(BodyLength.Chunked, "zz\r\nhello\r\n0\r\n\r\n") }.exceptionOrNull()
        assertTrue("$badChunk", badChunk is MalformedMessage)
        val unterminated = runCatching { copy(BodyLength.Chunked, "5\r\nhelloX\r\n0\r\n\r\n") }.exceptionOrNull()
        assertTrue("$unterminated", unterminated is MalformedMessage)
    }

    @Test
    fun aBodyUntilCloseTakesEverything() {
        val (body, rest) = copy(BodyLength.UntilClose, "all of it")
        assertEquals("all of it", body)
        assertEquals("", rest)
    }

    @Test
    fun drainingTakesWhatTheBufferReadAhead() {
        val input = DrainableInput(ByteArrayInputStream("ab\r\n\r\npayload".toByteArray()))
        repeat(6) { input.read() }
        assertEquals("payload", input.drainBuffered().toString(Charsets.ISO_8859_1))
        assertEquals(-1, input.read())
    }
}
