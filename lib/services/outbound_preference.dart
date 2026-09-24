import 'package:webspace/services/domain_claim.dart';

/// One outbound routing rule of a site (LIR-013): a link the site opens that
/// [claim] covers goes to the site [targetSiteId]. Lives beside
/// `domain_claim.dart` for the same import-cycle reason that file does.
class OutboundPreference {
  final DomainClaim claim;
  final String targetSiteId;

  const OutboundPreference({required this.claim, required this.targetSiteId});

  Map<String, dynamic> toJson() => {
        'claim': claim.toJson(),
        'targetSiteId': targetSiteId,
      };

  /// Null for an entry that cannot route anywhere: no claim value, an unknown
  /// claim kind, or no target. A hand-edited backup loses that entry, never
  /// the site (BACKUP-014).
  static OutboundPreference? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final claimRaw = raw['claim'];
    final target = raw['targetSiteId'];
    if (claimRaw is! Map || target is! String || target.isEmpty) return null;
    final kindName = claimRaw['kind'];
    final value = claimRaw['value'];
    if (kindName is! String || value is! String) return null;
    DomainClaimKind? kind;
    for (final k in DomainClaimKind.values) {
      if (k.name == kindName) kind = k;
    }
    if (kind == null) return null;
    final claim = DomainClaim(kind, value);
    if (claim.value.isEmpty) return null;
    return OutboundPreference(claim: claim, targetSiteId: target);
  }

  /// [prefs] with at most one entry per claim, the first kept, so "which
  /// site does this claim route to" always has one answer.
  static List<OutboundPreference> dedupedByClaim(
    Iterable<OutboundPreference> prefs,
  ) {
    final seen = <DomainClaim>{};
    return [
      for (final p in prefs)
        if (seen.add(p.claim)) p,
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is OutboundPreference &&
      other.claim == claim &&
      other.targetSiteId == targetSiteId;

  @override
  int get hashCode => Object.hash(claim, targetSiteId);

  @override
  String toString() => 'OutboundPreference($claim -> $targetSiteId)';
}

/// LIR-014's candidate rule: a link routes only to a site on its source's
/// side of the archive boundary (ARCH-001, ARCH-006).
class OutboundBoundary {
  OutboundBoundary._();

  /// The sites of [sites] that [source] may route to: every app-tier site
  /// for an app-tier source, the sites of the same open archive for an
  /// archive-tier one. [archiveOf] names the archive an archive-tier site
  /// belongs to; an archive-tier source it cannot place gets none.
  static List<T> candidatesOf<T>(
    T source,
    Iterable<T> sites, {
    required bool Function(T site) isArchiveTier,
    required Object? Function(T site) archiveOf,
  }) {
    if (!isArchiveTier(source)) {
      return [
        for (final s in sites)
          if (!isArchiveTier(s)) s,
      ];
    }
    final archive = archiveOf(source);
    if (archive == null) return <T>[];
    return [
      for (final s in sites)
        if (isArchiveTier(s) && archiveOf(s) == archive) s,
    ];
  }
}

/// Orphan cleanup for outbound preferences (LIR-017). Pure: the caller says
/// which targets each site may still route to and applies the result.
class OutboundPreferenceGc {
  OutboundPreferenceGc._();

  /// [prefs] without the entries whose target [isCandidate] rejects, or null
  /// when nothing would be dropped, so a caller persists only on a change.
  static List<OutboundPreference>? pruned(
    List<OutboundPreference> prefs,
    bool Function(String targetSiteId) isCandidate,
  ) {
    if (prefs.every((p) => isCandidate(p.targetSiteId))) return null;
    return [
      for (final p in prefs)
        if (isCandidate(p.targetSiteId)) p,
    ];
  }

  /// Prune every site in [sites] against [OutboundBoundary.candidatesOf]
  /// over the same list; true when any list changed.
  static bool pruneAcrossBoundary<T>(
    List<T> sites, {
    required String Function(T site) siteIdOf,
    required bool Function(T site) isArchiveTier,
    required Object? Function(T site) archiveOf,
    required List<OutboundPreference> Function(T site) prefsOf,
    required void Function(T site, List<OutboundPreference> prefs) setPrefs,
  }) {
    final idsBySource = <String, Set<String>>{};
    return pruneAll<T>(
      sites,
      prefsOf: prefsOf,
      setPrefs: setPrefs,
      isCandidate: (source, id) => idsBySource
          .putIfAbsent(siteIdOf(source), () => {
                for (final c in OutboundBoundary.candidatesOf(
                  source,
                  sites,
                  isArchiveTier: isArchiveTier,
                  archiveOf: archiveOf,
                ))
                  siteIdOf(c),
              })
          .contains(id),
    );
  }

  /// Prune every site in [sites]; true when any list changed.
  static bool pruneAll<T>(
    Iterable<T> sites, {
    required List<OutboundPreference> Function(T site) prefsOf,
    required void Function(T site, List<OutboundPreference> prefs) setPrefs,
    required bool Function(T source, String targetSiteId) isCandidate,
  }) {
    var changed = false;
    for (final site in sites) {
      final next = pruned(prefsOf(site), (id) => isCandidate(site, id));
      if (next == null) continue;
      setPrefs(site, next);
      changed = true;
    }
    return changed;
  }
}
