// Linux integration smoke test — proves the integration_test
// pipeline works on Linux desktop (WPE WebKit + GTK), and exercises
// the App Settings screen path that touches the recent proxy / backup
// fix area (PR #266 + the proxy_password_secure_storage migration).
//
// Scope is intentionally narrow: boot the app, reach App Settings,
// assert the Export/Import buttons render. That's enough to prove:
//   * Linux Flutter desktop builds and launches under Xvfb in CI
//   * SharedPreferences default-init works (no crash on cold start)
//   * The webspaces-list / drawer / settings navigation chain
//     renders without hitting an exception
//   * The settings-backup UI surface (the recent proxy auth fix
//     touched _exportSettings / _importSettings indirectly) is
//     reachable and renders its expected rows
//
// Deeper scenarios (settings backup roundtrip with proxy passwords
// preserved, navigation race guards) want this same harness extended
// to drive file-picker mocks and rapid-input sequences. Adding those
// is straightforward once this smoke test confirms the harness works
// in CI; the goal here is to pin the pipeline before the harness is
// invested in.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Empty SharedPreferences — fresh-install state, no seeded sites.
    SharedPreferences.setMockInitialValues({});
    // isDemoMode = true bypasses persistence so the test never writes
    // to the host's real SharedPreferences (CI runners share state
    // across test runs without this).
    isDemoMode = true;
  });

  testWidgets('App boots on Linux and reaches App Settings', (tester) async {
    app.main();
    // pumpAndSettle drives the splash → first frame → first idle
    // sequence. 30s is generous for the slow CI runner; locally this
    // settles in <1s.
    await tester.pumpAndSettle(const Duration(seconds: 30));

    // The App Settings icon button is rendered on the webspaces-list
    // screen (no site selected). With empty SharedPreferences and
    // isDemoMode=true, the app boots straight into that screen.
    final settingsButton = find.byTooltip('App Settings');
    expect(settingsButton, findsOneWidget,
      reason: 'App Settings icon should be visible on empty webspaces list');

    await tester.tap(settingsButton);
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // The settings screen renders an Export Settings + Import Settings
    // pair. They're the entry points for the JSON backup flow that
    // the recent proxy-auth-wipe fix (PR #266) touches indirectly via
    // _exportSettings / _importSettings in main.dart.
    expect(find.text('Export Settings'), findsOneWidget,
      reason: 'Export Settings list tile should render');
    expect(find.text('Import Settings'), findsOneWidget,
      reason: 'Import Settings list tile should render');

    // Verify we can scroll the settings screen — proves the
    // ListView/Scrollable inside the screen layouts correctly under
    // the Linux desktop renderer's DPR. Without this, a regression
    // that broke the layout (e.g. infinite-height ListView in a
    // Column) would surface as an exception in pumpAndSettle but
    // could be silently swallowed in less obvious ways.
    final scrollable = find.byType(Scrollable).first;
    expect(scrollable, findsOneWidget);
    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pumpAndSettle();
  });
}
