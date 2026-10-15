import 'dart:async';
import 'package:webspace/settings/site_ids.dart';
import 'dart:convert';
import 'dart:isolate' show IsolateSpawnException;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:webspace/platform/host_platform.dart' show IOException;
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/bloom_filter.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/host_lookup.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/blocker_data.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/utils/concurrency.dart';
import 'package:webspace/services/block_decision.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/view_blockers.dart';

export 'package:webspace/services/block_decision.dart' show BlockSource;

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
  void record(String domain,
      {required bool wasBlocked, BlockSource? source, int count = 1}) {
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
  final SerialQueue _mutations = SerialQueue('dnsMutations');

  /// Per-site DNS statistics, keyed by siteId.
  final Map<String, DnsStats> _siteStats = {};

  /// Listeners notified when a DNS request is logged (for live UI updates).
  final List<VoidCallback> _dnsLogListeners = [];

  bool get hasBlocklist => !_levelSets.isEmpty;

  /// The app-wide severity level (0-5). Sites that don't set their own run
  /// here; a site's own level is resolved against [downloadedLevels].
  int get level => _level;

  /// Number of domains across every downloaded level.
  int get domainCount => _levelSets.domainCount;

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

  /// Cached Bloom filter built from DNS ∪ ABP blocked domains. Used by the
  /// iOS/macOS JS sub-resource interceptor as a "maybe blocked" prefilter;
  /// the authoritative DNS-vs-ABP decision happens in Dart on hit.
  BloomFilter? _mergedBloomFilter;

  /// Listeners invoked whenever the DNS blocklist changes (download, level
  /// change, clear). [DnsLoaded.mirrorInto] re-pushes to the native
  /// interceptor from here so individual call sites don't each have to
  /// remember to sync.
  final List<VoidCallback> _blocklistChangedListeners = [];

  void addBlocklistChangedListener(VoidCallback listener) {
    _blocklistChangedListeners.add(listener);
  }

  void removeBlocklistChangedListener(VoidCallback listener) {
    _blocklistChangedListeners.remove(listener);
  }

  /// Every live site webview's native interceptor, told its site's level
  /// whenever the partition or the app-wide level moves (DNS-022).
  late ViewBlockers views = ViewBlockers(
    send: _attachNative,
    resolve: effectiveLevelFor,
  );

  static void _attachNative(ViewAttach a) =>
      unawaited(WebInterceptNative.attachToView(
        viewId: a.view,
        siteId: a.site,
        dnsLevel: a.dnsLevel,
        localCdn: a.localCdn,
        contentBlock: a.contentBlock,
      ));

  void _notifyBlocklistChanged() {
    // Invalidate the merged Bloom since the DNS half changed. The
    // ContentBlockerService change path invalidates it too. The DNS hot-path
    // cache is also stale because the groups themselves changed.
    _mergedBloomFilter = null;
    _dnsBlockCache.clear();
    views.changed();
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
  /// the ABP host set and invalidates the merged Bloom. The DNS-only hot
  /// path cache is unaffected because it depends only on the level groups.
  void setAbpNetworkHosts(Set<String> hosts) {
    _abpNetworkHosts = hosts;
    invalidateMergedBloom();
  }

  /// Invalidate the merged Bloom without changing the ABP host set (e.g.
  /// when only the DNS half changed).
  void invalidateMergedBloom() {
    _mergedBloomFilter = null;
  }

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

  /// What an earlier build kept of every host every site requested, in
  /// plaintext and never read back for a decision; removed at launch.
  static const _retiredDomainCacheKey = 'dns_domain_cache';
  static const _maxDomainCacheEntries = 5000;


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
    LogTag.blockBloom.info(
        'Built merged bloom: ${_mergedBloomFilter!.sizeInBytes} bytes, k=${_mergedBloomFilter!.k}, '
        'from ${_levelSets.domainCount} DNS + ${_abpNetworkHosts.length} ABP '
        'host(s) ($unionCount unique) in ${sw.elapsedMilliseconds}ms');
    return _mergedBloomFilter!;
  }

  DnsStats statsForSite(SiteId siteId) {
    return _siteStats.putIfAbsent(siteId, () => DnsStats());
  }

  /// Records [verdict] for [query] against [siteId]. [count] folds repeats
  /// the Android interceptor deduplicated into one log entry.
  void recordVerdict(
    SiteId siteId, {
    required BlockQuery query,
    required BlockVerdict verdict,
    int count = 1,
  }) {
    final host = switch (query) {
      UrlQuery(:final url) => extractHost(url),
      HostQuery(:final host) => host,
    };
    if (host == null || host.isEmpty) return;
    final source = verdict.source;
    final blocked = source != null;
    statsForSite(siteId)
        .record(host, wasBlocked: blocked, source: source, count: count);
    // Single funnel for the persisted app-wide report (STATS-002): every
    // DNS/ABP block on every platform passes through here, so the aggregate
    // cannot drift from the per-site counters.
    if (source != null) {
      BlockStatsService.instance.record(
        siteId,
        category: switch (source) {
          BlockSource.dns => BlockCategory.dnsBlocklist,
          BlockSource.abp => BlockCategory.filterList,
        },
        count: count,
        label: host,
      );
    }
    _scheduleNotifyDnsLogListeners();
  }

  void clearStatsForSite(SiteId siteId) {
    _siteStats[siteId]?.clear();
    _scheduleNotifyDnsLogListeners();
  }

  void addDnsLogListener(VoidCallback listener) {
    _dnsLogListeners.add(listener);
  }

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

  /// How far [initialize] got: once [BlockerData.ready], the level sets
  /// are the ones on disk, or none when there are none.
  BlockerData get data => _data;
  BlockerData _data = BlockerData.pending;

  /// Initialize the service by loading the cached blocklist from disk (no
  /// network). Call in main() at app startup.
  Future<DnsLoaded> initialize() async {
    await _load();
    return DnsLoaded._(this);
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final level = prefs.get(_levelKey);
      _level = level is int ? level : 0;

      await _loadFromDisk(prefs);
      if (!_levelSets.isEmpty) {
        LogTag.dnsBlock.info(
            'Loaded ${_levelSets.domainCount} domains from cache '
            '(level $_level, levels ${_levelSets.levels.toList()..sort()}, '
            '${_levelSets.groupCount} group(s))');
      }
      await prefs.remove(_retiredDomainCacheKey);
      _data = BlockerData.ready;
    } on FormatException catch (e) {
      LogTag.dnsBlock.error('Error loading cached blocklist: $e');
      _data = BlockerData.unreadable;
    } on IOException catch (e) {
      LogTag.dnsBlock.error('Error loading cached blocklist: $e');
      _data = BlockerData.unreadable;
    } on PlatformException catch (e) {
      LogTag.dnsBlock.error('Error loading cached blocklist: $e');
      _data = BlockerData.unreadable;
    } on IsolateSpawnException catch (e) {
      LogTag.dnsBlock.error('Error loading cached blocklist: $e');
      _data = BlockerData.unreadable;
    }
  }

  /// Read the stored partition, or migrate the pre-mask single-file cache the
  /// first time this runs after an upgrade.
  Future<void> _loadFromDisk(SharedPreferences prefs) async {
    final stored = await _store.readText(_levelsFileName);
    if (stored != null) {
      // Hundreds of thousands of domains: parsed off the UI isolate, so the
      // other startup inits run beside it instead of after it.
      _apply(sets: await compute(_parseLevelSets, stored), level: _level);
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
    await _store.writeText(_levelsFileName,
        contents: _serializeLevelSets(migrated));
    await _store.delete(_legacyCacheFileName);
    await _persistDownloadedLevels(prefs, levels: migrated.levels);
    _apply(sets: migrated, level: _level);
  }

  Future<void> _persistDownloadedLevels(
      SharedPreferences prefs, {required Set<int> levels}) async {
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

  /// The partition and the app-wide level a listener reads, put in force
  /// together: a listener told of one reads the other as it now stands.
  void _apply({required DnsLevelSets sets, required int level}) {
    _levelSets = sets;
    _level = level;
    _notifyBlocklistChanged();
  }

  /// Download the domain list for the given level (0-5) and make it the
  /// app-wide level. Tries each mirror URL in order. Level 0 clears every
  /// downloaded level. Returns true on success, false on failure.
  Future<bool> downloadList(int level) =>
      _mutations.run(() => _downloadListInner(level));

  Future<bool> _downloadListInner(int level) async {
    assert(_mutations.isHeld, 'a DNS level mutation outside its turn');
    if (level < 0 || level > kDnsMaxLevel) return false;

    if (level != 0) return _download(level, appWide: true);
    await _runFlow(
      DnsFlow._(this, level: 0, appWide: true),
      from: DnsPlace.clear,
    );
    return true;
  }

  /// The level-0 clear's disk work, before the table puts it in force.
  Future<void> _clearStored() async {
    try {
      await _store.delete(_levelsFileName);
      await _store.delete(_legacyCacheFileName);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_levelKey, 0);
      await prefs.remove(_lastUpdatedKey);
      await _persistDownloadedLevels(prefs, levels: const <int>{});
    } on IOException catch (e) {
      LogTag.dnsBlock.error('Error clearing blocklist: $e');
    } on PlatformException catch (e) {
      LogTag.dnsBlock.error('Error clearing blocklist: $e');
    }
  }

  /// [flow] run from its input at [from] to its end, with
  /// `"dns" \in Kinds` held meanwhile.
  Future<DnsFlow> _runFlow(DnsFlow flow, {required DnsPlace from}) async {
    assert(_mutations.isHeld, 'a DNS level mutation outside its turn');
    final c = StepContext(flow);
    final next = DnsTable.table.runInput(c, from: from);
    _flowing = true;
    try {
      await DnsTable.table.run(c, from: next);
    } finally {
      _flowing = false;
    }
    return flow;
  }

  /// One download as the table runs it: [level]'s list fetched and folded
  /// in, made the app-wide level when [appWide], then recorded.
  Future<bool> _download(int level, {required bool appWide}) async {
    final flow = await _runFlow(
      DnsFlow._(this, level: level, appWide: appWide),
      from: appWide ? DnsPlace.download : DnsPlace.addLevel,
    );
    if (flow.held) return true;
    if (flow.folded == null) return false;
    final prefs = await SharedPreferences.getInstance();
    if (appWide) {
      await prefs.setInt(_levelKey, level);
      await prefs.setString(_lastUpdatedKey, DateTime.now().toIso8601String());
    }
    await _persistDownloadedLevels(prefs, levels: _levelSets.levels);
    LogTag.dnsBlock.info(
        '${appWide ? 'Downloaded' : 'Added'} level $level '
        '(${_levelSets.domainCount} domains across '
        '${_levelSets.groupCount} group(s))');
    return true;
  }

  /// Whether a download is under way: the model's `"dns" \in Kinds`.
  bool _flowing = false;

  /// Fetch one extra severity level so sites may run at it, without touching
  /// the app-wide level. Idempotent: a level already downloaded succeeds
  /// without a request.
  Future<bool> downloadLevel(int level) =>
      _mutations.run(() => _downloadLevelInner(level));

  Future<bool> _downloadLevelInner(int level) async {
    assert(_mutations.isHeld, 'a DNS level mutation outside its turn');
    if (level < 1 || level > kDnsMaxLevel) return false;
    return _download(level, appWide: false);
  }

  /// Drop cached levels nothing asks for any more. [keep] comes from
  /// [requiredDnsLevels]; a domain no remaining level names falls out with
  /// its last bit. [keep] is read when this is called, so a level downloaded
  /// after that is kept, and so is the app-wide level as it is when the
  /// prune runs: the startup sweep reads the levels before a download the
  /// user started lands, or a site's level fetched before its Save
  /// (DNS-021).
  Future<void> pruneLevels(Set<int> keep) {
    final since = _folds;
    return _mutations.run(() => _pruneLevelsInner(keep, since: since));
  }

  /// Folds so far; [_foldedAt] names the fold each level last landed in.
  int _folds = 0;
  final Map<int, int> _foldedAt = {};

  Future<void> _pruneLevelsInner(Set<int> keep, {required int since}) async {
    assert(_mutations.isHeld, 'a DNS level mutation outside its turn');
    final drop = _levelSets.levels
        .where((l) =>
            !keep.contains(l) &&
            l != _level &&
            (_foldedAt[l] ?? 0) <= since)
        .toSet();
    if (drop.isEmpty) return;
    final builder = DnsLevelSetsBuilder.from(_levelSets);
    for (final level in drop) {
      builder.dropLevel(level);
    }
    final pruned = builder.build();
    await _writeLevelSets(pruned);
    final prefs = await SharedPreferences.getInstance();
    await _persistDownloadedLevels(prefs, levels: pruned.levels);
    _apply(sets: pruned, level: _level);
    LogTag.dnsBlock.info(
        'Dropped unused blocklist levels ${drop.toList()..sort()} '
        '(${pruned.domainCount} domains left)');
  }

  /// Download [level]'s list and fold it into the partition, setting its bit
  /// on the domains it names and clearing it on the ones it does not, and
  /// write it; the caller puts it in force. The raw body is parsed into a
  /// set that is dropped as soon as the fold is done; only the partition
  /// survives. Null when the list could not be had.
  Future<DnsLevelSets?> _foldLevel(int level) async {
    final body = await _fetchLevelBody(level);
    if (body == null) return null;
    final builder = DnsLevelSetsBuilder.from(_levelSets)..startLevel(level);
    for (final domain in _extractDomains(body)) {
      builder.add(domain);
    }
    final folded = builder.build();
    await _writeLevelSets(folded);
    _foldedAt[level] = ++_folds;
    return folded;
  }

  Future<void> _writeLevelSets(DnsLevelSets sets) async {
    if (sets.isEmpty) {
      await _store.delete(_levelsFileName);
      return;
    }
    await _store.writeText(_levelsFileName,
        contents: _serializeLevelSets(sets));
  }

  /// Fetch [level]'s list body. Tries each mirror in order; a mirror that
  /// answers 200 with something that isn't a domain list is skipped rather
  /// than folded into a working partition.
  Future<String?> _fetchLevelBody(int level) async {
    final filePath = _levelFiles[level];
    if (filePath == null) return null;

    for (final baseUrl in _mirrorBaseUrls) {
      final url = '$baseUrl$filePath';
      LogTag.dnsBlock.debug('Trying mirror: $url');
      switch (await fetchViaAppProxy(Uri.parse(url), tag: LogTag.dnsBlock)) {
        case FetchRefused():
          return null;
        case FetchFailed():
          continue;
        case Fetched(:final response):
          final domains = _extractDomains(response.body);
          if (looksLikeDomainList(domains)) return response.body;
          LogTag.dnsBlock.error(
              'Mirror returned ${response.body.length} bytes yielding '
              '${domains.length} usable entries, not a domain list. Skipping.');
      }
    }
    LogTag.dnsBlock.error('All mirrors failed for level $level');
    return null;
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
  bool isBlocked(String url) => isBlockedAtLevel(url, level: _level);

  /// Like [isBlocked] but skips URL parsing — caller already has the host
  /// (e.g. native interceptor bridge passing `host` directly).
  bool isHostBlocked(String host) => isHostBlockedAtLevel(host, level: _level);

  /// [isBlocked] at a specific severity level — what a site with its own
  /// level runs. The tier lookup is shared, so this costs the same as the
  /// app-wide check.
  bool isBlockedAtLevel(String url, {required int level}) {
    if (level <= kDnsLevelOff || _levelSets.isEmpty) return false;
    final host = extractHost(url);
    if (host == null || host.isEmpty) return false;
    return isHostBlockedAtLevel(host, level: level);
  }

  bool isHostBlockedAtLevel(String host, {required int level}) {
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
    _dnsBlockCache.put(host, value: mask);
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
      _mutations.run(() => _applyImportedLevelInner(level));

  Future<void> _applyImportedLevelInner(int level) async {
    assert(_mutations.isHeld, 'a DNS level mutation outside its turn');
    if (level < 0 || level > kDnsMaxLevel) return;
    if (level == _level) return;
    try {
      await _store.delete(_levelsFileName);
      await _store.delete(_legacyCacheFileName);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_levelKey, level);
      await prefs.remove(_lastUpdatedKey);
      await _persistDownloadedLevels(prefs, levels: const <int>{});
    } on IOException catch (e) {
      LogTag.dnsBlock.error('Error applying imported level: $e');
    } on PlatformException catch (e) {
      LogTag.dnsBlock.error('Error applying imported level: $e');
    }
    _apply(sets: DnsLevelSets.empty, level: level);
  }

  /// Get the last time the blocklist was downloaded, or null if never.
  Future<DateTime?> getLastUpdated() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getString(_lastUpdatedKey);
    if (timestamp == null) return null;
    return DateTime.tryParse(timestamp);
  }

  /// Load one level's domains from a raw string, as if it had just been
  /// downloaded at [level] and made the app-wide level.
  @visibleForTesting
  void loadDomainsFromString(String data, {int level = 1}) {
    final domains = _extractDomains(data);
    if (domains.isEmpty) {
      _apply(sets: DnsLevelSets.empty, level: level);
      return;
    }
    final builder = DnsLevelSetsBuilder()..startLevel(level);
    for (final domain in domains) {
      builder.add(domain);
    }
    _apply(sets: builder.build(), level: level);
  }

  /// Load several levels at once, as if each had been downloaded. Keys are
  /// levels, values raw list bodies.
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
    _apply(
      sets: builder.build(),
      level: globalLevel ?? (levels.isEmpty ? 0 : levels.last),
    );
  }

  /// The stored form of the current partition, for tests that need to prove
  /// a round-trip through disk preserves every level's membership.
  @visibleForTesting
  String serializeLevelSetsForTest() => _serializeLevelSets(_levelSets);

  @visibleForTesting
  void loadLevelSetsFromSerialized(String text, {int? globalLevel}) {
    _apply(sets: _parseLevelSets(text), level: globalLevel ?? _level);
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

  /// Drop every piece of in-memory state so a test can drive [initialize]
  /// from a known-empty service. The singleton outlives a test otherwise, and
  /// the storage paths are exactly what needs exercising from cold.
  @visibleForTesting
  void resetForTest() {
    _data = BlockerData.pending;
    _folds = 0;
    _foldedAt.clear();
    _levelSets = DnsLevelSets.empty;
    _level = 0;
    _mergedBloomFilter = null;
    _abpNetworkHosts = <String>{};
    _dnsBlockCache.clear();
    _siteStats.clear();
    _storeOverride = null;
    _flowing = false;
    views = ViewBlockers(send: _attachNative, resolve: effectiveLevelFor);
  }

  FileStore? _storeOverride;

  /// Cache directory for the downloaded blocklist. Swappable for tests and
  /// the design gallery.
  @visibleForTesting
  set store(FileStore store) => _storeOverride = store;

  FileStore get _store => _storeOverride ??= defaultFileStore('dns_blocklist');
}

