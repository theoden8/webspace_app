// TOR-025: a picker never passes an external tor off as the built-in one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/proxy_library.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart';
import 'helpers/localized.dart';

Widget _picker({required bool external}) => localizedApp(Scaffold(
  body: ProxyChoiceDropdown(
    type: ProxyType.TOR,
    savedProxyId: null,
    gatewayId: null,
    library: ProxyLibraryData(),
    torAvailable: true,
    torExternal: external,
    onChanged: (_) {},
  ),
), locale: const Locale('en'));

void main() {
  test('TOR has no address to check and no fields to show (TOR-007, PROXY-010)',
      () {
    expect(ProxyType.TOR.typesAddress, isFalse);
    expect(ProxyType.TOR.showsRouteFields, isFalse);
    expect(ProxyType.SOCKS5.typesAddress, isTrue);
    expect(ProxyType.GATEWAY.typesAddress, isFalse);
    expect(ProxyType.GATEWAY.showsRouteFields, isTrue);
  });

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
