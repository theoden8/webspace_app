import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/page_focus.dart';
import 'package:webspace/services/remote_input.dart';
import 'package:webspace/widgets/remote_controls.dart';

/// What `app.dart` wraps the navigator in: a remote's keys, a desktop's, or
/// none, as a phone has it.
enum _Keys { remote, desktop, none }

Widget _app(Widget home, {_Keys keys = _Keys.remote}) => MaterialApp(
      builder: switch (keys) {
        _Keys.remote => (context, child) => RemoteControls(child: child!),
        _Keys.desktop => (context, child) => KeyNavigation(child: child!),
        _Keys.none => null,
      },
      home: Scaffold(body: home),
    );

final _ring = find.byKey(KeyNavigation.ringKey);

void main() {
  late FocusNode field;
  late FocusNode below;

  setUp(() {
    field = FocusNode(debugLabel: 'field');
    below = FocusNode(debugLabel: 'below');
  });
  tearDown(() {
    field.dispose();
    below.dispose();
  });

  Widget form({int maxLines = 1}) => Column(
        children: [
          TextField(focusNode: field, maxLines: maxLines),
          TextButton(focusNode: below, onPressed: () {}, child: const Text('go')),
        ],
      );

  testWidgets(
      'a one-line field keeps Up and Down on every other device, so a remote '
      'is stuck in it', (tester) async {
    await tester.pumpWidget(_app(form(), keys: _Keys.none));
    field.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(field.hasPrimaryFocus, isTrue);
  });

  testWidgets('Up and Down leave a one-line text field (NAV-016)',
      (tester) async {
    await tester.pumpWidget(_app(form()));
    field.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(below.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(field.hasPrimaryFocus, isTrue);
  });

  group('a slider (NAV-016)', () {
    late FocusNode slider;
    setUp(() => slider = FocusNode(debugLabel: 'slider'));
    tearDown(() => slider.dispose());

    Widget settings({required ValueChanged<double> onChanged}) => Column(
          children: [
            Slider(focusNode: slider, value: 0.5, onChanged: onChanged),
            TextButton(focusNode: below, onPressed: () {}, child: const Text('go')),
          ],
        );

    testWidgets('takes Down as a change of its value on every other device',
        (tester) async {
      final values = <double>[];
      await tester.pumpWidget(_app(settings(onChanged: values.add), keys: _Keys.none));
      slider.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      expect(values, isNotEmpty);
      expect(slider.hasPrimaryFocus, isTrue);
    });

    testWidgets('leaves Down to the remote\'s focus moves, and keeps Left and '
        'Right for its value', (tester) async {
      final values = <double>[];
      await tester.pumpWidget(_app(settings(onChanged: values.add)));
      slider.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(values, hasLength(1));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(values, hasLength(1), reason: 'Down is not a change of value');
      expect(below.hasPrimaryFocus, isTrue);
    });
  });

  group('the on-screen keyboard (NAV-016)', () {
    /// The input type the platform was last told the field takes: none while
    /// the keyboard is held back.
    String? inputType(WidgetTester tester) =>
        switch (tester.testTextInput.setClientArgs?['inputType']) {
          {'name': final String name} => name,
          _ => null,
        };
    bool keyboardUp(WidgetTester tester) =>
        tester.testTextInput.isVisible &&
        inputType(tester) != 'TextInputType.none';

    testWidgets('comes up as focus lands on a field on every other device',
        (tester) async {
      await tester.pumpWidget(_app(form(), keys: _Keys.none));
      below.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();

      expect(field.hasPrimaryFocus, isTrue);
      expect(keyboardUp(tester), isTrue);
    });

    testWidgets('waits for OK in a field the D-pad lands on, and is held back '
        'again once focus leaves it', (tester) async {
      await tester.pumpWidget(_app(form()));
      below.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(field.hasPrimaryFocus, isTrue);
      expect(keyboardUp(tester), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(keyboardUp(tester), isTrue);
      expect(field.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(below.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(field.hasPrimaryFocus, isTrue);
      expect(keyboardUp(tester), isFalse,
          reason: 'OK opened it for one visit to the field');
    });

    testWidgets('waits for OK in a field that takes focus by itself',
        (tester) async {
      await tester.pumpWidget(_app(TextField(focusNode: field, autofocus: true)));
      await tester.pump();
      expect(field.hasPrimaryFocus, isTrue);
      expect(keyboardUp(tester), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(keyboardUp(tester), isTrue);
    });

    testWidgets('OK on any other control goes on to it', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(_app(TextButton(
        focusNode: below,
        onPressed: () => pressed++,
        child: const Text('go'),
      )));
      below.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(pressed, 1);
    });
  });

  testWidgets('Left and Right stay with the caret', (tester) async {
    await tester.pumpWidget(_app(form()));
    field.requestFocus();
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'abc');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(field.hasPrimaryFocus, isTrue);
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.selection.baseOffset, 2);
  });

  testWidgets('a field of several lines keeps Up and Down for its lines',
      (tester) async {
    await tester.pumpWidget(_app(form(maxLines: 3)));
    field.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(field.hasPrimaryFocus, isTrue);
  });

  testWidgets('an outline marks what has focus once a key moves it (NAV-016)',
      (tester) async {
    await tester.pumpWidget(_app(form()));
    await tester.pump();
    expect(_ring, findsNothing, reason: 'nothing has focus yet');

    field.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump();

    expect(_ring, findsOneWidget);
    expect(tester.getRect(_ring), below.rect,
        reason: 'drawn inside the control, never over its neighbours');
  });

  testWidgets('no outline while the device is touched rather than keyed',
      (tester) async {
    await tester.pumpWidget(_app(form()));
    await tester.tap(find.byType(TextButton));
    await tester.pump();
    await tester.pump();

    expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
    expect(_ring, findsNothing);
  });

  testWidgets('no outline over what outlines itself', (tester) async {
    final page = FocusNode(debugLabel: 'page');
    addTearDown(page.dispose);
    await tester.pumpWidget(_app(OwnFocusOutline(
      child: Focus(focusNode: page, child: const SizedBox(width: 50, height: 50)),
    )));
    page.requestFocus();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    page.requestFocus();
    await tester.pump();
    await tester.pump();

    expect(FocusManager.instance.highlightMode,
        FocusHighlightMode.traditional);
    expect(_ring, findsNothing);
  });

  testWidgets('the outline follows a control that scrolls', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final target = FocusNode(debugLabel: 'target');
    addTearDown(target.dispose);
    await tester.pumpWidget(_app(ListView(
      controller: scroll,
      children: [
        for (var i = 0; i < 30; i++)
          TextButton(
            focusNode: i == 5 ? target : null,
            onPressed: () {},
            child: Text('row $i'),
          ),
      ],
    )));
    target.requestFocus();
    await tester.sendKeyEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    await tester.pump();
    final before = tester.getRect(_ring);

    scroll.jumpTo(40);
    await tester.pump();
    await tester.pump();

    expect(tester.getRect(_ring), before.translate(0, -40));
    expect(tester.getRect(_ring), target.rect);
  });
  group('on a desktop (NAV-022)', () {
    testWidgets('chromeKeys gives a desktop the keyboard\'s keys and a remote '
        'its own (NAV-022)', (tester) async {
      expect(hostIsDesktop, isTrue, reason: 'the tests run on a desktop');
      expect(chromeKeys(const SizedBox()), isA<KeyNavigation>());
      RemoteInput.debugDrivenOverride = true;
      addTearDown(() => RemoteInput.debugDrivenOverride = null);
      expect(chromeKeys(const SizedBox()), isA<RemoteControls>());
    });

    testWidgets('Up and Down leave a one-line text field (NAV-022)',
        (tester) async {
      await tester.pumpWidget(_app(form(), keys: _Keys.desktop));
      field.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(below.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(field.hasPrimaryFocus, isTrue);
    });

    testWidgets('a slider leaves Down to the focus moves (NAV-022)',
        (tester) async {
      final slider = FocusNode(debugLabel: 'slider');
      addTearDown(slider.dispose);
      final values = <double>[];
      await tester.pumpWidget(_app(
        Column(children: [
          Slider(focusNode: slider, value: 0.5, onChanged: values.add),
          TextButton(focusNode: below, onPressed: () {}, child: const Text('go')),
        ]),
        keys: _Keys.desktop,
      ));
      slider.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      expect(values, hasLength(1));
      expect(below.hasPrimaryFocus, isTrue);
    });

    testWidgets('a disabled control takes focus (NAV-022)', (tester) async {
      final locked = FocusNode(debugLabel: 'locked');
      addTearDown(locked.dispose);
      await tester.pumpWidget(_app(
        Column(children: [
          TextButton(focusNode: below, onPressed: () {}, child: const Text('go')),
          TextButton(focusNode: locked, onPressed: null, child: const Text('no')),
        ]),
        keys: _Keys.desktop,
      ));
      below.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      expect(locked.hasPrimaryFocus, isTrue);
    });

    testWidgets('an outline marks what a key moved focus to (NAV-022)',
        (tester) async {
      await tester.pumpWidget(_app(form(), keys: _Keys.desktop));
      field.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump();

      expect(_ring, findsOneWidget);
      expect(tester.getRect(_ring), below.rect);
    });

    testWidgets('the keyboard comes up in a field and Enter is the field\'s '
        '(NAV-022)', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(_app(
        Column(children: [
          TextField(focusNode: field, onSubmitted: submitted.add),
          TextButton(focusNode: below, onPressed: () {}, child: const Text('go')),
        ]),
        keys: _Keys.desktop,
      ));
      below.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(field.hasPrimaryFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.testTextInput.setClientArgs?['inputType'],
          isNot(containsPair('name', 'TextInputType.none')));

      await tester.enterText(find.byType(TextField), 'abc');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(submitted, ['abc']);
    });
  });
}
