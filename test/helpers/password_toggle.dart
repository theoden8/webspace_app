import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The eye beside the one password field on screen, pressed by a screen
/// reader: one name, Show password, with whether the password shows as its
/// toggled state, and the field obscured only while it is off.
Future<void> expectPasswordToggle(WidgetTester tester) async {
  final semantics = tester.ensureSemantics();
  bool obscured() => tester
      .widgetList<EditableText>(find.byType(EditableText))
      .any((field) => field.obscureText);
  // A tooltip is the name a platform reads for a button that has one.
  SemanticsFinder eye() => find.semantics.byPredicate(
      (node) => node.tooltip == 'Show password',
      describeMatch: (_) => 'the eye named Show password');

  expect(eye(), findsOne);
  expect(eye().evaluate().single,
      containsSemantics(isButton: true, hasToggledState: true, isToggled: false));
  expect(obscured(), isTrue);

  tester.semantics.tap(eye());
  await tester.pump();
  expect(eye(), findsOne, reason: 'the name stays; the state says it shows');
  expect(eye().evaluate().single,
      containsSemantics(hasToggledState: true, isToggled: true));
  expect(obscured(), isFalse);
  semantics.dispose();
}
