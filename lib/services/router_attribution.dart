import 'dart:async';

import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_router_engine.dart';

/// Drives the profile [identity] runs in to fetch [url], so the relay can
/// observe which credential that profile presents (PROXY-015).
///
/// A function rather than a concrete type so the service stays testable
/// without a WebView; the app passes `runAttributionProbe`, which opens a
/// short-lived headless WebView in that profile. It fails with the webview
/// plugin's [PlatformException] or [MissingPluginException].
typedef ProxyAttributionProbe =
    Future<void> Function(RouterIdentity identity, {required String url});

/// The launch the checks run beside (PROXY-015).
final class RouterLaunch {
  const RouterLaunch({required this.presents, required this.settled});

  /// The identity the launched site presents, or null when the launch opens
  /// none. The proof checks it first, so the launched webview waits for no
  /// check of its own.
  final Future<RouterIdentity?> presents;

  /// Completes once the launched page has settled or is no longer waited
  /// for. No queued check starts before it, so their probes do not load
  /// beside that page.
  final Future<void> settled;
}

/// Which routing identities this run has shown to present their own proxy
/// credential, and the checks still to run (PROXY-015).
///
/// A profile that shares another's proxy auth cache shows it only to a check
/// that runs after the other's: Chromium then sends the cached credential
/// with the probe before any challenge, and the relay records whose it was.
/// Checks run side by side all start cold and each answers with its own, so
/// [prove] checks two identities one after the other before router mode is
/// trusted, and every later check runs against profiles whose caches are
/// already warm. A webview presents an identity only once it is checked
/// ([attributed]), so the rest are checked after the launch rather than
/// before it, from [queuedAfter] on.
class RouterAttribution {
  RouterAttribution({
    required this.probe,
    required this.observed,
    required this.onFailed,
    Future<void>? queuedAfter,
  }) : _held = queuedAfter != null {
    if (queuedAfter != null) {
      unawaited(queuedAfter.then((_) {
        _held = false;
        _fill();
      }));
    }
  }

  /// How many identities a successful proof checks one after the other.
  static const proofSize = 2;

  /// How many queued identities are checked at once. Each check is a
  /// headless WebView, so a run with many sites must not build one per site
  /// at the same moment.
  static const concurrency = 4;

  final ProxyAttributionProbe probe;

  /// Nonce -> the identity whose credential carried it, as the relay saw.
  final Future<Map<String, String>> Function() observed;

  /// Told the identities found unproven after [prove] held, which must stop
  /// routing: an identity that failed, and the one whose credential its
  /// probe carried.
  final void Function(Set<RouterIdentity> failed) onFailed;

  final _verified = <RouterIdentity>{};
  final _failed = <RouterIdentity>{};
  final _running = <RouterIdentity, Future<bool>>{};
  final _queue = <RouterIdentity>[];
  final _proof = Completer<bool>();
  var _proven = false;
  var _ended = false;
  var _slots = 0;

  /// Queued checks wait while this holds; a webview's own never does.
  bool _held;

  /// Identities a check found unproven this run.
  Set<RouterIdentity> get failed => Set.unmodifiable(_failed);

  /// Check the first [proofSize] of [identities], [first] leading when it is
  /// one of them, one after the other, and queue the rest. False when the
  /// proof failed, and then nothing else is checked.
  Future<bool> prove(
    List<RouterIdentity> identities, {
    RouterIdentity? first,
  }) async {
    assert(!_proof.isCompleted, 'one proof per run');
    final order = [
      if (first != null && identities.contains(first)) first,
      for (final identity in identities)
        if (identity != first) identity,
    ];
    var held = true;
    for (final identity in order.take(proofSize)) {
      if (!await _start(identity)) {
        held = false;
        break;
      }
    }
    _proven = held;
    if (!_proof.isCompleted) _proof.complete(held);
    if (held) enqueue(order.skip(proofSize));
    return held && !_ended;
  }

  /// Stop answering for this run: whatever still waits on the proof is told
  /// no, and nothing more is checked.
  void end() {
    _ended = true;
    _queue.clear();
    if (!_proof.isCompleted) _proof.complete(false);
  }

  /// Queue each of [identities] not checked, running or queued yet; they
  /// are checked once the proof holds.
  void enqueue(Iterable<RouterIdentity> identities) {
    if (_ended) return;
    for (final identity in identities) {
      if (_verified.contains(identity) ||
          _failed.contains(identity) ||
          _running.containsKey(identity) ||
          _queue.contains(identity)) {
        continue;
      }
      _queue.add(identity);
    }
    _fill();
  }

  /// Whether [identity]'s profile presents its own credential, once the
  /// proof holds. Its check runs now when it is still waiting for a slot: a
  /// webview waiting on the answer is a site the user is looking at.
  Future<bool> attributed(RouterIdentity identity) async {
    if (!await _proof.future || _ended) return false;
    // Before verified: a profile another check found carrying its
    // credential was verified once and is shared all the same.
    if (_failed.contains(identity)) return false;
    if (_verified.contains(identity)) return true;
    if (!_running.containsKey(identity)) _queue.remove(identity);
    final checked = await (_running[identity] ?? _start(identity));
    return checked && !_failed.contains(identity);
  }

  void _fill() {
    if (!_proven || _ended || _held) return;
    while (_slots < concurrency && _queue.isNotEmpty) {
      final identity = _queue.removeAt(0);
      _slots++;
      unawaited(
        _start(identity).whenComplete(() {
          _slots--;
          _fill();
        }),
      );
    }
  }

  /// Run [identity]'s check, registered as running before the first await
  /// so a caller asking at once shares it.
  Future<bool> _start(RouterIdentity identity) async {
    final check = _check(identity);
    _running[identity] = check;
    try {
      return await check;
    } finally {
      _running.removeWhere((running, _) => running == identity);
    }
  }

  Future<bool> _check(RouterIdentity identity) async {
    // A probe that never reported (a slow load, a webview that would not
    // start) is asked once more; one that came back carrying another
    // identity's credential is not.
    final seen = await _observe(identity) ?? await _observe(identity);
    if (seen == identity) {
      _verified.add(identity);
      LogTag.proxy.info('Attribution verified for $identity', sensitive: true);
      return true;
    }
    final carried = RouterIdentity.parse(seen);
    _failed.addAll({identity, ?carried});
    LogTag.proxy.error(
      'ATTRIBUTION CHECK FAILED: ${seen == null ? 'no' : 'another'} '
      'credential reached the relay with a probe',
    );
    LogTag.proxy.error(
      'ATTRIBUTION CHECK FAILED for $identity: the relay saw '
      '${seen ?? 'nothing'}. This device did not give that profile its own '
      "proxy credential, so it would route through another site's proxy.",
      sensitive: true,
    );
    if (_proven && !_ended) onFailed(failed);
    return false;
  }

  /// The identity whose credential carried a fresh probe of [identity], or
  /// null when none reached the relay.
  Future<String?> _observe(RouterIdentity identity) async {
    final nonce = ProxyRouterEngine.mintNonce();
    try {
      await probe(identity, url: ProxyRouterEngine.probeUrlFor(nonce));
    } on PlatformException catch (e) {
      return _probeFailed(identity, error: e);
    } on MissingPluginException catch (e) {
      return _probeFailed(identity, error: e);
    }
    return (await observed())[nonce];
  }

  String? _probeFailed(RouterIdentity identity, {required Exception error}) {
    LogTag.proxy.error(
      'Attribution probe for $identity failed to run: $error',
      sensitive: true,
    );
    return null;
  }
}
