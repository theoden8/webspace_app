// NOTIF-018 and PLATFORM-010 on the desktop tiers: a close that only hides
// the window, a site that keeps notifying behind it, and the ways back.
//
// The close takes the runner's own path: the debug `window_capture` channel's
// `close` sends the delete-event a window manager sends on Linux, and
// performClose:, the close button's action, on macOS. This test runs in the
// app's process, so getting past the close is the proof the app did not quit.
//
// The loopback server holds the site's messages as a chat server does
// (NOTIF-012): it sends one only once the window is hidden, and the page's own
// JS has to take it off its event stream, count it and post it. On Linux a
// stand-in for the desktop's notification server on the session bus records
// the post and clicks it, which is how the window comes back the first time;
// a second launch brings it back the second. On macOS the Dock's way back is
// `open` of the running app.

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
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'fixture_server.dart';

/// A chat page: each message on its event stream is one more unread, in the
/// title and as a notification, and is reported back so the server sees the
/// page's JS took it.
const _chatPage = '''<!doctype html>
<html><head><meta charset="utf-8"><title>Chat</title></head>
<body><p>Chat</p>
<script>
var unread = 0;
var events = new EventSource('/events');
events.onmessage = function (e) {
  unread += 1;
  document.title = '(' + unread + ') Chat';
  new Notification('Chat', { body: e.data });
  fetch('/seen?unread=' + unread);
};
</script></body></html>''';

/// The desktop's notification server, as the freedesktop spec names it on the
/// session bus: what the app posts, and a click on one.
class _NotificationServer extends DBusObject {
  _NotificationServer() : super(DBusObjectPath('/org/freedesktop/Notifications'));

  static const _interface = 'org.freedesktop.Notifications';

  final posted = <({int id, String summary, String body})>[];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != _interface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (methodCall.name) {
      case 'Notify':
        final values = methodCall.values;
        final id = posted.length + 1;
        posted.add((
          id: id,
          summary: values[3].asString(),
          body: values[4].asString(),
        ));
        return DBusMethodSuccessResponse([DBusUint32(id)]);
      case 'CloseNotification':
        return DBusMethodSuccessResponse();
      case 'GetCapabilities':
        return DBusMethodSuccessResponse([
          DBusArray.string(['body', 'actions']),
        ]);
      case 'GetServerInformation':
        return DBusMethodSuccessResponse([
          const DBusString('close_keeps_running_test'),
          const DBusString('webspace'),
          const DBusString('1'),
          const DBusString('1.2'),
        ]);
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }

  /// The user clicks notification [id], as a desktop reports it.
  Future<void> click(int id) => emitSignal(
      _interface, 'ActionInvoked', [DBusUint32(id), const DBusString('default')]);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final desktop = Platform.isLinux || Platform.isMacOS;
  final sessionBus = Platform.environment['DBUS_SESSION_BUS_ADDRESS'] != null;

  late HttpServer server;
  final streams = <HttpResponse>[];
  final seen = <int>[];
  DBusClient? bus;
  _NotificationServer? notifications;

  void log(String m) {
    // ignore: avoid_print
    print('[close-keeps-running] $m');
  }

