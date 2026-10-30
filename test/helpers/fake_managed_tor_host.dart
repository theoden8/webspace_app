import 'dart:async';
import 'dart:typed_data';

import 'package:webspace/services/managed_tor_runtime.dart';
import 'package:webspace/services/tor_control.dart';
import 'package:webspace/services/tor_control_link.dart';
import 'package:webspace/services/tor_engine.dart' show TorRuntimeFailure;

import 'fake_tor_control.dart';

/// A program a [FakeManagedTorHost] started: a test writes its output with
/// [say] and ends it with [exit]; a kill ends it as a signal does.
class FakeChild implements ManagedChild {
  FakeChild(this.launch);

  final ManagedLaunch launch;
  final _lines = StreamController<String>();
  final _exit = Completer<int>();
  final kills = <bool>[];

  /// Whether a SIGTERM ends it; a stubborn one waits for SIGKILL.
  bool diesOnTerm = true;

  bool get exited => _exit.isCompleted;

  void say(String line) => scheduleMicrotask(() => _lines.add(line));

  void exit(int code) {
    if (_exit.isCompleted) return;
    _exit.complete(code);
    unawaited(_lines.close());
  }

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void kill({required bool force}) {
    kills.add(force);
    if (force || diesOnTerm) exit(force ? -9 : -15);
  }
}

/// The machine a [ManagedTorRuntime] runs on, as far as it asks: tor is a
/// [FakeTorControl] behind a control socket that answers once tor has
/// [listening] (after [refusedConnects] refusals), each launch's places are
/// fixed paths, and a pluggable transport is a child that answers the
/// managed-transport protocol with [transportPort], or as [transportAnswer]
/// says.
class FakeManagedTorHost implements ManagedTorHost {
  FakeManagedTorHost({FakeTorControl? tor, this.refusedConnects = 0})
      : tor = tor ??
            FakeTorControl(
              methods: {TorAuthMethod.cookie, TorAuthMethod.safeCookie},
              cookieFile: '/cache/tor/control_auth_cookie',
              socksListeners: const ['127.0.0.1:41337'],
            );

  final FakeTorControl tor;

  /// How many connects are refused before tor's socket answers.
  int refusedConnects;

  /// Whether tor answers on its control socket at all.
  bool listening = true;

  int transportPort = 4711;

  /// The lines a transport writes, given the transport it was asked for;
  /// null for the protocol's success.
  List<String> Function(String transport)? transportAnswer;

  final launches = <FakeChild>[];
  final prepared = <ManagedTorPlaces>[];
  final released = <ManagedTorPlaces>[];
  int connects = 0;

  FakeChild? get torProcess {
    for (final child in launches.reversed) {
      if (child.launch.environment['TOR_PT_CLIENT_TRANSPORTS'] == null) {
        return child;
      }
    }
    return null;
  }

  List<FakeChild> get transports => [
        for (final child in launches)
          if (child.launch.environment['TOR_PT_CLIENT_TRANSPORTS'] != null)
            child,
      ];

  @override
  Future<ManagedTorPlaces> prepare() async {
    final n = prepared.length;
    final places = ManagedTorPlaces(
      dataDirectory: '/cache/tor',
      controlSocket: '/tmp/wstor$n/control',
      torrc: '/tmp/wstor$n/torrc',
    );
    prepared.add(places);
    return places;
  }

  @override
  Future<void> release(ManagedTorPlaces places) async => released.add(places);

  @override
  Future<String> transportState() async => '/cache/tor_transports';

  @override
  Future<ManagedChild> spawn(ManagedLaunch launch) async {
    if (launch.executable.endsWith('/missing')) {
      throw TorRuntimeFailure('Could not start ${launch.executable}');
    }
    final child = FakeChild(launch);
    launches.add(child);
    final transport = launch.environment['TOR_PT_CLIENT_TRANSPORTS'];
    if (transport != null) {
      final lines = transportAnswer?.call(transport) ??
          [
            'VERSION 1',
            'CMETHOD $transport socks5 127.0.0.1:$transportPort',
            'CMETHODS DONE',
          ];
      for (final line in lines) {
        child.say(line);
      }
    } else {
      tor.onHalt = () => child.exit(0);
      child.say('Oct 30 10:56:07.829 [notice] Tor 0.4.9.11 running on Linux.');
    }
    return child;
  }

  @override
  TorControlConnect get connect => (endpoint) async {
        connects++;
        if (!listening || refusedConnects > 0) {
          refusedConnects--;
          throw TorControlUnreachable('Nothing answers at $endpoint');
        }
        return tor.connect();
      };

  @override
  TorCookieRead get readCookie => (path) async =>
      path == tor.cookieFile ? Uint8List.fromList(tor.cookie) : null;

  @override
  int get ownPid => 4242;
}
