import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/widgets/page_layer.dart';

/// NAV-016: the page keeps the library and the sites mounted one over the
/// other. A layer not on screen must let go of focus, or a remote's arrows go
/// on to a page nobody sees.
void main() {
  late FocusNode site;
  late FocusNode icon;

  setUp(() {
    site = FocusNode(debugLabel: 'site page');
    icon = FocusNode(debugLabel: 'library icon');
  });
  tearDown(() {
    site.dispose();
    icon.dispose();
  });

  Widget page({required bool siteShown}) => MaterialApp(
        home: Stack(
          children: [
            PageLayer(
              shown: !siteShown,
              child: Center(
                child: TextButton(
                  focusNode: icon,
                  onPressed: () {},
                  child: const Text('icon'),
                ),
              ),
            ),
            PageLayer(
              shown: siteShown,
              child: Focus(focusNode: site, child: const SizedBox.expand()),
            ),
          ],
        ),
      );

  testWidgets('a layer leaving the screen takes its focus with it (NAV-016)',
      (tester) async {
    await tester.pumpWidget(page(siteShown: true));
    site.requestFocus();
    await tester.pump();
    expect(site.hasPrimaryFocus, isTrue);

    await tester.pumpWidget(page(siteShown: false));
    await tester.pump();
    expect(site.hasFocus, isFalse, reason: 'the hidden page keeps no focus');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(icon.hasPrimaryFocus, isTrue,
        reason: 'an arrow reaches the layer on screen');
  });

  testWidgets('a hidden layer is never moved into', (tester) async {
    await tester.pumpWidget(page(siteShown: false));
    icon.requestFocus();
    await tester.pump();

    for (final key in [
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.tab,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(site.hasFocus, isFalse, reason: '$key');
    }
  });
}