/// The partition and the app-wide level in force, as the model's `dns`:
/// the level and the levels downloaded.
@immutable
final class DnsInForce {
  const DnsInForce({required this.level, required this.levels});

  final int level;
  final Set<int> levels;

  @override
  bool operator ==(Object other) =>
      other is DnsInForce &&
      other.level == level &&
      setEquals(other.levels, levels);

  @override
  int get hashCode => Object.hash(level, Object.hashAllUnordered(levels));

  @override
  String toString() => 'DnsInForce($level, $levels)';
}

/// The places a download waits at, as `activation.tla` names them: the
/// three inputs, the fetch and fold, the clear's disk work, and the end.
enum DnsPlace { download, addLevel, clear, dFold, dCleared, done }

/// One download as its table runs it: the service, the level asked for,
/// whether it becomes the app-wide level, and what the fold made.
final class DnsFlow {
  DnsFlow._(this.service, {required this.level, required this.appWide});

  final DnsBlockService service;
  final int level;
  final bool appWide;
  DnsLevelSets? folded;

  /// The level was downloaded already: nothing to fetch.
  bool held = false;
}

extension DnsTable on DnsBlockService {
  /// The table a download runs from, printed into the model (DNS-019,
  /// DNS-021, DNS-022).
  static StepTable<DnsFlow, DnsPlace> get table => _dnsTable;
}

