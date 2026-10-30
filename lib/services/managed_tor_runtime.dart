// The built-in Tor on Linux: tor run as a child process of the app, started
// from the binary the build bundles (or one installed on the machine), and
// driven over its control socket as the Apple plugin drives Tor.framework.
// Spec: TOR-027.
//
// No dart:io: the processes and the directories are a [ManagedTorHost],
// opened by managed_tor_io.dart in the app and by a fake in tests. The
// control protocol is tor_control.dart's and tor_control_link.dart's, the
// one the external tor's link speaks (TOR-026).

import 'dart:async';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/tor_control.dart';
import 'package:webspace/services/tor_control_link.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_log.dart';
import 'package:webspace/utils/concurrency.dart';

/// How long the runtime keeps trying to reach a fresh tor's control socket,
/// as a poll interval and a count: tor binds it once it has read its
/// configuration, which on a cold machine takes seconds.
const Duration kManagedTorAttachPoll = Duration(milliseconds: 250);
const int kManagedTorAttachAttempts = 120;

/// How long a stopping tor gets to exit after `SIGNAL HALT`, and then after
/// SIGTERM, before it is killed.
const Duration kManagedTorExitWait = Duration(seconds: 5);

/// How long a pluggable transport gets to name its SOCKS listener.
const Duration kManagedTransportStartWait = Duration(seconds: 15);

/// How many of tor's own warnings a failure quotes.
const int _kRecentWarnings = 3;

/// Where tor and its pluggable transports live on this machine.
final class ManagedTorInstall {
  const ManagedTorInstall({
    required this.tor,
    required this.environment,
    required this.transports,
    required this.bundled,
  });

  /// tor's executable.
  final String tor;

  /// What every process started from the install adds to the app's
  /// environment: where the bundle keeps the libraries tor links.
  final Map<String, String> environment;

  /// The programs that can run each transport, in the order they are tried.
  final Map<TorTransport, List<String>> transports;

  /// Whether [tor] is the one the build bundles, rather than one found on
  /// the machine.
  final bool bundled;
}

/// Where one launch keeps its files.
final class ManagedTorPlaces {
  const ManagedTorPlaces({
    required this.dataDirectory,
    required this.controlSocket,
    required this.torrc,
  });

  /// tor's DataDirectory: its consensus, its guards and its cookie.
  final String dataDirectory;

  /// The Unix socket tor takes control connections on, in a directory only
  /// this user can list, which tor requires.
  final String controlSocket;

  /// An empty file, read as both torrc and defaults-torrc, so a torrc the
  /// machine's own tor service keeps (`/etc/tor/torrc`) never reaches this
  /// one.
  final String torrc;
}

/// A program the runtime started.
abstract interface class ManagedChild {
  /// Its standard output and standard error, a line at a time, kept until
  /// the one listener it has subscribes.
  Stream<String> get lines;

  Future<int> get exitCode;

  /// SIGTERM, or SIGKILL when [force].
  void kill({required bool force});
}

/// A program to start.
final class ManagedLaunch {
  const ManagedLaunch({
    required this.executable,
    required this.arguments,
    required this.environment,
  });

  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
}

/// What the runtime asks of the machine.
abstract interface class ManagedTorHost {
  /// The places for a launch, made ready. Throws [TorRuntimeFailure].
  Future<ManagedTorPlaces> prepare();

  /// Removes what [prepare] made for one launch, once its tor has exited.
  Future<void> release(ManagedTorPlaces places);

  /// Where pluggable transports keep their state, made ready. Throws
  /// [TorRuntimeFailure].
  Future<String> transportState();

  /// Starts [launch]. Throws [TorRuntimeFailure] when it cannot.
  Future<ManagedChild> spawn(ManagedLaunch launch);

  TorControlConnect get connect;
  TorCookieRead get readCookie;

  /// This process's id, which tor watches and exits with.
  int get ownPid;
}

