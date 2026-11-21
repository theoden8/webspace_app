import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/entry_cover.dart';

final _cover = find.byWidgetPredicate(
    (w) => w is AbsorbPointer && w.child is ColoredBox);

/// A launch is covered until it knows its screen, so a shortcut's site comes
/// up with no webspace list on the way, and a warm entry shows no other site
/// (HS-006).
void main() {
  Future<({EntryCover cover, Completer<void> launched})> pump(
      WidgetTester tester) async {
    final launched = Completer<void>();
    final cover = EntryCover(
      card: () => null,
      shown: () => null,
      until: launched.future,
    );
    addTearDown(cover.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Stack(children: [const Text('list'), cover.view()]),
    ));
    return (cover: cover, launched: launched);
  }

  testWidgets('a launch starts covered and shows the list once it opens none',
      (tester) async {
    final (:cover, launched: _) = await pump(tester);
    expect(_cover, findsOneWidget, reason: 'the shortcut is not read yet');
    cover.decided(null);
    await tester.pump();
    expect(_cover, findsNothing);
  });

  testWidgets('a launch that opens a site stays covered until the launch '
      'ends, and no longer than the cap', (tester) async {
    final (:cover, :launched) = await pump(tester);
    cover.decided(WebViewModel(initUrl: 'https://ddg.example.test'));
    await tester.pump(Motion.launchHold ~/ 2);
    expect(_cover, findsOneWidget, reason: 'the site is not up yet');
    launched.complete();
    await tester.pump();
    await tester.pump();
    expect(_cover, findsNothing);

    final (cover: capped, launched: _) = await pump(tester);
    capped.decided(WebViewModel(initUrl: 'https://ddg.example.test'));
    await tester.pump(Motion.launchHold);
    await tester.pump();
    expect(_cover, findsNothing, reason: 'a slow launch shows as it is');
  });

  testWidgets('a warm entry covers the page until its switch has finished',
      (tester) async {
    final (:cover, :launched) = await pump(tester);
    launched.complete();
    await tester.pump();
    expect(_cover, findsNothing);
    final switched = Completer<void>();
    final entering = cover.over(
      WebViewModel(initUrl: 'https://ddg.example.test'),
      show: () => switched.future,
    );
    await tester.pump();
    expect(_cover, findsOneWidget);
    switched.complete();
    await entering;
    await tester.pump();
    expect(_cover, findsNothing);
  });
}