final _dnsKind = Field<FlowKind, DnsFlow>(FlowField.kind);
final _dnsLvl = Field<int, DnsFlow>(FlowField.lvl);
final _dnsAppWide = Field<bool, DnsFlow>(FlowField.appWide);

/// The partition and the app-wide level: written only here, by the fold's
/// one apply, so a view told of it reads both as they now stand.
final _dnsInForce = Mutable<DnsInForce, DnsFlow>(
  ModelVar.dns,
  read: (w) => DnsInForce(
    level: w.service._level,
    levels: w.service._levelSets.levels,
  ),
  write: (w, {required to}) {
    final folded = w.folded!;
    assert(
      setEquals(folded.levels, to.levels),
      'the fold made levels ${folded.levels}, the model ${to.levels}',
    );
    w.service._apply(sets: folded, level: to.level);
  },
);

/// The level each live view told its interceptor: the views' own (they
/// are told as the partition moves), which the model's value must match.
final _dnsTold = Mutable<Map<SiteId, int>, DnsFlow>(
  ModelVar.told,
  read: (w) => w.service.views.told,
  write: (w, {required to}) {
    final told = w.service.views.told;
    assert(
      told.length == to.length &&
          told.entries.every((e) => to[e.key] == e.value),
      'the views were told $told, the model $to',
    );
  },
);

