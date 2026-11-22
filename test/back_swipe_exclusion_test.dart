import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/back_swipe_exclusion.dart';
import 'package:webspace/widgets/sidebar_arrow_tab.dart';

import 'helpers/localized.dart';

/// TAB-032: on Android the sidebar's arrow tab claims its own strip of the
/// left edge from the system back swipe, so a drag from the edge pulls the
/// sidebar out rather than going back. Android applies the claim to the
/// window (`View.setSystemGestureExclusionRects`), which no test here reaches;
/// these hold what the app tells it.
void main() {
  const channel = MethodChannel('test/back_swipe_exclusion');
  late List<List<Object?>> told;

  setUp(() {
    told = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setRects') {
        told.add(List<Object?>.from(call.arguments as List));
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Widget tab({required double top, required BackSwipeExclusion exclusion}) =>
      localizedApp(Scaffold(
        body: Stack(children: [
          Positioned(
            left: 0,
            top: top,
            child: SidebarArrowTab(
              exclusion: exclusion,
              onTap: () {},
              onPull: (_) {},
              onPullEnd: () {},
              onMove: (_) {},
              onMoveEnd: () {},
            ),
          ),
        ]),
      ));

  testWidgets('TAB-032 the arrow tab claims its own strip of the edge, in '
      'device pixels, follows it as it moves and gives it back when it goes',
      (tester) async {
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    final exclusion = BackSwipeExclusion(claims: true, channel: channel);

    await tester.pumpWidget(tab(top: 100, exclusion: exclusion));
    await tester.pump();
    final size = SidebarArrowTab.size;
    expect(told.last, [
      [0.0, 200.0, size.width * 2, (100 + size.height) * 2],
    ]);

    await tester.pumpWidget(tab(top: 300, exclusion: exclusion));
    await tester.pump();
    expect(told.last, [
      [0.0, 600.0, size.width * 2, (300 + size.height) * 2],
    ]);
    final sent = told.length;
    await tester.pump();
    expect(told.length, sent, reason: 'an unmoved tab tells Android nothing');

    await tester.pumpWidget(localizedApp(const Scaffold()));
    await tester.pump();
    expect(told.last, isEmpty, reason: 'the edge is the system\'s again');
  });

  testWidgets('where no platform keeps a claim nothing is sent',
      (tester) async {
    final exclusion = BackSwipeExclusion(claims: false, channel: channel);
    await tester.pumpWidget(tab(top: 100, exclusion: exclusion));
    await tester.pump();
    expect(told, isEmpty);
  });
}
