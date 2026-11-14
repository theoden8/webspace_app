import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/page_handlers.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/host_hooks.dart';
import 'helpers/isolations.dart';
import 'helpers/user_script_bridge_fakes.dart';

const _home = 'https://chat.example/';

/// A view that counts the reads of its top document, the handler's first
/// step past the gate.
final class _View extends FakeUserScriptController {
  int urlReads = 0;

  @override
  Future<inapp.WebUri?> getUrl() async {
    urlReads++;
    return inapp.WebUri(_home);
  }
}

/// The view after a frame of it posts a notification, the site's webview
/// registering the handler with [shown] as whether its tab is on screen.
/// The frame is of another origin with no grant, so a post that passes the
/// gate ends at the grant check and reaches no platform.
Future<_View> _post({required bool shown}) async {
  final view = _View();
  PageHandlers.registerPageHandlers(
    view,
    config: WebViewConfig(
      posture: WebViewModel(initUrl: _home, notificationsEnabled: true)
          .sitePosture(
            globalUserScripts: const <UserScriptConfig>[],
            isolation: fakeContainers(),
          ),
      hooks: inertHostHooks(isolation: fakeContainers),
      initialUrl: _home,
      cacheFirst: false,
      speaksForSite: () => shown,
    ),
    grants: null,
    userScriptService: serviceWith(const []),
    page: (sourceUrl: () => _home, document: view.page),
  );
  await view.handlers['webNotification']!(
    inapp.JavaScriptHandlerFunctionData(
      args: [
        {'title': 'New message', 'body': 'hi'},
      ],
      isMainFrame: false,
      origin: inapp.WebUri('https://ads.example'),
      requestUrl: inapp.WebUri('https://ads.example/frame'),
    ),
  );
  return view;
}

void main() {
  setUpAll(() => SharedPreferences.setMockInitialValues({}));

  test("TAB-025: a warm tab's post is dropped at the bridge, before it is "
      'checked or shown', () async {
    expect((await _post(shown: false)).urlReads, 0);
    expect((await _post(shown: true)).urlReads, greaterThan(0));
  });
}
