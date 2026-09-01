import 'package:webspace/services/host_lookup.dart';

/// Level 0 ("Off") names no list, so it is always resolvable without any
/// downloaded data.
const int kDnsLevelOff = 0;
const int kDnsMaxLevel = 5;

/// Blocked domains partitioned by the lowest severity level whose Hagezi
/// list names them.
///
/// The levels are cumulative, so "blocked at level N" is exactly "sits in
/// some tier 1..N". Keeping the partition instead of one flat set is what
/// lets every site run its own level off one copy of the data: the per-site
/// setting is a comparison against the tier, not a second blocklist.
class DnsTiers {
  DnsTiers._(this._tiers, this.levels);

  /// Indexed by level; index 0 is unused and a level that was never
  /// downloaded is null. Tiers are disjoint, so the entry count across all
  /// of them equals the size of the largest downloaded list.
  final List<Set<String>?> _tiers;

  /// Levels whose list has been folded in. A level absent here has no tier
  /// boundary, which is why [resolveDnsLevel] refuses to run at it.
  final Set<int> levels;

  static final DnsTiers empty = DnsTiers._(
    List<Set<String>?>.filled(kDnsMaxLevel + 1, null),
    const <int>{},
  );

  bool get isEmpty {
    for (final tier in _tiers) {
      if (tier != null && tier.isNotEmpty) return false;
    }
    return true;
  }

  int get domainCount {
    var n = 0;
    for (final tier in _tiers) {
      if (tier != null) n += tier.length;
    }
    return n;
  }

  /// Every blocked domain, across all downloaded levels. Lazy so callers
  /// that only need to hash them (Bloom construction, the native push) never
  /// materialise a union set.
  Iterable<String> get domains =>
      _tiers.whereType<Set<String>>().expand((tier) => tier);

  Set<String> tierDomains(int level) =>
      (level >= 0 && level < _tiers.length ? _tiers[level] : null) ??
      const <String>{};

  /// Lowest level at which [host] (or a parent domain) is blocked, or 0 when
  /// no downloaded list names it.
  ///
  /// Ascending so the first hit is the answer: a domain reachable through
  /// both a level-1 parent and a level-4 exact match blocks from level 1 on.
  int tierOf(String host) {
    if (host.isEmpty) return 0;
    for (var level = 1; level <= kDnsMaxLevel; level++) {
      final tier = _tiers[level];
      if (tier != null && hostInSet(host, tier)) return level;
    }
    return 0;
  }

  bool blockedAt(String host, int level) {
    if (level <= kDnsLevelOff) return false;
    final tier = tierOf(host);
    return tier != 0 && tier <= level;
  }
}

/// Accumulates tiers level by level, dropping each domain a lower level
/// already carries.
///
/// Levels MUST be started in ascending order. Feed domains one at a time
/// rather than as a parsed set: a full list is ~650K entries, and holding
/// the raw set alongside the tiers it is about to be subtracted into is the
/// one place this structure could cost more memory than the flat set it
/// replaces.
class DnsTiersBuilder {
  final List<Set<String>?> _tiers =
      List<Set<String>?>.filled(kDnsMaxLevel + 1, null);
  final Set<int> _levels = <int>{};
  int _current = 0;

  void startLevel(int level) {
    if (level < 1 || level > kDnsMaxLevel) {
      throw ArgumentError.value(level, 'level', 'not a blocklist level');
    }
    if (level <= _current) {
      throw StateError('levels must be added in ascending order');
    }
    _current = level;
    _levels.add(level);
    _tiers[level] = <String>{};
  }

  void add(String domain) {
    if (_current == 0) throw StateError('startLevel() first');
    for (var level = 1; level < _current; level++) {
      if (_tiers[level]?.contains(domain) ?? false) return;
    }
    _tiers[_current]!.add(domain);
  }

  int get currentLevelCount => _current == 0 ? 0 : _tiers[_current]!.length;

  DnsTiers build() => DnsTiers._(_tiers, Set<int>.unmodifiable(_levels));
}

/// Level a site actually runs at.
///
/// A site level only means what it says when that level's list has been
/// downloaded — otherwise the tier boundary it asks for does not exist and
/// evaluating against the tiers would silently under-block. Falling back to
/// the app-wide level keeps the site at least as protected as it would have
/// been without a per-site setting at all.
int resolveDnsLevel({
  required int? siteLevel,
  required int globalLevel,
  required Set<int> downloadedLevels,
}) {
  if (siteLevel == null) return globalLevel;
  if (siteLevel <= kDnsLevelOff) return kDnsLevelOff;
  if (siteLevel > kDnsMaxLevel) return globalLevel;
  if (downloadedLevels.contains(siteLevel)) return siteLevel;
  return globalLevel;
}

/// Whether [siteLevel] is asking for a list the app has not fetched. Drives
/// the settings row's download affordance and its "not configured" warning.
bool dnsLevelNeedsDownload({
  required int? siteLevel,
  required Set<int> downloadedLevels,
}) {
  if (siteLevel == null || siteLevel <= kDnsLevelOff) return false;
  if (siteLevel > kDnsMaxLevel) return false;
  return !downloadedLevels.contains(siteLevel);
}

/// Levels worth keeping on disk and in memory: the app-wide level plus every
/// level some site asks for. Anything else is a leftover from an earlier
/// configuration and can be dropped.
Set<int> requiredDnsLevels({
  required int globalLevel,
  required Iterable<int?> siteLevels,
}) {
  final keep = <int>{};
  if (globalLevel > kDnsLevelOff) keep.add(globalLevel);
  for (final level in siteLevels) {
    if (level != null && level > kDnsLevelOff && level <= kDnsMaxLevel) {
      keep.add(level);
    }
  }
  return keep;
}
