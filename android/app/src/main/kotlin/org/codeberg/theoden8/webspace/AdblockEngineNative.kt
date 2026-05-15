// JVM/Kotlin facade for the JNI exports in `webspace_adblock`'s
// src/jni.rs. Kotlin can then call into the Rust adblock-rust engine
// directly from `FastSubresourceInterceptor.checkUrl` — no Dart
// roundtrip per sub-resource request.
//
// The native library (`libwebspace_adblock.so`) is built by
// `scripts/build_rust.sh android-all` and ends up under
// `android/app/src/main/jniLibs/<abi>/`, so System.loadLibrary
// finds it automatically. If the library isn't present (the user
// is running a CI build that skipped the Rust step, or the engine
// is disabled), `available` is false and every method becomes a
// no-op — the existing host-only fast path keeps working.
package org.codeberg.theoden8.webspace

import android.util.Log

/**
 * Singleton wrapper around the JNI bridge to adblock-rust. Thread-safe
 * for concurrent reads (`checkUrl`); writes (`setRules`, `dispose`)
 * are serialised via `synchronized`.
 *
 * Lifecycle: Dart pushes rules text via the `setAdblockEngineRules`
 * method channel call when the user flips the toggle. We parse them
 * once into a Box<Engine> on the Rust side and keep the long handle
 * here. Subsequent navigation events have FastSubresourceInterceptor
 * call `checkUrl` per request; when the user flips the toggle off
 * we `dispose()` the handle and revert to host-only matching.
 */
object AdblockEngineNative {
    private const val TAG = "AdblockEngineNative"

    /** True iff `libwebspace_adblock.so` loaded and the JNI probe returned true. */
    @Volatile
    private var loaded: Boolean = false

    /** Opaque pointer the Rust side hands back from `engineNew`. */
    @Volatile
    private var enginePtr: Long = 0L

    init {
        try {
            System.loadLibrary("webspace_adblock")
            // Probe the symbol so we know cbindgen+JNI wired
            // correctly before any sub-resource request hits.
            loaded = nativeProbe()
            if (loaded) {
                Log.i(TAG, "webspace_adblock JNI loaded")
            } else {
                Log.w(TAG, "webspace_adblock loaded but probe returned false")
            }
        } catch (t: Throwable) {
            // Missing .so on this ABI / CI build skipped Rust step.
            // Falling back to host-only is the documented contract,
            // so we log info-level (not error) and move on.
            Log.i(TAG, "webspace_adblock JNI not loaded: ${t.message}")
            loaded = false
        }
    }

    /** True when the engine is built and ready to answer `checkUrl`. */
    val active: Boolean
        get() = loaded && enginePtr != 0L

    /** True when the .so was loaded — independent of whether rules are set. */
    val supported: Boolean
        get() = loaded

    /**
     * Parse [rulesText] into a fresh engine. Drops the previous
     * engine if any. Pass an empty string to tear down (same effect
     * as [dispose]).
     */
    @Synchronized
    fun setRules(rulesText: String, enableUboResources: Boolean = true) {
        if (!loaded) return
        if (enginePtr != 0L) {
            nativeEngineFree(enginePtr)
            enginePtr = 0L
        }
        if (rulesText.isEmpty()) {
            Log.i(TAG, "engine torn down")
            return
        }
        val ptr = nativeEngineNew(rulesText, enableUboResources)
        enginePtr = ptr
        Log.i(TAG, if (ptr != 0L)
            "engine built (${rulesText.length} bytes, handle=0x${java.lang.Long.toHexString(ptr)}, ubo=$enableUboResources)"
        else
            "engine build failed")
    }

    /**
     * Block decision for one sub-resource. Returns false (allow) when
     * the engine isn't active so callers don't need to gate on
     * [active] before calling — short-circuit happens here.
     */
    fun checkUrl(url: String, sourceUrl: String, requestType: String): Boolean {
        val handle = enginePtr
        if (!loaded || handle == 0L) return false
        return nativeCheckUrl(handle, url, sourceUrl, requestType)
    }

    /**
     * If a `$redirect=` (or `$redirect-rule=`) rule matches this
     * request, returns the redirect target as a data: URL — i.e.
     * `data:<mime>;base64,<body>`. Returns null when no redirect
     * applies, when the engine isn't active, or when the loaded
     * resource pool doesn't contain the redirect target named by
     * the rule.
     *
     * Call this AFTER [checkUrl] has reported blocked, to decide
     * whether the synthetic response should carry the redirect
     * body (recommended — sites that probe for the redirected
     * resource keep working) or just an empty 200.
     */
    fun redirectFor(url: String, sourceUrl: String, requestType: String): String? {
        val handle = enginePtr
        if (!loaded || handle == 0L) return null
        return nativeRedirectFor(handle, url, sourceUrl, requestType)
    }

    /** Tear down the engine; idempotent. */
    @Synchronized
    fun dispose() {
        if (enginePtr != 0L) {
            nativeEngineFree(enginePtr)
            enginePtr = 0L
            Log.i(TAG, "engine disposed")
        }
    }

    // ---- JNI declarations (implemented in rust/webspace_adblock/src/jni.rs) ----
    @JvmStatic
    private external fun nativeProbe(): Boolean

    @JvmStatic
    private external fun nativeEngineNew(rulesText: String, enableUboResources: Boolean): Long

    @JvmStatic
    private external fun nativeEngineFree(handle: Long)

    @JvmStatic
    private external fun nativeCheckUrl(
        handle: Long,
        url: String,
        sourceUrl: String,
        requestType: String,
    ): Boolean

    @JvmStatic
    private external fun nativeRedirectFor(
        handle: Long,
        url: String,
        sourceUrl: String,
        requestType: String,
    ): String?
}
