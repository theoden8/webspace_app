// TOR-025: a picker never passes an external tor off as the built-in one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/proxy_library.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart';

Widget _picker({required bool external}) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: ProxyChoiceDropdown(
          type: ProxyType.TOR,
          savedProxyId: null,
          gatewayId: null,
          library: ProxyLibraryData(),
          torAvailable: true,
          torExternal: external,
          onChanged: (_) {},
        ),
      ),
    );

void main() {
  testWidgets('the built-in tor is TOR', (tester) async {
    await tester.pumpWidget(_picker(external: false));
    expect(find.text('TOR'), findsOneWidget);
    expect(find.text('Tor (external)'), findsNothing);
  });

  testWidgets('an external tor says so', (tester) async {
    await tester.pumpWidget(_picker(external: true));
    expect(find.text('Tor (external)'), findsOneWidget);
    expect(find.text('TOR'), findsNothing);
  });
}
