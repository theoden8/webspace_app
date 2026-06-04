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

  group('ShortcutService — non-mobile host', () {
    // Test host is the OS running `flutter test` (Linux on CI, macOS for local
    // dev). All methods that gate on Platform.isAndroid / Platform.isIOS must
    // short-circuit without touching the channel.
    final isMobileHost = Platform.isAndroid || Platform.isIOS;

    test('syncSites is a no-op off iOS', () async {
      await ShortcutService.syncSites(const [
        ShortcutSite(siteId: 'a', label: 'A'),
      ]);
      if (!Platform.isIOS) {
        expect(calls, isEmpty);
      }
    });

    test('isAppIntentsSupported is false off iOS', () async {
      final supported = await ShortcutService.isAppIntentsSupported();
      if (!Platform.isIOS) {
        expect(supported, isFalse);
        expect(calls, isEmpty);
      }
    });

    test('pinShortcut is false on non-mobile host', () async {
      final ok = await ShortcutService.pinShortcut(
        siteId: 'a',
        label: 'A',
      );
      if (!isMobileHost) {
        expect(ok, isFalse);
        expect(calls, isEmpty);
      }
    });

    test('getLaunch is null on non-mobile host', () async {
      final launch = await ShortcutService.getLaunch();
      if (!isMobileHost) {
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
      expect(await ShortcutService.pinShortcut(siteId: 'a', label: 'A'), isFalse);
      expect(await ShortcutService.getLaunch(), isNull);
      expect(await ShortcutService.getPinnedSiteIds(), isEmpty);
      expect(await ShortcutService.isAppIntentsSupported(), isFalse);
      await ShortcutService.syncSites(const []);
      await ShortcutService.removeShortcut('a');
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
  group('WebSpaceAppIntents.swift — SiteEntity displayRepresentation', () {
    test('uses a static %@ key with a runtime defaultValue', () {
      final source =
          File('ios/Runner/WebSpaceAppIntents.swift').readAsStringSync();
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
  });
}
