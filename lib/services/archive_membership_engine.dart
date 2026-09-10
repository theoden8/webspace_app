import 'package:webspace/webspace_model.dart';

/// Moves the membership of archived sites between app-tier webspaces and
/// the archive's own encrypted state, so no archived `siteId` ever reaches
/// the plaintext `webspaces` pref or a backup file (ARCH-001).
///
/// The runtime `Webspace.siteIds` list still carries archived ids while the
/// archive is open (so the drawer shows them in their collections); the
/// persisted form is produced by [persistable].
class ArchiveMembershipEngine {
  ArchiveMembershipEngine._();

  /// Which app-tier webspaces currently contain each id in [siteIds], as
  /// `{webspaceId: [siteIds]}`, merged into [existing] when given. Does not
  /// mutate the webspaces.
  static Map<String, List<String>> record(
    List<Webspace> webspaces,
    Set<String> siteIds, {
    Map<String, List<String>>? existing,
  }) {
    final out = <String, List<String>>{
      if (existing != null)
        for (final e in existing.entries) e.key: List<String>.from(e.value),
    };
    for (final ws in webspaces) {
      if (ws.isArchiveTier || ws.isAll) continue;
      final members = [
        for (final sid in ws.siteIds)
          if (siteIds.contains(sid)) sid,
      ];
      if (members.isEmpty) continue;
      final bucket = out.putIfAbsent(ws.id, () => <String>[]);
      for (final sid in members) {
        if (!bucket.contains(sid)) bucket.add(sid);
      }
    }
    return out;
  }

  /// [record] followed by stripping [siteIds] from every app-tier
  /// webspace's runtime list. Used when the archived sites leave the
  /// runtime list (archive close).
  static Map<String, List<String>> detach(
    List<Webspace> webspaces,
    Set<String> siteIds, {
    Map<String, List<String>>? existing,
  }) {
    final out = record(webspaces, siteIds, existing: existing);
    for (final ws in webspaces) {
      if (ws.isArchiveTier || ws.isAll) continue;
      ws.siteIds.removeWhere(siteIds.contains);
    }
    return out;
  }

  /// Re-inserts [membership] (as produced by [record]) into the matching
  /// app-tier webspaces' runtime `siteIds`. Ids already present are not
  /// duplicated; webspaces that no longer exist are skipped.
  static void attach(
    List<Webspace> webspaces,
    Map<String, List<String>> membership,
  ) {
    for (final ws in webspaces) {
      if (ws.isArchiveTier || ws.isAll) continue;
      final ids = membership[ws.id];
      if (ids == null) continue;
      for (final sid in ids) {
        if (!ws.siteIds.contains(sid)) ws.siteIds.add(sid);
      }
    }
  }

  /// Drops [siteId] from every bucket of [membership], removing buckets
  /// that become empty. Used when a site is moved back out of an archive.
  static void forget(Map<String, List<String>> membership, String siteId) {
    for (final ids in membership.values) {
      ids.remove(siteId);
    }
    membership.removeWhere((_, ids) => ids.isEmpty);
  }

  /// The app-tier webspaces as they may be written to plaintext storage or
  /// a backup: archive-tier collections dropped, and every id in
  /// [archivedSiteIds] stripped from the remaining membership lists.
  static List<Webspace> persistable(
    List<Webspace> webspaces,
    Set<String> archivedSiteIds,
  ) {
    return [
      for (final ws in webspaces)
        if (!ws.isArchiveTier)
          ws.copyWith(
            siteIds: [
              for (final sid in ws.siteIds)
                if (!archivedSiteIds.contains(sid)) sid,
            ],
          ),
    ];
  }
}
