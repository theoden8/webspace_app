import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/bloom_filter.dart';
import 'package:webspace/services/dns_tier_engine.dart';
import 'package:webspace/services/host_lookup.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/log_service.dart';
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
///
/// Upstream retired the flat `domains/` tree. The bare-domain-per-line
/// equivalent now lives under `wildcard/` with an `-onlydomains` suffix.
/// Not the plain `wildcard/*.txt` files: those prefix every entry with
/// `*.`, which the parser would take literally.
const List<String?> _levelFiles = [
  null, // 0: Off
  'wildcard/light-onlydomains.txt', // 1: Light
  'wildcard/multi-onlydomains.txt', // 2: Normal
  'wildcard/pro-onlydomains.txt', // 3: Pro
  'wildcard/pro.plus-onlydomains.txt', // 4: Pro++
  'wildcard/ultimate-onlydomains.txt', // 5: Ultimate
];

/// Smallest plausible entry count for a real Hagezi list. The smallest one
/// ("Light") carries ~40K domains, so a body parsing to fewer than this is a
/// mirror serving an error page or a truncated transfer, not a blocklist.
const int _minPlausibleDomains = 1000;

/// Mirror base URLs tried in order on failure.
const List<String> _mirrorBaseUrls = [
  'https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/',
  'https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/',
  'https://codeberg.org/hagezi/mirror2/raw/branch/main/dns-blocklists/',
];

/// Full mirror URLs tried, in order, for [level]. Empty for level 0 (Off)
/// and for out-of-range levels.
@visibleForTesting
List<String> dnsMirrorUrlsForLevel(int level) {
  if (level < 1 || level >= _levelFiles.length) return const <String>[];
  final path = _levelFiles[level];
  if (path == null) return const <String>[];
  return [for (final base in _mirrorBaseUrls) '$base$path'];
}

/// Singleton service for downloading, caching, and querying Hagezi DNS blocklists.
/// Blocks navigation to ad/malware/tracker domains at the webview level.
class DnsBlockService {
  /// Pre-tier installs kept the one downloaded list here, with no level in
  /// the name. Read once at startup and re-filed under its level.
  static const String _legacyCacheFileName = 'dns_blocklist.txt';
  static const String _levelKey = 'dns_block_level';
  static const String _lastUpdatedKey = 'dns_block_last_updated';
  static const String _downloadedLevelsKey = 'dns_block_downloaded_levels';

  static String _cacheFileName(int level) => 'dns_blocklist_$level.txt';

  static DnsBlockService? _instance;
  static DnsBlockService get instance => _instance ??= DnsBlockService._();

  DnsBlockService._();

  DnsTiers _tiers = DnsTiers.empty;
  int _level = 0;

  // Serialize blocklist mutations: downloadList and applyImportedLevel both
  // rewrite the cache files, `_tiers`, `_level`, and prefs across many
  // awaits. Overlapping calls (two downloads, or a download racing an import)
  // could otherwise leave the file, level, and in-memory set from different
  // calls — the wrong list loading under the wrong label after restart.
  Future<void> _mutationChain = Future<void>.value();

  Future<T> _serializeMutation<T>(Future<T> Function() action) {
    final result = _mutationChain.then((_) => action());
    _mutationChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Per-site DNS statistics, keyed by siteId.
  final Map<String, DnsStats> _siteStats = {};

  /// Listeners notified when a DNS request is logged (for live UI updates).
  final List<VoidCallback> _dnsLogListeners = [];

  /// Whether a blocklist is loaded and active.
  bool get hasBlocklist => !_tiers.isEmpty;

  /// The app-wide severity level (0-5). Sites that don't set their own run
  /// here; a site's own level is resolved against [downloadedLevels].
  int get level => _level;

  /// Number of domains across every downloaded level.
  int get domainCount => _tiers.domainCount;

  /// Every blocked domain, across every downloaded level.
  Iterable<String> get blockedDomains => _tiers.domains;

  /// Levels whose list has been fetched, so a site may run at them.
  Set<int> get downloadedLevels => _tiers.levels;

  /// Domains that enter the blocklist at [level] and at no lower one. The
  /// native push ships the partition rather than a flat set so the Android
  /// interceptor can apply each site's own level.
  Set<String> tierDomains(int level) => _tiers.tierDomains(level);

  /// The whole partition, level → its tier. What the native push ships.
  Map<int, Set<String>> get tiersByLevel => {
        for (final level in _tiers.levels) level: _tiers.tierDomains(level),
      };

  /// Level [siteLevel] actually runs at once missing tier data is accounted
  /// for. See [resolveDnsLevel].
  int effectiveLevelFor(int? siteLevel) => resolveDnsLevel(
        siteLevel: siteLevel,
        globalLevel: _level,
        downloadedLevels: _tiers.levels,
      );

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
    // cache is also stale because the tiers themselves changed.
    _mergedBloomFilter = null;
    _dnsBlockCache.clear();
    for (final listener in List<VoidCallback>.from(_blocklistChangedListeners)) {
      listener();
    }
  }

