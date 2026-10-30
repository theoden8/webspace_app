import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/keyboard_input.dart';
import 'package:webspace/services/page_focus.dart';

/// The page as Flutter holds it: a platform view is a focus node over the
/// native view, which the fake stands in for.
Widget _screen({
  required FocusNode page,
  required FocusNode menu,
  PageFocus? remote,
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
    await tester.pumpWidget(_screen(page: page, menu: menu, remote: PageFocus(keys: PageKeys.remote)));
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
    final remote = PageFocus(keys: PageKeys.remote);
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
    final remote = PageFocus(keys: PageKeys.remote);
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
    final remote = PageFocus(keys: PageKeys.remote);
    await tester.pumpWidget(_screen(page: page, menu: menu, remote: remote));
    page.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    remote.leave(TraversalDirection.up);
    await tester.pump();

    expect(menu.hasPrimaryFocus, isTrue);
  });

  testWidgets(
      'one press moves focus once, so a frame reporting an arrow nobody '
      'pressed moves nothing (NAV-016)', (tester) async {
    final remote = PageFocus(keys: PageKeys.remote);
    await tester.pumpWidget(_screen(page: page, menu: menu, remote: remote));
    page.requestFocus();
    await tester.pump();

    remote.leave(TraversalDirection.up);
    await tester.pump();
    expect(page.hasPrimaryFocus, isTrue, reason: 'no key was pressed');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    remote.leave(TraversalDirection.up);
    await tester.pump();
    expect(page.hasPrimaryFocus, isTrue, reason: 'the key pressed was Down');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    remote.leave(TraversalDirection.up);
    await tester.pump();
    expect(menu.hasPrimaryFocus, isTrue);

    page.requestFocus();
    await tester.pump();
    remote.leave(TraversalDirection.up);
    await tester.pump();
    expect(page.hasPrimaryFocus, isTrue,
        reason: 'that press was answered; a second report of it is nobody\'s');
  });

  testWidgets('a page without focus moves nobody\'s focus', (tester) async {
    final remote = PageFocus(keys: PageKeys.remote);
    await tester.pumpWidget(_screen(page: page, menu: menu, remote: remote));
    menu.requestFocus();
    await tester.pump();

    remote.leave(TraversalDirection.down);
    await tester.pump();

    expect(menu.hasPrimaryFocus, isTrue,
        reason: 'a late report from a page focus has left is not a key press');
  });

  test('the page script names one of the four directions', () {
    expect(PageFocus.edgeOf(['up']), TraversalDirection.up);
    expect(PageFocus.edgeOf(['right']), TraversalDirection.right);
    expect(PageFocus.edgeOf(['sideways']), isNull);
    expect(PageFocus.edgeOf([]), isNull);
    expect(PageFocus.edgeOf([1]), isNull);
    expect(PageFocus.edgeOf(['up', 'down']), isNull);
  });

  test('only a device a remote drives takes the page script (NAV-016)', () {
    final scripts = <inapp.UserScript>[];
    expect(PageFocus.install(keys: null, into: scripts), isNull);
    expect(PageFocus.install(keys: PageKeys.keyboard, into: scripts),
        isNotNull);
    expect(scripts, isEmpty, reason: 'a keyboard never leaves the page');

    expect(PageFocus.install(keys: PageKeys.remote, into: scripts),
        isNotNull);
    expect(scripts, hasLength(1));
    expect(scripts.single.forMainFrameOnly, isFalse,
        reason: 'a key reaches only the frame holding focus, which passes it '
            'up to the top document');
    expect(scripts.single.source, contains(kRemoteEdgeHandler));
  });

  test('only Android wraps a page (NAV-016, NAV-019)', () {
    expect(PageKeys.host, isNull, reason: 'the tests run on a desktop');
  });

  group('a keyboard on Android (NAV-019)', () {
    setUp(() => KeyboardInput.attached.value = false);

    testWidgets('Flutter spends Tab on its own focus unless the page is '
        'wrapped', (tester) async {
      await tester.pumpWidget(_screen(page: page, menu: menu));
      page.requestFocus();
      await tester.pump();

      expect(await tester.sendKeyEvent(LogicalKeyboardKey.tab), isTrue);
      expect(page.hasPrimaryFocus, isFalse);
    });

    testWidgets('a page with focus hands every key on to the webview',
        (tester) async {
      await tester.pumpWidget(_screen(
        page: page,
        menu: menu,
        remote: PageFocus(keys: PageKeys.keyboard),
      ));
      page.requestFocus();
      await tester.pump();

      for (final key in [
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.keyA,
      ]) {
        expect(await tester.sendKeyEvent(key), isFalse,
            reason: '$key goes back to the platform, which gives it the view');
        expect(page.hasPrimaryFocus, isTrue);
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.tab), isFalse,
          reason: 'Shift-Tab moves back through the page\'s own fields');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(page.hasPrimaryFocus, isTrue);
    });

    testWidgets('focus entering the page focuses the webview only while a '
        'keyboard is attached', (tester) async {
      final keyboard = PageFocus(keys: PageKeys.keyboard);
      var asked = 0;
      keyboard.bind(focusView: () async => asked++);
      await tester.pumpWidget(_screen(page: page, menu: menu, remote: keyboard));

      page.requestFocus();
      await tester.pump();
      expect(asked, 0, reason: 'a touch focuses the view itself');

      menu.requestFocus();
      await tester.pump();
      KeyboardInput.attached.value = true;
      page.requestFocus();
      await tester.pump();
      expect(asked, 1, reason: 'Tab from the app bar moves only Flutter\'s focus');
    });
  });
}
