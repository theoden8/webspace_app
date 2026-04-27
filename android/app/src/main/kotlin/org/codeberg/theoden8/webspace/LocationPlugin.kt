package org.codeberg.theoden8.webspace

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Returns a single GPS fix from Android's native LocationManager.
 *
 * No Google Play Services dependency — keeps the F-Droid flavor clean. Permission
 * is requested on demand via ActivityCompat; the activity must forward
 * onRequestPermissionsResult here (registered as a RequestPermissionsResultListener
 * on the FlutterEngine).
 */
class LocationPlugin(
    private val activity: FlutterActivity,
    flutterEngine: FlutterEngine,
) : MethodChannel.MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {

    companion object {
        private const val CHANNEL = "org.codeberg.theoden8.webspace/location"
        private const val REQ_PERMISSION = 0x10C
    }

    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
    private var pendingResult: MethodChannel.Result? = null
    private var pendingTimeoutMs: Long = 30_000

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCurrentLocation" -> {
                pendingTimeoutMs = (call.argument<Number>("timeoutMs")?.toLong() ?: 30_000)
                handleGetCurrentLocation(result)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleGetCurrentLocation(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.success(mapOf("status" to "error", "message" to "Another location request is already in progress."))
            return
        }
        val fineGranted = ContextCompat.checkSelfPermission(
            activity, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val coarseGranted = ContextCompat.checkSelfPermission(
            activity, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!fineGranted && !coarseGranted) {
            pendingResult = result
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                ),
                REQ_PERMISSION,
            )
            return
        }
        requestSingleLocation(result)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_PERMISSION) return false
        val pending = pendingResult
        pendingResult = null
        if (pending == null) return true

        val granted = grantResults.any { it == PackageManager.PERMISSION_GRANTED }
        if (!granted) {
            // shouldShowRequestPermissionRationale returns false after a "deny + don't ask again"
            // (or on first prompt before any answer). Combined with denial, treat the
            // false-after-denial case as "denied forever" so the UI can offer settings.
            val canPromptAgain = permissions.any {
                ActivityCompat.shouldShowRequestPermissionRationale(activity, it)
            }
            val status = if (canPromptAgain) "permission_denied" else "permission_denied_forever"
            pending.success(mapOf(
                "status" to status,
                "message" to "Location permission was not granted.",
            ))
            return true
        }
        requestSingleLocation(pending)
        return true
    }

    private fun requestSingleLocation(result: MethodChannel.Result) {
        val lm = activity.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (lm == null) {
            result.success(mapOf("status" to "error", "message" to "LocationManager unavailable."))
            return
        }
        val providers = mutableListOf<String>()
        if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) providers.add(LocationManager.GPS_PROVIDER)
        if (lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) providers.add(LocationManager.NETWORK_PROVIDER)
        if (providers.isEmpty()) {
            result.success(mapOf(
                "status" to "service_disabled",
                "message" to "Location services are disabled.",
            ))
            return
        }

        val main = Handler(Looper.getMainLooper())
        val resolved = AtomicBoolean(false)
        val listeners = mutableListOf<LocationListener>()

        fun finish(payload: Map<String, Any?>) {
            if (!resolved.compareAndSet(false, true)) return
            for (l in listeners) {
                try { lm.removeUpdates(l) } catch (_: SecurityException) {}
            }
            main.post { result.success(payload) }
        }

        for (provider in providers) {
            val listener = object : LocationListener {
                override fun onLocationChanged(location: Location) {
                    finish(mapOf(
                        "status" to "ok",
                        "latitude" to location.latitude,
                        "longitude" to location.longitude,
                        "accuracy" to (if (location.hasAccuracy()) location.accuracy.toDouble() else 0.0),
                    ))
                }

                @Deprecated("Required for older API levels")
                override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                override fun onProviderEnabled(provider: String) {}
                override fun onProviderDisabled(provider: String) {}
            }
            listeners.add(listener)
            try {
                lm.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
            } catch (e: SecurityException) {
                finish(mapOf("status" to "permission_denied", "message" to e.message))
                return
            }
        }

        // Seed with last known fix if available — common when Wi-Fi + GPS are off
        // briefly but we have a recent network fix. Reduces wait from ~10s to ~0.
        for (provider in providers) {
            try {
                val last = lm.getLastKnownLocation(provider) ?: continue
                val ageMs = System.currentTimeMillis() - last.time
                if (ageMs in 0..120_000) {
                    finish(mapOf(
                        "status" to "ok",
                        "latitude" to last.latitude,
                        "longitude" to last.longitude,
                        "accuracy" to (if (last.hasAccuracy()) last.accuracy.toDouble() else 0.0),
                    ))
                    return
                }
            } catch (_: SecurityException) {}
        }

        main.postDelayed({
            finish(mapOf(
                "status" to "timeout",
                "message" to "Timed out waiting for a location fix.",
            ))
        }, pendingTimeoutMs)
    }
}
