import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

WebViewModel _site(String url, {UserProxySettings? proxy}) =>
    WebViewModel(initUrl: url, proxySettings: proxy);

void main() {
  setUp(() {
    GlobalOutboundProxy.resetForTest();
  });

  group('SiteUnloadEngine.indicesToUnloadOnWebspaceSwitch', () {
    test('returns empty under container mode (sites stay resident)', () {
      final result = SiteUnloadEngine.indicesToUnloadOnWebspaceSwitch(
        useContainers: true,
        loadedIndices: {0, 1, 2},
        previousWebspaceIndices: {0, 1},
        newWebspaceIndices: {2, 3},
      );
      expect(result, isEmpty);
    });

    test('container mode short-circuits even with no overlap', () {
      // Worst case for legacy (every loaded site leaves the visible set);
      // container mode still keeps them all.
      final result = SiteUnloadEngine.indicesToUnloadOnWebspaceSwitch(
        useContainers: true,
        loadedIndices: {0, 1, 2},
        previousWebspaceIndices: {0, 1, 2},
        newWebspaceIndices: {3, 4, 5},
      );
      expect(result, isEmpty);
    });

    test('legacy mode unloads sites visible only in previous webspace', () {
      final result = SiteUnloadEngine.indicesToUnloadOnWebspaceSwitch(
        useContainers: false,
        loadedIndices: {0, 1, 2},
        previousWebspaceIndices: {0, 1},
        newWebspaceIndices: {2, 3},
      );
      expect(result, {0, 1});
    });

    test('legacy mode preserves sites visible in both webspaces', () {
      final result = SiteUnloadEngine.indicesToUnloadOnWebspaceSwitch(
        useContainers: false,
        loadedIndices: {0, 1, 2},
        previousWebspaceIndices: {0, 1, 2},
        newWebspaceIndices: {1, 2, 3},
      );
      expect(result, {0});
    });

    test('legacy mode no-op when no loaded sites in previous webspace', () {
      final result = SiteUnloadEngine.indicesToUnloadOnWebspaceSwitch(
        useContainers: false,
        loadedIndices: {5, 6},
        previousWebspaceIndices: {0, 1},
        newWebspaceIndices: {2, 3},
      );
      expect(result, isEmpty);
    });

    test('legacy mode no-op on empty loadedIndices', () {
      final result = SiteUnloadEngine.indicesToUnloadOnWebspaceSwitch(
        useContainers: false,
        loadedIndices: const {},
        previousWebspaceIndices: {0, 1, 2},
        newWebspaceIndices: {3, 4},
      );
      expect(result, isEmpty);
    });
  });

  group('SiteUnloadEngine.indicesToUnloadForProxyMismatch', () {
    test('returns empty when proxy is per-site (iOS/macOS)', () {
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p1:8080')),
        _site('https://b.example.com',
            proxy: UserProxySettings(type: ProxyType.SOCKS5, address: 'p2:9050')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 1,
        models: models,
        loadedIndices: {0, 1},
        proxyIsGlobal: false,
      );
      expect(result, isEmpty);
    });

    test('flags loaded sites with a different proxy on Android', () {
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p1:8080')),
        _site('https://b.example.com',
            proxy: UserProxySettings(type: ProxyType.SOCKS5, address: 'p2:9050')),
        _site('https://c.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p1:8080')),
      ];
      // Activating index 1 (SOCKS5) — index 0 (HTTP p1) and index 2 (HTTP p1)
      // must be unloaded; their next request would silently route through
      // p2 once `ProxyController.setProxyOverride` lands the new override.
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 1,
        models: models,
        loadedIndices: {0, 1, 2},
        proxyIsGlobal: true,
      );
      expect(result, {0, 2});
    });

    test('does not flag the activating site itself', () {
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p1:8080')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 0,
        models: models,
        loadedIndices: {0},
        proxyIsGlobal: true,
      );
      expect(result, isEmpty);
    });

    test('does not flag sites with the same proxy', () {
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p1:8080')),
        _site('https://b.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p1:8080')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 0,
        models: models,
        loadedIndices: {0, 1},
        proxyIsGlobal: true,
      );
      expect(result, isEmpty);
    });

    test('two DEFAULT sites are equivalent regardless of global proxy', () {
      // Both fall through resolveEffectiveProxy to the global outbound
      // proxy, so they resolve to the same effective value.
      GlobalOutboundProxy.setForTest(
        UserProxySettings(type: ProxyType.SOCKS5, address: 'tor:9050'),
      );
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(type: ProxyType.DEFAULT)),
        _site('https://b.example.com',
            proxy: UserProxySettings(type: ProxyType.DEFAULT)),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 1,
        models: models,
        loadedIndices: {0, 1},
        proxyIsGlobal: true,
      );
      expect(result, isEmpty);
    });

    test('DEFAULT vs explicit-matching-global is equivalent', () {
      GlobalOutboundProxy.setForTest(
        UserProxySettings(type: ProxyType.HTTP, address: 'gp:1234'),
      );
      final models = [
        // Resolves through the global proxy.
        _site('https://a.example.com',
            proxy: UserProxySettings(type: ProxyType.DEFAULT)),
        // Set explicitly to the same value the global proxy provides.
        _site('https://b.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'gp:1234')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 0,
        models: models,
        loadedIndices: {0, 1},
        proxyIsGlobal: true,
      );
      expect(result, isEmpty);
    });

    test('flags credential-only differences', () {
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(
                type: ProxyType.HTTP,
                address: 'p:8080',
                username: 'alice',
                password: 'a-pw')),
        _site('https://b.example.com',
            proxy: UserProxySettings(
                type: ProxyType.HTTP,
                address: 'p:8080',
                username: 'bob',
                password: 'b-pw')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 1,
        models: models,
        loadedIndices: {0, 1},
        proxyIsGlobal: true,
      );
      expect(result, {0});
    });

    test('flags type-only differences (HTTP vs SOCKS5, same address)', () {
      // Same host:port string but different protocol — the wire format
      // is fundamentally different (CONNECT tunnel vs SOCKS handshake),
      // so a request that thinks it's going to one will fail on the
      // other. Must be treated as a mismatch.
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p:9050')),
        _site('https://b.example.com',
            proxy: UserProxySettings(
                type: ProxyType.SOCKS5, address: 'p:9050')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 1,
        models: models,
        loadedIndices: {0, 1},
        proxyIsGlobal: true,
      );
      expect(result, {0});
    });

    test('flags HTTP vs HTTPS (different schemes)', () {
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p:8080')),
        _site('https://b.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTPS, address: 'p:8080')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 1,
        models: models,
        loadedIndices: {0, 1},
        proxyIsGlobal: true,
      );
      expect(result, {0});
    });

    test('flags address-only differences (host)', () {
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p1:8080')),
        _site('https://b.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p2:8080')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 1,
        models: models,
        loadedIndices: {0, 1},
        proxyIsGlobal: true,
      );
      expect(result, {0});
    });

    test('flags address-only differences (port)', () {
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p:8080')),
        _site('https://b.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p:9090')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 1,
        models: models,
        loadedIndices: {0, 1},
        proxyIsGlobal: true,
      );
      expect(result, {0});
    });

    test('flags username-only differences', () {
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(
                type: ProxyType.HTTP,
                address: 'p:8080',
                username: 'alice',
                password: 'shared-pw')),
        _site('https://b.example.com',
            proxy: UserProxySettings(
                type: ProxyType.HTTP,
                address: 'p:8080',
                username: 'bob',
                password: 'shared-pw')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 1,
        models: models,
        loadedIndices: {0, 1},
        proxyIsGlobal: true,
      );
      expect(result, {0});
    });

    test('flags password-only differences', () {
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(
                type: ProxyType.HTTP,
                address: 'p:8080',
                username: 'shared',
                password: 'pw1')),
        _site('https://b.example.com',
            proxy: UserProxySettings(
                type: ProxyType.HTTP,
                address: 'p:8080',
                username: 'shared',
                password: 'pw2')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 1,
        models: models,
        loadedIndices: {0, 1},
        proxyIsGlobal: true,
      );
      expect(result, {0});
    });

    test('null and absent credentials are equivalent', () {
      // Both sites: same type/address, no credentials. Different
      // construction paths (UserProxySettings(...) vs default ctor) but
      // the field values match.
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(
                type: ProxyType.HTTP,
                address: 'p:8080',
                username: null,
                password: null)),
        _site('https://b.example.com',
            proxy: UserProxySettings(
                type: ProxyType.HTTP, address: 'p:8080')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 1,
        models: models,
        loadedIndices: {0, 1},
        proxyIsGlobal: true,
      );
      expect(result, isEmpty);
    });

    test('flags DEFAULT vs explicit-non-matching-global', () {
      // Site 0 = DEFAULT → resolves through global (HTTP gp:1234).
      // Site 1 = explicit SOCKS5. Different effective proxy.
      GlobalOutboundProxy.setForTest(
        UserProxySettings(type: ProxyType.HTTP, address: 'gp:1234'),
      );
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(type: ProxyType.DEFAULT)),
        _site('https://b.example.com',
            proxy: UserProxySettings(
                type: ProxyType.SOCKS5, address: 'tor:9050')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 1,
        models: models,
        loadedIndices: {0, 1},
        proxyIsGlobal: true,
      );
      expect(result, {0});
    });

    test('only conflicting indices are returned, not all loaded', () {
      // Mix: site 0 matches target, site 2 differs. Activating target
      // (index 1) should unload only 2, not 0.
      GlobalOutboundProxy.resetForTest();
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p:8080')),
        _site('https://b.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p:8080')),
        _site('https://c.example.com',
            proxy: UserProxySettings(
                type: ProxyType.SOCKS5, address: 'tor:9050')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 1,
        models: models,
        loadedIndices: {0, 1, 2},
        proxyIsGlobal: true,
      );
      expect(result, {2});
    });

    test('skips out-of-bounds entries in loadedIndices', () {
      // Mock state where _loadedIndices contains a stale index past
      // the end of models (e.g. mid-deletion race). Engine must not
      // throw a RangeError.
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p:8080')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 0,
        models: models,
        loadedIndices: {0, 99, -1},
        proxyIsGlobal: true,
      );
      expect(result, isEmpty);
    });

    test('out-of-bounds target returns empty', () {
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 5,
        models: const [],
        loadedIndices: const {},
        proxyIsGlobal: true,
      );
      expect(result, isEmpty);
    });

    test('negative target returns empty', () {
      final models = [
        _site('https://a.example.com',
            proxy: UserProxySettings(type: ProxyType.HTTP, address: 'p:8080')),
      ];
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: -1,
        models: models,
        loadedIndices: {0},
        proxyIsGlobal: true,
      );
      expect(result, isEmpty);
    });
  });

  group('SiteUnloadEngine.indicesToEvictForLruCap', () {
    test('returns empty when within cap', () {
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 3,
        loadedIndices: {0, 1, 2},
        maxLoadedSites: 5,
      );
      expect(result, isEmpty);
    });

    test('evicts oldest when adding target overflows cap', () {
      // LinkedHashSet preserves insertion order; iteration is LRU-first.
      // Loaded order: 0 (oldest), 1, 2. Activating index 3 would make 4
      // loaded; cap is 3, so the oldest (0) is evicted.
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      loaded.add(2);
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 3,
        loadedIndices: loaded,
        maxLoadedSites: 3,
      );
      expect(result, [0]);
    });

    test('evicts multiple when overflow > 1', () {
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      loaded.add(2);
      loaded.add(3);
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 4,
        loadedIndices: loaded,
        maxLoadedSites: 2,
      );
      expect(result, [0, 1, 2]);
    });

    test('skips the target index even at the front of loaded order', () {
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      loaded.add(2);
      // Re-activating index 0 doesn't add a new slot — projected count is
      // still 3, so no eviction needed at cap=3.
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 0,
        loadedIndices: loaded,
        maxLoadedSites: 3,
      );
      expect(result, isEmpty);
    });

    test('skips protected indices (e.g. currently active site)', () {
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      loaded.add(2);
      // Cap is 2, projected is 4 with new index 3 → overflow 2. With
      // index 0 protected, the engine should evict 1 and 2 instead.
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 3,
        loadedIndices: loaded,
        maxLoadedSites: 2,
        protectedIndices: {0},
      );
      expect(result, [1, 2]);
    });

    test('respects access-order updates (LRU semantics)', () {
      // Caller bumps re-activated sites to the end. After visiting 0, 1,
      // 2, then re-visiting 0, the order becomes 1, 2, 0 — so the next
      // overflow evicts 1, not 0.
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      loaded.add(2);
      // Bump 0 (re-activation).
      loaded.remove(0);
      loaded.add(0);
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 3,
        loadedIndices: loaded,
        maxLoadedSites: 3,
      );
      expect(result, [1]);
    });

    test('eviction order respects multiple bumps', () {
      // Activations in order: 0, 1, 2, 3 — then 1 bumped, then 0 bumped.
      // Final order: 2, 3, 1, 0. Cap=2 with new index 4 → overflow 3,
      // evict 2, 3, 1 (oldest three) and keep 0 + new 4.
      final loaded = <int>{};
      for (final i in [0, 1, 2, 3]) {
        loaded.add(i);
      }
      loaded.remove(1);
      loaded.add(1);
      loaded.remove(0);
      loaded.add(0);
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 4,
        loadedIndices: loaded,
        maxLoadedSites: 2,
      );
      expect(result, [2, 3, 1]);
    });

    test('empty loadedIndices needs no eviction', () {
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 0,
        loadedIndices: const {},
        maxLoadedSites: 5,
      );
      expect(result, isEmpty);
    });

    test('cap of 1 evicts every prior site', () {
      final loaded = <int>{};
      loaded.add(0);
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 1,
        loadedIndices: loaded,
        maxLoadedSites: 1,
      );
      expect(result, [0]);
    });

    test('exactly-at-cap re-activation does not evict', () {
      // Loaded = {0, 1, 2}, cap=3, target=2 (already loaded). Projected
      // count stays at 3, no eviction.
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      loaded.add(2);
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 2,
        loadedIndices: loaded,
        maxLoadedSites: 3,
      );
      expect(result, isEmpty);
    });

    test('all loaded sites protected — overflow is unavoidable, returns []',
        () {
      // Pathological: every loaded site is protected and target adds
      // one more. There's nothing to evict. Engine returns [] rather
      // than evicting a protected site.
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 2,
        loadedIndices: loaded,
        maxLoadedSites: 1,
        protectedIndices: {0, 1},
      );
      expect(result, isEmpty);
    });

    test('protected indices kept even when oldest', () {
      // Order: 0 (oldest), 1, 2. Cap=2 with target=3 → overflow 2,
      // evict 0 and 1 normally. Protect 0 → evict 1 and 2 instead.
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      loaded.add(2);
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 3,
        loadedIndices: loaded,
        maxLoadedSites: 2,
        protectedIndices: {0},
      );
      expect(result, [1, 2]);
    });

    test('re-activation at cap is a no-op (target already loaded)', () {
      // Loaded = {0, 1}, cap=2, target=0. Projected stays at 2 (target
      // is already loaded), so no eviction. protectedIndices is the
      // currently-active site, which may or may not equal target.
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 0,
        loadedIndices: loaded,
        maxLoadedSites: 2,
        protectedIndices: {0},
      );
      expect(result, isEmpty);
    });

    test('over-cap state recovers via eviction even on target re-activation',
        () {
      // Loaded = {0, 1}, cap=1 (already over cap from a prior config
      // change or settings import). Re-activating the protected target
      // doesn't change the count, but the engine still pulls back to
      // cap by evicting the non-target non-protected entry.
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 0,
        loadedIndices: loaded,
        maxLoadedSites: 1,
        protectedIndices: {0},
      );
      expect(result, [1]);
    });

    test('cap of 0 evicts every non-target non-protected entry', () {
      // Degenerate but well-defined: cap=0 with target → projected 1,
      // overflow 1, evict the oldest non-target site.
      final loaded = <int>{};
      loaded.add(0);
      loaded.add(1);
      final result = SiteUnloadEngine.indicesToEvictForLruCap(
        targetIndex: 2,
        loadedIndices: loaded,
        maxLoadedSites: 0,
      );
      // Overflow = 3 (projected 3 - cap 0). All non-target loaded
      // sites are evictable.
      expect(result, [0, 1]);
    });

    group('preferKeepIndices (active-webspace soft-keep)', () {
      test('out-of-set candidates are evicted before in-set candidates', () {
        // Loaded LRU order: 0 (oldest), 1, 2, 3 (newest).
        // Active webspace = {0, 2}; sites 1 and 3 are outside.
        // Cap=4 with target=4 → overflow 1. Naive LRU would evict 0;
        // soft-keep prefers to evict 1 (the oldest out-of-set).
        final loaded = <int>{};
        for (final i in [0, 1, 2, 3]) {
          loaded.add(i);
        }
        final result = SiteUnloadEngine.indicesToEvictForLruCap(
          targetIndex: 4,
          loadedIndices: loaded,
          maxLoadedSites: 4,
          preferKeepIndices: {0, 2},
        );
        expect(result, [1]);
      });

      test('falls back to in-set when out-of-set is exhausted', () {
        // Loaded: 0, 1, 2, 3. Active webspace = {0, 1, 2, 3} (everything).
        // Cap=2 with target=4 → overflow 3. Out-of-set is empty, so the
        // engine falls through to in-set in LRU order: evict 0, 1, 2.
        final loaded = <int>{};
        for (final i in [0, 1, 2, 3]) {
          loaded.add(i);
        }
        final result = SiteUnloadEngine.indicesToEvictForLruCap(
          targetIndex: 4,
          loadedIndices: loaded,
          maxLoadedSites: 2,
          preferKeepIndices: {0, 1, 2, 3},
        );
        expect(result, [0, 1, 2]);
      });

      test('mixes tiers when out-of-set is too small', () {
        // Loaded: 0 (out), 1 (in), 2 (out), 3 (in), 4 (in), 5 (in).
        // Cap=3 with target=6 → overflow 4. Out-of-set = [0, 2] (2
        // candidates), in-set = [1, 3, 4, 5]. Need 4 → take 0, 2,
        // then 1, 3 from in-set.
        final loaded = <int>{};
        for (final i in [0, 1, 2, 3, 4, 5]) {
          loaded.add(i);
        }
        final result = SiteUnloadEngine.indicesToEvictForLruCap(
          targetIndex: 6,
          loadedIndices: loaded,
          maxLoadedSites: 3,
          preferKeepIndices: {1, 3, 4, 5},
        );
        expect(result, [0, 2, 1, 3]);
      });

      test('protectedIndices wins over preferKeepIndices', () {
        // Site 0 is hard-protected; site 1 is in soft-keep; sites 2, 3
        // are out-of-set. Cap=3 with target=4 → overflow 2.
        // Eviction: out-of-set first ([2, 3]) — exhausts overflow.
        // Site 0 (protected) and site 1 (soft-keep) both stay.
        final loaded = <int>{};
        for (final i in [0, 1, 2, 3]) {
          loaded.add(i);
        }
        final result = SiteUnloadEngine.indicesToEvictForLruCap(
          targetIndex: 4,
          loadedIndices: loaded,
          maxLoadedSites: 3,
          protectedIndices: {0},
          preferKeepIndices: {1},
        );
        expect(result, [2, 3]);
      });

      test('a soft-keep site can still be evicted if hard-protected covers '
          'the keep room', () {
        // Loaded: 0 (out), 1 (in), 2 (out, hard-protected), 3 (in,
        // hard-protected). Cap=2 with target=4 → overflow 2.
        // Non-protected eligible: 0 (out), 1 (in). Out tier supplies
        // [0]; need one more → in tier supplies [1].
        final loaded = <int>{};
        for (final i in [0, 1, 2, 3]) {
          loaded.add(i);
        }
        final result = SiteUnloadEngine.indicesToEvictForLruCap(
          targetIndex: 4,
          loadedIndices: loaded,
          maxLoadedSites: 2,
          protectedIndices: {2, 3},
          preferKeepIndices: {1, 3},
        );
        expect(result, [0, 1]);
      });

      test('empty preferKeepIndices == old single-tier behavior', () {
        // Sanity check: when no soft-keep is provided, eviction order
        // is pure LRU (oldest first) — backwards-compatible default.
        // Cap=3 with target=3 (new) → overflow 1 → evict [0].
        final loaded = <int>{};
        for (final i in [0, 1, 2]) {
          loaded.add(i);
        }
        final result = SiteUnloadEngine.indicesToEvictForLruCap(
          targetIndex: 3,
          loadedIndices: loaded,
          maxLoadedSites: 3,
        );
        expect(result, [0]);
      });

      test('preferKeepIndices may include unloaded sites without effect', () {
        // The active webspace can list site indices that aren't loaded
        // yet (haven't been visited). Those don't affect eviction
        // because the engine only iterates loadedIndices.
        // Cap=3 with target=3 (new) → overflow 1.
        final loaded = <int>{};
        for (final i in [0, 1, 2]) {
          loaded.add(i);
        }
        final result = SiteUnloadEngine.indicesToEvictForLruCap(
          targetIndex: 3,
          loadedIndices: loaded,
          maxLoadedSites: 3,
          preferKeepIndices: {0, 4, 5, 99},
        );
        // Site 0 is in soft-keep; sites 4/5/99 are noise. Out-of-set
        // candidates: [1, 2]. Evict oldest: [1].
        expect(result, [1]);
      });

      test('respects access-order within each tier', () {
        // Loaded in order: 0 (out), 1 (in), 2 (out), 3 (in). Then 0
        // gets bumped (re-activation) → order becomes 1, 2, 3, 0.
        // Cap=2 with target=4 → overflow 3. Out-of-set in LRU order:
        // [2, 0]. In-set in LRU order: [1, 3]. Need 3 → [2, 0, 1].
        final loaded = <int>{};
        for (final i in [0, 1, 2, 3]) {
          loaded.add(i);
        }
        loaded.remove(0);
        loaded.add(0);
        final result = SiteUnloadEngine.indicesToEvictForLruCap(
          targetIndex: 4,
          loadedIndices: loaded,
          maxLoadedSites: 2,
          preferKeepIndices: {1, 3},
        );
        expect(result, [2, 0, 1]);
      });
    });
  });
}
