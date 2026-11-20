import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/app.dart';
import 'package:webspace/demo_data.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/launch_context.dart';
import 'package:webspace/settings/app_design.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/demo_mode.dart';

import '../integration_test/helpers/library_tour.dart';
import 'helpers/real_app.dart';

/// The store screenshot tour (SCREENSHOT-003) on the real app with faked
/// webviews, launched as `main()` launches it after the screenshot test seeds
/// the demo: the seed, then the design read off what it wrote. The CI tier
/// takes 45 minutes a device and once captured the legacy design for a whole
/// release without failing (WEBSPACE-019); this walks the same stops in
/// seconds, and fails when the seed reads as an upgrade.
void main() {
  setUp(() => ConnectivityService.onlineOverride = Future.value(true));
  tearDown(() {
    ConnectivityService.reset();
    isDemoMode = false;
    AppPref.legacyDesign.debugValue = AppPref.legacyDesign.fallback;
  });

  for (final seeds in [1, 2]) {
    testWidgets(
      'SCREENSHOT-003: the tour walks the library after $seeds demo seed(s)',
      (tester) async {
        await prepareRealApp(tester, sites: const []);
        // The screenshot test starts each theme on fresh in-memory prefs and
        // seeds again; from the second seed on it runs in demo mode, where a
        // pref's own `set` writes nothing.
        for (var i = 0; i < seeds; i++) {
          SharedPreferences.setMockInitialValues({});
          await seedDemoData(theme: i.isEven ? 'light' : 'dark');
        }
        await loadLegacyDesign(await SharedPreferences.getInstance());
        await tester.pumpWidget(const WebSpaceApp(launch: ProcessLaunch.user));
        await settleRealApp(tester);
        final shots = <String>[];
        await walkLibraryTour(
          tester,
          host: (
            settle: () => settleRealApp(tester),
            pageLoad: () async {},
            shoot: (name) async => shots.add(name),
          ),
        );
        expect(shots, [
          '02-webspace-library',
          '03-work-webspace',
          '01-site-settings',
          '04-workspace-sites-selected',
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
