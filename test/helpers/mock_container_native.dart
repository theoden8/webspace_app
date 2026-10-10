import 'package:webspace/services/container_native.dart';

/// In-memory model of the native Profile API with **per-profile cookie
/// storage**, so the central spec claim — sites in different profiles do
/// not see each other's cookies — can actually be asserted, not just
/// assumed. Every cookie write goes through a webview scoped to its
/// site's profile from construction (CONT-005); reads from the wrong
/// profile see nothing.
///
/// Mirrors the [MockCookieManager] pattern in
/// [test/helpers/mock_cookie_manager.dart] — modeling the engine's
/// actual contract end-to-end, not stubbing it.
class MockContainerNative implements ContainerNative {
  bool supported;

  /// `siteId` -> `ws-<siteId>` for every profile that exists in the
  /// simulated `ProfileStore`. Mirrors `ProfileStore.getAllProfileNames()`.
  final Map<String, String> containers = {};

  /// Per-profile cookie store. Outer key is the profile name
  /// (`ws-<siteId>`); inner is `cookieName -> value`. A read from the
  /// wrong profile sees the empty map for that profile, so cross-profile
  /// leaks fail the assertion that the owning site's cookie is intact.
  final Map<String, Map<String, String>> cookiesByContainer = {};

  /// Records every native call so tests can assert which ones ran.
  final List<String> calls = [];

  MockContainerNative({this.supported = true});

  @override
  bool get cachedSupported => supported;

  @override
  Future<bool> isSupported() async {
    calls.add('isSupported');
    return supported;
  }

  @override
  Future<String> getOrCreateContainer(String siteId) async {
    calls.add('getOrCreateContainer($siteId)');
    final name = 'ws-$siteId';
    containers[siteId] = name;
    cookiesByContainer.putIfAbsent(name, () => <String, String>{});
    return name;
  }


  @override
  Future<bool> deleteContainer(String siteId) async {
    calls.add('deleteContainer($siteId)');
    final existed = containers.remove(siteId) != null;
    cookiesByContainer.remove('ws-$siteId');
    return existed;
  }

  @override
  Future<bool> clearContainerData(String siteId) async {
    calls.add('clearContainerData($siteId)');
    if (!containers.containsKey(siteId)) return false;
    cookiesByContainer['ws-$siteId'] = {};
    return true;
  }

  @override
  Future<List<String>> listContainers() async {
    calls.add('listContainers');
    return containers.keys.toList();
  }

  /// Inject an orphan profile to simulate state left behind by a previous
  /// session (site deleted before profile mode shipped, or a crash mid-
  /// deletion). The orphan has its own cookie jar so a successful GC
  /// must drop both the profile name and its data.
  void seedOrphanContainer(String siteId,
      {required Map<String, String> cookies}) {
    containers[siteId] = 'ws-$siteId';
    cookiesByContainer['ws-$siteId'] = Map.of(cookies);
  }
}