final _dnsSiteLevel = Indexed<SiteId, int, DnsFlow>.fixed(
  ModelConst.siteLevel,
  read: (w, {required at}) =>
      w.service.views.siteLevels[at] ?? kDnsLevelFollow,
);

/// Whether a DNS flow runs already, which the model reads off every flow.
final _dnsRunning = Port<bool, DnsFlow>(
  'running',
  reads: {ModelVar.fl},
  changes: const {},
  of: (w) => w.service._flowing,
);

/// What a DNS flow's calls do and keep for the step after them, which
/// writes the model's `dns` and `told` itself: the list fetched and folded
/// in, or every list deleted.
final _dnsFold = Port<DnsFold, DnsFlow>(
  'fold',
  reads: const {},
  changes: const {},
  of: (w) => (
    fold: () async => w.folded = await w.service._foldLevel(w.level),
    clear: () async {
      await w.service._clearStored();
      w.folded = DnsLevelSets.empty;
    },
    failed: () => w.folded == null,
    held: () => w.held = true,
  ),
);

/// [_dnsFold]'s interface.
typedef DnsFold = ({
  Future<void> Function() fold,
  Future<void> Function() clear,
  bool Function() failed,
  void Function() held,
});

final _dnsFlowing = Expr.inFlight<DnsFlow>(
  FlowKind.dns,
  run: _dnsRunning.from,
);

