// What iOS does to the app's sockets while it is suspended, done on the
// macOS tier to a running tor.
//
// A phone that suspended the app with tor running came back with tor's
// control port and SOCKS port dead, and nothing in the process could reach
// tor or start another. The kernel defuncts a suspended app's sockets
// through `socket_defunct`, which spares a socket born SOF_NODEFUNCT, and
// every Unix-domain socket is (xnu bsd/kern/uipc_socket.c, socreate).
// `pid_shutdown_sockets` is the same call made on demand.
//
// Not a `flutter test`: the defunct takes every TCP socket the process owns,
// the VM service connection `flutter test` drives the app over included.
// The workflow builds this file as the Runner's entrypoint, runs the binary,
// and reads the verdict off stderr (`[tor-suspend]` lines).

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/tor_service.dart';

/// xnu bsd/sys/proc.h and bsd/kern/syscalls.master.
const int _kDisconnectAll = 0x2;
const int _kSysPidShutdownSockets = 436;

final Uri _exitCheck = Uri.parse('https://check.torproject.org/api/ip');

void _say(String message) => stderr.writeln('[tor-suspend] $message');

int _pid() => DynamicLibrary.process()
    .lookupFunction<Int32 Function(), int Function()>('getpid')();

int _errno() => DynamicLibrary.process()
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__error')()
    .value;

/// `pid_shutdown_sockets(getpid(), DISCONNECT_ALL)`, as a result line.
String _defunctOwnSockets() {
  final libc = DynamicLibrary.process();
  final int rc;
  if (libc.providesSymbol('pid_shutdown_sockets')) {
    rc = libc.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'pid_shutdown_sockets')(_pid(), _kDisconnectAll);
  } else {
    rc = libc.lookupFunction<Int32 Function(Int32, VarArgs<(Int32, Int32)>),
        int Function(int, int, int)>('syscall')(
        _kSysPidShutdownSockets, _pid(), _kDisconnectAll);
  }
  return rc == 0 ? 'ok' : 'rc=$rc errno=${_errno()}';
}

/// A connected pair whose far end echoes, to tell a live socket from a
/// defunct one after the fact.
class _Pair {
  _Pair._(this.client, this._echoes);

  final Socket client;
  final Stream<Uint8List> _echoes;

  static Future<_Pair> open(InternetAddress address, int port) async {
    final server = await ServerSocket.bind(address, port);
    final accepted = server.first;
    final client = await Socket.connect(address, server.port);
    final far = await accepted;
    far.listen(far.add, onError: (Object _) {}, cancelOnError: true);
    return _Pair._(client, client.asBroadcastStream());
  }

  Future<bool> echoes() async {
    try {
      final back = _echoes.first.timeout(const Duration(seconds: 3));
      client.add(const [42]);
      await client.flush().timeout(const Duration(seconds: 3));
      return (await back).contains(42);
    } catch (_) {
      return false;
    }
  }
}

/// Whether a SOCKS5 listener at [endpoint] answers a greeting.
Future<bool> _socksAnswers(String endpoint) async {
  final colon = endpoint.lastIndexOf(':');
  try {
    final socket = await Socket.connect(
      endpoint.substring(0, colon),
      int.parse(endpoint.substring(colon + 1)),
      timeout: const Duration(seconds: 3),
    );
    try {
      socket.add(const [5, 1, 0]);
      final reply = await socket.first.timeout(const Duration(seconds: 3));
      return reply.length >= 2 && reply[0] == 5 && reply[1] == 0;
    } finally {
      socket.destroy();
    }
  } catch (_) {
    return false;
  }
}

/// A control connection of the probe's own: over tor's Unix socket where
/// the plugin gave it one, else over the TCP port it published.
class _Control {
  _Control._(this.kind, this._socket, this._lines);

  final String kind;
  final Socket _socket;
  final StreamIterator<String> _lines;

  static Future<_Control?> open() async {
    final tor = '${(await getApplicationCacheDirectory()).parent.path}/Tor';
    final status = await const MethodChannel('org.codeberg.theoden8.webspace/tor')
        .invokeMapMethod<String, Object?>('status');
    final unix = status?['controlSocket'];
    Socket socket;
    String kind;
    if (unix is String && await File(unix).exists()) {
      socket = await Socket.connect(
          InternetAddress(unix, type: InternetAddressType.unix), 0);
      kind = 'unix';
    } else {
      final port = RegExp(r'PORT=([\d.]+):(\d+)')
          .firstMatch(await File('$tor/controlport').readAsString());
      if (port == null) return null;
      socket = await Socket.connect(port[1]!, int.parse(port[2]!));
      kind = 'tcp';
    }
    final control = _Control._(kind, socket,
        StreamIterator(utf8.decoder.bind(socket).transform(const LineSplitter())));
    final cookie = await File('$tor/control_auth_cookie').readAsBytes();
    final hex = cookie.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return await control.answers('AUTHENTICATE $hex') ? control : null;
  }

