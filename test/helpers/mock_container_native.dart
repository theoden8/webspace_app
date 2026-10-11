import 'package:webspace/services/container_native.dart';

/// In-memory model of the native container API: a set of containers
/// keyed by siteId. Mirrors the [MockCookieManager] pattern in
/// [test/helpers/mock_cookie_manager.dart] — the engine is
/// unaware it is talking to a fake.
class MockContainerNative implements ContainerNative {
  bool supported;

  /// `siteId` -> native name (`ws-<siteId>`).
  final Map<String, String> profiles = {};

  /// `siteId` -> arbitrary "data" the mock tracks so tests can assert
  /// `clearContainerData` wiped contents without removing the entry.
  final Map<String, List<String>> dataByContainer = {};

  /// Records every method call so tests can assert sequencing.
  final List<String> calls = [];

  /// When non-null, `clearContainerData` returns false (simulates a
  /// platform refusing the clear — Linux pre-bind, or any other "data
  /// store not materialized" path).
  Set<String>? refuseClearFor;

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
    profiles[siteId] = name;
    dataByContainer.putIfAbsent(siteId, () => []);
    return name;
  }

  @override
  Future<bool> deleteContainer(String siteId) async {
    calls.add('deleteContainer($siteId)');
    final existed = profiles.remove(siteId) != null;
    dataByContainer.remove(siteId);
    return existed;
  }

  @override
  Future<bool> clearContainerData(String siteId) async {
    calls.add('clearContainerData($siteId)');
    if (refuseClearFor?.contains(siteId) ?? false) return false;
    if (!profiles.containsKey(siteId)) return false;
    dataByContainer[siteId] = [];
    return true;
  }

  @override
  Future<List<String>> listContainers() async {
    calls.add('listContainers');
    return profiles.keys.toList();
  }
}
