import 'dart:async';

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
/// moved (`integration_test/proxy_router_fallback_test.dart`, PROXY-008), so
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

    a.disposeWebView(commit: const Commit.unmodeled(Unmodeled.rebuild));
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

  /// The rule busy with another write as [a] lets go of its webview, and the
  /// frame that unmounts the webview run before the rule's turn comes: what
  /// the webview had been told when [b]'s proxy took the rule. [letGo] is
  /// how [a] lets go.
  Future<({bool blocked, bool stopped})?> quietWhileBusy({
    required FakeWebViewController controller,
    required void Function(WebViewModel a) letGo,
  }) async {
    final a = WebViewModel(
      siteId: SiteId('dispose-a'),
      initUrl: 'http://a.test/',
    );
    a.controller = controller;
    await rule.claim(
      a.routeClaim.occupant,
      route: _route('a:8080'),
      write: () async {},
    );
    final busy = Completer<void>();
    final held = rule.vacate(const [], close: () => busy.future);
    letGo(a);
    controller.unmount();
    busy.complete();
    await held;
    ({bool blocked, bool stopped})? whenMoved;
    await rule.claim(
      (use: RouteUse.webview, site: SiteId('dispose-b')),
      route: _route('b:8080'),
      write: () async => whenMoved = (
        blocked: controller.networkBlocked,
        stopped: controller.stopped,
      ),
    );
    return whenMoved;
  }

  test('a webview let go of is quieted in that turn, though the rule is busy '
      'and the frame unmounts it first (PROXY-008)', () async {
    final controller = FakeWebViewController();
    expect(
      await quietWhileBusy(
        controller: controller,
        letGo: (a) =>
            a.disposeWebView(commit: const Commit.unmodeled(Unmodeled.rebuild)),
      ),
      (blocked: true, stopped: true),
      reason: "a's block and stop must go out before the frame that unmounts "
          'its webview: the plugin answers nothing sent after it',
    );
  });

  test('planted: a quiet asked for only in the rule\'s turn reaches a '
      'webview already unmounted, and b\'s proxy takes the rule over a '
      'webview still loading', () async {
    final controller = FakeWebViewController();
    expect(
      await quietWhileBusy(
        controller: controller,
        // disposeWebView before BUG-037 attempt 19: the quiet started when
        // the rule's turn came.
        letGo: (a) => unawaited(
          rule.leave(a.routeClaim.occupant, quiet: controller.quiet),
        ),
      ),
      (blocked: false, stopped: false),
    );
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
    a.disposeWebView(commit: const Commit.unmodeled(Unmodeled.rebuild));
    expect(rule.occupants, isEmpty);
  });
}
