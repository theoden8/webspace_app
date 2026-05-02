import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/services/bloom_filter.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/host_lookup.dart';
import 'package:webspace/services/log_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which blocklist attributed a block decision. Allowed requests have no
/// source. Stats preserve this so the UI can show a merged count while
/// still disentangling DNS vs ABP hits when needed.
enum BlockSource { dns, abp }

/// A single request log entry (allowed or blocked).
class DnsLogEntry {
  final DateTime timestamp;
  final String domain;
  final bool blocked;
  final BlockSource? source;

  const DnsLogEntry({
    required this.timestamp,
    required this.domain,
    required this.blocked,
    this.source,
  });
}

/// Per-site block request statistics (DNS + ABP combined).
///
/// `blocked`/`allowed` are merged totals; `blockedByDns`/`blockedByAbp` let
/// callers break it down without iterating the log.
///
/// The log is backed by a fixed-size ring buffer so high-volume pages
/// (hundreds of sub-resources per load) don't pay an O(n) shift on every
/// overflow — `List.removeAt(0)` on a 500-element list copies all 499
/// remaining elements per insert past the cap.
class DnsStats {
  int allowed = 0;
  int blocked = 0;
  int blockedByDns = 0;
  int blockedByAbp = 0;
  static const int _maxLogEntries = 500;

  final List<DnsLogEntry?> _ring =
      List<DnsLogEntry?>.filled(_maxLogEntries, null);
  int _head = 0;
  int _size = 0;

  int get total => allowed + blocked;
  double get blockRate => total > 0 ? blocked / total * 100 : 0;

  /// Snapshot of the log, oldest-first. Allocates a new list per call —
  /// the dev tools UI consumes this once per visible refresh, not per
  /// recorded request.
  List<DnsLogEntry> get log {
    if (_size == 0) return const <DnsLogEntry>[];
    final out = List<DnsLogEntry>.filled(_size, _ring[0]!, growable: false);
    final start = _size < _maxLogEntries ? 0 : _head;
    for (var i = 0; i < _size; i++) {
      out[i] = _ring[(start + i) % _maxLogEntries]!;
    }
    return out;
  }

  /// Record a request decision against this site's stats. [count] lets
  /// callers fold in `N` repeated requests for the same host without
  /// allocating `N` log entries — the log only ever grows by one per
  /// call, but the per-site total and source-attributed counters
  /// increment by [count]. Used by the Android native interceptor's
  /// per-host dedup batching.
  void record(String domain, bool wasBlocked, {BlockSource? source, int count = 1}) {
    if (count < 1) count = 1;
    if (wasBlocked) {
      blocked += count;
      switch (source) {
        case BlockSource.dns:
          blockedByDns += count;
          break;
        case BlockSource.abp:
          blockedByAbp += count;
          break;
        case null:
          // Unsourced block — count toward the total only. Callers should
          // always pass a source for blocked requests; this branch exists
          // so the counters stay consistent if they don't.
          break;
      }
    } else {
      allowed += count;
    }
    final entry = DnsLogEntry(
      timestamp: DateTime.now(),
      domain: domain,
      blocked: wasBlocked,
      source: wasBlocked ? source : null,
    );
    if (_size < _maxLogEntries) {
      _ring[(_head + _size) % _maxLogEntries] = entry;
      _size++;
    } else {
      _ring[_head] = entry;
      _head = (_head + 1) % _maxLogEntries;
    }
  }

  void clear() {
    allowed = 0;
    blocked = 0;
    blockedByDns = 0;
    blockedByAbp = 0;
    for (var i = 0; i < _maxLogEntries; i++) {
      _ring[i] = null;
    }
    _head = 0;
    _size = 0;
  }
}

/// Level names for DNS blocklist severity levels (0-5).
const List<String> dnsBlockLevelNames = [
  'Off',
  'Light',
  'Normal',
  'Pro',
  'Pro++',
  'Ultimate',
];

/// Domain list file names for each level (index 0 is unused since level 0 = Off).
const List<String?> _levelFiles = [
  null, // 0: Off
  'domains/light.txt', // 1: Light
  'domains/multi.txt', // 2: Normal
  'domains/pro.txt', // 3: Pro
  'domains/pro.plus.txt', // 4: Pro++
  'domains/ultimate.txt', // 5: Ultimate
];

/// Mirror base URLs tried in order on failure.
const List<String> _mirrorBaseUrls = [
  'https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/',
  'https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/',
  'https://codeberg.org/hagezi/mirror2/raw/branch/main/dns-blocklists/',
];

