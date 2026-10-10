import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import '../mock_container_native.dart';
import '../mock_cookie_manager.dart';
import 'walk_runner.dart';

/// What a walk does to the page: a user's taps, the OS, a page's own writes,
/// and changes to the site list. A slot is taken modulo the site count when
/// the action runs, so every subsequence of a walk is a walk and shrinking
/// needs no repair.
sealed class SiteAction {
  const SiteAction();
}

/// A tap on the site at [slot] (`setCurrentIndex`), left running.
final class Tap extends SiteAction {
  const Tap(this.slot);
  final int slot;
  @override
  String toString() => 'Tap($slot)';
}

/// Back to the webspace list (`setCurrentIndex(null)`), left running.
final class GoHome extends SiteAction {
  const GoHome();
  @override
  String toString() => 'GoHome()';
}

/// An OS memory-pressure event, left running.
final class Pressure extends SiteAction {
  const Pressure();
  @override
  String toString() => 'Pressure()';
}

/// Lets the work in flight run [hops] microtask turns, so the next action
/// lands partway through it.
final class Yield extends SiteAction {
  const Yield(this.hops);
  final int hops;
  @override
  String toString() => 'Yield($hops)';
}

/// Waits for everything in flight and checks the settled invariants.
final class Settle extends SiteAction {
  const Settle();
  @override
  String toString() => 'Settle()';
}

/// The page of the site at [slot], if loaded, sets a cookie, as a sign-in
/// does. Settles first: a write that lands inside another site's
/// capture-nuke-restore is lost by design of the shared jar, which the
/// legacy engine accepts.
final class Login extends SiteAction {
  const Login(this.slot);
  final int slot;
  @override
  String toString() => 'Login($slot)';
}

/// A site from the page's host pool, appended (`SiteAdded`).
final class Add extends SiteAction {
  const Add(this.host);
  final int host;
  @override
  String toString() => 'Add($host)';
}

/// The site at [from] moves to [to] (`SitesMoved`).
final class Move extends SiteAction {
  const Move(this.from, {required this.to});
  final int from;
  final int to;
  @override
  String toString() => 'Move($from, to: $to)';
}

/// Noise: a tap on the site already on screen. The site on screen, the
/// loaded set and the jar stay; the site moves last in the loaded order.
final class Retap extends SiteAction {
  const Retap();
  @override
  String toString() => 'Retap()';
}

/// Noise: an edit that changes no field (`SitesEdited`). Nothing moves.
final class Touch extends SiteAction {
  const Touch();
  @override
  String toString() => 'Touch()';
}

/// Noise: the site at [slot] moved onto its own position. Only the
/// activation version moves.
final class StayPut extends SiteAction {
  const StayPut(this.slot);
  final int slot;
  @override
  String toString() => 'StayPut($slot)';
}

/// What a walk's page starts with.
typedef WalkPage = ({
  /// Hosts of the sites loaded at startup, in order.
  List<String> hosts,

  /// Hosts [Add] draws from.
  List<String> pool,

  /// Per-site containers instead of the legacy shared jar.
  bool containers,
});

/// What the walk reads off the page after a step.
final class PageState {
  const PageState({
    required this.current,
    required this.loaded,
    required this.version,
    required this.sites,
    required this.tiers,
    required this.jar,
    required this.stored,
    required this.containers,
    required this.unloads,
  });

  final int? current;

  /// Site ids, least recently used first.
  final List<String> loaded;
  final int version;
  final List<String> sites;
  final List<String> tiers;

  /// `name=value@domain`, sorted.
  final List<String> jar;

  /// Cookie names in secure storage by site id, both sorted.
  final String stored;
  final List<String> containers;
  final List<String> unloads;

  @override
  String toString() =>
      'current=$current loaded=$loaded version=$version '
      'sites=$sites tiers=$tiers jar=$jar stored=$stored '
      'containers=$containers unloads=$unloads';
}

