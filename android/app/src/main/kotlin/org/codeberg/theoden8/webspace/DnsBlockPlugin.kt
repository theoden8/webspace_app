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

class DnsBlockPlugin(private val activity: Activity, flutterEngine: FlutterEngine) {
    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
    private val blockedDomains = HashSet<String>()
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

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
                else -> result.notImplemented()
            }
        }
    }

    private val pendingBlocked = mutableListOf<Map<String, String>>()
    private var flushScheduled = false

    private fun reportBlocked(siteId: String, host: String) {
        synchronized(pendingBlocked) {
            pendingBlocked.add(mapOf("siteId" to siteId, "host" to host))
            if (!flushScheduled) {
                flushScheduled = true
                handler.postDelayed({
                    val batch: List<Map<String, String>>
                    synchronized(pendingBlocked) {
                        batch = pendingBlocked.toList()
                        pendingBlocked.clear()
                        flushScheduled = false
                    }
                    if (batch.isNotEmpty()) {
                        channel.invokeMethod("onDnsBlockedBatch", batch)
                    }
                }, 200)
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
                webView.contentBlockerHandler = FastDnsBlockerHandler(blockedDomains) { host ->
                    reportBlocked(siteId, host)
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
    private val onBlocked: (String) -> Unit
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

        if (isBlockedDomain(host)) {
            onBlocked(host)
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
