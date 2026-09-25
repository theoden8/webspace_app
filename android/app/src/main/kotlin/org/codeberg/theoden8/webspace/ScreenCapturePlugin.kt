package org.codeberg.theoden8.webspace

import android.app.Activity
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Sets FLAG_SECURE on the activity window: screenshots and screen recordings
 * come out blank, casting to a non-secure display shows black, and the
 * recent-apps preview is hidden.
 *
 * The flag is window-wide, so a per-site block is the Dart side switching it
 * as the site on screen changes. The handler runs on the main looper, which is
 * the only thread that touches the window (BUG-007: none-shared).
 */
class ScreenCapturePlugin(private val activity: Activity, flutterEngine: FlutterEngine) {
    companion object {
        private const val CHANNEL = "org.codeberg.theoden8.webspace/screen_capture"
    }

    init {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setBlocked" -> {
                    val blocked = call.argument<Boolean>("blocked")
                    if (blocked == null) {
                        result.error("INVALID_ARGS", "blocked required", null)
                    } else {
                        if (blocked) {
                            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
