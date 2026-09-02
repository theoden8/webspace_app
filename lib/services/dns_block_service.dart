import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/bloom_filter.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
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
  /// The whole blocklist, as `#<mask-hex>` sections of domains. Its domain
  /// content is exactly the union of the downloaded levels — no domain is
  /// stored twice however many levels name it — so disk stays the size of
  /// the largest list rather than the sum of them.
  static const String _levelsFileName = 'dns_blocklist_levels.txt';

  /// Pre-mask installs kept one flat list here, with no level in the name.
  /// Read once at startup and folded in under the level it was fetched at.
  static const String _legacyCacheFileName = 'dns_blocklist.txt';
  static const String _levelKey = 'dns_block_level';
  static const String _lastUpdatedKey = 'dns_block_last_updated';
  static const String _downloadedLevelsKey = 'dns_block_downloaded_levels';

  static DnsBlockService? _instance;
  static DnsBlockService get instance => _instance ??= DnsBlockService._();

  DnsBlockService._();

  DnsLevelSets _levelSets = DnsLevelSets.empty;
  int _level = 0;

  // Serialize blocklist mutations: downloadList and applyImportedLevel both
  // rewrite the cache file, `_levelSets`, `_level`, and prefs across many
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
  bool get hasBlocklist => !_levelSets.isEmpty;

  /// The app-wide severity level (0-5). Sites that don't set their own run
  /// here; a site's own level is resolved against [downloadedLevels].
  int get level => _level;

  /// Number of domains across every downloaded level.
  int get domainCount => _levelSets.domainCount;

  /// Every blocked domain, across every downloaded level.
  Iterable<String> get blockedDomains => _levelSets.domains;

  /// Levels whose list has been fetched, so a site may run at them.
  Set<int> get downloadedLevels => _levelSets.levels;

  /// Domains [level]'s own list names.
  Iterable<String> domainsAtLevel(int level) =>
      _levelSets.domainsAtLevel(level);

  /// The disjoint groups, keyed by level-membership mask. What the native
  /// push ships, so the Android interceptor can answer at each site's own
  /// level off one copy of the data.
  Map<int, Set<String>> get levelGroups => _levelSets.groups;

  /// How many groups the downloaded levels resolve to. One while a single
  /// level is downloaded, which is what an install that never sets a
  /// per-site level stays at.
  int get levelGroupCount => _levelSets.groupCount;

  /// Level [siteLevel] actually runs at once missing tier data is accounted
  /// for. See [resolveDnsLevel].
  int effectiveLevelFor(int? siteLevel) => resolveDnsLevel(
        siteLevel: siteLevel,
        globalLevel: _level,
        downloadedLevels: _levelSets.levels,
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
    // cache is also stale because the groups themselves changed.
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
  /// unaffected because it depends only on the level groups.
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
  /// host's *level mask*, not a blocked/allowed bit: every site then bit-tests
  /// the one cached answer with its own level, so per-site levels cost no
  /// extra entries and no extra walks. In-memory only — no disk persistence —
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
    _bloomFilter = BloomFilter.build(_levelSets.domains, fpRate: 0.05);
    sw.stop();
    LogService.instance.log('DnsBlock',
        'Built bloom filter: ${_bloomFilter!.sizeInBytes} bytes, k=${_bloomFilter!.k}, from ${_levelSets.domainCount} domains in ${sw.elapsedMilliseconds}ms',
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
    // Only materialise a union when there is something to union in: the DNS
    // half alone is up to ~650K entries, and copying it every rebuild is the
    // kind of transient allocation that shows up as a startup stall.
    final Iterable<String> union;
    final int unionCount;
    if (_abpNetworkHosts.isEmpty) {
      union = _levelSets.domains;
      unionCount = _levelSets.domainCount;
    } else {
      final merged = <String>{..._levelSets.domains, ..._abpNetworkHosts};
      union = merged;
      unionCount = merged.length;
    }
    _mergedBloomFilter = BloomFilter.build(union, fpRate: 0.05);
    sw.stop();
    LogService.instance.log(
        'BlockBloom',
        'Built merged bloom: ${_mergedBloomFilter!.sizeInBytes} bytes, k=${_mergedBloomFilter!.k}, '
        'from ${_levelSets.domainCount} DNS + ${_abpNetworkHosts.length} ABP '
        'host(s) ($unionCount unique) in ${sw.elapsedMilliseconds}ms',
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

  /// Initialize the service by loading the cached blocklist from disk (no
  /// network). Call in main() at app startup.
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _level = prefs.getInt(_levelKey) ?? 0;

      await _loadFromDisk(prefs);
      if (!_levelSets.isEmpty) {
        LogService.instance.log(
            'DnsBlock',
            'Loaded ${_levelSets.domainCount} domains from cache '
            '(level $_level, levels ${_levelSets.levels.toList()..sort()}, '
            '${_levelSets.groupCount} group(s))',
            level: LogLevel.info);
      }
      await _loadDomainCache();
    } catch (e) {
      LogService.instance.log('DnsBlock', 'Error loading cached blocklist: $e', level: LogLevel.error);
    }
  }

  /// Read the stored partition, or migrate the pre-mask single-file cache the
  /// first time this runs after an upgrade.
  Future<void> _loadFromDisk(SharedPreferences prefs) async {
    final stored = await _store.readText(_levelsFileName);
    if (stored != null) {
      _applyLevelSets(_parseLevelSets(stored));
      return;
    }
    if (_level < 1 || _level > kDnsMaxLevel) return;
    final legacy = await _store.readText(_legacyCacheFileName);
    if (legacy == null) return;
    final builder = DnsLevelSetsBuilder()..startLevel(_level);
    for (final domain in _extractDomains(legacy)) {
      builder.add(domain);
    }
    final migrated = builder.build();
    await _store.writeText(_levelsFileName, _serializeLevelSets(migrated));
    await _store.delete(_legacyCacheFileName);
    await _persistDownloadedLevels(prefs, migrated.levels);
    _applyLevelSets(migrated);
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

  /// `#<mask-hex>` section markers, then that group's domains. Domains never
  /// start with `#` — the parser on both sides drops comment lines — so the
  /// marker is unambiguous, and a domain appears exactly once however many
  /// levels name it.
  static String _serializeLevelSets(DnsLevelSets sets) {
    final buf = StringBuffer();
    final masks = sets.groups.keys.toList()..sort();
    for (final mask in masks) {
      buf.writeln('#${mask.toRadixString(16)}');
      for (final domain in sets.groups[mask]!) {
        buf.writeln(domain);
      }
    }
    return buf.toString();
  }

  static DnsLevelSets _parseLevelSets(String text) {
    final builder = DnsLevelSetsBuilder();
    final byMask = <int, List<String>>{};
    var mask = 0;
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#')) {
        mask = int.tryParse(trimmed.substring(1), radix: 16) ?? 0;
        continue;
      }
      if (mask == 0) continue;
      (byMask[mask] ??= <String>[]).add(trimmed);
    }
    // Replay the partition level by level: the builder owns the mask
    // arithmetic, so there is one place that decides what a group means.
    for (var level = 1; level <= kDnsMaxLevel; level++) {
      final bit = dnsLevelBit(level);
      if (!byMask.keys.any((m) => m & bit != 0)) continue;
      builder.startLevel(level);
      for (final entry in byMask.entries) {
        if (entry.key & bit == 0) continue;
        for (final domain in entry.value) {
          builder.add(domain);
        }
      }
    }
    return builder.build();
  }

  void _applyLevelSets(DnsLevelSets sets) {
    _levelSets = sets;
    // Rebuild the bloom filter eagerly so the first webview page load doesn't
    // pay the ~500ms build cost synchronously.
    _bloomFilter = null;
    if (!sets.isEmpty) {
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
        await _store.delete(_levelsFileName);
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
      _applyLevelSets(DnsLevelSets.empty);
      return true;
    }

    if (!await _foldLevel(level)) return false;
    _level = level;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_levelKey, level);
    await prefs.setString(_lastUpdatedKey, DateTime.now().toIso8601String());
    await _persistDownloadedLevels(prefs, _levelSets.levels);
    await _clearDomainCache();
    LogService.instance.log('DnsBlock',
        'Downloaded level $level (${_levelSets.domainCount} domains across '
        '${_levelSets.groupCount} group(s))',
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
    if (_levelSets.levels.contains(level)) return true;
    if (!await _foldLevel(level)) return false;
    final prefs = await SharedPreferences.getInstance();
    await _persistDownloadedLevels(prefs, _levelSets.levels);
    await _clearDomainCache();
    LogService.instance.log('DnsBlock',
        'Added level $level (${_levelSets.domainCount} domains across '
        '${_levelSets.groupCount} group(s))',
        level: LogLevel.info);
    return true;
  }

  /// Drop cached levels nothing asks for any more. [keep] comes from
  /// [requiredDnsLevels]; the app-wide level is always in it. A domain no
  /// remaining level names falls out with its last bit.
  Future<void> pruneLevels(Set<int> keep) =>
      _serializeMutation(() => _pruneLevelsInner(keep));

  Future<void> _pruneLevelsInner(Set<int> keep) async {
    final drop = _levelSets.levels.where((l) => !keep.contains(l)).toSet();
    if (drop.isEmpty) return;
    final builder = DnsLevelSetsBuilder.from(_levelSets);
    for (final level in drop) {
      builder.dropLevel(level);
    }
    final pruned = builder.build();
    await _writeLevelSets(pruned);
    final prefs = await SharedPreferences.getInstance();
    await _persistDownloadedLevels(prefs, pruned.levels);
    await _clearDomainCache();
    _applyLevelSets(pruned);
    LogService.instance.log('DnsBlock',
        'Dropped unused blocklist levels ${drop.toList()..sort()} '
        '(${pruned.domainCount} domains left)',
        level: LogLevel.info);
  }

  /// Download [level]'s list and fold it into the partition, setting its bit
  /// on the domains it names and clearing it on the ones it does not. The
  /// raw body is parsed into a set that is dropped as soon as the fold is
  /// done; only the partition survives.
  Future<bool> _foldLevel(int level) async {
    final body = await _fetchLevelBody(level);
    if (body == null) return false;
    final builder = DnsLevelSetsBuilder.from(_levelSets)..startLevel(level);
    for (final domain in _extractDomains(body)) {
      builder.add(domain);
    }
    final folded = builder.build();
    await _writeLevelSets(folded);
    _applyLevelSets(folded);
    return true;
  }

  Future<void> _writeLevelSets(DnsLevelSets sets) async {
    if (sets.isEmpty) {
      await _store.delete(_levelsFileName);
      return;
    }
    await _store.writeText(_levelsFileName, _serializeLevelSets(sets));
  }

  /// Fetch [level]'s list body. Tries each mirror in order; a mirror that
  /// answers 200 with something that isn't a domain list is skipped rather
  /// than folded into a working partition.
  Future<String?> _fetchLevelBody(int level) async {
    final filePath = _levelFiles[level];
    if (filePath == null) return null;

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
      return null;
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

          return response.body;
        } catch (e) {
          LogService.instance.log('DnsBlock', 'Mirror error: $e', level: LogLevel.error);
          continue;
        }
      }

      LogService.instance.log('DnsBlock', 'All mirrors failed for level $level', level: LogLevel.error);
      return null;
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
    if (level <= kDnsLevelOff || _levelSets.isEmpty) return false;
    final host = extractHost(url);
    if (host == null || host.isEmpty) return false;
    return isHostBlockedAtLevel(host, level);
  }

  /// [isHostBlocked] at a specific severity level.
  bool isHostBlockedAtLevel(String host, int level) {
    if (level <= kDnsLevelOff || level > kDnsMaxLevel) return false;
    if (_levelSets.isEmpty || host.isEmpty) return false;
    return hostLevelMask(host) & dnsLevelBit(level) != 0;
  }

  /// Which levels name [host] (or a parent domain), as a mask; 0 when none
  /// does. Cached, so repeat hosts within a page walk the groups once
  /// however many sites at however many levels ask — the one cached number
  /// answers all of them with a bit test.
  int hostLevelMask(String host) {
    if (host.isEmpty) return 0;
    final cached = _dnsBlockCache[host];
    if (cached != null) return cached;
    final mask = _levelSets.maskOf(host);
    _dnsBlockCache.put(host, mask);
    return mask;
  }

  /// Apply a DNS severity level restored from a settings backup.
  ///
  /// A backup carries only the chosen level (user intent), never the
  /// downloaded domain blob. This persists the level so the App Settings
  /// slider reflects the user's choice; the user re-downloads from there to
  /// repopulate the tiers. Every cached level is dropped along the way: the
  /// files are not tagged with the level they were fetched at beyond their
  /// name, and a per-site level the import brought in has no tier here yet.
  /// Out-of-range levels, and an import that names the level already in
  /// force, are no-ops. Tiers no site wants are reclaimed by the startup
  /// sweep rather than here.
  Future<void> applyImportedLevel(int level) =>
      _serializeMutation(() => _applyImportedLevelInner(level));

  Future<void> _applyImportedLevelInner(int level) async {
    if (level < 0 || level > kDnsMaxLevel) return;
    if (level == _level) return;
    try {
      await _store.delete(_levelsFileName);
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
    _applyLevelSets(DnsLevelSets.empty);
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
      _applyLevelSets(DnsLevelSets.empty);
      return;
    }
    final builder = DnsLevelSetsBuilder()..startLevel(level);
    for (final domain in domains) {
      builder.add(domain);
    }
    _applyLevelSets(builder.build());
  }

  /// Load several levels at once, as if each had been downloaded. Keys are
  /// levels, values raw list bodies. Exposed for testing.
  @visibleForTesting
  void loadLevelsFromStrings(Map<int, String> byLevel, {int? globalLevel}) {
    final levels = byLevel.keys.toList()..sort();
    final builder = DnsLevelSetsBuilder();
    for (final level in levels) {
      builder.startLevel(level);
      for (final domain in _extractDomains(byLevel[level]!)) {
        builder.add(domain);
      }
    }
    _level = globalLevel ?? (levels.isEmpty ? 0 : levels.last);
    _applyLevelSets(builder.build());
  }

  /// The stored form of the current partition, for tests that need to prove
  /// a round-trip through disk preserves every level's membership.
  @visibleForTesting
  String serializeLevelSetsForTest() => _serializeLevelSets(_levelSets);

  @visibleForTesting
  void loadLevelSetsFromSerialized(String text, {int? globalLevel}) {
    final parsed = _parseLevelSets(text);
    _level = globalLevel ?? _level;
    _applyLevelSets(parsed);
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
