import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/fake_webview_controller.dart';

ProxyRouteKey _route(String address) =>
    (type: ProxyType.HTTP, address: address, username: null, password: null);

/// A webview the app lets go of keeps loading until the plugin destroys it,
/// after it has loaded `about:blank`. On the emulator an icon fetched in that
/// window left through the next site's proxy once the process-wide rule had
/// moved (`integration_test/proxy_one_rule_test.dart`, PROXY-008), so
/// the site's claim on the rule ends only once the webview loads nothing
/// more and has stopped what it had started (BUG-037).
void main() {
  final rule = ProcessRoute.instance;

  setUp(rule.resetForTest);
  tearDown(rule.resetForTest);

  test('a disposed webview is blocked and stopped before the rule moves '
      '(PROXY-008)', () async {
    final a = WebViewModel(
      siteId: SiteId('dispose-a'),
      initUrl: 'http://a.test/',
    );
    final controller = FakeWebViewController();
    a.controller = controller;
    await rule.claim(
      a.routeClaim.occupant,
      route: _route('a:8080'),
      write: () async {},
    );

    a.disposeWebView(commit: const Commit.environment(Environment.letGo));
    expect(a.controller, isNull);
    ({bool blocked, bool stopped})? whenMoved;
    await rule.claim(
      (use: RouteUse.webview, site: SiteId('dispose-b')),
      route: _route('b:8080'),
      write: () async => whenMoved = (
        blocked: controller.networkBlocked,
        stopped: controller.stopped,
      ),
    );

    expect(
      whenMoved,
      (blocked: true, stopped: true),
      reason: "a's webview could still send when b's proxy took the rule: "
          'a block reaches only requests not yet intercepted, so what it '
          'had already started must be stopped too',
    );
    expect(rule.occupants.keys, {
      (use: RouteUse.webview, site: SiteId('dispose-b')),
    });
  });

  test('a webview never built leaves the rule at once', () async {
    final a = WebViewModel(
      siteId: SiteId('dispose-a'),
      initUrl: 'http://a.test/',
    );
    await rule.claim(
      a.routeClaim.occupant,
      route: _route('a:8080'),
      write: () async {},
    );
    a.disposeWebView(commit: const Commit.environment(Environment.letGo));
    expect(rule.occupants, isEmpty);
  });
}
