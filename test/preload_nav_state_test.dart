import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/startup_controller.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/services/deferred_startup_engine.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/activation_page.dart';
import 'helpers/isolations.dart';
import 'helpers/model_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test("PAUSE-035: a preload queues the site's saved back stack as it loads "
      'it, since no later activation reads it', () async {
    final site = WebViewModel(
      initUrl: 'https://chat.example/',
      notificationsEnabled: true,
    );
    final sites = SiteRuntime()
      ..isolation = fakeContainers()
      ..applied(SitesLoaded([site]));
    final saved = Uint8List.fromList(const [7, 7, 7]);
    final navStates = InMemoryWebViewStateStorage();
    await navStates.saveState(site.activeStateKey, state: saved);
    final page = FakeActivationPage();
    final activation = SiteActivationController(
      sites,
      host: page,
      residency: FakeResidency(sites),
      navStates: navStates,
      surface: SurfaceRepaintController(page, repaints: false, traceSuffix: ''),
    );

    final outcome = await activation.preload(site.siteId,
        after: const Reached.inTest());

    expect(outcome, PreloadOutcome.loaded);
    expect(sites.loaded, contains(site));
    expect(sites.shown, isNull, reason: 'a preload does not show');
    expect(site.tabBinding.queuedFor, site.activeTabId);
    expect(site.tabBinding.queued?.bytes, saved,
        reason: 'the first build restores what the last session saved');
  });
}
