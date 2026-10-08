// The Tor screen behind the App settings card (TOR-004): the runtime's state,
// what is holding it up, and the settings that apply to every site at once.


import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/screens/tor_status.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'helpers/fake_tor_runtime.dart';
import 'helpers/localized.dart';

void main() {
  late FakeTorRuntime runtime;

  Widget host() => localizedApp(const TorStatusScreen(siteNames: {'a1': 'Mail', 'b2': 'Bank'}));

  Future<void> drain(WidgetTester t) async {
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 91));
  }

  // Built inside each test body: the engine subscribes to the runtime's
  // events in its constructor, and a stream delivers in the zone that called
  // listen, so an engine built in setUp never sees an emit the test makes.
  void install() {
    runtime = FakeTorRuntime();
    TorService.overrideEngine(TorEngine(runtime: runtime, sessionSecret: 's'));
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 10));
  }

  tearDown(TorService.reset);

  testWidgets('lists every site and the app-wide proxy using Tor',
      (t) async {
    install();
    await TorService.instance
        .syncHolders({TorSiteHolder('a1'), TorSiteHolder('b2'), TorSiteHolder('archived'), const TorAppWideHolder()});
    await t.pumpWidget(host());
    runtime.emit(const TorUp('127.0.0.1', port: 41337));
    await settle(t);

    expect(find.text('Using Tor'), findsOneWidget);
    expect(find.text('All app traffic'), findsOneWidget);
    expect(find.text('Bank'), findsOneWidget);
    expect(find.text('Mail'), findsOneWidget);
    expect(find.text('One other site'), findsOneWidget,
        reason: 'a site with no name here is counted, never named');
    expect(find.text('Connected'), findsOneWidget,
        reason: 'the live card heads the screen');
    await drain(t);
  });

  testWidgets('shows the runtime-wide settings', (t) async {
    install();
    await TorService.instance.syncHolders({TorSiteHolder('a1')});
    await TorService.instance.setExitCountry('{de}');
    await t.pumpWidget(host());
    runtime.emit(const TorBootstrapping(50));
    await settle(t);

    expect(find.textContaining('Deutschland (DE)'), findsOneWidget,
        reason: 'the exit pin is one country for every site (TOR-014)');
    expect(find.text('Bridges'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Circuits'), findsOneWidget);
    expect(find.text('One per site'), findsOneWidget);
    await drain(t);
  });

  testWidgets('says so when nothing uses Tor', (t) async {
    install();
    await t.pumpWidget(host());
    await settle(t);
    expect(find.text('Nothing is using Tor'), findsOneWidget);
    expect(find.text('Any country'), findsOneWidget);
    await drain(t);
  });
}
