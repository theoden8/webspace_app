import 'package:webspace/services/host_lookup.dart';

/// Level 0 ("Off") names no list, so it is always resolvable without any
/// downloaded data.
const int kDnsLevelOff = 0;
const int kDnsMaxLevel = 5;

/// Bit a level occupies in a domain's membership mask.
int dnsLevelBit(int level) => 1 << (level - 1);

/// Blocked domains grouped by which severity levels name them.
///
/// The obvious compression — one "lowest level that names it" per domain,
/// blocking whenever that level is at or below the site's — assumes the
/// levels nest. They do not. Hagezi describes the five as building on each
/// other, but 21,921 of the 297,756 domains across them drop out of a higher
/// level: 1,455 are in Light and in nothing above it, 11,518 are in Normal
/// and not in Pro. Under the lowest-level model those would block at every
/// level above, so the app-wide level's behaviour would shift depending on
/// which per-site levels happened to be downloaded.
///
/// The mask is the exact model instead: a site at level N blocks a domain iff
/// level N's own list names it.
///
/// Groups are disjoint and keyed by the mask, so the entry count across all
/// of them is exactly the union of the downloaded lists — what a flat set of
/// that union would cost — and the group count is 1 while only one level is
/// downloaded, which is the case for anyone not using a per-site level.
class DnsLevelSets {
  DnsLevelSets._(this._groups, this.levels)
      : _masks = _groups.keys.toList(growable: false),
        _sets = _groups.values.toList(growable: false);

  /// Membership mask -> the domains carrying exactly that mask. Disjoint.
  final Map<int, Set<String>> _groups;

  /// The same groups as parallel lists. [maskOf] runs on every first sight of
  /// a host, and iterating the map there allocates an iterator per call —
  /// enough to show up against the flat-set lookup it replaces.
  final List<int> _masks;
  final List<Set<String>> _sets;

  /// Levels whose list has been folded in. A level absent here has no
  /// meaningful bit, which is why [resolveDnsLevel] refuses to run at it.
  final Set<int> levels;

  static final DnsLevelSets empty =
      DnsLevelSets._(const <int, Set<String>>{}, const <int>{});

  bool get isEmpty => _groups.values.every((group) => group.isEmpty);

  int get domainCount {
    var n = 0;
    for (final group in _groups.values) {
      n += group.length;
    }
    return n;
  }

  /// How many disjoint groups the downloaded levels resolve to. One while a
  /// single level is downloaded; the per-lookup cost scales with this.
  int get groupCount => _groups.length;

  /// Every blocked domain across every downloaded level, without
  /// materialising a union set.
  Iterable<String> get domains => _groups.values.expand((group) => group);

  /// The groups, for callers that need to ship the partition (the native
  /// push, the on-disk file).
  Map<int, Set<String>> get groups => _groups;

  /// Domains named by [level]'s own list.
  Iterable<String> domainsAtLevel(int level) {
    final bit = dnsLevelBit(level);
    return _groups.entries
        .where((e) => e.key & bit != 0)
        .expand((e) => e.value);
  }

  /// Which levels name [host] or a parent domain of it, as a mask. 0 when no
  /// downloaded list does.
  ///
  /// One number per host answers every level, so callers cache this once and
  /// let each site bit-test it. A parent domain's mask is unioned in: a rule
  /// on `example.com` covers `sub.example.com` at whatever levels name the
  /// parent.
  int maskOf(String host) {
    if (host.isEmpty) return 0;
    var mask = 0;
    for (var i = 0; i < _masks.length; i++) {
      final groupMask = _masks[i];
      if (mask & groupMask == groupMask) continue;
      if (hostInSet(host, _sets[i])) mask |= groupMask;
    }
    return mask;
  }

  bool blockedAt(String host, int level) {
    if (level <= kDnsLevelOff || level > kDnsMaxLevel) return false;
    return maskOf(host) & dnsLevelBit(level) != 0;
  }
}

/// Accumulates the level groups one level at a time.
///
/// Domains arrive one at a time rather than as a parsed set, so a level's raw
/// list is never materialised alongside what it is being folded into. The
/// builder does hold a flat domain -> mask map while it works — a domain's
/// group is not known until every level has been seen — which is a transient
/// peak during a rebuild, not steady state: the builder is a local of the
/// rebuild and everything it holds is dropped once [build] has cut the
/// groups.
class DnsLevelSetsBuilder {
  DnsLevelSetsBuilder();

  /// Start from an existing partition, so a newly downloaded level can be
  /// folded into what is already loaded instead of re-reading every level.
  DnsLevelSetsBuilder.from(DnsLevelSets existing) {
    _levels.addAll(existing.levels);
    existing._groups.forEach((mask, domains) {
      for (final domain in domains) {
        _mask[domain] = mask;
      }
    });
  }

  /// Domain -> mask under construction. Held flat while building because a
  /// domain's group is not known until every level has been seen; the groups
  /// are cut once, in [build].
  final Map<String, int> _mask = <String, int>{};
  final Set<int> _levels = <int>{};
  int _bit = 0;

  void startLevel(int level) {
    if (level < 1 || level > kDnsMaxLevel) {
      throw ArgumentError.value(level, 'level', 'not a blocklist level');
    }
    _bit = dnsLevelBit(level);
    _levels.add(level);
    // Re-adding a level replaces its membership rather than merging with
    // what a previous download of it said.
    if (_mask.isNotEmpty) {
      _mask.updateAll((_, mask) => mask & ~_bit);
    }
  }

  void add(String domain) {
    if (_bit == 0) throw StateError('startLevel() first');
    _mask[domain] = (_mask[domain] ?? 0) | _bit;
  }

  /// Drop [level] entirely: its bit is cleared and any domain no level names
  /// any more falls out.
  void dropLevel(int level) {
    if (!_levels.remove(level)) return;
    final bit = dnsLevelBit(level);
    _mask.removeWhere((_, mask) => mask & ~bit == 0);
    _mask.updateAll((_, mask) => mask & ~bit);
  }

  DnsLevelSets build() {
    final groups = <int, Set<String>>{};
    _mask.forEach((domain, mask) {
      if (mask == 0) return;
      (groups[mask] ??= <String>{}).add(domain);
    });
    return DnsLevelSets._(groups, Set<int>.unmodifiable(_levels));
  }
}

/// Level a site actually runs at.
///
/// A site level only means what it says when that level's list has been
/// downloaded — otherwise its bit means nothing and evaluating against the
/// mask would silently under-block. Falling back to the app-wide level keeps
/// the site at least as protected as it would have been without a per-site
/// setting at all.
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
