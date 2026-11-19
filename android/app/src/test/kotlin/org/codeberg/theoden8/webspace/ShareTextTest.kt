// JVM unit tests for ShareText.urlIn, the URL a share's text carries
// (LIR-005).
package org.codeberg.theoden8.webspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ShareTextTest {

    @Test
    fun lir005SharedUrlIsDeliveredTrimmed() {
        assertEquals(
            "https://example.com/a?b=1",
            ShareText.urlIn("  https://example.com/a?b=1\n"),
        )
        assertEquals("HTTP://EXAMPLE.COM/", ShareText.urlIn("HTTP://EXAMPLE.COM/"))
    }

    @Test
    fun lir005UrlInsideSharedTextIsFound() {
        assertEquals(
            "https://news.example/story",
            ShareText.urlIn("Read this https://news.example/story via the app"),
        )
        assertEquals(
            "http://first.example/",
            ShareText.urlIn("a http://first.example/ b https://second.example/"),
        )
    }

    @Test
    fun lir005TextWithoutUrlRoutesNothing() {
        assertNull(ShareText.urlIn(null))
        assertNull(ShareText.urlIn("   "))
        assertNull(ShareText.urlIn("just some words"))
        assertNull(ShareText.urlIn("ftp://files.example/x"))
        assertNull(ShareText.urlIn("mailto:a@example.com"))
    }
}