/// One page's activation stack: the real [SiteActivationController] over a
/// real [SiteRuntime], with the real unload and cookie-isolation engines
/// behind it, and fakes only where the platform would be (the cookie jar,
/// secure storage, the container API, nav-state bytes). No webview is built,
/// so what a controller would do to one is out of the walk. Needs
/// `TorService` overridden with an unavailable runtime.
final class ActivationWorld implements WalkWorld<SiteAction> {
  ActivationWorld(this.page) {
    sites
      ..useContainers = page.containers
      ..apply(SitesLoaded([for (final h in page.hosts) _site(h)]));
    final host = _WalkHost();
    activation = SiteActivationController(
      sites,
      host: host,
      residency: _WalkResidency(this),
      navStates: InMemoryWebViewStateStorage(),
      containers: ContainerIsolationEngine(containerNative: native),
      surface: SurfaceRepaintController(host, repaints: false, traceSuffix: ''),
    );
  }

  final WalkPage page;
  final SiteRuntime sites = SiteRuntime();
  final MockCookieManager jar = MockCookieManager();
  final MockCookieSecureStorage stored = MockCookieSecureStorage();
  final MockContainerNative native = MockContainerNative();
  late final CookieIsolationEngine sharedJar = CookieIsolationEngine(
    cookieManager: jar,
    storage: stored,
  );
  late final SiteActivationController activation;

  /// `siteId:reason` for every unload, in order.
  final List<String> unloads = [];

  final List<Future<void>> _inFlight = [];

  /// The cookie names each site's page set, by site id.
  final Map<String, Set<String>> _signedIn = {};
  int _nextSite = 0;
  int _nextCookie = 0;

  WebViewModel _site(String host) => WebViewModel(
    siteId: 'walk-${_nextSite++}',
    initUrl: 'https://$host/',
    name: host,
  );

  @override
  Future<void> apply(SiteAction action) async {
    final n = sites.models.length;
    switch (action) {
      case Tap(:final slot):
        if (n > 0) _inFlight.add(activation.setCurrentIndex(slot % n));
      case GoHome():
        _inFlight.add(activation.setCurrentIndex(null));
      case Pressure():
        _inFlight.add(activation.memoryPressure());
      case Yield(:final hops):
        for (var i = 0; i < hops; i++) {
          await Future<void>.value();
        }
      case Settle():
        await settle();
      case Login(:final slot):
        await settle();
        if (n > 0 && sites.loaded.contains(slot % n)) {
          await _signIn(sites.models[slot % n]);
        }
      case Add(:final host):
        if (page.pool.isNotEmpty) {
          sites.apply(SiteAdded(_site(page.pool[host % page.pool.length])));
        }
      case Move(:final from, :final to):
        if (n > 0) sites.apply(SitesMoved(from % n, to: to % n));
      case Retap():
        await _noise(
          () async {
            if (sites.current case final c?) {
              await activation.setCurrentIndex(c);
            }
          },
          // The restore re-runs: the cookies an unloaded site left in the
          // jar go, the loaded sites' stay; storage and cache tiers are the
          // activation's to refresh.
          expected: ({required before, required after}) => PageState(
            current: before.current,
            loaded: [
              ...before.loaded.where((id) => id != _shownId(before)),
              ?_shownId(before),
            ],
            version: before.version + (before.current == null ? 0 : 1),
            sites: before.sites,
            tiers: after.tiers,
            jar: before.current == null
                ? before.jar
                : [
                    for (final e in before.jar)
                      if (before.loaded.contains(_owner(e))) e,
                  ],
            stored: after.stored,
            containers: before.containers,
            unloads: before.unloads,
          ),
        );
      case Touch():
        await _noise(
          () async => sites.apply(const SitesEdited()),
          expected: ({required before, required after}) => before,
        );
      case StayPut(:final slot):
        await _noise(
          () async {
            if (n > 0) sites.apply(SitesMoved(slot % n, to: slot % n));
          },
          expected: ({required before, required after}) => PageState(
            current: before.current,
            loaded: before.loaded,
            version: before.version + (n > 0 ? 1 : 0),
            sites: before.sites,
            tiers: before.tiers,
            jar: before.jar,
            stored: before.stored,
            containers: before.containers,
            unloads: before.unloads,
          ),
        );
    }
  }

