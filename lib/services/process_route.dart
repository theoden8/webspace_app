import 'package:flutter/foundation.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/utils/concurrency.dart';

/// What sends a site's traffic under the process-wide proxy rule: its own
/// webview, the nested screen opened as it, or a wake's headless check.
enum RouteUse { webview, nested, headless }

/// One thing running on the rule, as a site and how it runs.
typedef RouteOccupant = ({RouteUse use, SiteId site});

/// The process-wide proxy rule where one covers every webview (Android
/// outside router mode, Linux): the route in force and what runs on it
/// (PROXY-008). Every write of the rule is a [claim], one at a time, so a
/// write's relay and override calls are whole before the next begins.
final class ProcessRoute {
  ProcessRoute();

  static final instance = ProcessRoute();

  final SerialQueue _writes = SerialQueue('process-route');

  ProxyRouteKey? _inForce;
  final Map<RouteOccupant, ProxyRouteKey> _on = {};

  /// Each occupant's latest claim, from when it is made until it is done or
  /// a release voids it: a claim released while it waits for the turn, or
  /// while its write is out, neither moves the rule nor brings its occupant
  /// back on the route it was leaving (formal/process_route.tla).
  final Map<RouteOccupant, Object> _claims = {};

  /// Nothing on the rule and no route named, as at launch; for a test that
  /// runs the production webviews against [instance].
  @visibleForTesting
  void resetForTest() {
    assert(_claims.isEmpty, 'reset while a claim is under way');
    _on.clear();
    _inForce = null;
  }

  /// The route the rule names, null before the first write.
  ProxyRouteKey? get inForce => _inForce;

  /// What runs on the rule, and the route each one needs.
  Map<RouteOccupant, ProxyRouteKey> get occupants => Map.unmodifiable(_on);

  /// Points the rule at [route] for [occupant] by [write], in the rule's
  /// turn. Nothing else may run on another route when the rule moves: its
  /// traffic would leave through this one's proxy. An occupant released
  /// before its turn writes nothing, and one released during its write is
  /// not listed after it.
  Future<void> claim(
    RouteOccupant occupant, {
    required ProxyRouteKey route,
    required Future<void> Function() write,
  }) {
    final ticket = Object();
    _claims[occupant] = ticket;
    bool current() => identical(_claims[occupant], ticket);
    return _writes.run(() async {
      if (!current()) return;
      assert(
        _on.entries.every((e) => e.key == occupant || e.value == route),
        'the process-wide proxy moved under '
        '${_others(occupant, route: route)}, which run on another route '
        '(PROXY-008)',
      );
      _on.remove(occupant);
      try {
        await write();
        _inForce = route;
        if (current()) _on[occupant] = route;
      } finally {
        if (current()) _claims.remove(occupant);
      }
    });
  }

  /// [occupant] runs on the route in force without moving it.
  void join(RouteOccupant occupant, {required ProxyRouteKey route}) {
    assert(
      route == _inForce,
      '$occupant joined the process-wide proxy on another route (PROXY-008)',
    );
    _on[occupant] = route;
  }

  /// [occupant] no longer runs: its webview went, its screen closed.
  void release(RouteOccupant occupant) {
    _on.remove(occupant);
    _claims.remove(occupant);
  }

  /// [occupants] leave once [close] has ended them, in the rule's turn: a
  /// write asked for meanwhile waits until they are gone, so the rule never
  /// moves under a page still loading on the old route (NOTIF-016).
  Future<void> vacate(
    Iterable<RouteOccupant> occupants, {
    required Future<void> Function() close,
  }) {
    final leaving = [...occupants];
    return _writes.run(() async {
      try {
        await close();
      } finally {
        leaving.forEach(_on.remove);
      }
    });
  }

  /// Every occupant running as [use] leaves once [close] has ended them,
  /// in the rule's turn: one whose claim was queued before the turn came,
  /// and so ran after the call, leaves with the rest (NOTIF-016).
  Future<void> vacateEvery(
    RouteUse use, {
    required Future<void> Function() close,
  }) => _writes.run(() async {
    try {
      await close();
    } finally {
      _on.removeWhere((occupant, _) => occupant.use == use);
    }
  });

  /// Nothing runs as [use] any more: a wake's checks all closed.
  void releaseEvery(RouteUse use) {
    _on.removeWhere((occupant, _) => occupant.use == use);
    _claims.removeWhere((occupant, _) => occupant.use == use);
  }

  String _others(RouteOccupant occupant, {required ProxyRouteKey route}) => [
    for (final e in _on.entries)
      if (e.key != occupant && e.value != route) '${e.key.use.name} ${e.key.site}',
  ].join(', ');
}
