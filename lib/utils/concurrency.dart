import 'dart:async';

const _heldKey = #concurrencyHeld;

/// A queue or a flight the running code is inside, and what it was inside
/// when it got there. A task's hold ends with the task, so work it left
/// running holds nothing.
final class _Hold {
  _Hold(
    this.owner, {
    required this.name,
    required this.flight,
    required this.key,
    required this.outer,
  });

  final Object owner;
  final String name;

  /// A [SingleFlight] call for [key], not a lock.
  final bool flight;
  final Object? key;
  final _Hold? outer;
  bool active = true;

  Iterable<_Hold> get chain sync* {
    for (_Hold? h = this; h != null; h = h.outer) {
      if (h.active) yield h;
    }
  }
}

Iterable<_Hold> _held() => (Zone.current[_heldKey] as _Hold?)?.chain ?? const [];

/// The deadlock check every primitive that makes a caller wait shares.
///
/// A holder that waits on what it holds never ends, since what it waits for
/// comes after it: waiting on an owner the running code holds is an assert.
/// Across owners, two holders that each hold one and wait on the other never
/// end either. Each owner has a lock class, its name; every wait taken while
/// holding another records that order, and waiting in an order the reverse of
/// one already recorded, directly or through other classes, is an assert,
/// whether or not the two ever met (the lock-order check Linux calls
/// lockdep). A hold lasts as long as the holder's work, so work it left
/// running holds nothing once it ends.
abstract final class LockOrder {
  /// `_order[a]` holds each class waited on while `a` was held.
  static final Map<String, Set<String>> _order = {};

  /// Whether the running code may wait on [owner] of class [name]; true, or
  /// an assert. For use inside `assert`.
  static bool mayWait(Object owner, {required String name}) {
    final held = _held().where((h) => !h.flight).toList();
    assert(!held.any((h) => identical(h.owner, owner)),
        'the "$name" holder waits on it, behind itself: it never ends');
    for (final h in held) {
      if (h.name == name) continue;
      assert(!_reaches(name, to: h.name),
          '"$name" is waited on while holding "${h.name}", the reverse of an '
          'order already seen: two holders of one each can wait on each other '
          'forever');
      (_order[h.name] ??= {}).add(name);
    }
    return true;
  }

  /// Whether the running code holds [owner].
  static bool holds(Object owner) =>
      _held().any((h) => !h.flight && identical(h.owner, owner));

  /// Runs [body] holding [owner] of class [name] until it ends.
  static Future<T> holding<T>(
    Object owner, {
    required String name,
    required Future<T> Function() body,
  }) {
    final hold = _Hold(
      owner,
      name: name,
      flight: false,
      key: null,
      outer: Zone.current[_heldKey] as _Hold?,
    );
    return runZoned(
      () => Future.sync(body),
      zoneValues: {_heldKey: hold},
    ).whenComplete(() => hold.active = false);
  }

  /// Whether [to] was ever waited on, directly or through other classes,
  /// while [from] was held.
  static bool _reaches(String from, {required String to}) {
    final seen = <String>{};
    final todo = [from];
    while (todo.isNotEmpty) {
      final next = _order[todo.removeLast()] ?? const <String>{};
      for (final n in next) {
        if (n == to) return true;
        if (seen.add(n)) todo.add(n);
      }
    }
    return false;
  }
}

/// Runs tasks one at a time, in the order they were submitted.
///
/// A task's failure reaches its own caller and nobody else: the next task
/// starts once it settles either way. Where the queue lives is the scope of
/// the exclusion, so a `static` queue serialises every instance and an
/// instance field only that instance.
///
/// It is not re-entrant: a task that waits on its own queue never ends
/// ([LockOrder]). Work a task needs done inside its own turn is a function the
/// task calls, which asserts [isHeld]; [enqueue] puts work behind the running
/// task without waiting for it.
final class SerialQueue {
  SerialQueue(this.name);

  /// The lock class, for the order and the messages.
  final String name;

  /// The last task's settling, or null once the queue is idle: an idle
  /// queue holds no future, so none outlives the zone that made it.
  Future<void>? _tail;

  /// Whether the running code is one of this queue's tasks.
  bool get isHeld => LockOrder.holds(this);

  Future<T> run<T>(Future<T> Function() task) {
    assert(LockOrder.mayWait(this, name: name));
    return _submit(task);
  }

  /// Queues [task] behind whatever runs now without waiting for it, from
  /// inside one of the queue's own tasks too. Its failure reaches the zone,
  /// as an unawaited future's does.
  void enqueue(Future<void> Function() task) => unawaited(_submit(task));

  Future<T> _submit<T>(Future<T> Function() task) {
    final previous = _tail ?? Future<void>.value();
    final settled = Completer<void>();
    final mine = _tail = settled.future;
    return previous
        .then((_) => LockOrder.holding(this, name: name, body: task))
        .whenComplete(() {
          settled.complete();
          if (identical(_tail, mine)) _tail = null;
        });
  }
}

/// Shares one in-flight call per key among concurrent callers.
///
/// A call is forgotten once it settles, before any caller resumes, so the
/// next [run] for the key starts afresh. Every caller that shared a failed
/// call receives its error. Use `()` as the key for a single unkeyed flight.
/// A call that waits on its own key's flight waits on itself; that is an
/// assert.
final class SingleFlight<K, V> {
  final Map<K, Future<V>> _running = {};

  bool isRunning(K key) => _running.containsKey(key);

  Future<V> run(K key, {required Future<V> Function() call}) {
    assert(
      !_held().any((h) => h.flight && identical(h.owner, this) && h.key == key),
      'a flight for $key waits on itself: it never ends',
    );
    final running = _running[key];
    if (running != null) return running;
    final hold = _Hold(
      this,
      name: 'flight',
      flight: true,
      key: key,
      outer: Zone.current[_heldKey] as _Hold?,
    );
    final flight = runZoned(
      () => Future.sync(call),
      zoneValues: {_heldKey: hold},
    ).whenComplete(() {
      hold.active = false;
      // The flight is dropped from the table, not started.
      // ignore: discarded_futures
      _running.remove(key);
    });
    _running[key] = flight;
    return flight;
  }
}
