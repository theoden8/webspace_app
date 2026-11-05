package org.codeberg.theoden8.webspace

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Android's own captive portal verdict on the network the app's traffic
 * takes (TLS-012): whether a sign-in page holds it back, and which network
 * that is, read from ConnectivityManager each time Dart asks. The OS probed
 * already, so the app sends nothing. Holds no state (BUG-007: none-shared).
 */
class NetworkSignInPlugin(private val activity: Activity, flutterEngine: FlutterEngine) {
    companion object {
        private const val CHANNEL = "org.codeberg.theoden8.webspace/network_sign_in"
    }

    init {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "verdict" -> result.success(verdict())
                "openSignIn" -> result.success(openSignIn())
                else -> result.notImplemented()
            }
        }
    }

    private fun verdict(): Map<String, Any> {
        val none = mapOf("signIn" to false)
        val connectivity = activity.getSystemService(ConnectivityManager::class.java) ?: return none
        val network = connectivity.activeNetwork ?: return none
        val capabilities = connectivity.getNetworkCapabilities(network) ?: return none
        return mapOf(
            "signIn" to capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL),
            "network" to network.networkHandle.toString(),
        )
    }

    /** Wi-Fi settings, where tapping a network that wants a sign-in opens its page. */
    private fun openSignIn(): Boolean =
        try {
            activity.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
            true
        } catch (e: ActivityNotFoundException) {
            AppLog.failed(AppLog.Tag.tls, "opening the Wi-Fi settings", e)
            false
        }
}