  setUpAll(() async {
    if (!desktop) return;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    listenFixture(server, onEvent: (req) {
      switch (req.uri.path) {
        case '/events':
          // Buffered, dart:io holds even a flushed event until the response
          // closes, and the page saw the message only at teardown.
          final res = req.response
            ..bufferOutput = false
            ..headers.contentType = ContentType('text', 'event-stream')
            ..headers.set('Cache-Control', 'no-store')
            ..write(': open\n\n');
          // Headers now, or WebKit's load times out before the first message.
          unawaited(res.flush().catchError((Object _) {},
              test: (e) => e is SocketException || e is HttpException));
          streams.add(res);
        case '/seen':
          seen.add(int.tryParse(req.uri.queryParameters['unread'] ?? '') ?? -1);
          req.response.statusCode = HttpStatus.noContent;
          unawaited(req.response.close());
        default:
          final res = req.response..headers.contentType = ContentType.html;
          res.write(_chatPage);
          unawaited(res.close());
      }
    });

    if (Platform.isLinux && sessionBus) {
      final client = DBusClient.session();
      final reply = await client.requestName('org.freedesktop.Notifications');
      expect(reply, DBusRequestNameReply.primaryOwner,
          reason: 'another notification server already holds the name');
      final stub = _NotificationServer();
      await client.registerObject(stub);
      bus = client;
      notifications = stub;
    }

    isDemoMode = true;
    final chat = WebViewModel(
      siteId: SiteId('close-keeps-running'),
      initUrl: 'http://127.0.0.1:${server.port}/',
      name: 'Chat',
      notificationsEnabled: true,
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [jsonEncode(chat.toJson())],
      'keepRunningWhenClosed': true,
    });
  });

  tearDownAll(() async {
    if (!desktop) return;
    for (final s in streams) {
      unawaited(s.close().catchError((Object _) {},
          test: (e) => e is SocketException || e is HttpException));
    }
    await server.close(force: true);
    await bus?.close();
  });

  testWidgets(
      'NOTIF-018 a close hides the window, the site behind it still '
      'notifies, and the window comes back', (tester) async {
    const window = MethodChannel('org.codeberg.theoden8.webspace/window_capture');

    /// Real time, with no frame asked for: a hidden window draws none, and a
    /// pump would wait on one.
    Future<void> until(
      bool Function() done, {
      required String what,
      Duration timeout = const Duration(seconds: 60),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (!done()) {
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

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));
    await tester.tap(find.byKey(const ValueKey(WebspaceId.all)));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    await tester.tap(find.text('Chat'));
    for (var i = 0; i < 20 && streams.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)));
    }
    await until(() => streams.isNotEmpty,
        what: 'the page to open its event stream');

    await close();

    // The message arrives with nothing on screen: the page takes it and posts.
    for (final s in streams) {
      s.write('data: hello\n\n');
    }
    await tester.runAsync(() => Future.wait([for (final s in streams) s.flush()]));
    await until(() => seen.contains(1),
        what: 'the hidden page to take the message off its stream');
    log('the hidden page counted the message');

    if (notifications case final server?) {
      await until(() => server.posted.isNotEmpty,
          what: 'the post to reach the desktop notification server');
      expect(server.posted.single.summary, 'Chat');
      expect(server.posted.single.body, 'hello');
      log('posted to the desktop while hidden');

      // A click on it is one way back.
      await server.click(server.posted.single.id);
      await until(() => !hidden(), what: 'the click to show the window');
      log('the click showed the window');
    } else if (Platform.isMacOS) {
      // The Dock's way back: a reopen of the running app.
      final bundle =
          File(Platform.resolvedExecutable).parent.parent.parent.path;
      final opened =
          await tester.runAsync(() => Process.run('open', [bundle]));
      expect(opened?.exitCode, 0, reason: '${opened?.stderr}');
      await until(() => !hidden(), what: 'the reopen to show the window');
      log('the reopen showed the window');
    } else {
      markTestSkipped('no session bus: no notification server to click, and '
          'no second launch to take');
      return;
    }

    if (Platform.isLinux && sessionBus) {
      // PLATFORM-010: a second launch is the other way back, and it does not
      // become a second app.
      await close();
      // A second launch that became an app of its own would run this file
      // again; named nothing, its entrypoint exits 64 instead.
      final exit = await tester.runAsync(() async {
        final second = await Process.start(Platform.resolvedExecutable, const [],
            environment: const {'WEBSPACE_INTEGRATION_FILE': ''});
        unawaited(second.stdout.drain<void>());
        unawaited(second.stderr.drain<void>());
        return second.exitCode.timeout(const Duration(seconds: 30),
            onTimeout: () {
          second.kill(ProcessSignal.sigkill);
          return -1;
        });
      });
      expect(exit, 0,
          reason: 'the second launch should hand its activation over and exit '
              '(64: it ran as an app of its own; -1: it was still running)');
      await until(() => !hidden(), what: 'the second launch to show the window');
      log('the second launch showed the window and exited');
    }
  }, skip: !desktop);
}
