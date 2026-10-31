package org.codeberg.theoden8.webspace

import android.app.Activity
import android.content.pm.ApplicationInfo
import android.os.Build
import android.view.View
import android.view.WindowInsets
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
                "debugLayout" -> {
                    // The Android desktop tier (INTEG-018) reads where the
                    // content sits under the header. Debuggable builds only.
                    val debuggable =
                        (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
                    if (!debuggable) {
                        result.error("UNAVAILABLE", "debuggable builds only", null)
                    } else {
                        result.success(layout())
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * The header's height and where the content starts, in the window's
     * pixels, and the appearance the window was given. Laid out below an
     * opaque header the content starts at the header's height; under a
     * transparent one at 0.
     */
    private fun layout(): Map<String, Int> {
        val at = IntArray(2)
        activity.findViewById<View>(android.R.id.content).getLocationInWindow(at)
        val multiWindow = if (activity.isInMultiWindowMode) 1 else 0
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return mapOf(
                "captionTop" to 0, "contentTop" to at[1], "appearance" to 0,
                "multiWindow" to multiWindow,
            )
        }
        val insets = activity.window.decorView.rootWindowInsets
        return mapOf(
            "captionTop" to (insets?.getInsets(WindowInsets.Type.captionBar())?.top ?: 0),
            "contentTop" to at[1],
            "appearance" to (controller()?.systemBarsAppearance ?: 0),
            "multiWindow" to multiWindow,
        )
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
