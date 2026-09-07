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
 * Ensures the app holds a capture runtime permission before the webview grants
 * a page's capture permission request. Android's `PermissionRequest.grant()`
 * fails silently when the app itself lacks the permission, so the Dart-side
 * grant path calls the ensure method first. Permission is requested on demand
 * via ActivityCompat; the activity forwards onRequestPermissionsResult here
 * (same contract as LocationPlugin).
 *
 * One instance per capability, each with its own channel and request code, so
 * the camera and the microphone queue independently and a prompt for one does
 * not resolve waiters on the other.
 */
class CapturePermissionPlugin(
    private val activity: FlutterActivity,
    flutterEngine: FlutterEngine,
    channelName: String,
    private val method: String,
    private val permission: String,
    private val requestCode: Int,
) : MethodChannel.MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {

    companion object {
        fun camera(activity: FlutterActivity, engine: FlutterEngine) = CapturePermissionPlugin(
            activity, engine,
            "org.codeberg.theoden8.webspace/camera_permission",
            "ensureCameraPermission",
            Manifest.permission.CAMERA,
            0x10D,
        )

        fun microphone(activity: FlutterActivity, engine: FlutterEngine) = CapturePermissionPlugin(
            activity, engine,
            "org.codeberg.theoden8.webspace/microphone_permission",
            "ensureMicrophonePermission",
            Manifest.permission.RECORD_AUDIO,
            0x10E,
        )
    }

    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)

    // All calls arrive on the main thread; a burst of requests while the OS
    // prompt is up shares the single in-flight prompt and every waiter is
    // resolved by the one onRequestPermissionsResult.
    private val pending = mutableListOf<MethodChannel.Result>()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            method -> handleEnsurePermission(result)
            else -> result.notImplemented()
        }
    }

    private fun handleEnsurePermission(result: MethodChannel.Result) {
        val granted = ContextCompat.checkSelfPermission(
            activity, permission
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success("granted")
            return
        }
        val promptInFlight = pending.isNotEmpty()
        pending.add(result)
        if (!promptInFlight) {
            ActivityCompat.requestPermissions(
                activity, arrayOf(permission), this.requestCode
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != this.requestCode) return false
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