/// The command line a launch runs tor with: everything on it, nothing read
/// from a torrc, as Tor.framework's TORConfiguration does on Apple.
///
/// `SocksPort auto IsolateSOCKSAuth`: a free loopback port tor picks and
/// reports, never 9050, which the machine's own tor may hold, with isolation
/// by the per-site credentials written out (TOR-003). `ConfluxEnabled 0`
/// for the runtime's life, as on Apple (TOR-014, TOR-024).
/// `__OwningControllerProcess` makes tor exit when the app does, however it
/// ends, so no tor outlives the process that started it (TOR-020).
List<String> managedTorArguments({
  required ManagedTorPlaces places,
  required int ownerPid,
  required List<(String, String)> options,
}) =>
    [
      '-f', places.torrc,
      '--defaults-torrc', places.torrc,
      '--DataDirectory', places.dataDirectory,
      '--ControlSocket', places.controlSocket,
      '--CookieAuthentication', '1',
      '--SocksPort', 'auto IsolateSOCKSAuth',
      '--ConfluxEnabled', '0',
      '--SafeLogging', '1',
      '--ClientOnly', '1',
      '--AvoidDiskWrites', '1',
      '--RunAsDaemon', '0',
      '--Log', 'notice stdout',
      '--__OwningControllerProcess', '$ownerPid',
      for (final (key, value) in options) ...['--$key', value],
    ];

/// The environment a managed pluggable transport is started with
/// (pt-spec.txt 3.2): client mode, the one [transport], and an exit when
/// its standard input closes, which it does when the app goes.
Map<String, String> managedTransportEnvironment(
        {required String transport, required String stateDirectory}) =>
    {
      'TOR_PT_MANAGED_TRANSPORT_VER': '1',
      'TOR_PT_CLIENT_TRANSPORTS': transport,
      'TOR_PT_STATE_LOCATION': stateDirectory,
      'TOR_PT_EXIT_ON_STDIN_CLOSE': '1',
    };

/// One line a managed pluggable transport wrote (pt-spec.txt 3.3).
sealed class PtLine {
  const PtLine();

  /// Null for a line that says nothing about the transport's methods:
  /// `VERSION`, `LOG`, `STATUS`, or anything else.
  static PtLine? parse(String line) {
    final words = line.trim().split(' ');
    switch (words.first) {
      case 'CMETHOD' when words.length >= 4 && words[2] == 'socks5':
        final at = words[3].lastIndexOf(':');
        final port = at < 0 ? null : int.tryParse(words[3].substring(at + 1));
        if (port == null || port <= 0) return null;
        return PtListening(words[1],
            host: words[3].substring(0, at), port: port);
      case 'CMETHOD-ERROR' when words.length >= 2:
        return PtRefused(words[1], message: words.skip(2).join(' '));
      case 'CMETHODS' when words.length >= 2 && words[1] == 'DONE':
        return const PtDone();
      case 'ENV-ERROR' || 'VERSION-ERROR' || 'PROXY-ERROR':
        return PtFailed(words.skip(1).join(' '));
    }
    return null;
  }
}

/// `CMETHOD <transport> socks5 <host>:<port>`.
final class PtListening extends PtLine {
  const PtListening(this.transport, {required this.host, required this.port});

  final String transport;
  final String host;
  final int port;
}

/// `CMETHOD-ERROR <transport> <message>`.
final class PtRefused extends PtLine {
  const PtRefused(this.transport, {required this.message});

  final String transport;
  final String message;
}

/// `CMETHODS DONE`: every method it will run has been named.
final class PtDone extends PtLine {
  const PtDone();
}

/// `ENV-ERROR`, `VERSION-ERROR` or `PROXY-ERROR`: it will run nothing.
final class PtFailed extends PtLine {
  const PtFailed(this.message);

  final String message;
}

/// A transport the runtime started, and the listener it named.
final class _RunningTransport {
  const _RunningTransport(this.child, {required this.port});

  final ManagedChild child;
  final int port;
}

/// One launch of tor and what the runtime knows of it.
final class _Run {
  _Run(this.child, {required this.places, required this.generation});

  final ManagedChild child;
  final ManagedTorPlaces places;
  final int generation;

