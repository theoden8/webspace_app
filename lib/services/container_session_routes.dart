// Which route each container's live network session was opened on, and the
// reset that has to finish before a WebView on that container takes another.
//
// On Apple a container's WKWebsiteDataStore opens one network session and
// keeps it for as long as the store lives, which the fork makes the whole
// process. WebKit hands a SOCKS proxy change to that live session in place
// (`NetworkSessionCocoa::setProxyConfigData`), so a connection the container
// opened on its old route can stay pooled and carry the next WebView's
// requests: a site moved from direct to Tor went on loading from the device's
// own address until the app restarted. A reset drops the store, and a store
// made afterwards for the same container starts a session of its own, bound
// to its first WebView's proxy before any connection opens. Cookies and
// storage live on disk under the container and carry over.
//
// Pure Dart; the native reset is injected.

import 'dart:async';

class ContainerSessionRoutes {
  ContainerSessionRoutes({required Future<bool> Function(String) reset})
      : _reset = reset;

  final Future<bool> Function(String containerId) _reset;

  final Map<String, String> _routes = {};
  final Map<String, Future<bool>> _resets = {};

  /// Null when a WebView on [containerId] may bind [route] now: the
  /// container has had no session this process, or its session was opened
  /// on [route]. Otherwise the reset that has to finish first; `true` means
  /// the next [admit] starts a fresh session, `false` that something still
  /// held the old one and it is still there.
  ///
  /// Every WebView on the container has to be gone for a reset to finish,
  /// so the caller builds none while it runs.
  Future<bool>? admit(String containerId, String route) {
    final pending = _resets[containerId];
    if (pending != null) return pending;
    final bound = _routes[containerId];
    if (bound == null || bound == route) {
      _routes[containerId] = route;
      return null;
    }
    final reset = _reset(containerId)
        .catchError((Object _) => false)
        .then((ok) {
      _resets.remove(containerId);
      if (ok) _routes.remove(containerId);
      return ok;
    });
    _resets[containerId] = reset;
    return reset;
  }

  /// The route [containerId]'s session was opened on, if it has one.
  String? routeOf(String containerId) => _routes[containerId];
}
