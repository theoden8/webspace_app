import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:webspace/services/tor_control.dart';
import 'package:webspace/services/tor_control_link.dart';

TorControlConnect? createTorControlConnect() => openTorControl;

TorCookieRead? createTorCookieRead() => readTorCookie;

const Duration _patience = Duration(seconds: 3);

/// A control channel to the tor at [endpoint] (TOR-026). Throws
/// [TorControlUnreachable] when nothing accepts the connection.
Future<TorControlChannel> openTorControl(TorControlEndpoint endpoint) async {
  try {
    final socket = switch (endpoint) {
      TorControlSocket(:final path) => await Socket.connect(
          InternetAddress(path, type: InternetAddressType.unix), 0,
          timeout: _patience),
      TorControlTcp(:final host, :final port) =>
        await Socket.connect(host, port, timeout: _patience),
    };
    return _SocketControlChannel(socket);
  } on SocketException catch (e) {
    throw TorControlUnreachable(
        'Nothing answers at $endpoint: ${e.osError?.message ?? e.message}');
  }
}

/// The bytes at [path], or null when the app may not read them.
Future<Uint8List?> readTorCookie(String path) async {
  try {
    return await File(path).readAsBytes();
  } on FileSystemException {
    return null;
  }
}

final class _SocketControlChannel implements TorControlChannel {
  _SocketControlChannel(this._socket) {
    _framer = TorControlFramer(onMessage: _onMessage);
    _sub = _socket
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onLine,
            onError: (Object error, StackTrace stack) =>
                _onError(error, stack: stack),
            onDone: () => _finish(const TorControlClosed()));
    // A write to a peer that has gone fails here rather than at write().
    unawaited(_socket.done.then<void>(
      (_) => _finish(const TorControlClosed()),
      onError: (Object error, StackTrace stack) =>
          _onError(error, stack: stack),
    ));
  }

  final Socket _socket;
  late final TorControlFramer _framer;
  late final StreamSubscription<String> _sub;
  final Queue<Completer<TorControlReply>> _pending = Queue();
  final StreamController<TorControlReply> _events =
      StreamController<TorControlReply>.broadcast();
  final Completer<void> _done = Completer<void>();

  @override
  Stream<TorControlReply> get events => _events.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<TorControlReply> send(String command) {
    if (_done.isCompleted) return Future.error(const TorControlClosed());
    final reply = Completer<TorControlReply>();
    _pending.add(reply);
    _socket.write('$command\r\n');
    return reply.future;
  }

  void _onLine(String line) {
    try {
      _framer.addLine(line);
    } on FormatException catch (e) {
      // Not tor's grammar: whatever answers here is not its control port.
      _finish(e);
    }
  }

  void _onMessage(TorControlReply message) {
    if (message.isEvent) {
      if (!_events.isClosed) _events.add(message);
    } else if (_pending.isNotEmpty) {
      _pending.removeFirst().complete(message);
    }
  }

  void _onError(Object error, {required StackTrace stack}) {
    if (error is! SocketException) Error.throwWithStackTrace(error, stack);
    _finish(const TorControlClosed());
  }

  /// Fails every command still waiting with [why] and closes.
  void _finish(Exception why) {
    if (_done.isCompleted) return;
    _done.complete();
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completeError(why);
    }
    unawaited(_events.close());
    unawaited(_sub.cancel());
    _socket.destroy();
  }

  @override
  Future<void> close() async => _finish(const TorControlClosed());
}
