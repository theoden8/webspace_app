import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_retention_priority.dart';

import 'helpers/retention_tiers.dart';

const resident = SiteLifecycleState.resident;
const cleared = SiteLifecycleState.cacheCleared;
const saved = SiteLifecycleState.savedForRestore;

void main() {
  group('SiteLifecyclePromotionEngine.nextState', () {
    for (final (name, from, to) in [
      ('live → cacheCleared', resident, cleared),
      ('cacheCleared → savedForRestore', cleared, saved),
      ('savedForRestore is terminal', saved, null),
    ]) {
      test(name, () {
        expect(SiteLifecyclePromotionEngine.nextState(from), to);
      });
    }
  });

  group('evictionOrder', () {
    test('keeps the given order within a priority, past where List.sort is '
        'no longer stable', () {
      final loaded = [for (var i = 0; i < 100; i++) i];
      final order = evictionOrder(
        loaded,
        (i) => i.isEven
            ? SiteRetentionPriority.loaded
            : SiteRetentionPriority.webspace,
      );
      expect(order, [
        for (final i in loaded)
          if (i.isEven) i,
        for (final i in loaded)
          if (i.isOdd) i,
      ]);
    });

    test('never yields a site that is not evictable', () {
      final order = evictionOrder([0, 1, 2], tiers(active: {0, 2}));
      expect(order, [1]);
      for (final p in SiteRetentionPriority.values) {
        expect(evictionOrder([0], (_) => p).isEmpty, !p.evictable);
      }
    });
  });

  group('SiteLifecyclePromotionEngine.pickPromotionTarget', () {
    for (final c in [
      (name: 'returns null when nothing is loaded',
          loaded: <int>{}, states: const <int, SiteLifecycleState>{},
          tiers: tiers(), picks: null),
      (name: 'returns oldest live site when all loaded are live',
          loaded: {0, 1, 2}, states: {0: resident, 1: resident, 2: resident},
          tiers: tiers(), picks: 0),
      // Robustness: a site that hasn't had its state explicitly set
      // should default to live (not crash, not be skipped).
      (name: 'treats missing state-map entries as live (default)',
          loaded: {0}, states: const <int, SiteLifecycleState>{},
          tiers: tiers(), picks: 0),
      // Order: 0 (cacheCleared, oldest), 1 (cacheCleared), 2 (live, newest).
      // Engine returns 2 — even though it's the newest, it's at the
      // lowest non-terminal tier and gets promoted first. All live
      // sites become cacheCleared before any cacheCleared sites are
      // saved-for-restore.
      (name: 'prefers live tier over cacheCleared (tier dominates LRU)',
          loaded: {0, 1, 2}, states: {0: cleared, 1: cleared, 2: resident},
          tiers: tiers(), picks: 2),
      (name: 'falls through to cacheCleared when no live candidate',
          loaded: {0, 1}, states: {0: cleared, 1: cleared},
          tiers: tiers(), picks: 0),
      (name: 'skips protected indices (e.g. active site)',
          loaded: {0, 1}, states: {0: resident, 1: resident},
          tiers: tiers(active: {0}), picks: 1),
      (name: 'returns null when every loaded site is protected',
          loaded: {0, 1}, states: {0: resident, 1: resident},
          tiers: tiers(active: {0, 1}), picks: null),
      // 0 is in-keep and oldest, 1 out-of-keep and newer: out-of-keep wins
      // within the tier, even though newer.
      (name: 'within a tier, prefers out-of-preferKeep over in-keep',
          loaded: {0, 1}, states: {0: resident, 1: resident},
          tiers: tiers(keep: {0}), picks: 1),
      // Out-of-keep cacheCleared vs in-keep live: live tier promotes
      // first, even though in-keep would normally be evicted later.
      (name: 'tier dominates over preferKeep',
          loaded: {0, 1}, states: {0: cleared, 1: resident},
          tiers: tiers(keep: {1}), picks: 1),
      // Defensive: if a savedForRestore site somehow appears in the
      // loadedIndices snapshot (caller error), the engine skips it.
      (name: 'skips savedForRestore (terminal — should not be in loaded)',
          loaded: {0, 1}, states: {0: saved, 1: resident},
          tiers: tiers(), picks: 1),
    ]) {
      test(c.name, () {
        expect(
          SiteLifecyclePromotionEngine.pickPromotionTarget(
            loadedIndices: c.loaded,
            states: c.states,
            priorityOf: c.tiers,
          ),
          c.picks,
        );
      });
    }

    test('cascade walks the full hierarchy across successive promotions', () {
      // 4 loaded sites in LRU order [0, 1, 2, 3]. Active (3) is
      // protected. Active webspace = {1, 2, 3}; site 0 is out-of-keep.
      // Initial state: all live.
      //
      // Cascade steps the caller would observe:
      //   1. Pick 0 (out-of-keep live, oldest at lowest tier).
      //      Caller promotes: state[0] = cacheCleared.
      //   2. Pick 1 (in-keep live, oldest live remaining).
      //      state[1] = cacheCleared.
      //   3. Pick 2 (in-keep live, oldest live remaining).
      //      state[2] = cacheCleared.
      //   4. Pick 0 (out-of-keep cacheCleared, oldest at next tier).
      //      state[0] = savedForRestore. Caller would also remove
      //      from loadedIndices at this point.
      //   ...
      final loaded = {0, 1, 2, 3};
      final states = {0: resident, 1: resident, 2: resident, 3: resident};
      int? pick() => SiteLifecyclePromotionEngine.pickPromotionTarget(
            loadedIndices: loaded,
            states: states,
            priorityOf: tiers(active: {3}, keep: {1, 2, 3}),
          );

      expect(pick(), 0);
      states[0] = cleared;
      expect(pick(), 1);
      states[1] = cleared;
      expect(pick(), 2);
      states[2] = cleared;

      // No more live sites. Engine should now pick at cacheCleared
      // tier — out-of-keep first, so 0.
      expect(pick(), 0);
      states[0] = saved;
      // Caller also removes 0 from loadedIndices when it transitions
      // to savedForRestore (the webview is disposed at that point).
      loaded.remove(0);

      // Now {1, 2}, both in-keep cacheCleared.
      expect(pick(), 1);
    });
  });

  group('SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets', () {
    final four = {0: resident, 1: resident, 2: resident, 3: resident};
    for (final c in [
      (name: 'returns empty when count is at threshold',
          loaded: {0, 1, 2}, states: {0: resident, 1: resident, 2: resident},
          max: 3, tiers: tiers(), picks: isEmpty),
      (name: 'returns empty when count is below threshold',
          loaded: {0, 1}, states: {0: resident, 1: resident},
          max: 5, tiers: tiers(), picks: isEmpty),
      // 5 resident sites, threshold 3 → excess 2, evict oldest 2.
      (name: 'picks oldest excess to bring count back to threshold',
          loaded: {0, 1, 2, 3, 4},
          states: {0: resident, 1: resident, 2: resident, 3: resident, 4: resident},
          max: 3, tiers: tiers(), picks: [0, 1]),
      // 3 resident + 2 cacheCleared, threshold 3 → resident count is
      // 3, no excess. Returns empty.
      (name: 'only counts resident-tier sites against the threshold',
          loaded: {0, 1, 2, 3, 4},
          states: {0: cleared, 1: cleared, 2: resident, 3: resident, 4: resident},
          max: 3, tiers: tiers(), picks: isEmpty),
      // 4 resident + 1 cacheCleared, threshold 2 → resident excess 2.
      // Result picks 2 resident sites, never the already-cacheCleared.
      (name: 'skips already-cacheCleared sites in the result',
          loaded: {0, 1, 2, 3, 4},
          states: {0: cleared, 1: resident, 2: resident, 3: resident, 4: resident},
          max: 2, tiers: tiers(), picks: [1, 2]),
      // Protected (0) excluded; pick oldest 2 of {1, 2, 3} → [1, 2].
      (name: 'skips protected indices',
          loaded: {0, 1, 2, 3}, states: four,
          max: 2, tiers: tiers(active: {0}), picks: [1, 2]),
      // 4 resident, threshold 2 → excess 2.
      // Active webspace = {0, 2}. Out-of-keep: [1, 3]. In-keep:
      // [0, 2]. Take 2 from out-of-keep → [1, 3].
      (name: 'prefers out-of-keep over in-keep within excess budget',
          loaded: {0, 1, 2, 3}, states: four,
          max: 2, tiers: tiers(keep: {0, 2}), picks: [1, 3]),
      // 4 resident, threshold 1 → excess 3.
      // Active webspace = {1, 2, 3}. Out-of-keep: [0]. In-keep:
      // [1, 2, 3]. Take 0, then 1, 2.
      (name: 'falls through to in-keep when out-of-keep is exhausted',
          loaded: {0, 1, 2, 3}, states: four,
          max: 1, tiers: tiers(keep: {1, 2, 3}), picks: [0, 1, 2]),
      // Loaded [0, 1, 2, 3]; bump 0 → [1, 2, 3, 0].
      // Threshold 2 → excess 2. Picks oldest in post-bump order:
      // [1, 2].
      (name: 'respects LRU access-order bumps',
          loaded: {1, 2, 3, 0}, states: four,
          max: 2, tiers: tiers(), picks: [1, 2]),
      // No state map provided — defaults to resident.
      // Threshold 1, 3 loaded → excess 2 → pick oldest [0, 1].
      (name: 'treats missing state-map entries as resident',
          loaded: {0, 1, 2}, states: const <int, SiteLifecycleState>{},
          max: 1, tiers: tiers(), picks: [0, 1]),
      (name: 'all resident protected returns empty',
          loaded: {0, 1, 2}, states: {0: resident, 1: resident, 2: resident},
          max: 1, tiers: tiers(active: {0, 1, 2}), picks: isEmpty),
    ]) {
      test(c.name, () {
        expect(
          SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
            loadedIndices: c.loaded,
            states: c.states,
            maxResidentSites: c.max,
            priorityOf: c.tiers,
          ),
          c.picks,
        );
      });
    }
  });

  group('SiteLifecyclePromotionEngine.tierCounts', () {
    test('counts sites by tier with active accounted separately', () {
      final counts = SiteLifecyclePromotionEngine.tierCounts(
        loadedIndices: {0, 1, 2, 3, 4},
        states: {0: resident, 1: resident, 2: cleared, 3: cleared, 4: resident},
        activeIndex: 4,
      );
      expect(counts.active, 1);
      expect(counts.resident, 2); // 0 and 1; 4 is active and excluded
      expect(counts.cacheCleared, 2);
      expect(counts.savedForRestore, 0);
    });

    test('savedForRestore tracked per-state-map regardless of loaded set',
        () {
      // savedForRestore sites are NOT in loadedIndices (their webviews
      // are disposed). The counter inspects the state map directly so
      // callers can monitor pressure-induced disposal.
      final counts = SiteLifecyclePromotionEngine.tierCounts(
        loadedIndices: {0, 1},
        states: {0: resident, 1: resident, 2: saved, 3: saved},
        activeIndex: null,
      );
      expect(counts.active, 0);
      expect(counts.resident, 2);
      expect(counts.cacheCleared, 0);
      expect(counts.savedForRestore, 2);
    });

    test('handles null activeIndex', () {
      final counts = SiteLifecyclePromotionEngine.tierCounts(
        loadedIndices: {0},
        states: {0: resident},
        activeIndex: null,
      );
      expect(counts.active, 0);
      expect(counts.resident, 1);
    });
  });
}
