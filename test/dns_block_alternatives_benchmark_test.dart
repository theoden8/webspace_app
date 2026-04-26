import 'dart:collection';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/bloom_filter.dart';
import 'package:webspace/services/dns_block_service.dart';

/// Benchmarks five lookup strategies on a ~400k+ domain list with a realistic
/// Zipfian browsing workload, to answer:
///
///   "Does the iOS-style bloom-filter + per-host cache help the native Dart
///    isBlocked() hot path, beyond what the existing Set<String> already does?"
///
/// The five variants share the same domain set + same workload so timings are
/// directly comparable. Each variant only differs in the per-call code path.
///
///   1. baseline           — current production path: Set.contains + walk via
///                           parts.sublist(i).join('.') (allocates strings).
///   2. substringWalk      — same Set lookups, but the hierarchy walk uses
///                           lastIndexOf substring slicing instead of
///                           sublist+join. No per-step allocations.
///   3. bloomThenSet       — bloom prefilter for the whole host first; if
///                           bloom says "definitely no" we still need to walk
///                           parents (a parent could be in the bloom even if
///                           the leaf isn't), so this only short-circuits
///                           when the host itself isn't in the bloom AND no
///                           parent is. Uses the substring walk.
///   4. lruCacheWalk       — LinkedHashMap-backed LRU on the resolved
///                           host -> bool decision; on miss, falls back to
///                           the substring walk. This is the "cache like
///                           iOS does" piece, ported to native Dart.
///   5. bloomLruWalk       — both: LRU first, on miss bloom-prefilter, then
///                           substring walk. This is the full iOS-style
///                           tier order in Dart.
///
/// We use a synthetic blocklist sized to ~600k entries (Hagezi Ultimate
/// ~522k + a slice for EasyList domain rules) because the hot-path cost
/// depends on size and host distribution, not blocklist contents. The numbers
/// are reproducible (fixed seed) so deltas between variants are meaningful.
///
/// Output is printed to stdout via `print` so `flutter test --reporter
/// expanded` shows it. Each test makes a soft assertion that the variant
/// completes without regressing past a generous absolute bound, so the
/// benchmark always runs to completion and you can read the comparison.
void main() {
  // Build dataset + workload once. group setUpAll runs before each test.
  late _Dataset dataset;
  late List<String> workload;

  setUpAll(() {
    dataset = _buildDataset(domainCount: 600000, seed: 42);
    workload = _buildZipfianWorkload(
      dataset: dataset,
      requestCount: 200000,
      seed: 99,
    );
  });

  group('DnsBlock alternatives — 600k domains, Zipfian workload', () {
    test('00. dataset and workload sanity', () {
      // ignore: avoid_print
      print('=== Dataset ===');
      // ignore: avoid_print
      print('  domains in blocklist: ${dataset.domains.length}');
      // ignore: avoid_print
      print('  bloom size: ${dataset.bloom.sizeInBytes} bytes, k=${dataset.bloom.k}');
      // ignore: avoid_print
      print('=== Workload ===');
      // ignore: avoid_print
      print('  total lookups: ${workload.length}');
      // Estimate hit rate for the workload using the production isBlocked.
      DnsBlockService.instance.loadDomainsFromString(dataset.rawText);
      int hits = 0;
      for (final url in workload) {
        if (DnsBlockService.instance.isBlocked(url)) hits++;
      }
      // ignore: avoid_print
      print('  blocked: $hits  allowed: ${workload.length - hits}  '
          'block-rate: ${(hits / workload.length * 100).toStringAsFixed(1)}%');
      expect(workload.length, equals(200000));
      expect(dataset.domains.length, greaterThan(500000));
    });

    test('01. baseline (Set.contains + sublist+join walk) — current production path', () {
      DnsBlockService.instance.loadDomainsFromString(dataset.rawText);
      final sw = Stopwatch()..start();
      int hits = 0;
      for (final url in workload) {
        if (DnsBlockService.instance.isBlocked(url)) hits++;
      }
      sw.stop();
      _report('baseline (sublist+join)', sw, workload.length, hits);
      expect(sw.elapsedMilliseconds, lessThan(60000));
    });

    test('02. substring walk (same Set, no allocations in walk)', () {
      final domains = dataset.domains;
      final sw = Stopwatch()..start();
      int hits = 0;
      for (final url in workload) {
        if (_isBlockedSubstring(url, domains)) hits++;
      }
      sw.stop();
      _report('substring walk', sw, workload.length, hits);
      expect(sw.elapsedMilliseconds, lessThan(60000));
    });

    test('03. bloom prefilter + substring walk', () {
      final domains = dataset.domains;
      final bloom = dataset.bloom;
      final sw = Stopwatch()..start();
      int hits = 0;
      for (final url in workload) {
        if (_isBlockedBloomFirst(url, domains, bloom)) hits++;
      }
      sw.stop();
      _report('bloom + substring walk', sw, workload.length, hits);
      expect(sw.elapsedMilliseconds, lessThan(60000));
    });

    test('04. LRU host-decision cache (5000) + substring walk', () {
      final domains = dataset.domains;
      final cache = _LruCache<String, bool>(capacity: 5000);
      final sw = Stopwatch()..start();
      int hits = 0;
      for (final url in workload) {
        if (_isBlockedLru(url, domains, cache)) hits++;
      }
      sw.stop();
      _report('LRU + substring walk', sw, workload.length, hits,
          extra: 'cache size=${cache.length}');
      expect(sw.elapsedMilliseconds, lessThan(60000));
    });

    test('05. bloom + LRU + substring walk (iOS-style tiering)', () {
      final domains = dataset.domains;
      final bloom = dataset.bloom;
      final cache = _LruCache<String, bool>(capacity: 5000);
      final sw = Stopwatch()..start();
      int hits = 0;
      for (final url in workload) {
        if (_isBlockedBloomLru(url, domains, bloom, cache)) hits++;
      }
      sw.stop();
      _report('bloom + LRU + substring', sw, workload.length, hits,
          extra: 'cache size=${cache.length}');
      expect(sw.elapsedMilliseconds, lessThan(60000));
    });

    test('06. cold cache vs warm cache for variant 04 (LRU)', () {
      // Run the LRU variant twice. The second run should be cache-warm and
      // shows the steady-state cost when the working-set fits the cache.
      final domains = dataset.domains;
      final cache = _LruCache<String, bool>(capacity: 5000);

      final coldSw = Stopwatch()..start();
      for (final url in workload) {
        _isBlockedLru(url, domains, cache);
      }
      coldSw.stop();

      final warmSw = Stopwatch()..start();
      for (final url in workload) {
        _isBlockedLru(url, domains, cache);
      }
      warmSw.stop();

      // ignore: avoid_print
      print('LRU cold:  ${coldSw.elapsedMilliseconds}ms total, '
          '${(coldSw.elapsedMicroseconds / workload.length).toStringAsFixed(2)}us/call');
      // ignore: avoid_print
      print('LRU warm:  ${warmSw.elapsedMilliseconds}ms total, '
          '${(warmSw.elapsedMicroseconds / workload.length).toStringAsFixed(2)}us/call');
      // ignore: avoid_print
      print('LRU final cache size: ${cache.length}');
    });
  });
}

