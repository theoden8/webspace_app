import 'dart:ui' show AppLifecycleState;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// FS-004. The OS shows the system bars again while the app is away, so a
/// resume in full screen asks for the immersive mode anew; out of full screen
/// it asks for none.
void main() {
  const immersiveSticky = 'SystemUiMode.immersiveSticky';
  late List<String> modes;

  Future<void> openSite(WidgetTester tester, {required bool fullscreen}) async {
    modes = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'SystemChrome.setEnabledSystemUIMode':
            modes.add(call.arguments as String);
          case 'SystemChrome.setEnabledSystemUIOverlays':
            modes.add('SystemUiMode.manual ${call.arguments}');
        }
        return null;
      },
    );
    final site = WebViewModel(
      initUrl: 'https://example.com',
      name: 'Example',
      fullscreenMode: fullscreen,
    );
    await pumpRealApp(tester, sites: [site]);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Example');
  }

  Future<void> goThrough(WidgetTester tester,
      {required List<AppLifecycleState> states}) async {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    await settleRealApp(tester);
  }

  const away = [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ];
  const back = [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ];

  testWidgets('a resume in full screen applies the immersive mode again '
      '(FS-004)', (tester) async {
    await openSite(tester, fullscreen: true);
    expect(modes.last, immersiveSticky, reason: 'the site opened in full screen');

    await goThrough(tester, states: away);
    modes.clear();
    await goThrough(tester, states: back);
    expect(modes, contains(immersiveSticky));
  });

  testWidgets('a resume out of full screen asks for no immersive mode '
      '(FS-004)', (tester) async {
    await openSite(tester, fullscreen: false);
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);

    await goThrough(tester, states: away);
    modes.clear();
    await goThrough(tester, states: back);
    expect(modes.where((m) => m.startsWith('SystemUiMode.immersive')), isEmpty);
  });
}
