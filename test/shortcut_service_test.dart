import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:webspace/services/launcher_tile_engine.dart';
import 'package:webspace/settings/shortcut_id.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/shortcut_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel =
      MethodChannel('org.codeberg.theoden8.webspace/shortcuts');

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      // Default to a permissive value; individual tests can re-register.
      if (call.method == 'isAppIntentsSupported') return true;
      if (call.method == 'canPinShortcuts') return true;
      if (call.method == 'getPinnedShortcuts') return <Object?>[];
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('ShortcutSite', () {
    test('toMap omits iconUrl when null', () {
      final m = ShortcutSite(siteId: SiteId('abc'), label: 'Site A').toMap();
      expect(m, {'siteId': 'abc', 'label': 'Site A'});
    });

    test('toMap includes iconUrl when present', () {
      final m = ShortcutSite(
        siteId: SiteId('abc'),
        label: 'Site A',
        iconUrl: 'https://example.com/favicon.png',
      ).toMap();
      expect(m, {
        'siteId': 'abc',
        'label': 'Site A',
        'iconUrl': 'https://example.com/favicon.png',
      });
    });

    test('toMap includes url when present', () {
      final m = ShortcutSite(
        siteId: SiteId('abc'),
        label: 'Site A',
        url: 'https://example.com/',
      ).toMap();
      expect(m, {
        'siteId': 'abc',
        'label': 'Site A',
        'url': 'https://example.com/',
      });
    });
  });

  group('ShortcutService — host gating', () {
    // Test host is the OS running `flutter test` (Linux on CI, macOS for local
    // dev and some CI lanes). Methods gate on the platform: pin/getLaunch run
    // on Android + iOS + macOS, as does probe; syncSites runs on the
    // App Intents hosts (iOS + macOS); the rest short-circuit without the
    // channel.
    final isShortcutHost =
        Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
    final isAppIntentsHost = Platform.isIOS || Platform.isMacOS;

    test('syncSites is a no-op off iOS/macOS', () async {
      await ShortcutService.syncSites([
        ShortcutSite(siteId: SiteId('a'), label: 'A'),
      ]);
      if (!isAppIntentsHost) {
        expect(calls, isEmpty);
      }
    });

    test('a shortcut is not offered off a shortcut host (HS-004)', () async {
      await ShortcutService.probe();
      if (!isShortcutHost) {
        expect(ShortcutService.offered, isFalse);
        expect(calls, isEmpty);
      }
    });

    test('pinShortcut fails off a shortcut host', () async {
      final result = await ShortcutService.pinShortcut(
        siteId: SiteId('a'),
        label: 'A',
      );
      if (!isShortcutHost) {
        expect(result, PinShortcutResult.failed);
        expect(calls, isEmpty);
      }
    });

    test('getLaunch is null off a shortcut host', () async {
      final launch = await ShortcutService.getLaunch();
      if (!isShortcutHost) {
        expect(launch, isNull);
        expect(calls, isEmpty);
      }
    });

    test('getPinnedShortcuts is empty off Android', () async {
      final tiles = await ShortcutService.getPinnedShortcuts();
      if (!Platform.isAndroid) {
        expect(tiles, isEmpty);
        expect(calls, isEmpty);
      }
    });

    test('removeShortcut is a no-op off Android', () async {
      await ShortcutService.removeShortcut(SiteId('a'));
      if (!Platform.isAndroid) {
        expect(calls, isEmpty);
      }
    });

    test('disableShortcut is a no-op off Android', () async {
      await ShortcutService.disableShortcut(ShortcutId.mint());
      if (!Platform.isAndroid) {
        expect(calls, isEmpty);
      }
    });

    test('updateTiles writes nothing off Android', () async {
      final written = await ShortcutService.updateTiles([
        (tile: ShortcutId.mint(), site: SiteId('a'), label: 'A', icon: null),
      ]);
      if (!Platform.isAndroid) {
        expect(written, isFalse);
        expect(calls, isEmpty);
      }
    });
  });

  group('ShortcutService — channel error handling', () {
    test('platform exceptions degrade to safe defaults', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'boom');
      });
      // On a non-mobile host these all short-circuit before touching the
      // channel; this case really exercises mobile hosts. Still: the calls
      // must never throw a PlatformException out of the service.
      expect(await ShortcutService.pinShortcut(siteId: SiteId('a'), label: 'A'),
          PinShortcutResult.failed);
      expect(await ShortcutService.getLaunch(), isNull);
      expect(await ShortcutService.getPinnedShortcuts(), isEmpty);
      await ShortcutService.probe();
      expect(ShortcutService.offered, isFalse);
      expect(await ShortcutService.updateTiles(const []), isFalse);
      await ShortcutService.syncSites(const []);
      await ShortcutService.removeShortcut(SiteId('a'));
    });
  });

  group('ShortcutService.tileArguments (HS-018)', () {
    test('a site icon crosses as a tile with its own background', () async {
      // White on transparency, as GitHub's dark-mode logo is.
      final logo = img.Image(width: 32, height: 32, numChannels: 4)
        ..clear(img.ColorRgba8(0, 0, 0, 0));
      img.fillCircle(logo,
          x: 16, y: 16, radius: 14, color: img.ColorRgba8(255, 255, 255, 255));
      final tile = ShortcutId.mint();
      final args = await ShortcutService.tileArguments(
        tile: tile,
        site: SiteId('a'),
        label: 'A',
        siteIcon: img.encodePng(logo),
      );
      expect(args['shortcutId'], tile);
      expect(args['siteId'], 'a');
      expect(args['label'], 'A');
      final sent = img.decodePng(args['iconBytes']! as Uint8List)!;
      expect((sent.width, sent.height), (kLauncherTileEdge, kLauncherTileEdge));
      final corner = sent.getPixel(0, 0);
      expect((corner.r, corner.g, corner.b, corner.a),
          (TilePlate.dark.r, TilePlate.dark.g, TilePlate.dark.b, 0xFF));
    });

    test('no icon, or one that does not decode, sends none', () async {
      for (final siteIcon in [null, Uint8List.fromList([1, 2, 3])]) {
        final args = await ShortcutService.tileArguments(
          tile: null,
          site: SiteId('a'),
          label: 'A',
          siteIcon: siteIcon,
        );
        expect(args.containsKey('iconBytes'), isTrue);
        expect(args['iconBytes'], isNull, reason: '$siteIcon');
      }
    });
  });

  group('PinShortcutResult.fromChannel', () {
    test('true is a pin request (Android dialog, or Shortcuts.app opened)', () {
      expect(PinShortcutResult.fromChannel(true), PinShortcutResult.requested);
    });

    test('anything else is a failure', () {
      for (final raw in [false, null, 'requested', 'alreadyPinned', 1]) {
        expect(PinShortcutResult.fromChannel(raw), PinShortcutResult.failed,
            reason: '$raw');
      }
    });
  });

  group('ShortcutId (HS-017)', () {
    test('a minted id is fresh and parses back', () {
      final a = ShortcutId.mint();
      final b = ShortcutId.mint();
      expect(a, isNot(b));
      expect(ShortcutId.parse(a), a);
    });

    test('a tile pinned before shortcut ids parses', () {
      expect(ShortcutId.parse('site_abc-123'), 'site_abc-123');
    });

    test('anything native code could not have handed out is absent', () {
      for (final raw in [null, '', 'a b', 'tile/1', 42, 'x' * 161]) {
        expect(ShortcutId.parse(raw), isNull, reason: '$raw');
      }
    });
  });

  // HS-015/HS-017: the tile's id is its own and the site it opens rides its
  // intent, so the app can point a pinned tile at another site and a fresh
  // pin never meets a disabled copy under its id (a device restore leaves
  // one). HS-018: its icon brings its own background. No test can stage a
  // launcher, so guard the lines that do it.
  group('MainActivity.kt: tiles carry their own id and background', () {
    final source = File(
            'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/MainActivity.kt')
        .readAsStringSync();

    String body(String signature) {
      final start = source.indexOf(signature);
      expect(start, isNot(-1), reason: 'missing $signature');
      final next = source.indexOf('\n    private fun ', start + 1);
      return source.substring(start, next == -1 ? source.length : next);
    }

    test('a tile is built under the id Dart gives it, naming its site', () {
      final shortcut = body('private fun siteShortcut(');
      expect(shortcut, contains('ShortcutInfoCompat.Builder(this, shortcutId)'));
      expect(shortcut, contains('putExtra("siteId", siteId)'));
      expect(shortcut, contains('putExtra("shortcutId", shortcutId)'));
      expect(shortcut, isNot(contains(r'"site_$')),
          reason: 'A tile id derived from the site makes a restored, '
              'disabled tile block pinning that site again (HS-015).');
    });

    test('a tile icon is an adaptive bitmap (HS-018)', () {
      final decode = body('private fun decodeIcon(');
      expect(decode, contains('IconCompat.createWithAdaptiveBitmap(bmp)'));
      expect(decode, isNot(contains('createWithBitmap(')),
          reason: 'A plain bitmap is wrapped on a background the launcher '
              'picks (white in Launcher3), which hides a white logo.');
    });

    test('getPinnedShortcuts reads the site from the intent, enabled only',
        () {
      final start = source.indexOf('internal fun pinnedShortcuts(');
      expect(start, isNot(-1));
      final fn = source.substring(start);
      expect(fn, contains('it.isEnabled'),
          reason: 'A disabled tile opens nothing; counted as reaching its '
              'site, it hides the menu item that would pin a working one.');
      expect(fn, contains('getStringExtra("siteId")'),
          reason: 'A rewritten tile opens the site its intent names, not '
              'the one its id was minted for.');
    });
  });

  // The iOS App Shortcuts materialization (HS-008) collapses every entity
  // down to a single visible row unless SiteEntity.displayRepresentation
  // pairs a static "%@" key (stable for the compile-time App Intents metadata
  // extractor) with a runtime defaultValue carrying the site name. A bare
  // `stringLiteral:` resolves in the live picker but not in the materialized
  // tiles (runtime string can't be a compile-time key); a `title: "\(name)"`
  // interpolation renders the literal "%@". Guard the Swift source so a
  // future refactor can't silently revert to either broken form.
  // One source, compiled by both Apple Runners
  // (test/js/apple_shared_sources.test.js).
  test('WebSpaceAppIntents.swift uses a static %@ key with a runtime defaultValue', () {
    final source = File('ios/Runner/WebSpaceAppIntents.swift').readAsStringSync();
    expect(
        source,
        contains(
            'LocalizedStringResource("%@", defaultValue: String.LocalizationValue(name))'),
        reason: 'SiteEntity.displayRepresentation must use a static "%@" '
            'key plus a runtime defaultValue so each site materializes as '
            'its own App Shortcut entry. See HS-008 / openspec spec.');
    expect(source, isNot(contains(r'DisplayRepresentation(title: "\(name)")')),
        reason: 'String interpolation inside DisplayRepresentation(title:) '
            'is parsed as a LocalizedStringResource template, which '
            'collapses every materialized App Shortcut to a single %@ '
            'placeholder row in Shortcuts.app.');
    expect(source, isNot(contains('DisplayRepresentation(stringLiteral: name)')),
        reason: 'A bare stringLiteral resolves in the live picker but not '
            'in the materialized App Shortcut tiles, because the App Intents '
            'metadata extractor cannot bake a runtime string as the key.');
  });
}