  TorControlChannel? channel;

  /// The SOCKS endpoint read at attach, published only once bootstrap is
  /// done (TOR-008).
  ({String host, int port})? socks;

  /// tor's last warnings and errors, for a failure to quote.
  final List<String> warnings = [];
  bool exited = false;
}

class ManagedTorRuntime implements TorRuntime {
  ManagedTorRuntime({required ManagedTorInstall install, required ManagedTorHost host})
      : _install = install,
        _host = host;

  final ManagedTorInstall _install;
  final ManagedTorHost _host;
  final StreamController<TorStatus> _events =
      StreamController<TorStatus>.broadcast();

  /// Starts and stops, one at a time.
  final SerialQueue _lifecycle = SerialQueue('managedTorLifecycle');

  /// Commands on the control channel, one at a time, so the reads of one
  /// step are never interleaved with another's.
  final SerialQueue _control = SerialQueue('managedTorControl');

  /// Bumped by every start and stop: an attach or an event of an earlier
  /// run carries the generation it began in and does nothing once it no
  /// longer matches.
  int _generation = 0;
  _Run? _run;
  TorStatus _status = const TorStopped();

  /// The exit of a tor retired after a failure, which the next start waits
  /// for.
  Future<void>? _retiring;
  List<(String, String)> _torrcOptions = const [];
  final Map<String, _RunningTransport> _transports = {};

  @override
  bool get isAvailable => true;

  /// A launch is a child process and can be made again, but a failed exit
  /// pin retried on every resume would download a GeoIP table each time:
  /// the user's Retry is its retry, as on Apple.
  @override
  bool get retriesFreely => false;

  @override
  Stream<TorStatus> get events => _events.stream;

  /// A no-op while tor is running, as the engine's Retry relies on
  /// (TOR-020). A tor that has exited is started again: unlike Apple's, a
  /// child process leaves nothing behind in this one.
  @override
  Future<void> start() => _lifecycle.run(() async {
        if (_run != null) return;
        // Its data directory is this one's, and tor locks it.
        await _retiring;
        final generation = ++_generation;
        _emit(const TorStarting());
        final places = await _host.prepare();
        if (generation != _generation) {
          await _host.release(places);
          return;
        }
        _note(_install.bundled
            ? 'Starting the bundled tor${_bridgeNote()}.'
            : 'Starting ${_install.tor}${_bridgeNote()}.');
        final ManagedChild child;
        try {
          child = await _host.spawn(ManagedLaunch(
            executable: _install.tor,
            arguments: managedTorArguments(
                places: places,
                ownerPid: _host.ownPid,
                options: _torrcOptions),
            environment: _install.environment,
          ));
        } on TorRuntimeFailure {
          await _host.release(places);
          rethrow;
        }
        final run = _run = _Run(child, places: places, generation: generation);
        child.lines.listen((line) => _onTorLine(line, run: run));
        unawaited(child.exitCode.then((code) => _onExit(code, run: run)));
        unawaited(_attach(run));
      });

  String _bridgeNote() => _torrcOptions.isEmpty
      ? ', with no bridges configured'
      : ', with ${_torrcOptions.length} extra torrc option(s)';

  void _onTorLine(String line, {required _Run run}) {
    if (line.trim().isEmpty) return;
    final parsed = parseTorLogLine(line);
    logTorLine(parsed);
    if (parsed.level == LogLevel.warning || parsed.level == LogLevel.error) {
      run.warnings.add(parsed.message);
      if (run.warnings.length > _kRecentWarnings) run.warnings.removeAt(0);
    }
  }

