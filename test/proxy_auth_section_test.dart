// PROXY-019: the credentials fold. It replaces a checkbox whose state nothing
// persisted, so the one thing it must get right is showing the user what is
// actually stored the moment the screen opens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/widgets/proxy_auth_section.dart';

Widget _host(TextEditingController user, TextEditingController password,
        {VoidCallback? onEditingComplete}) =>
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ListView(children: [
          ProxyAuthSection(
            usernameController: user,
            passwordController: password,
            onEditingComplete: onEditingComplete,
          ),
        ]),
      ),
    );

/// The fold's subtitle, read off the tile rather than by text search: a
/// username also appears in the field below it once the section is open.
String _subtitle(WidgetTester tester) {
  final tile = tester.widget<ExpansionTile>(find.byType(ExpansionTile));
  return (tile.subtitle! as Text).data!;
}

void main() {
  testWidgets('opens already expanded when only a password is stored',
      (tester) async {
    // The reported failure: the password was saved, the checkbox came back
    // unticked because there was no username, and the next save wiped it.
    final user = TextEditingController();
    final password = TextEditingController(text: 'hunter2');
    addTearDown(user.dispose);
    addTearDown(password.dispose);

    await tester.pumpWidget(_host(user, password));

    expect(find.byType(TextFormField), findsNWidgets(2),
        reason: 'a stored credential must be visible without hunting for it');
    expect(_subtitle(tester), 'Needs both a username and a password');
  });

  testWidgets('opens expanded when only a username is stored', (tester) async {
    final user = TextEditingController(text: 'alice');
    final password = TextEditingController();
    addTearDown(user.dispose);
    addTearDown(password.dispose);

    await tester.pumpWidget(_host(user, password));

    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(_subtitle(tester), 'Needs both a username and a password');
  });

  testWidgets('names the account in the subtitle once the pair is complete',
      (tester) async {
    final user = TextEditingController(text: 'alice');
    final password = TextEditingController(text: 'hunter2');
    addTearDown(user.dispose);
    addTearDown(password.dispose);

    await tester.pumpWidget(_host(user, password));

    expect(_subtitle(tester), 'alice');
  });

  testWidgets('starts collapsed and says so when nothing is stored',
      (tester) async {
    final user = TextEditingController();
    final password = TextEditingController();
    addTearDown(user.dispose);
    addTearDown(password.dispose);

    await tester.pumpWidget(_host(user, password));

    expect(find.byType(TextFormField), findsNothing);
    expect(_subtitle(tester), 'Not configured');
  });

  testWidgets('the subtitle tracks what is typed, and the fold stays open',
      (tester) async {
    final user = TextEditingController();
    final password = TextEditingController();
    addTearDown(user.dispose);
    addTearDown(password.dispose);

    await tester.pumpWidget(_host(user, password));
    await tester.tap(find.text('Proxy authentication'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'alice');
    await tester.pump();
    expect(_subtitle(tester), 'Needs both a username and a password');

    await tester.enterText(find.byType(TextFormField).last, 'hunter2');
    await tester.pump();
    expect(_subtitle(tester), 'alice');

    // Clearing both must not fold the section away mid-edit.
    await tester.enterText(find.byType(TextFormField).first, '');
    await tester.enterText(find.byType(TextFormField).last, '');
    await tester.pump();
    expect(find.byType(TextFormField), findsNWidgets(2));
  });

  testWidgets('the password is obscured until the reveal is tapped',
      (tester) async {
    final user = TextEditingController(text: 'alice');
    final password = TextEditingController(text: 'hunter2');
    addTearDown(user.dispose);
    addTearDown(password.dispose);

    await tester.pumpWidget(_host(user, password));

    EditableText passwordField() => tester.widget<EditableText>(
        find.byType(EditableText).last);
    expect(passwordField().obscureText, isTrue);

    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pump();
    expect(passwordField().obscureText, isFalse);
  });

  testWidgets('editing a field notifies the screens that persist on edit',
      (tester) async {
    var edits = 0;
    final user = TextEditingController(text: 'alice');
    final password = TextEditingController(text: 'hunter2');
    addTearDown(user.dispose);
    addTearDown(password.dispose);

    await tester.pumpWidget(_host(user, password, onEditingComplete: () => edits++));
    await tester.enterText(find.byType(TextFormField).first, 'bob');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(edits, greaterThan(0));
  });
}
