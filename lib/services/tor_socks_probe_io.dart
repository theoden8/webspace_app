import 'dart:io';

import 'package:webspace/services/tor_engine.dart';

TorSocksProbe? createTorSocksProbe() => torSocksAnswers;

/// Whether tor's SOCKS listener at [host]:[port] answers a SOCKS5 greeting
/// (TOR-024).
///
/// A greeting rather than a bare connect: a listener the kernel defuncted
/// can still be named by tor and bound to its port, and what matters is
/// whether anything reads from it. No request follows, so no circuit is
/// built and nothing leaves the device.
Future<bool> torSocksAnswers(String host, int port) async {
  const patience = Duration(seconds: 3);
  try {
    final socket = await Socket.connect(host, port, timeout: patience);
    try {
      socket.add(const [5, 1, 0]);
      final reply = await socket.first.timeout(patience);
      return reply.length >= 2 && reply[0] == 5 && reply[1] == 0;
    } finally {
      socket.destroy();
    }
  } catch (_) {
    return false;
  }
}