  /// Keep connecting to [run]'s control socket until tor answers, then
  /// authenticate, read what bootstrap needs, and subscribe to its status.
  Future<void> _attach(_Run run) async {
    for (var attempt = 0; attempt < kManagedTorAttachAttempts; attempt++) {
      if (!_current(run)) return;
      final TorControlChannel channel;
      try {
        channel = await _host
            .connect(TorControlSocket(run.places.controlSocket))
            .timeout(kTorControlCommandTimeout);
      } on TorControlUnreachable {
        await Future<void>.delayed(kManagedTorAttachPoll);
        continue;
      } on TimeoutException {
        await Future<void>.delayed(kManagedTorAttachPoll);
        continue;
      }
      if (!_current(run)) {
        await channel.close();
        return;
      }
      _note('Control port answered; authenticating.');
      await _control.run(() => _adopt(channel, run: run));
      return;
    }
    if (!_current(run)) return;
    final waited = kManagedTorAttachPoll * kManagedTorAttachAttempts;
    _retire(run,
        message: 'Could not reach the Tor control port after '
            '${waited.inSeconds} seconds.${_quoted(run)}');
  }

  /// [run] failed with tor still running: a tor nobody can talk to is
  /// stopped, so a Retry starts one that can be (TOR-020).
  void _retire(_Run run, {required String message}) {
    _generation++;
    if (identical(_run, run)) _run = null;
    final channel = run.channel;
    run.channel = null;
    _fail(message);
    _retiring = () async {
      await channel?.close();
      if (!run.exited) await _awaitExit(run.child, asked: false);
    }();
  }

  Future<void> _adopt(TorControlChannel channel, {required _Run run}) async {
    try {
      switch (await authenticateTorControl(channel,
          password: null, readCookie: _host.readCookie)) {
        case TorControlAuthRefused(:final detail):
          await channel.close();
          if (_current(run)) {
            _retire(run, message: 'Tor control authentication failed: $detail');
          }
          return;
        case TorControlAuthenticated():
      }
      // tor exits when this connection closes, as well as with the app.
      await channel.command('TAKEOWNERSHIP');
      final listeners = torKeyValues(
          await channel.command('GETINFO net/listeners/socks'));
      final phase = torKeyValues(
          await channel.command('GETINFO status/bootstrap-phase'));
      if (!_current(run)) {
        await channel.close();
        return;
      }
      run.channel = channel;
      run.socks = _socksOf(listeners['net/listeners/socks']?.firstOrNull);
      if (run.socks == null) _note('Tor has not opened a SOCKS listener yet.');
      channel.events.listen((event) => _onEvent(event, run: run));
      unawaited(channel.done.then((_) => _onChannelClosed(run)));
      await channel.command('SETEVENTS STATUS_CLIENT');
      _note('Control port authenticated.');
      final bootstrap =
          torBootstrapPhase(phase['status/bootstrap-phase']?.firstOrNull ?? '');
      if (bootstrap != null) {
        _note('Bootstrap was at ${bootstrap.percent}% when the control port '
            'attached.');
        _onBootstrap(bootstrap, run: run);
      }
    } on TorControlClosed {
      // tor went: its exit says why.
    } on TimeoutException {
      await channel.close();
      if (_current(run)) {
        _retire(run, message: 'Tor did not answer on its control port.');
      }
    } on TorControlRejected catch (e) {
      await channel.close();
      if (_current(run)) {
        _retire(run, message: 'Tor refused a control port command: $e');
      }
    } on FormatException catch (e) {
      await channel.close();
      if (_current(run)) {
        _retire(run,
            message: 'Tor answered its control port unreadably: ${e.message}');
      }
    }
  }

  /// The first `host:port` of a `net/listeners/socks` value.
  static ({String host, int port})? _socksOf(String? raw) {
    for (final listener in torQuotedList(raw ?? '')) {
      final at = listener.lastIndexOf(':');
      if (at <= 0) continue;
      final port = int.tryParse(listener.substring(at + 1));
      if (port != null && port > 0) {
        return (host: listener.substring(0, at), port: port);
      }
    }
    return null;
  }

  void _onEvent(TorControlReply event, {required _Run run}) {
    if (!_current(run) || event.lines.isEmpty) return;
    final line = event.lines.first;
    if (!line.startsWith('STATUS_CLIENT ')) return;
    if (line.split(' ').contains('CIRCUIT_ESTABLISHED')) {
      _finish(run);
      return;
    }
    final bootstrap = torBootstrapPhase(line);
    if (bootstrap != null) _onBootstrap(bootstrap, run: run);
  }