/// Singleton service for downloading, caching, and querying Hagezi DNS blocklists.
/// Blocks navigation to ad/malware/tracker domains at the webview level.
class DnsBlockService {
  static const String _cacheFileName = 'dns_blocklist.txt';
  static const String _levelKey = 'dns_block_level';
  static const String _lastUpdatedKey = 'dns_block_last_updated';

  static DnsBlockService? _instance;
  static DnsBlockService get instance => _instance ??= DnsBlockService._();

  DnsBlockService._();

  Set<String> _blockedDomains = {};
  int _level = 0;

  /// Per-site DNS statistics, keyed by siteId.
  final Map<String, DnsStats> _siteStats = {};

  /// Listeners notified when a DNS request is logged (for live UI updates).
  final List<VoidCallback> _dnsLogListeners = [];

  /// Whether a blocklist is loaded and active.
  bool get hasBlocklist => _blockedDomains.isNotEmpty;

  /// The currently downloaded blocklist level (0-5).
  int get level => _level;

  /// Number of domains in the current blocklist.
  int get domainCount => _blockedDomains.length;

  /// The raw blocked domains set (for sending to native handler).
  Set<String> get blockedDomains => _blockedDomains;

  /// Cached Bloom filter built from DNS domains only.
  BloomFilter? _bloomFilter;

  /// Cached Bloom filter built from DNS ∪ ABP blocked domains. Used by the
  /// iOS/macOS JS sub-resource interceptor as a "maybe blocked" prefilter;
  /// the authoritative DNS-vs-ABP decision happens in Dart on hit.
  BloomFilter? _mergedBloomFilter;

  /// Listeners invoked whenever the DNS blocklist changes (download, level
  /// change, clear). main.dart re-pushes to the native interceptor from
  /// here so individual call sites don't each have to remember to sync.
  final List<VoidCallback> _blocklistChangedListeners = [];

  void addBlocklistChangedListener(VoidCallback listener) {
    _blocklistChangedListeners.add(listener);
  }

  void removeBlocklistChangedListener(VoidCallback listener) {
    _blocklistChangedListeners.remove(listener);
  }

  void _notifyBlocklistChanged() {
    // Invalidate the merged Bloom since the DNS half changed. The
    // ContentBlockerService change path invalidates it too. The DNS hot-path
    // cache is also stale because _blockedDomains itself changed.
    _mergedBloomFilter = null;
    _dnsBlockCache.clear();
    for (final listener in List<VoidCallback>.from(_blocklistChangedListeners)) {
      listener();
    }
  }

  /// Called by ContentBlockerService when its rule set changes. Invalidates
  /// the merged Bloom and the merged host-decision cache (which may have
  /// stale entries: a host previously cached as blocked because of an
  /// ABP-only rule is no longer blocked, or vice versa). The DNS-only hot
  /// path cache is unaffected because it depends only on _blockedDomains.
  void invalidateMergedBloom() {
    _mergedBloomFilter = null;
    // Fire-and-forget; the in-memory clear is synchronous, the prefs delete
    // happens on the microtask queue and never blocks the caller.
    _clearDomainCache();
  }

  /// Global per-domain merged-decision cache: host -> blocked_bool.
  /// Shared across all sites since the same tracker/CDN domains appear
  /// everywhere. Stores the *merged* (DNS ∪ ABP) decision because that's
  /// what the iOS JS interceptor needs to skip Dart roundtrips. The native
  /// Dart [isBlocked] hot path uses [_dnsBlockCache] instead, since reading
  /// merged decisions there would conflate ABP-only blocks with DNS blocks
  /// and break per-site `dnsBlockEnabled` gating.
  final Map<String, bool> _domainCache = {};

  /// DNS-only host-decision cache for the [isBlocked] hot path. In-memory
  /// only — no disk persistence — since the cost of a cold cache after
  /// startup is modest (a single cheap walk per first-seen host) and
  /// avoiding the persist debounce keeps [isBlocked] purely synchronous.
  /// Cleared whenever [_blockedDomains] changes.
  ///
  /// Backed by a ring buffer rather than a plain `Map` for the FIFO
  /// eviction path: `_map.keys.first` allocates an iterator on every evict
  /// (~830 ns/call when the working set exceeds the cap). The ring records
  /// insertion order in a fixed `List` and evicts via `_ring[head++ % cap]`
  /// — no allocation per evict. On the realistic single-page workload this
  /// shaves ~50% off per-call cost; on cache-thrash workloads it
  /// eliminates the regression entirely.
  final HostFifoCache _dnsBlockCache = HostFifoCache(_maxDomainCacheEntries);