  Future<bool> answers(String command) async {
    try {
      _socket.write('$command\r\n');
      while (await _lines.moveNext().timeout(const Duration(seconds: 5))) {
        final line = _lines.current;
        if (line.startsWith('250 ')) return true;
        if (!line.startsWith('250') && !line.startsWith('650')) return false;
      }
    } catch (_) {}
    return false;
  }
}

Future<bool> _waitFor(bool Function() done, Duration budget) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    if (done()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return done();
}

Future<String?> _exitAddress(String reason) async {
  final via = TorService.instance.socksFor(siteId: reason);
  if (via == null) return null;
  final route = outboundHttp.clientFor(via);
  if (route is! OutboundClientReady) return null;
  try {
    final response =
        await route.client.get(_exitCheck).timeout(const Duration(seconds: 90));
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['IsTor'] == true ? body['IP'] as String? : 'not-tor';
  } catch (e) {
    return null;
  } finally {
    route.client.close();
  }
}

Future<bool> _run() async {
  var ok = true;
  void check(bool passed, String what) {
    _say('${passed ? 'ok' : 'FAIL'}: $what');
    if (!passed) ok = false;
  }

  DeveloperModeService.instance.debugSet(true);
  if (!TorService.instance.isAvailable) {
    check(false, 'the Tor runtime is available on this build');
    return false;
  }
  const reason = 'suspend-probe';
  await TorService.instance.maybeStart(reason);
  final up = await _waitFor(
      () => TorService.instance.status is TorUp, const Duration(minutes: 4));
  check(up, 'tor bootstrapped (${TorService.instance.status})');
  if (!up) return false;

  final before = TorService.instance.socksEndpoint!;
  final exitBefore = await _exitAddress(reason);
  check(exitBefore != null && exitBefore != 'not-tor',
      'a request through $before left from a Tor exit ($exitBefore)');

  final tcp = await _Pair.open(InternetAddress.loopbackIPv4, 0);
  final unixPath = '${(await getTemporaryDirectory()).path}/ts.sock';
  if (await File(unixPath).exists()) await File(unixPath).delete();
  final unix = await _Pair.open(
      InternetAddress(unixPath, type: InternetAddressType.unix), 0);
  final control = await _Control.open();
  _say('control connection: ${control?.kind ?? 'none'}');

  var defunct = _defunctOwnSockets();
  if (defunct != 'ok') {
    // The sandbox may refuse the call; a root helper outside it is the
    // workflow's fallback, asked for here and waited on.
    _say('self defunct refused ($defunct); request-defunct pid=${_pid()}');
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    var helped = false;
    while (!helped && DateTime.now().isBefore(deadline)) {
      helped = !await tcp.echoes();
      if (!helped) await Future<void>.delayed(const Duration(seconds: 1));
    }
    defunct = helped ? 'ok (root helper)' : 'no helper answered';
  }
  _say('defunct: $defunct');
  if (!defunct.startsWith('ok')) {
    check(false, 'the process could have its sockets defuncted');
    return false;
  }

  final tcpAfter = await tcp.echoes();
  final unixAfter = await unix.echoes();
  _say('kernel: tcp=${tcpAfter ? 'alive' : 'dead'} '
      'unix=${unixAfter ? 'alive' : 'dead'}');
  check(!tcpAfter, 'a loopback TCP connection died with the defunct');
  check(unixAfter, 'a Unix-domain connection survived it');

  final socksAfter = await _socksAnswers(before);
  _say('after defunct: SOCKS at $before answers=$socksAfter');
  check(!socksAfter, 'tor\'s SOCKS listener died with the defunct');
  if (control != null) {
    final answered = await control.answers('GETINFO version');
    _say('after defunct: ${control.kind} control connection answers=$answered');
  }

  // What the app sees on coming back from a suspension.
  WidgetsBinding.instance
    ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
    ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);

  final recovered = await _waitFor(() {
    final endpoint = TorService.instance.socksEndpoint;
    return endpoint != null && endpoint != before;
  }, const Duration(minutes: 2));
  final after = TorService.instance.socksEndpoint;
  _say('after resume: status=${TorService.instance.status}');
  check(recovered, 'tor published a new SOCKS listener after the resume');
  if (after != null) {
    check(await _socksAnswers(after), 'the SOCKS listener at $after answers');
    final exitAfter = await _exitAddress(reason);
    check(exitAfter != null && exitAfter != 'not-tor',
        'a request through $after left from a Tor exit ($exitAfter)');
  }
  return ok;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final watchdog = Timer(const Duration(minutes: 12), () {
    _say('verdict: FAILED (gave up after 12 minutes)');
    exit(2);
  });
  var ok = false;
  try {
    ok = await _run();
  } catch (e, stack) {
    _say('FAIL: $e\n$stack');
  }
  watchdog.cancel();
  if (!ok) {
    for (final e in LogService.instance.allEntriesMerged
        .where((e) => e.tag == 'Tor' || e.tag == 'TorLog')) {
      _say('log [${e.tag}] ${e.message}');
    }
  }
  _say('verdict: ${ok ? 'recovered' : 'FAILED'}');
  exit(ok ? 0 : 1);
}
