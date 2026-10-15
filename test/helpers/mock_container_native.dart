import 'package:webspace/services/activation_step.dart';
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

  /// Containers a mounted webview binds, which a delete leaves: Android
  /// refuses one in use, iOS and macOS one a webview still holds (LIR-023).
  final Set<ContainerKey> bound = {};

  /// A webview mounts on [key]'s container, making it if missing, as the
  /// platform does when the view binds it.
  void bind(ContainerKey key) {
    profiles[key] = ContainerName.of(key);
    dataByContainer.putIfAbsent(key, () => []);
    bound.add(key);
  }

  void unbind(ContainerKey key) => bound.remove(key);

  /// Awaited before every call, named by its method: a test that schedules
  /// the platform's replies decides here when each one lands.
  Future<void> Function(PlatformCall call)? pace;

  @override
  Future<bool> isSupported() async {
    await pace?.call(PlatformCall.containerIsSupported);
    calls.add('isSupported');
    return supported;
  }

  @override
  Future<ContainerName> getOrCreateContainer(ContainerKey siteId) async {
    await pace?.call(PlatformCall.containerGetOrCreate);
    calls.add('getOrCreateContainer($siteId)');
    final name = ContainerName.of(siteId);
    profiles[siteId] = name;
    dataByContainer.putIfAbsent(siteId, () => []);
    return name;
  }

  @override
  Future<bool> deleteContainer(ContainerKey siteId) async {
    await pace?.call(PlatformCall.containerDelete);
    calls.add('deleteContainer($siteId)');
    if (bound.contains(siteId)) return false;
    final existed = profiles.remove(siteId) != null;
    dataByContainer.remove(siteId);
    return existed;
  }

  @override
  Future<bool> clearContainerData(ContainerKey siteId) async {
    await pace?.call(PlatformCall.containerClearData);
    calls.add('clearContainerData($siteId)');
    if (refuseClearFor?.contains(siteId) ?? false) return false;
    if (!profiles.containsKey(siteId)) return false;
    dataByContainer[siteId] = [];
    return true;
  }

  @override
  Future<List<ContainerKey>> listContainers() async {
    await pace?.call(PlatformCall.containerList);
    calls.add('listContainers');
    return [for (final name in profiles.keys) ContainerKey.named(name)];
  }
}
