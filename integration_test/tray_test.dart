// NOTIF-019 on the desktop tiers: while a close only hides the window, the
// app keeps an icon in the desktop's status area whose menu lists the sites
// with notifications on, with the unread count each page's title shows, and
// shows the window, opens a site or quits.
//
// On Linux a client on the session bus plays the desktop, as Plasma or the
// AppIndicator extension does: it owns org.kde.StatusNotifierWatcher, takes
// the registration, reads the icon and its dbusmenu, and clicks them. On
// macOS the debug `window_capture` channel reads the menu bar item's menu and
// performs a line's action, the path a click takes.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'fixture_server.dart';

/// A page whose title counts two unread, as a chat site's does.
const _chatPage = '''<!doctype html>
<html><head><meta charset="utf-8"><title>(2) Chat</title></head>
<body><p>Chat</p></body></html>''';

const _sni = 'org.kde.StatusNotifierItem';
const _dbusmenu = 'com.canonical.dbusmenu';

/// The desktop's StatusNotifierWatcher: who registered which item.
class _Watcher extends DBusObject {
  _Watcher() : super(DBusObjectPath('/StatusNotifierWatcher'));

  final registered = <({String sender, String path})>[];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == 'org.kde.StatusNotifierWatcher' &&
        methodCall.name == 'RegisterStatusNotifierItem') {
      registered.add((
        sender: methodCall.sender!,
        path: methodCall.values.single.asString(),
      ));
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final desktop = Platform.isLinux || Platform.isMacOS;
  final sessionBus = Platform.environment['DBUS_SESSION_BUS_ADDRESS'] != null;

  late HttpServer server;
  DBusClient? bus;
  final watcher = _Watcher();

  void log(String m) {
    // ignore: avoid_print
    print('[tray] $m');
  }

  setUpAll(() async {
    if (!desktop) return;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    listenFixture(server, onEvent: (req) {
      final res = req.response..headers.contentType = ContentType.html;
      res.write(_chatPage);
      unawaited(res.close());
    });

    if (Platform.isLinux && sessionBus) {
      final client = DBusClient.session();
      await client.registerObject(watcher);
      final reply = await client.requestName('org.kde.StatusNotifierWatcher');
      expect(reply, DBusRequestNameReply.primaryOwner,
          reason: 'another status notifier watcher already holds the name');
      bus = client;
    }

    isDemoMode = true;
    final chat = WebViewModel(
      siteId: SiteId('tray-chat'),
      initUrl: 'http://127.0.0.1:${server.port}/',
      name: 'Chat',
      notificationsEnabled: true,
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [jsonEncode(chat.toJson())],
      'keepRunningWhenClosed': true,
      // The Tray icon experiment, which developer mode gates (DEVTOOLS-011).
      'developerMode': true,
      'experimentalDesktopTray': true,
    });
  });

  tearDownAll(() async {
    if (!desktop) return;
    await server.close(force: true);
    await bus?.close();
  });

  testWidgets(
      'NOTIF-019 the tray lists the notifying site with its unread count, '
      'and its lines show the window and open the site', (tester) async {
    const window = MethodChannel('org.codeberg.theoden8.webspace/window_capture');

    /// Real time, with no frame asked for: a hidden window draws none, and a
    /// pump would wait on one.
    Future<void> until(
      FutureOr<bool> Function() done, {
      required String what,
      Duration timeout = const Duration(seconds: 60),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (!await done()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out after ${timeout.inSeconds}s waiting for $what');
        }
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 200)));
      }
    }

    bool hidden() =>
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden;

    Future<void> close() async {
      await window.invokeMethod<void>('close');
      await until(hidden, what: 'the lifecycle to report the window hidden');
      log('hidden after the close');
    }

    /// The tray's menu as the desktop reads it, a separator as "-".
    late Future<List<String>?> Function() lines;

    /// A press on the line labelled [label].
    late Future<void> Function(String label) press;

    /// A click on the icon itself, where one shows the window.
    Future<void> Function()? click;

    /// Whether the icon is still in the status area.
    late Future<bool> Function() shown;

    if (Platform.isLinux && sessionBus) {
      final client = bus!;
      DBusRemoteObject item() => DBusRemoteObject(client,
          name: watcher.registered.last.sender,
          path: DBusObjectPath(watcher.registered.last.path));
      Future<DBusRemoteObject> menu() async {
        final path = await item().getProperty(_sni, 'Menu');
        return DBusRemoteObject(client,
            name: watcher.registered.last.sender, path: path.asObjectPath());
      }

      Future<List<(int, String)>> layout() async {
        final m = await menu();
        await m.callMethod(_dbusmenu, 'AboutToShow', [const DBusInt32(0)],
            replySignature: DBusSignature('b'));
        final reply = await m.callMethod(_dbusmenu, 'GetLayout',
            [const DBusInt32(0), const DBusInt32(-1), DBusArray.string(const [])],
            replySignature: DBusSignature('u(ia{sv}av)'));
        return [
          for (final child in reply.values[1].asStruct()[2].asArray())
            (
              child.asVariant().asStruct()[0].asInt32(),
              child.asVariant().asStruct()[1].asStringVariantDict()['label']
                      ?.asString() ??
                  '-',
            ),
        ];
      }

      lines = () async => watcher.registered.isEmpty
          ? null
          : [for (final (_, label) in await layout()) label];
      press = (label) async {
        final id = (await layout()).firstWhere((l) => l.$2 == label).$1;
        await (await menu()).callMethod(_dbusmenu, 'Event', [
          DBusInt32(id),
          const DBusString('clicked'),
          const DBusVariant(DBusInt32(0)),
          const DBusUint32(0),
        ]);
      };
      click = () => item().callMethod(
          _sni, 'Activate', [const DBusInt32(0), const DBusInt32(0)]);
      // A desktop drops an item whose owner left the bus.
      shown = () => client.nameHasOwner(watcher.registered.last.sender);
    } else if (Platform.isMacOS) {
      lines = () async {
        await window.invokeMethod<void>('openTray');
        return window.invokeListMethod<String>('trayMenu');
      };
      press = (label) async {
        await window.invokeMethod<void>('openTray');
        final titles = await window.invokeListMethod<String>('trayMenu') ?? [];
        final index = titles.indexOf(label);
        expect(index, isNonNegative, reason: '$label is not in $titles');
        final pressed =
            await window.invokeMethod<bool>('pressTray', {'index': index});
        expect(pressed, isTrue);
      };
      shown = () async => await window.invokeListMethod<String>('trayMenu') != null;
    } else {
      markTestSkipped('no session bus: no desktop to host the icon');
      return;
    }

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));
    await tester.tap(find.byKey(const ValueKey(WebspaceId.all)));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await until(
        () => LogService.instance.allEntriesMerged.any(
            (e) => e.message == 'Desktop window: a close hides it: true'),
        what: 'the runner to take the setting');

    await until(() async => await lines() != null, what: 'the tray icon');
    log('the icon is in the status area');
    await close();

    // The page's title is read as the menu opens.
    await until(() async => (await lines())?.contains('Chat (2)') ?? false,
        what: 'the menu to list the site with its unread count');
    expect(await lines(),
        ['Show WebSpace', '-', 'Chat (2)', '-', 'Quit WebSpace']);
    log('the menu lists the site with its unread count');

    await press('Chat (2)');
    await until(() => !hidden(), what: 'the site pressed to show the window');
    log('a press on the site showed the window');

    await close();
    if (click case final click?) {
      await click();
      await until(() => !hidden(), what: 'a click on the icon to show the window');
      log('a click on the icon showed the window');
      await close();
    }
    await press('Show WebSpace');
    await until(() => !hidden(), what: 'Show WebSpace to show the window');
    log('Show WebSpace showed the window');

    // With a close quitting again, the icon goes.
    await tester.runAsync(() => AppPref.keepRunningWhenClosed.set(false));
    await until(() async => !await shown(), what: 'the icon to leave');
    log('the icon left with the setting');
  }, skip: !desktop);
}
