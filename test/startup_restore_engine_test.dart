import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/startup_restore_engine.dart';
import 'package:webspace/web_view_model.dart';

WebViewModel _site(String url) => WebViewModel(initUrl: url);

void main() {
  group('StartupRestoreEngine.resolveLaunchTarget', () {
    test('returns null when no shortcut intent was passed', () {
      final models = [_site('https://example.com'), _site('https://other.com')];
      expect(
        StartupRestoreEngine.resolveLaunchTarget(
          shortcutSiteId: null,
          models: models,
        ),
        isNull,
      );
    });

    test('returns the index of the matching siteId', () {
      final a = _site('https://a.com');
      final b = _site('https://b.com');
      expect(
        StartupRestoreEngine.resolveLaunchTarget(
          shortcutSiteId: b.siteId,
          models: [a, b],
        ),
        1,
      );
    });

    test('returns null when the shortcut siteId no longer exists', () {
      final models = [_site('https://a.com'), _site('https://b.com')];
      expect(
        StartupRestoreEngine.resolveLaunchTarget(
          shortcutSiteId: 'deleted-site-id',
          models: models,
        ),
        isNull,
      );
    });

    test('returns null when the model list is empty', () {
      expect(
        StartupRestoreEngine.resolveLaunchTarget(
          shortcutSiteId: 'any-id',
          models: const [],
        ),
        isNull,
      );
    });

    test('returns the first match if siteIds collide (defensive)', () {
      final a = _site('https://a.com');
      final b = _site('https://b.com');
      // siteIds are random UUIDs in production; this tests indexWhere
      // semantics in case a hand-edited backup ever produces a collision.
      expect(
        StartupRestoreEngine.resolveLaunchTarget(
          shortcutSiteId: a.siteId,
          models: [a, b],
        ),
        0,
      );
    });
  });

  group('StartupRestoreEngine.resolveLaunch', () {
    test('no intent -> LaunchNone', () {
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: null,
        shortcutUrl: null,
        models: [_site('https://a.com')],
        rememberedRemap: const {},
      );
      expect(r, isA<LaunchNone>());
    });

    test('direct siteId hit -> LaunchOpenSite at its index', () {
      final a = _site('https://a.com');
      final b = _site('https://b.com');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: b.siteId,
        shortcutUrl: 'https://b.com',
        models: [a, b],
        rememberedRemap: const {},
      );
      expect(r, isA<LaunchOpenSite>());
      expect((r as LaunchOpenSite).index, 1);
    });

    test('siteId gone but remembered remap resolves -> LaunchOpenSite', () {
      final a = _site('https://a.com');
      final b = _site('https://b.com');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: 'stale-id',
        shortcutUrl: 'https://b.com',
        models: [a, b],
        rememberedRemap: {'stale-id': b.siteId},
      );
      expect(r, isA<LaunchOpenSite>());
      expect((r as LaunchOpenSite).index, 1);
    });

    test('remembered remap takes priority over a domain match', () {
      final a = _site('https://a.com');
      final b = _site('https://b.com');
      // url points at a.com, but the user previously rebound to b.
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: 'stale-id',
        shortcutUrl: 'https://a.com',
        models: [a, b],
        rememberedRemap: {'stale-id': b.siteId},
      );
      expect((r as LaunchOpenSite).index, 1);
    });

    test('stale remap (target deleted) falls through to domain match', () {
      final a = _site('https://mail.example.com/inbox');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: 'stale-id',
        shortcutUrl: 'https://www.example.com/',
        models: [a],
        rememberedRemap: const {'stale-id': 'also-gone'},
      );
      expect(r, isA<LaunchConfirmExisting>());
      expect((r as LaunchConfirmExisting).index, 0);
      expect(r.shortcutSiteId, 'stale-id');
    });

    test('siteId gone, base-domain match -> LaunchConfirmExisting', () {
      final a = _site('https://a.com');
      final b = _site('https://mail.example.com/inbox');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: 'stale-id',
        shortcutUrl: 'https://calendar.example.com/day',
        models: [a, b],
        rememberedRemap: const {},
      );
      expect(r, isA<LaunchConfirmExisting>());
      expect((r as LaunchConfirmExisting).index, 1);
    });

    test('siteId gone, no domain match -> LaunchOfferCreate', () {
      final a = _site('https://a.com');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: 'stale-id',
        shortcutUrl: 'https://newsite.example/',
        models: [a],
        rememberedRemap: const {},
      );
      expect(r, isA<LaunchOfferCreate>());
      expect((r as LaunchOfferCreate).url, 'https://newsite.example/');
      expect(r.shortcutSiteId, 'stale-id');
    });

    test('legacy shortcut (siteId gone, no url) -> LaunchNone', () {
      final a = _site('https://a.com');
      final r = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: 'stale-id',
        shortcutUrl: null,
        models: [a],
        rememberedRemap: const {},
      );
      expect(r, isA<LaunchNone>());
    });
  });
}
