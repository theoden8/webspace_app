package org.codeberg.theoden8.webspace

import android.app.Activity
import android.os.Build
import android.view.WindowInsetsController
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The header Android draws over a window in desktop windowing, Android 15
 * and later (NAV-019). Opaque, as it is by default, Android lays the app out
 * below it, and Flutter, which reads the header from the window's own
 * insets, pads the top for it a second time. Transparent, the app runs under
 * it, its top padding is the header's and the app bar fills it, with the
 * header's buttons drawn dark or light as Dart says the app is. Where no
 * header is drawn the appearance changes nothing. Main looper only (BUG-007:
 * none-shared).
 */
class WindowCaptionPlugin(private val activity: Activity, flutterEngine: FlutterEngine) {
    companion object {
        private const val CHANNEL = "org.codeberg.theoden8.webspace/window_caption"
    }

    init {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            val transparent = WindowInsetsController.APPEARANCE_TRANSPARENT_CAPTION_BAR_BACKGROUND
            controller()?.setSystemBarsAppearance(transparent, transparent)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setLight" -> {
                    val light = call.arguments as? Boolean
                    if (light == null) {
                        result.error("BAD_ARGS", "setLight takes a Boolean", null)
                    } else {
                        setLight(light)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Dark buttons over a light app, light ones over a dark app. */
    private fun setLight(light: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) return
        val flag = WindowInsetsController.APPEARANCE_LIGHT_CAPTION_BARS
        controller()?.setSystemBarsAppearance(if (light) flag else 0, flag)
    }

    // The decor view's controller holds an appearance set before the window
    // is attached and applies it as it attaches.
    private fun controller(): WindowInsetsController? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.window.decorView.windowInsetsController
        } else {
            null
        }
}
