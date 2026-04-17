package org.codeberg.theoden8.webspace

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import android.webkit.WebResourceResponse
import com.pichillilorenzo.flutter_inappwebview_android.content_blocker.ContentBlocker
import com.pichillilorenzo.flutter_inappwebview_android.content_blocker.ContentBlockerAction
import com.pichillilorenzo.flutter_inappwebview_android.content_blocker.ContentBlockerHandler
import com.pichillilorenzo.flutter_inappwebview_android.content_blocker.ContentBlockerTrigger
import com.pichillilorenzo.flutter_inappwebview_android.types.WebResourceRequestExt
import com.pichillilorenzo.flutter_inappwebview_android.webview.in_app_webview.InAppWebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.URI
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

class DnsBlockPlugin(private val activity: Activity, flutterEngine: FlutterEngine) {
    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
    private val blockedDomains = HashSet<String>()
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    // Per-site pending events. Java is the source of truth; Dart pulls on demand.
    // Each event is {"host": String, "blocked": Boolean}.
    private val pendingEvents = ConcurrentHashMap<String, MutableList<Map<String, Any>>>()
    // Whether a signal is in flight for this siteId (prevents signal spam).
    private val signalPending = ConcurrentHashMap<String, AtomicBoolean>()

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setBlockedDomains" -> {
                    val domains = call.argument<List<String>>("domains")
                    if (domains != null) {
                        blockedDomains.clear()
                        blockedDomains.addAll(domains)
                        result.success(blockedDomains.size)
                    } else {
                        result.error("INVALID_ARGS", "domains list required", null)
                    }
                }
                "attachToWebViews" -> {
                    val siteId = call.argument<String>("siteId")
                    val count = attachToAllWebViews(siteId)
                    result.success(count)
                }
                "fetchEvents" -> {
                    val siteId = call.argument<String>("siteId")
                    if (siteId == null) {
                        result.error("INVALID_ARGS", "siteId required", null)
                    } else {
                        val list = pendingEvents[siteId]
                        if (list == null) {
                            result.success(emptyList<Map<String, Any>>())
                        } else {
                            val snapshot: List<Map<String, Any>>
                            synchronized(list) {
                                snapshot = ArrayList(list)
                                list.clear()
                            }
                            result.success(snapshot)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Records a DNS event (allowed or blocked) for this site and signals
    /// Dart once per batch. If Dart is already processing an earlier signal
    /// for this site, subsequent events just accumulate — no duplicate signals.
    private fun recordEvent(siteId: String, host: String, blocked: Boolean) {
        val list = pendingEvents.computeIfAbsent(siteId) {
            Collections.synchronizedList(mutableListOf())
        }
        list.add(mapOf("host" to host, "blocked" to blocked))

        val signaled = signalPending.computeIfAbsent(siteId) { AtomicBoolean(false) }
        if (signaled.compareAndSet(false, true)) {
            mainHandler.post {
                channel.invokeMethod("dnsEventsReady", siteId, object : MethodChannel.Result {
                    override fun success(result: Any?) { signaled.set(false) }
                    override fun error(code: String, message: String?, details: Any?) { signaled.set(false) }
                    override fun notImplemented() { signaled.set(false) }
                })
            }
        }
    }

    private fun attachToAllWebViews(newSiteId: String?): Int {
        val rootView = activity.window.decorView.rootView
        val webViews = mutableListOf<InAppWebView>()
        findInAppWebViews(rootView, webViews)
        for (webView in webViews) {
            val isNew = webView.contentBlockerHandler !is FastDnsBlockerHandler
            if (isNew && newSiteId != null) {
                siteIdMap[webView] = newSiteId
            }
            if (isNew) {
                val siteId = siteIdMap[webView] ?: "unknown"
                webView.contentBlockerHandler = FastDnsBlockerHandler(blockedDomains) { host, blocked ->
                    recordEvent(siteId, host, blocked)
                }
            }
        }
        return webViews.size
    }

    private val siteIdMap = HashMap<InAppWebView, String>()

    private fun findInAppWebViews(view: View, results: MutableList<InAppWebView>) {
        if (view is InAppWebView) {
            results.add(view)
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findInAppWebViews(view.getChildAt(i), results)
            }
        }
    }

    companion object {
        const val CHANNEL = "org.codeberg.theoden8.webspace/dns_block"
    }
}

class FastDnsBlockerHandler(
    private val blockedDomains: HashSet<String>,
    private val onChecked: (String, Boolean) -> Unit
) : ContentBlockerHandler() {

    init {
        // Dummy rule so the Java guard `ruleList.size() > 0` passes
        val trigger = ContentBlockerTrigger(".*", null, null, null, null, null, null, null)
        val action = ContentBlockerAction.fromMap(mapOf("type" to "block"))
        ruleList.add(ContentBlocker(trigger, action))
    }

    override fun checkUrl(
        webView: InAppWebView,
        request: WebResourceRequestExt
    ): WebResourceResponse? {
        val url = request.url ?: return null
        val host = try {
            URI(url).host?.lowercase() ?: return null
        } catch (e: Exception) {
            return null
        }
        if (host.isEmpty()) return null

        val blocked = isBlockedDomain(host)
        onChecked(host, blocked)
        if (blocked) {
            return WebResourceResponse("text/plain", "utf-8", null)
        }
        return null
    }

    private fun isBlockedDomain(host: String): Boolean {
        if (blockedDomains.contains(host)) return true
        val parts = host.split(".")
        for (i in 1 until parts.size - 1) {
            if (blockedDomains.contains(parts.subList(i, parts.size).joinToString("."))) {
                return true
            }
        }
        return false
    }
}