// -----------------------------------------------------------------------------
// Variants
// -----------------------------------------------------------------------------

/// Substring-based hierarchy walk. Same logic as production `isBlocked()` but
/// without `parts.sublist(i).join('.')` — uses indexOf to slice the host.
bool _isBlockedSubstring(String url, Set<String> domains) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final host = uri.host;
  if (host.isEmpty) return false;
  if (domains.contains(host)) return true;
  int dot = host.indexOf('.');
  while (dot >= 0 && dot < host.length - 1) {
    final parent = host.substring(dot + 1);
    // Stop at the eTLD level: don't check single-label "com".
    if (parent.indexOf('.') < 0) break;
    if (domains.contains(parent)) return true;
    dot = host.indexOf('.', dot + 1);
  }
  return false;
}

/// Bloom prefilter for both the host and parent suffixes. If neither the host
/// nor any parent is in the bloom, definitely not blocked. Otherwise resort to
/// the authoritative Set walk to filter false positives.
bool _isBlockedBloomFirst(String url, Set<String> domains, BloomFilter bloom) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final host = uri.host;
  if (host.isEmpty) return false;

  // Cheap probe of the bloom for host + each parent. If all probes are
  // negative we can skip the Set entirely. False positives on any probe
  // require the Set check.
  if (bloom.contains(host)) {
    if (domains.contains(host)) return true;
  }
  int dot = host.indexOf('.');
  while (dot >= 0 && dot < host.length - 1) {
    final parent = host.substring(dot + 1);
    if (parent.indexOf('.') < 0) break;
    if (bloom.contains(parent)) {
      if (domains.contains(parent)) return true;
    }
    dot = host.indexOf('.', dot + 1);
  }
  return false;
}

