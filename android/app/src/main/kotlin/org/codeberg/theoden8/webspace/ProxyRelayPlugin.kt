package org.codeberg.theoden8.webspace

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.codeberg.theoden8.webspace.proxy.ProxyRelay

/**
 * Method-channel surface for the local authenticating proxy relay.
 *
 * The relay solves Android WebView's missing proxy-auth: Dart starts it
 * with the upstream credentials, gets back a loopback port, and points
 * `ProxyController` at `127.0.0.1:<port>` with no credentials. The relay
 * itself ([ProxyRelay]) holds no `android.*` deps so it is JVM-unit-tested;
 * this class is the thin Android wrapper.
 *
 * The relay runs on daemon JVM threads in the app process, independent of
 * the Flutter engine lifecycle, so it keeps serving while the engine is
 * paused (background notification-refresh sites still proxy correctly).
 */
class ProxyRelayPlugin(flutterEngine: FlutterEngine) {
    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())
    // Forward every relay event to the Dart side so it surfaces in the
    // in-app Logs tab next to the proxy-apply events — critical for the
    // container-reach diagnostic (zero accepted connections during a
    // proxied page load = ProxyController not reaching the container).
    private val relay = ProxyRelay { msg ->
        Log.i(TAG, msg)
        mainHandler.post {
            runCatching { channel.invokeMethod("logEvent", mapOf("msg" to msg)) }
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val typeStr = call.argument<String>("type")
                    val host = call.argument<String>("host")
                    val port = call.argument<Int>("port")
                    if (typeStr == null || host == null || port == null) {
                        result.error("INVALID_ARGS", "type, host and port are required", null)
                        return@setMethodCallHandler
                    }
                    val type = when (typeStr.lowercase()) {
                        "http" -> ProxyRelay.UpstreamType.HTTP
                        "https" -> ProxyRelay.UpstreamType.HTTPS
                        "socks5" -> ProxyRelay.UpstreamType.SOCKS5
                        else -> {
                            result.error("INVALID_TYPE", "unsupported upstream type: $typeStr", null)
                            return@setMethodCallHandler
                        }
                    }
                    try {
                        val localPort = relay.start(
                            ProxyRelay.UpstreamConfig(
                                type = type,
                                host = host,
                                port = port,
                                username = call.argument<String>("username"),
                                password = call.argument<String>("password"),
                            )
                        )
                        result.success(localPort)
                    } catch (e: Exception) {
                        // Bind failure: report it so Dart can fail closed
                        // rather than clearing the override (which would
                        // leak a direct connection).
                        result.error("RELAY_START_FAILED", e.message, null)
                    }
                }
                "stop" -> {
                    relay.stop()
                    result.success(true)
                }
                "isRunning" -> result.success(relay.isRunning())
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        relay.stop()
        channel.setMethodCallHandler(null)
    }

    companion object {
        private const val TAG = "ProxyRelayPlugin"
        const val CHANNEL = "org.codeberg.theoden8.webspace/proxy_relay"
    }
}
