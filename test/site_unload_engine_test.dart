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

    test('out-of-bounds target returns empty', () {
      final result = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
        targetIndex: 5,
        models: const [],
        loadedIndices: const {},
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
  });
}
