package org.codeberg.theoden8.webspace

import android.app.Activity
import android.app.UiModeManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.res.Configuration
import android.content.pm.PackageManager
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Says whether a remote's D-pad, not a touchscreen, drives this device
 * (NAV-016): a TV, or any device without a touchscreen. Stateless; the
 * handler runs on the main looper (BUG-007: none-shared).
 */
class RemoteInputPlugin(private val activity: Activity, flutterEngine: FlutterEngine) {
    companion object {
        private const val CHANNEL = "org.codeberg.theoden8.webspace/remote_input"
    }

    init {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "drivenByRemote" -> result.success(drivenByRemote())
                "debugPressKey" -> {
                    // The Android TV tier (NAV-016) presses the D-pad from a
                    // test in this process, into the activity as a remote's
                    // key arrives. Debuggable builds only: MainActivity is
                    // exported, and no release build takes keys this way.
                    val debuggable =
                        (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
                    val keyCode = call.argument<Int>("keyCode")
                    if (!debuggable || keyCode == null) {
                        result.error("UNAVAILABLE", "debuggable builds only, with a keyCode", null)
                    } else {
                        pressKey(keyCode)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun pressKey(keyCode: Int) {
        val down = SystemClock.uptimeMillis()
        for (action in listOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP)) {
            activity.dispatchKeyEvent(
                KeyEvent(
                    down, SystemClock.uptimeMillis(), action, keyCode, 0, 0,
                    KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_DPAD,
                )
            )
        }
    }

    private fun drivenByRemote(): Boolean {
        val uiMode = activity.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        return uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            !activity.packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)
    }
}
