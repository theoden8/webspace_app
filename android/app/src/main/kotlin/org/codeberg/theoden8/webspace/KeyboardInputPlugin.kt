package org.codeberg.theoden8.webspace

import android.app.Activity
import android.content.res.Configuration
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
}