/// LRU cache on host-level decision, falls back to substring walk.
bool _isBlockedLru(String url, Set<String> domains, _LruCache<String, bool> cache) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final host = uri.host;
  if (host.isEmpty) return false;
  final cached = cache.get(host);
  if (cached != null) return cached;
  final result = _hostBlockedSubstring(host, domains);
  cache.put(host, result);
  return result;
}

/// LRU + bloom prefilter + substring walk. Bloom check is applied only on
/// cache miss, mirroring the iOS JS interceptor's tier order:
///   1. cache hit            → instant
///   2. bloom says no        → instant negative
///   3. bloom says maybe     → authoritative Set walk
bool _isBlockedBloomLru(
    String url, Set<String> domains, BloomFilter bloom, _LruCache<String, bool> cache) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final host = uri.host;
  if (host.isEmpty) return false;
  final cached = cache.get(host);
  if (cached != null) return cached;

  // Bloom probe over host + parents. If all bloom probes are negative we can
  // record `false` without touching the Set.
  bool maybeMember = bloom.contains(host);
  if (!maybeMember) {
    int dot = host.indexOf('.');
    while (dot >= 0 && dot < host.length - 1) {
      final parent = host.substring(dot + 1);
      if (parent.indexOf('.') < 0) break;
      if (bloom.contains(parent)) {
        maybeMember = true;
        break;
      }
      dot = host.indexOf('.', dot + 1);
    }
  }

  bool result;
  if (!maybeMember) {
    result = false;
  } else {
    result = _hostBlockedSubstring(host, domains);
  }
  cache.put(host, result);
  return result;
}

bool _hostBlockedSubstring(String host, Set<String> domains) {
  if (domains.contains(host)) return true;
  int dot = host.indexOf('.');
  while (dot >= 0 && dot < host.length - 1) {
    final parent = host.substring(dot + 1);
    if (parent.indexOf('.') < 0) break;
    if (domains.contains(parent)) return true;
    dot = host.indexOf('.', dot + 1);
  }
  return false;
}

// -----------------------------------------------------------------------------
// LRU cache (LinkedHashMap-based, insertion-order eviction reordered on hit).
// -----------------------------------------------------------------------------

class _LruCache<K, V> {
  final int capacity;
  final LinkedHashMap<K, V> _map = LinkedHashMap();
  _LruCache({required this.capacity});

  V? get(K key) {
    final v = _map.remove(key);
    if (v == null) return null;
    _map[key] = v;
    return v;
  }

  void put(K key, V value) {
    if (_map.containsKey(key)) {
      _map.remove(key);
    } else if (_map.length >= capacity) {
      _map.remove(_map.keys.first);
    }
    _map[key] = value;
  }

  int get length => _map.length;
}

// -----------------------------------------------------------------------------
// Dataset and workload generation.
// -----------------------------------------------------------------------------

class _Dataset {
  final Set<String> domains;
  final String rawText;
  final BloomFilter bloom;
  final List<String> domainList; // ordered, used for hit-sampling
  _Dataset(this.domains, this.rawText, this.bloom, this.domainList);
}

