// A site's icon in the shipped app. A launch draws what a past launch found,
// its URL and its image, without asking the network again (ICON-008). A folder preview on the library
// home that missed its icon at launch takes it once the icon may come, as Tor
// comes up or the app comes back to the front, with no folder opened to fetch
// it (ICON-017).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:webspace/app.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/icon_image_store.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/launch_context.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/webspace_group_tile.dart';

import 'helpers/fake_outbound.dart';
import 'helpers/fake_tor_runtime.dart';
import 'helpers/real_app.dart';

final Uint8List _png =
    Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 64)));

http.Response _online(http.Request req) => switch (req.url.path) {
      '' || '/' => http.Response(
          '<html><head><link rel="icon" href="/icon.png"></head></html>', 200,
          headers: {'content-type': 'text/html'}),
      '/icon.png' => http.Response.bytes(_png, 200,
          headers: {'content-type': 'image/png'}),
      _ => http.Response('', 404),
    };

http.Response _offline(http.Request req) =>
    throw http.ClientException('offline');

/// The images drawn in [folder]'s preview on the library home.
Finder _preview(String folder) => find.descendant(
      of: find.byWidgetPredicate(
          (w) => w is WebspaceGroupTile && w.webspace.name == folder),
      matching: find.byType(Image),
    );

Future<void> _pumpHome(WidgetTester tester, {required WebViewModel site}) =>
    pumpRealApp(
      tester,
      sites: [site],
      webspaces: [
        Webspace(id: WebspaceId('work'), name: 'Work', siteIds: [site.siteId]),
      ],
      prefs: {
        AppPref.developerMode.key: true,
        AppPref.experimentalFolderLibrary.key: true,
      },
    );

void main() {
  late FakeOutbound net;

  setUp(() {
    ConnectivityService.onlineOverride = Future.value(true);
    clearFaviconCache();
    FaviconUrlCache.resetForTest();
    // Its directory is resolved once, and each test has its own.
    IconImageStore.instance = IconImageStore();
    net = FakeOutbound(responder: _offline);
    outboundHttp = net;
  });

  tearDown(() {
    ConnectivityService.reset();
    resetOutboundHttp();
    clearFaviconCache();
  });

  testWidgets(
      'ICON-008: a launch draws the icons a past launch found, offline and '
      'without a request', (tester) async {
    net.responder = _online;
    await _pumpHome(tester,
        site: WebViewModel(initUrl: 'https://alpha.example.test', name: 'Alpha'));
    expect(_preview('Work'), findsOneWidget);

    // The next launch is a new process: nothing it held in memory survives.
    await tester.pumpWidget(const SizedBox.shrink());
    await settleRealApp(tester);
    clearFaviconCache();
    FaviconUrlCache.resetForTest();
    net
      ..requests.clear()
      ..responder = _offline;
    // A device draws frames while the launch waits on the platform, after the
    // sites are on the page: the home's previews mount then.
    final launchDetails = Completer<void>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async {
        if (call.method == 'getNotificationAppLaunchDetails') {
          await launchDetails.future;
          return {'notificationLaunchedApp': false};
        }
        return call.method == 'initialize' ? true : null;
      },
    );
    await tester.pumpWidget(const WebSpaceApp(launch: ProcessLaunch.user));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(WebspaceGroupTile), findsWidgets,
        reason: 'the home is drawn while the launch waits');
    launchDetails.complete();
    await settleRealApp(tester);
    expect(_preview('Work'), findsOneWidget);
    expect(net.requested, isEmpty,
        reason: 'the URL and the image a past launch found are read from disk');
  });

  testWidgets(
      'ICON-017: a folder preview that missed its icon at launch takes it '
      'when the app comes back to the front', (tester) async {
    await _pumpHome(tester,
        site: WebViewModel(initUrl: 'https://alpha.example.test', name: 'Alpha'));
    expect(_preview('Work'), findsNothing, reason: 'offline at launch');

    net.responder = _online;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await settleRealApp(tester);
    expect(_preview('Work'), findsNothing, reason: 'nothing asked again yet');

    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await settleRealApp(tester);
    expect(_preview('Work'), findsOneWidget);
  });

  testWidgets(
      'ICON-017: a folder preview of a site on Tor takes its icon when Tor '
      'comes up', (tester) async {
    final runtime = FakeTorRuntime();
    TorService.overrideEngine(TorEngine(runtime: runtime, sessionSecret: 's'));
    addTearDown(() async {
      await TorService.reset();
      await runtime.dispose();
    });
    var torUp = false;
    net = FakeOutbound(
      responder: _online,
      blockWhen: (route) => route.type == ProxyType.TOR && !torUp,
    );
    outboundHttp = net;

    await _pumpHome(tester,
        site: WebViewModel(
          initUrl: 'https://hidden.example.test',
          name: 'Hidden',
          proxySettings: UserProxySettings(type: ProxyType.TOR),
        ));
    expect(_preview('Work'), findsNothing, reason: 'Tor is not up yet');

    torUp = true;
    runtime.emit(const TorUp('127.0.0.1', port: 9050));
    await settleRealApp(tester);
    expect(_preview('Work'), findsOneWidget);
  });
}
