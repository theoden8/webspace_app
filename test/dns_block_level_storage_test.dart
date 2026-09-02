// Storage lifecycle for the level-membership blocklist: download, fold a
// second level in, reload from disk, prune, clear. The mask replaced the flat
// on-disk list wholesale, so these paths are where a format or bookkeeping
// mistake silently costs the user their blocklist — none of it is reachable
// from the pure-engine tests.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/proxy.dart';

/// `looksLikeDomainList` rejects anything under 1000 entries, so a plausible
/// body has to be that big. [extra] are the domains the test actually asserts
/// on; the filler exists only to clear the plausibility bar.
String _body(int level, List<String> extra) {
  final buf = StringBuffer('# hagezi level $level\n');
  for (var i = 0; i < 1200; i++) {
    buf.writeln('filler$level-$i.example');
  }
  for (final domain in extra) {
    buf.writeln(domain);
  }
  return buf.toString();
}

/// Serves each level's list off any mirror, so the test doesn't depend on
/// which mirror the service reaches for first.
class _MirrorFactory implements OutboundHttpFactory {
  _MirrorFactory(this.bodies);

  /// Level -> body. A level absent here 404s, standing in for a list the
  /// mirrors don't have.
  final Map<int, String> bodies;
  final List<String> requested = [];

  @override
  OutboundClient clientFor(UserProxySettings settings) =>
      OutboundClientReady(MockClient((req) async {
        requested.add(req.url.toString());
        for (final entry in bodies.entries) {
          for (final url in dnsMirrorUrlsForLevel(entry.key)) {
            if (req.url.toString() == url) {
              return http.Response(entry.value, 200);
            }
          }
        }
        return http.Response('not found', 404);
      }));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DnsBlockService service;
  late MemoryFileStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = DnsBlockService.instance;
    service.resetForTest();
    store = MemoryFileStore();
    service.store = store;
  });

  tearDown(() {
    resetOutboundHttp();
    service.resetForTest();
  });

  /// Re-read everything from disk the way a cold launch does, keeping the
  /// same backing store. Proves what was written is what comes back.
  Future<void> coldStart() async {
    service.resetForTest();
    service.store = store;
    await service.initialize();
  }

  group('download and fold (DNS-019, DNS-021)', () {
    test('the app-wide download writes one file and records the level',
        () async {
      outboundHttp = _MirrorFactory({3: _body(3, ['pro-only.example'])});

      expect(await service.downloadList(3), isTrue);

      expect(service.level, 3);
      expect(service.downloadedLevels, {3});
      expect(service.levelGroupCount, 1);
      expect(service.isHostBlockedAtLevel('pro-only.example', 3), isTrue);
      expect(await store.exists('dns_blocklist_levels.txt'), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('dns_block_level'), 3);
      expect(prefs.getStringList('dns_block_downloaded_levels'), ['3']);
      expect(prefs.getString('dns_block_last_updated'), isNotNull);
    });

    test('a second level folds in without duplicating a shared domain',
        () async {
      outboundHttp = _MirrorFactory({
        3: _body(3, ['shared.example', 'pro-only.example']),
        1: _body(1, ['shared.example', 'light-only.example']),
      });

      await service.downloadList(3);
      final afterOne = service.domainCount;
      expect(await service.downloadLevel(1), isTrue);

      expect(service.downloadedLevels, {1, 3});
      // shared.example was already stored; only the level-1 filler and
      // light-only.example are new.
      expect(service.domainCount, afterOne + 1201);
      expect(service.isHostBlockedAtLevel('shared.example', 1), isTrue);
      expect(service.isHostBlockedAtLevel('shared.example', 3), isTrue);
      expect(service.isHostBlockedAtLevel('light-only.example', 1), isTrue);
      expect(service.isHostBlockedAtLevel('light-only.example', 3), isFalse,
          reason: 'Pro never named it, so folding Light in must not add it');
      expect(service.isHostBlockedAtLevel('pro-only.example', 1), isFalse);
      expect(service.level, 3, reason: 'an extra level is not the app level');
    });

    test('folding a level already held costs no request', () async {
      final factory = _MirrorFactory({3: _body(3, ['a.example'])});
      outboundHttp = factory;
      await service.downloadList(3);
      final before = service.domainCount;
      final requestsAfterDownload = factory.requested.length;

      expect(await service.downloadLevel(3), isTrue);

      expect(service.domainCount, before);
      expect(factory.requested.length, requestsAfterDownload,
          reason: 'a level already folded in must not be refetched');
    });

    test('a level the mirrors do not have leaves the partition alone',
        () async {
      outboundHttp = _MirrorFactory({3: _body(3, ['pro-only.example'])});
      await service.downloadList(3);
      final before = service.domainCount;

      expect(await service.downloadLevel(1), isFalse);

      expect(service.downloadedLevels, {3});
      expect(service.domainCount, before);
      expect(service.isHostBlockedAtLevel('pro-only.example', 3), isTrue);
    });

    test('an implausible body never overwrites a working partition',
        () async {
      outboundHttp = _MirrorFactory({3: _body(3, ['pro-only.example'])});
      await service.downloadList(3);
      final before = service.domainCount;

      // Every mirror answers 200 with an error page.
      outboundHttp = _MirrorFactory({1: '<!DOCTYPE html>\n<html>oops</html>'});
      expect(await service.downloadLevel(1), isFalse);

      expect(service.downloadedLevels, {3});
      expect(service.domainCount, before);
      expect(service.isHostBlockedAtLevel('pro-only.example', 3), isTrue);
    });

    test('re-downloading a level drops what left its list', () async {
      outboundHttp = _MirrorFactory({
        3: _body(3, ['stays.example', 'delisted.example']),
      });
      await service.downloadList(3);
      expect(service.isHostBlockedAtLevel('delisted.example', 3), isTrue);

      service.resetForTest();
      service.store = store;
      await service.initialize();
      outboundHttp = _MirrorFactory({3: _body(3, ['stays.example'])});
      await service.downloadList(3);

      expect(service.isHostBlockedAtLevel('stays.example', 3), isTrue);
      expect(service.isHostBlockedAtLevel('delisted.example', 3), isFalse);
    });
  });

  group('reload from disk (DNS-019)', () {
    test('a cold start reproduces every level exactly', () async {
      outboundHttp = _MirrorFactory({
        3: _body(3, ['shared.example', 'pro-only.example']),
        1: _body(1, ['shared.example', 'light-only.example']),
      });
      await service.downloadList(3);
      await service.downloadLevel(1);

      final before = {
        for (final host in [
          'shared.example',
          'pro-only.example',
          'light-only.example',
          'unlisted.example',
        ])
          host: [
            for (var level = 1; level <= kDnsMaxLevel; level++)
              service.isHostBlockedAtLevel(host, level)
          ]
      };
      final countBefore = service.domainCount;

      await coldStart();

      expect(service.level, 3);
      expect(service.downloadedLevels, {1, 3});
      expect(service.domainCount, countBefore);
      for (final entry in before.entries) {
        expect([
          for (var level = 1; level <= kDnsMaxLevel; level++)
            service.isHostBlockedAtLevel(entry.key, level)
        ], entry.value, reason: entry.key);
      }
    });

    test('the file carries each domain once', () async {
      outboundHttp = _MirrorFactory({
        3: _body(3, ['shared.example']),
        1: _body(1, ['shared.example']),
      });
      await service.downloadList(3);
      await service.downloadLevel(1);

      final lines = (await store.readText('dns_blocklist_levels.txt'))!
          .split('\n')
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();
      expect(lines.length, lines.toSet().length);
      expect(lines.length, service.domainCount);
    });

    test('the marker is hex, and survives a mask that proves it', () async {
      // Levels 2 and 4 give mask 0b1010 = 10, the smallest value where hex
      // and decimal disagree. Every smaller mask reads the same either way,
      // so a test using only adjacent low levels cannot see a radix drift —
      // and the Kotlin reader parses this marker with toIntOrNull(16).
      outboundHttp = _MirrorFactory({
        4: _body(4, ['proplus-only.example', 'both.example']),
        2: _body(2, ['normal-only.example', 'both.example']),
      });
      await service.downloadList(4);
      await service.downloadLevel(2);

      final text = (await store.readText('dns_blocklist_levels.txt'))!;
      final markers = text
          .split('\n')
          .where((l) => l.startsWith('#'))
          .map((l) => l.substring(1))
          .toSet();
      expect(markers, contains('a'),
          reason: 'the both-levels group is mask 10, written hex as "a"');
      expect(markers, isNot(contains('10')));

      await coldStart();
      expect(service.isHostBlockedAtLevel('both.example', 2), isTrue);
      expect(service.isHostBlockedAtLevel('both.example', 4), isTrue);
      expect(service.isHostBlockedAtLevel('both.example', 3), isFalse);
      expect(service.isHostBlockedAtLevel('normal-only.example', 2), isTrue);
      expect(service.isHostBlockedAtLevel('normal-only.example', 4), isFalse);
      expect(service.isHostBlockedAtLevel('proplus-only.example', 4), isTrue);
      expect(service.isHostBlockedAtLevel('proplus-only.example', 2), isFalse);
    });

    test('a cold start with no file leaves the service empty', () async {
      await coldStart();
      expect(service.hasBlocklist, isFalse);
      expect(service.downloadedLevels, isEmpty);
    });
  });

  group('legacy migration (DNS-019)', () {
    test('a pre-mask flat cache is folded in at its recorded level',
        () async {
      SharedPreferences.setMockInitialValues({'dns_block_level': 2});
      await store.writeText(
          'dns_blocklist.txt', _body(2, ['legacy.example']));
      service.resetForTest();
      service.store = store;

      await service.initialize();

      expect(service.level, 2);
      expect(service.downloadedLevels, {2});
      expect(service.isHostBlockedAtLevel('legacy.example', 2), isTrue);
      expect(service.isHostBlockedAtLevel('legacy.example', 3), isFalse,
          reason: 'only level 2 ever named it');
      expect(await store.exists('dns_blocklist.txt'), isFalse);
      expect(await store.exists('dns_blocklist_levels.txt'), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('dns_block_downloaded_levels'), ['2']);

      // And it survives the next launch, now through the mask path.
      await coldStart();
      expect(service.isHostBlockedAtLevel('legacy.example', 2), isTrue);
    });

    test('a legacy file with the level off is not migrated', () async {
      SharedPreferences.setMockInitialValues({'dns_block_level': 0});
      await store.writeText('dns_blocklist.txt', _body(1, ['legacy.example']));
      service.resetForTest();
      service.store = store;

      await service.initialize();

      expect(service.hasBlocklist, isFalse);
      expect(service.downloadedLevels, isEmpty);
    });
  });

  group('prune and clear (DNS-021)', () {
    test('pruning clears a level and the domains only it named', () async {
      outboundHttp = _MirrorFactory({
        3: _body(3, ['shared.example', 'pro-only.example']),
        1: _body(1, ['shared.example', 'light-only.example']),
      });
      await service.downloadList(3);
      await service.downloadLevel(1);
      final withBoth = service.domainCount;

      await service.pruneLevels({3});

      expect(service.downloadedLevels, {3});
      expect(service.isHostBlockedAtLevel('light-only.example', 1), isFalse);
      expect(service.isHostBlockedAtLevel('light-only.example', 3), isFalse);
      expect(service.isHostBlockedAtLevel('shared.example', 3), isTrue,
          reason: 'Pro still names it');
      expect(service.domainCount, lessThan(withBoth));

      await coldStart();
      expect(service.downloadedLevels, {3});
      expect(service.isHostBlockedAtLevel('shared.example', 3), isTrue);
      expect(service.isHostBlockedAtLevel('light-only.example', 1), isFalse);
    });

    test('pruning nothing rewrites nothing', () async {
      outboundHttp = _MirrorFactory({3: _body(3, ['a.example'])});
      await service.downloadList(3);
      final before = await store.readText('dns_blocklist_levels.txt');

      await service.pruneLevels({3});

      expect(await store.readText('dns_blocklist_levels.txt'), before);
    });

    test('setting the app level to Off clears the file and the prefs',
        () async {
      outboundHttp = _MirrorFactory({3: _body(3, ['a.example'])});
      await service.downloadList(3);

      expect(await service.downloadList(0), isTrue);

      expect(service.hasBlocklist, isFalse);
      expect(service.level, 0);
      expect(service.downloadedLevels, isEmpty);
      expect(await store.exists('dns_blocklist_levels.txt'), isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('dns_block_level'), 0);
      expect(prefs.getStringList('dns_block_downloaded_levels'), isNull);
      expect(prefs.getString('dns_block_last_updated'), isNull);

      await coldStart();
      expect(service.hasBlocklist, isFalse);
    });

    test('an imported level drops the cache and keeps the intent', () async {
      outboundHttp = _MirrorFactory({3: _body(3, ['a.example'])});
      await service.downloadList(3);

      await service.applyImportedLevel(5);

      expect(service.level, 5);
      expect(service.hasBlocklist, isFalse,
          reason: 'a backup carries the level, never the blob');
      expect(await store.exists('dns_blocklist_levels.txt'), isFalse);

      await coldStart();
      expect(service.level, 5);
      expect(service.hasBlocklist, isFalse);
    });
  });
}
