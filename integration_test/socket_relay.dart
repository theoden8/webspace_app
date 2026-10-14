import 'dart:async';
import 'dart:io';

/// Pump bytes between a proxy fixture's client and its upstream until one
/// side closes, then tear both down.
///
/// Takes the subscription the fixture already made for its handshake
/// rather than re-subscribing: a `Socket` stream is not a broadcast
/// stream, so a second listen would throw.
///
/// Shared by the SOCKS5 and HTTP CONNECT fixtures because getting it wrong
/// is not visible from the tests they serve. The first version used
/// `subscription.asFuture()`, which *replaces* the subscription's `onDone`
/// and `onError`, so the teardown passed to `listen` never ran: the fixture
/// relayed correctly and leaked every client socket. The integration files
/// never wait for a close, so only a self-test of the fixture could see it.
///
/// A socket's stream ends right after its error, so `onDone` tears down
/// both halves either way; the fixture's stream handles its own errors.
Future<void> relaySockets(
  Socket client, {
  required StreamSubscription<List<int>> incoming,
  required Socket upstream,
  List<int> pending = const [],
}) async {
  final finished = Completer<void>();
  void finish() {
    if (!finished.isCompleted) finished.complete();
  }

  if (pending.isNotEmpty) upstream.add(pending);
  incoming
    ..onData(upstream.add)
    ..onDone(() {
      upstream.destroy();
      finish();
    });
  upstream
      .handleError((Object _) {}, test: (e) => e is SocketException)
      .listen(client.add, onDone: () {
        client.destroy();
        finish();
      });
  await finished.future;
}
