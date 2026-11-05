import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/connectivity_service.dart';

import 'helpers/real_app.dart';

void main() {
  setUp(() => ConnectivityService.onlineOverride = Future.value(true));

  testWidgets(
      'L10N-006: the shipped app registers the localizations, their locales '
      'and a localized window title', (tester) async {
    await pumpRealApp(tester, sites: const []);

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp).first);
    expect(app.localizationsDelegates, AppLocalizations.localizationsDelegates);
    expect(app.supportedLocales, AppLocalizations.supportedLocales);
    final context = tester.element(find.byType(Navigator).first);
    expect(app.onGenerateTitle?.call(context), 'WebSpace');
  });
}
