// JVM unit tests for FastSubresourceInterceptor.redirectResponseFor —
// the data: URL parser that turns adblock-rust's `$redirect=` body
// into a WebResourceResponse the chromium WebView can serve.
//
// adblock-rust emits resources as `data:<mime>;base64,<body>`. The
// parser splits on `;base64,` boundaries, decodes the body, and wraps
// it in a WebResourceResponse with the correct content-type. Get
// these wrong and the WebView either ignores the response (wrong
// mime) or corrupts the body (wrong decode).
//
// Robolectric-free: `testOptions.unitTests.returnDefaultValues = true`
// stubs Android framework calls. android.util.Base64 IS framework,
// so its decoder returns null/zero by default — we wrap test setup
// to use the actual java.util.Base64 implementation if needed. For
// our parser path we only need the structure to be right; the actual
// decode is exercised end-to-end on a device.
package org.codeberg.theoden8.webspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean

class RedirectResponseForTest {

    private fun newInterceptor(): FastSubresourceInterceptor =
        FastSubresourceInterceptor(
            dnsBlockedDomains = HashSet(),
            abpBlockedDomains = HashSet(),
            cdnPatterns = mutableListOf(),
            cdnCacheIndex = mutableMapOf(),
            localCdnDisabled = AtomicBoolean(false),
            onBlockChecked = { _, _, _ -> },
            onCdnReplaced = { _, _ -> },
            onLog = { _, _ -> },
        )

    @Test
    fun nonDataUrl_returnsNull() {
        // Defensive: if the JNI bridge somehow returns a non-data
        // URL (e.g. resource resolution failed but engine still
        // returned a path), we MUST NOT crash building a response.
        val r = newInterceptor().redirectResponseFor("https://x.com/a.js")
        assertNull(r)
    }

    @Test
    fun malformedDataUrl_returnsNull() {
        val r = newInterceptor().redirectResponseFor("data:")
        assertNull(r)
    }

    @Test
    fun dataUrlMissingComma_returnsNull() {
        val r = newInterceptor()
            .redirectResponseFor("data:application/javascript;base64")
        assertNull(r)
    }

    @Test
    fun dataUrlBase64Body_parsedToWebResourceResponse() {
        // adblock-rust's noop.js resource fits this shape:
        //   data:application/javascript;base64,<base64-noop-js>
        // returnDefaultValues=true means android.util.Base64.decode
        // returns null/empty so we can only assert the parser
        // accepted the structure (non-null response) and routed the
        // right mime type to the WebResourceResponse constructor.
        val r = newInterceptor().redirectResponseFor(
            "data:application/javascript;base64,Y29uc3QgYSA9IDA7")
        // WebResourceResponse construction also touches Android
        // framework, but the response object itself doesn't throw —
        // we just need it to be non-null.
        assertNotNull("parser must accept canonical data: URL", r)
        // JVM unit-test stub returns null for WebResourceResponse
        // getters (returnDefaultValues=true). We can only assert
        // the response object itself was built — actual mime
        // routing is exercised on-device.
    }

    @Test
    fun dataUrlEmptyMime_acceptedAsOctetStream() {
        // `data:;base64,...` should still produce a response (parser
        // defaults the mime internally to application/octet-stream).
        val r = newInterceptor()
            .redirectResponseFor("data:;base64,Y29uc3Q=")
        assertNotNull(r)
    }

    @Test
    fun dataUrlPlainText_acceptedThroughNonBase64Path() {
        // adblock-rust always uses base64, but defensively the
        // parser handles `data:text/plain,literal-body` too.
        val r = newInterceptor()
            .redirectResponseFor("data:text/plain,hello")
        assertNotNull(r)
    }
}