  static const _domainCacheKey = 'dns_domain_cache';
  static const _maxDomainCacheEntries = 5000;

  /// Get the current domain cache (for hydrating new webviews).
  Map<String, bool> getDomainCache() => _domainCache;

  /// Insert (or update) a host->bool entry into the given cache, enforcing
  /// the [_maxDomainCacheEntries] cap with FIFO eviction. Single point of
  /// truth for cache writes so the cap can never be bypassed.
  void _putCappedHostDecision(Map<String, bool> cache, String host, bool blocked) {
    final present = cache.containsKey(host);
    if (!present && cache.length >= _maxDomainCacheEntries) {
      cache.remove(cache.keys.first);
    }
    cache[host] = blocked;
  }

  /// Record a confirmed merged decision for a host. Persists asynchronously.
  /// Called from [recordRequest] — caller has already merged DNS+ABP signals.
  void recordDomainDecision(String host, bool blocked) {
    if (host.isEmpty) return;
    final prev = _domainCache[host];
    if (prev == blocked) return; // no change, no write
    _putCappedHostDecision(_domainCache, host, blocked);
    _schedulePersistDomainCache();
  }

  Timer? _persistTimer;

  void _schedulePersistDomainCache() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 2), _persistDomainCache);
  }

  Future<void> _persistDomainCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_domainCacheKey, jsonEncode(_domainCache));
    } catch (e) {
      LogService.instance.log('DnsBlock', 'Failed to persist domain cache: $e', level: LogLevel.error);
    }
  }

  Future<void> _loadDomainCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_domainCacheKey);
      if (raw == null) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _domainCache.clear();
      // Defensively cap at load time. If a previous version (or a tampered
      // prefs blob) wrote past _maxDomainCacheEntries, take only the first
      // cap-many entries and let the rest fall off — better to drop tail
      // entries than to load an unbounded cache into memory.
      for (final e in data.entries) {
        if (_domainCache.length >= _maxDomainCacheEntries) break;
        _domainCache[e.key] = e.value as bool;
      }
    } catch (e) {
      LogService.instance.log('DnsBlock', 'Failed to load domain cache: $e', level: LogLevel.error);
    }
  }

  /// Clear the merged domain cache. Called when the DNS blocklist changes,
  /// when the ABP rule set changes, or when the level is set to Off.
  /// The DNS-only [_dnsBlockCache] is cleared separately by
  /// [_notifyBlocklistChanged] since it's only invalidated by DNS changes.
  Future<void> _clearDomainCache() async {
    _domainCache.clear();
    _persistTimer?.cancel();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_domainCacheKey);
    } catch (_) {}
  }

  /// Get (and cache) a Bloom filter built from all DNS-blocked domains.
  /// Kept for callers that want the DNS-only set; the webview JS
  /// interceptor uses [getMergedBlockBloom] instead.
  BloomFilter getBloomFilter() {
    if (_bloomFilter != null) return _bloomFilter!;
    final sw = Stopwatch()..start();
    _bloomFilter = BloomFilter.build(_blockedDomains, fpRate: 0.05);
    sw.stop();
    LogService.instance.log('DnsBlock',
        'Built bloom filter: ${_bloomFilter!.sizeInBytes} bytes, k=${_bloomFilter!.k}, from ${_blockedDomains.length} domains in ${sw.elapsedMilliseconds}ms',
        level: LogLevel.info);
    return _bloomFilter!;
  }

  /// Get (and cache) a Bloom filter built from DNS ∪ ABP blocked domains.
  /// Used as the JS-side prefilter for sub-resource interception. On a hit
  /// the JS interceptor asks Dart for the authoritative decision, which
  /// tags the stat entry with the right [BlockSource].
  BloomFilter getMergedBlockBloom() {
    if (_mergedBloomFilter != null) return _mergedBloomFilter!;
    final abp = ContentBlockerService.instance.blockedDomains;
    final sw = Stopwatch()..start();
    if (_blockedDomains.isEmpty && abp.isEmpty) {
      _mergedBloomFilter = BloomFilter.build(const <String>{}, fpRate: 0.05);
    } else if (abp.isEmpty) {
      _mergedBloomFilter = getBloomFilter();
    } else {
      final merged = <String>{..._blockedDomains, ...abp};
      _mergedBloomFilter = BloomFilter.build(merged, fpRate: 0.05);
    }
    sw.stop();
    LogService.instance.log(
        'BlockBloom',
        'Built merged bloom: ${_mergedBloomFilter!.sizeInBytes} bytes, k=${_mergedBloomFilter!.k}, '
        'from ${_blockedDomains.length} DNS + ${abp.length} ABP domains in ${sw.elapsedMilliseconds}ms',
        level: LogLevel.info);
    return _mergedBloomFilter!;
  }

  /// Get DNS stats for a specific site. Creates on first access.
  DnsStats statsForSite(String siteId) {
    return _siteStats.putIfAbsent(siteId, () => DnsStats());
  }

  /// Record a request (allowed or blocked) for a site. [source] identifies
  /// which blocklist attributed the block (`dns` vs `abp`); null for
  /// allowed requests.
  ///
  /// Also updates the global per-domain cache so other webviews skip
  /// re-checking the same host. The domain cache only persists the
  /// blocked-or-not bit — the DNS vs ABP distinction is recovered on the
  /// next request because both services can answer independently.
  void recordRequest(String siteId, String url, bool wasBlocked,
      {BlockSource? source}) {
    final host = extractHost(url);
    if (host == null || host.isEmpty) return;
    recordHostRequest(siteId, host, wasBlocked, source: source);
  }

  /// Like [recordRequest] but the caller already has a host (e.g. the
  /// Android native interceptor reports `host` directly). Skips
  /// `Uri.tryParse` and the URL synthesis roundtrip. [count] folds
  /// dedup'd repeat requests into the per-site totals without growing
  /// the log by [count].
  void recordHostRequest(String siteId, String host, bool wasBlocked,
      {BlockSource? source, int count = 1}) {
    if (host.isEmpty) return;
    statsForSite(siteId).record(host, wasBlocked, source: source, count: count);
    recordDomainDecision(host, wasBlocked);
    _scheduleNotifyDnsLogListeners();
  }

  /// Clear stats for a specific site.
  void clearStatsForSite(String siteId) {
    _siteStats[siteId]?.clear();
    _scheduleNotifyDnsLogListeners();
  }

  /// Add a listener for DNS log changes (live UI updates).
  void addDnsLogListener(VoidCallback listener) {
    _dnsLogListeners.add(listener);
  }

  /// Remove a DNS log listener.
  void removeDnsLogListener(VoidCallback listener) {
    _dnsLogListeners.remove(listener);
  }

  /// Coalesce listener notifications across a microtask. The dev-tools UI
  /// only needs one rebuild per batch of recorded requests — without
  /// coalescing, a page load that records hundreds of sub-resources kicks
  /// off hundreds of `setState` calls in <1s, each rebuilding the entire
  /// log `ListView`. The microtask runs before the next frame, so the UI
  /// still updates "live". When no listener is registered the post is a
  /// no-op (early return).
  bool _notifyScheduled = false;
  void _scheduleNotifyDnsLogListeners() {
    if (_dnsLogListeners.isEmpty) return;
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(_flushDnsLogListeners);
  }

  void _flushDnsLogListeners() {
    _notifyScheduled = false;
    for (final listener in List<VoidCallback>.from(_dnsLogListeners)) {
      listener();
    }
  }

  /// Initialize the service by loading the cached domain file from disk (no network).
  /// Call in main() at app startup.
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _level = prefs.getInt(_levelKey) ?? 0;

      if (_level > 0) {
        final file = await _getCacheFile();
        if (await file.exists()) {
          final contents = await file.readAsString();
          _parseDomains(contents);
          LogService.instance.log('DnsBlock', 'Loaded ${_blockedDomains.length} domains from cache (level $_level)', level: LogLevel.info);
        }
      }
      await _loadDomainCache();
    } catch (e) {
      LogService.instance.log('DnsBlock', 'Error loading cached blocklist: $e', level: LogLevel.error);
    }
  }

  /// Download the domain list for the given level (0-5).
  /// Tries each mirror URL in order. Level 0 clears the blocklist.
  /// Returns true on success, false on failure.
  Future<bool> downloadList(int level) async {
    if (level < 0 || level > 5) return false;

    if (level == 0) {
      _blockedDomains = {};
      _level = 0;
      _bloomFilter = null;
      try {
        final file = await _getCacheFile();
        if (await file.exists()) {
          await file.delete();
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_levelKey, 0);
        await prefs.remove(_lastUpdatedKey);
      } catch (e) {
        LogService.instance.log('DnsBlock', 'Error clearing blocklist: $e', level: LogLevel.error);
      }
      await _clearDomainCache();
      _notifyBlocklistChanged();
      return true;
    }

    final filePath = _levelFiles[level];
    if (filePath == null) return false;

    // Route through the app-global outbound proxy (HTTP/HTTPS findProxy on
    // dart:io's HttpClient, or the SOCKS5 tunnel from socks5_proxy when the
    // user picks SOCKS5). Fail-closed on a malformed config rather than
    // leaking the IP via direct.
    final clientResult = outboundHttp.clientFor(GlobalOutboundProxy.current);
    if (clientResult is OutboundClientBlocked) {
      LogService.instance.log(
        'DnsBlock',
        'Skipped download: ${clientResult.reason}',
        level: LogLevel.warning,
      );
      return false;
    }
    final client = (clientResult as OutboundClientReady).client;
    try {
    for (final baseUrl in _mirrorBaseUrls) {
      try {
        final url = '$baseUrl$filePath';
        LogService.instance.log('DnsBlock', 'Trying mirror: $url');

        final response = await client.get(Uri.parse(url)).timeout(
          const Duration(seconds: 15),
        );

        if (response.statusCode != 200) {
          LogService.instance.log('DnsBlock', 'Mirror failed: HTTP ${response.statusCode}', level: LogLevel.error);
          continue;
        }

        // Save to disk
        final file = await _getCacheFile();
        await file.writeAsString(response.body);

        // Parse domains
        _parseDomains(response.body);
        _level = level;

        // Save level and timestamp
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_levelKey, level);
        await prefs.setString(_lastUpdatedKey, DateTime.now().toIso8601String());

        // Blocklist changed - invalidate per-site caches
        await _clearDomainCache();

        LogService.instance.log('DnsBlock', 'Downloaded ${_blockedDomains.length} domains (level $level)', level: LogLevel.info);

        return true;
      } catch (e) {
        LogService.instance.log('DnsBlock', 'Mirror error: $e', level: LogLevel.error);
        continue;
      }
    }

    LogService.instance.log('DnsBlock', 'All mirrors failed for level $level', level: LogLevel.error);
    return false;
    } finally {
      client.close();
    }
  }

  /// Check if a URL should be blocked by the DNS blocklist. Synchronous
  /// hot path — called per navigation and (on iOS) per JS-interceptor
  /// roundtrip. Backed by [_dnsBlockCache] so a domain repeated dozens of
  /// times within a single page (the common case) only walks once.
  ///
  /// Host extraction uses [extractHost] rather than `Uri.tryParse`: full
  /// RFC 3986 validation is unnecessary, we only need scheme://host[:port],
  /// and [extractHost] handles userinfo, IPv6 brackets, and case-folding
  /// without allocating intermediate `Uri` objects. The scenarios
  /// `Uri.tryParse` rejects (relative URLs, opaque schemes like `data:` /
  /// `about:`) are also rejected here, with the same observable behavior:
  /// return false.
  bool isBlocked(String url) {
    if (_blockedDomains.isEmpty) return false;

    final host = extractHost(url);
    if (host == null || host.isEmpty) return false;
    return isHostBlocked(host);
  }

  /// Like [isBlocked] but skips URL parsing — caller already has the host
  /// (e.g. native interceptor bridge passing `host` directly). Hot-path
  /// callers should prefer this over `recordRequest('https://$host/', ...)`
  /// which round-trips through `Uri.tryParse` just to recover the host.
  bool isHostBlocked(String host) {
    if (_blockedDomains.isEmpty || host.isEmpty) return false;
    final cached = _dnsBlockCache[host];
    if (cached != null) return cached;
    final result = hostInSet(host, _blockedDomains);
    _dnsBlockCache.put(host, result);
    return result;
  }

  /// Get the last time the blocklist was downloaded, or null if never.
  Future<DateTime?> getLastUpdated() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getString(_lastUpdatedKey);
    if (timestamp == null) return null;
    return DateTime.tryParse(timestamp);
  }

  /// Load domains from a raw string. Exposed for testing.
  @visibleForTesting
  void loadDomainsFromString(String data) {
    _parseDomains(data);
  }

  void _parseDomains(String data) {
    final domains = <String>{};
    for (final line in data.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      domains.add(trimmed);
    }
    _blockedDomains = domains;
    // Rebuild bloom filter eagerly so the first webview page load doesn't
    // pay the ~500ms build cost synchronously.
    _bloomFilter = null;
    if (domains.isNotEmpty) {
      getBloomFilter();
    }
    _notifyBlocklistChanged();
  }

  Future<File> _getCacheFile() async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/$_cacheFileName');
  }
}