  static String? _shownId(PageState s) =>
      s.current == null ? null : s.sites[s.current!];

  /// The site id a [PageState.jar] entry was set by.
  static String _owner(String entry) =>
      entry.substring(entry.indexOf('=') + 1, entry.lastIndexOf('@'));

  /// Runs [act] between two settled points and requires the page to end
  /// where [expected] says. A field the noise may move is taken from
  /// `after`; every other one is predicted from `before`.
  Future<void> _noise(
    Future<void> Function() act, {
    required PageState Function({
      required PageState before,
      required PageState after,
    })
    expected,
  }) async {
    await settle();
    final before = observe();
    await act();
    await settle();
    final after = observe();
    expect(
      after.toString(),
      expected(before: before, after: after).toString(),
      reason: 'noise changed the page beyond its prediction',
    );
  }

  Future<void> _signIn(WebViewModel site) async {
    final name = 'walk${_nextCookie++}';
    if (page.containers) {
      (native.cookiesByContainer['ws-${site.siteId}'] ??= {})[name] =
          site.siteId;
    } else {
      await jar.setCookie(
        url: Uri.parse(site.initUrl),
        name: name,
        value: site.siteId,
      );
    }
    (_signedIn[site.siteId] ??= {}).add(name);
  }

  @override
  Future<void> settle() async {
    while (_inFlight.isNotEmpty) {
      final pending = [..._inFlight];
      _inFlight.clear();
      await Future.wait(pending);
    }
    // Work the controller leaves unawaited (the quiesce sweep, the renderer
    // probe) finishes on the event queue.
    for (var i = 0; i < 3; i++) {
      await Future<void>(() {});
    }
    _checkSettled();
  }

  void _checkSettled() {
    final n = sites.models.length;
    expect(
      sites.activating,
      isNull,
      reason: 'an activation is still marked in flight once settled',
    );
    expect(
      sites.loaded.where((i) => i < 0 || i >= n),
      isEmpty,
      reason: 'loaded positions ${sites.loaded} name no site among $n',
    );
    if (sites.current case final c?) {
      expect(c >= 0 && c < n, isTrue, reason: 'current $c names no site of $n');
      expect(
        sites.loaded,
        contains(c),
        reason: 'the site on screen is not loaded (Inv_CurrentLoaded)',
      );
    }
    page.containers ? _checkContainers() : _checkSharedJar();
  }

  void _checkSharedJar() {
    final loaded = [for (final i in sites.loaded) sites.models[i]];
    final byBase = <String, String>{};
    for (final s in loaded) {
      final base = getBaseDomain(s.initUrl);
      expect(
        byBase[base],
        isNull,
        reason:
            '${byBase[base]} and ${s.siteId} are loaded together on '
            'one base domain $base (ISO-001)',
      );
      byBase[base] = s.siteId;
      final foreign = jar.all.where(
        (c) =>
            cookieMatchesBaseDomain(c, baseDomain: base) && c.value != s.siteId,
      );
      expect(
        foreign.map(_cookie),
        isEmpty,
        reason:
            'the jar holds another site\'s cookies under loaded '
            '${s.siteId} (Inv_JarMatchesVisible)',
      );
    }
    for (final MapEntry(key: siteId, value: names) in _signedIn.entries) {
      final i = sites.models.indexWhere((m) => m.siteId == siteId);
      final held = sites.loaded.contains(i)
          ? {
              for (final c in jar.all)
                if (c.value == siteId) c.name,
            }
          : {
              for (final c in stored.allStorage[siteId] ?? const <Cookie>[])
                c.name,
            };
      expect(
        held,
        containsAll(names),
        reason:
            '$siteId lost cookies its page set, while '
            '${sites.loaded.contains(i) ? 'loaded (jar)' : 'unloaded (storage)'}',
      );
    }
  }

