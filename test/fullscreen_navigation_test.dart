import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/activation_page.dart';
import 'helpers/isolations.dart';
import 'helpers/model_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('FS-005: going to the webspace list leaves full screen', () async {
    final video = WebViewModel(initUrl: 'https://video.example/')
      ..fullscreenMode = true;
    final sites = SiteRuntime()
      ..isolation = fakeContainers()
      ..applied(SitesLoaded([video]));
    final page = FakeActivationPage();
    final activation = SiteActivationController(
      sites,
      host: page,
      residency: FakeResidency(sites),
      navStates: InMemoryWebViewStateStorage(),
      surface: SurfaceRepaintController(page, repaints: false, traceSuffix: ''),
    );

    await activation.activate(video);
    expect(page.fullscreen, isTrue, reason: 'a full-screen site opens so (FS-003)');

    await activation.activate(null);
    expect(sites.shown, isNull);
    expect(page.fullscreen, isFalse);
  });
}
