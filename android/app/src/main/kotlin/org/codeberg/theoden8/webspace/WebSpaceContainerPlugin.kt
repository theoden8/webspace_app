package org.codeberg.theoden8.webspace

import androidx.webkit.WebViewFeature
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Tiny Android-only shim that surfaces `WebViewFeature.MULTI_PROFILE`
/// to the Dart side. The fork's
/// `inapp.ContainerController` already handles every container
/// lifecycle op (list / has / delete) over its own MethodChannel, but
/// it answers each method with empty/false on devices without
/// MULTI_PROFILE — meaning we can't tell "supported but no containers
/// yet" from "not supported" by inspecting return values alone. The
/// fork also does NOT expose `MULTI_PROFILE` as a Dart-side
/// `WebViewFeature` constant, so engine selection
/// (ContainerIsolationEngine vs. legacy CookieIsolationEngine) needs
/// this single boolean answered natively.
///
/// Method called from [container_native.dart]:
///   - `isSupported()`: forwards `WebViewFeature.isFeatureSupported(MULTI_PROFILE)`.
///
/// All other lifecycle calls (delete, list, getOrCreate, bind) route
/// through the fork — we don't reimplement them here.
class WebSpaceContainerPlugin(flutterEngine: FlutterEngine) {
    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(
                    WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)
                )
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        const val CHANNEL = "org.codeberg.theoden8.webspace/container"
    }
}