  void _checkContainers() {
    if (sites.shown case final shown?) {
      expect(
        native.containers,
        contains(shown.siteId),
        reason: 'the site on screen runs without its container',
      );
    }
    for (final MapEntry(key: siteId, value: names) in _signedIn.entries) {
      expect(
        native.cookiesByContainer['ws-$siteId']?.keys ?? const <String>[],
        containsAll(names),
        reason: '$siteId lost cookies from its own container',
      );
    }
  }

  PageState observe() => PageState(
    current: sites.current,
    loaded: [for (final i in sites.loaded) sites.models[i].siteId],
    version: sites.activationVersion,
    sites: [for (final m in sites.models) m.siteId],
    tiers: [for (final m in sites.models) m.lifecycleState.name],
    jar: [for (final c in jar.all) _cookie(c)]..sort(),
    stored: _stored(),
    containers: [...native.containers.keys]..sort(),
    unloads: [...unloads],
  );

  String _stored() {
    final all = stored.allStorage;
    final ids = [...all.keys]..sort();
    return [
      for (final id in ids) '$id:${[for (final c in all[id]!) c.name]..sort()}',
    ].join(' ');
  }

  static String _cookie(Cookie c) => '${c.name}=${c.value}@${c.domain}';

  @override
  String snapshot() => observe().toString();
}

/// The page's answers to the activation controller, minus the widgets:
/// mounted for the whole walk, side channels ignored.
final class _WalkHost implements ActivationHost, SurfaceHost {
  @override
  bool get mounted => true;

  @override
  void rebuild() {}

  @override
  void toast(
    String Function(AppLocalizations loc) message, {
    Duration duration = const Duration(seconds: 4),
    bool floating = false,
  }) {}

  @override
  Future<void> commitSites(SiteSetChange change) => throw UnsupportedError(
    'activation committed $change; the walk models '
    'no site-set change from inside an activation',
  );

  @override
  void forgetTabReturns() {}

  @override
  void enterFullscreen() {}

  @override
  void exitFullscreen() {}

  @override
  Future<void> refreshRoutes({int? activeIndex}) async {}

  @override
  void syncTorExitPin(Set<int> indices) {}

  @override
  Future<void> probeRenderer(
    WebViewModel model, {
    required String trigger,
  }) async {}

  @override
  void backgroundSitesChanged() {}
}

/// The page's `_ResidencyHost` (webspace_page.dart), forwarding to the same
/// [SiteRuntime] methods. Proxies and Tor are outside the walk.
final class _WalkResidency implements ResidencyHost {
  _WalkResidency(this.world);

  final ActivationWorld world;

  @override
  List<WebViewModel> get models => world.sites.models;

  @override
  Set<int> get loadedIndices => world.sites.loaded;

  @override
  CookieIsolationEngine? get sharedJar =>
      world.sites.useContainers ? null : world.sharedJar;

  @override
  Future<void> captureNavState(WebViewModel model) =>
      world.activation.captureStateForRestore(model);

  @override
  void noteUnloaded(WebViewModel model, {required UnloadReason reason}) =>
      world.unloads.add('${model.siteId}:${reason.name}');

  @override
  List<WebViewModel> identities({int? except}) =>
      world.sites.slotIdentities(except: except);

  @override
  SiteRetentionPriority priorityOf(int index) =>
      world.sites.retentionPriority(index);

  @override
  ProxyTopology get proxyTopology => ProxyTopology.of(
    linux: false,
    android: false,
    routerActive: false,
    sharesDefaultSession: (_) => false,
  );

  @override
  bool get torAvailable => false;
}
