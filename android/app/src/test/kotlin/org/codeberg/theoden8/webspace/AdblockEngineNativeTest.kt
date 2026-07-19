// JVM unit tests for the AdblockEngineNative facade.
//
// In the JVM unit-test runtime the `webspace_adblock` shared
// library isn't loaded (no `System.loadLibrary` resolution against
// JNI symbols), so `loaded` is false. The interesting contract to
// pin down is therefore the *fallback* behavior — when the .so
// isn't present, every method must be a clean no-op so callers
// can invoke them without gating on `active`.
package org.codeberg.theoden8.webspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class AdblockEngineNativeTest {

    @Test
    fun supported_falseWhenLibraryNotLoaded() {
        // System.loadLibrary in the singleton's init block can't
        // resolve `webspace_adblock` from this test classpath, so
        // the singleton initialised with loaded=false.
        assertFalse(
            "JVM unit tests run without the .so on the classpath; " +
                "supported must be false to keep callers from blowing up.",
            AdblockEngineNative.supported,
        )
    }

    @Test
    fun active_falseWhenNotLoaded() {
        assertFalse(AdblockEngineNative.active)
    }

    @Test
    fun checkUrl_returnsFalseWhenNotLoaded() {
        // Critical: callers in FastSubresourceInterceptor invoke
        // checkUrl WITHOUT first checking `active`. The function
        // must short-circuit to false (= allow) so production code
        // doesn't NPE on platforms where the library is missing.
        val out = AdblockEngineNative.checkUrl(
            "https://tracker.com/x",
            "https://news.com/article",
            "script",
        )
        assertEquals(false, out)
    }

    @Test
    fun setRules_isNoOpWhenNotLoaded() {
        // Should NOT throw — the production-side toggle handler
        // calls setRules unconditionally. If this throws, flipping
        // the engine toggle on a non-Rust-built APK crashes the app.
        AdblockEngineNative.setRules("||tracker.com^\n")
        // Engine still inactive because the .so wasn't loaded.
        assertFalse(AdblockEngineNative.active)
    }

    @Test
    fun setRules_emptyStringIsNoOpAndIdempotent() {
        AdblockEngineNative.setRules("")
        AdblockEngineNative.setRules("")
        assertFalse(AdblockEngineNative.active)
    }

    @Test
    fun dispose_isIdempotentWhenNotLoaded() {
        // dispose() is also called from the toggle-off path; must
        // be safe to call when the library isn't loaded.
        AdblockEngineNative.dispose()
        AdblockEngineNative.dispose()
        assertFalse(AdblockEngineNative.active)
    }

    @Test
    fun concurrentReadersAndWritersDoNotDeadlockOrThrow() {
        // The read/write lock added to guard free-vs-deref must not
        // deadlock when many threads pound the facade at once (the
        // production shape: chromium IO threads call checkUrl while the
        // toggle handler calls setRules/dispose). With the .so absent
        // every call short-circuits, but the write-lock methods still
        // acquire the lock, so this pins "no deadlock, no exception".
        val threads = (0 until 16).map { i ->
            Thread {
                repeat(200) {
                    when (i % 3) {
                        0 -> AdblockEngineNative.checkUrl(
                            "https://t.com/x", "https://s.com/a", "script")
                        1 -> AdblockEngineNative.setRules("||t.com^\n")
                        else -> AdblockEngineNative.dispose()
                    }
                }
            }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join(5_000) }
        threads.forEach { assertFalse("thread stuck / deadlocked", it.isAlive) }
        assertFalse(AdblockEngineNative.active)
    }
}
