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
    String frame = 'main',
    List<String>? js,
  }) {
    return service.report(
      siteId: siteId,
      frame: frame,
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
    MediaSessionService.debugSurfaceReclearDelay = Duration.zero;
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

  test('a sibling iframe of the playing site cannot pause the notification',
      () async {
    // BGAUDIO-008. The shim runs in every frame and they share one handler, so
    // an ad / comments iframe reports `playing:false` for the same siteId
    // moments after the main frame raised the notification. Without the frame
    // guard that flips it to a paused, dismissible state while audio plays.
    await reportPlaying('a', frame: 'main');
    await reportPlaying('a', frame: 'ad-iframe', playing: false);

    expect(controlCalls().map((c) => c.method), ['start']);
    expect(service.isActive, isTrue);
  });

  test('playback moving to another frame transfers ownership', () async {
    await reportPlaying('a', frame: 'main');
    await reportPlaying('a', frame: 'player-iframe');
    await reportPlaying('a', frame: 'player-iframe', playing: false);

    expect(controlCalls().map((c) => c.method), ['start', 'update', 'update']);
    expect((controlCalls().last.arguments as Map)['playing'], isFalse);
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

  test('native audio-session state lands in the app log (BGAUDIO-011)',
      () async {
    service.initialize();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(const MethodCall('onSessionState', {
        'message': 'interruption ended, session re-activated '
            '[category=AVAudioSessionCategoryPlayback otherAudio=false]',
      })),
      (_) {},
    );
    final lines = LogService.instance.allEntriesMerged
        .where((e) => e.tag == 'MediaSession')
        .map((e) => e.message)
        .toList();
    expect(lines.any((m) => m.contains('interruption ended')), isTrue);
    expect(lines.any((m) => m.contains('Playback')), isTrue);
  });

  test('an empty session-state message is ignored', () async {
    service.initialize();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
          const MethodCall('onSessionState', {'message': ''})),
      (_) {},
    );
    expect(LogService.instance.allEntriesMerged.where((e) =>
        e.tag == 'MediaSession' && e.message.startsWith('Audio session')),
        isEmpty);
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

  group('control failures are diagnosable (BGAUDIO-007)', () {
    test('a refused transport is logged as a warning, no metadata', () async {
      await service.reportControlFailure(
          action: 'play', error: 'NotAllowedError');
      final warnings = LogService.instance.allEntriesMerged
          .where((e) => e.tag == 'MediaSession' && e.level == LogLevel.warning)
          .map((e) => e.message)
          .toList();
      expect(warnings.single, contains('play'));
      expect(warnings.single, contains('NotAllowedError'));
    });

    test('the failure path invokes nothing on the channel', () async {
      await service.reportControlFailure(action: 'play', error: 'unknown');
      expect(calls, isEmpty);
    });
  });

  group('clearOsMediaSurface (BGAUDIO-009/010)', () {
    test('clears even when we never raised anything', () async {
      // The iOS case this exists for: the Now Playing entry belongs to WebKit,
      // so `isActive` is false and `stopAll` would do nothing.
      expect(service.isActive, isFalse);
      await service.clearOsMediaSurface();
      // Twice: WebKit republishes its Now Playing entry when it finishes
      // processing the pause that preceded this.
      expect(controlCalls().map((c) => c.method), ['stop', 'stop']);
      expect(
          controlCalls().every((c) =>
              (c.arguments as Map)['deactivate'] == true),
          isTrue,
          reason: 'clearing the metadata alone leaves an entry the engine '
              'repopulates; the session has to go with it');
    });

    test('tears our own surface down when we do own it', () async {
      await reportPlaying('a');
      calls.clear();
      await service.clearOsMediaSurface();
      expect(controlCalls().map((c) => c.method), ['stop', 'stop']);
      expect(service.isActive, isFalse);
    });

    test('is inert where there is no native media session', () async {
      MediaSessionService.debugEnabledOverride = false;
      service.debugReset();
      await service.clearOsMediaSurface();
      expect(calls, isEmpty);
    });
  });

  test('a missing native side does not throw', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await expectLater(reportPlaying('a'), completes);
  });

  test('everything is inert on a platform with no native media session',
      () async {
    MediaSessionService.debugEnabledOverride = false;
    service.debugReset();

    await reportPlaying('a');
    await service.stopAll();
    expect(calls, isEmpty);
    expect(await service.notificationPosted(), isFalse);
    // The same answer gates the shim + handler injection in webview.dart, so
    // no report can arrive on a platform that would drop it.
    expect(service.isSupported, isFalse);
  });

  test('isSupported is what arms the bridge', () async {
    MediaSessionService.debugEnabledOverride = true;
    expect(service.isSupported, isTrue);
  });
}
