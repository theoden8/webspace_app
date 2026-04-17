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
import java.io.File
import java.io.FileInputStream
import java.net.URI
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

class WebInterceptPlugin(private val activity: Activity, flutterEngine: FlutterEngine) {
    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    // DNS blocklist (mutated in place; FastSubresourceInterceptor holds a reference)
    private val blockedDomains = HashSet<String>()

    // LocalCDN: regex patterns matching CDN URLs. Each pattern must expose
    // groups 1/2/3 = library/version/file (matching the Dart _cdnPatterns table).
    private val cdnPatterns = mutableListOf<Regex>()
    // LocalCDN: cacheKey ("lib/ver/file") -> absolute file path on disk.
    private val cdnCacheIndex = mutableMapOf<String, String>()

    // Per-site pending DNS events. Java is the source of truth; Dart pulls on demand.
    private val pendingDnsEvents = ConcurrentHashMap<String, MutableList<Map<String, Any>>>()
    private val dnsSignalPending = ConcurrentHashMap<String, AtomicBoolean>()

    // Per-site pending LocalCDN replacement events. Events carry the cache key
    // that was served; Dart turns each into a recordReplacement(siteId) call.
    private val pendingCdnEvents = ConcurrentHashMap<String, MutableList<Map<String, Any>>>()
    private val cdnSignalPending = ConcurrentHashMap<String, AtomicBoolean>()

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
                "setCdnPatterns" -> {
                    val patterns = call.argument<List<String>>("patterns")
                    if (patterns != null) {
                        synchronized(cdnPatterns) {
                            cdnPatterns.clear()
                            for (p in patterns) {
                                try {
                                    cdnPatterns.add(Regex(p))
                                } catch (_: Exception) {
                                    // Skip malformed patterns (Java/Dart regex dialects differ)
                                }
                            }
                        }
                        result.success(cdnPatterns.size)
                    } else {
                        result.error("INVALID_ARGS", "patterns list required", null)
                    }
                }
                "setCdnCacheIndex" -> {
                    @Suppress("UNCHECKED_CAST")
                    val index = call.argument<Map<String, String>>("index")
                    if (index != null) {
                        synchronized(cdnCacheIndex) {
                            cdnCacheIndex.clear()
                            cdnCacheIndex.putAll(index)
                        }
                        result.success(cdnCacheIndex.size)
                    } else {
                        result.error("INVALID_ARGS", "index map required", null)
                    }
                }
                "attachToWebViews" -> {
                    val siteId = call.argument<String>("siteId")
                    val count = attachToAllWebViews(siteId)
                    result.success(count)
                }
                "fetchDnsEvents" -> {
                    val siteId = call.argument<String>("siteId")
                    if (siteId == null) {
                        result.error("INVALID_ARGS", "siteId required", null)
                    } else {
                        result.success(drainEvents(pendingDnsEvents, siteId))
                    }
                }
                "fetchCdnEvents" -> {
                    val siteId = call.argument<String>("siteId")
                    if (siteId == null) {
                        result.error("INVALID_ARGS", "siteId required", null)
                    } else {
                        result.success(drainEvents(pendingCdnEvents, siteId))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun drainEvents(
        store: ConcurrentHashMap<String, MutableList<Map<String, Any>>>,
        siteId: String
    ): List<Map<String, Any>> {
        val list = store[siteId] ?: return emptyList()
        synchronized(list) {
            val snapshot = ArrayList(list)
            list.clear()
            return snapshot
        }
    }

    /// Records a DNS event (allowed or blocked) and signals Dart once per
    /// batch. If Dart is already processing an earlier signal for this
    /// site, subsequent events just accumulate — no duplicate signals.
    private fun recordDnsEvent(siteId: String, host: String, blocked: Boolean) {
        val list = pendingDnsEvents.computeIfAbsent(siteId) {
            Collections.synchronizedList(mutableListOf())
        }
        list.add(mapOf("host" to host, "blocked" to blocked))

        val signaled = dnsSignalPending.computeIfAbsent(siteId) { AtomicBoolean(false) }
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

    /// Records that a CDN request was replaced with a cached resource for
    /// this site. Signal batching mirrors the DNS path.
    private fun recordCdnEvent(siteId: String, cacheKey: String, url: String) {
        val list = pendingCdnEvents.computeIfAbsent(siteId) {
            Collections.synchronizedList(mutableListOf())
        }
        list.add(mapOf("cacheKey" to cacheKey, "url" to url))

        val signaled = cdnSignalPending.computeIfAbsent(siteId) { AtomicBoolean(false) }
        if (signaled.compareAndSet(false, true)) {
            mainHandler.post {
                channel.invokeMethod("cdnEventsReady", siteId, object : MethodChannel.Result {
                    override fun success(result: Any?) { signaled.set(false) }
                    override fun error(code: String, message: String?, details: Any?) { signaled.set(false) }
                    override fun notImplemented() { signaled.set(false) }
                })
            }
        }
    }

    /// Forward a log line to Dart's LogService so the user can see what
    /// the native interceptor is doing without plugging into logcat.
    fun log(tag: String, message: String) {
        mainHandler.post {
            channel.invokeMethod("log", mapOf("tag" to tag, "message" to message), null)
        }
    }

    private fun attachToAllWebViews(newSiteId: String?): Int {
        val rootView = activity.window.decorView.rootView
        val webViews = mutableListOf<InAppWebView>()
        findInAppWebViews(rootView, webViews)
        for (webView in webViews) {
            val isNew = webView.contentBlockerHandler !is FastSubresourceInterceptor
            if (isNew && newSiteId != null) {
                siteIdMap[webView] = newSiteId
            }
            if (isNew) {
                val siteId = siteIdMap[webView] ?: "unknown"
                webView.contentBlockerHandler = FastSubresourceInterceptor(
                    blockedDomains = blockedDomains,
                    cdnPatterns = cdnPatterns,
                    cdnCacheIndex = cdnCacheIndex,
                    onDnsChecked = { host, blocked -> recordDnsEvent(siteId, host, blocked) },
                    onCdnReplaced = { cacheKey, url -> recordCdnEvent(siteId, cacheKey, url) },
                    onLog = { tag, message -> log(tag, message) }
                )
                log("WebIntercept",
                    "Attached interceptor: siteId=$siteId domains=${blockedDomains.size} " +
                    "cdnPatterns=${cdnPatterns.size} cdnCache=${cdnCacheIndex.size}")
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
        const val CHANNEL = "org.codeberg.theoden8.webspace/web_intercept"
    }
}

/// Native ContentBlockerHandler that handles both DNS blocking and LocalCDN
/// replacement for sub-resource requests. Runs on the WebView thread (no
/// main-thread roundtrip), which is why it actually fires for sub-resources
/// where Dart-side shouldInterceptRequest only catches the main document
/// navigation on modern Chromium WebView.
class FastSubresourceInterceptor(
    private val blockedDomains: HashSet<String>,
    private val cdnPatterns: MutableList<Regex>,
    private val cdnCacheIndex: MutableMap<String, String>,
    private val onDnsChecked: (String, Boolean) -> Unit,
    private val onCdnReplaced: (String, String) -> Unit,
    private val onLog: (String, String) -> Unit = { _, _ -> }
) : ContentBlockerHandler() {

    private var checkCount = 0
    private var loggedNoCache = false

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
        } catch (_: Exception) {
            return null
        }
        if (host.isEmpty()) return null

        checkCount++
        // Log the first handful of sub-resource intercepts so you can
        // confirm the native path is firing at all, plus periodic samples.
        if (checkCount <= 10 || checkCount % 100 == 0) {
            onLog("WebIntercept", "checkUrl #$checkCount host=$host url=$url")
        }

        // 1. DNS blocking + stats recording
        val blocked = isBlockedDomain(host)
        onDnsChecked(host, blocked)
        if (blocked) {
            return WebResourceResponse("text/plain", "utf-8", null)
        }

        // 2. LocalCDN: try to serve from the pre-downloaded cache
        if (cdnPatterns.isNotEmpty() && cdnCacheIndex.isNotEmpty()) {
            val response = tryServeCdn(url)
            if (response != null) return response
        } else if (!loggedNoCache) {
            loggedNoCache = true
            onLog("WebIntercept",
                "LocalCDN inert: patterns=${cdnPatterns.size} cache=${cdnCacheIndex.size}")
        }

        return null
    }

    private fun tryServeCdn(url: String): WebResourceResponse? {
        val patternsSnapshot = synchronized(cdnPatterns) { cdnPatterns.toList() }
        for (pattern in patternsSnapshot) {
            val match = pattern.find(url) ?: continue
            if (match.groupValues.size < 4) continue
            val lib = match.groupValues[1].lowercase()
            val ver = match.groupValues[2]
            val file = match.groupValues[3]
            if (lib.isEmpty() || ver.isEmpty() || file.isEmpty()) continue
            val cacheKey = "$lib/$ver/$file"
            val filePath = synchronized(cdnCacheIndex) { cdnCacheIndex[cacheKey] }
            if (filePath == null) {
                onLog("WebIntercept", "CDN match but no cache entry: key=$cacheKey url=$url")
                continue
            }
            val f = File(filePath)
            if (!f.exists()) {
                onLog("WebIntercept", "CDN match but file missing: key=$cacheKey path=$filePath")
                continue
            }
            return try {
                val stream = FileInputStream(f)
                onCdnReplaced(cacheKey, url)
                onLog("LocalCDN", "Replaced: $url -> $cacheKey")
                WebResourceResponse(contentTypeFor(file), "utf-8", stream)
            } catch (e: Exception) {
                onLog("WebIntercept", "CDN serve failed: key=$cacheKey err=${e.message}")
                null
            }
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

    companion object {
        private val contentTypes = linkedMapOf(
            ".js" to "application/javascript",
            ".mjs" to "application/javascript",
            ".css" to "text/css",
            ".json" to "application/json",
            ".woff2" to "font/woff2",
            ".woff" to "font/woff",
            ".ttf" to "font/ttf",
            ".otf" to "font/otf",
            ".eot" to "application/vnd.ms-fontobject",
            ".svg" to "image/svg+xml",
            ".map" to "application/json"
        )

        private fun contentTypeFor(file: String): String {
            val path = if (file.contains("?")) file.substringBefore("?") else file
            for ((ext, mime) in contentTypes) {
                if (path.endsWith(ext)) return mime
            }
            return "application/octet-stream"
        }
    }
}
