import 'dart:typed_data';

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

/// A tab sent home in place keeps its id, so the back stack saved for it is
/// still the page it was on (#1046).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a site sent home forgets the back stack saved for its tab, so its '
      'next activation opens at home (AOH-004, LIR-011)', () async {
    final bank = WebViewModel(
      initUrl: 'https://bank.example/login',
      alwaysOpenHome: true,
    )..currentUrl = 'https://bank.example/account/123';
    final other = WebViewModel(initUrl: 'https://other.example/');
    final sites = SiteRuntime()
      ..isolation = fakeContainers()
      ..applied(SitesLoaded([bank, other]));
    final navStates = InMemoryWebViewStateStorage();
    await navStates.saveState(bank.activeStateKey,
        state: Uint8List.fromList(const [7, 7, 7]));
    final page = FakeActivationPage();
    final activation = SiteActivationController(
      sites,
      host: page,
      residency: FakeResidency(sites),
      navStates: navStates,
      surface: SurfaceRepaintController(page, repaints: false, traceSuffix: ''),
    );

    await activation.sendHome(bank);

    expect(bank.currentUrl, bank.initUrl);
    expect(await navStates.loadState(bank.activeStateKey), isNull);

    await activation.activate(bank);

    expect(sites.shown, bank);
    expect(bank.tabBinding.queued, isNull,
        reason: 'nothing of the page it was on is restored over home');
  });
}
