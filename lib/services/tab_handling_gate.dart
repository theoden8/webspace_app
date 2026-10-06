/// The re-entrancy guard the tab handlers share (UI race conditions), plus
/// one piece of work that may be asked for while it is held.
///
/// Every tab handler awaits a capture or a disk read before it mutates a tab
/// list, so a second handler entering in that window would capture the wrong
/// tab's back stack or bind the wrong one. Work that has to touch the same
/// lists but arrives from elsewhere (a routing switch flipped in a site's
/// settings, LIR-034) cannot simply be dropped while a handler runs, so it
/// waits: asked for while busy, it runs once after the holder lets go,
/// however many times it was asked for. Work that must happen, in order with
/// what its caller does next (closing a deleted site's hosted tabs before the
/// delete), waits for [idle] and takes the gate itself.
library;

import 'dart:async';

class TabHandlingGate {
  TabHandlingGate(this._schedule);

  /// How deferred work is run once the gate is released: a microtask in the
  /// app, so it never runs inside the releasing handler's `finally`.
  final void Function(void Function() run) _schedule;

  bool _busy = false;
  void Function()? _deferred;
  Completer<void>? _idle;

  bool get busy => _busy;

  set busy(bool value) {
    _busy = value;
    if (value) return;
    final waiting = _idle;
    _idle = null;
    waiting?.complete();
    final task = _deferred;
    if (task == null) return;
    _deferred = null;
    _schedule(task);
  }

  /// Whether work is waiting for the gate.
  bool get hasDeferred => _deferred != null;

  /// Remember [task] for when the gate is released. A later request replaces
  /// an earlier one: the work is idempotent, so running the latest once is
  /// running all of them.
  void deferUntilIdle(void Function() task) => _deferred = task;

  /// Completes when the gate is next released, or now when it is free.
  /// Another waiter may take it first, so a caller checks [busy] again.
  Future<void> idle() =>
      _busy ? (_idle ??= Completer<void>()).future : Future<void>.value();
}
