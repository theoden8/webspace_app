import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/web_intercept_native.dart';

/// A launch reads the engine the last build with the same inputs cached, and
/// opens no list: rebuilding from the lists' text is several hundred ms on a
/// phone, on the thread the first frame waits for. Every input that changes
/// the rules the engine is built from has to miss.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = _libraryExists() ? false : 'library not built';
  final service = ContentBlockerService.instance;

  late _CountingStore store;

  void installBuild(String buildNumber) => PackageInfo.setMockInitialValues(
        appName: 'WebSpace',
        packageName: 'org.codeberg.theoden8.webspace',
        version: '1.0.0',
        buildNumber: buildNumber,
        buildSignature: '',
      );

  Future<void> launch({Map<String, List<String>> masks = const {}}) async {
    SharedPreferences.setMockInitialValues({
      'content_blocker_lists': jsonEncode([
        for (final id in ['ads', 'trackers'])
          {'id': id, 'name': id, 'url': 'https://lists.example/$id.txt', 'enabled': true},
      ]),
      if (masks.isNotEmpty) 'content_blocker_list_masks': jsonEncode(masks),
    });
    service
      ..reset()
      ..store = store;
    store.listReads = 0;
    await service.initialize();
    // The cache is written behind the launch, not on its path.
    await pumpEventQueue();
  }

  setUp(() async {
    installBuild('1');
    store = _CountingStore();
    await store.writeText('ads.txt', contents: '||ads.example^\n');
    await store.writeText('trackers.txt', contents: '||tracker.example^\n');
  });

  test('a second launch opens no list and blocks the same', () async {
    await launch();
    expect(store.listReads, 2);
    final hosts = service.abpNetworkBlockHosts;

    await launch();
    expect(store.listReads, 0);
    expect(service.isHostBlocked('tracker.example'), isTrue);
    expect(service.isHostBlocked('example.org'), isFalse);
    expect(service.abpNetworkBlockHosts, hosts,
        reason: 'the interceptor prefilter comes back from the cache too');
  }, skip: skip);

  test('a list downloaded again rebuilds from its text', () async {
    await launch();
    await store.writeText('trackers.txt', contents: '||other.example^\n');

    await launch();
    expect(store.listReads, 2);
    expect(service.isHostBlocked('other.example'), isTrue);
    expect(service.isHostBlocked('tracker.example'), isFalse);
  }, skip: skip);

  test('a site switching a list off rebuilds from text', () async {
    await launch();
    await launch(masks: {
      'trackers': ['news.example'],
    });
    expect(store.listReads, 2);
  }, skip: skip);

  test('a new app build rebuilds from text', () async {
    await launch();
    installBuild('2');
    await launch();
    expect(store.listReads, 2);
  }, skip: skip);

  group('Android interceptor', () {
    const channel = MethodChannel('org.codeberg.theoden8.webspace/web_intercept');
    late List<Map<Object?, Object?>> pushes;
    late bool blobHydrates;

    setUp(() {
      pushes = [];
      blobHydrates = true;
      WebInterceptNative.debugAssumeAndroid = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        if (call.method != 'setAdblockEngine') return null;
        final args = call.arguments as Map<Object?, Object?>;
        pushes.add(args);
        final active = args.containsKey('blob')
            ? blobHydrates && (args['blob'] as Uint8List).isNotEmpty
            : (args['rulesText'] as String).isNotEmpty;
        return {'supported': true, 'active': active};
      });
    });
    tearDown(() {
      WebInterceptNative.debugAssumeAndroid = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('gets the engine Dart runs, cold and warm', () async {
      await launch();
      expect(pushes, hasLength(1));
      final cold = pushes.single['blob'] as Uint8List;
      expect(cold, isNotEmpty);

      pushes.clear();
      await launch();
      expect(store.listReads, 0);
      expect(pushes.single['blob'], cold,
          reason: 'the cached engine is the one the cold launch built');
    }, skip: skip);

    test('is handed the rules when the blob does not hydrate', () async {
      blobHydrates = false;
      await launch();
      expect(pushes, hasLength(2));
      expect(pushes.last['rulesText'], contains('||tracker.example^'));

      pushes.clear();
      await launch();
      expect(pushes, hasLength(2),
          reason: 'a warm launch reads the lists for the fallback');
      expect(pushes.last['rulesText'], contains('||tracker.example^'));
    }, skip: skip);
  });

  test('a cache whose write was cut short rebuilds from text', () async {
    await launch();
    await store.delete('.engine.meta');
    await launch();
    expect(store.listReads, 2);
    expect(service.isHostBlocked('tracker.example'), isTrue);
  }, skip: skip);
}

/// Counts reads of the downloaded lists, the work a warm launch skips.
class _CountingStore implements FileStore {
  final MemoryFileStore _inner = MemoryFileStore();
  int listReads = 0;

  @override
  Future<String?> readText(String name) {
    if (name.endsWith('.txt')) listReads++;
    return _inner.readText(name);
  }

  @override
  Future<void> ensure() => _inner.ensure();

  @override
  Future<bool> exists(String name) => _inner.exists(name);

  @override
  Future<void> writeText(String name, {required String contents}) =>
      _inner.writeText(name, contents: contents);

  @override
  Future<Uint8List?> readBytes(String name) => _inner.readBytes(name);

  @override
  Future<void> writeBytes(String name, {required List<int> bytes}) =>
      _inner.writeBytes(name, bytes: bytes);

  @override
  Future<void> delete(String name) => _inner.delete(name);

  @override
  Future<String?> stamp(String name) => _inner.stamp(name);

  @override
  Future<List<String>> list() => _inner.list();

  @override
  Future<void> deleteAll() => _inner.deleteAll();
}

bool _libraryExists() => [
      'rust/webspace_adblock/target/release/libwebspace_adblock.so',
      'rust/webspace_adblock/target/release/libwebspace_adblock.dylib',
    ].any((p) => File('${Directory.current.path}/$p').existsSync());
