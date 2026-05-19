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

    test('getLaunchSiteId is null on non-mobile host', () async {
      final id = await ShortcutService.getLaunchSiteId();
      if (!isMobileHost) {
        expect(id, isNull);
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
      expect(await ShortcutService.getLaunchSiteId(), isNull);
      expect(await ShortcutService.getPinnedSiteIds(), isEmpty);
      expect(await ShortcutService.isAppIntentsSupported(), isFalse);
      await ShortcutService.syncSites(const []);
      await ShortcutService.removeShortcut('a');
    });
  });

  // The iOS App Shortcuts materialization (HS-008) collapses every entity
  // down to a single visible "Open %@ in WebSpace" row when SiteEntity's
  // displayRepresentation uses string interpolation: iOS treats the
  // interpolated form as a LocalizedStringResource template whose %@ is never
  // bound at materialization time. The fix is `DisplayRepresentation(
  // stringLiteral: name)`. Guard the Swift source so a future refactor can't
  // silently revert it.
  group('WebSpaceAppIntents.swift — SiteEntity displayRepresentation', () {
    test('uses stringLiteral, not LocalizedStringResource interpolation', () {
      final source =
          File('ios/Runner/WebSpaceAppIntents.swift').readAsStringSync();
      expect(source, contains('DisplayRepresentation(stringLiteral: name)'),
          reason: 'SiteEntity.displayRepresentation must use the '
              '`stringLiteral:` initializer so each site materializes as its '
              'own App Shortcut entry. See HS-008 / openspec spec.');
      expect(source, isNot(contains(r'DisplayRepresentation(title: "\(name)")')),
          reason: 'String interpolation inside DisplayRepresentation(title:) '
              'is parsed as a LocalizedStringResource template, which '
              'collapses every materialized App Shortcut to a single %@ '
              'placeholder row in Shortcuts.app.');
    });
  });
}
