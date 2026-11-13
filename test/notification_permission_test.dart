import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/page_handlers.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/isolations.dart';
import 'helpers/user_script_bridge_fakes.dart';
import 'helpers/host_hooks.dart';
import 'helpers/localized.dart';

const _home = 'https://chat.example/';

/// A view whose top document is [top], as a subframe's request reads it.
final class _View extends FakeUserScriptController {
  _View({required this.top});
  final String top;

  @override
  Future<inapp.WebUri?> getUrl() async => inapp.WebUri(top);
}

/// What the page's `Notification.requestPermission()` resolves to, asked
/// from a document of [origin] in a view showing [top], on a site whose
/// notifications are [enabled]: the handler the polyfill calls, as the
/// site's webview registers it. No grant store, as on a surface that
/// cannot ask.
Future<Object?> _ask({
  required bool enabled,
  required String origin,
  String top = _home,
}) async {
  final view = _View(top: top);
  PageHandlers.registerPageHandlers(
    view,
    config: WebViewConfig(
      posture: WebViewModel(initUrl: _home, notificationsEnabled: enabled)
          .sitePosture(
        globalUserScripts: const <UserScriptConfig>[],
        isolation: fakeContainers(),
      ),
      hooks: inertHostHooks(isolation: fakeContainers),
      initialUrl: _home,
      cacheFirst: false,
    ),
    grants: null,
    userScriptService: serviceWith(const []),
    page: (sourceUrl: () => _home, document: view.page),
  );
  final handler = view.handlers['webNotificationRequestPermission']!;
  return await handler(inapp.JavaScriptHandlerFunctionData(
    isMainFrame: origin == top,
    origin: inapp.WebUri(origin),
    requestUrl: inapp.WebUri(origin),
  ));
}

/// The site's Permissions screen, opened from its settings as the user
/// opens it, under [isolation].
Future<void> _openPermissions(
  WidgetTester tester, {
  required Isolation isolation,
}) async {
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(localizedApp(SettingsScreen(
      webViewModel: WebViewModel(initUrl: _home),
      appTheme: WebViewTheme.system,
      isolation: isolation,
    )));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Permissions'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => SharedPreferences.setMockInitialValues({}));

  test(
      'NOTIF-001: the site asks for notifications and is answered from its '
      'toggle', () async {
    expect(await _ask(enabled: true, origin: 'https://chat.example'),
        'granted');
    expect(await _ask(enabled: false, origin: 'https://chat.example'),
        'denied');
  });

  test(
      'NOTIF-001: a frame of another origin is denied where no one can be '
      'asked, the toggle on (PERM-002)', () async {
    expect(await _ask(enabled: true, origin: 'https://ads.example'), 'denied');
  });

  testWidgets(
      'NOTIF-001: the notifications toggle is offered only where each site '
      'has a container of its own', (tester) async {
    await _openPermissions(tester, isolation: fakeContainers());
    expect(find.text('Notifications'), findsOneWidget);
    await _openPermissions(tester, isolation: fakeSharedJar());
    expect(find.text('Notifications'), findsNothing);
  });
}
