// The embedded Tor runtime, against the real plugin (TOR-014, TOR-018,
// TOR-019, TOR-020).
//
// Every other Tor test in this repo drives a fake `TorRuntime` that answers
// `TorUp` when told to, which is exactly why a control-port protocol bug and
// a process-singleton crash both shipped: nothing ever ran the handshake.
// This file runs it. iOS has no integration tier, so the runtime under test
// is the macOS one, which exists for this file alone — a shipped macOS build
// has no Tor pod and no Tor channels (macos/Podfile, TOR-007).
//
// Two tiers of assertion, because one of them needs the Tor network and the
// other does not:
//
//   - The handshake, the bootstrap phase, tor's own log and a restart are
//     asserted always. They are what broke, and none of them needs tor to
//     finish bootstrapping: tor opens its control port and its SOCKS
//     listener before it has reached anything.
//   - Reaching `up` needs the network to allow tor out. It is asserted only
//     when WEBSPACE_TOR_NETWORK=1, which is CI opting into that dependency
//     (see the workflow step). Locally it degrades to a skip with the log
//     attached, so a developer on a censored network is not stuck.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:socks5_proxy/socks_client.dart' as socks5;

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/tor_geoip_io.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/proxy.dart';

/// Whether this run is the one that opted into the real Tor network.
final bool torRequired = Platform.environment['WEBSPACE_TOR_NETWORK'] == '1';

/// Where the plugin is supposed to exist, so its absence is a failure rather
/// than a platform this file does not cover.
final bool isApple = defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Everything the runtime and tor itself said, for a failure message that
/// explains itself instead of naming a timeout.
String torTranscript() {
  final entries = LogService.instance.allEntriesMerged
      .where((e) => e.tag == 'Tor' || e.tag == 'TorLog' || e.tag == 'TorGeoIP')
      .map((e) => '[${e.tag}/${e.level.name}] ${e.message}')
      .toList();
  return entries.isEmpty
      ? '(the Tor log is empty, which means the plugin never spoke)'
      : entries.join('\n');
}

/// The detail of a control-channel failure, or null for anything else.
///
/// The distinction this file turns on: tor not reaching the network is the
/// run's environment, and tor not reaching its own control port is our bug.
/// They arrive as the same `TorErrored`, and treating them alike is how a
/// broken handshake passed as "no network here" (BUG-013).
String? controlChannelFailure(TorStatus status) {
  if (status is! TorErrored) return null;
  final failure = classifyTorFailure(status.message);
  return failure.kind == TorFailureKind.controlChannel ? status.message : null;
}

/// The Tor Project's own answer to "which address reached me".
final Uri exitCheck = Uri.parse('https://check.torproject.org/api/ip');

/// Country of [ipv4] in a tor GeoIP [table], or null when no row covers it.
///
/// The table is the one tor resolved the pin against. What it is applied to
/// is the address the far side saw, so the witness is the web, not tor's
/// account of which relay it picked.
String? countryIn(String table, String ipv4) {
  final n = ipv4.split('.').map(int.parse).fold<int>(0, (a, o) => a * 256 + o);
  for (final line in const LineSplitter().convert(table)) {
    if (line.isEmpty || line.startsWith('#')) continue;
    final row = line.split(',');
    if (int.parse(row[0]) <= n && n <= int.parse(row[1])) return row[2];
  }
  return null;
}

/// A raw stream through [via] to [to], outside any HTTP client.
Future<Socket> openStream(UserProxySettings via, Uri to) {
  final address = via.address!;
  final colon = address.lastIndexOf(':');
  return socks5.SocksTCPClient.connect(
    [
      socks5.ProxySettings(
        InternetAddress(address.substring(0, colon)),
        int.parse(address.substring(colon + 1)),
        username: via.username,
        password: via.password,
      ),
    ],
    InternetAddress(to.host, type: InternetAddressType.unix),
    to.port,
  );
}

/// How long [stream] stayed open, from now until the far end ended it.
///
/// `done` is not the signal: it tracks the write side, and nothing here
/// writes. A read that ends is what tor closing the stream looks like.
Future<Duration> whenEnded(Socket stream) {
  final clock = Stopwatch()..start();
  final ended = Completer<Duration>();
  void end([Object? _]) {
    if (!ended.isCompleted) ended.complete(clock.elapsed);
  }

  stream.listen((_) {}, onDone: end, onError: end, cancelOnError: true);
  return ended.future;
}

