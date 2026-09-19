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
Future<void> relaySockets(
  Socket client,
  StreamSubscription<List<int>> incoming,
  Socket upstream, {
  List<int> pending = const [],
}) async {
  final finished = Completer<void>();
  void finish() {
    if (!finished.isCompleted) finished.complete();
  }

  // Writing to a socket the other end has already dropped throws rather
  // than ending the relay; the half that is still open has to keep going
  // until its own close arrives.
  void forward(Socket to, List<int> data) {
    try {
      to.add(data);
    } on Object {
      to.destroy();
    }
  }

  if (pending.isNotEmpty) forward(upstream, pending);
  incoming
    ..onData((data) => forward(upstream, data))
    ..onError((Object _) {
      upstream.destroy();
      finish();
    })
    ..onDone(() {
      upstream.destroy();
      finish();
    });
  upstream.listen(
    (data) => forward(client, data),
    onError: (Object _) {
      client.destroy();
      finish();
    },
    onDone: () {
      client.destroy();
      finish();
    },
  );
  await finished.future;
}
