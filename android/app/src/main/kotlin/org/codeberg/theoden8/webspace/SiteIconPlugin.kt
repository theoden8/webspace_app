package org.codeberg.theoden8.webspace

import android.content.Context
import android.webkit.WebIconDatabase
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Turns on WebView favicon downloads so `WebChromeClient.onReceivedIcon`
 * fires (ICON-009).
 *
 * Chromium's WebView downloads a page's `rel=icon` candidates only while a
 * process-wide flag is set, and the one public way to set it is
 * `WebIconDatabase.open`: its Chromium implementation ignores the path and
 * calls `AwSettings.setShouldDownloadFaviconsGlobal()`. The class is
 * deprecated with a note that it is only needed up to JELLY_BEAN_MR2, which
 * no longer matches Chromium: `AwSettings::ShouldDownloadFavicon` still
 * requires the flag.
 *
 * `getInstance` starts Chromium and blocks until it is up, so Dart calls this
 * right before it builds the first site webview, which starts Chromium
 * anyway. Main looper only (method-channel handler), so no shared state.
 */
class SiteIconPlugin(private val context: Context, flutterEngine: FlutterEngine) {
    private var enabled = false

    init {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enable" -> {
                    if (!enabled) {
                        @Suppress("DEPRECATION")
                        WebIconDatabase.getInstance().open(context.cacheDir.absolutePath)
                        enabled = true
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        const val CHANNEL = "org.codeberg.theoden8.webspace/site_icon"
    }
}
