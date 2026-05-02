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
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

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
                    val count = attachToAllWebViews(siteId)
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

    private fun attachToAllWebViews(newSiteId: String?): Int {
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
                    onBlockChecked = { host, blocked, source ->
                        recordBlockEvent(siteId, host, blocked, source)
                    },
                    onCdnReplaced = { cacheKey, url -> recordCdnEvent(siteId, cacheKey, url) },
                    onLog = { tag, message -> log(tag, message) }
                )
                log("WebIntercept",
                    "Attached interceptor: siteId=$siteId dns=${dnsBlockedDomains.size} " +
                    "abp=${abpBlockedDomains.size} cdnPatterns=${cdnPatterns.size} " +
                    "cdnCache=${cdnCacheIndex.size} " +
                    "localCdnDisabled=${localCdnDisabled.get()}")
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
/// and LocalCDN replacement for sub-resource requests. Runs on the
/// WebView thread (no main-thread roundtrip), which is why it actually
/// fires for sub-resources where Dart-side shouldInterceptRequest only
/// catches the main document navigation on modern Chromium WebView.
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
class FastSubresourceInterceptor(
    private val dnsBlockedDomains: HashSet<String>,
    private val abpBlockedDomains: HashSet<String>,
    private val cdnPatterns: MutableList<Regex>,
    private val cdnCacheIndex: MutableMap<String, String>,
    private val localCdnDisabled: AtomicBoolean,
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
        val url = request.url ?: return null
        val host = extractHost(url) ?: return null
        if (host.isEmpty()) return null

        checkCount++
        if (checkCount <= 10 || checkCount % 100 == 0) {
            onLog("WebIntercept", "checkUrl #$checkCount host=$host url=$url")
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
