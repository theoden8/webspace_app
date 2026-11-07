import 'package:webspace/settings/site_field.dart';
import 'package:webspace/settings/site_ids.dart';

/// An archive's sites as they join the lists, built from their sealed
/// records under the ids [ids] names them by: the one way an archive's
/// sites reach the lists, so none joins under an id a listed site holds.
final class Admitted<S> {
  Admitted._(this.sites, {required this.ids});

  final List<S> sites;
  final ArchiveIds ids;

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
      [
        for (final r in records)
          if (SiteId.parse(r[key]) case final id?) id,
      ],
      listed: listed,
      mint: mint,
    );
    return Admitted._(ids: ids, [
      for (final r in records)
        build(switch (SiteId.parse(r[key])) {
          final id? when ids.listed(id) != id => {...r, key: ids.listed(id)},
          _ => r,
        }),
    ]);
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
  ArchiveIds._(this._sealedAs);

  /// Each of the archive's sites, from the id it runs under to the id it is
  /// sealed under.
  final Map<SiteId, SiteId> _sealedAs;

  /// [archived] named for the lists: each keeps its id unless a site in
  /// [listed], or one admitted before it, holds it already.
  factory ArchiveIds.admit(
    Iterable<SiteId> archived, {
    required Set<SiteId> listed,
    SiteId Function() mint = SiteId.mint,
  }) {
    final taken = {...listed};
    final sealedAs = <SiteId, SiteId>{};
    for (final id in archived) {
      final runsAs = taken.add(id) ? id : _fresh(taken, mint: mint);
      sealedAs[runsAs] = id;
    }
    return ArchiveIds._(sealedAs);
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

  /// Every listed id its site is not sealed under.
  Iterable<SiteId> get renamed => [
        for (final MapEntry(key: listed, value: archived)
            in _sealedAs.entries)
          if (listed != archived) listed,
      ];

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
}
