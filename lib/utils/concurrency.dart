import 'dart:async';

/// Runs tasks one at a time, in the order they were submitted.
///
/// A task's failure reaches its own caller and nobody else: the next task
/// starts once it settles either way. Where the queue lives is the scope of
/// the exclusion, so a `static` queue serialises every instance and an
/// instance field only that instance.
final class SerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() task) {
    final previous = _tail;
    final settled = Completer<void>();
    _tail = settled.future;
    return previous.then((_) => task()).whenComplete(settled.complete);
  }
}

/// Shares one in-flight call per key among concurrent callers.
///
/// A call is forgotten once it settles, before any caller resumes, so the
/// next [run] for the key starts afresh. Every caller that shared a failed
/// call receives its error. Use `()` as the key for a single unkeyed flight.
final class SingleFlight<K, V> {
  final Map<K, Future<V>> _running = {};

  bool isRunning(K key) => _running.containsKey(key);

  Future<V> run(K key, Future<V> Function() call) {
    final running = _running[key];
    if (running != null) return running;
    final flight = Future.sync(call).whenComplete(() {
      _running.remove(key);
    });
    _running[key] = flight;
    return flight;
  }
}
