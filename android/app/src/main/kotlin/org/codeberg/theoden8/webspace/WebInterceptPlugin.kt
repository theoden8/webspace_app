package org.codeberg.theoden8.webspace

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebResourceResponse
import com.pichillilorenzo.flutter_inappwebview_android.content_blocker.ContentBlocker
import com.pichillilorenzo.flutter_inappwebview_android.content_blocker.ContentBlockerAction
import com.pichillilorenzo.flutter_inappwebview_android.content_blocker.ContentBlockerHandler
import com.pichillilorenzo.flutter_inappwebview_android.content_blocker.ContentBlockerTrigger
import com.pichillilorenzo.flutter_inappwebview_android.types.WebResourceRequestExt
import com.pichillilorenzo.flutter_inappwebview_android.webview.in_app_webview.InAppWebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.nio.charset.Charset
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.GZIPInputStream
import java.util.zip.InflaterInputStream

class WebInterceptPlugin(private val activity: Activity, flutterEngine: FlutterEngine) {
    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    // DNS blocklist (mutated in place; FastSubresourceInterceptor holds a reference)
    private val dnsBlockedDomains = HashSet<String>()

    // ABP blocklist built from enabled filter lists' `||domain^` rules.
    // Kept separate from DNS so each block event can be attributed to the
    // list that matched it (see FastSubresourceInterceptor.checkUrl).
    private val abpBlockedDomains = HashSet<String>()

    // LocalCDN: regex patterns matching CDN URLs. Each pattern must expose
    // groups 1/2/3 = library/version/file (matching the Dart _cdnPatterns table).
    private val cdnPatterns = mutableListOf<Regex>()
    // LocalCDN: cacheKey ("lib/ver/file") -> absolute file path on disk.
    private val cdnCacheIndex = mutableMapOf<String, String>()

    // Per-site pending block events. Stored as a per-host map keyed by
    // host so repeated requests for the same host (the dominant pattern
    // on real pages — a CDN domain serving 30+ assets) collapse into one
    // log entry with a `count` aggregate. Without this dedup, a typical
    // page enqueued 200+ HashMap allocations on the WebView thread per
    // load, pinned the synchronized list contention, and pumped 200+
    // events through the Flutter MethodChannel codec on each drain.
    private val pendingBlockEvents = ConcurrentHashMap<String, MutableMap<String, BlockEventEntry>>()
    private val blockSignalPending = ConcurrentHashMap<String, AtomicBoolean>()

    // Per-site pending LocalCDN replacement events. Events carry the cache key
    // that was served; Dart turns each into a recordReplacement(siteId) call.
    private val pendingCdnEvents = ConcurrentHashMap<String, MutableList<Map<String, Any>>>()
    private val cdnSignalPending = ConcurrentHashMap<String, AtomicBoolean>()