  /// Hosts named by ABP `||host^` network-block rules, pushed by
  /// ContentBlockerService whenever its rule set changes. Unioned into
  /// the merged Bloom so the interceptor prefilter trips for ABP-only
  /// hosts (a bloom miss is a hard allow, so without this an ABP network
  /// rule for a host absent from the DNS list never fires on iOS/macOS).
  Set<String> _abpNetworkHosts = <String>{};

  /// Called by ContentBlockerService when its rule set changes. Replaces
  /// the ABP host set, invalidates the merged Bloom, and clears the
  /// merged host-decision cache (which may have stale entries: a host
  /// previously cached as blocked because of an ABP-only rule is no
  /// longer blocked, or vice versa). The DNS-only hot path cache is
  /// unaffected because it depends only on the tiers.
  void setAbpNetworkHosts(Set<String> hosts) {
    _abpNetworkHosts = hosts;
    invalidateMergedBloom();
  }

  /// Invalidate the merged Bloom + merged host-decision cache without
  /// changing the ABP host set (e.g. when only the DNS half changed).
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

  /// DNS-only host-decision cache for the [isBlocked] hot path. Holds the
  /// host's *tier*, not a blocked/allowed bit: every site then masks the one
  /// cached answer with its own level, so per-site levels cost no extra
  /// entries and no extra walks. In-memory only — no disk persistence —
  /// since the cost of a cold cache after startup is modest (a single cheap
  /// walk per first-seen host) and avoiding the persist debounce keeps
  /// [isBlocked] purely synchronous. Cleared whenever the tiers change.
  ///
  /// Backed by a ring buffer rather than a plain `Map` for the FIFO
  /// eviction path: `_map.keys.first` allocates an iterator on every evict
  /// (~830 ns/call when the working set exceeds the cap). The ring records
  /// insertion order in a fixed `List` and evicts via `_ring[head++ % cap]`
  /// — no allocation per evict. On the realistic single-page workload this
  /// shaves ~50% off per-call cost; on cache-thrash workloads it
  /// eliminates the regression entirely.
  final HostFifoCache<int> _dnsBlockCache =
      HostFifoCache<int>(_maxDomainCacheEntries);

  static const _domainCacheKey = 'dns_domain_cache';
  static const _maxDomainCacheEntries = 5000;