final _dnsFails = Expr.op<bool, DnsFlow>(
  'FALSE',
  run: (c) => _dnsFold.from(c).failed(),
  reads: Reads.none,
);

/// The levels a download may pick (`DnsLevels`): the one asked, in the
/// code.
final _dnsLevels = Constant<List<int>, DnsFlow>(
  ModelConst.dnsLevels,
  read: (w) => [w.level],
).value;
final _dnsEachLevel = Pick<int, DnsFlow>(_dnsLevels);

final _dnsViews = Constant<Iterable<SiteId>, DnsFlow>(
  ModelConst.sites,
  read: (w) => w.service.views.told.keys,
).value;

final _dnsS = Bound<SiteId, DnsFlow>('s');
final _dnsResolve = resolveLevelDef<DnsFlow>();

/// What each live view is told once [level] and [levels] are in force: the
/// level its site resolves to under them.
Write<DnsFlow> _toldUnder({
  required Expr<int, DnsFlow> level,
  required Expr<Iterable<int>, DnsFlow> levels,
}) => _dnsTold.becomes(
  _dnsViews.mapTo(
    _dnsS,
    to: Expr.choose(
      when: _dnsTold.value.at(_dnsS.it).eq(Expr.constant(-1)),
      then: Expr.constant(-1),
      otherwise: _dnsResolve.call([
        _dnsSiteLevel.at(_dnsS.it),
        level,
        levels,
      ]),
    ),
  ),
);

