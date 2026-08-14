package org.codeberg.theoden8.webspace

import android.Manifest
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Ensures the app holds the CAMERA runtime permission before the webview
 * grants a page's camera permission request. Android's
 * `PermissionRequest.grant()` fails silently when the app itself lacks the
 * permission, so the Dart-side grant path calls `ensureCameraPermission`
 * first. Permission is requested on demand via ActivityCompat; the activity
 * forwards onRequestPermissionsResult here (same contract as LocationPlugin).
 */
class CameraPermissionPlugin(
    private val activity: FlutterActivity,
    flutterEngine: FlutterEngine,
) : MethodChannel.MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {

    companion object {
        private const val CHANNEL = "org.codeberg.theoden8.webspace/camera_permission"
        private const val REQ_PERMISSION = 0x10D
    }

    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

    // All calls arrive on the main thread; a burst of requests while the OS
    // prompt is up shares the single in-flight prompt and every waiter is
    // resolved by the one onRequestPermissionsResult.
    private val pending = mutableListOf<MethodChannel.Result>()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ensureCameraPermission" -> handleEnsureCameraPermission(result)
            else -> result.notImplemented()
        }
    }

    private fun handleEnsureCameraPermission(result: MethodChannel.Result) {
        val granted = ContextCompat.checkSelfPermission(
            activity, Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success("granted")
            return
        }
        val promptInFlight = pending.isNotEmpty()
        pending.add(result)
        if (!promptInFlight) {
            ActivityCompat.requestPermissions(
                activity, arrayOf(Manifest.permission.CAMERA), REQ_PERMISSION
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_PERMISSION) return false
        val waiters = pending.toList()
        pending.clear()
        val granted = grantResults.any { it == PackageManager.PERMISSION_GRANTED }
        val status = if (granted) {
            "granted"
        } else {
            // shouldShowRequestPermissionRationale returns false after a
            // "deny + don't ask again"; combined with denial that means the
            // OS will not prompt again and the user must go to app settings.
            val canPromptAgain = permissions.any {
                ActivityCompat.shouldShowRequestPermissionRationale(activity, it)
            }
            if (canPromptAgain) "denied" else "denied_forever"
        }
        for (waiter in waiters) {
            waiter.success(status)
        }
        return true
    }
}
