import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/media_session_service.dart';

/// Restores real sockets inside a block: TestWidgetsFlutterBinding installs
/// HttpOverrides that answer every request with a 400, which would make the
/// artwork tests below pass for the wrong reason.
class _RealHttpOverrides extends HttpOverrides {}

/// BGAUDIO-006 channel contract. The shim tier proves the page reports its
/// playback state; the emulator tier proves the notification reaches the
/// screen. This tier pins what sits between them: which method is invoked for
/// which report, the owner guard that stops a background site from clobbering
/// the one the user is listening to, and the failure modes that would silently
/// leave the notification absent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel =
      MethodChannel('org.codeberg.theoden8.webspace/media_session');
  const codec = StandardMethodCodec();

  late List<MethodCall> calls;
  late bool osPostedNotification;

  final service = MediaSessionService.instance;

  /// Everything except the visibility probe, which is a side channel.
  List<MethodCall> controlCalls() =>
      calls.where((c) => c.method != 'isNotificationActive').toList();

  Future<void> reportPlaying(
    String siteId, {
    bool playing = true,
    String title = 'Track',
    String artworkUrl = '',
    List<String>? js,
  }) {
    return service.report(
      siteId: siteId,
      runJs: (source) async => js?.add(source),
      playing: playing,
      title: title,
      artist: 'Artist',
      album: 'Album',
      artworkUrl: artworkUrl,
    );
  }

  setUp(() {
    calls = [];
    osPostedNotification = true;
    LogService.instance.clear();
    MediaSessionService.debugEnabledOverride = true;
    MediaSessionService.debugVisibilityCheckDelay = Duration.zero;
    service.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'isNotificationActive') return osPostedNotification;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    MediaSessionService.debugEnabledOverride = null;
    MediaSessionService.debugVisibilityCheckDelay = const Duration(seconds: 1);
    service.debugReset();
  });

  test('first playing report starts the service, later ones update it',
      () async {
    await reportPlaying('a', title: 'One');
    await reportPlaying('a', title: 'Two');

    expect(controlCalls().map((c) => c.method), ['start', 'update']);
    expect(controlCalls().first.arguments, {
      'title': 'One',
      'artist': 'Artist',
      'album': 'Album',
      'playing': true,
      'artwork': null,
    });
    expect(service.isActive, isTrue);
  });

  test('the owner pausing flips the notification without tearing it down',
      () async {
    await reportPlaying('a');
    await reportPlaying('a', playing: false);

    expect(controlCalls().map((c) => c.method), ['start', 'update']);
    expect((controlCalls().last.arguments as Map)['playing'], isFalse);
    expect(service.isActive, isTrue,
        reason: 'a paused player is still the owner and can be resumed');
  });

  test('a non-owner reporting not-playing cannot clobber the owner', () async {
    await reportPlaying('a');
    await reportPlaying('b', playing: false);

    expect(controlCalls().map((c) => c.method), ['start'],
        reason: 'a background site going quiet must not touch the '
            'notification the user is listening to');
  });

  test('not-playing before anything was raised is a no-op', () async {
    await reportPlaying('a', playing: false);
    expect(controlCalls(), isEmpty);
    expect(service.isActive, isFalse);
  });

  test('stopForSite only fires for the owner', () async {
    await reportPlaying('a');
    await service.stopForSite('b');
    expect(controlCalls().map((c) => c.method), ['start']);

    await service.stopForSite('a');
    expect(controlCalls().map((c) => c.method), ['start', 'stop']);
    expect(service.isActive, isFalse);
  });

  test('stopAll is a no-op when nothing is raised', () async {
    await service.stopAll();
    expect(controlCalls(), isEmpty);

    await reportPlaying('a');
    await service.stopAll();
    expect(controlCalls().map((c) => c.method), ['start', 'stop']);
  });

  test('ownership transfers to whichever site is playing', () async {
    await reportPlaying('a');
    await reportPlaying('b');
    // 'a' is no longer the owner, so its teardown must not kill b's notification.
    await service.stopForSite('a');
    expect(controlCalls().map((c) => c.method), ['start', 'update']);
  });

  group('artwork', () {
    test('a non-http artwork URL is dropped without a fetch', () async {
      await reportPlaying('a', artworkUrl: 'data:image/png;base64,AAAA');
      expect((controlCalls().single.arguments as Map)['artwork'], isNull);
    });

    test('an unreachable artwork URL still raises the notification', () async {
      // Bind and immediately release a port so the connect is refused rather
      // than hanging: the claim is that a dead artwork host cannot stop the
      // notification from going up.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();

      await HttpOverrides.runWithHttpOverrides(
        () => reportPlaying('a',
            artworkUrl: 'http://127.0.0.1:$deadPort/art.png'),
        _RealHttpOverrides(),
      );

      expect(controlCalls().map((c) => c.method), ['start']);
      expect((controlCalls().single.arguments as Map)['artwork'], isNull);
    });

    test('artwork bytes are forwarded as a byte buffer', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response
          ..add(<int>[1, 2, 3, 4])
          ..close();
      });
      addTearDown(() => server.close(force: true));

      await HttpOverrides.runWithHttpOverrides(
        () => reportPlaying('a',
            artworkUrl: 'http://127.0.0.1:${server.port}/art.png'),
        _RealHttpOverrides(),
      );

      final artwork = (controlCalls().single.arguments as Map)['artwork'];
      expect(artwork, isA<Uint8List>(),
          reason: 'the Kotlin side reads this as ByteArray');
      expect(artwork, <int>[1, 2, 3, 4]);
    });
  });

  test('a raised-but-unposted notification is logged as a warning', () async {
    osPostedNotification = false;
    await reportPlaying('a');
    // The visibility probe is unawaited; the zero delay lands it on the next
    // microtask drain.
    await Future<void>.delayed(Duration.zero);

    expect(calls.map((c) => c.method), contains('isNotificationActive'));
    final warnings = LogService.instance.allEntriesMerged
        .where((e) => e.level == LogLevel.warning)
        .map((e) => e.message);
    expect(warnings.join('\n'), contains('not posted by the OS'),
        reason: 'a denied notification permission leaves the service running '
            'with nothing on screen — it must not be silent');
  });

  test('a posted notification logs no warning', () async {
    await reportPlaying('a');
    await Future<void>.delayed(Duration.zero);

    final warnings = LogService.instance.allEntriesMerged
        .where((e) => e.level == LogLevel.warning);
    expect(warnings, isEmpty);
  });

  test('transport actions run the control shim on the owning webview',
      () async {
    service.initialize();
    final js = <String>[];
    await reportPlaying('a', js: js);

    for (final action in ['play', 'pause', 'stop']) {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(MethodCall('onTransport', {'action': action})),
        (_) {},
      );
    }

    expect(js, [
      'if(window.__wsMediaControl)window.__wsMediaControl("play");',
      'if(window.__wsMediaControl)window.__wsMediaControl("pause");',
      'if(window.__wsMediaControl)window.__wsMediaControl("stop");',
    ]);
  });

  test('an empty transport action is ignored', () async {
    service.initialize();
    final js = <String>[];
    await reportPlaying('a', js: js);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(const MethodCall('onTransport', {'action': ''})),
      (_) {},
    );

    expect(js, isEmpty);
  });

  test('a missing native side does not throw', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await expectLater(reportPlaying('a'), completes);
  });

  test('everything is inert off Android', () async {
    MediaSessionService.debugEnabledOverride = false;
    service.debugReset();

    await reportPlaying('a');
    await service.stopAll();
    expect(calls, isEmpty);
    expect(await service.notificationPosted(), isFalse);
  });
}