_Dataset _buildDataset({required int domainCount, required int seed}) {
  final random = Random(seed);
  final tlds = const [
    'com', 'net', 'org', 'io', 'co', 'info', 'biz', 'xyz', 'app', 'dev',
  ];
  final domains = <String>{};
  final list = <String>[];
  final buffer = StringBuffer();
  buffer.writeln('# Synthetic blocklist for benchmarking (~$domainCount domains)');

  while (domains.length < domainCount) {
    final tld = tlds[random.nextInt(tlds.length)];
    final nameLen = 4 + random.nextInt(12);
    final name = String.fromCharCodes(
      List.generate(nameLen, (_) => 97 + random.nextInt(26)),
    );
    String d;
    if (random.nextInt(5) == 0) {
      // ~20% subdomain entries, mirroring real Hagezi shape
      final subLen = 3 + random.nextInt(6);
      final sub = String.fromCharCodes(
        List.generate(subLen, (_) => 97 + random.nextInt(26)),
      );
      d = '$sub.$name.$tld';
    } else {
      d = '$name.$tld';
    }
    if (domains.add(d)) {
      list.add(d);
      buffer.writeln(d);
    }
  }

  final bloom = BloomFilter.build(domains, fpRate: 0.05);
  return _Dataset(domains, buffer.toString(), bloom, list);
}

/// Build a Zipfian-distributed workload that mimics real browsing:
/// - A long tail of "hot" domains (CDNs, analytics) that recur constantly.
/// - Some misses (URLs to non-blocked domains).
/// - Some subdomain hits (blocked-by-parent walk-up triggers).
List<String> _buildZipfianWorkload({
  required _Dataset dataset,
  required int requestCount,
  required int seed,
}) {
  final random = Random(seed);
  final blocked = dataset.domainList;
  // Hot pool: pick 200 "trackers" from the blocklist that get sampled often.
  final hotBlocked = <String>[
    for (var i = 0; i < 200; i++) blocked[random.nextInt(blocked.length)],
  ];
  // Hot allowed pool: 50 normal domains (typed queries, page hosts).
  final hotAllowed = <String>[
    for (var i = 0; i < 50; i++)
      'site${random.nextInt(1000)}.example${random.nextInt(50)}.test',
  ];

  String pickHotBlocked() => hotBlocked[_zipf(random, hotBlocked.length)];
  String pickHotAllowed() => hotAllowed[_zipf(random, hotAllowed.length)];

  final urls = <String>[];
  for (var i = 0; i < requestCount; i++) {
    final r = random.nextInt(100);
    String host;
    if (r < 60) {
      // 60% hot blocked (recurring CDN/tracker that page reloads keep hitting)
      host = pickHotBlocked();
    } else if (r < 75) {
      // 15% subdomain of a random blocked domain (walk-up hit)
      final parent = blocked[random.nextInt(blocked.length)];
      host = 'sub${random.nextInt(20)}.$parent';
    } else if (r < 90) {
      // 15% hot allowed (normal traffic)
      host = pickHotAllowed();
    } else {
      // 10% cold misses (random non-blocked hosts)
      final nameLen = 5 + random.nextInt(8);
      final name = String.fromCharCodes(
        List.generate(nameLen, (_) => 97 + random.nextInt(26)),
      );
      host = '$name.notblocked.test';
    }
    urls.add('https://$host/path?q=$i');
  }
  return urls;
}

/// Sample with a Zipf-like decay so a small head is hit most often.
int _zipf(Random random, int n) {
  // Quick zipfian-ish: take min over k uniform draws to bias toward 0.
  int idx = random.nextInt(n);
  for (var i = 0; i < 3; i++) {
    final j = random.nextInt(n);
    if (j < idx) idx = j;
  }
  return idx;
}

// -----------------------------------------------------------------------------
// Reporting
// -----------------------------------------------------------------------------

void _report(String name, Stopwatch sw, int n, int hits, {String? extra}) {
  final perCallUs = sw.elapsedMicroseconds / n;
  // ignore: avoid_print
  print('--- $name ---');
  // ignore: avoid_print
  print('  total:    ${sw.elapsedMilliseconds}ms (${sw.elapsedMicroseconds}us)');
  // ignore: avoid_print
  print('  per call: ${perCallUs.toStringAsFixed(3)}us');
  // ignore: avoid_print
  print('  hits:     $hits / $n');
  if (extra != null) {
    // ignore: avoid_print
    print('  $extra');
  }
}
