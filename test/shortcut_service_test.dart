import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
      if (call.method == 'getPinnedSiteIds') return <Object?>[];
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('ShortcutSite', () {
    test('toMap omits iconUrl when null', () {
      final m = const ShortcutSite(siteId: 'abc', label: 'Site A').toMap();
      expect(m, {'siteId': 'abc', 'label': 'Site A'});
    });

    test('toMap includes iconUrl when present', () {
      final m = const ShortcutSite(
        siteId: 'abc',
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
      final m = const ShortcutSite(
        siteId: 'abc',
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
    // on Android + iOS + macOS; syncSites/isAppIntentsSupported run on the App
    // Intents hosts (iOS + macOS); the rest short-circuit without the channel.
    final isShortcutHost =
        Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
    final isAppIntentsHost = Platform.isIOS || Platform.isMacOS;

    test('syncSites is a no-op off iOS/macOS', () async {
      await ShortcutService.syncSites(const [
        ShortcutSite(siteId: 'a', label: 'A'),
      ]);
      if (!isAppIntentsHost) {
        expect(calls, isEmpty);
      }
    });

    test('isAppIntentsSupported is false off iOS/macOS', () async {
      final supported = await ShortcutService.isAppIntentsSupported();
      if (!isAppIntentsHost) {
        expect(supported, isFalse);
        expect(calls, isEmpty);
      }
    });

    test('pinShortcut fails off a shortcut host', () async {
      final result = await ShortcutService.pinShortcut(
        siteId: 'a',
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

    test('getPinnedSiteIds is empty off Android', () async {
      final ids = await ShortcutService.getPinnedSiteIds();
      if (!Platform.isAndroid) {
        expect(ids, isEmpty);
        expect(calls, isEmpty);
      }
    });

    test('removeShortcut is a no-op off Android', () async {
      await ShortcutService.removeShortcut('a');
      if (!Platform.isAndroid) {
        expect(calls, isEmpty);
      }
    });

    test('disableShortcut is a no-op off Android', () async {
      await ShortcutService.disableShortcut('a');
      if (!Platform.isAndroid) {
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
      expect(await ShortcutService.pinShortcut(siteId: 'a', label: 'A'),
          PinShortcutResult.failed);
      expect(await ShortcutService.getLaunch(), isNull);
      expect(await ShortcutService.getPinnedSiteIds(), isEmpty);
      expect(await ShortcutService.isAppIntentsSupported(), isFalse);
      await ShortcutService.syncSites(const []);
      await ShortcutService.removeShortcut('a');
    });
  });

  group('PinShortcutResult.fromChannel', () {
    test('true is a pin request (Android dialog, or Shortcuts.app opened)', () {
      expect(PinShortcutResult.fromChannel(true), PinShortcutResult.requested);
    });

    test('alreadyPinned is a re-enabled tile with no dialog (HS-015)', () {
      expect(PinShortcutResult.fromChannel('alreadyPinned'),
          PinShortcutResult.alreadyPinned);
    });

    test('anything else is a failure', () {
      for (final raw in [false, null, 'requested', 1]) {
        expect(PinShortcutResult.fromChannel(raw), PinShortcutResult.failed,
            reason: '$raw');
      }
    });
  });

  // HS-015: a device restore brings a pinned tile back disabled under the
  // same id, and an imported backup brings the same siteId back. No test can
  // stage a restore, so guard the two lines that keep such a tile from
  // blocking a new pin.
  group('MainActivity.kt — a disabled tile never blocks pinning (HS-015)', () {
    final source = File(
            'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/MainActivity.kt')
        .readAsStringSync();

    String body(String signature) {
      final start = source.indexOf(signature);
      expect(start, isNot(-1), reason: 'missing $signature');
      final next = source.indexOf('\n    private fun ', start + 1);
      return source.substring(start, next == -1 ? source.length : next);
    }

    test('pinShortcut republishes the id before requestPinShortcut', () {
      final pin = body('private fun pinShortcut(');
      final republish = pin.indexOf('republish(shortcut)');
      final request = pin.indexOf('requestPinShortcut(');
      expect(republish, isNot(-1),
          reason: 'requestPinShortcut throws "already exists but disabled" '
              'for a restored tile; republishing replaces it first.');
      expect(request, greaterThan(republish));
      expect(body('private fun republish('), contains('pushDynamicShortcut('));
    });

    test('getPinnedSiteIds leaves disabled tiles out', () {
      final start = source.indexOf('"getPinnedSiteIds" ->');
      final branch = source.substring(start, source.indexOf('else ->', start));
      expect(branch, contains('pinnedSiteIds('));
      final fn = source.indexOf('internal fun pinnedSiteIds(');
      expect(fn, greaterThanOrEqualTo(0));
      expect(source.substring(fn), contains('it.isEnabled'),
          reason: 'A disabled tile counted as pinned hides the Home Shortcut '
              'menu item that would re-enable it.');
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
