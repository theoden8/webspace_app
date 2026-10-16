// The Tor screen behind the App settings card (TOR-004): the runtime's state,
// what is holding it up, and the settings that apply to every site at once.


import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/screens/tor_status.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'helpers/fake_tor_runtime.dart';
import 'helpers/localized.dart';

void main() {
  late FakeTorRuntime runtime;

  Widget host() => localizedApp(TorStatusScreen(sites: {
        SiteId('a1'): (name: 'Mail', exitNodes: '{de}'),
        SiteId('b2'): (name: 'Bank', exitNodes: null),
      }));

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
        .syncHolders({TorSiteHolder(SiteId('a1')), TorSiteHolder(SiteId('b2')), TorSiteHolder(SiteId('archived')), const TorAppWideHolder()});
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

  testWidgets('names each site with its own exit country', (t) async {
    install();
    await TorService.instance
        .syncHolders({TorSiteHolder(SiteId('a1')), TorSiteHolder(SiteId('b2'))});
    // What is in force answers for the loaded sites only, so the screen
    // must not print it beside a site that asks for another country.
    await TorService.instance.setExitCountry('{nl}');
    await t.pumpWidget(host());
    runtime.emit(const TorUp('127.0.0.1', port: 41337));
    await settle(t);

    expect(find.text('Exit country: 🇩🇪  Deutschland (DE)'), findsOneWidget);
    expect(find.text('Exit country: Any country'), findsOneWidget);
    expect(find.textContaining('Nederland'), findsNothing);
    expect(find.text('Exit country'), findsNothing,
        reason: 'no runtime-wide row: the country is a site setting');
    await drain(t);
  });

  testWidgets('shows the runtime-wide settings', (t) async {
    install();
    await TorService.instance.syncHolders({TorSiteHolder(SiteId('a1'))});
    await t.pumpWidget(host());
    runtime.emit(const TorBootstrapping(50));
    await settle(t);

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
    expect(find.textContaining('country'), findsNothing,
        reason: 'no site uses Tor, so no site has an exit to show');
    await drain(t);
  });
}
