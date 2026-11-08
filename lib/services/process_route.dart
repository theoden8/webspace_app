import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/utils/concurrency.dart';

/// What sends a site's traffic under the process-wide proxy rule: its own
/// webview, the nested screen opened as it, or a wake's headless check.
enum RouteUse { webview, nested, headless }

/// One thing running on the rule, as a site and how it runs.
typedef RouteOccupant = ({RouteUse use, SiteId site});

/// A webview leaving the rule: [quiet] stops what it loads, and [destroyed]
/// completes once its native view can send nothing more (PROXY-008).
abstract interface class LeavingView {
  Future<void> quiet();
  Future<void> destroyed();
}

/// The process-wide proxy rule where one carries a site's own proxy (Android
/// without per-site profiles, `ProxyBinding.processWide`): the route in
/// force and what runs on it (PROXY-008).
/// Every write of the rule is a [claim], one at a time, so a write's relay
/// and override calls are whole before the next begins.
final class ProcessRoute {
  ProcessRoute();

  static final instance = ProcessRoute();

  /// How long a leaving webview holds the rule for its native destroy: a
  /// destroy that never comes (a view the tree kept) would otherwise hold
  /// every later move of the rule.
  static const destroyWait = Duration(seconds: 5);

  /// Completes once [destroyed] has, or after [destroyWait], so [what] goes
  /// on holding its place on the rule only so long.
  static Future<void> untilDestroyed(
    Future<void> destroyed, {
    required String what,
  }) =>
      destroyed.timeout(destroyWait, onTimeout: () {
        LogTag.proxy.warning(
          '$what was not destroyed in ${destroyWait.inSeconds}s; '
          'the process-wide proxy moves anyway (PROXY-008)',
          sensitive: true,
        );
      });

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

  /// What a run a planted mistake broke left mid-claim, dropped, for a test
  /// that goes on to its next world.
  @visibleForTesting
  void abandonClaimsForTest() => _claims.clear();

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

  /// [occupant]'s webview went but may still send: the plugin destroys a
  /// native webview only after it has loaded `about:blank`, and an icon or
  /// page it fetches meanwhile would leave through the next site's proxy.
  /// Its claims are void at once; it leaves the rule once [view] is quiet
  /// and destroyed, in the rule's turn, so a write asked for meanwhile waits
  /// (PROXY-008; Leave, Gone and Vacated in formal/process_route.tla). With
  /// no webview it leaves now.
  Future<void> leave(RouteOccupant occupant, {required LeavingView? view}) {
    if (view == null) {
      release(occupant);
      return Future.value();
    }
    _claims.remove(occupant);
    return vacate([occupant], close: () async {
      await view.quiet();
      LogTag.proxy.debug('$occupant is quiet, waiting for its destroy',
          sensitive: true);
      await untilDestroyed(view.destroyed(), what: '$occupant');
      LogTag.proxy.debug('$occupant left the process-wide proxy',
          sensitive: true);
    });
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