    // Diagnostic kill-switch for the LocalCDN serve path inside
    // FastSubresourceInterceptor.checkUrl. Originally added when we
    // suspected LocalCDN's FileInputStream-backed WebResourceResponse
    // was a candidate for a chromium dangling-raw_ptr crash on
    // Chrome_IOThread. Symbolicated minidump analysis later traced the
    // dangle to chromium's own `PartitionAllocUnretainedDanglingPtr`
    // self-test (a feature-gated debug check enabled on AOSP userdebug
    // builds, disabled in production Stable WebView), unrelated to
    // LocalCDN. Re-enabled.
    //
    // The flag is kept as plumbing so we can re-disable from a single
    // line if a real LocalCDN-specific crash surfaces in the future.
    private val localCdnDisabled = AtomicBoolean(false)

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setDnsBlockedDomains" -> {
                    val domains = call.argument<List<String>>("domains")
                    if (domains != null) {
                        dnsBlockedDomains.clear()
                        dnsBlockedDomains.addAll(domains)
                        result.success(dnsBlockedDomains.size)
                    } else {
                        result.error("INVALID_ARGS", "domains list required", null)
                    }
                }
                "setAbpBlockedDomains" -> {
                    val domains = call.argument<List<String>>("domains")
                    if (domains != null) {
                        abpBlockedDomains.clear()
                        abpBlockedDomains.addAll(domains)
                        result.success(abpBlockedDomains.size)
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
                    val desktopMode = call.argument<Boolean>("desktopMode") ?: false
                    val count = attachToAllWebViews(siteId, desktopMode)
                    result.success(count)
                }
                "fetchBlockEvents" -> {
                    val siteId = call.argument<String>("siteId")
                    if (siteId == null) {
                        result.error("INVALID_ARGS", "siteId required", null)
                    } else {
                        result.success(drainBlockEvents(siteId))
                    }
                }
                "fetchCdnEvents" -> {
                    val siteId = call.argument<String>("siteId")
                    if (siteId == null) {
                        result.error("INVALID_ARGS", "siteId required", null)
                    } else {
                        result.success(drainCdnEvents(siteId))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun drainCdnEvents(siteId: String): List<Map<String, Any>> {
        val list = pendingCdnEvents[siteId] ?: return emptyList()
        synchronized(list) {
            val snapshot = ArrayList(list)
            list.clear()
            return snapshot
        }
    }

    /// Drain all pending block events for a site. The map is consumed
    /// (cleared) under lock and returned as a list of `{host, blocked,
    /// source, count}` records. A repeat host that fired N times since
    /// the previous drain shows up as a single record with `count = N`.
    /// Dart applies the counts to the per-site totals while only adding
    /// one DnsLogEntry per record.
    private fun drainBlockEvents(siteId: String): List<Map<String, Any>> {
        val map = pendingBlockEvents[siteId] ?: return emptyList()
        synchronized(map) {
            if (map.isEmpty()) return emptyList()
            val snapshot = ArrayList<Map<String, Any>>(map.size)
            for ((host, entry) in map) {
                val event = HashMap<String, Any>(4)
                event["host"] = host
                event["blocked"] = entry.blocked
                if (entry.source != null) event["source"] = entry.source!!
                event["count"] = entry.count
                snapshot.add(event)
            }
            map.clear()
            return snapshot
        }
    }

    /// Records a block event (allowed or blocked, source-tagged) and
    /// signals Dart once per batch. Repeat hosts in the same drain
    /// window only bump the `count` field on the existing entry — no
    /// new HashMap allocation, no extra mainHandler.post.
    private fun recordBlockEvent(siteId: String, host: String, blocked: Boolean, source: String?) {
        val map = pendingBlockEvents.computeIfAbsent(siteId) {
            Collections.synchronizedMap(LinkedHashMap())
        }
        val isNew: Boolean
        synchronized(map) {
            val existing = map[host]
            if (existing != null) {
                existing.count++
                isNew = false
            } else {
                map[host] = BlockEventEntry(blocked, source, 1)
                isNew = true
            }
        }

        // Signal Dart only when a new host appears, OR when no signal is
        // pending (Dart will eventually drain). Bumping a count on an
        // already-pending host doesn't need a fresh wakeup.
        if (!isNew) return

        val signaled = blockSignalPending.computeIfAbsent(siteId) { AtomicBoolean(false) }
        if (signaled.compareAndSet(false, true)) {
            mainHandler.post {
                channel.invokeMethod("blockEventsReady", siteId, object : MethodChannel.Result {
                    override fun success(result: Any?) { signaled.set(false) }
                    override fun error(code: String, message: String?, details: Any?) { signaled.set(false) }
                    override fun notImplemented() { signaled.set(false) }
                })
            }
        }
    }

    /// Mutable count carrier. The map of these is the source of truth
    /// while events are pending; on drain we atomically swap the map
    /// contents and translate each entry to a serializable `Map<String, Any>`.
    private class BlockEventEntry(val blocked: Boolean, val source: String?, var count: Int)

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

    private fun attachToAllWebViews(newSiteId: String?, desktopMode: Boolean): Int {
        val rootView = activity.window.decorView.rootView
        val webViews = mutableListOf<InAppWebView>()
        findInAppWebViews(rootView, webViews)

        // Prune `siteIdMap` of entries whose webview is no longer in the
        // activity tree. Without this the map retains hard refs to disposed
        // InAppWebView instances forever, which keeps their native peer
        // alive past the point chromium thinks it's gone — exactly the
        // kind of lifetime mismatch that surfaces as a dangling raw_ptr
        // crash on the IO thread.
        if (siteIdMap.isNotEmpty()) {
            val live = HashSet<InAppWebView>(webViews)
            val it = siteIdMap.keys.iterator()
            while (it.hasNext()) {
                if (!live.contains(it.next())) it.remove()
            }
        }

        for (webView in webViews) {
            val isNew = webView.contentBlockerHandler !is FastSubresourceInterceptor
            if (isNew && newSiteId != null) {
                siteIdMap[webView] = newSiteId
            }
            if (isNew) {
                val siteId = siteIdMap[webView] ?: "unknown"
                // Always attach the interceptor. The kill-switch
                // (localCdnDisabled) governs only the LocalCDN
                // FileInputStream serve path inside checkUrl — it does
                // not gate DNS or ABP blocking, which must stay active
                // so users don't have a window where their blocklists
                // silently stop protecting sub-resource fetches.
                webView.contentBlockerHandler = FastSubresourceInterceptor(
                    dnsBlockedDomains = dnsBlockedDomains,
                    abpBlockedDomains = abpBlockedDomains,
                    cdnPatterns = cdnPatterns,
                    cdnCacheIndex = cdnCacheIndex,
                    localCdnDisabled = localCdnDisabled,
                    isDesktopMode = desktopMode,
                    onBlockChecked = { host, blocked, source ->
                        recordBlockEvent(siteId, host, blocked, source)
                    },
                    onCdnReplaced = { cacheKey, url -> recordCdnEvent(siteId, cacheKey, url) },
                    onLog = { tag, message -> log(tag, message) }
                )
                val handlerAfter = webView.contentBlockerHandler
                val s = webView.settings
                log("WebIntercept",
                    "Attached interceptor: siteId=$siteId desktop=$desktopMode " +
                    "dns=${dnsBlockedDomains.size} abp=${abpBlockedDomains.size} " +
                    "cdnPatterns=${cdnPatterns.size} cdnCache=${cdnCacheIndex.size} " +
                    "localCdnDisabled=${localCdnDisabled.get()} " +
                    "handler=${handlerAfter::class.java.simpleName} " +
                    "ruleListSize=${handlerAfter.ruleList.size} " +
                    "useWideViewPort=${s.useWideViewPort} " +
                    "loadWithOverviewMode=${s.loadWithOverviewMode} " +
                    "ua='${s.userAgentString.take(60)}…'")
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

/// Native ContentBlockerHandler that handles DNS + ABP domain blocking
/// and LocalCDN replacement for sub-resource requests, plus main-document
/// `<meta name=viewport>` rewriting in desktop mode. Runs on the WebView
/// thread (no main-thread roundtrip), which is why it actually fires for
/// sub-resources where Dart-side shouldInterceptRequest only catches the
/// main document navigation on modern Chromium WebView.
///
/// DNS is checked before ABP so that requests which appear in both lists
/// are attributed to DNS (the user-facing blocklist with the tighter
/// severity settings). Stats downstream can be disentangled by source.
///
/// Hot-path notes:
/// * Host extraction avoids `java.net.URI`. Java's URI ctor is strict
///   about RFC 3986 and throws on perfectly valid web URLs (spaces,
///   curly braces in query strings, etc.); each throw allocates a stack
///   trace. The substring-based [extractHost] handles every form
///   chromium delivers without throwing.
/// * [isInSet] walks the suffix hierarchy without `host.split(".")` /
///   `parts.subList(...).joinToString(".")` per level. Hundreds of
///   sub-resources per page x 4–6 levels of suffix walk ≈ thousands of
///   list/string allocations on the WebView thread; the substring walk
///   keeps that down to one substring per parent label visited.
/// * [hostDecision] caches the (DNS+ABP+allowed) classification per
///   host so a page that loads 50 resources from `cdn.example.com`
///   walks the suffix lookup once, not 50 times. The cache is also
///   used to dedupe block-event reporting back to Dart: only the
///   first request per (siteId, host) is enqueued, repeats just bump
///   atomic counters that Dart reconciles on each drain. Without
///   dedup, a single page load enqueued one event per allowed
///   sub-resource — hundreds of HashMap allocations + synchronizedList
///   adds per page on the critical request path.
///
/// Desktop-mode main-doc rewrite (when `isDesktopMode == true`):
/// Android Chromium WebView does NOT recompute layout when a meta
/// viewport is mutated post-parse, so the JS-shim's MutationObserver
/// rewrite (which iOS WKWebView honours) only changes the attribute
/// string. The layout viewport stays at the device's CSS width and React
/// Native Web sites (Bluesky and similar) read `window.innerWidth` and
/// the CSS `(max-width: …)` queries off it, picking the mobile branch
/// despite the desktop UA. Re-fetching the main document here and
/// rewriting the meta tag in the body BEFORE the parser reads it is the
/// only way to actually move the layout viewport.
class FastSubresourceInterceptor(
    private val dnsBlockedDomains: HashSet<String>,
    private val abpBlockedDomains: HashSet<String>,
    private val cdnPatterns: MutableList<Regex>,
    private val cdnCacheIndex: MutableMap<String, String>,
    private val localCdnDisabled: AtomicBoolean,
    private val isDesktopMode: Boolean,
    private val onBlockChecked: (String, Boolean, String?) -> Unit,
    private val onCdnReplaced: (String, String) -> Unit,
    private val onLog: (String, String) -> Unit = { _, _ -> }
) : ContentBlockerHandler() {

    private var checkCount = 0
    private var loggedNoCache = false
    private var loggedLocalCdnDisabled = false

    /// Per-instance host classification cache. Capacity 1024 covers a
    /// typical busy page (≤ a few hundred unique hosts) plus headroom;
    /// once full, FIFO eviction keeps memory bounded. Storing
    /// `Decision` (an enum) instead of raw `String?` for the source
    /// avoids re-classifying on dedup'd repeats.
    private val hostDecision = LinkedHashMap<String, Decision>(256, 0.75f, false)
    private val hostDecisionCap = 1024

    init {
        // Dummy rule so the Java guard `ruleList.size() > 0` passes
        val trigger = ContentBlockerTrigger(".*", null, null, null, null, null, null, null)
        val action = ContentBlockerAction.fromMap(mapOf("type" to "block"))
        ruleList.add(ContentBlocker(trigger, action))
    }

    private enum class Decision { ALLOWED, BLOCKED_DNS, BLOCKED_ABP }

    override fun checkUrl(
        webView: InAppWebView,
        request: WebResourceRequestExt
    ): WebResourceResponse? {
        // DEBUG: Unconditional entry log so we can confirm the fork is
        // actually dispatching to this handler. Move back behind the
        // `checkCount <= 10` gate once verified.
        onLog("WebIntercept",
            "checkUrl ENTERED url=${request.url} mainFrame=${request.isForMainFrame}")

        val url = request.url ?: return null
        val host = extractHost(url) ?: return null
        if (host.isEmpty()) return null

        checkCount++
        if (checkCount <= 10 || checkCount % 100 == 0) {
            onLog("WebIntercept",
                "checkUrl #$checkCount host=$host url=$url " +
                "mainFrame=${request.isForMainFrame}")
        }

        // 0. Main-document viewport rewrite (desktop-mode WebViews only).
        // Run BEFORE the DNS/ABP/CDN checks so a desktop-mode page on a
        // host the user has DNS-blocked still gets a clean blocked
        // response from the existing path below — the rewrite handler
        // returns null for non-main-frame requests anyway.
        if (isDesktopMode && request.isForMainFrame &&
            (url.startsWith("http://") || url.startsWith("https://")) &&
            (request.method ?: "GET").equals("GET", ignoreCase = true)) {
            val rewritten = tryRewriteMainDocViewport(url, request.headers)
            if (rewritten != null) return rewritten
            // null means upstream error / non-HTML / etc — fall through
            // to the rest of checkUrl, which for main-doc requests will
            // return null and let the WebView fetch natively.
        }

        // 1. Look up the cached classification for this host. On miss,
        // walk the DNS + ABP sets and cache. The dominant cost the cache
        // saves is the suffix walk — `tracker.example.com` resolved
        // once doesn't need to look up `tracker.example.com`,
        // `example.com`, then fail again on every subsequent fetch.
        var decision = hostDecision[host]
        if (decision == null) {
            decision = when {
                isInSet(host, dnsBlockedDomains) -> Decision.BLOCKED_DNS
                isInSet(host, abpBlockedDomains) -> Decision.BLOCKED_ABP
                else -> Decision.ALLOWED
            }
            putHostDecision(host, decision)
        }

        // Always report — the WebInterceptPlugin layer dedupes at the
        // pending-drain level, collapsing repeat requests for the same
        // host into a single Dart-side log entry while still summing
        // the count toward the per-site totals.
        when (decision) {
            Decision.BLOCKED_DNS -> onBlockChecked(host, true, "dns")
            Decision.BLOCKED_ABP -> onBlockChecked(host, true, "abp")
            Decision.ALLOWED -> onBlockChecked(host, false, null)
        }

        // 2. Domain blocking response. Use an EMPTY ByteArrayInputStream
        // for the response body, NOT null. Returning a `WebResourceResponse(
        // _, _, null)` is a documented edge case: per the chromium WebView
        // source the null body is treated as "request blocked" but the
        // response object is still routed across the IPC boundary to
        // chromium's IO thread, which on some builds dereferences the
        // InputStream during cleanup of cross-origin redirects. That's the
        // candidate for the dangling-raw_ptr SIGTRAP at
        // `partition_alloc_support.cc:770`. An empty stream gives chromium
        // a real (zero-byte) object with no null dereference.
        if (decision == Decision.BLOCKED_DNS || decision == Decision.BLOCKED_ABP) {
            return WebResourceResponse(
                "text/plain", "utf-8", ByteArrayInputStream(EMPTY_BODY))
        }

        // 3. LocalCDN — gated by the diagnostic kill-switch. Builds a
        // WebResourceResponse with a FileInputStream that chromium's IO
        // thread reads async; if the request lifecycle ends before
        // chromium consumes the stream, that's the candidate origin
        // for the System WebView dangling-raw_ptr crash on
        // Chrome_IOThread (`partition_alloc_support.cc:770`).
        if (localCdnDisabled.get()) {
            if (!loggedLocalCdnDisabled) {
                loggedLocalCdnDisabled = true
                onLog("WebIntercept",
                    "LocalCDN serve disabled (DNS + ABP blocking remain active)")
            }
            return null
        }
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

    private fun putHostDecision(host: String, decision: Decision) {
        if (hostDecision.size >= hostDecisionCap) {
            val it = hostDecision.entries.iterator()
            if (it.hasNext()) {
                it.next()
                it.remove()
            }
        }
        hostDecision[host] = decision
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

    /// Re-fetch [url] over the native HTTP stack, rewrite the
    /// `<meta name=viewport>` in the response body to a desktop width,
    /// and return the modified [WebResourceResponse]. Returns null on
    /// any path we can't safely handle (non-HTML, non-2xx, decompression
    /// failure, network error) so the WebView falls through to its own
    /// native fetch.
    ///
    /// Forwarded request headers come from [requestHeaders] (which the
    /// WebView populates with our spoofed Firefox UA, Sec-CH-UA-*,
    /// Cookie, Accept-Language, etc.) — so the upstream sees the same
    /// per-site fingerprint as the native fetch would have. We
    /// additionally pull cookies from the global CookieManager to
    /// cover the case where the caller didn't include them, and we
    /// re-apply Set-Cookie response headers back to CookieManager so
    /// the WebView's cookie jar tracks logins through the rewrite.
    private fun tryRewriteMainDocViewport(
        url: String,
        requestHeaders: Map<String, String>?
    ): WebResourceResponse? {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 10_000
                readTimeout = 30_000
                requestMethod = "GET"
                instanceFollowRedirects = true
                // Accept-Encoding controls compression; we only handle
                // gzip/deflate/identity below, so cap it to those (the
                // WebView's original Accept-Encoding may include br
                // which we don't decompress here).
                setRequestProperty("Accept-Encoding", "gzip, deflate")
            }
            requestHeaders?.forEach { (k, v) ->
                if (k.equals("Accept-Encoding", ignoreCase = true)) return@forEach
                if (k.equals("Host", ignoreCase = true)) return@forEach
                connection.setRequestProperty(k, v)
            }
            // Backstop the Cookie header from the global jar if the
            // caller didn't include one.
            if (requestHeaders?.keys?.none {
                    it.equals("Cookie", ignoreCase = true)
                } != false) {
                CookieManager.getInstance().getCookie(url)?.let {
                    if (it.isNotEmpty()) connection.setRequestProperty("Cookie", it)
                }
            }

            connection.connect()
            val statusCode = connection.responseCode
            if (statusCode < 200 || statusCode >= 400) {
                onLog("WebIntercept",
                    "Main-doc rewrite skipped: url=$url status=$statusCode")
                return null
            }

            val rawContentType = connection.contentType ?: ""
            val mime = rawContentType.substringBefore(';').trim().lowercase()
            if (mime != "text/html" && mime != "application/xhtml+xml") {
                onLog("WebIntercept",
                    "Main-doc rewrite skipped: url=$url mime='$mime'")
                return null
            }

            val charsetName = parseCharset(rawContentType) ?: "UTF-8"
            val charset = try {
                Charset.forName(charsetName)
            } catch (_: Exception) {
                Charsets.UTF_8
            }

            val bodyStream = decompressedStream(
                connection.inputStream,
                connection.contentEncoding
            )
            val bodyBytes = bodyStream.use { it.readBytes() }

            val original = String(bodyBytes, charset)
            val rewritten = rewriteViewportMeta(original)
            val rewrittenBytes = rewritten.toByteArray(charset)
            val rewriteApplied = rewritten != original

            // Re-apply Set-Cookie response headers to the WebView's
            // cookie jar. WebView does NOT auto-apply Set-Cookie from
            // synthetic shouldInterceptRequest responses, so without
            // this logins through a desktop-mode page would silently
            // drop their session cookies.
            applySetCookieHeaders(connection, url)

            // Forward upstream headers minus the ones that no longer
            // apply (length / encoding change after rewrite).
            val responseHeaders = HashMap<String, String>()
            for ((rawKey, values) in connection.headerFields) {
                val key = rawKey ?: continue
                val lk = key.lowercase()
                if (lk == "content-length" || lk == "content-encoding" ||
                    lk == "transfer-encoding" || lk == "content-type") continue
                responseHeaders[key] = values.joinToString(",")
            }

            onLog("WebIntercept",
                "Main-doc rewrite: url=$url status=$statusCode mime=$mime " +
                "charset=$charsetName origBytes=${bodyBytes.size} " +
                "rewrittenBytes=${rewrittenBytes.size} applied=$rewriteApplied " +
                "headers=${responseHeaders.size}")

            return WebResourceResponse(
                "text/html",
                charsetName,
                statusCode,
                connection.responseMessage ?: "OK",
                responseHeaders,
                ByteArrayInputStream(rewrittenBytes)
            )
        } catch (e: Exception) {
            onLog("WebIntercept",
                "Main-doc rewrite failed: url=$url err=${e.javaClass.simpleName}: ${e.message}")
            return null
        } finally {
            connection?.disconnect()
        }
    }

    private fun decompressedStream(
        raw: java.io.InputStream,
        contentEncoding: String?
    ): java.io.InputStream = when (contentEncoding?.lowercase()) {
        "gzip" -> GZIPInputStream(raw)
        "deflate" -> InflaterInputStream(raw)
        else -> raw
    }

    private fun applySetCookieHeaders(connection: HttpURLConnection, url: String) {
        val cm = CookieManager.getInstance()
        val rawHeaders = connection.headerFields
        for ((rawKey, values) in rawHeaders) {
            val key = rawKey ?: continue
            if (!key.equals("Set-Cookie", ignoreCase = true)) continue
            for (cookie in values) cm.setCookie(url, cookie)
        }
    }

    /// Allocation-free suffix-walk lookup. Same semantics as the previous
    /// `host.split(".")` + `parts.subList(i, parts.size).joinToString(".")`
    /// pattern, but uses `String.indexOf` against `host` to derive each
    /// parent label without allocating a fresh `List<String>` or composing
    /// strings via `joinToString`. The single substring per parent is
    /// the key for `set.contains(...)` — `HashSet.contains` accepts that
    /// substring directly without further allocation. Stops before the
    /// final eTLD label (`com` alone is never matched).
    private fun isInSet(host: String, set: HashSet<String>): Boolean {
        if (set.isEmpty()) return false
        if (set.contains(host)) return true
        var dot = host.indexOf('.')
        while (dot in 0 until host.length - 1) {
            val parent = host.substring(dot + 1)
            if (parent.indexOf('.') < 0) return false
            if (set.contains(parent)) return true
            dot = host.indexOf('.', dot + 1)
        }
        return false
    }

    companion object {
        /// Shared empty-body buffer for blocked-request responses.
        /// Reused across calls so we don't allocate a fresh byte array
        /// per blocked sub-resource (Reddit page loads alone fire
        /// hundreds of these). The InputStream wrapping is per-call
        /// because chromium consumes/closes it.
        private val EMPTY_BODY = ByteArray(0)

        /// Synthetic viewport `content` value injected into rewritten
        /// HTML. Must clear the widest "desktop" breakpoint a
        /// mainstream site uses; Bluesky's `useWebMediaQueries` gates
        /// `isDesktop` on `(min-width: 1300px)` and treats 800-1299
        /// as tablet, so anything <=1299 ships the tablet layout.
        /// 1366 is a common laptop width.
        private const val DESKTOP_VIEWPORT_CONTENT =
            "width=1366, initial-scale=1.0"
        // `data-ws-source="wire"` lets us prove via JS introspection
        // whether the meta in the DOM came from this wire rewrite or
        // from the JS-shim's MutationObserver post-parse fallback.
        // The data-* attribute is invisible to layout / CSS / page
        // logic so it has no semantic effect.
        private const val DESKTOP_VIEWPORT_META =
            """<meta name="viewport" content="$DESKTOP_VIEWPORT_CONTENT" data-ws-source="wire">"""

        private val VIEWPORT_META_RE = Regex(
            """<meta\b[^>]*?\bname\s*=\s*["']?viewport["']?[^>]*?>""",
            setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)
        )
        private val HEAD_OPEN_RE = Regex(
            """<head\b[^>]*>""",
            RegexOption.IGNORE_CASE
        )
        private val CHARSET_RE = Regex(
            """charset\s*=\s*["']?([^\s;"']+)["']?""",
            RegexOption.IGNORE_CASE
        )

        /// Replace any `<meta name=viewport>` in [html] with one whose
        /// `content` attribute is the desktop viewport. If no viewport
        /// meta exists, inject one as the first child of `<head>`.
        /// Pages without `<head>` fall through unchanged — the WebView
        /// would synthesise one, the page would have rendered the
        /// platform default viewport anyway, so adding a floating meta
        /// would be wasted work.
        fun rewriteViewportMeta(html: String): String {
            if (VIEWPORT_META_RE.containsMatchIn(html)) {
                return VIEWPORT_META_RE.replace(html, DESKTOP_VIEWPORT_META)
            }
            val headMatch = HEAD_OPEN_RE.find(html) ?: return html
            return html.replaceFirst(
                HEAD_OPEN_RE,
                "${headMatch.value}$DESKTOP_VIEWPORT_META"
            )
        }

        fun parseCharset(contentType: String): String? {
            val match = CHARSET_RE.find(contentType) ?: return null
            return match.groupValues[1]
        }

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

        /// Extract the lowercase host from `scheme://host[:port]/...`.
        /// Mirrors `host_lookup.dart#extractHost` so Dart and Kotlin
        /// agree on what counts as a host. Avoids `java.net.URI` which
        /// throws on URLs chromium accepts (spaces / `{` `}` in query
        /// strings, malformed userinfo, etc.) — each throw allocates a
        /// stack trace and pays for `Throwable.fillInStackTrace`. This
        /// hand-rolled extractor uses three index scans + one substring,
        /// no exceptions.
        @JvmStatic
        fun extractHost(url: String): String? {
            val schemeEnd = url.indexOf("://")
            if (schemeEnd < 0) return null
            val start = schemeEnd + 3
            val len = url.length
            var end = len
            for (j in start until len) {
                val c = url[j].code
                if (c == 0x2F || c == 0x3F || c == 0x23) {
                    end = j
                    break
                }
            }
            // Strip userinfo: last '@' before authority terminator.
            var hostStart = start
            for (j in start until end) {
                if (url[j].code == 0x40) hostStart = j + 1
            }
            // IPv6 literal: bracketed.
            if (hostStart < end && url[hostStart].code == 0x5B) {
                for (j in hostStart until end) {
                    if (url[j].code == 0x5D) {
                        return slice(url, hostStart, j + 1)
                    }
                }
                return null
            }
            // Strip :port — first ':' between hostStart and end.
            var hostEnd = end
            for (j in hostStart until end) {
                if (url[j].code == 0x3A) {
                    hostEnd = j
                    break
                }
            }
            return slice(url, hostStart, hostEnd)
        }

        private fun slice(url: String, start: Int, end: Int): String {
            if (start >= end) return ""
            var hasUpper = false
            for (j in start until end) {
                val c = url[j].code
                if (c in 0x41..0x5A) {
                    hasUpper = true
                    break
                }
            }
            val s = url.substring(start, end)
            return if (hasUpper) s.lowercase() else s
        }
    }
}
