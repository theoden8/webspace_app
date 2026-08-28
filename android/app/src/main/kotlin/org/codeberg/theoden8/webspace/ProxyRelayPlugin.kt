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
                    val type = parseType(typeStr)
                    if (type == null) {
                        result.error("INVALID_TYPE", "unsupported upstream type: $typeStr", null)
                        return@setMethodCallHandler
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
                "startRouter" -> {
                    val realm = call.argument<String>("realm")
                    if (realm == null) {
                        result.error("INVALID_ARGS", "realm is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(relay.startRouter(realm))
                    } catch (e: Exception) {
                        result.error("RELAY_START_FAILED", e.message, null)
                    }
                }
                "setRoutes" -> {
                    val raw = call.argument<Map<String, Map<String, Any?>>>("routes")
                    if (raw == null) {
                        result.error("INVALID_ARGS", "routes is required", null)
                        return@setMethodCallHandler
                    }
                    val parsed = LinkedHashMap<String, ProxyRelay.Route>(raw.size)
                    for ((credential, entry) in raw) {
                        val route = parseRoute(entry)
                        if (route == null) {
                            // Fail closed on the whole table rather than
                            // installing a partial one: a site silently
                            // missing its route would be answered 502, but a
                            // site silently mis-parsed could be routed wrong.
                            result.error("INVALID_ROUTE", "malformed route entry", null)
                            return@setMethodCallHandler
                        }
                        parsed[credential] = route
                    }
                    relay.setRoutes(parsed)
                    result.success(true)
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

    private fun parseType(name: String): ProxyRelay.UpstreamType? =
        when (name.lowercase()) {
            "http" -> ProxyRelay.UpstreamType.HTTP
            "https" -> ProxyRelay.UpstreamType.HTTPS
            "socks5" -> ProxyRelay.UpstreamType.SOCKS5
            "direct" -> ProxyRelay.UpstreamType.DIRECT
            else -> null
        }

    private fun parseRoute(entry: Map<String, Any?>): ProxyRelay.Route? {
        val siteId = entry["siteId"] as? String ?: return null
        val type = parseType(entry["type"] as? String ?: return null) ?: return null
        val host = entry["host"] as? String ?: return null
        val port = entry["port"] as? Int ?: return null
        if (type != ProxyRelay.UpstreamType.DIRECT && (host.isEmpty() || port !in 1..65535)) {
            return null
        }
        return ProxyRelay.Route(
            siteId = siteId,
            upstream = ProxyRelay.UpstreamConfig(
                type = type,
                host = host,
                port = port,
                username = entry["username"] as? String,
                password = entry["password"] as? String,
            ),
        )
    }

    companion object {
        private const val TAG = "ProxyRelayPlugin"
        const val CHANNEL = "org.codeberg.theoden8.webspace/proxy_relay"
    }
}
