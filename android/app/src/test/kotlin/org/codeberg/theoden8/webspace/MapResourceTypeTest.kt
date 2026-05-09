// JVM unit tests for FastSubresourceInterceptor.mapResourceType.
//
// Why this exists: phase 9 introduced the function with a Kotlin
// typo (`request.requestHeaders` vs the actual `request.headers`)
// that compiled fine on every other JVM target except an Android
// release build, where it surfaced as a Kotlin compile error
// during APK assembly. Locally `flutter test` doesn't touch Kotlin
// at all, so the bug only showed up in CI's "Build APK" step.
//
// Running this file via `./gradlew :app:testFdroidDebugUnitTest`
// (added to the Build Android CI job) catches that class of error
// in seconds without spinning up the slow gradle/flutter build.
package org.codeberg.theoden8.webspace

import com.pichillilorenzo.flutter_inappwebview_android.types.WebResourceRequestExt
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean

class MapResourceTypeTest {

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

    private fun req(
        url: String,
        isMainFrame: Boolean = false,
        headers: Map<String, String> = emptyMap(),
    ): WebResourceRequestExt = WebResourceRequestExt(
        url, headers, /* isRedirect = */ false,
        /* hasGesture = */ false, isMainFrame, "GET",
    )

    @Test
    fun mainFrameNavigation_isDocument() {
        val out = newInterceptor().mapResourceType(
            req("https://example.com/", isMainFrame = true))
        assertEquals("document", out)
    }

    @Test
    fun secFetchDest_script_mapsToScript() {
        val out = newInterceptor().mapResourceType(
            req("https://example.com/x.js",
                headers = mapOf("Sec-Fetch-Dest" to "script")))
        assertEquals("script", out)
    }

    @Test
    fun secFetchDest_lowercase_alsoMatches() {
        // Some chromium versions normalise headers to lowercase.
        // The lookup must succeed for both casings or we'd silently
        // miss the engine's resource-type rules on those builds.
        val out = newInterceptor().mapResourceType(
            req("https://example.com/x.js",
                headers = mapOf("sec-fetch-dest" to "script")))
        assertEquals("script", out)
    }

    @Test
    fun secFetchDest_image_mapsToImage() {
        val out = newInterceptor().mapResourceType(
            req("https://example.com/x.png",
                headers = mapOf("Sec-Fetch-Dest" to "image")))
        assertEquals("image", out)
    }

    @Test
    fun secFetchDest_style_mapsToStylesheet() {
        val out = newInterceptor().mapResourceType(
            req("https://example.com/x.css",
                headers = mapOf("Sec-Fetch-Dest" to "style")))
        assertEquals("stylesheet", out)
    }

    @Test
    fun secFetchDest_empty_mapsToXhr() {
        // Chromium uses Sec-Fetch-Dest: empty for fetch() and XHR
        // calls — those flow through the engine's `$xhr` modifier.
        val out = newInterceptor().mapResourceType(
            req("https://example.com/api",
                headers = mapOf("Sec-Fetch-Dest" to "empty")))
        assertEquals("xhr", out)
    }

    @Test
    fun secFetchDest_iframe_mapsToSubdocument() {
        val out = newInterceptor().mapResourceType(
            req("https://example.com/embed",
                headers = mapOf("Sec-Fetch-Dest" to "iframe")))
        assertEquals("subdocument", out)
    }

    @Test
    fun urlExtensionFallback_jsScript() {
        // No Sec-Fetch-Dest header: url extension classifies.
        val out = newInterceptor().mapResourceType(
            req("https://example.com/path/to/lib.js"))
        assertEquals("script", out)
    }

    @Test
    fun urlExtensionFallback_pngImage() {
        val out = newInterceptor().mapResourceType(
            req("https://example.com/banner.png"))
        assertEquals("image", out)
    }

    @Test
    fun urlExtensionFallback_woffFont() {
        val out = newInterceptor().mapResourceType(
            req("https://example.com/fonts/x.woff2"))
        assertEquals("font", out)
    }

    @Test
    fun urlExtensionFallback_handlesQueryString() {
        // .js?v=123 should still classify as script — we strip
        // query before checking the extension.
        val out = newInterceptor().mapResourceType(
            req("https://example.com/lib.js?v=cachebust"))
        assertEquals("script", out)
    }

    @Test
    fun urlExtensionFallback_handlesFragment() {
        val out = newInterceptor().mapResourceType(
            req("https://example.com/lib.js#section"))
        assertEquals("script", out)
    }

    @Test
    fun unknownExtension_fallsBackToOther() {
        val out = newInterceptor().mapResourceType(
            req("https://example.com/api/data"))
        assertEquals("other", out)
    }

    @Test
    fun emptyHeaders_dontCrashLookup() {
        // Regression test for the phase 9 bug: the function
        // accessed `request.requestHeaders` instead of `.headers`.
        // Compile-error in real builds, but if it ever ships as a
        // null-tolerant getter we want to assert the empty-map
        // behavior here too.
        val out = newInterceptor().mapResourceType(
            req("https://example.com/x.js", headers = emptyMap()))
        assertEquals("script", out)
    }
}
