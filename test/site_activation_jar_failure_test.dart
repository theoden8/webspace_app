import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/activation_page.dart';
import 'helpers/isolations.dart';
import 'helpers/mock_cookie_manager.dart';
import 'helpers/model_fixture.dart';

/// A site opened while the shared jar does not answer is not shown: until
/// the jar is emptied and refilled it can hold another same-base-domain
/// site's session (ISO-001).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'ISO-014: an activation whose cookie restore fails shows the webspace '
      'list and says why, not the site', () async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    final jar = MockCookieManager();
    final shown = WebViewModel(initUrl: 'https://example.com/', name: 'Example');
    final target = WebViewModel(initUrl: 'https://github.com/', name: 'GitHub');
    final sites = SiteRuntime()
      ..isolation = fakeSharedJar(cookies: jar)
      ..applied(SitesLoaded([shown, target]));
    final page = FakeActivationPage();
    final activation = SiteActivationController(
      sites,
      host: page,
      residency: FakeResidency(sites),
      navStates: InMemoryWebViewStateStorage(),
      surface: SurfaceRepaintController(page, repaints: false, traceSuffix: ''),
    );
    await activation.activate(shown);
    expect(sites.shown, shown);

    jar.failing.add(JarCall.read);
    await activation.activate(target);

    expect(sites.shown, isNull,
        reason: 'the list, not the site on screen before the tap');
    expect(sites.loaded, isNot(contains(target)));
    expect(page.exitedFullscreen, isTrue);
    expect(page.toasts.map((m) => m(en)),
        ['Could not open GitHub: its cookies could not be restored']);
  });
}
