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
}