  void _onBootstrap(({int percent, String? tag, String? summary}) phase,
      {required _Run run}) {
    final status = _status;
    // Never backwards, and never over a terminal state.
    if (status is! TorStarting && status is! TorBootstrapping) return;
    if (status is TorBootstrapping && phase.percent < status.percent) return;
    _emit(TorBootstrapping(phase.percent,
        tag: phase.tag, summary: phase.summary));
    if (phase.percent >= 100) _finish(run);
  }

  /// Bootstrap is done: publish the endpoint read at attach. Idempotent,
  /// since CIRCUIT_ESTABLISHED and `PROGRESS=100` both lead here.
  void _finish(_Run run) {
    final status = _status;
    if (status is! TorStarting && status is! TorBootstrapping) return;
    final socks = run.socks;
    if (socks == null) {
      _retire(run, message: 'Tor reported no usable SOCKS listener.');
      return;
    }
    _emit(TorUp(socks.host, port: socks.port));
    _note('Connected. SOCKS listener on ${socks.host}:${socks.port}.');
  }

  /// tor took ownership of the channel, so it exits as the channel
  /// closes, and its exit is what is reported.
  void _onChannelClosed(_Run run) {
    if (!_current(run)) return;
    run.channel = null;
    _note("Tor's control port closed.");
  }

  void _onExit(int code, {required _Run run}) {
    run.exited = true;
    run.channel = null;
    if (identical(_run, run)) _run = null;
    unawaited(_host.release(run.places));
    if (run.generation != _generation) return;
    _fail(_status is TorUp
        ? 'Tor exited (code $code).${_quoted(run)}'
        : 'Tor exited before it connected (code $code): it rejected its '
            'configuration or could not open a listener.${_quoted(run)}');
  }

  /// tor's last warnings, as a failure quotes them.
  static String _quoted(_Run run) =>
      run.warnings.isEmpty ? '' : ' tor said: ${run.warnings.join(' / ')}';

  bool _current(_Run run) =>
      run.generation == _generation && identical(_run, run) && !run.exited;

  /// Asks tor to exit and waits for it, then for the transports.
  @override
  Future<void> stop() => _lifecycle.run(() async {
        _generation++;
        final run = _run;
        _run = null;
        if (run != null && !run.exited) {
          _note('Stopping tor.');
          final channel = run.channel;
          run.channel = null;
          var asked = false;
          if (channel != null) {
            try {
              await channel.command('SIGNAL HALT',
                  within: const Duration(seconds: 3));
              asked = true;
            } on TorControlClosed {
              // Already on its way out.
            } on TimeoutException {
              _note('tor did not answer SIGNAL HALT.');
            } on TorControlRejected catch (e) {
              _note('tor refused SIGNAL HALT: $e');
            }
            await channel.close();
          }
          await _awaitExit(run.child, asked: asked);
        }
        await _stopTransports();
        _emit(const TorStopped());
      });

  /// Waits for [child] to exit: a bounded wait for one [asked] to already,
  /// then SIGTERM, then SIGKILL.
  Future<void> _awaitExit(ManagedChild child, {required bool asked}) async {
    final exited = child.exitCode;
    if (!asked) child.kill(force: false);
    for (final force in [if (asked) false, true]) {
      try {
        await exited.timeout(kManagedTorExitWait);
        return;
      } on TimeoutException {
        child.kill(force: force);
      }
    }
    await exited;
  }

  @override
  Future<void> rebuildCircuits() async {
    final run = _run;
    final channel = run?.channel;
    if (channel == null) return;
    await _control.run(() async {
      try {
        await channel.command('SIGNAL NEWNYM');
      } on TorControlClosed {
        _note('New circuits: the control channel had closed.');
      } on TimeoutException {
        _note('New circuits: the control port did not answer.');
      } on TorControlRejected catch (e) {
        _note('New circuits refused: $e');
      }
    });
  }

