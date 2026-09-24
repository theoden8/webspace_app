import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/widgets/http_auth_prompt.dart';

Future<Future<HttpAuthPromptResult?>> _open(
  WidgetTester tester,
  HttpAuthPromptRequest request,
) async {
  late Future<HttpAuthPromptResult?> result;
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => result = promptHttpAuth(context, request),
        child: const SizedBox.square(dimension: 40),
      ),
    ),
  ));
  await tester.tap(find.byType(TextButton));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('returns what the user typed, remember unticked', (tester) async {
    final result = await _open(
      tester,
      const HttpAuthPromptRequest(
        host: 'nas.example.com',
        isRetry: false,
        canRemember: true,
      ),
    );

    expect(find.textContaining('nas.example.com'), findsOneWidget);
    expect(find.text('That username and password were not accepted.'),
        findsNothing);
    await tester.enterText(find.byType(TextField).at(0), 'alice');
    await tester.enterText(find.byType(TextField).at(1), 's3cret');
    await tester.tap(find.widgetWithText(TextButton, 'Sign in'));
    await tester.pumpAndSettle();

    final typed = await result;
    expect(typed?.username, 'alice');
    expect(typed?.password, 's3cret');
    expect(typed?.remember, isFalse);
  });

  testWidgets('ticking remember is returned', (tester) async {
    final result = await _open(
      tester,
      const HttpAuthPromptRequest(
        host: 'nas.example.com',
        isRetry: false,
        canRemember: true,
      ),
    );

    await tester.tap(find.byType(Checkbox));
    await tester.tap(find.widgetWithText(TextButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect((await result)?.remember, isTrue);
  });

  testWidgets('cancel returns null', (tester) async {
    final result = await _open(
      tester,
      const HttpAuthPromptRequest(
        host: 'nas.example.com',
        isRetry: false,
        canRemember: true,
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets('no remember checkbox where saving is not allowed',
      (tester) async {
    await _open(
      tester,
      const HttpAuthPromptRequest(
        host: 'nas.example.com',
        isRetry: false,
        canRemember: false,
      ),
    );

    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('a retry says so and prefills the username', (tester) async {
    final result = await _open(
      tester,
      const HttpAuthPromptRequest(
        host: 'nas.example.com',
        isRetry: true,
        canRemember: true,
        initialUsername: 'alice',
        rememberByDefault: true,
      ),
    );

    expect(find.text('That username and password were not accepted.'),
        findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    await tester.tap(find.widgetWithText(TextButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect((await result)?.remember, isTrue);
  });
}
