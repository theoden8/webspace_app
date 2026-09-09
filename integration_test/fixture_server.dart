import 'dart:async';

/// Subscribe to a test fixture's socket stream, tolerating its errors.
///
/// The error handler is the whole point. A fixture server's socket can
/// error at any time -- most often as the harness tears it down -- and an
/// unhandled error on that stream is an uncaught async error, which
/// `flutter_test` reports against whichever test finished last. So a
/// socket hiccup in the page fixture fails an unrelated assertion, under
/// the confusing banner "this test failed after it had already
/// completed". It cost a macOS CI cycle once (`page_zoom_test`, errno 22
/// out of `_HttpServer.listen`, in a run whose real subject was
/// elsewhere).
///
/// The fixture serves pages so a test has something to load; nothing here
/// asserts on its socket. A test that does need to see a server error
/// should subscribe itself rather than reach for this.
StreamSubscription<T> listenFixture<T>(
  Stream<T> source,
  void Function(T event) onEvent,
) =>
    source.listen(onEvent, onError: (Object _) {});
