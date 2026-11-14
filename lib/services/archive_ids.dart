import 'package:webspace/settings/site_field.dart';
import 'package:webspace/settings/site_ids.dart';

/// An archive's sites as they join the lists, built from their sealed
/// records under the ids [ids] names them by: the one way an archive's
/// sites reach the lists, so none joins under an id a listed site holds.
final class Admitted<S> {
  Admitted._(
    this.sites, {
    required this.ids,
    required List<Map<String, dynamic>> records,
    required List<SiteId?> runsAs,
    required S Function(Map<String, dynamic> record) build,
  }) : _records = records,
       _runsAs = runsAs,
       _build = build;

  /// The sites, one per record, in order; [readmit] replaces the ones it
  /// renames.
  final List<S> sites;
  final ArchiveIds ids;
  final List<Map<String, dynamic>> _records;

  /// The id each record's site runs under, null for a record with none.
  final List<SiteId?> _runsAs;
  final S Function(Map<String, dynamic> record) _build;

  /// [records] as [build] makes them, each under its listed id, admitted
  /// against [listed].
  static Admitted<S> of<S>(
    List<Map<String, dynamic>> records, {
    required Set<SiteId> listed,
    required S Function(Map<String, dynamic> record) build,
    SiteId Function() mint = SiteId.mint,
  }) {
    final key = SiteField.siteId.key;
    final ids = ArchiveIds.admit(
      [for (final r in records) ?SiteId.parse(r[key])],
      listed: listed,
      mint: mint,
    );
    final admitted = ids.admitted.iterator;
    final sites = <S>[];
    final runsAs = <SiteId?>[];
    for (final r in records) {
      final sealed = SiteId.parse(r[key]);
      if (sealed != null && admitted.moveNext()) {
        final id = admitted.current;
        runsAs.add(id);
        sites.add(id != sealed ? build({...r, key: id}) : build(r));
      } else {
        runsAs.add(null);
        sites.add(build(r));
      }
    }
    return Admitted._(
      sites,
      ids: ids,
      records: records,
      runsAs: runsAs,
      build: build,
    );
  }

  /// Admits again, as the sites land, against the ids [listed] then: a site
  /// whose id a site listed since the admission holds runs under a fresh
  /// one, rebuilt from its record and renamed in [ids], its archived id and
  /// so its container, cookies and sealed record unchanged (ARCH-016,
  /// BUG-046). Returns each rebuilt site beside the one it replaces.
  List<({S was, S now})> readmit({
    required Set<SiteId> listed,
    SiteId Function() mint = SiteId.mint,
  }) {
    final key = SiteField.siteId.key;
    final rebuilt = <({S was, S now})>[];
    final taken = {
      ...listed,
      for (final id in _runsAs) ?id,
      ...ids._sealedAs.values,
    };
    for (var i = 0; i < sites.length; i++) {
      final id = _runsAs[i];
      if (id == null || !listed.contains(id)) continue;
      final fresh = ArchiveIds._fresh(taken, mint: mint);
      ids._rename(id, to: fresh);
      _runsAs[i] = fresh;
      final now = _build({..._records[i], key: fresh});
      rebuilt.add((was: sites[i], now: now));
      sites[i] = now;
    }
    return rebuilt;
  }
}

/// How an open archive's sites are named in the lists, and how they are
/// named in its sealed state (SEC-044, R8).
///
/// An archived site keeps the id it was sealed under, which an app-tier site
/// or another open archive's may hold too: a backup brought the app-tier site
/// back, or the archive was made from a copy. Two listed sites never share an
/// id, so one whose id is taken runs under a fresh one while its archive is
/// open; its container key, cookies and sealed record stay under the archived
/// id, so opening and closing an archive changes nothing it holds.
final class ArchiveIds {
  ArchiveIds._(this._sealedAs, {required this.admitted});

  /// Each of the archive's sites, from the id it runs under to the id it is
  /// sealed under.
  final Map<SiteId, SiteId> _sealedAs;

  /// The id each site passed to [ArchiveIds.admit] runs under, in order.
  final List<SiteId> admitted;

  /// [archived] named for the lists: each keeps its id unless a site in
  /// [listed] holds it already. A site sealed under the same id as one
  /// before it, which a build before ARCH-016 could seal, gets an id of its
  /// own to run and be sealed under, and so a container of its own.
  factory ArchiveIds.admit(
    Iterable<SiteId> archived, {
    required Set<SiteId> listed,
    SiteId Function() mint = SiteId.mint,
  }) {
    final ids = archived.toList();
    final taken = {...listed, ...ids};
    final seen = <SiteId>{};
    final sealedAs = <SiteId, SiteId>{};
    final admitted = <SiteId>[];
    for (final id in ids) {
      final SiteId runsAs;
      if (!seen.add(id)) {
        runsAs = _fresh(taken, mint: mint);
        sealedAs[runsAs] = runsAs;
      } else {
        runsAs = listed.contains(id) ? _fresh(taken, mint: mint) : id;
        sealedAs[runsAs] = id;
      }
      admitted.add(runsAs);
    }
    return ArchiveIds._(sealedAs, admitted: admitted);
  }

  static SiteId _fresh(Set<SiteId> taken, {required SiteId Function() mint}) {
    var fresh = mint();
    while (!taken.add(fresh)) {
      fresh = mint();
    }
    return fresh;
  }

  /// The id an archived site runs under while its archive is open.
  SiteId listed(SiteId archived) {
    for (final MapEntry(key: listed, value: id) in _sealedAs.entries) {
      if (id == archived) return listed;
    }
    return archived;
  }

  /// The id a listed site is sealed under.
  SiteId archived(SiteId listed) => _sealedAs[listed] ?? listed;

  /// A listed site moves into the archive: sealed under its own id, unless
  /// the archive seals another site under it already.
  SiteId enter(SiteId listed, {SiteId Function() mint = SiteId.mint}) {
    final sealed = _sealedAs.containsValue(listed)
        ? _fresh({..._sealedAs.keys, ..._sealedAs.values, listed}, mint: mint)
        : listed;
    _sealedAs[listed] = sealed;
    return sealed;
  }

  /// A site moves back out: the archive no longer names it.
  void forget(SiteId listed) => _sealedAs.remove(listed);

  /// The site that ran under [listed] runs under [to], sealed as before.
  void _rename(SiteId listed, {required SiteId to}) {
    final sealed = _sealedAs.remove(listed);
    assert(sealed != null, 'only an admitted site is renamed');
    _sealedAs[to] = sealed!;
    final i = admitted.indexOf(listed);
    if (i >= 0) admitted[i] = to;
  }
}
