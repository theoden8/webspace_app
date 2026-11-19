// JVM unit tests for FastSubresourceInterceptor.contentTypeFor, the MIME
// type a LocalCDN resource is served with (LCDN-006).
package org.codeberg.theoden8.webspace

import org.junit.Assert.assertEquals
import org.junit.Test

class LocalCdnContentTypeTest {

    private fun type(file: String): String =
        FastSubresourceInterceptor.contentTypeFor(file)

    @Test
    fun lcdn006ScriptsAndStylesheets() {
        assertEquals("application/javascript", type("jquery/3.7.1/jquery.min.js"))
        assertEquals("application/javascript", type("lib/module.mjs"))
        assertEquals("text/css", type("bootstrap/5.3.0/css/bootstrap.min.css"))
    }

    @Test
    fun lcdn006Fonts() {
        assertEquals("font/woff2", type("fa/webfonts/fa-solid-900.woff2"))
        assertEquals("font/woff", type("fa/webfonts/fa-solid-900.woff"))
        assertEquals("font/ttf", type("fa/webfonts/fa-solid-900.ttf"))
        assertEquals("font/otf", type("font.otf"))
        assertEquals("application/vnd.ms-fontobject", type("font.eot"))
    }

    @Test
    fun lcdn006QueryIsIgnoredAndUnknownIsOpaque() {
        assertEquals("application/javascript", type("lib.js?v=3"))
        assertEquals("font/woff2", type("font.woff2?#iefix"))
        assertEquals("image/svg+xml", type("icons.svg"))
        assertEquals("application/json", type("lib.min.js.map"))
        assertEquals("application/octet-stream", type("archive.zip"))
        assertEquals("application/octet-stream", type("README"))
    }
}