/// tor's own account, over a control connection of the test's own.
///
/// What the web sees says whether a pin held; this says why not: which
/// circuit a stream rode, when that circuit was built, and which country tor
/// puts its exit in. The plugin's connection is out of Dart's reach, and tor
/// takes a second one without complaint.
class TorProbe {
  TorProbe._(this._socket, this._lines);

  final Socket _socket;
  final StreamIterator<String> _lines;

  static final _ipv4 = RegExp(r'^\d+\.\d+\.\d+\.\d+$');

  static Future<TorProbe> open() async {
    // `<Caches>/Tor`, the plugin's data directory, beside path_provider's
    // `<Caches>/<bundle id>`.
    final tor = '${(await getApplicationCacheDirectory()).parent.path}/Tor';
    final port = RegExp(r'PORT=([\d.]+):(\d+)')
        .firstMatch(await File('$tor/controlport').readAsString());
    if (port == null) throw StateError('no control port in $tor/controlport');
    final socket = await Socket.connect(port[1]!, int.parse(port[2]!));
    final probe = TorProbe._(
      socket,
      StreamIterator(utf8.decoder.bind(socket).transform(const LineSplitter())),
    );
    final cookie = await File('$tor/control_auth_cookie').readAsBytes();
    await probe._send('AUTHENTICATE '
        '${cookie.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
    return probe;
  }

  void close() => _socket.destroy();

  /// Reply lines with their status prefix cut, data blocks inline.
  Future<List<String>> _send(String command) async {
    final verb = command.split(' ').first;
    _socket.write('$command\r\n');
    final reply = <String>[];
    var inData = false;
    while (await _lines.moveNext().timeout(const Duration(seconds: 10))) {
      final line = _lines.current;
      if (inData) {
        if (line == '.') {
          inData = false;
        } else {
          reply.add(line);
        }
        continue;
      }
      if (line.length < 4 || !line.startsWith('2')) {
        throw StateError('$verb: $line');
      }
      reply.add(line.substring(4));
      if (line[3] == '+') inData = true;
      if (line[3] == ' ') return reply;
    }
    throw StateError('$verb: the control connection closed');
  }

  Future<String> info(String key) async {
    final body = (await _send('GETINFO $key'))..removeLast();
    final first = body.first;
    return [first.substring(first.indexOf('=') + 1), ...body.skip(1)]
        .where((l) => l.isNotEmpty)
        .join('\n');
  }

  Future<String> config() async =>
      (await _send('GETCONF ExitNodes StrictNodes GeoIPFile')).join(', ');

  /// circuit-status lines by circuit id, closed and failed ones left out.
  Future<Map<String, String>> circuits() async {
    final lines = (await info('circuit-status')).split('\n');
    return {
      for (final l in lines)
        if (l.split(' ').length > 1 &&
            !const {'CLOSED', 'FAILED'}.contains(l.split(' ')[1]))
          l.split(' ')[0]: l,
    };
  }

  /// Circuit id of every open stream to [host], by stream id.
  Future<Map<String, String>> streamsTo(String host) async {
    final lines = (await info('stream-status')).split('\n');
    return {
      for (final l in lines.map((l) => l.split(' ')))
        if (l.length > 3 && l[3].startsWith('$host:')) l[0]: l[2],
    };
  }

  /// A circuit-status line as purpose, age and exit, with tor's country for
  /// the exit's address.
  Future<String> describe(String line) async {
    final parts = line.split(' ');
    final fields = {
      for (final p in parts.skip(2))
        if (p.contains('=')) p.substring(0, p.indexOf('=')): p.substring(p.indexOf('=') + 1),
    };
    var exit = 'no exit yet';
    if (parts.length > 2 && parts[2].startsWith(r'$')) {
      final hop = parts[2].split(',').last.substring(1);
      final fingerprint = hop.split(RegExp('[~=]')).first;
      String ip = '?';
      try {
        final r = (await info('ns/id/$fingerprint'))
            .split('\n')
            .firstWhere((l) => l.startsWith('r '), orElse: () => '');
        ip = r.split(' ').firstWhere(_ipv4.hasMatch, orElse: () => '?');
      } catch (_) {}
      final cc = ip == '?' ? '?' : await info('ip-to-country/$ip');
      exit = 'exit $hop at $ip ($cc)';
    }
    return 'circuit ${parts[0]} ${parts[1]} ${fields['PURPOSE']} '
        'created ${fields['TIME_CREATED']}: $exit';
  }

  /// Every live circuit, described.
  Future<String> snapshot() async {
    final all = await circuits();
    return [for (final line in all.values) await describe(line)].join('\n');
  }

  /// The circuit each open stream to [host] rides, described.
  Future<String> ridden(String host) async {
    final all = await circuits();
    final streams = await streamsTo(host);
    if (streams.isEmpty) return 'no open stream to $host';
    return [
      for (final e in streams.entries)
        'stream ${e.key}: ${all[e.value] == null ? 'circuit ${e.value}, gone' : await describe(all[e.value]!)}',
    ].join('\n');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late StreamSubscription<TorStatus> sub;
  final seen = <TorStatus>[];

  /// Printed, not asserted: when this file reports nothing useful the log is
  /// all there is, and the first run of it in CI reported two ticks and "no
  /// tests were found" with no way to tell which branch each test took.
  void trace(String message) {
    // ignore: avoid_print
    print('[tor-test] $message');
  }

  setUpAll(() {
    DeveloperModeService.instance.debugSet(true);
    sub = TorService.instance.statusStream.listen(seen.add);
    trace('platform=$defaultTargetPlatform '
        'available=${TorService.instance.isAvailable} '
        'torRequired=$torRequired '
        'env=${Platform.environment['WEBSPACE_TOR_NETWORK']}');
  });

  tearDownAll(() async {
    await sub.cancel();
    TorService.instance.release('integration');
    DeveloperModeService.instance.debugSet(false);
  });

  /// Poll until [done] or [budget] runs out. A plain `await for` on the
  /// status stream would hang past the test timeout when nothing arrives at
  /// all, which is the failure this file most wants to describe.
  Future<bool> waitFor(bool Function() done, Duration budget) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      if (done()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return done();
  }

  testWidgets('the runtime bootstraps, says what it is doing, and restarts',
      (tester) async {
    trace('scenario 1 start');
    if (!TorService.instance.isAvailable) {
      // On an Apple build the runtime is supposed to be there, so its
      // absence is the finding rather than a reason to stand down: a skip
      // here is how a tier that reaches nothing reports success.
      if (isApple) {
        fail('the Tor runtime reports unavailable on an Apple build: either '
            'the plugin is not registered or developer mode did not take');
      }
      // Android, Linux and the web have no plugin (TOR-007); this file is
      // driven by the macOS tier.
      expect(torRequired, isFalse,
          reason: 'WEBSPACE_TOR_NETWORK=1 asked for a Tor run on a platform '
              'that has no runtime');
      markTestSkipped('no Tor runtime on this platform (TOR-007)');
      return;
    }

    await TorService.instance.maybeStart('integration');

    // The plugin answering at all. A build where it never registered lands
    // here as an error naming the missing runtime rather than as a hang.
    final spoke = await waitFor(
      () => TorService.instance.status is! TorStopped &&
          TorService.instance.status is! TorStarting,
      const Duration(seconds: 30),
    );
    final status = TorService.instance.status;
    expect(status is TorErrored && status.message.contains('No Tor runtime'),
        isFalse,
        reason: 'the channels have no plugin behind them: this build linked '
            'no tor, or the plugin was never registered');
    expect(spoke, isTrue,
        reason: 'the plugin never left "starting", so the control-port '
            'handshake did not complete:\n${torTranscript()}');
    // Leaving "starting" for an error is not completing the handshake. The
    // wait above is satisfied by either, so the failure that this file was
    // written for would otherwise travel on to the network assertions and
    // be reported as a network problem, or skipped outright.
    expect(controlChannelFailure(status), isNull,
        reason: 'the plugin never reached tor over its control port:\n'
            '${torTranscript()}');

    // TOR-018: the phase, not just a percentage. Before the fix TAG and
    // SUMMARY were read off the event and dropped at the platform seam, so
    // every bootstrapping status carried a bare number.
    final phased = await waitFor(
      () => seen.any((s) => s is TorBootstrapping && s.summary != null),
      const Duration(seconds: 30),
    );
    expect(phased, isTrue,
        reason: 'no bootstrap status carried tor\'s own phase:\n'
            '${seen.join(", ")}\n${torTranscript()}');

    // TOR-018: tor's own output reaches the app log, under its own tag and
    // in the sensitive ring. Waited for, not asserted outright: the phase
    // check above is satisfied by the initial 0% status, which carries a
    // summary before tor has emitted a single NOTICE, so a bare expect here
    // races the control port's first log line.
    final loggedTorOutput = await waitFor(
      () => LogService.instance.sensitiveEntries.any((e) => e.tag == 'TorLog'),
      const Duration(seconds: 30),
    );
    expect(
      loggedTorOutput,
      isTrue,
      reason: 'tor said nothing the app could show:\n${torTranscript()}',
    );
    expect(
      LogService.instance.entries.where((e) => e.tag == 'Tor'),
      isNotEmpty,
      reason: 'no state transition reached the app log',
    );

    // TOR-019: reaching `up` at all. The engine gives bootstrap 90 seconds
    // before it calls it off, so this waits a little past that to see which
    // of the two happened.
    final settled = await waitFor(
      () => TorService.instance.status is TorUp ||
          TorService.instance.status is TorErrored,
      const Duration(seconds: 100),
    );
    expect(settled, isTrue,
        reason: 'bootstrap neither finished nor failed:\n${torTranscript()}');

    final outcome = TorService.instance.status;
    if (outcome is TorUp) {
      expect(TorService.instance.socksEndpoint, isNotNull);
      expect(TorService.instance.socksFor(siteId: 'site-1'), isNotNull,
          reason: 'a connected runtime must hand a site its SOCKS settings');
    } else if (controlChannelFailure(outcome) != null) {
      // Never a skip, on any run: nothing here depends on the network.
      fail('Tor never answered on its control port:\n${torTranscript()}');
    } else if (torRequired) {
      fail('Tor did not connect on a run that required it:\n'
          '${torTranscript()}');
    } else {
      markTestSkipped('Tor did not reach the network here; '
          'handshake assertions still ran');
    }

    // TOR-020: a restart is the Retry button, and it must not stop tor. The
    // process gets one `tor_run_main`: the second dies in `threadpool_new`
    // and never bootstraps, so a Retry that tore the runtime down would end
    // the feature for the session (BUG-013 attempt 9). Retry re-arms the
    // wait on the tor that is already there.
    final before = TorService.instance.socksEndpoint;
    await TorService.instance.restart();
    final restarted = await waitFor(
      () => TorService.instance.status is TorUp ||
          TorService.instance.status is TorBootstrapping ||
          TorService.instance.status is TorErrored,
      const Duration(seconds: 60),
    );
    expect(restarted, isTrue,
        reason: 'the runtime never reported after a restart:\n'
            '${torTranscript()}');
    expect(TorService.instance.status, isNot(isA<TorStopped>()));
    expect(controlChannelFailure(TorService.instance.status), isNull,
        reason: 'the restarted runtime never reached tor\'s control port:\n'
            '${torTranscript()}');
    if (before != null) {
      expect(TorService.instance.socksEndpoint, before,
          reason: 'a Retry replaced the running tor instead of waiting on '
              'it; this process has no second launch:\n${torTranscript()}');
    }
    expect(
      LogService.instance.allEntriesMerged
          .any((e) => e.message.contains('already run once')),
      isFalse,
      reason: 'a Retry tried to launch a second tor:\n${torTranscript()}',
    );
    trace('scenario 1 done');
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('repeated Retries never take the runtime down', (tester) async {
    trace('scenario 2 start');
    if (!TorService.instance.isAvailable) {
      if (isApple) {
        fail('the Tor runtime reports unavailable on an Apple build');
      }
      markTestSkipped('no Tor runtime on this platform (TOR-007)');
      return;
    }

    // Retry is the one control the failure interstitial offers, and a user
    // whose first bootstrap is slow will use it more than once. Each one
    // used to stop and re-start tor; the second launch dies in
    // `threadpool_new` and never bootstraps, so two taps were enough to end
    // Tor for the session (BUG-013 attempt 9, TOR-020). Three taps here,
    // back to back, including one inside a handshake window.
    await TorService.instance.restart();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await TorService.instance.restart();
    await TorService.instance.restart();

    final recovered = await waitFor(
      () => TorService.instance.status is TorBootstrapping ||
          TorService.instance.status is TorUp,
      const Duration(seconds: 90),
    );
    expect(recovered, isTrue,
        reason: 'the runtime did not survive repeated Retries:'
            '\n${torTranscript()}');
    expect(
      LogService.instance.allEntriesMerged
          .any((e) => e.message.contains('already run once')),
      isFalse,
      reason: 'a Retry tried to launch a second tor:\n${torTranscript()}',
    );
    expect(
      LogService.instance.allEntriesMerged
          .any((e) => e.message.contains('still running')),
      isFalse,
      reason: 'a previous tor was left holding the process:\n'
          '${torTranscript()}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('an exit-country pin is the country the web sees',
      (tester) async {
    trace('scenario 3 start');
    if (!TorService.instance.isAvailable) {
      if (isApple) {
        fail('the Tor runtime reports unavailable on an Apple build');
      }
      markTestSkipped('no Tor runtime on this platform (TOR-007)');
      return;
    }

    // TOR-014. A pin to Brazil once left a page leaving from the
    // Netherlands twice over: tor had no GeoIP table, so `{br}` matched no
    // relay, and a connection the webview kept alive from before the pin
    // stayed on its Dutch circuit. Every fake in test/ answers the pin with
    // OK, so only a real tor can say whether either is fixed.
    final up = await waitFor(
      () => TorService.instance.status is TorUp,
      const Duration(seconds: 120),
    );
    if (!up) {
      if (torRequired) {
        fail('Tor was not up to take a pin:\n${torTranscript()}');
      }
      markTestSkipped('Tor did not reach the network here; nothing to pin');
      return;
    }

    // Read while up: a pending pin withholds SOCKS settings, and a tag keeps
    // its credentials for the whole launch.
    final via = TorService.instance.socksFor(siteId: 'exit-pin')!;
    final route = outboundHttp.clientFor(via);
    if (route is! OutboundClientReady) fail('no route through Tor: $route');
    // One client throughout, the way a webview keeps one pool.
    final client = route.client;

    TorProbe? probe;
    try {
      probe = await TorProbe.open();
    } catch (e) {
      trace('no control probe: $e');
    }
    Future<String> askTor(Future<String> Function(TorProbe) ask) async {
      final p = probe;
      if (p == null) return '(no control probe)';
      try {
        return await ask(p);
      } catch (e) {
        return '(probe failed: $e)';
      }
    }

    /// What tor says the check stream rode, and where tor puts [ip].
    Future<String> torView(String ip) => askTor((p) async =>
        'tor places $ip in ${await p.info('ip-to-country/$ip')}; '
        '${await p.config()}\n${await p.ridden(exitCheck.host)}');

    // Longer than tor's own patience with a stream (SocksTimeout, two
    // minutes). Until tor has timed 100 circuits it gives a stalled build
    // 60 s before trying another, so a fresh tor can spend a minute on the
    // first circuit after a pin change and still answer.
    const patience = Duration(seconds: 150);

    Future<String> exitAddress(String when) async {
      final clock = Stopwatch()..start();
      Future<http.Response> ask() => client.get(exitCheck).timeout(patience);
      http.Response response;
      try {
        try {
          response = await ask();
        } on http.ClientException catch (e) {
          // A kept-alive connection tor has just ended can fail the request
          // that races the close. The retry cannot hide a stale exit: that
          // answers, it does not fail.
          trace('check request $when failed once: $e');
          response = await ask();
        }
      } catch (e) {
        fail('the check $when got no answer in ${clock.elapsed.inSeconds}s '
            '($e):\n${torTranscript()}');
      }
      trace('check $when answered in ${clock.elapsed.inSeconds}s');
      expect(response.statusCode, 200,
          reason: 'check.torproject.org answered ${response.statusCode}: '
              '${response.body}');
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      trace('check.torproject.org saw $body');
      final ip = body['IP'] as String;
      expect(InternetAddress.tryParse(ip)?.type, InternetAddressType.IPv4,
          reason: 'the exit reached the check from $ip, and the table tor '
              'loads is IPv4 only');
      return ip;
    }

    Future<void> pin(String nodes) async {
      final clock = Stopwatch()..start();
      await TorService.instance.setExitCountry(nodes);
      final status = TorService.instance.status;
      expect(status, isA<TorUp>(),
          reason: 'pinning $nodes did not land ($status):\n${torTranscript()}');
      expect(TorService.instance.exitNodes, nodes);
      trace('$nodes in force after ${clock.elapsed.inSeconds}s');
      trace('circuits once $nodes landed:\n'
          '${await askTor((p) async => '${await p.config()}\n${await p.snapshot()}')}');
    }

    Socket? held;
    Socket? control;
    try {
      final unpinned = await exitAddress('unpinned');
      trace('unpinned: ${await torView(unpinned)}');

      // The first pin fetches the table through Tor before tor can resolve
      // any country, so its time is the download's.
      await pin('{de}');
      final kept = await createTorGeoIpStore()!.newest();
      expect(kept, isNotNull,
          reason: 'a pin landed with no GeoIP table on the device:\n'
              '${torTranscript()}');
      final table = await File(kept!.path).readAsString();
      trace('unpinned exit $unpinned is in ${countryIn(table, unpinned)}');

      final de = await exitAddress('under {de}');
      final deView = await torView(de);
      trace('under {de}: $deView');
      expect(countryIn(table, de), 'DE',
          reason: 'pinned {de}, and check.torproject.org saw $de, which the '
              'table places in ${countryIn(table, de)}. $deView\n'
              '${torTranscript()}');

      // A stream opened on the German circuit and left silent. Until the
      // server's own timeout, nothing but that circuit closing ends it.
      held = await openStream(via, exitCheck);
      final heldEnded = whenEnded(held);
      await pin('{us}');
      final heldLasted = await heldEnded
          .then<Duration?>((d) => d)
          .timeout(const Duration(seconds: 15), onTimeout: () => null);
      expect(heldLasted, isNotNull,
          reason: 'a stream opened under {de} was still open 15 s after {us} '
              'was in force, so a connection a page keeps alive goes on '
              'leaving from Germany:\n${torTranscript()}');

      final us = await exitAddress('under {us}');
      final usView = await torView(us);
      trace('under {us}: $usView');
      expect(countryIn(table, us), 'US',
          reason: 'pinned {us}, and check.torproject.org saw $us, which the '
              'table places in ${countryIn(table, us)}. $usView\n'
              '${torTranscript()}');

      // The control: a stream no change touches, left silent for longer
      // than the held one lasted. If the server ends it too, the held stream
      // measured the server, not tor.
      control = await openStream(via, exitCheck);
      final controlLasted = await whenEnded(control)
          .then<Duration?>((d) => d)
          .timeout(heldLasted! + const Duration(seconds: 5),
              onTimeout: () => null);
      expect(controlLasted, isNull,
          reason: 'the server ended a silent stream after $controlLasted, '
              'within the $heldLasted the held one lasted, so the held '
              'stream says nothing about tor');
      trace('exits: unpinned $unpinned, {de} $de, {us} $us; the stream '
          'opened under {de} ended ${heldLasted.inMilliseconds} ms after it '
          'opened');
    } finally {
      held?.destroy();
      control?.destroy();
      client.close();
      probe?.close();
    }

    // Clearing is its own round trip, RESETCONF and the same circuit close.
    await TorService.instance.setExitCountry(null);
    expect(TorService.instance.status, isA<TorUp>(),
        reason: 'clearing the pin did not land:\n${torTranscript()}');
    expect(TorService.instance.exitNodes, isNull);
    trace('scenario 3 done');
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('two sites at once never share a circuit', (tester) async {
    trace('scenario 4 start');
    if (!TorService.instance.isAvailable) {
      if (isApple) {
        fail('the Tor runtime reports unavailable on an Apple build');
      }
      markTestSkipped('no Tor runtime on this platform (TOR-007)');
      return;
    }

    // TOR-003 against a real tor. Every other isolation test checks that
    // each site hands tor its own credentials; only tor can say it kept them
    // apart. What is promised is two circuits, not two exits: a circuit's
    // exit is drawn by bandwidth, so two circuits can end at one relay, and
    // a country pin narrows the draw further.
    final up = await waitFor(
      () => TorService.instance.status is TorUp,
      const Duration(seconds: 120),
    );
    if (!up) {
      if (torRequired) {
        fail('Tor was not up to open two sites:\n${torTranscript()}');
      }
      markTestSkipped('Tor did not reach the network here');
      return;
    }

    // A host no other scenario dials, so every stream to it is one of these.
    final target = Uri.parse('https://www.torproject.org/');
    final probe = await TorProbe.open();
    final streams = <Socket>[];
    try {
      for (final site in ['site-a', 'site-b']) {
        streams.add(await openStream(
            TorService.instance.socksFor(siteId: site)!, target)
            .timeout(const Duration(seconds: 150)));
      }
      final rode = await probe.streamsTo(target.host);
      final seen = await probe.ridden(target.host);
      trace('two sites:\n$seen');
      expect(rode, hasLength(2),
          reason: 'tor lists ${rode.length} open streams to ${target.host}, '
              'not the two just opened:\n$seen');
      expect(rode.values.toSet(), hasLength(2),
          reason: 'site-a and site-b ride one circuit, so per-site isolation '
              'is not in force:\n$seen');
    } finally {
      for (final s in streams) {
        s.destroy();
      }
      probe.close();
    }
    trace('scenario 4 done');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
