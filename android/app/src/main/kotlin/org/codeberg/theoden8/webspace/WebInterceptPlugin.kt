package org.codeberg.theoden8.webspace

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import android.webkit.WebResourceResponse
import com.pichillilorenzo.flutter_inappwebview_android.InAppWebViewFlutterPlugin
import com.pichillilorenzo.flutter_inappwebview_android.content_blocker.ContentBlocker
import com.pichillilorenzo.flutter_inappwebview_android.content_blocker.ContentBlockerAction
import com.pichillilorenzo.flutter_inappwebview_android.content_blocker.ContentBlockerHandler
import com.pichillilorenzo.flutter_inappwebview_android.content_blocker.ContentBlockerTrigger
import com.pichillilorenzo.flutter_inappwebview_android.types.WebResourceRequestExt
import com.pichillilorenzo.flutter_inappwebview_android.webview.in_app_webview.InAppWebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.util.concurrent.atomic.AtomicInteger
import java.util.regex.PatternSyntaxException

/**
 * [activity] is null in an engine the notification worker started with no
 * activity (NOTIF-016): there the only webviews are headless ones, which the
 * flutter_inappwebview plugin holds outside any view tree.
 */
class WebInterceptPlugin(
    private val activity: Activity?,
    private val flutterEngine: FlutterEngine,
) {
    private val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    // DNS blocklist. FastSubresourceInterceptor holds a reference; the set
    // inside is swapped atomically on replace (see DnsHostBlocklist).
    private val dnsBlocklist = DnsHostBlocklist()

    // ABP rules are owned end-to-end by the native adblock-rust engine
    // (see setAdblockEngine). The interceptor consults it for every
    // request that wasn't already blocked by the DNS host-only fast path.

    private val cdnTables = LocalCdnTables()

    // Repeat requests for one host (a CDN domain serving 30+ assets) collapse
    // into one counted record, so a page load costs one channel round trip
    // per batch instead of one per request.
    private val blockEvents = SiteEventInbox<BlockEvent>(wakeDart("blockEventsReady"))
    private val cdnEvents = SiteEventInbox<CdnEvent>(wakeDart("cdnEventsReady"))

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setDnsBlockedDomains" -> {
                    // One newline-joined blob, not a List<String>: the channel
                    // codec encodes/decodes a list element-by-element (type tag
                    // + length + UTF-8 per entry), which costs ~1s for a full
                    // ~650k-domain blocklist. A single string is one decode; we
                    // split it here.
                    val blob = call.argument<String>("domains")
                    if (blob != null) {
                        // Build the ~650k-entry set off the Android main thread:
                        // it's ~1.8s on ART and would freeze the UI. Mark the
                        // build in-flight first (synchronously) so a racing
                        // request thread fail-closed-waits in awaitReady; the
                        // first sub-resource request is seconds out, so the
                        // worker always wins.
                        dnsBlocklist.beginBuild()
                        Thread {
                            val t0 = System.nanoTime()
                            dnsBlocklist.replaceFromBlob(blob)
                            val buildMs = (System.nanoTime() - t0) / 1_000_000
                            log("WebIntercept",
                                "setDnsBlockedDomains: native build ${buildMs}ms " +
                                "for ${dnsBlocklist.size} domains (${blob.length} chars)")
                            // Touches the view tree -> must run on the main thread.
                            mainHandler.post { clearAllHostDecisionCaches() }
                        }.apply { name = "dns-blocklist-build"; isDaemon = true; start() }
                        // The set size isn't known until the worker finishes;
                        // the caller already knows the count, so return nothing.
                        result.success(null)
                    } else {
                        result.error("INVALID_ARGS", "domains blob required", null)
                    }
                }
                "setAdblockEngine" -> {
                    // Dart pushes the engine it built, serialized, at launch
                    // and on every rebuild, or the rules text when the blob
                    // did not hydrate; empty turns it off and reverts to the
                    // host-only fast path. Built off the main thread, where
                    // Dart itself runs; Dart awaits the reply, so no page
                    // loads before the engine is in.
                    val blob = call.argument<ByteArray>("blob")
                    val rulesText = call.argument<String>("rulesText")
                    val enableUboResources =
                        call.argument<Boolean>("enableUboResources") ?: true
                    engineBuilds.execute {
                        if (blob != null) {
                            AdblockEngineNative.setEngine(blob, enableUboResources)
                        } else {
                            AdblockEngineNative.setRules(rulesText ?: "", enableUboResources)
                        }
                        mainHandler.post {
                            // host-decision cache keys on host only, but the
                            // engine answers per (url, source, type). Hits
                            // that previously read ALLOWED from the cache
                            // would shadow the engine — clear so the engine
                            // gets to vote.
                            clearAllHostDecisionCaches()
                            result.success(mapOf(
                                "supported" to AdblockEngineNative.supported,
                                "active" to AdblockEngineNative.active,
                            ))
                        }
                    }
                }
                "isAdblockEngineSupported" -> {
                    // Diagnostic for the Dart-side UI: lets the toggle
                    // know whether the .so loaded so it can grey out
                    // the switch when the build skipped the Rust step.
                    result.success(AdblockEngineNative.supported)
                }
                "setCdnPatterns" -> {
                    val patterns = call.argument<List<String>>("patterns")
                    if (patterns != null) {
                        // Java and Dart regex dialects differ; a pattern only
                        // Dart accepts is skipped rather than failing the set.
                        val compiled = patterns.mapNotNull { p ->
                            try {
                                Regex(p)
                            } catch (_: PatternSyntaxException) {
                                null
                            }
                        }
                        cdnTables.patterns = compiled
                        result.success(compiled.size)
                    } else {
                        result.error("INVALID_ARGS", "patterns list required", null)
                    }
                }
                "setCdnCacheIndex" -> {
                    val index = call.argument<Map<String, String>>("index")
                    if (index != null) {
                        cdnTables.index = index.toMap()
                        result.success(index.size)
                    } else {
                        result.error("INVALID_ARGS", "index map required", null)
                    }
                }
                "attachToWebViews" -> {
                    val siteId = call.argument<String>("siteId")
                    val dnsLevel = call.argument<Int>("dnsLevel")
                    val localCdn = call.argument<Boolean>("localCdn")
                    val count = attachToAllWebViews(siteId, dnsLevel, localCdn)
                    result.success(count)
                }
                "attachToHeadless" -> {
                    val headlessId = call.argument<String>("headlessId")
                    val siteId = call.argument<String>("siteId")
                    val dnsLevel = call.argument<Int>("dnsLevel")
                    val localCdn = call.argument<Boolean>("localCdn")
                    val webView = headlessId?.let { headlessWebView(it) }
                    if (webView == null || siteId == null) {
                        result.success(false)
                    } else {
                        if (dnsLevel != null) siteDnsLevel[siteId] = dnsLevel
                        if (localCdn != null) siteLocalCdn[siteId] = localCdn
                        siteIdMap[webView] = siteId
                        attachInterceptor(webView, siteId)
                        result.success(true)
                    }
                }
                "fetchBlockEvents" -> drain(call, result) { siteId ->
                    blockEvents.take(siteId).map { (event, count) -> event.toChannel(count) }
                }
                "fetchCdnEvents" -> drain(call, result) { siteId ->
                    cdnEvents.take(siteId).flatMap { (event, count) ->
                        List(count) { event.toChannel() }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun drain(
        call: MethodCall,
        result: MethodChannel.Result,
        take: (siteId: String) -> List<Map<String, Any>>,
    ) {
        val siteId = call.argument<String>("siteId")
        if (siteId == null) {
            result.error("INVALID_ARGS", "siteId required", null)
        } else {
            result.success(take(siteId))
        }
    }

    private fun wakeDart(method: String): (String, () -> Unit) -> Unit = { siteId, answered ->
        mainHandler.post {
            channel.invokeMethod(method, siteId, object : MethodChannel.Result {
                override fun success(result: Any?) = answered()
                override fun error(code: String, message: String?, details: Any?) = answered()
                override fun notImplemented() = answered()
            })
        }
    }

    /// Forward a log line to Dart's LogService so the user can see what
    /// the native interceptor is doing without plugging into logcat.
    fun log(tag: String, message: String) {
        mainHandler.post {
            channel.invokeMethod("log", mapOf("tag" to tag, "message" to message), null)
        }
    }

    private fun attachToAllWebViews(
        newSiteId: String?,
        dnsLevel: Int? = null,
        localCdn: Boolean? = null
    ): Int {
        if (newSiteId != null && dnsLevel != null) siteDnsLevel[newSiteId] = dnsLevel
        if (newSiteId != null && localCdn != null) siteLocalCdn[newSiteId] = localCdn
        val webViews = collectWebViews()
        val alreadyAttached = webViews.count {
            it.contentBlockerHandler is FastSubresourceInterceptor
        }
        log("WebIntercept",
            "attachToAllWebViews(newSiteId=$newSiteId): " +
            "found=${webViews.size} alreadyAttached=$alreadyAttached " +
            "willAttach=${webViews.size - alreadyAttached}")

        // PlatformView attachment race: onWebViewCreated fires on the
        // Dart side BEFORE the native android.view.WebView has been
        // added to the activity's view tree (Flutter's hybrid composition
        // path materialises the platform view asynchronously). When we
        // get called too early, decorView traversal finds zero views
        // and we silently no-op — and the new site loads its first
        // resources without an interceptor attached. Schedule retries
        // with exponential backoff until we actually find something.
        if (webViews.isEmpty() && newSiteId != null) {
            scheduleAttachRetry(newSiteId, attempt = 1)
        }

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
            val existing = webView.contentBlockerHandler as? FastSubresourceInterceptor
            if (existing == null && newSiteId != null) {
                siteIdMap[webView] = newSiteId
            }
            val siteId = siteIdMap[webView] ?: "unknown"
            if (existing != null) {
                // Already attached: the settings edit only moves the level.
                // The host cache holds masks, not decisions, so it survives.
                existing.dnsLevel = levelFor(siteId)
                existing.localCdnEnabled = localCdnFor(siteId)
                continue
            }
            attachInterceptor(webView, siteId)
        }
        return webViews.size
    }

    /// A site's own level, remembered across re-attach so a call that names
    /// no level (the LocalCDN kill switch re-attaching everything) can't
    /// silently promote a site back to full blocking. Unknown sites fail
    /// closed at the strongest level.
    private fun levelFor(siteId: String) =
        siteDnsLevel[siteId] ?: DnsHostBlocklist.MAX_LEVEL

    /// Unknown sites keep the pre-per-site behaviour: serve the cache.
    private fun localCdnFor(siteId: String) = siteLocalCdn[siteId] ?: true

    private fun attachInterceptor(webView: InAppWebView, siteId: String) {
        val level = levelFor(siteId)
        val cdn = localCdnFor(siteId)
        webView.contentBlockerHandler = FastSubresourceInterceptor(
            dnsBlocklist = dnsBlocklist,
            dnsLevel = level,
            localCdnEnabled = cdn,
            cdnTables = cdnTables,
            onBlockChecked = { blockEvents.record(siteId, it) },
            onCdnReplaced = { cdnEvents.record(siteId, it) },
            onLog = { tag, message -> log(tag, message) }
        )
        log("WebIntercept",
            "Attached interceptor: siteId=$siteId dnsLevel=$level localCdn=$cdn " +
            "dns=${dnsBlocklist.size} " +
            "cdnPatterns=${cdnTables.patterns.size} " +
            "cdnCache=${cdnTables.index.size}")
    }

    private fun inAppWebViewPlugin(): InAppWebViewFlutterPlugin? =
        flutterEngine.plugins.get(InAppWebViewFlutterPlugin::class.java)
            as? InAppWebViewFlutterPlugin

    private fun headlessWebView(id: String): InAppWebView? =
        inAppWebViewPlugin()?.headlessInAppWebViewManager?.webViews?.get(id)
            ?.flutterWebView?.webView

    /// Every webview this engine runs: those in the activity's view tree,
    /// and the headless ones, which are in no tree while no activity is.
    private fun collectWebViews(): MutableList<InAppWebView> {
        val webViews = mutableListOf<InAppWebView>()
        activity?.window?.decorView?.rootView?.let { findInAppWebViews(it, webViews) }
        val headless = inAppWebViewPlugin()?.headlessInAppWebViewManager?.webViews?.values
        if (headless != null) {
            for (h in headless) {
                val w = h?.flutterWebView?.webView ?: continue
                if (w !in webViews) webViews.add(w)
            }
        }
        return webViews
    }

    private val siteIdMap = HashMap<InAppWebView, String>()

    /// Last DNS severity level Dart reported for each site. Read on every
    /// attach so an interceptor created by a call that names no level still
    /// gets the site's own posture.
    private val siteDnsLevel = HashMap<String, Int>()

    /// Last per-site LocalCDN decision Dart reported (LCDN-007), read on every
    /// attach like [siteDnsLevel]. Main thread only.
    private val siteLocalCdn = HashMap<String, Boolean>()

    /// Exponential backoff: 50, 100, 200, 400, 800 ms. The platform-
    /// view materialisation lag is usually 1-2 frames; this gives us
    /// up to ~1.5s before we give up. If we still find nothing the
    /// site simply doesn't have a visible webview (e.g. lazy-loaded
    /// site in IndexedStack waiting for first navigation) and the
    /// next `attachToWebViews` call from Dart at navigation time
    /// will pick it up cleanly.
    private val attachRetryDelaysMs = intArrayOf(50, 100, 200, 400, 800)

    private fun scheduleAttachRetry(siteId: String, attempt: Int) {
        if (attempt > attachRetryDelaysMs.size) {
            log("WebIntercept",
                "attachToAllWebViews retries exhausted for siteId=$siteId — " +
                "webview not yet in tree, will reattach on next navigation")
            return
        }
        val delayMs = attachRetryDelaysMs[attempt - 1].toLong()
        mainHandler.postDelayed({
            val webViews = collectWebViews()
            if (webViews.isEmpty()) {
                log("WebIntercept",
                    "attach retry $attempt for siteId=$siteId: still found=0, " +
                    "will retry in ${if (attempt < attachRetryDelaysMs.size)
                        attachRetryDelaysMs[attempt] else "—"}ms")
                scheduleAttachRetry(siteId, attempt + 1)
                return@postDelayed
            }
            log("WebIntercept",
                "attach retry $attempt for siteId=$siteId: found=${webViews.size}, attaching")
            attachToAllWebViews(siteId)
        }, delayMs)
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

    /// Walk every attached `FastSubresourceInterceptor` and invalidate
    /// its per-host decision cache. Called whenever the DNS set or the
    /// engine rules are replaced — without this a host the page already
    /// fetched (and got `Decision.ALLOWED` cached for) stays allowed
    /// even after the rule that would block it lands. The shared
    /// `dnsBlocklist` swaps in the new set so the interceptor sees the
    /// new contents on the next cache miss; this call ensures there IS a miss.
    private fun clearAllHostDecisionCaches() {
        val webViews = collectWebViews()
        var cleared = 0
        for (webView in webViews) {
            (webView.contentBlockerHandler as? FastSubresourceInterceptor)?.let {
                it.clearHostDecisionCache()
                cleared++
            }
        }
        if (cleared > 0) {
            log("WebIntercept", "Invalidated host decision cache on $cleared interceptor(s)")
        }
    }

    companion object {
        const val CHANNEL = "org.codeberg.theoden8.webspace/web_intercept"

        // At most one thread for the process, so engine pushes apply in the
        // order they were sent whichever engine sent them; it exits when idle,
        // so a background wake's engine leaves no thread behind.
        private val engineBuilds = java.util.concurrent.ThreadPoolExecutor(
            0, 1, 30L, java.util.concurrent.TimeUnit.SECONDS,
            java.util.concurrent.LinkedBlockingQueue(),
        ) { r -> Thread(r, "adblock-engine-build").apply { isDaemon = true } }
    }
}

/// What LocalCDN can serve, written by the plugin on the main thread and read
/// by every interceptor on chromium IO threads. Dart replaces each table
/// whole, so each is an immutable snapshot behind a volatile reference: a
/// reader sees the old table or the new one, never one half-applied.
class LocalCdnTables {
    /// CDN URL patterns, each exposing groups 1/2/3 = library/version/file
    /// (matching the Dart _cdnPatterns table).
    @Volatile
    var patterns: List<Regex> = emptyList()

    /// Cache key (`lib/ver/file`) to the absolute path of the cached copy.
    @Volatile
    var index: Map<String, String> = emptyMap()
}

/// One sub-resource verdict. The verdict is part of the identity: the engine
/// decides per URL, so one host is often allowed for its page assets and
/// blocked for its ad paths in the same drain window.
data class BlockEvent(val host: String, val blocked: Boolean, val source: String?) {
    /// The `{host, blocked, source?, count}` row `WebInterceptNative.applyBlockEvents` reads.
    fun toChannel(count: Int): Map<String, Any> = buildMap {
        put("host", host)
        put("blocked", blocked)
        if (source != null) put("source", source)
        put("count", count)
    }
}

/// One CDN request served from the cache instead of the network.
data class CdnEvent(val cacheKey: String, val url: String) {
    fun toChannel(): Map<String, Any> = mapOf("cacheKey" to cacheKey, "url" to url)
}

/// Native ContentBlockerHandler that handles DNS host-only blocking, the
/// adblock-rust engine's per-request ABP decisions, and LocalCDN
/// replacement for sub-resource requests. Runs on the WebView thread
/// (no main-thread roundtrip), which is why it actually fires for
/// sub-resources where Dart-side shouldInterceptRequest only catches
/// the main document navigation on modern Chromium WebView.
///
/// DNS is checked before ABP so that requests which appear in both
/// sources are attributed to DNS (the user-facing blocklist with the
/// tighter severity settings). Stats downstream can be disentangled by
/// source.
///
/// Hot-path notes:
/// * Host extraction avoids `java.net.URI`. Java's URI ctor is strict
///   about RFC 3986 and throws on perfectly valid web URLs (spaces,
///   curly braces in query strings, etc.); each throw allocates a stack
///   trace. The substring-based [extractHost] handles every form
///   chromium delivers without throwing.
/// * [DnsHostBlocklist.isBlocked] walks the suffix hierarchy without
///   `host.split(".")` / `parts.subList(...).joinToString(".")` per level.
/// * [hostDecision] caches the DNS host-only classification so repeat
///   requests to the same host skip the suffix walk. Engine decisions
///   are NOT cached here because the answer depends on (url, source,
///   type), not just the host; the engine has its own internal caching.
class FastSubresourceInterceptor(
    private val dnsBlocklist: DnsHostBlocklist,
    dnsLevel: Int = DnsHostBlocklist.MAX_LEVEL,
    localCdnEnabled: Boolean = true,
    private val cdnTables: LocalCdnTables,
    private val onBlockChecked: (BlockEvent) -> Unit,
    private val onCdnReplaced: (CdnEvent) -> Unit,
    private val onLog: (String, String) -> Unit = { _, _ -> }
) : ContentBlockerHandler() {

    /// Severity level this site blocks at; 0 when it has DNS blocking off.
    /// The blocklist is app-wide, so this is the only place an Android
    /// sub-resource learns the site's own DNS posture. Volatile because a
    /// settings edit moves it on the main thread while chromium IO threads
    /// are reading it.
    @Volatile
    var dnsLevel: Int = dnsLevel

    /// Whether this site serves CDN sub-resources from the app-wide cache
    /// (LCDN-007). Volatile for the same reason as [dnsLevel].
    @Volatile
    var localCdnEnabled: Boolean = localCdnEnabled

    private val checkCount = AtomicInteger()

    @Volatile
    private var loggedNoCache = false

    /// Per-instance host level-mask cache, read and written by chromium's
    /// concurrent sub-resource IO threads (BUG-007). Capacity 1024 covers a
    /// typical busy page (a few hundred unique hosts) plus headroom; past it
    /// the oldest entry goes. Caches which levels name the host rather than a
    /// blocked/allowed decision, so [dnsLevel] can move without the cached
    /// answers going stale.
    private val hostDecision = Guarded(object : LinkedHashMap<String, Int>(256, 0.75f, false) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Int>) =
            size > HOST_DECISION_CAP
    })

    /// Drop every cached host classification. Called by
    /// [WebInterceptPlugin.clearAllHostDecisionCaches] when the
    /// blocked-domains set is replaced — see comment there for the
    /// race this avoids.
    fun clearHostDecisionCache() = hostDecision.with { clear() }

    init {
        // Dummy rule so the Java guard `ruleList.size() > 0` passes
        val trigger = ContentBlockerTrigger(".*", null, null, null, null, null, null, null)
        val action = ContentBlockerAction.fromMap(mapOf("type" to "block"))
        ruleList.add(ContentBlocker(trigger, action))
    }

    private enum class Decision(val blocked: Boolean, val source: String?) {
        ALLOWED(false, null),
        BLOCKED_DNS(true, "dns"),
        BLOCKED_ABP(true, "abp"),
    }

    override fun checkUrl(
        webView: InAppWebView,
        request: WebResourceRequestExt
    ): WebResourceResponse? {
        // Normalize once, at the funnel: the engine, the LocalCDN patterns
        // and the DNS set all have to see the same hostname, and only the
        // DNS side goes through extractHost.
        val rawUrl = request.url ?: return null
        val url = stripRootDot(rawUrl)
        val host = extractHost(url) ?: return null
        if (host.isEmpty()) return null

        val check = checkCount.incrementAndGet()
        val verbose = check <= 10 || check % 100 == 0
        if (verbose) {
            onLog("WebIntercept", "checkUrl #$check host=$host url=$url")
        }

        // 1. Look up the cached DNS level mask for this host. On miss, walk
        // the groups and cache. The dominant cost the cache saves is the
        // suffix walk — `tracker.example.com` resolved once doesn't need to
        // look up `tracker.example.com`, `example.com`, then fail again on
        // every subsequent fetch. The site's level bit-tests the cached mask
        // rather than being baked into it.
        var mask = hostDecision.with { get(host) }
        val cached = mask != null
        if (mask == null) {
            // Fail-closed: if the blocklist build is still in flight, wait for
            // it rather than evaluate against an incomplete set and let a
            // tracker through. Runs on a WebView request thread (not the UI
            // thread), so blocking briefly here is safe; in practice the build
            // finished seconds ago and this returns immediately.
            if (!dnsBlocklist.awaitReady(DNS_READY_TIMEOUT_MS)) {
                onLog("WebIntercept",
                    "DNS blocklist not ready after ${DNS_READY_TIMEOUT_MS}ms — " +
                    "allowing $host (safety valve)")
            }
            val walked = dnsBlocklist.maskOf(host)
            hostDecision.with { put(host, walked) }
            mask = walked
        }
        val level = dnsLevel
        val blockedByDns = level in 1..DnsHostBlocklist.MAX_LEVEL &&
            mask and DnsHostBlocklist.levelBit(level) != 0
        var decision = if (blockedByDns) Decision.BLOCKED_DNS else Decision.ALLOWED
        if (verbose) {
            onLog("WebIntercept",
                "  host-only decision=$decision (mask=$mask level=$level " +
                "cached=$cached, dnsSetSize=${dnsBlocklist.size})")
        }

        // 1b. When the DNS host-only check let it through, consult the
        // adblock-rust engine. `$domain=`, path-anchored, and
        // resource-type rules all live in the engine — DNS is just the
        // user-curated host blocklist. Engine decisions are not cached
        // in `hostDecision` because the answer depends on the URL +
        // sourceUrl + requestType, not just the host.
        if (decision == Decision.ALLOWED && AdblockEngineNative.active) {
            // shouldInterceptRequest runs on chromium's IO thread, so
            // we CANNOT call webView.getUrl() here — WebView methods
            // are main-thread-only and StrictMode flags the violation.
            // The Referer header carries the page URL the request
            // originated from, which is exactly what the engine needs
            // for $domain= matching. Both casings to survive header
            // normalization quirks across chromium versions.
            val headers = request.headers ?: emptyMap()
            val sourceUrl = stripRootDot(headers["Referer"] ?: headers["referer"] ?: "")
            val requestType = mapResourceType(request)
            if (AdblockEngineNative.checkUrl(url, sourceUrl, requestType)) {
                decision = Decision.BLOCKED_ABP
                if (verbose) {
                    onLog("WebIntercept",
                        "engine blocked sub-resource: host=$host source=$sourceUrl type=$requestType")
                }
            }
        }

        // Always report: the plugin's inbox counts repeats, so a host that
        // fires a hundred times costs one Dart-side record per verdict.
        onBlockChecked(BlockEvent(host, decision.blocked, decision.source))

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
        if (decision.blocked) {
            // ABP-only: try to serve the uBO redirect body if the
            // matched rule was a `$redirect=`. Falls through to the
            // empty-body response when:
            //   * decision was DNS (DNS rules don't carry $redirect)
            //   * engine isn't active (host-only fast-path block)
            //   * matched rule has no $redirect= option
            //   * resource name in the rule isn't in the loaded pool
            // The empty-body path is the legacy / status-quo block; the
            // redirect path is the upgrade that keeps sites probing for
            // the replacement library working (Google Analytics
            // shims, AdSense neutered scripts, etc.).
            if (decision == Decision.BLOCKED_ABP && AdblockEngineNative.active) {
                val headers = request.headers ?: emptyMap()
                val sourceUrl = stripRootDot(headers["Referer"] ?: headers["referer"] ?: "")
                val requestType = mapResourceType(request)
                val dataUrl = AdblockEngineNative.redirectFor(
                    url, sourceUrl, requestType)
                if (dataUrl != null) {
                    val response = redirectResponseFor(dataUrl)
                    if (response != null) {
                        if (verbose) {
                            onLog("WebIntercept",
                                "engine served \$redirect= body for host=$host " +
                                "type=$requestType")
                        }
                        return response
                    }
                }
            }
            return WebResourceResponse(
                "text/plain", "utf-8", ByteArrayInputStream(EMPTY_BODY))
        }

        // 3. LocalCDN.
        return localCdnResponse(url)
    }

    /// The cached copy of a CDN sub-resource, or null to let the request
    /// through: [localCdnEnabled] is this site's own choice (LCDN-007).
    internal fun localCdnResponse(url: String): WebResourceResponse? {
        if (!localCdnEnabled) return null
        val patterns = cdnTables.patterns
        val index = cdnTables.index
        if (patterns.isEmpty() || index.isEmpty()) {
            if (!loggedNoCache) {
                loggedNoCache = true
                onLog("WebIntercept",
                    "LocalCDN inert: patterns=${patterns.size} cache=${index.size}")
            }
            return null
        }
        for (pattern in patterns) {
            val match = pattern.find(url) ?: continue
            if (match.groupValues.size < 4) continue
            val lib = match.groupValues[1].lowercase()
            val ver = match.groupValues[2]
            val file = match.groupValues[3]
            if (lib.isEmpty() || ver.isEmpty() || file.isEmpty()) continue
            val cacheKey = "$lib/$ver/$file"
            val filePath = index[cacheKey]
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
                onCdnReplaced(CdnEvent(cacheKey, url))
                onLog("LocalCDN", "Replaced: $url -> $cacheKey")
                WebResourceResponse(contentTypeFor(file), "utf-8", stream)
            } catch (e: FileNotFoundException) {
                onLog("WebIntercept", "CDN serve failed: key=$cacheKey err=${e.message}")
                null
            }
        }
        return null
    }

    /**
     * Classify a sub-resource request into ABP's resource-type
     * taxonomy so the engine's `$script`, `$image`, `$xhr`, etc.
     * modifiers can fire. The Android WebResourceRequest doesn't
     * carry a direct resource-type field — chromium only exposes
     * URL + headers + method + isForMainFrame — so we triangulate:
     *   1. `isForMainFrame` → "document".
     *   2. `Sec-Fetch-Dest` header (Chromium adds it on most
     *      requests as of WebView 96+).
     *   3. URL extension fallback.
     *   4. "other" as the final default — ABP rules without a
     *      resource-type modifier still match this.
     */
    /**
     * Build a `WebResourceResponse` from an adblock-rust redirect
     * data URL (`data:<mime>;base64,<body>`). Returns null when the
     * URL doesn't parse — caller falls back to the empty-body
     * response. Supports both base64 (the format adblock-rust emits
     * for binary + JS resources) and plain (rare; defensively
     * handled).
     */
    internal fun redirectResponseFor(dataUrl: String): WebResourceResponse? {
        if (!dataUrl.startsWith("data:")) return null
        val semi = dataUrl.indexOf(';', startIndex = 5)
        val comma = dataUrl.indexOf(',', startIndex = if (semi >= 0) semi else 5)
        if (comma < 0) return null
        val mime = if (semi >= 0) {
            dataUrl.substring(5, semi).ifEmpty { "application/octet-stream" }
        } else {
            dataUrl.substring(5, comma).ifEmpty { "application/octet-stream" }
        }
        val encoding = if (semi >= 0) dataUrl.substring(semi + 1, comma) else ""
        val payload = dataUrl.substring(comma + 1)
        val body = try {
            if (encoding == "base64") {
                // java.util.Base64 over android.util.Base64: the JDK
                // version is available in JVM unit tests too (the
                // Android variant returns null under returnDefault
                // Values=true, NPE-ing the ByteArrayInputStream ctor).
                java.util.Base64.getDecoder().decode(payload)
            } else {
                // Percent-decoded payload would be more correct here,
                // but adblock-rust emits base64 for every redirect
                // resource it produces, so plain just round-trips
                // the UTF-8 bytes.
                payload.toByteArray(Charsets.UTF_8)
            }
        } catch (_: Throwable) {
            return null
        }
        return WebResourceResponse(mime, "utf-8", ByteArrayInputStream(body))
    }

    internal fun mapResourceType(request: WebResourceRequestExt): String {
        if (request.isForMainFrame()) return "document"
        val headers = request.headers ?: emptyMap()
        // Header keys come back as the original case the browser
        // sent (typically lowercase for fetch metadata) — match
        // both casings to survive future quirks.
        val dest = headers["Sec-Fetch-Dest"] ?: headers["sec-fetch-dest"]
        if (!dest.isNullOrEmpty()) {
            return when (dest) {
                "script" -> "script"
                "style" -> "stylesheet"
                "image" -> "image"
                "font" -> "font"
                "audio", "video", "track" -> "media"
                "iframe", "frame", "embed", "object" -> "subdocument"
                "empty" -> "xhr"
                "document" -> "document"
                "websocket" -> "websocket"
                else -> "other"
            }
        }
        val url = request.url ?: return "other"
        val pathEnd = url.indexOfAny(charArrayOf('?', '#')).let {
            if (it < 0) url.length else it
        }
        val tail = url.substring(0, pathEnd).lowercase()
        return when {
            tail.endsWith(".js") || tail.endsWith(".mjs") -> "script"
            tail.endsWith(".css") -> "stylesheet"
            tail.endsWith(".png") || tail.endsWith(".jpg") ||
                tail.endsWith(".jpeg") || tail.endsWith(".gif") ||
                tail.endsWith(".webp") || tail.endsWith(".svg") ||
                tail.endsWith(".ico") -> "image"
            tail.endsWith(".woff") || tail.endsWith(".woff2") ||
                tail.endsWith(".ttf") || tail.endsWith(".otf") -> "font"
            tail.endsWith(".mp4") || tail.endsWith(".webm") ||
                tail.endsWith(".mp3") || tail.endsWith(".ogg") -> "media"
            else -> "other"
        }
    }

    companion object {
        // Upper bound a request thread will fail-closed-wait for an in-flight
        // DNS blocklist build. Generous: the build is ~1.2s and finishes
        // seconds before the first sub-resource, so this is only a valve
        // against a wedged build, never hit in normal operation.
        const val DNS_READY_TIMEOUT_MS = 15_000L

        private const val HOST_DECISION_CAP = 1024

        /// Shared empty-body buffer for blocked-request responses.
        /// Reused across calls so we don't allocate a fresh byte array
        /// per blocked sub-resource (Reddit page loads alone fire
        /// hundreds of these). The InputStream wrapping is per-call
        /// because chromium consumes/closes it.
        private val EMPTY_BODY = ByteArray(0)

        private val contentTypes = mapOf(
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
        /// no exceptions. A single trailing root dot is dropped:
        /// chromium keeps the FQDN form (`tracker.example.com.`) in the
        /// URL and DNS resolves it identically, but blocklist and
        /// filter-list hostnames are written without it.
        @JvmStatic
        fun extractHost(url: String): String? {
            val b = hostBounds(url)
            if (b < 0L) return null
            return slice(url, (b ushr 32).toInt(), (b and 0xFFFFFFFFL).toInt())
        }

        /// Drop the host's root dot inside a whole URL, leaving the rest
        /// byte-identical. The adblock engine parses the URL itself
        /// rather than taking [extractHost]'s output, so without this
        /// `$domain=` and host-anchored rules would still be matched
        /// against the FQDN form that [extractHost] already folds away.
        /// Returns [url] itself when there is nothing to drop.
        @JvmStatic
        fun stripRootDot(url: String): String {
            val b = hostBounds(url)
            if (b < 0L) return url
            val hostStart = (b ushr 32).toInt()
            val hostEnd = (b and 0xFFFFFFFFL).toInt()
            if (hostEnd <= hostStart || url[hostEnd - 1] != '.') return url
            return url.substring(0, hostEnd - 1) + url.substring(hostEnd)
        }

        /// Locate the host inside `scheme://[userinfo@]host[:port]/...`:
        /// start index in the high 32 bits, exclusive end (before any
        /// root-dot normalization) in the low 32. -1 when the URL has no
        /// `://` authority or an IPv6 literal is unterminated. Packed
        /// rather than returned as a Pair so the per-request hot path
        /// allocates nothing.
        private fun hostBounds(url: String): Long {
            val schemeEnd = url.indexOf("://")
            if (schemeEnd < 0) return -1L
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
                        return (hostStart.toLong() shl 32) or (j + 1).toLong()
                    }
                }
                return -1L
            }
            // Strip :port — first ':' between hostStart and end.
            var hostEnd = end
            for (j in hostStart until end) {
                if (url[j].code == 0x3A) {
                    hostEnd = j
                    break
                }
            }
            return (hostStart.toLong() shl 32) or hostEnd.toLong()
        }

        private fun slice(url: String, start: Int, end: Int): String {
            // One dot only: `example.com..` is not a valid FQDN form, so it
            // stays unmatched rather than folding onto `example.com`.
            // Bracketed IPv6 literals end in ']' and are untouched.
            var stop = end
            if (stop > start && url[stop - 1] == '.') stop--
            if (start >= stop) return ""
            var hasUpper = false
            for (j in start until stop) {
                val c = url[j].code
                if (c in 0x41..0x5A) {
                    hasUpper = true
                    break
                }
            }
            val s = url.substring(start, stop)
            return if (hasUpper) s.lowercase() else s
        }
    }
}