  @override
  Future<void> applyExitCountry(String? exitNodes, {String? geoipFile}) =>
      _commandUp('the exit-country change', body: (channel) async {
        if (exitNodes == null) {
          await channel.command('RESETCONF ExitNodes');
          await channel.command('SETCONF StrictNodes=0 ConfluxEnabled=0');
          await torCloseExitCircuits(channel);
          return;
        }
        // tor parses a GeoIP path it has not read yet, which is why each
        // download has a name of its own (TOR-014).
        if (geoipFile != null && geoipFile.isNotEmpty) {
          await channel.command('SETCONF GeoIPFile=${torQuoted(geoipFile)}');
        }
        final geoip = torKeyValues(
            await channel.command('GETINFO ip-to-country/ipv4-available'));
        if (geoip['ip-to-country/ipv4-available']?.firstOrNull != '1') {
          throw const TorRuntimeFailure('Tor has no GeoIP data loaded, so the '
              'exit-country pin cannot resolve a country. The pin was not '
              'applied.');
        }
        final countries = torPinnedCountries(exitNodes);
        if (countries != null &&
            await torHasNoExitIn(channel, countries: countries)) {
          final names = (countries.toList()..sort())
              .map((c) => c.toUpperCase())
              .join(', ');
          throw TorExitCountryEmpty("tor's consensus lists no exit relay in "
              '$names, so no circuit could be built under this exit-country '
              'pin, and it was not applied. Sites pinned there stay blocked: '
              'nothing leaves from another country instead.');
        }
        await channel.command('SETCONF ExitNodes=${torQuoted(exitNodes)} StrictNodes=1 '
            'ConfluxEnabled=0');
        await torCloseExitCircuits(channel);
        _note('Exit-country pin applied.');
      });

  /// Close every listener and relay connection and open the listeners
  /// again (TOR-024), with [bridgeOptions] in force as the network comes
  /// back, then publish the SOCKS endpoint tor now has.
  @override
  Future<void> reopenListeners(
          {required List<(String, String)> bridgeOptions}) =>
      _commandUp('reopening its listeners', body: (channel) async {
        await channel.command('SETCONF DisableNetwork=1');
        final bridges = [
          for (final (key, value) in bridgeOptions) '$key=${torQuoted(value)}',
        ];
        await channel.command('SETCONF ${[...bridges, 'DisableNetwork=0'].join(' ')}');
        final listeners = torKeyValues(
            await channel.command('GETINFO net/listeners/socks'));
        final socks = _socksOf(listeners['net/listeners/socks']?.firstOrNull);
        final run = _run;
        if (socks == null || run == null) {
          throw const TorRuntimeFailure('Tor did not reopen its SOCKS listener.');
        }
        run.socks = socks;
        _emit(TorUp(socks.host, port: socks.port));
        _note('Reopened. SOCKS listener on ${socks.host}:${socks.port}.');
      });

  @override
  Future<bool> circuitEstablished() async {
    var built = false;
    await _commandUp('whether it has a circuit', body: (channel) async {
      final values = torKeyValues(
          await channel.command('GETINFO status/circuit-established'));
      built = values['status/circuit-established']?.firstOrNull == '1';
    });
    return built;
  }

  /// [body] on the control channel of a tor that is up, with whatever the
  /// channel fails with reported as the runtime's failure, naming [what].
  Future<void> _commandUp(String what,
      {required Future<void> Function(TorControlChannel channel) body}) async {
    final channel = _run?.channel;
    if (channel == null || (_status is! TorUp && _status is! TorBootstrapping)) {
      throw TorRuntimeFailure('Tor is not connected, so $what did not happen.');
    }
    await _control.run(() async {
      try {
        await body(channel);
      } on TorControlClosed {
        throw TorRuntimeFailure(
            "Tor's control port closed during $what, so it is not in force.");
      } on TimeoutException {
        throw TorRuntimeFailure(
            "Tor's control port did not answer during $what, so it is not "
            'in force.');
      } on TorControlRejected catch (e) {
        throw TorRuntimeFailure('Tor refused $what ($e).');
      } on FormatException catch (e) {
        throw TorRuntimeFailure(
            "Tor's control port answered $what unreadably: ${e.message}");
      }
    });
  }

