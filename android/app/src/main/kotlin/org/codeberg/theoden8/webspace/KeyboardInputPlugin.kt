package org.codeberg.theoden8.webspace

import android.app.Activity
import android.content.pm.ApplicationInfo
import android.content.res.Configuration
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Says whether a hardware keyboard is attached (NAV-019), and tells Dart
 * when that changes: the activity takes keyboard changes itself
 * (`configChanges`), so it is not recreated for one and hears of it in
 * [onConfigurationChanged]. The handler and that callback run on the main
 * looper, the only thread that reads or writes [sent] (BUG-007: none-shared).
 */
class KeyboardInputPlugin(private val activity: Activity, flutterEngine: FlutterEngine) {
    companion object {
        private const val CHANNEL = "org.codeberg.theoden8.webspace/keyboard_input"

        private fun attached(config: Configuration): Boolean =
            config.keyboard == Configuration.KEYBOARD_QWERTY &&
                config.hardKeyboardHidden == Configuration.HARDKEYBOARDHIDDEN_NO
    }

    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
    private var sent: Boolean? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "attached" -> {
                    val now = attached(activity.resources.configuration)
                    sent = now
                    result.success(now)
                }
                "debugTypeKey" -> {
                    // The Android desktop tier (INTEG-018) types into the
                    // activity as a keyboard's key arrives. Debuggable builds
                    // only, as RemoteInputPlugin's debugPressKey.
                    val debuggable =
                        (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
                    val keyCode = call.argument<Int>("keyCode")
                    val metaState = call.argument<Int>("metaState") ?: 0
                    if (!debuggable || keyCode == null) {
                        result.error("UNAVAILABLE", "debuggable builds only, with a keyCode", null)
                    } else {
                        typeKey(keyCode, metaState)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun onConfigurationChanged(config: Configuration) {
        val now = attached(config)
        if (now == sent) return
        sent = now
        channel.invokeMethod("attachedChanged", now)
    }

    private fun typeKey(keyCode: Int, metaState: Int) {
        val down = SystemClock.uptimeMillis()
        for (action in listOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP)) {
            activity.dispatchKeyEvent(
                KeyEvent(
                    down, SystemClock.uptimeMillis(), action, keyCode, 0, metaState,
                    KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD,
                )
            )
        }
    }
}
