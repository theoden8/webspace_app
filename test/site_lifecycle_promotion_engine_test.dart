import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';

void main() {
  group('SiteLifecyclePromotionEngine.nextState', () {
    test('live → cacheCleared', () {
      expect(
        SiteLifecyclePromotionEngine.nextState(SiteLifecycleState.resident),
        SiteLifecycleState.cacheCleared,
      );
    });

    test('cacheCleared → savedForRestore', () {
      expect(
        SiteLifecyclePromotionEngine.nextState(
            SiteLifecycleState.cacheCleared),
        SiteLifecycleState.savedForRestore,
      );
    });

    test('savedForRestore is terminal', () {
      expect(
        SiteLifecyclePromotionEngine.nextState(
            SiteLifecycleState.savedForRestore),
        isNull,
      );
    });
  });

  group('SiteLifecyclePromotionEngine.pickPromotionTarget', () {
    test('returns null when nothing is loaded', () {
      final result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: const {},
        states: const {},
      );
      expect(result, isNull);
    });

    test('returns oldest live site when all loaded are live', () {
      final loaded = <int>{};
      for (final i in [0, 1, 2]) {
        loaded.add(i);
      }
      final result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.resident,
          1: SiteLifecycleState.resident,
          2: SiteLifecycleState.resident,
        },
      );
      expect(result, 0);
    });

    test('treats missing state-map entries as live (default)', () {
      // Robustness: a site that hasn't had its state explicitly set
      // should default to live (not crash, not be skipped).
      final loaded = <int>{};
      loaded.add(0);
      final result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: loaded,
        states: const {},
      );
      expect(result, 0);
    });

    test('prefers live tier over cacheCleared (tier dominates LRU)', () {
      // Order: 0 (cacheCleared, oldest), 1 (cacheCleared), 2 (live, newest).
      // Engine returns 2 — even though it's the newest, it's at the
      // lowest non-terminal tier and gets promoted first. All live
      // sites become cacheCleared before any cacheCleared sites are
      // saved-for-restore.
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      loaded.add(2);
      final result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.cacheCleared,
          1: SiteLifecycleState.cacheCleared,
          2: SiteLifecycleState.resident,
        },
      );
      expect(result, 2);
    });

    test('falls through to cacheCleared when no live candidate', () {
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      final result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.cacheCleared,
          1: SiteLifecycleState.cacheCleared,
        },
      );
      expect(result, 0);
    });

    test('skips protected indices (e.g. active site)', () {
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      final result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.resident,
          1: SiteLifecycleState.resident,
        },
        protectedIndices: {0},
      );
      expect(result, 1);
    });

    test('returns null when every loaded site is protected', () {
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      final result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.resident,
          1: SiteLifecycleState.resident,
        },
        protectedIndices: {0, 1},
      );
      expect(result, isNull);
    });

    test('within a tier, prefers out-of-preferKeep over in-keep', () {
      final loaded = <int>{};
      loaded.add(0); // in-keep, oldest
      loaded.add(1); // out-of-keep, newer
      final result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.resident,
          1: SiteLifecycleState.resident,
        },
        preferKeepIndices: {0},
      );
      // out-of-keep wins within tier, even though newer.
      expect(result, 1);
    });

    test('tier dominates over preferKeep', () {
      // Out-of-keep cacheCleared vs in-keep live: live tier promotes
      // first, even though in-keep would normally be evicted later.
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      final result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.cacheCleared,
          1: SiteLifecycleState.resident,
        },
        preferKeepIndices: {1},
      );
      expect(result, 1);
    });

    test('skips savedForRestore (terminal — should not be in loaded)', () {
      // Defensive: if a savedForRestore site somehow appears in the
      // loadedIndices snapshot (caller error), the engine skips it.
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      final result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.savedForRestore,
          1: SiteLifecycleState.resident,
        },
      );
      expect(result, 1);
    });

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
      final loaded = <int>{};
      for (final i in [0, 1, 2, 3]) {
        loaded.add(i);
      }
      final states = <int, SiteLifecycleState>{
        0: SiteLifecycleState.resident,
        1: SiteLifecycleState.resident,
        2: SiteLifecycleState.resident,
        3: SiteLifecycleState.resident,
      };
      const protected = <int>{3};
      const preferKeep = <int>{1, 2, 3};

      var result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: loaded,
        states: states,
        protectedIndices: protected,
        preferKeepIndices: preferKeep,
      );
      expect(result, 0);
      states[0] = SiteLifecycleState.cacheCleared;

      result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: loaded,
        states: states,
        protectedIndices: protected,
        preferKeepIndices: preferKeep,
      );
      expect(result, 1);
      states[1] = SiteLifecycleState.cacheCleared;

      result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: loaded,
        states: states,
        protectedIndices: protected,
        preferKeepIndices: preferKeep,
      );
      expect(result, 2);
      states[2] = SiteLifecycleState.cacheCleared;

      // No more live sites. Engine should now pick at cacheCleared
      // tier — out-of-keep first, so 0.
      result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: loaded,
        states: states,
        protectedIndices: protected,
        preferKeepIndices: preferKeep,
      );
      expect(result, 0);
      states[0] = SiteLifecycleState.savedForRestore;
      // Caller also removes 0 from loadedIndices when it transitions
      // to savedForRestore (the webview is disposed at that point).
      loaded.remove(0);

      // Now {1, 2}, both in-keep cacheCleared.
      result = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: loaded,
        states: states,
        protectedIndices: protected,
        preferKeepIndices: preferKeep,
      );
      expect(result, 1);
    });
  });

  group('SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets', () {
    test('returns empty when count is at threshold', () {
      final loaded = <int>{};
      for (final i in [0, 1, 2]) {
        loaded.add(i);
      }
      final result = SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.resident,
          1: SiteLifecycleState.resident,
          2: SiteLifecycleState.resident,
        },
        maxResidentSites: 3,
      );
      expect(result, isEmpty);
    });

    test('returns empty when count is below threshold', () {
      final loaded = <int>{};
      for (final i in [0, 1]) {
        loaded.add(i);
      }
      final result = SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.resident,
          1: SiteLifecycleState.resident,
        },
        maxResidentSites: 5,
      );
      expect(result, isEmpty);
    });

    test('picks oldest excess to bring count back to threshold', () {
      // 5 resident sites, threshold 3 → excess 2, evict oldest 2.
      final loaded = <int>{};
      for (final i in [0, 1, 2, 3, 4]) {
        loaded.add(i);
      }
      final result = SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.resident,
          1: SiteLifecycleState.resident,
          2: SiteLifecycleState.resident,
          3: SiteLifecycleState.resident,
          4: SiteLifecycleState.resident,
        },
        maxResidentSites: 3,
      );
      expect(result, [0, 1]);
    });

    test('only counts resident-tier sites against the threshold', () {
      // 3 resident + 2 cacheCleared, threshold 3 → resident count is
      // 3, no excess. Returns empty.
      final loaded = <int>{};
      for (final i in [0, 1, 2, 3, 4]) {
        loaded.add(i);
      }
      final result = SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.cacheCleared,
          1: SiteLifecycleState.cacheCleared,
          2: SiteLifecycleState.resident,
          3: SiteLifecycleState.resident,
          4: SiteLifecycleState.resident,
        },
        maxResidentSites: 3,
      );
      expect(result, isEmpty);
    });

    test('skips already-cacheCleared sites in the result', () {
      // 4 resident + 1 cacheCleared, threshold 2 → resident excess 2.
      // Result picks 2 resident sites, never the already-cacheCleared.
      final loaded = <int>{};
      for (final i in [0, 1, 2, 3, 4]) {
        loaded.add(i);
      }
      final result = SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.cacheCleared, // already cleared
          1: SiteLifecycleState.resident,
          2: SiteLifecycleState.resident,
          3: SiteLifecycleState.resident,
          4: SiteLifecycleState.resident,
        },
        maxResidentSites: 2,
      );
      expect(result, [1, 2]);
    });

    test('skips protected indices', () {
      final loaded = <int>{};
      for (final i in [0, 1, 2, 3]) {
        loaded.add(i);
      }
      final result = SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.resident,
          1: SiteLifecycleState.resident,
          2: SiteLifecycleState.resident,
          3: SiteLifecycleState.resident,
        },
        maxResidentSites: 2,
        protectedIndices: {0},
      );
      // Protected (0) excluded; pick oldest 2 of {1, 2, 3} → [1, 2].
      expect(result, [1, 2]);
    });

    test('prefers out-of-keep over in-keep within excess budget', () {
      // 4 resident, threshold 2 → excess 2.
      // Active webspace = {0, 2}. Out-of-keep: [1, 3]. In-keep:
      // [0, 2]. Take 2 from out-of-keep → [1, 3].
      final loaded = <int>{};
      for (final i in [0, 1, 2, 3]) {
        loaded.add(i);
      }
      final result = SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.resident,
          1: SiteLifecycleState.resident,
          2: SiteLifecycleState.resident,
          3: SiteLifecycleState.resident,
        },
        maxResidentSites: 2,
        preferKeepIndices: {0, 2},
      );
      expect(result, [1, 3]);
    });

    test('falls through to in-keep when out-of-keep is exhausted', () {
      // 4 resident, threshold 1 → excess 3.
      // Active webspace = {1, 2, 3}. Out-of-keep: [0]. In-keep:
      // [1, 2, 3]. Take 0, then 1, 2.
      final loaded = <int>{};
      for (final i in [0, 1, 2, 3]) {
        loaded.add(i);
      }
      final result = SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.resident,
          1: SiteLifecycleState.resident,
          2: SiteLifecycleState.resident,
          3: SiteLifecycleState.resident,
        },
        maxResidentSites: 1,
        preferKeepIndices: {1, 2, 3},
      );
      expect(result, [0, 1, 2]);
    });

    test('respects LRU access-order bumps', () {
      // Loaded [0, 1, 2, 3]; bump 0 → [1, 2, 3, 0].
      // Threshold 2 → excess 2. Picks oldest in post-bump order:
      // [1, 2].
      final loaded = <int>{};
      for (final i in [0, 1, 2, 3]) {
        loaded.add(i);
      }
      loaded.remove(0);
      loaded.add(0);
      final result = SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.resident,
          1: SiteLifecycleState.resident,
          2: SiteLifecycleState.resident,
          3: SiteLifecycleState.resident,
        },
        maxResidentSites: 2,
      );
      expect(result, [1, 2]);
    });

    test('treats missing state-map entries as resident', () {
      // No state map provided — defaults to resident.
      // Threshold 1, 3 loaded → excess 2 → pick oldest [0, 1].
      final loaded = <int>{};
      for (final i in [0, 1, 2]) {
        loaded.add(i);
      }
      final result = SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
        loadedIndices: loaded,
        states: const {},
        maxResidentSites: 1,
      );
      expect(result, [0, 1]);
    });

    test('all resident protected returns empty', () {
      final loaded = <int>{};
      for (final i in [0, 1, 2]) {
        loaded.add(i);
      }
      final result = SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.resident,
          1: SiteLifecycleState.resident,
          2: SiteLifecycleState.resident,
        },
        maxResidentSites: 1,
        protectedIndices: {0, 1, 2},
      );
      expect(result, isEmpty);
    });
  });

  group('SiteLifecyclePromotionEngine.tierCounts', () {
    test('counts sites by tier with active accounted separately', () {
      final loaded = <int>{};
      for (final i in [0, 1, 2, 3, 4]) {
        loaded.add(i);
      }
      final counts = SiteLifecyclePromotionEngine.tierCounts(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.resident,
          1: SiteLifecycleState.resident,
          2: SiteLifecycleState.cacheCleared,
          3: SiteLifecycleState.cacheCleared,
          4: SiteLifecycleState.resident,
        },
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
      final loaded = <int>{};
      for (final i in [0, 1]) {
        loaded.add(i);
      }
      final counts = SiteLifecyclePromotionEngine.tierCounts(
        loadedIndices: loaded,
        states: {
          0: SiteLifecycleState.resident,
          1: SiteLifecycleState.resident,
          2: SiteLifecycleState.savedForRestore,
          3: SiteLifecycleState.savedForRestore,
        },
        activeIndex: null,
      );
      expect(counts.active, 0);
      expect(counts.resident, 2);
      expect(counts.cacheCleared, 0);
      expect(counts.savedForRestore, 2);
    });

    test('handles null activeIndex', () {
      final loaded = <int>{};
      loaded.add(0);
      final counts = SiteLifecyclePromotionEngine.tierCounts(
        loadedIndices: loaded,
        states: {0: SiteLifecycleState.resident},
        activeIndex: null,
      );
      expect(counts.active, 0);
      expect(counts.resident, 1);
    });
  });
}
