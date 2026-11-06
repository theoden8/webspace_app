import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/activation_page.dart';
import 'helpers/fake_webview_controller.dart';
import 'helpers/isolations.dart';
import 'helpers/model_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// TLC accepts the guard's removal (the base world, 16.7M states): a
  /// second plan that picks the same victim is spared when its unload asks
  /// again (BUG-033). What the guard saves is the second plan's work, which
  /// this checks.
  test('PAUSE-011: a memory-pressure event while one still applies its plan '
      'is dropped', () async {
    final shown = WebViewModel(initUrl: 'https://mail.example/');
    final behind = WebViewModel(initUrl: 'https://news.example/');
    final sites = SiteRuntime()
      ..isolation = fakeContainers()
      ..applied(SitesLoaded([shown, behind]));
    final page = FakeActivationPage();
    final activation = SiteActivationController(
      sites,
      host: page,
      residency: FakeResidency(sites),
      navStates: InMemoryWebViewStateStorage(),
      surface: SurfaceRepaintController(page, repaints: false, traceSuffix: ''),
    );
    await activation.activate(behind);
    final view = FakeWebViewController();
    behind
      ..webview = const SizedBox()
      ..controller = view;
    await activation.activate(shown);
    expect(sites.loaded, containsAll([shown, behind]));

    final clearing = Completer<void>();
    view.pace = (call) => call == PlatformCall.webViewClearCache
        ? clearing.future
        : Future<void>.value();
    final first = activation.memoryPressure();
    await pumpEventQueue();
    expect(view.calls, isNot(contains('clearCache')),
        reason: "the first plan's cache clear is out");
    final second = activation.memoryPressure();
    await pumpEventQueue();
    clearing.complete();
    await Future.wait([first, second]);

    expect(view.calls.where((c) => c == 'clearCache'), hasLength(1));
  });
}
