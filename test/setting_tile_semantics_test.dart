import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/runtime/arb_messages.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/widgets/setting_tile.dart';

import 'helpers/localized.dart';
import 'helpers/semantics_actions.dart';

/// A settings row merges what it holds into one node, its hint button too,
/// so a screen reader opens the hint through the row's own custom action;
/// a row that follows the app default also offers, as an action, what its
/// long press does.
void main() {
  const title = Localized.verbatim('Cookie isolation');
  const hint = Localized.verbatim('Each site keeps its own cookie jar.');

  SemanticsFinder row() => pressable('Cookie isolation');

  Future<void> hintOpens(WidgetTester tester) async {
    performCustomAction(row(), label: 'About Cookie isolation');
    await tester.pumpAndSettle();
    expect(find.text('Each site keeps its own cookie jar.'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  testWidgets('a switch row opens its hint through the row', (tester) async {
    final semantics = tester.ensureSemantics();
    var on = false;
    await pumpLocalized(tester,
        home: Scaffold(
          body: SettingTile(
            title: title,
            hint: hint,
            control: Toggle(value: on, onChanged: (v) => on = v),
          ),
        ));
    expect(row(), findsOne, reason: 'the row and its hint are one node');
    expect(customActionsOf(row()), {'About Cookie isolation'});
    await hintOpens(tester);
    tester.semantics.tap(row());
    expect(on, isTrue);
    semantics.dispose();
  });

  testWidgets('a row that follows the app default offers its long press and '
      'its hint', (tester) async {
    final semantics = tester.ensureSemantics();
    final choices = <Scoped<bool>>[];
    await pumpLocalized(tester,
        home: Scaffold(
          body: SettingTile(
            title: title,
            hint: hint,
            control: ScopedToggle(
              value: true,
              choice: const FollowApp(),
              source: FollowSource.app,
              onChoice: choices.add,
            ),
          ),
        ));
    expect(customActionsOf(row()),
        {'Keep for this site', 'About Cookie isolation'});
    performCustomAction(row(), label: 'Keep for this site');
    expect(choices, [const Own(true)]);
    performCustomAction(row(), label: 'About Cookie isolation');
    await tester.pumpAndSettle();
    expect(find.textContaining('Each site keeps its own cookie jar.'),
        findsOneWidget);
    semantics.dispose();
  });
}
