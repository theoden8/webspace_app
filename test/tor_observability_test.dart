// What the user can see while Tor starts (TOR-018).
//
// The interstitial used to show "Starting" and a bar, because the phase
// tor reports alongside every bootstrap event was dropped at the platform
// seam and the app log said nothing at all. Three surfaces are asserted
// here: the decoded status carries tor's phase, every transition reaches
// the app log, and tor's own output reaches it too — separately tagged and
// filed as sensitive.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';

class _Runtime implements TorRuntime {
  final _events = StreamController<TorStatus>.broadcast();

  @override
  bool get isAvailable => true;

  @override
  Stream<TorStatus> get events => _events.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> rebuildCircuits() async {}

  @override
  Future<void> applyExitCountry(String? exitNodes) async {}

  @override
  Future<int> startTransport(String transport) async => 0;

  @override
  Future<void> setTorrcOptions(List<(String, String)> options) async {}

  void emit(TorStatus s) => _events.add(s);
  Future<void> dispose() => _events.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decodeStatus carries tor\'s own phase', () {
    test('tag and summary ride the bootstrapping payload', () {
      final status = MethodChannelTorRuntime.decodeStatus({
        'state': 'bootstrapping',
        'bootstrapPct': 45,
        'bootstrapTag': 'loading_descriptors',
        'bootstrapSummary': 'Loading relay descriptors',
      });
      expect(status, isA<TorBootstrapping>());
      final bootstrapping = status as TorBootstrapping;
      expect(bootstrapping.percent, 45);
      expect(bootstrapping.tag, 'loading_descriptors');
      expect(bootstrapping.summary, 'Loading relay descriptors');
    });

    test('a payload without a phase decodes to null, not an empty string', () {
      // The widgets render the phase row only when it is non-null, so an
      // empty string would put an empty "Phase:" line under the bar.
      final status = MethodChannelTorRuntime.decodeStatus(
              {'state': 'bootstrapping', 'bootstrapPct': 5, 'bootstrapTag': ''})
          as TorBootstrapping;
      expect(status.tag, isNull);
      expect(status.summary, isNull);
    });

    test('a non-string phase does not throw into the status stream', () {
      final status = MethodChannelTorRuntime.decodeStatus({
        'state': 'bootstrapping',
        'bootstrapPct': 10,
        'bootstrapTag': 7,
      });
      expect(status, isA<TorBootstrapping>());
      expect((status as TorBootstrapping).tag, isNull);
    });
  });

  group('decodeLogLine', () {
    test('maps tor severities onto log levels', () {
      LogLevel levelOf(String severity) =>
          TorLogBridge.decodeLogLine(
                  {'source': 'tor', 'severity': severity, 'message': 'm'})!
              .level;
      expect(levelOf('err'), LogLevel.error);
      expect(levelOf('warn'), LogLevel.warning);
      expect(levelOf('notice'), LogLevel.info);
      expect(levelOf('something-new'), LogLevel.info);
    });

    test('separates tor\'s output from the plugin\'s notes', () {
      expect(
        TorLogBridge.decodeLogLine(
            {'source': 'tor', 'severity': 'notice', 'message': 'm'})!.fromTor,
        isTrue,
      );
      expect(
        TorLogBridge.decodeLogLine(
            {'source': 'plugin', 'severity': 'notice', 'message': 'm'})!.fromTor,
        isFalse,
      );
    });

    test('drops malformed payloads instead of logging them', () {
      expect(TorLogBridge.decodeLogLine(null), isNull);
      expect(TorLogBridge.decodeLogLine('nonsense'), isNull);
      expect(TorLogBridge.decodeLogLine({'severity': 'notice'}), isNull);
      expect(TorLogBridge.decodeLogLine({'message': ''}), isNull);
      expect(TorLogBridge.decodeLogLine({'message': 42}), isNull);
    });
  });

  group('the app log follows the runtime', () {
    late _Runtime runtime;

    setUp(() {
      LogService.instance.resetForTest();
      DeveloperModeService.instance.debugSet(true);
      runtime = _Runtime();
      TorService.overrideEngine(
        TorEngine(runtime: runtime, sessionSecret: 'secret'),
      );
    });

    tearDown(() async {
      await TorService.reset();
      await runtime.dispose();
      DeveloperModeService.instance.debugSet(false);
      LogService.instance.resetForTest();
    });

    List<LogEntry> torEntries() =>
        LogService.instance.entries.where((e) => e.tag == 'Tor').toList();

    test('every transition is logged, with its phase', () async {
      await TorService.instance.maybeStart('site:a');
      runtime.emit(const TorBootstrapping(45,
          tag: 'loading_descriptors', summary: 'Loading relay descriptors'));
      runtime.emit(const TorUp('127.0.0.1', 41337));
      await pumpEventQueue();

      final messages = torEntries().map((e) => e.message).toList();
      expect(messages, contains('State: starting'));
      expect(messages, contains('State: bootstrapping(45%, loading_descriptors)'));
      expect(messages, contains('State: up(127.0.0.1:41337)'));
    });

    test('a failure is logged at error level', () async {
      await TorService.instance.maybeStart('site:a');
      runtime.emit(TorErrored('Tor did not finish bootstrapping in time.'));
      await pumpEventQueue();

      final failures =
          torEntries().where((e) => e.level == LogLevel.error).toList();
      expect(failures, hasLength(1));
      expect(failures.single.message, contains('did not finish bootstrapping'));
    });

    test('status lines are not sensitive, so they show without the toggle',
        () async {
      await TorService.instance.maybeStart('site:a');
      await pumpEventQueue();
      expect(torEntries(), isNotEmpty);
      expect(LogService.instance.sensitiveEntries, isEmpty);
    });
  });

  group('where the runtime is offered', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('both Apple platforms have a runtime', () {
      // Capability, not permission: developer mode still decides whether
      // anything offers Tor, and that gate is on TorService (TOR-007).
      for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(MethodChannelTorRuntime().isAvailable, isTrue,
            reason: '$platform ships the plugin');
      }
    });

    test('no other platform is offered a runtime', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.linux,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(MethodChannelTorRuntime().isAvailable, isFalse,
            reason: '$platform has no plugin, so asking must not open a '
                'channel (TOR-007)');
      }
    });

    test('a channel with no plugin behind it becomes an error state',
        () async {
      // A channel that answers with an error rather than events: a plugin
      // that failed to register, or a platform where one was never built.
      // Letting that through raw would be an unhandled async error at
      // startup instead of a state the UI can name.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      const channel = EventChannel('test/tor/events/absent');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (arguments, sink) =>
              sink.error(code: 'channel-error', message: 'no plugin'),
        ),
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(channel, null);
      });

      final runtime = MethodChannelTorRuntime(events: channel);
      final first = await runtime.events.first;
      expect(first, isA<TorErrored>());
      expect((first as TorErrored).message, contains('No Tor runtime'));
    });
  });

  group('the native log channel feeds the app log', () {
    const channelName = 'org.codeberg.theoden8.webspace/tor/logs';
    late TorLogBridge bridge;

    setUp(() {
      LogService.instance.resetForTest();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      bridge = TorLogBridge(events: const EventChannel(channelName));
    });

    tearDown(() async {
      await bridge.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(const EventChannel(channelName), null);
      debugDefaultTargetPlatformOverride = null;
      LogService.instance.resetForTest();
    });

    /// Replays [payloads] to whoever subscribes to the channel.
    void stubChannel(List<Map<String, Object?>> payloads) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        const EventChannel(channelName),
        MockStreamHandler.inline(
          onListen: (arguments, sink) {
            for (final payload in payloads) {
              sink.success(payload);
            }
          },
        ),
      );
    }

    test('tor\'s own lines land in the sensitive ring, the plugin\'s do not',
        () async {
      stubChannel([
        {
          'source': 'plugin',
          'severity': 'notice',
          'message': 'Starting tor.',
        },
        {
          'source': 'tor',
          'severity': 'notice',
          'message': 'Bootstrapped 10% (conn_done): Connected to a relay',
        },
      ]);
      bridge.start();
      await pumpEventQueue();

      expect(LogService.instance.entries.map((e) => e.message),
          contains('Starting tor.'));
      expect(
        LogService.instance.sensitiveEntries.map((e) => e.message),
        contains('Bootstrapped 10% (conn_done): Connected to a relay'),
        reason: 'a notice-level line can name the bridges this device dials',
      );
      expect(
        LogService.instance.sensitiveEntries.single.tag,
        'TorLog',
        reason: "tor's own output is tagged apart from the app's decisions",
      );
    });

    test('no subscription is opened where there is no plugin', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      stubChannel([
        {'source': 'tor', 'severity': 'notice', 'message': 'should not arrive'},
      ]);
      bridge.start();
      await pumpEventQueue();
      expect(LogService.instance.allEntriesMerged, isEmpty);
    });
  });
}
