import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_network_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/activation_page.dart';
import 'helpers/isolations.dart';
import 'helpers/model_fixture.dart';

/// Revoking a pinned certificate unloads the sites whose home is on its
/// host as a home reset does (ISO-002): one off screen leaves the loaded
/// set, and the one on screen stays loaded with its webview let go of, so
/// the frame builds it afresh and the screen never shows a site that is not
/// loaded (LAZY-007). The revoke used to take every pinned site out of the
/// loaded set itself, the one on screen too, which left LAZY-003's
/// placeholder where the site was, in a write the model did not see.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SiteNetworkController.clearCache = () async => false;
  });

  test(
      "LAZY-007: a revoked pin unloads its host's sites off screen and keeps "
      'the one on screen loaded', () async {
    final shown =
        WebViewModel(initUrl: 'https://self.example:8443/', name: 'Shown');
    final away =
        WebViewModel(initUrl: 'https://self.example:8443/away', name: 'Away');
    final other = WebViewModel(initUrl: 'https://other.example/', name: 'Other');
    final sites = SiteRuntime()
      ..isolation = fakeContainers()
      ..applied(SitesLoaded([shown, away, other]));
    final page = FakeActivationPage();
    final residency = FakeResidency(sites);
    final activation = SiteActivationController(
      sites,
      host: page,
      residency: residency,
      navStates: InMemoryWebViewStateStorage(),
      surface: SurfaceRepaintController(page, repaints: false, traceSuffix: ''),
    );
    final network = SiteNetworkController(
      sites,
      host: page,
      residency: residency,
      activation: activation,
    );
    await activation.activate(away);
    await activation.activate(other);
    await activation.activate(shown);
    expect(sites.loaded, {shown, away, other});

    await network.pinRevoked(const TrustedHostEntry(
      host: 'self.example',
      port: 8443,
      sha256Hex: 'ab',
    ));

    expect(sites.shown, shown);
    expect(sites.loaded, {shown, other});
  });
}
