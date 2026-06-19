// Notification-site auto-load parity integration test.
//
// Guards the behaviour this branch changed: notification sites auto-load on
// cold start (so they can poll + fire notifications without being opened), but
// their load was moved OFF the first-frame path (deferred post-paint in
// container mode; pre-paint in legacy mode) and each one's HTML is now
// decrypted per-site via `_ensureSiteHtml` instead of a bulk preload. Parity:
//   - a notification site's webview slot still materialises after launch
//     (auto-load completes, and the per-site HTML preload didn't break it), and
//   - a non-notification, never-visited site stays a `SizedBox.shrink()`
//     placeholder (lazy loading preserved).
//
// Like lazy_webview_loading_test, the only public signal that a webview was
// constructed for a site is its `ValueKey(siteId)` slot, so the test asserts on
// key presence/absence. Site activation mounts a real WebView; the wayland +
// WEBKIT_DISABLE_SANDBOX chroot harness is required (see
// openspec/specs/integration-tests/spec.md). Cannot run under plain
// `flutter test`.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';
import 'package:webspace/web_view_model.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    isDemoMode = true;

    // RFC 5737 reserved test addresses — they won't connect; the assertion is
    // on widget-tree shape, not page content.
    final notifSite = WebViewModel(
      siteId: 'notif-auto',
      initUrl: 'http://192.0.2.10/',
      name: 'Notif Auto',
      notificationsEnabled: true,
    );
    final plainSite = WebViewModel(
      siteId: 'plain-idle',
      initUrl: 'http://192.0.2.11/',
      name: 'Plain Idle',
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [
        jsonEncode(notifSite.toJson()),
        jsonEncode(plainSite.toJson()),
      ],
    });
  });

  testWidgets(
      'notification site auto-loads; idle site stays a lazy placeholder',
      (tester) async {
    app.main();
    await tester.pump(const Duration(seconds: 1));

    bool hasKey(String siteId) =>
        find.byKey(ValueKey(siteId), skipOffstage: false).evaluate().isNotEmpty;

    // pumpAndSettle deadlocks on a live WebView; pump in slices and stop as
    // soon as the predicate holds (tolerant to wide WebView-mount variance
    // between local chroot and CI).
    Future<void> pumpUntil(
      bool Function() predicate, {
      Duration timeout = const Duration(seconds: 45),
      Duration step = const Duration(milliseconds: 250),
      required String description,
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(step);
        if (predicate()) return;
      }
      throw StateError(
          'Timed out after ${timeout.inSeconds}s waiting for: $description');
    }

    // The notif site is never tapped — it must materialise on its own because
    // it's notification-enabled (auto-load), proving the deferred load + the
    // per-site HTML preload completed without leaving it blank.
    await pumpUntil(
      () => hasKey('notif-auto'),
      description: 'notification site slot to auto-materialise',
    );

    expect(find.byKey(const ValueKey('notif-auto'), skipOffstage: false),
        findsOneWidget,
        reason: 'notification-enabled site should auto-load its webview slot');
    expect(find.byKey(const ValueKey('plain-idle'), skipOffstage: false),
        findsNothing,
        reason: 'a non-notification, unvisited site must stay a lazy '
            'placeholder (no slot)');
  });
}
