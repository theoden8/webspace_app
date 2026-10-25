import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_retention_priority.dart';

import 'helpers/retention_tiers.dart';

const resident = SiteLifecycleState.resident;
const cleared = SiteLifecycleState.cacheCleared;

void main() {
  group('evictionOrder', () {
    test('keeps the given order within a priority, past where List.sort is '
        'no longer stable', () {
      final loaded = [for (var i = 0; i < 100; i++) i];
      final order = evictionOrder(
        loaded,
        priorityOf: (i) => i.isEven
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
      final order = evictionOrder([0, 1, 2], priorityOf: tiers(active: {0, 2}));
      expect(order, [1]);
      for (final p in SiteRetentionPriority.values) {
        expect(evictionOrder([0], priorityOf: (_) => p).isEmpty, !p.evictable);
      }
    });
  });

  // PAUSE-012
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
}