/// The app-wide level once the fold lands, and the levels downloaded.
final _dnsNewLevel = Expr.choose(
  when: _dnsAppWide.value,
  then: _dnsLvl.value,
  otherwise: _dnsInForce.value.part('lvl', get: (d) => d.level),
);
final _dnsNewLevels = _dnsInForce.value
    .part<Iterable<int>>('levels', get: (d) => d.levels)
    .union(_dnsLvl.value.asSet);

final _dnsOff = Expr.constant<int, DnsFlow>(kDnsLevelOff);
final _dnsNoLevels = Expr.constant<Iterable<int>, DnsFlow>(
  const <int>[],
  tla: '{}',
);

final _dnsHeld = _dnsInForce.value
    .part<Iterable<int>>('levels', get: (d) => d.levels)
    .has(_dnsEachLevel.it);

final StepTable<DnsFlow, DnsPlace> _dnsTable = StepTable(
  DnsPlace.values,
  ending: {DnsPlace.done},
  vars: [_dnsInForce, _dnsTold],
  at: (place) => switch (place) {
    // The user downloads a level as the app-wide one (DNS-019).
    DnsPlace.download => Step.input(
      ActivationStep.dnsDownload,
      enabled: ~_dnsFlowing,
      pick: _dnsEachLevel,
      otherwise: Otherwise(
        StepOutcome.none,
        then: [
          _dnsKind.becomes(Expr.constant(FlowKind.dns)),
          _dnsLvl.becomes(_dnsEachLevel.it),
          _dnsAppWide.becomes(Expr.constant(true)),
        ],
        next: to(DnsPlace.dFold),
      ),
    ),
    // A site's level asks for a list not downloaded yet (DNS-021); one
    // already held costs no request.
    DnsPlace.addLevel => Step.input(
      ActivationStep.dnsAddLevel,
      enabled: ~_dnsFlowing,
      pick: _dnsEachLevel,
      branches: [
        Branch(
          StepOutcome.skip,
          when: _dnsHeld,
          then: [Note((c) => _dnsFold.from(c).held())],
          next: to(DnsPlace.done),
        ),
      ],
      otherwise: Otherwise(
        StepOutcome.go,
        then: [
          _dnsKind.becomes(Expr.constant(FlowKind.dns)),
          _dnsLvl.becomes(_dnsEachLevel.it),
          _dnsAppWide.becomes(Expr.constant(false)),
        ],
        next: to(DnsPlace.dFold),
      ),
    ),
    // The list fetched and folded in: the partition and the app-wide level
    // in force together, so every live view is told the level its site
    // resolves to now (DNS-022). One the mirrors do not have changes
    // nothing.
    DnsPlace.dFold => Step(
      ActivationStep.dnsFolded,
      holds: null,
      call: Call.on(
        _dnsFold,
        run: (c) => c.api.fold(),
        writes: const [],
      ),
      branches: [
        Branch(
          StepOutcome.bail,
          when: _dnsFails,
          then: [],
          next: to(DnsPlace.done),
        ),
      ],
      otherwise: Otherwise(
        StepOutcome.go,
        then: [
          Act.of([
            _dnsInForce.becomes(
              record(
                {'lvl': _dnsNewLevel, 'levels': _dnsNewLevels},
                run: (c) => DnsInForce(
                  level: _dnsNewLevel.run(c),
                  levels: _dnsNewLevels.run(c).toSet(),
                ),
              ),
            ),
            _toldUnder(level: _dnsNewLevel, levels: _dnsNewLevels),
          ]),
          modelOnly(
            'seen\' = seen \\cup (IF \\E s \\in Sites : told\'[s] > 0 '
            'THEN {"dnsTells"} ELSE {})',
            writes: {ModelVar.seen},
            reads: const Reads(vars: {ModelVar.seen, ModelVar.told}),
          ),
        ],
        next: to(DnsPlace.done),
      ),
    ),
    // The user turns DNS blocking off (level 0): every list goes.
    DnsPlace.clear => Step.input(
      ActivationStep.dnsClear,
      enabled: _dnsLevels.isNotEmpty & ~_dnsFlowing,
      otherwise: Otherwise(
        StepOutcome.none,
        then: [
          _dnsKind.becomes(Expr.constant(FlowKind.dns)),
          _dnsLvl.becomes(Expr.constant(kDnsLevelOff)),
          _dnsAppWide.becomes(Expr.constant(true)),
        ],
        next: to(DnsPlace.dCleared),
      ),
    ),
    // The lists deleted from disk; then nothing is downloaded and every
    // live view is told off, as one write.
    DnsPlace.dCleared => Step(
      ActivationStep.dnsCleared,
      holds: null,
      call: Call.on(
        _dnsFold,
        run: (c) => c.api.clear(),
        writes: const [],
      ),
      otherwise: Otherwise(
        StepOutcome.none,
        then: [
          Act.of([
            _dnsInForce.becomes(
              record(
                {'lvl': _dnsOff, 'levels': _dnsNoLevels},
                run: (_) =>
                    const DnsInForce(level: kDnsLevelOff, levels: <int>{}),
              ),
            ),
            _toldUnder(level: _dnsOff, levels: _dnsNoLevels),
          ]),
        ],
        next: to(DnsPlace.done),
      ),
    ),
    DnsPlace.done => const Leaves(),
  },
);

/// [DnsBlockService] once [DnsBlockService.initialize] has run, which alone
/// makes one: startup work that reads the level sets takes this.
extension type const DnsLoaded._(DnsBlockService _service)
    implements DnsBlockService {
  /// Android's interceptor answers from the raw level sets: sent now, and
  /// again each time they change.
  Future<void> mirrorInto(NativeIntercept native) async {
    addBlocklistChangedListener(() => native.sendDnsLevelGroups(levelGroups));
    if (hasBlocklist) await native.sendDnsLevelGroups(levelGroups);
  }
}
