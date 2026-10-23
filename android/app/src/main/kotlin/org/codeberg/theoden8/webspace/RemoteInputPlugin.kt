package org.codeberg.theoden8.webspace

import android.app.Activity
import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.content.pm.PackageManager
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
                else -> result.notImplemented()
            }
        }
    }

    private fun drivenByRemote(): Boolean {
        val uiMode = activity.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        return uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            !activity.packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)
    }
}
