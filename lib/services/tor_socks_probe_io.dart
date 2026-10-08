import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:webspace/services/external_tor_runtime.dart';
import 'package:webspace/services/tor_engine.dart';

TorSocksProbe? createTorSocksProbe() => torSocksAnswers;

ExternalTorIdentify? createExternalTorIdentify() => identifyTor;

/// Whether tor's SOCKS listener at [host]:[port] answers a SOCKS5 greeting
/// (TOR-024).
///
/// A greeting rather than a bare connect: a listener the kernel defuncted
/// can still be named by tor and bound to its port, and what matters is
/// whether anything reads from it. No request follows, so no circuit is
/// built and nothing leaves the device.
Future<bool> torSocksAnswers(String host, {required int port}) async {
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
  } on SocketException {
    return false;
  } on TimeoutException {
    return false;
  } on StateError {
    // `first` on a stream the listener closed without a byte.
    return false;
  }
}

const String _kTorHttpReply = 'HTTP/1.0 501 Tor is not an HTTP Proxy';

/// Whether the listener at [host]:[port] is tor's SOCKS port (TOR-025).
///
/// A SOCKS greeting cannot tell tor from any other SOCKS5 proxy, and a
/// "Tor" route that is not tor is the one thing this must never claim. tor
/// answers an HTTP request on its SOCKS port with a fixed refusal (C tor's
/// `SOCKS_PROXY_IS_NOT_AN_HTTP_PROXY_MSG`, Arti's `WRONG_PROTOCOL_PAYLOAD`),
/// and nothing leaves the device to get it. The price is one warning in
/// that tor's log per check.
Future<ExternalTorAnswer> identifyTor(String host, {required int port}) async {
  const patience = Duration(seconds: 3);
  final Socket socket;
  try {
    socket = await Socket.connect(host, port, timeout: patience);
  } on SocketException {
    return ExternalTorAnswer.unreachable;
  }
  final received = <int>[];
  try {
    socket.add(ascii.encode('GET / HTTP/1.0\r\n\r\n'));
    await for (final chunk in socket.timeout(patience)) {
      received.addAll(chunk);
      if (received.length >= _kTorHttpReply.length) break;
    }
  } on SocketException {
    // A reset still leaves whatever arrived to judge.
  } on TimeoutException {
    // So does a listener that goes quiet.
  } finally {
    socket.destroy();
  }
  return latin1.decode(received).startsWith(_kTorHttpReply)
      ? ExternalTorAnswer.tor
      : ExternalTorAnswer.notTor;
}