  /// Starts [transport] as a managed pluggable transport and answers the
  /// port of the SOCKS listener it names, or 0 when no program here runs
  /// it. A running one answers its port again.
  @override
  Future<int> startTransport(String transport) =>
      _lifecycle.run(() => _startTransport(transport));

  @override
  Future<int> restartTransport(String transport) =>
      _lifecycle.run(() async {
        final running = _transports.remove(transport);
        if (running != null) await _awaitExit(running.child, asked: false);
        return _startTransport(transport);
      });

  Future<int> _startTransport(String transport) async {
    final running = _transports[transport];
    if (running != null) return running.port;
    final kind = TorTransport.fromWireName(transport);
    final programs = kind == null ? const <String>[] : _install.transports[kind];
    if (programs == null || programs.isEmpty) {
      _note('No program here runs the $transport transport; continuing '
          'without bridges.');
      return 0;
    }
    final stateDirectory = await _host.transportState();
    for (final program in programs) {
      final started = await _tryTransport(transport,
          program: program, stateDirectory: stateDirectory);
      if (started == null) continue;
      _transports[transport] = started;
      // One that dies is started again on the next ask, not answered by a
      // port nothing listens on.
      unawaited(started.child.exitCode.then((_) {
        if (identical(_transports[transport], started)) {
          _transports.remove(transport);
        }
      }));
      _note('Pluggable transport $transport listening on port '
          '${started.port}.');
      return started.port;
    }
    _note('Pluggable transport $transport failed to start; continuing '
        'without bridges.');
    return 0;
  }

  Future<_RunningTransport?> _tryTransport(String transport,
      {required String program, required String stateDirectory}) async {
    final ManagedChild child;
    try {
      child = await _host.spawn(ManagedLaunch(
        executable: program,
        arguments: const [],
        environment: {
          ..._install.environment,
          ...managedTransportEnvironment(
              transport: transport, stateDirectory: stateDirectory),
        },
      ));
    } on TorRuntimeFailure catch (e) {
      _note('$program did not start: $e');
      return null;
    }
    final answer = Completer<int?>();
    final sub = child.lines.listen((line) {
      if (answer.isCompleted) return;
      switch (PtLine.parse(line)) {
        case PtListening(transport: final name, :final port)
            when name == transport:
          answer.complete(port);
        case PtRefused(transport: final name, :final message)
            when name == transport:
          _note('$program refused $transport: $message');
          answer.complete(null);
        case PtFailed(:final message):
          _note('$program failed: $message');
          answer.complete(null);
        case PtDone():
          answer.complete(null);
        case PtListening() || PtRefused() || null:
      }
    });
    unawaited(child.exitCode.then((_) {
      if (!answer.isCompleted) answer.complete(null);
    }));
    final int? port;
    try {
      port = await answer.future.timeout(kManagedTransportStartWait);
    } on TimeoutException {
      _note('$program named no $transport listener in time.');
      await sub.cancel();
      await _awaitExit(child, asked: false);
      return null;
    }
    if (port == null) {
      await sub.cancel();
      await _awaitExit(child, asked: false);
      return null;
    }
    return _RunningTransport(child, port: port);
  }

  Future<void> _stopTransports() async {
    final running = _transports.values.toList();
    _transports.clear();
    for (final transport in running) {
      await _awaitExit(transport.child, asked: false);
    }
  }

  @override
  Future<void> setTorrcOptions(List<(String, String)> options) async {
    _torrcOptions = List.unmodifiable(options);
  }

  void _fail(String message) {
    _note(message);
    _emit(TorErrored(message));
  }

  void _note(String message) => logTorLine(
      TorLogLine(fromTor: false, level: LogLevel.info, message: message));

  void _emit(TorStatus status) {
    _status = status;
    if (!_events.isClosed) _events.add(status);
  }
}
