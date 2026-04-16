package org.codeberg.theoden8.webspace

import android.app.Activity
import android.util.Log
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
                    val count = attachToAllWebViews()
                    result.success(count)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun reportBlocked(host: String) {
        handler.post {
            channel.invokeMethod("onDnsBlocked", host)
        }
    }

    private fun attachToAllWebViews(): Int {
        val rootView = activity.window.decorView.rootView
        val webViews = mutableListOf<InAppWebView>()
        findInAppWebViews(rootView, webViews)
        for (webView in webViews) {
            if (webView.contentBlockerHandler !is FastDnsBlockerHandler) {
                webView.contentBlockerHandler = FastDnsBlockerHandler(blockedDomains, ::reportBlocked)
            }
        }
        return webViews.size
    }

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

        val blocked = isBlockedDomain(host)
        Log.d("DnsBlock", "[Native] $host ${if (blocked) "BLOCKED" else "allowed"}")
        if (blocked) {
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