  /// Read-only view of the merged domain-decision cache, for tests and
  /// diagnostics. Never hand this to page JS: it is app-wide, so it names
  /// every host every site has requested.
  @visibleForTesting
  Map<String, bool> get debugDomainCache => Map.unmodifiable(_domainCache);

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
    _bloomFilter = BloomFilter.build(_tiers.domains.toList(growable: false),
        fpRate: 0.05);
    sw.stop();
    LogService.instance.log('DnsBlock',
        'Built bloom filter: ${_bloomFilter!.sizeInBytes} bytes, k=${_bloomFilter!.k}, from ${_tiers.domainCount} domains in ${sw.elapsedMilliseconds}ms',
        level: LogLevel.info);
    return _bloomFilter!;
  }

  /// Get (and cache) a Bloom filter built from the DNS blocked domains.
  /// Used as the JS-side prefilter for sub-resource interception. On a
  /// bloom hit the JS interceptor asks Dart for the authoritative
  /// decision (which also asks the adblock engine for ABP rules), so
  /// ABP-only hosts that don't appear in DNS will miss the bloom filter
  /// and round-trip through Dart per-request — acceptable since the
  /// engine itself is microseconds-fast.
  BloomFilter getMergedBlockBloom() {
    if (_mergedBloomFilter != null) return _mergedBloomFilter!;
    final sw = Stopwatch()..start();
    final union = <String>{..._tiers.domains, ..._abpNetworkHosts};
    _mergedBloomFilter = BloomFilter.build(union, fpRate: 0.05);
    sw.stop();
    LogService.instance.log(
        'BlockBloom',
        'Built merged bloom: ${_mergedBloomFilter!.sizeInBytes} bytes, k=${_mergedBloomFilter!.k}, '
        'from ${_tiers.domainCount} DNS + ${_abpNetworkHosts.length} ABP '
        'host(s) (${union.length} unique) in ${sw.elapsedMilliseconds}ms',
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
    // Single funnel for the persisted app-wide report (STATS-002): every
    // DNS/ABP block on every platform passes through here, so the aggregate
    // cannot drift from the per-site counters.
    if (wasBlocked && source != null) {
      BlockStatsService.instance.record(
        siteId,
        source == BlockSource.dns
            ? BlockCategory.dnsBlocklist
            : BlockCategory.filterList,
        count: count,
        label: host,
      );
    }
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

  /// Initialize the service by loading the cached domain files from disk (no
  /// network). Call in main() at app startup.
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _level = prefs.getInt(_levelKey) ?? 0;

      final levels = await _readDownloadedLevels(prefs);
      if (levels.isNotEmpty) {
        await _rebuildTiers(levels);
        LogService.instance.log(
            'DnsBlock',
            'Loaded ${_tiers.domainCount} domains from cache '
            '(level $_level, tiers ${_tiers.levels.toList()..sort()})',
            level: LogLevel.info);
      }
      await _loadDomainCache();
    } catch (e) {
      LogService.instance.log('DnsBlock', 'Error loading cached blocklist: $e', level: LogLevel.error);
    }
  }

  /// Levels the app has a cached list for. Falls back to migrating the
  /// pre-tier single-file cache the first time this runs after an upgrade.
  Future<Set<int>> _readDownloadedLevels(SharedPreferences prefs) async {
    final stored = prefs.getStringList(_downloadedLevelsKey);
    if (stored != null) {
      final levels = <int>{};
      for (final raw in stored) {
        final level = int.tryParse(raw);
        if (level != null && level >= 1 && level <= kDnsMaxLevel) {
          levels.add(level);
        }
      }
      return levels;
    }
    if (_level < 1 || _level > kDnsMaxLevel) return <int>{};
    final legacy = await _store.readText(_legacyCacheFileName);
    if (legacy == null) return <int>{};
    await _store.writeText(_cacheFileName(_level), legacy);
    await _store.delete(_legacyCacheFileName);
    await _persistDownloadedLevels(prefs, <int>{_level});
    return <int>{_level};
  }

  Future<void> _persistDownloadedLevels(
      SharedPreferences prefs, Set<int> levels) async {
    if (levels.isEmpty) {
      await prefs.remove(_downloadedLevelsKey);
      return;
    }
    final sorted = levels.toList()..sort();
    await prefs.setStringList(
        _downloadedLevelsKey, [for (final l in sorted) '$l']);
  }

  /// Re-partition the cached level files into tiers. Reads ascending and
  /// streams each file into the builder so the raw list of a level is never
  /// live alongside the tier it is about to be folded into.
  Future<void> _rebuildTiers(Set<int> levels) async {
    final sorted = levels.toList()..sort();
    final builder = DnsTiersBuilder();
    final loaded = <int>{};
    for (final level in sorted) {
      final text = await _store.readText(_cacheFileName(level));
      if (text == null) continue;
      builder.startLevel(level);
      for (final line in const LineSplitter().convert(text)) {
        final domain = line.trim();
        if (domain.isEmpty || domain.startsWith('#')) continue;
        builder.add(domain);
      }
      loaded.add(level);
    }
    if (loaded.length != levels.length) {
      final prefs = await SharedPreferences.getInstance();
      await _persistDownloadedLevels(prefs, loaded);
    }
    _applyTiers(builder.build());
  }

  void _applyTiers(DnsTiers tiers) {
    _tiers = tiers;
    // Rebuild the bloom filter eagerly so the first webview page load doesn't
    // pay the ~500ms build cost synchronously.
    _bloomFilter = null;
    if (!tiers.isEmpty) {
      getBloomFilter();
    }
    _notifyBlocklistChanged();
  }

  /// Download the domain list for the given level (0-5) and make it the
  /// app-wide level. Tries each mirror URL in order. Level 0 clears every
  /// downloaded level. Returns true on success, false on failure.
  Future<bool> downloadList(int level) =>
      _serializeMutation(() => _downloadListInner(level));

  Future<bool> _downloadListInner(int level) async {
    if (level < 0 || level > kDnsMaxLevel) return false;

    if (level == 0) {
      try {
        for (final downloaded in _tiers.levels) {
          await _store.delete(_cacheFileName(downloaded));
        }
        await _store.delete(_legacyCacheFileName);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_levelKey, 0);
        await prefs.remove(_lastUpdatedKey);
        await _persistDownloadedLevels(prefs, const <int>{});
      } catch (e) {
        LogService.instance.log('DnsBlock', 'Error clearing blocklist: $e', level: LogLevel.error);
      }
      _level = 0;
      await _clearDomainCache();
      _applyTiers(DnsTiers.empty);
      return true;
    }

    if (!await _fetchLevelFile(level)) return false;
    _level = level;
    final levels = <int>{..._tiers.levels, level};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_levelKey, level);
    await prefs.setString(_lastUpdatedKey, DateTime.now().toIso8601String());
    await _persistDownloadedLevels(prefs, levels);
    await _clearDomainCache();
    await _rebuildTiers(levels);
    LogService.instance.log('DnsBlock',
        'Downloaded ${_tiers.domainCount} domains (level $level)',
        level: LogLevel.info);
    return true;
  }

  /// Fetch one extra severity level so sites may run at it, without touching
  /// the app-wide level. Idempotent: a level already downloaded succeeds
  /// without a request.
  Future<bool> downloadLevel(int level) =>
      _serializeMutation(() => _downloadLevelInner(level));

  Future<bool> _downloadLevelInner(int level) async {
    if (level < 1 || level > kDnsMaxLevel) return false;
    if (_tiers.levels.contains(level)) return true;
    if (!await _fetchLevelFile(level)) return false;
    final levels = <int>{..._tiers.levels, level};
    final prefs = await SharedPreferences.getInstance();
    await _persistDownloadedLevels(prefs, levels);
    await _clearDomainCache();
    await _rebuildTiers(levels);
    LogService.instance.log('DnsBlock',
        'Added tier for level $level (${_tiers.domainCount} domains total)',
        level: LogLevel.info);
    return true;
  }

  /// Drop cached levels nothing asks for any more. [keep] comes from
  /// [requiredDnsLevels]; the app-wide level is always in it.
  Future<void> pruneLevels(Set<int> keep) =>
      _serializeMutation(() => _pruneLevelsInner(keep));

  Future<void> _pruneLevelsInner(Set<int> keep) async {
    final drop = _tiers.levels.where((l) => !keep.contains(l)).toSet();
    if (drop.isEmpty) return;
    for (final level in drop) {
      try {
        await _store.delete(_cacheFileName(level));
      } catch (_) {}
    }
    final remaining = _tiers.levels.difference(drop);
    final prefs = await SharedPreferences.getInstance();
    await _persistDownloadedLevels(prefs, remaining);
    await _clearDomainCache();
    await _rebuildTiers(remaining);
    LogService.instance.log('DnsBlock',
        'Dropped unused blocklist tiers ${drop.toList()..sort()}',
        level: LogLevel.info);
  }

  /// Download [level]'s list and write it to its cache file. Tries each
  /// mirror in order; a mirror that answers 200 with something that isn't a
  /// domain list never overwrites a working cache.
  Future<bool> _fetchLevelFile(int level) async {
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

          final domains = _extractDomains(response.body);
          if (!looksLikeDomainList(domains)) {
            LogService.instance.log(
                'DnsBlock',
                'Mirror returned ${response.body.length} bytes yielding '
                '${domains.length} usable entries, not a domain list. Skipping.',
                level: LogLevel.error);
            continue;
          }

          await _store.writeText(_cacheFileName(level), response.body);
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
  bool isBlocked(String url) => isBlockedAtLevel(url, _level);

  /// Like [isBlocked] but skips URL parsing — caller already has the host
  /// (e.g. native interceptor bridge passing `host` directly). Hot-path
  /// callers should prefer this over `recordRequest('https://$host/', ...)`
  /// which round-trips through `Uri.tryParse` just to recover the host.
  bool isHostBlocked(String host) => isHostBlockedAtLevel(host, _level);

  /// [isBlocked] at a specific severity level — what a site with its own
  /// level runs. The tier lookup is shared, so this costs the same as the
  /// app-wide check.
  bool isBlockedAtLevel(String url, int level) {
    if (level <= kDnsLevelOff || _tiers.isEmpty) return false;
    final host = extractHost(url);
    if (host == null || host.isEmpty) return false;
    return isHostBlockedAtLevel(host, level);
  }

  /// [isHostBlocked] at a specific severity level.
  bool isHostBlockedAtLevel(String host, int level) {
    if (level <= kDnsLevelOff || _tiers.isEmpty || host.isEmpty) return false;
    final tier = hostTier(host);
    return tier != 0 && tier <= level;
  }

  /// Lowest level whose list names [host] (or a parent), 0 when none does.
  /// Cached, so repeat hosts within a page walk the tiers once however many
  /// sites with however many levels ask.
  int hostTier(String host) {
    if (host.isEmpty) return 0;
    final cached = _dnsBlockCache[host];
    if (cached != null) return cached;
    final tier = _tiers.tierOf(host);
    _dnsBlockCache.put(host, tier);
    return tier;
  }

  /// Apply a DNS severity level restored from a settings backup.
  ///
  /// A backup carries only the chosen level (user intent), never the
  /// downloaded domain blob. This persists the level so the App Settings
  /// slider reflects the user's choice; the user re-downloads from there to
  /// repopulate the tiers. Every cached level is dropped along the way: the
  /// import also replaces the per-site levels, so which tiers are wanted is
  /// only known once the user re-downloads. Out-of-range levels are ignored.
  Future<void> applyImportedLevel(int level) =>
      _serializeMutation(() => _applyImportedLevelInner(level));

  Future<void> _applyImportedLevelInner(int level) async {
    if (level < 0 || level > kDnsMaxLevel) return;
    if (level == _level && _tiers.isEmpty) return;
    try {
      for (final downloaded in _tiers.levels) {
        await _store.delete(_cacheFileName(downloaded));
      }
      await _store.delete(_legacyCacheFileName);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_levelKey, level);
      await prefs.remove(_lastUpdatedKey);
      await _persistDownloadedLevels(prefs, const <int>{});
    } catch (e) {
      LogService.instance.log('DnsBlock',
          'Error applying imported level: $e', level: LogLevel.error);
    }
    _level = level;
    await _clearDomainCache();
    _applyTiers(DnsTiers.empty);
  }

  /// Get the last time the blocklist was downloaded, or null if never.
  Future<DateTime?> getLastUpdated() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getString(_lastUpdatedKey);
    if (timestamp == null) return null;
    return DateTime.tryParse(timestamp);
  }

  /// Load one level's domains from a raw string, as if it had just been
  /// downloaded at [level] and made the app-wide level. Exposed for testing.
  @visibleForTesting
  void loadDomainsFromString(String data, {int level = 1}) {
    final domains = _extractDomains(data);
    _level = level;
    if (domains.isEmpty) {
      _applyTiers(DnsTiers.empty);
      return;
    }
    final builder = DnsTiersBuilder()..startLevel(level);
    for (final domain in domains) {
      builder.add(domain);
    }
    _applyTiers(builder.build());
  }

  /// Load several levels at once, as if each had been downloaded. Keys are
  /// levels, values raw list bodies. Exposed for testing.
  @visibleForTesting
  void loadTiersFromStrings(Map<int, String> byLevel, {int? globalLevel}) {
    final levels = byLevel.keys.toList()..sort();
    final builder = DnsTiersBuilder();
    for (final level in levels) {
      builder.startLevel(level);
      for (final domain in _extractDomains(byLevel[level]!)) {
        builder.add(domain);
      }
    }
    _level = globalLevel ?? (levels.isEmpty ? 0 : levels.last);
    _applyTiers(builder.build());
  }

  static Set<String> _extractDomains(String data) {
    final domains = <String>{};
    for (final line in data.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      domains.add(trimmed);
    }
    return domains;
  }

  /// Whether a freshly downloaded body is a domain list at all. Guards the
  /// download path only: a mirror that answers 200 with an HTML error page
  /// or a truncated body must not overwrite a working cached blocklist.
  /// Samples the head rather than the whole set — a real list is uniform,
  /// and a bad one goes wrong from the first entry.
  @visibleForTesting
  static bool looksLikeDomainList(Set<String> domains) {
    if (domains.length < _minPlausibleDomains) return false;
    var checked = 0;
    for (final d in domains) {
      if (!d.contains('.') || d.contains(' ') || d.contains('<')) return false;
      if (++checked >= 50) break;
    }
    return true;
  }

  FileStore? _storeOverride;

  /// Cache directory for the downloaded blocklist. Swappable for tests and
  /// the design gallery.
  @visibleForTesting
  set store(FileStore store) => _storeOverride = store;

  FileStore get _store => _storeOverride ??= defaultFileStore('dns_blocklist');
}
