import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/remote_focus.dart';
import 'package:webspace/services/remote_input.dart';

/// The page as Flutter holds it: a platform view is a focus node over the
/// native view, which the fake stands in for.
Widget _screen({
  required FocusNode page,
  required FocusNode menu,
  RemoteFocus? remote,
}) {
  final view = Focus(focusNode: page, child: const SizedBox.expand());
  return MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          TextButton(
            focusNode: menu,
            onPressed: () {},
            child: const Text('menu'),
          ),
          Expanded(child: remote?.wrap(view) ?? view),
        ],
      ),
    ),
  );
}

void main() {
  late FocusNode page;
  late FocusNode menu;

  setUp(() {
    page = FocusNode(debugLabel: 'page');
    menu = FocusNode(debugLabel: 'menu');
  });
  tearDown(() {
    page.dispose();
    menu.dispose();
    RemoteInput.debugDrivenOverride = null;
  });

  testWidgets(
      'Flutter spends an arrow on its own focus unless the page is wrapped '
      '(NAV-016)', (tester) async {
    await tester.pumpWidget(_screen(page: page, menu: menu));
    page.requestFocus();
    await tester.pump();

    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);

    expect(handled, isTrue, reason: 'the default traversal takes the key');
    expect(page.hasPrimaryFocus, isFalse,
        reason: 'and moves focus off the page, so the webview never sees it');
  });

  testWidgets('a page with focus hands the D-pad on to the webview (NAV-016)',
      (tester) async {
    await tester.pumpWidget(_screen(page: page, menu: menu, remote: RemoteFocus()));
    page.requestFocus();
    await tester.pump();

    for (final key in [
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.enter,
    ]) {
      expect(await tester.sendKeyEvent(key), isFalse,
          reason: '$key goes back to the platform, which gives it the view');
      expect(page.hasPrimaryFocus, isTrue);
    }
  });

  testWidgets('focus entering the page focuses the webview (NAV-016)',
      (tester) async {
    final remote = RemoteFocus();
    var asked = 0;
    remote.bind(focusView: () async => asked++);
    await tester.pumpWidget(_screen(page: page, menu: menu, remote: remote));
    expect(asked, 0);

    page.requestFocus();
    await tester.pump();
    expect(asked, 1);

    FocusManager.instance.primaryFocus?.focusInDirection(TraversalDirection.up);
    await tester.pump();
    expect(asked, 1, reason: 'leaving asks nothing of the view');
  });

  testWidgets('a view built after focus entered is focused as it attaches',
      (tester) async {
    final remote = RemoteFocus();
    await tester.pumpWidget(_screen(page: page, menu: menu, remote: remote));
    page.requestFocus();
    await tester.pump();

    var asked = 0;
    remote.bind(focusView: () async => asked++);
    expect(asked, 1);
  });

  testWidgets(
      'an arrow the page had no use for moves focus out toward it (NAV-016)',
      (tester) async {
    final remote = RemoteFocus();
    await tester.pumpWidget(_screen(page: page, menu: menu, remote: remote));
    page.requestFocus();
    await tester.pump();

    remote.leave(TraversalDirection.up);
    await tester.pump();

    expect(menu.hasPrimaryFocus, isTrue);
  });

  testWidgets('a page without focus moves nobody\'s focus', (tester) async {
    final remote = RemoteFocus();
    await tester.pumpWidget(_screen(page: page, menu: menu, remote: remote));
    menu.requestFocus();
    await tester.pump();

    remote.leave(TraversalDirection.down);
    await tester.pump();

    expect(menu.hasPrimaryFocus, isTrue,
        reason: 'a late report from a page focus has left is not a key press');
  });

  test('the page script names one of the four directions', () {
    expect(RemoteFocus.edgeOf(['up']), TraversalDirection.up);
    expect(RemoteFocus.edgeOf(['right']), TraversalDirection.right);
    expect(RemoteFocus.edgeOf(['sideways']), isNull);
    expect(RemoteFocus.edgeOf([]), isNull);
    expect(RemoteFocus.edgeOf([1]), isNull);
    expect(RemoteFocus.edgeOf(['up', 'down']), isNull);
  });

  test('only a device a remote drives takes the page script (NAV-016)', () {
    final scripts = <inapp.UserScript>[];
    RemoteInput.debugDrivenOverride = false;
    expect(RemoteFocus.install(into: scripts), isNull);
    expect(scripts, isEmpty);

    RemoteInput.debugDrivenOverride = true;
    expect(RemoteFocus.install(into: scripts), isNotNull);
    expect(scripts, hasLength(1));
    expect(scripts.single.forMainFrameOnly, isTrue);
    expect(scripts.single.source, contains(kRemoteEdgeHandler));
  });
}
