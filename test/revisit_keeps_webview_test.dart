import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/activation_page.dart';
import 'helpers/model_fixture.dart';
import 'helpers/fake_webview_controller.dart';
import 'helpers/isolations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'LAZY-004: returning to a visited site shows the webview it left, with '
      'no reload', () async {
    final search = WebViewModel(initUrl: 'https://duckduckgo.com/');
    final code = WebViewModel(initUrl: 'https://github.com/');
    final sites = SiteRuntime()
      ..isolation = fakeContainers()
      ..applied(SitesLoaded([search, code]));
    final page = FakeActivationPage();
    final activation = SiteActivationController(
      sites,
      host: page,
      residency: FakeResidency(sites),
      navStates: InMemoryWebViewStateStorage(),
      surface: SurfaceRepaintController(page, repaints: false, traceSuffix: ''),
    );

    await activation.activate(search);
    // The frame builds the shown site's webview.
    const built = SizedBox();
    final controller = FakeWebViewController();
    search
      ..webview = built
      ..controller = controller;

    await activation.activate(code);
    await activation.activate(search);

    expect(sites.shown, same(search));
    expect(sites.loaded, contains(search));
    expect(search.webview, same(built), reason: 'the webview it left');
    expect(search.controller, same(controller));
    expect(controller.calls.where((c) => c == 'reload' || c.startsWith('loadUrl')),
        isEmpty, reason: 'no page reload');
  });
}
