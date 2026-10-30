import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'package:webspace/services/file_store.dart' show StoreKind;
import 'package:webspace/services/file_store_io.dart' show appDirectory;
import 'package:webspace/services/managed_tor_runtime.dart';
import 'package:webspace/services/tor_bridges.dart' show TorTransport;
import 'package:webspace/services/tor_control_io.dart';
import 'package:webspace/services/tor_control_link.dart';
import 'package:webspace/services/tor_engine.dart' show TorRuntimeFailure;

/// The built-in Tor runtime on this machine, or null when no tor is here
/// to run (TOR-027).
ManagedTorRuntime? createManagedTorRuntime() {
  final install = findManagedTor(
    executable: Platform.resolvedExecutable,
    environment: Platform.environment,
  );
  if (install == null) return null;
  return ManagedTorRuntime(install: install, host: IoManagedTorHost());
}

/// The licence texts the bundled tor came with, as (package, text).
Future<List<(String, String)>> managedTorNotices() async {
  final docs = Directory('${_bundleDir(Platform.resolvedExecutable)}/docs');
  if (!await docs.exists()) return const [];
  final out = <(String, String)>[];
  await for (final entry in docs.list()) {
    if (entry is! File || !entry.path.endsWith('.txt')) continue;
    final name = entry.uri.pathSegments.last;
    out.add((
      '${name.substring(0, name.length - 4)} (bundled with the built-in Tor)',
      await entry.readAsString(),
    ));
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  return out;
}

/// Where the build puts tor beside the executable (linux/CMakeLists.txt).
String _bundleDir(String executable) => '${File(executable).parent.path}/lib/tor';

/// The programs that run [transport], in the order they are tried: the
/// Tor Project's lyrebird runs all but dnstt, and the older single-purpose
/// ones stand in for it where a machine has those instead.
List<String> _transportPrograms(TorTransport transport) => switch (transport) {
      TorTransport.obfs4 || TorTransport.meekLite => ['lyrebird', 'obfs4proxy'],
      TorTransport.webtunnel => ['lyrebird'],
      TorTransport.snowflake => ['lyrebird', 'snowflake-client'],
      TorTransport.dnstt => const [],
    };

/// The tor the build bundles beside [executable], else the first `tor` on
/// [environment]'s PATH or in the sbin directories a distribution installs
/// it to. Null when there is none.
ManagedTorInstall? findManagedTor({
  required String executable,
  required Map<String, String> environment,
}) {
  final bundle = _bundleDir(executable);
  final bundled = File('$bundle/tor').existsSync();
  final tor = bundled ? '$bundle/tor' : _which('tor', environment: environment);
  if (tor == null) return null;
  String? program(String name) {
    final inBundle = '$bundle/pluggable_transports/$name';
    if (bundled && File(inBundle).existsSync()) return inBundle;
    return _which(name, environment: environment);
  }

  final libraries = environment['LD_LIBRARY_PATH'] ?? '';
  return ManagedTorInstall(
    tor: tor,
    // The bundle's tor links the libevent and OpenSSL beside it, as Tor
    // Browser's does.
    environment: bundled
        ? {'LD_LIBRARY_PATH': libraries.isEmpty ? bundle : '$bundle:$libraries'}
        : const {},
    transports: {
      for (final transport in TorTransport.values)
        transport: [
          for (final name in _transportPrograms(transport)) ?program(name),
        ],
    },
    bundled: bundled,
  );
}

String? _which(String name, {required Map<String, String> environment}) {
  final dirs = [
    ...(environment['PATH'] ?? '').split(':').where((d) => d.isNotEmpty),
    // Debian and Ubuntu put tor in /usr/sbin, which a user's PATH leaves out.
    '/usr/local/sbin', '/usr/sbin', '/sbin',
  ];
  for (final dir in dirs) {
    final candidate = File('$dir/$name');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

/// [ManagedTorHost] over this machine: tor's DataDirectory and the
/// transports' state in the app's cache directory, as on Apple, and each
/// launch's control socket in a fresh directory of its own under the
/// system's temporary one, which only this user can list and whose path
/// fits a `sockaddr_un`.
class IoManagedTorHost implements ManagedTorHost {
  IoManagedTorHost({Directory? cacheRoot, Directory? temporaryRoot})
      : _cacheRoot = cacheRoot,
        _temporaryRoot = temporaryRoot;

  final Directory? _cacheRoot;
  final Directory? _temporaryRoot;

  /// `sizeof(sockaddr_un.sun_path)` on Linux, the NUL included.
  static const int _sunPathSize = 108;

  Future<Directory> _cache() async =>
      _cacheRoot ?? await appDirectory(StoreKind.cache);

  @override
  Future<ManagedTorPlaces> prepare() async {
    try {
      final cache = await _cache();
      await cache.create(recursive: true);
      final run =
          _privateDirectory(in_: _temporaryRoot ?? Directory.systemTemp);
      final socket = '${run.path}/control';
      if (utf8.encode(socket).length >= _sunPathSize) {
        await run.delete(recursive: true);
        throw TorRuntimeFailure('The temporary directory\'s path is too long '
            'for a control socket: $socket');
      }
      final torrc = File('${run.path}/torrc');
      await torrc.writeAsString('');
      return ManagedTorPlaces(
        // tor makes it, private, on its first launch.
        dataDirectory: '${cache.path}/tor',
        controlSocket: socket,
        torrc: torrc.path,
      );
    } on IOException catch (e) {
      throw TorRuntimeFailure('Could not prepare a directory for tor: $e');
    }
  }

  @override
  Future<void> release(ManagedTorPlaces places) async {
    try {
      await File(places.torrc).parent.delete(recursive: true);
    } on FileSystemException {
      // Already gone; a temporary directory is the system's to clear.
    }
  }

  @override
  Future<String> transportState() async {
    try {
      final dir = Directory('${(await _cache()).path}/tor_transports');
      await dir.create(recursive: true);
      return dir.path;
    } on IOException catch (e) {
      throw TorRuntimeFailure(
          'Could not prepare a directory for a pluggable transport: $e');
    }
  }

  @override
  Future<ManagedChild> spawn(ManagedLaunch launch) async {
    try {
      return _ProcessChild(await Process.start(
        launch.executable,
        launch.arguments,
        environment: launch.environment,
      ));
    } on ProcessException catch (e) {
      throw TorRuntimeFailure('Could not start ${launch.executable}: '
          '${e.message}');
    }
  }

  @override
  TorControlConnect get connect => openTorControl;

  @override
  TorCookieRead get readCookie => readTorCookie;

  @override
  int get ownPid => pid;
}

typedef _MkdtempC = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> template);
typedef _MkdtempDart = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8> template);

final _mkdtemp = ffi.DynamicLibrary.process()
    .lookupFunction<_MkdtempC, _MkdtempDart>('mkdtemp');

/// A new directory under [in_] that only this user can list, as tor
/// requires of the one its control socket is in. libc's mkdtemp, which
/// makes it 0700 as it creates it: Dart's createTemp leaves it to the
/// umask, 0755 under the usual one, and tor refuses that.
Directory _privateDirectory({required Directory in_}) {
  final template = '${in_.path}/wstorXXXXXX'.toNativeUtf8();
  try {
    final made = _mkdtemp(template);
    if (made == ffi.nullptr) {
      throw FileSystemException('mkdtemp failed', in_.path);
    }
    return Directory(made.toDartString());
  } finally {
    malloc.free(template);
  }
}

/// A started process. Its standard input stays open: a pluggable transport
/// exits when it closes, which is when the app goes.
final class _ProcessChild implements ManagedChild {
  _ProcessChild(this._process) {
    var open = 2;
    void pipe(Stream<List<int>> output) => output
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen(_lines.add, onDone: () {
          if (--open == 0) unawaited(_lines.close());
        });
    pipe(_process.stdout);
    pipe(_process.stderr);
  }

  final Process _process;
  final StreamController<String> _lines = StreamController<String>();

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill({required bool force}) =>
      _process.kill(force ? ProcessSignal.sigkill : ProcessSignal.sigterm);
}
