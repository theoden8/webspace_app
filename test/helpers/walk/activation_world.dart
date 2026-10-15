import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/controllers/activation_host.dart';
import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/site_route.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/site_deletion.dart';
import 'package:webspace/controllers/site_set_commit.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/controllers/webspaces_controller.dart';
import 'package:webspace/formal_model/models.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_crypto.dart';
import 'package:webspace/services/archive_storage.dart';
import 'package:webspace/services/background_wake_engine.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/container_names.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/controllers/startup_controller.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/link_intent_dispatch_engine.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/nav_capture.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/proxy_refused.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/proxy_conflict_engine.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import '../fake_outbound.dart';
import '../fake_webview_controller.dart';
import '../mock_container_native.dart';
import '../mock_cookie_manager.dart';
import '../mock_secure_storage.dart';
import '../paced_state_storage.dart';
import 'schedules.dart';
import 'step_traces.dart';
import '../model_fixture.dart';

/// What a walk does to the page: a user's taps, the OS, a page's own writes,
/// and changes to the site list. A slot is taken modulo the site count when
/// the action runs, so every subsequence of a walk is a walk and shrinking
/// needs no repair.
sealed class SiteAction {
  const SiteAction();
}

/// A tap on the site at [slot] (`activate`), left running.
final class Tap extends SiteAction {
  const Tap(this.slot);
  final int slot;
  @override
  String toString() => 'Tap($slot)';
}

/// The site at [slot] loaded off screen (`preload`), as a notification
/// site is at launch, left running.
final class Preload extends SiteAction {
  const Preload(this.slot);
  final int slot;
  @override
  String toString() => 'Preload($slot)';
}

/// A link opens the site at [slot] nested (`openNested`), left running
/// until a reply pops its screen.
final class OpenNested extends SiteAction {
  const OpenNested(this.slot);
  final int slot;
  @override
  String toString() => 'OpenNested($slot)';
}

/// Back to the webspace list (`activate(null)`), left running.
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

/// The OS wakes the app off screen to check its notification sites
/// (`BackgroundWakeEngine.wake`), left running.
final class Wake extends SiteAction {
  const Wake();
  @override
  String toString() => 'Wake()';
}

/// The app leaves the screen.
final class Background extends SiteAction {
  const Background();
  @override
  String toString() => 'Background()';
}

/// The app comes back to the screen; a wake's checks close at once.
final class Foreground extends SiteAction {
  const Foreground();
  @override
  String toString() => 'Foreground()';
}

/// The user downloads the DNS level at [pick] of the page's as the
/// app-wide one (`DnsBlockService.downloadList`), left running.
final class DnsDownload extends SiteAction {
  const DnsDownload(this.pick);
  final int pick;
  @override
  String toString() => 'DnsDownload($pick)';
}

/// A site's level asks for the list at [pick] of the page's
/// (`downloadLevel`), left running.
final class DnsAddLevel extends SiteAction {
  const DnsAddLevel(this.pick);
  final int pick;
  @override
  String toString() => 'DnsAddLevel($pick)';
}

/// The user turns DNS blocking off (`downloadList(0)`), left running.
final class DnsClear extends SiteAction {
  const DnsClear();
  @override
  String toString() => 'DnsClear()';
}

/// The webspace at [pick] of the page's (`All` first) is chosen on the list
/// (`WebspacesController.select`), left running; dropped while a site is
/// on screen, where the list is not.
final class SwitchWebspace extends SiteAction {
  const SwitchWebspace(this.pick);
  final int pick;
  @override
  String toString() => 'SwitchWebspace($pick)';
}

/// The site at [slot] moves into a new archive (`ArchiveController.moveIn`),
/// in a setup: the script starts with the archive open (`Archive`).
final class ArchiveSite extends SiteAction {
  const ArchiveSite(this.slot);
  final int slot;
  @override
  String toString() => 'ArchiveSite($slot)';
}

/// The open archive is closed (`ArchiveController.close`).
final class CloseArchive extends SiteAction {
  const CloseArchive();
  @override
  String toString() => 'CloseArchive()';
}

/// The user deletes site 1, the page's first (`DeleteSite`, `DeleteOne`).
final class Delete extends SiteAction {
  const Delete();
  @override
  String toString() => 'Delete()';
}

/// Site 1's routing switch flips and its settings close (LIR-034): the
/// commit reconciles its link tab, which runs as site 3 with routing on
/// and as site 1 off (`reconcileLinkTabs`).
final class Reroute extends SiteAction {
  const Reroute();
  @override
  String toString() => 'Reroute()';
}

/// The platform answers the call at [pick] among those waiting, taken
/// modulo their number, so the next action lands when the work in flight
/// has moved on by one reply.
final class Reply extends SiteAction {
  const Reply(this.pick);
  final int pick;
  @override
  String toString() => 'Reply($pick)';
}

/// Answers every waiting call oldest first until nothing is in flight, and
/// checks the settled invariants.
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

/// What the platform fails at once a setup step says so: a read, a write
/// or the clear of the shared jar (ISO-014), the process-wide proxy rule
/// (PROXY-008), the network (WEBSPACE-013).
enum Fault { jarRead, jarWrite, jarClear, proxy, network }

/// From here on the platform fails at [fault]: a setup step, before the
/// script the trace records, whose world then lets the model's step fail
/// there too (`JarRefuses`, `ProxyRefused`, `Online`).
final class Fails extends SiteAction {
  const Fails(this.fault);
  final Fault fault;
  @override
  String toString() => 'Fails(Fault.${fault.name})';
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

/// Noise: the site at [slot] moved onto its own position, which changes
/// nothing, not even the activation version (BUG-029).
final class StayPut extends SiteAction {
  const StayPut(this.slot);
  final int slot;
  @override
  String toString() => 'StayPut($slot)';
}

/// The site at [slot] shows its tab at [tab] (`TabsController.openTab`),
/// the tab taken modulo the site's tab count, left running.
final class OpenTab extends SiteAction {
  const OpenTab(this.slot, {required this.tab});
  final int slot;
  final int tab;
  @override
  String toString() => 'OpenTab($slot, tab: $tab)';
}

/// A new tab in the site at [slot] (`newTab`), left running.
final class NewTab extends SiteAction {
  const NewTab(this.slot);
  final int slot;
  @override
  String toString() => 'NewTab($slot)';
}

/// The site at [slot] closes its tab at [tab] (`closeTab`), the tab taken
/// modulo the site's tab count, left running.
final class CloseTab extends SiteAction {
  const CloseTab(this.slot, {required this.tab});
  final int slot;
  final int tab;
  @override
  String toString() => 'CloseTab($slot, tab: $tab)';
}

/// The site at [slot] copies its active tab (`duplicateTab`), left running.
final class DuplicateTab extends SiteAction {
  const DuplicateTab(this.slot);
  final int slot;
  @override
  String toString() => 'DuplicateTab($slot)';
}

/// What a walk's page starts with.
typedef WalkPage = ({
  /// Hosts of the sites loaded at startup, in order.
  List<String> hosts,

  /// Hosts [Add] draws from.
  List<String> pool,

  /// Per-site containers instead of the legacy shared jar.
  bool containers,

  /// Hosts of the sites that are incognito: their session lives in the jar
  /// while loaded and nowhere once unloaded (INC-001).
  List<String> incognito,
});

/// How the host scopes a proxy: per session (iOS, macOS), one
/// process-global rule (Android, Linux), or the router (PROXY-013), under
/// which only the sites sharing the default session contend.
enum WalkScope { session, global, router }

/// Each site's proxy host by position, null for direct, and its Tor exit
/// country, a site with one routing through Tor instead; the [scope], and
/// under the router the positions that share the default session.
typedef WalkProxies = ({
  List<String?> routes,
  List<String?> exits,
  WalkScope scope,
  List<int> defaultSession,
});

/// The DNS level each of the page's first sites asks for, null to follow
/// the app-wide one and `kDnsLevelOff` for off, and the levels a download
/// picks from (`SiteLevel`, `DnsLevels`).
typedef WalkDns = ({List<int?> siteLevels, List<int> levels});

/// What the last session left, for a world that starts at launch: the
/// sites whose storage holds a session, and the sites whose cookies are
/// still in the shared jar, by position. Nothing is loaded yet, and on the
/// shared jar its clear is queued for the first turn.
typedef WalkLaunch = ({List<int> signedIn, List<int> left});

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

/// One page's activation stack: the real [SiteActivationController] and
/// [TabsController] over a real [SiteRuntime], with the real unload and
/// cookie-isolation engines behind them, and fakes only where the platform
/// would be (the cookie jar, secure storage, the container API, nav-state
/// bytes, and a webview's controller for each loaded site, built when its
/// activation ends or its tab is rebound, as the next frame would). Every
/// platform call waits on [gate], which a schedule holds and a walk does
/// not; of a webview's, the cache clear and the state capture. A webview's
/// back stack is the id of the tab whose history it is, so a file or a
/// webview holding another tab's history shows. With [tabbed] the first
/// site starts with a second tab. Needs `TorService` overridden with an
/// unavailable runtime.
final class ActivationWorld implements ScheduledWorld<SiteAction> {
  /// Each renderer probe and surface nudge the page was asked for, in order.
  final List<String> recoveries = [];

  ActivationWorld(
    this.page, {
    this.launch,
    this.tabbed = false,
    this.proxies,
    this.caps = kResidencyCaps,
    this.nestedOpens = false,
    this.wakes = false,
    this.dns,
    this.spaces,
    this.archived = false,
    this.deletes = false,
    this.rehosts = false,
    this.declared,
  }) {
    assert(!archived || page.containers, 'an archive needs containers');
    assert(!deletes || page.containers, 'the delete world runs on containers');
    assert(
      !rehosts || (page.containers && proxies?.scope == WalkScope.global),
      'a link tab runs as another site only with containers, and its '
      'identity reroutes only under one process-wide proxy (LIR-024)',
    );
    // The sites the page proxies resolve against the app-wide proxy, direct.
    if (proxies != null) GlobalOutboundProxy.resetForTest();
    if (launch case (:final signedIn, :final left)?) {
      for (final i in signedIn) {
        final name = 'stored$i';
        stored.seed('walk-$i', cookies: [_cookieOf(i, name: name)]);
        (_signedIn['walk-$i'] ??= {}).add(name);
      }
      for (final i in left) {
        jar.seed(_cookieOf(i, name: 'left$i'));
      }
    }
    jar.pace = gate.pace;
    stored.pace = gate.pace;
    native.pace = gate.pace;
    navStates
      ..pace = gate.pace
      ..onSave = _onSave;
    sites
      ..isolation = page.containers
          ? Containers(engine: ContainerIsolationEngine(containerNative: native))
          : SharedJar(sharedJar)
      ..applied(SitesLoaded([for (final h in page.hosts) _site(h)]));
    if (tabbed && sites.models.isNotEmpty) {
      final first = sites.models.first;
      first.setTabs([...first.tabs, SiteTab(url: '${first.initUrl}two')]);
    }
    if (rehosts) {
      // As the page does: a hosted tab finds the site it runs as.
      WebViewModel.siteLookup = sites.byId;
      final first = sites.models.first;
      final link = '${sites.models.last.initUrl}link';
      first.setTabs([
        ...first.tabs,
        SiteTab(url: link, homeUrl: link, openerSiteId: first.siteId),
      ]);
    }
    if (spaces case final named?) {
      SharedPreferences.setMockInitialValues({});
      sites
        ..webspaces.add(Webspace(id: WebspaceId.all, name: 'All'))
        ..webspaces.addAll([
          for (final (i, members) in named.indexed)
            Webspace(
              name: 'walk-$i',
              siteIds: [for (final p in members) sites.models[p].siteId],
            ),
        ])
        ..selectedWebspaceId = WebspaceId.all
        ..resolveWebspaceIndices();
    }
    if (dns != null) {
      SharedPreferences.setMockInitialValues({});
      DnsBlockService.instance
        ..resetForTest()
        ..store = MemoryFileStore();
      outboundHttp = FakeOutbound(responder: _servedList);
    }
    gate.onCall = _onCall;
    ActivationSteps.sink = _onStep;
    segments = (state: _frameState, changed: _onChanged);
    final host = _WalkHost(this);
    activation = SiteActivationController(
      sites,
      host: host,
      residency: _WalkResidency(this),
      navStates: navStates,
      surface: _WalkSurface(host, world: this),
    );
    tabs = TabsController(
      sites,
      host: _WalkTabsHost(this),
      navStates: navStates,
      residency: _WalkResidency(this),
    );
    webspaces = WebspacesController(
      sites,
      host: host,
      prompts: const _WalkWebspacePrompts(),
      shell: ShellStore(sites),
      activation: activation,
    );
    // The model numbers the launch clear's step 0: it is no input's flow.
    if (launch != null && !page.containers) {
      inFlow(
        flow: -1,
        () => _track(sharedJar.clearUnloaded(loaded: sites.loaded)),
      );
    }
  }

  final WalkPage page;

  /// Per-site proxies and Tor exits (PROXY-008), or none.
  final WalkProxies? proxies;

  /// How many sites may stay loaded and resident; a sweep runs ones its
  /// three sites reach.
  final ResidencyCaps caps;

  /// Links may open any site nested (`Linked`).
  final bool nestedOpens;

  /// Every site's notifications are on and the app goes to the background,
  /// where the OS wakes it (`Notified`, `Waking`).
  final bool wakes;

  /// The named webspaces by the positions of their sites, beside `All`, or
  /// none; a switch to one is `SwitchWebspace` (`Away`).
  final List<List<int>>? spaces;

  /// A setup may move a site into an archive ([ArchiveSite]) and the script
  /// close it ([CloseArchive]); a frame mounts each loaded site's webview,
  /// which binds its container (`Archive`, `Frame`).
  final bool archived;

  /// The script may delete site 1 ([Delete]); a frame mounts each loaded
  /// site's webview, which binds its container (`Deletable`, `Frame`).
  final bool deletes;

  /// Site 1 starts with a second tab, a link of its own into site 3's
  /// domain, which [Reroute] runs as site 3 or as site 1.
  final bool rehosts;

  /// The tables the frame check holds each step's changes to, the code's
  /// unless a planted mistake's ([frameMistake]).
  final Tables? declared;

  /// Whether the world follows the webviews and containers a close or a
  /// delete takes away (`Boxed`).
  bool get _boxed => archived || deletes;

  late final SiteDeletion deletion = SiteDeletion(
    sites,
    host: _WalkDeletionHost(this),
  );

  /// The site a delete takes, once one has.
  WebViewModel? _deleted;

  /// The sites whose containers the model follows (`Boxed`).
  Iterable<WebViewModel> get _followed => {
    ..._archived,
    if (deletes) ...{
      ?_deleted,
      for (final m in sites.models)
        if (_siteNumber(m) == 1) m,
    },
  };

  final MockFlutterSecureStorage _keychain = MockFlutterSecureStorage();
  late final ArchiveController archives = ArchiveController(
    sites,
    host: _WalkArchiveHost(this),
    prompts: const _WalkArchivePrompts(),
    cookieStore: stored,
    proxyPasswords: ProxyPasswordSecureStorage(secureStorage: _keychain),
    navStates: navStates,
    archive: Archive(
      storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()),
      deriveKey: _deriveArchiveKey,
    ),
  );

  /// The sites an archive took, by the order they went in.
  final List<WebViewModel> _archived = [];

  /// The sites whose webview is mounted, and the container each binds.
  final Map<WebViewModel, ContainerKey> _mounted = {};

  /// The list as it stood when a close or a delete took sites off it: the
  /// model keeps their rows, and moves none once one has gone.
  List<int>? _rowsAtDrop;

  /// The model's rows: the list, or as it stood at a drop.
  List<int> get _rows =>
      _rowsAtDrop ?? [for (final m in sites.models) _siteNumber(m)];

  /// A frame's mounts and unmounts: a loaded site's webview mounts and binds
  /// its container, one no longer loaded unmounts (`Frame`).
  void _frameMounts() {
    // A reroute lets go of the slot's webview; the next frame builds it as
    // the site it now runs as.
    if (_boxed || rehosts) _buildWebViews();
    if (!_boxed) return;
    inFlow(flow: _frameFlow, () {
      for (final m in {..._bySite, ..._mounted.keys}) {
        final live = sites.loaded.contains(m);
        final bound = _mounted[m];
        if (live && bound == m.containerKey) continue;
        if (!live && bound == null) continue;
        if (bound != null) native.unbind(bound);
        if (live) {
          // A webview let go and built again on another container (a move
          // into an archive) remounts: the model starts after that, so only
          // a first mount or an unmount is a step of it.
          _mounted[m] = m.containerKey;
          native.bind(m.containerKey);
          if (bound != null) continue;
        } else {
          _mounted.remove(m);
        }
        ActivationSteps.mark(ActivationStep.frame, site: m);
      }
    });
  }

  /// The frame a close waits for (`endOfFrame`): the webviews of sites no
  /// longer loaded unmount, which is all the close's step writes.
  void _unmountGone() {
    for (final MapEntry(key: m, value: key) in [..._mounted.entries]) {
      if (sites.loaded.contains(m)) continue;
      _mounted.remove(m);
      native.unbind(key);
    }
  }

  /// The sites' DNS levels and the levels a download picks, or no DNS: the
  /// lists come from a mirror whose answer waits on [gate], and a frame
  /// tells each loaded site's view its level.
  final WalkDns? dns;

  /// A mirror's answer for one of the page's levels: a list long enough to
  /// pass as one (`looksLikeDomainList`), after the gate lets it through.
  Future<http.Response> _servedList(http.Request request) async {
    await gate.pace(PlatformCall.dnsFetch);
    for (final level in dns!.levels) {
      if (dnsMirrorUrlsForLevel(level).contains(request.url.toString())) {
        return http.Response(
          [for (var i = 0; i < 1200; i++) 'walk$level-$i.example'].join('\n'),
          200,
        );
      }
    }
    return http.Response('not found', 404);
  }

  /// The flow a frame's view builds and drops run as: none of the script's,
  /// and not the launch clear's.
  static const _frameFlow = -2;

  /// The frame between two events, as far as DNS sees it: a loaded site's
  /// webview attaches at its site's level, and one whose site has gone is
  /// dropped (`ViewBuilt`, `ViewGone`).
  void _frameViews() {
    final levels = dns?.siteLevels;
    if (levels == null) return;
    final views = DnsBlockService.instance.views;
    inFlow(flow: _frameFlow, () {
      for (final m in _bySite) {
        final live = sites.loaded.contains(m);
        final attached = views.told.containsKey(m.siteId);
        if (live && !attached) {
          views.built(
            m,
            site: m.siteId,
            siteLevel: levels[_siteNumber(m) - 1],
            localCdn: false,
            contentBlock: false,
          );
          ActivationSteps.mark(ActivationStep.viewBuilt, site: m);
        } else if (!live && attached) {
          views.gone(m);
          ActivationSteps.mark(ActivationStep.viewGone, site: m);
        }
      }
    });
  }

  late final BackgroundWakeEngine<WebViewModel> wakeEngine =
      BackgroundWakeEngine();
  late final _WalkWake _wake = _WalkWake(this);

  /// A Tor runtime exists, whose one exit an activation repoints, when a
  /// site routes through Tor.
  bool get _torRuntime => proxies?.exits.any((e) => e != null) ?? false;

  /// The sites in the router's default session, by number.
  List<int> get _sharingDefault => [
    for (final p in proxies?.defaultSession ?? const <int>[]) p + 1,
  ];

  /// Whether [m] shares the router's default session: by its first
  /// position, whatever row it moved to.
  bool _inDefaultSession(WebViewModel m) =>
      proxies?.defaultSession.contains(_siteNumber(m) - 1) ?? false;
  final WalkLaunch? launch;
  final bool tabbed;

  /// The cookie the site at [i] of the page's first list set as [name].
  Cookie _cookieOf(int i, {required String name}) => Cookie(
    name: name,
    value: 'walk-$i',
    domain: page.hosts[i],
    path: '/',
  );
  final SiteRuntime sites = SiteRuntime();
  final MockCookieManager jar = MockCookieManager();
  final MockCookieSecureStorage stored = MockCookieSecureStorage();
  final MockContainerNative native = MockContainerNative();
  final PacedStateStorage navStates = PacedStateStorage();
  @override
  final Gate gate = Gate();
  late final CookieIsolationEngine sharedJar = CookieIsolationEngine(
    cookieManager: jar,
    storage: stored,
  );
  late final SiteActivationController activation;
  late final TabsController tabs;
  late final WebspacesController webspaces;

  /// The action each flow of the script runs, by flow.
  final Map<int?, SiteAction> _flowActions = {};

  /// A copy's state key to the tab whose history the duplicate wrote there.
  final Map<String, String> _copyOf = {};

  /// `siteId:reason` for every unload, in order.
  final List<String> unloads = [];

  final List<Future<void>> _inFlight = [];
  int _started = 0;
  int _finished = 0;

  /// The cookie names each site's page set, by site id.
  final Map<String, Set<String>> _signedIn = {};
  int _nextSite = 0;
  int _nextCookie = 0;

  /// The site the page last drew, at its last rebuild.
  WebViewModel? _drawn;

  int _nextFlow = 0;

  /// The platform calls each flow made since the step it last marked.
  final Map<int?, List<PlatformCall>> _unmarked = {};

  /// The script's steps, when a run asked for them (`StepTraces`), under
  /// the model's configuration as the script began: a close takes sites off
  /// the list the constants count.
  ({
    String config,
    TraceConstants constants,
    Map<String, Object> start,
    List<StepMark> steps,
  })? _recording;
  int _scriptVersion = 0;

  void _onCall(PlatformCall call, {required int? flow}) {
    if (_unmodeled.contains(flow)) return;
    (_unmarked[flow] ??= []).add(call);
  }

  /// Flows the model takes no step of, so neither the replay nor a table's
  /// declarations hold them: a move into an archive, which the model starts
  /// from (`Archive`), a reroute, and a tab input on a site off screen
  /// ([_offScreenTabInput]).
  final Set<int?> _unmodeled = {};

  /// Flows whose activation has committed.
  final Set<int?> _committed = {};

  /// A webview's calls wait on [gate], except the pause an activation sends
  /// every other loaded site after its commit: unawaited, it moves nothing
  /// the model holds, so it answers at once. The target's resume, the one
  /// await past the commit, waits like any other.
  Future<void> _webViewPace(PlatformCall call) =>
      _committed.contains(currentFlow()) && call != PlatformCall.webViewResume
          ? Future<void>.value()
          : gate.pace(call);

  /// A step the code marked: every call its flow made since its last step
  /// must be one this step declares, and the step joins the trace.
  void _onStep(
    ActivationStep step, {
    required StepOutcome outcome,
    required Object? site,
    required TabId? tab,
  }) {
    final flow = currentFlow();
    if (step == ActivationStep.commit) _committed.add(flow);
    // The rebind's rebuild is the frame that builds the webview.
    if (step == ActivationStep.tabRebind) _buildWebViews();
    final calls = _unmarked.remove(flow) ?? const <PlatformCall>[];
    for (final call in calls) {
      if (!step.calls.contains(call)) {
        _violations.add('flow $flow waited on ${call.label}, which '
            '${step.name} does not declare (ActivationStep)');
      }
    }
    // The model takes a step whole: two awaits in one step hide whatever
    // the code checks between them (BUG-036's capture).
    if (calls.length > 1 && step.severalAwaits == null) {
      _violations.add('flow $flow waited on ${calls.length} calls in '
          '${step.name} (${[for (final c in calls) c.label].join(', ')}); a '
          'step is one await, or names why several are safe (severalAwaits)');
    }
    if ((_recording, flow)
        case ((:final steps, config: _, constants: _, start: _)?, final f?)) {
      steps.add((
        action: step.action,
        // The launch clear and the frame are no input's flow; a spawned one
        // is numbered as the model numbers it, the next input.
        flow: f == -1 || f == _frameFlow
            ? 0
            : _modelFlows.putIfAbsent(f, () => _modelFlows.length + 1),
        outcome: outcome.tla,
        // Every mark's site is a model or nothing: the cast is the assert.
        site: switch (site as WebViewModel?) {
          null => 0,
          final m => switch (tab) {
            null => _siteNumber(m),
            final t => _tabNumber(m.siteId, tab: t),
          },
        },
        state: _project(),
      ));
    }
    takeSegment();
    _checkFrame(flow, step: step, outcome: outcome);
  }

  /// The model's variables each flow changed that no step it marked has
  /// taken yet, as the code holds them ([_frameState]).
  final Map<int, Set<ModelVar>> _changed = {};

  /// Each flow's last marked step, and whether it was marked in the
  /// stretch of code running now: what follows it there, before the next
  /// await, is that step's too.
  final Map<int, ({ActivationStep step, StepOutcome outcome})> _lastMark = {};
  final Set<int> _markedHere = {};

  void _onChanged(
    int? flow, {
    required Set<Object> keys,
    required bool closes,
  }) {
    if (flow == null) return;
    final pending = (_changed[flow] ??= {})..addAll(keys.cast<ModelVar>());
    if (!closes) return;
    if (_markedHere.remove(flow)) {
      if (_lastMark[flow] case (:final step, :final outcome)?) {
        _holdFrame(flow, step: step, outcome: outcome, changed: pending);
      }
      pending.clear();
    }
  }

  /// What a flow changed is what the step it belongs to declares, its
  /// call's writes and its arm's: the frame the model prints, held over
  /// every variable the code holds, not only the ones the step's table
  /// reads. A change belongs to the step whose mark follows it, or, after
  /// the last mark before an await, to that mark's step. The frame's own
  /// flow and the environment's actions are not a table's.
  void _checkFrame(
    int? flow, {
    required ActivationStep step,
    required StepOutcome outcome,
  }) {
    if (flow == null) return;
    final changed = _changed.remove(flow) ?? <ModelVar>{};
    _lastMark[flow] = (step: step, outcome: outcome);
    _markedHere.add(flow);
    _holdFrame(flow, step: step, outcome: outcome, changed: changed);
  }

  void _holdFrame(
    int flow, {
    required ActivationStep step,
    required StepOutcome outcome,
    required Set<ModelVar> changed,
  }) {
    if (!_heldByTables(flow)) return;
    final declares = declaredWrites(step, outcome: outcome, of: declared);
    if (declares == null) return;
    final undeclared = changed.difference(declares);
    if (undeclared.isNotEmpty) {
      _violations.add('flow $flow changed '
          '${[for (final v in undeclared) v.name].join(', ')} in '
          '${step.name} as ${outcome.tla}, which its table does not declare');
    }
  }

  /// Whether the steps [flow] marks are a table's, whose declarations hold
  /// what it changes: not the frame's, the environment's or an unmodeled
  /// flow's.
  bool _heldByTables(int flow) =>
      flow != _frameFlow &&
      !_environmentFlow(flow) &&
      !_unmodeled.contains(flow);

  bool _environmentFlow(int flow) => switch (_flowActions[flow]) {
    final a? => _environment(a),
    null => false,
  };

  /// Whether [a] is the environment's, in the model or around it (a move,
  /// a sign-in, a site added, the noise, a setup, the scheduler's own): its
  /// flow is held by the walk's other checks, not by a table's
  /// declarations. The reroute stays here until its reopen is printed.
  static bool _environment(SiteAction a) => switch (a) {
    Tap() ||
    Preload() ||
    OpenNested() ||
    GoHome() ||
    Pressure() ||
    Wake() ||
    Background() ||
    Foreground() ||
    DnsDownload() ||
    DnsAddLevel() ||
    DnsClear() ||
    SwitchWebspace() ||
    CloseArchive() ||
    Delete() ||
    Retap() ||
    OpenTab() ||
    NewTab() ||
    CloseTab() ||
    DuplicateTab() => false,
    ArchiveSite() ||
    Reroute() ||
    Reply() ||
    Settle() ||
    Login() ||
    Fails() ||
    Add() ||
    Move() ||
    Touch() ||
    StayPut() => true,
  };

  /// Each variable of the model the code holds, as the page and the fakes
  /// keep it now, by its id rather than the model's numbering, which a
  /// read here must not move; null for one only the model keeps.
  Map<Object, String> _frameState() {
    final bySite = [...sites.models, ..._followed.where(_gone)]
      ..sort((a, b) => a.siteId.compareTo(b.siteId));
    String ids(Iterable<WebViewModel> ms) =>
        ([for (final m in ms) '${m.siteId}']..sort()).join(',');
    String each(Object? Function(WebViewModel m) of) =>
        [for (final m in bySite) '${m.siteId}=${of(m)}'].join(';');
    String cookies(Iterable<Cookie> cs) =>
        ([for (final c in cs) '${c.name}=${c.value}']..sort()).join(',');
    String? held(ModelVar v) => switch (v) {
      ModelVar.rows => _rows.join(','),
      ModelVar.loaded => ids(sites.loaded),
      ModelVar.current => '${sites.shown?.siteId}',
      ModelVar.version => '${sites.activationVersion}',
      ModelVar.marker => switch (sites.activating) {
        null => '-',
        final a => '${a.target.siteId}@${a.version}',
      },
      ModelVar.tier => each((m) => m.lifecycleState.name),
      ModelVar.jar => cookies(jar.all),
      ModelVar.stored =>
        each((m) => cookies(stored.allStorage[m.siteId] ?? const <Cookie>[])),
      ModelVar.tabs => each((m) => [for (final t in m.tabs) t.id].join(',')),
      ModelVar.active => each((m) => m.activeTabId),
      ModelVar.built => each((m) => m.tabBinding.built),
      ModelVar.hist => each((m) => switch (m.controller) {
        final FakeWebViewController c => _labelOf(c.history),
        _ => null,
      }),
      ModelVar.queued => each((m) => switch (m.tabBinding.queued) {
        (:final tab, :final bytes) => '$tab:${_labelOf(bytes)}',
        null => null,
      }),
      ModelVar.file => ([
        for (final MapEntry(:key, :value) in navStates.files.entries)
          '$key=${_labelOf(value)}',
      ]..sort()).join(','),
      ModelVar.nested => '${sites.nested?.siteId}',
      ModelVar.headless => ids(sites.headless),
      ModelVar.fore => '${sites.fore}',
      ModelVar.dns => '${DnsBlockService.instance.level} '
          '${[...DnsBlockService.instance.downloadedLevels]..sort()}',
      ModelVar.told =>
        each((m) => DnsBlockService.instance.views.told[m.siteId]),
      ModelVar.gone => ids(_followed.where(_gone)),
      ModelVar.views => ids(_mounted.keys),
      ModelVar.boxes => ids([
        for (final m in _followed)
          if (native.profiles.containsKey(m.containerKey)) m,
      ]),
      // The jar keeps its turn to itself; its own tables' frame holds it.
      ModelVar.holder || ModelVar.queue => null,
      // Kept by the model alone.
      ModelVar.signedIn ||
      ModelVar.minted ||
      ModelVar.fl ||
      ModelVar.inputs ||
      ModelVar.newest ||
      ModelVar.evictedShown ||
      ModelVar.seen ||
      ModelVar.last => null,
    };
    return {for (final v in ModelVar.values) v: ?held(v)};
  }

  /// The script's flows as `formal/activation.tla` numbers them: by the
  /// order their inputs landed, from 1, so an input the code dropped before
  /// its step (a preload not admitted, a tap under a nested screen) leaves
  /// no gap. The launch clear is flow 0.
  final Map<int, int> _modelFlows = {};

  /// A site as `formal/activation.tla` numbers it: by its place in the
  /// page's first list, from 1.
  static int _siteNumber(WebViewModel site) =>
      int.parse(site.siteId.substring('walk-'.length)) + 1;

  /// Each site's tab ids as `formal/activation.tla` numbers them: by first
  /// sight, from 1, as the model mints them (`Mint`, never repeated).
  final Map<SiteId, Map<TabId, int>> _tabNumbers = {};

  int _tabNumber(SiteId site, {required TabId tab}) {
    final numbers = _tabNumbers.putIfAbsent(site, () => {});
    return numbers.putIfAbsent(tab, () => numbers.length + 1);
  }

  /// The tab whose history [label] is, under [key]'s site: its own for a
  /// copy of it (`_own`), numbered.
  int _labelNumber(String key, {required String label}) {
    final site = SiteId(key.substring(0, key.indexOf('.')));
    return _tabNumber(site, tab: TabId(_own(key, label: label)));
  }

  /// The tab variables of `formal/activation.tla`, read off the page: a
  /// tabbed world's every site is `Tabbed`.
  Map<String, Object> _projectTabs(List<WebViewModel> bySite) {
    final files = navStates.files;
    final maxTabs = <int>[];
    final out = <String, Object>{
      'tabs': [
        for (final m in bySite)
          [for (final t in m.tabs) _tabNumber(m.siteId, tab: t.id)]..sort(),
      ],
      'active': [
        for (final m in bySite) _tabNumber(m.siteId, tab: m.activeTabId),
      ],
      'built': [
        for (final m in bySite)
          switch (m.tabBinding.built) {
            final t? => _tabNumber(m.siteId, tab: t),
            null => 0,
          },
      ],
      'hist': [
        for (final m in bySite)
          switch (m.controller) {
            final FakeWebViewController c => _labelNumber(
              '${m.siteId}.${m.tabBinding.built}',
              label: _labelOf(c.history),
            ),
            _ => 0,
          },
      ],
      'queued': [
        for (final m in bySite)
          switch (m.tabBinding.queued) {
            (:final tab, :final bytes) => [
              _tabNumber(m.siteId, tab: tab),
              _labelNumber('${m.siteId}.$tab', label: _labelOf(bytes)),
            ],
            null => [0, 0],
          },
      ],
    };
    // Every tab seen so far has a number; a file names its tab by key.
    for (final key in files.keys) {
      _labelNumber(key, label: _labelOf(files[key]!));
    }
    for (final m in bySite) {
      maxTabs.add(_tabNumbers[m.siteId]?.length ?? 1);
    }
    out['file'] = [
      for (final m in bySite)
        [
          for (var n = 1; n <= maxTabs.reduce(max); n++)
            switch (files['${m.siteId}.${_tabWithNumber(m.siteId, n: n)}']) {
              final bytes? => _labelNumber(
                '${m.siteId}.${_tabWithNumber(m.siteId, n: n)}',
                label: _labelOf(bytes),
              ),
              null => 0,
            },
        ],
    ];
    out['minted'] = maxTabs;
    return out;
  }

  /// The tab numbered [n] of [site], or a name no tab has.
  TabId _tabWithNumber(SiteId site, {required int n}) {
    for (final MapEntry(key: tab, value: number)
        in (_tabNumbers[site] ?? const <TabId, int>{}).entries) {
      if (number == n) return tab;
    }
    return TabId('none');
  }

  bool _gone(WebViewModel m) => !sites.models.contains(m);

  /// The state `formal/activation.tla` names, read off the page.
  Map<String, Object> _project() {
    List<int> owners(Iterable<Cookie> cookies) => {
      for (final c in cookies)
        if (c.value.startsWith('walk-')) int.parse(c.value.substring(5)) + 1,
    }.toList()..sort();
    // The model's per-site state is over every site, a closed archive's
    // included.
    final bySite = [...sites.models, ..._followed.where(_gone)]
      ..sort((a, b) => _siteNumber(a).compareTo(_siteNumber(b)));
    final activating = sites.activating;
    return {
      'rows': _rows,
      'loaded': [for (final m in sites.loaded) _siteNumber(m)]..sort(),
      'current': switch (sites.shown) {
        final shown? => _siteNumber(shown),
        null => 0,
      },
      'version': sites.activationVersion - _scriptVersion,
      'nested': switch (sites.nested) {
        final up? => _siteNumber(up),
        null => 0,
      },
      'headless': [for (final m in sites.headless) _siteNumber(m)]..sort(),
      'fore': sites.fore,
      if (dns != null) ...{
        'dns': {
          'lvl': DnsBlockService.instance.level,
          'levels': [...DnsBlockService.instance.downloadedLevels]..sort(),
        },
        'told': [
          for (final m in bySite)
            DnsBlockService.instance.views.told[m.siteId] ?? -1,
        ],
      },
      'marker': activating == null
          ? [0, 0]
          : [
              _siteNumber(activating.target),
              activating.version - _scriptVersion,
            ],
      'tier': [
        for (final m in bySite)
          switch (m.lifecycleState) {
            SiteLifecycleState.resident => 'resident',
            SiteLifecycleState.cacheCleared => 'cleared',
            SiteLifecycleState.savedForRestore => 'saved',
          },
      ],
      'jar': owners(jar.all),
      'stored': [
        for (final m in bySite) owners(stored.allStorage[m.siteId] ?? const []),
      ],
      if (tabbed) ..._projectTabs(bySite),
      if (_boxed) ...{
        'gone': [for (final m in _followed.where(_gone)) _siteNumber(m)]
          ..sort(),
        'views': [for (final m in _mounted.keys) _siteNumber(m)]..sort(),
        'boxes': [
          for (final m in _followed)
            if (native.profiles.containsKey(m.containerKey)) _siteNumber(m),
        ]..sort(),
      },
    };
  }

  /// The tab whose history [bytes] are, as the walk writes it.
  static String _labelOf(Uint8List bytes) => utf8.decode(bytes);

  static Uint8List _historyOf(TabId tab) => Uint8List.fromList(utf8.encode('$tab'));

  /// History [label], as the tab [key] names sees it: its own when [label]
  /// is that tab or one it was copied from.
  String _own(String key, {required String label}) {
    final site = key.substring(0, key.indexOf('.'));
    final tab = key.substring(key.indexOf('.') + 1);
    for (String? at = tab; at != null; at = _copyOf['$site.$at']) {
      if (at == label) return tab;
    }
    return label;
  }

  /// A duplicate writes its source's history under its copy's key.
  void _onSave(String key, {required Uint8List state}) {
    if (_flowActions[currentFlow()] is! DuplicateTab) return;
    final label = _labelOf(state);
    if (key.substring(key.indexOf('.') + 1) != label) _copyOf[key] = label;
  }

  /// The page's first sites by number, whatever rows they moved to.
  List<WebViewModel> get _bySite =>
      [...sites.models.where((m) => _siteNumber(m) <= page.hosts.length)]
        ..sort((a, b) => _siteNumber(a).compareTo(_siteNumber(b)));

  /// The route each site's traffic takes as the code resolves it, numbered
  /// from 1 by first appearance, as the model's `Route`; direct is a route
  /// like any other.
  List<int> get _routes {
    final seen = <ProxyRouteKey, int>{};
    return [
      for (final m in _bySite)
        seen.putIfAbsent(
          resolveEffectiveProxy(m.proxySettings, siteId: m.siteId).routeKey,
          () => seen.length + 1,
        ),
    ];
  }

  /// Each site's Tor exit constraint as the code reads it, numbered from 1
  /// by first appearance, `0` for a site off Tor (the model's `Exit`).
  List<int> get _exits {
    final seen = <String, int>{};
    return [
      for (final m in _bySite)
        switch (SiteUnloadEngine.torExitConstraint(m)) {
          final exit? => seen.putIfAbsent(exit, () => seen.length + 1),
          null => 0,
        },
    ];
  }

  /// What a switch between two of the page's webspaces stops showing, by
  /// site number, as `formal/activation.tla`'s `Away`.
  List<List<int>> get _away {
    final named = spaces;
    if (named == null) return const [];
    final all = [for (var p = 0; p < page.hosts.length; p++) p];
    final views = [all, ...named];
    final away = <String, List<int>>{};
    for (final from in views) {
      for (final to in views) {
        if (identical(from, to)) continue;
        final left = [
          for (final p in from)
            if (!to.contains(p)) p + 1,
        ]..sort();
        away[left.join(',')] = left;
      }
    }
    return [...away.values];
  }

  /// The page's base domains, numbered from 1 by first appearance, as
  /// `formal/activation.tla`'s `Base`.
  List<int> get _bases {
    final seen = <String, int>{};
    return [
      for (final h in page.hosts)
        seen.putIfAbsent(getBaseDomain('https://$h/'), () => seen.length + 1),
    ];
  }

  @override
  void beginScript() {
    _nextFlow = 0;
    // The model starts from the state the setup left.
    _changed.clear();
    _lastMark.clear();
    _unmodeled.clear();
    // Setup flows are numbered from 0 too; one that committed must not
    // make the script's flow of that number look committed.
    _committed.clear();
    _flowActions.clear();
    _scriptVersion = sites.activationVersion;
    _tabNumbers.clear();
    _modelFlows.clear();
    // No model takes a slot's identity yet: a reroute world's steps are
    // held by its invariants, not replayed.
    if (StepTraces.instance.asked && !rehosts) {
      _recording = (
        config: '${page.containers ? 'containers' : 'jar'}_${_bases.join()}'
            '${launch == null ? '' : '_launch'}${tabbed ? '_tabs' : ''}'
            '${proxies == null ? '' : '_${proxies!.scope.name}${_routes.join()}_tor${_exits.join()}'}'
            '${caps == kResidencyCaps ? '' : '_cap${caps.loaded}${caps.resident}'}'
            '${nestedOpens ? '_nested' : ''}'
            '${wakes ? '_wake' : ''}'
            '${dns == null ? '' : '_dns'}'
            '${spaces == null ? '' : '_spaces'}'
            '${archived ? '_archive' : ''}'
            '${deletes ? '_delete' : ''}'
            '${page.incognito.isEmpty ? '' : '_incognito'}'
            '${_faults.isEmpty ? '' : '_fails_${[for (final f in _faults) f.name].join('_')}'}',
        constants: (
          sites: page.hosts.length,
          tabbed: tabbed,
          boxed: archived || deletes,
          tla: {for (final c in ModelConst.values) c: ?_constant(c)},
        ),
        start: _project(),
        steps: [],
      );
    }
  }

  /// Each constant of the model as this page sets it, as TLA+ text, or
  /// null where the base module's definition stands: a constant left out
  /// here does not compile, and the replay sets each one it is given.
  String? _constant(ModelConst c) {
    final every = [for (var s = 1; s <= page.hosts.length; s++) s];
    String set(Iterable<Object> xs) => '{${xs.join(', ')}}';
    String seq(Iterable<Object> xs) => '<<${xs.join(', ')}>>';
    return switch (c) {
      ModelConst.containers => '${page.containers}'.toUpperCase(),
      ModelConst.coldStart => '${launch != null}'.toUpperCase(),
      ModelConst.tabbed => set(tabbed ? every : const <int>[]),
      // Every script of the configuration counts: the replay takes the
      // most any trace minted.
      ModelConst.maxTabs => null,
      ModelConst.contending => set(switch (proxies?.scope) {
        WalkScope.global => every,
        WalkScope.router => _sharingDefault,
        WalkScope.session || null => const <int>[],
      }),
      ModelConst.routed => set(switch (proxies?.scope) {
        WalkScope.router => _sharingDefault,
        WalkScope.global || WalkScope.session || null => const <int>[],
      }),
      ModelConst.route => seq(_routes),
      ModelConst.torExit => seq(_exits),
      ModelConst.torRuntime => '$_torRuntime'.toUpperCase(),
      ModelConst.maxLoaded => '${caps.loaded}',
      ModelConst.maxResident => '${caps.resident}',
      ModelConst.linked => set(nestedOpens ? every : const <int>[]),
      ModelConst.proxyRefused => _faults.contains(Fault.proxy) ? 'TRUE' : null,
      ModelConst.jarRefuses => _jarFails ? 'TRUE' : null,
      ModelConst.notified => set(wakes ? every : const <int>[]),
      ModelConst.waking => '$wakes'.toUpperCase(),
      ModelConst.siteLevel => seq(switch (dns?.siteLevels) {
        final levels? when levels.isNotEmpty => [for (final l in levels) l ?? -1],
        _ => [for (final _ in every) -1],
      }),
      ModelConst.dnsLevels => set(dns?.levels ?? const <int>[]),
      ModelConst.away => set([for (final a in _away) set(a)]),
      ModelConst.online => _faults.contains(Fault.network) ? 'FALSE' : null,
      ModelConst.archive => set([for (final m in _archived) _siteNumber(m)]),
      ModelConst.deletable => set(deletes ? const [1] : const <int>[]),
      ModelConst.boxed || ModelConst.noNavState => null,
      // An archive's sites are incognito too (`Incognito == Archive`).
      ModelConst.incognito => page.incognito.isEmpty
          ? null
          : set({
              for (final m in _archived) _siteNumber(m),
              for (final (i, h) in page.hosts.indexed)
                if (page.incognito.contains(h)) i + 1,
            }),
      ModelConst.sites => null,
      ModelConst.base => seq(_bases),
    };
  }

  @override
  ActivationStep? inputOf(SiteAction action) => switch (action) {
    Tap() => ActivationStep.tap,
    GoHome() => ActivationStep.goHome,
    Pressure() => ActivationStep.pressure,
    Preload() => ActivationStep.preload,
    OpenNested() => ActivationStep.nestedOpen,
    Wake() => ActivationStep.wake,
    Background() => ActivationStep.background,
    Foreground() => ActivationStep.foreground,
    DnsDownload() => ActivationStep.dnsDownload,
    DnsAddLevel() => ActivationStep.dnsAddLevel,
    DnsClear() => ActivationStep.dnsClear,
    SwitchWebspace() => ActivationStep.spaceSwitch,
    CloseArchive() => ActivationStep.closeArchive,
    Delete() => ActivationStep.deleteSite,
    OpenTab() => ActivationStep.openTab,
    NewTab() => ActivationStep.newTab,
    CloseTab() => ActivationStep.closeTab,
    DuplicateTab() => ActivationStep.duplicateTab,
    // A move is the environment's, a move into an archive and a reroute
    // the model's setup, and the rest wait on the page.
    Move() ||
    ArchiveSite() ||
    Reroute() ||
    Add() ||
    Reply() ||
    Settle() ||
    Login() ||
    Fails() ||
    Retap() ||
    Touch() ||
    StayPut() => null,
  };

  @override
  void endScript() {
    if (_recording
        case (:final config, :final constants, :final start, :final steps)?) {
      StepTraces.instance.add(
        config: config,
        constants: constants,
        start: start,
        steps: steps,
      );
    }
  }

  /// The page's `_commitSites`: the change, then a rebuild.
  /// The page's commit, the funnel the page itself runs.
  Future<void> _commit(SiteSetChange change) => _siteSetCommit.commit(change);

  /// The rows as a drop found them, for the replay; a close's replaces a
  /// delete's.
  void _noteRowsAtDrop({required bool overwrite}) {
    if (_rowsAtDrop != null && !overwrite) return;
    _rowsAtDrop = [for (final m in sites.models) ActivationWorld._siteNumber(m)];
  }

  /// Another component edits the rows, as `formal/activation.tla`'s
  /// environment does (`Move`): at once, between the flows' steps.
  void _editRows(SiteSetChange change) {
    sites.apply(
      change,
      commit: change is SitesMoved
          ? const Commit.environment(Environment.move)
          : const Commit.unmodeled(Unmodeled.siteSet),
    );
    _drawn = sites.shown;
  }

  late final SiteSetCommit _siteSetCommit = SiteSetCommit(
    sites,
    host: _WalkCommitHost(this),
  );



  /// The frame after an activation or a tab rebind: every loaded site
  /// without a webview gets one, built as `WebViewModel.getWebView` builds
  /// it, for the active tab and from the back stack queued for that tab.
  void _buildWebViews() {
    for (final m in sites.loaded) {
      if (m.controller != null) continue;
      final tab = m.activeTabId;
      m.tabBinding.bind(tab, commit: const Commit.environment(Environment.frame));
      final bytes = m.tabBinding.take(
        tab: tab,
        commit: const Commit.environment(Environment.frame),
      );
      m.controller = FakeWebViewController()
        ..pace = _webViewPace
        ..history = bytes ?? _historyOf(tab);
      _claimRoute(m);
    }
  }

  /// A built webview's first act, as `WebViewModel.setController` does it:
  /// its site's claim on the process-wide rule, where one covers every
  /// webview. The write answers at once, as a loaded site's pause does: it
  /// moves nothing the model holds, and the rule's own assert holds the
  /// claim to every other occupant (PROXY-008).
  void _claimRoute(WebViewModel m) {
    if (proxies?.scope != WalkScope.global) return;
    final (:occupant, :runsAs) = m.routeClaim;
    _track(_route.claim(
      occupant,
      route: ProxyConflictEngine.routeOf(
        runsAs.proxySettings,
        siteId: runsAs.siteId,
      ),
      write: () async {},
    ));
  }

  WebViewModel _site(String host) => WebViewModel(
    siteId: SiteId('walk-${_nextSite++}'),
    initUrl: 'https://$host/',
    name: host,
    incognito: page.incognito.contains(host),
    proxySettings: switch ((
      route: proxies?.routes[page.hosts.indexOf(host)],
      exit: proxies?.exits[page.hosts.indexOf(host)],
    )) {
      (route: _, exit: final exit?) => UserProxySettings(
        type: ProxyType.TOR,
        torExitCountry: exit,
      ),
      (route: final route?, exit: null) => UserProxySettings(
        type: ProxyType.HTTP,
        address: '$route:8080',
      ),
      (route: null, exit: null) => UserProxySettings(type: ProxyType.DEFAULT),
    },
  );

  @override
  bool get idle => _started == _finished;

  void _track(Future<void> work) {
    _started++;
    _inFlight.add(work.whenComplete(() => _finished++));
  }

  /// The newest activation while it runs, whose target no unload may
  /// dispose (PAUSE-006) until a newer input supersedes it; read independently of the controller's own marker, and keyed by
  /// the activation, not its target, which a double tap shares.
  ({int id, WebViewModel? target, int version})? _newest;
  int _activations = 0;

  /// What broke between settles, reported at the next one.
  final List<String> _violations = [];

  /// What the platform fails at ([Fails]).
  final Set<Fault> _faults = {};

  bool get _jarFails => _faults.any(
    (f) => switch (f) {
      Fault.jarRead || Fault.jarWrite || Fault.jarClear => true,
      Fault.proxy || Fault.network => false,
    },
  );

  /// The process-wide proxy rule's write, which a [Fault.proxy] refuses
  /// once the platform has answered.
  Future<void> _writeRule() async {
    await gate.pace(PlatformCall.proxyOverride);
    if (_faults.contains(Fault.proxy)) {
      throw const ProxyRefused('the walk refuses the rule');
    }
  }

  /// The process-wide proxy rule the production webviews release on
  /// dispose, which the walk's nested opens, wakes and webview builds claim.
  final ProcessRoute _route = ProcessRoute.instance..resetForTest();

  void _startActivation(WebViewModel? target) => _track(_activate(target));

  /// The flows code starts on its own, an activation a tab handler asks
  /// for: numbered below the frame's, so the script's keep their numbers.
  int _nextSpawned = _frameFlow - 1;

  Future<void> _activate(WebViewModel? target) {
    final work = activation.activate(target);
    final id = ++_activations;
    _newest = (id: id, target: target, version: sites.activationVersion);
    return work.whenComplete(() {
      if (_newest?.id == id) _newest = null;
    });
  }

  void _noteUnloaded(WebViewModel model, {required UnloadReason reason}) {
    unloads.add('${model.siteId}:${reason.name}');
    if (_newest case (:final target?, :final version, id: _)
        when identical(model, target) && version == sites.activationVersion) {
      _violations.add('${reason.label} unloaded ${model.siteId} while its '
          'activation ran (PAUSE-006)');
    }
  }

  @override
  void start(SiteAction action) {
    _flowActions[_nextFlow] = action;
    final flow = _nextFlow++;
    // A nested screen covers the page: only the launch's preloads and the
    // OS's memory pressure land under it.
    if (sites.nested != null && action is! Preload && action is! Pressure) {
      return;
    }
    // The list, where a webspace is chosen, shows only with no site on
    // screen.
    if (action is SwitchWebspace && sites.shown != null) return;
    // Off screen the user makes no input: only the OS's and the app's
    // return land.
    if (!sites.fore &&
        action is! Preload &&
        action is! Pressure &&
        action is! Wake &&
        action is! Foreground) {
      return;
    }
    inFlow(flow: flow, () => _start(action));
  }

  void _start(SiteAction action) {
    final n = sites.models.length;
    WebViewModel at(int slot) => sites.models[slot % n];
    TabId tabAt(WebViewModel m, {required int tab}) => m.tabs[tab % m.tabs.length].id;
    switch (action) {
      case Tap(:final slot):
        if (n > 0) _startActivation(sites.models[slot % n]);
      case GoHome():
        _startActivation(null);
      case Pressure():
        _track(activation.memoryPressure());
      case Preload(:final slot):
        if (n > 0) {
          _track(
            activation.preload(
              sites.models[slot % n].siteId,
              after: const Reached<Launched>.inTest(),
            ),
          );
        }
      case Add(:final host):
        if (page.pool.isNotEmpty) {
          _editRows(SiteAdded(_site(page.pool[host % page.pool.length])));
        }
      case Move(:final from, :final to):
        if (n > 0) {
          _editRows(SitesMoved(from % n, to: to % n));
          ActivationSteps.mark(ActivationStep.move);
        }
      case OpenTab(:final slot, :final tab):
        if (n > 0) {
          final m = at(slot);
          _offScreenTabInput(m);
          _track(tabs.openTab(m, tabId: tabAt(m, tab: tab)));
        }
      case NewTab(:final slot):
        if (n > 0) {
          _offScreenTabInput(at(slot));
          _track(tabs.newTab(at(slot)));
        }
      case CloseTab(:final slot, :final tab):
        if (n > 0) {
          final m = at(slot);
          _offScreenTabInput(m);
          _track(tabs.closeTab(m, tabId: tabAt(m, tab: tab)));
        }
      case DuplicateTab(:final slot):
        if (n > 0) {
          _offScreenTabInput(at(slot));
          _track(tabs.duplicateTab(at(slot)));
        }
      case OpenNested(:final slot):
        if (n > 0) {
          _track(
            activation.openNested(
              at(slot),
              opening: (
                screen: _WalkNestedScreen(this),
                url: '${at(slot).initUrl}nested',
                source: null,
              ),
            ),
          );
        }
      case Wake():
        if (wakes && !sites.fore && !wakeEngine.waking) _track(_runWake());
      case DnsDownload(:final pick):
        if (dns case (:final levels, siteLevels: _)?) {
          _track(
            DnsBlockService.instance.downloadList(levels[pick % levels.length]),
          );
        }
      case DnsAddLevel(:final pick):
        if (dns case (:final levels, siteLevels: _)?) {
          _track(
            DnsBlockService.instance.downloadLevel(levels[pick % levels.length]),
          );
        }
      case DnsClear():
        if (dns != null) _track(DnsBlockService.instance.downloadList(0));
      case SwitchWebspace(:final pick):
        if (spaces != null) {
          _track(
            webspaces.select(sites.webspaces[pick % sites.webspaces.length]),
          );
        }
      case ArchiveSite(:final slot):
        if (archived && n > 0 && !at(slot).isArchiveTier) {
          _archived.add(at(slot));
          _unmodeled.add(currentFlow());
          _track(archives.moveIn(at(slot)));
        }
      case Delete():
        if (deletes) {
          for (final m in [...sites.models]) {
            if (_siteNumber(m) != 1) continue;
            _deleted = m;
            _track(deletion.delete(m));
          }
        }
      case Reroute():
        if (rehosts) {
          for (final m in sites.models) {
            if (_siteNumber(m) != 1) continue;
            m.routeOutboundLinks = !m.routeOutboundLinks;
          }
          _unmodeled.add(currentFlow());
          _track(_commit(const SiteSettingsClosed()));
        }
      case CloseArchive():
        if (archived && _archived.isNotEmpty) {
          if (archives.archiveOf(_archived.first) case final handle?) {
            _track(archives.close(handle));
          }
        }
      case Background():
        if (wakes && sites.fore) wakeEngine.background(_wake);
      case Foreground():
        if (!sites.fore) wakeEngine.foreground(_wake);
      case Reply() ||
          Settle() ||
          Login() ||
          Fails() ||
          Retap() ||
          Touch() ||
          StayPut():
        throw ArgumentError('$action waits on the platform or the page, so a '
            'schedule cannot start it');
    }
  }

  /// One wake, its settle paced afresh.
  Future<void> _runWake() async {
    _wake.paced = false;
    await wakeEngine.wake(_wake);
  }

  /// A tab input on a site off screen takes the handler's other path, an
  /// activation inside the tab gate, which activation.tla does not hold:
  /// the script's steps are checked by the world's invariants, not
  /// replayed.
  void _offScreenTabInput(WebViewModel m) {
    if (identical(m, sites.shown)) return;
    _recording = null;
    _unmodeled.add(currentFlow());
  }

  @override
  Future<void> apply(SiteAction action) async {
    // An action lands as an event does: only once every flow waits on the
    // platform, never between two of its microtasks.
    await quiesce(this);
    _frameViews();
    _frameMounts();
    final n = sites.models.length;
    switch (action) {
      case Tap() ||
          GoHome() ||
          Pressure() ||
          Preload() ||
          Add() ||
          Move() ||
          OpenTab() ||
          NewTab() ||
          CloseTab() ||
          DuplicateTab() ||
          OpenNested() ||
          Wake() ||
          Background() ||
          Foreground() ||
          DnsDownload() ||
          DnsAddLevel() ||
          DnsClear() ||
          SwitchWebspace() ||
          ArchiveSite() ||
          CloseArchive() ||
          Delete() ||
          Reroute():
        start(action);
      case Reply(:final pick):
        final waiting = gate.pending.length;
        if (waiting > 0) gate.release(pick % waiting);
      case Settle():
        await settle();
      case Fails(:final fault):
        _faults.add(fault);
        if (switch (fault) {
          Fault.jarRead => JarCall.read,
          Fault.jarWrite => JarCall.write,
          Fault.jarClear => JarCall.clear,
          Fault.proxy || Fault.network => null,
        } case final call?) {
          jar.failing.add(call);
        }
      case Login(:final slot):
        await settle();
        if (n > 0 && sites.isLoadedAt(slot % n)) {
          _track(_signIn(sites.models[slot % n]));
          await settle();
        }
      case Retap():
        await _noise(
          () async {
            if (sites.shown case final shown?) {
              _startActivation(shown);
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
          () async => _editRows(const SitesEdited()),
          expected: ({required before, required after}) => before,
        );
      case StayPut(:final slot):
        await _noise(
          () async {
            if (n > 0) _editRows(SitesMoved(slot % n, to: slot % n));
          },
          expected: ({required before, required after}) => PageState(
            current: before.current,
            loaded: before.loaded,
            version: before.version,
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
      (native.dataByContainer[site.containerKey] ??= []).add(name);
    } else {
      await jar.setCookie(
        url: Uri.parse(site.initUrl),
        name: name,
        value: site.siteId,
      );
    }
    ActivationSteps.mark(ActivationStep.login, site: site);
    (_signedIn[site.siteId] ??= {}).add(name);
  }

  @override
  Future<void> settle() async {
    // A frame's webview builds claim the process-wide rule, work that
    // settles in turn.
    do {
      await quiesce(this);
      while (gate.pending.isNotEmpty) {
        gate.release(0);
        await quiesce(this);
      }
      expect(idle, isTrue,
          reason: 'a flow waits on something no platform reply ends');
      final finished = [..._inFlight];
      _inFlight.clear();
      await Future.wait(finished);
      _frameViews();
      _frameMounts();
    } while (_inFlight.isNotEmpty);
    _checkSettled();
  }

  void _checkSettled() {
    expect(_violations, isEmpty);
    expect(
      {
        for (final MapEntry(key: flow, value: vars) in _changed.entries)
          if (vars.isNotEmpty && _heldByTables(flow))
            flow: [
              for (final v in vars) v.name,
              'after ${_lastMark[flow]?.step.name}',
              '${_flowActions[flow]}',
            ],
      },
      isEmpty,
      reason: 'a flow changed the model after its last step, where no '
          'table declares what it writes',
    );
    expect(
      {
        for (final MapEntry(key: flow, value: calls) in _unmarked.entries)
          if (calls.isNotEmpty) flow: calls,
      },
      isEmpty,
      reason: 'a flow waited on the platform with no step marking it '
          '(ActivationStep)',
    );
    expect(
      sites.activating,
      isNull,
      reason: 'an activation is still marked in flight once settled',
    );
    if (sites.shown case final shown?) {
      expect(
        sites.loaded,
        contains(shown),
        reason: 'the site on screen is not loaded (Inv_CurrentLoaded)',
      );
    }
    expect(
      [
        for (final m in sites.loaded)
          if (m.lifecycleState == SiteLifecycleState.savedForRestore)
            m.siteId,
      ],
      isEmpty,
      reason: 'a loaded site is at savedForRestore, which memory pressure '
          'never picks (Inv_LoadedNotSaved)',
    );
    expect(
      _drawn?.siteId,
      sites.shown?.siteId,
      reason: 'the page last drew another site than the one on screen: '
          'nothing rebuilt after the change',
    );
    expect(
      _route.occupants.keys.toSet(),
      {
        if (proxies?.scope == WalkScope.global)
          for (final m in sites.loaded) m.routeClaim.occupant,
      },
      reason: 'the process-wide proxy names something other than the '
          'loaded sites: a claim left with nothing running on it, or a '
          'webview that never claimed (PROXY-008)',
    );
    expect(
      sites.headless,
      isEmpty,
      reason: 'a wake left a headless check open (NOTIF-016)',
    );
    page.containers ? _checkContainers() : _checkSharedJar();
    _checkTabs();
    _checkRetired();
  }

  /// ARCH-007, ARCH-014, BUG-038: once a close or a delete took sites off
  /// the list, none is loaded, on screen or mounted, and none's container
  /// is on disk (`Inv_Retired`).
  void _checkRetired() {
    expect(
      [
        for (final m in _followed.where(_gone))
          if (sites.loaded.contains(m) ||
              identical(m, sites.shown) ||
              _mounted.containsKey(m) ||
              native.profiles.containsKey(m.containerKey))
            m.siteId,
      ],
      isEmpty,
      reason: 'a site off the list is still loaded, on screen, mounted or '
          'on disk (ARCH-007, ARCH-014, BUG-038)',
    );
  }

  /// TAB-003: a site's one webview shows its active tab's history, and each
  /// tab's state file holds that tab's history.
  void _checkTabs() {
    for (final m in sites.models) {
      expect([for (final t in m.tabs) t.id], contains(m.activeTabId),
          reason: '${m.siteId}\'s active tab is not in its list');
    }
    for (final m in sites.loaded) {
      final webview = m.controller;
      expect(webview, isA<FakeWebViewController>(),
          reason: 'loaded ${m.siteId} has no webview once settled');
      expect(m.tabBinding.built, m.activeTabId,
          reason: '${m.siteId}\'s webview was built for another tab');
      expect(
        _own('${m.siteId}.${m.activeTabId}',
            label: _labelOf((webview! as FakeWebViewController).history)),
        '${m.activeTabId}',
        reason: '${m.siteId}\'s webview shows another tab\'s history',
      );
    }
    navStates.files.forEach((key, bytes) {
      expect(_own(key, label: _labelOf(bytes)),
          key.substring(key.indexOf('.') + 1),
          reason: 'the state file $key holds another tab\'s history');
    });
  }

  void _checkSharedJar() {
    final byBase = <String, String>{};
    for (final s in sites.loaded) {
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
    // A jar that refuses can lose a session, never cross one (ISO-014).
    if (_jarFails) return;
    for (final MapEntry(key: siteId, value: names) in _signedIn.entries) {
      final loaded = sites.loaded.any((m) => m.siteId == siteId);
      // An incognito site's session is the jar's while it is loaded and
      // nowhere after; none of it reaches its storage (INC-001).
      final incognito = sites.models.any(
        (m) => m.siteId == siteId && m.effectiveIncognito,
      );
      if (incognito) {
        expect(
          stored.allStorage[siteId] ?? const <Cookie>[],
          isEmpty,
          reason: 'incognito $siteId had cookies saved to its storage (INC-001)',
        );
      }
      if (!loaded && incognito) continue;
      final held = loaded
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
            '${loaded ? 'loaded (jar)' : 'unloaded (storage)'}',
      );
    }
  }

  void _checkContainers() {
    if (sites.shown case final shown?) {
      expect(
        native.profiles,
        contains(shown.containerKey),
        reason: 'the site on screen runs without its container',
      );
    }
    for (final MapEntry(key: siteId, value: names) in _signedIn.entries) {
      // A closed archive's site took its container with it.
      final site = sites.models.where((m) => m.siteId == siteId).firstOrNull;
      if (site == null) continue;
      expect(
        native.dataByContainer[site.containerKey] ?? const <String>[],
        containsAll(names),
        reason: '$siteId lost cookies from its own container',
      );
    }
  }

  PageState observe() => PageState(
    current: sites.current,
    loaded: [for (final m in sites.loaded) m.siteId],
    version: sites.activationVersion,
    sites: [for (final m in sites.models) m.siteId],
    tiers: [for (final m in sites.models) m.lifecycleState.name],
    jar: [for (final c in jar.all) _cookie(c)]..sort(),
    stored: _stored(),
    containers: [...native.profiles.keys]..sort(),
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
/// The surface's repaints, recorded rather than drawn.
final class _WalkSurface extends SurfaceRepaintController {
  _WalkSurface(super.host, {required this.world})
      : super(repaints: false, traceSuffix: '');

  final ActivationWorld world;

  @override
  void nudge(String trigger) {
    world.recoveries.add('nudge $trigger');
    super.nudge(trigger);
  }
}

final class _WalkHost implements ActivationHost, SurfaceHost, WebspacesHost {
  _WalkHost(this.world);

  final ActivationWorld world;

  @override
  bool get mounted => true;

  @override
  void rebuild() => world._drawn = world.sites.shown;

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
  Future<void> refreshRoutes({WebViewModel? active}) =>
      world.gate.pace(PlatformCall.routerSetRoutes);

  /// Its own flow, numbered as an activation a tab handler asks for.
  @override
  Future<void> spawned(Future<void> Function() flow) {
    final work = inFlow(flow: world._nextSpawned--, flow);
    world._track(work);
    return work;
  }

  @override
  Future<bool> isOnline() async {
    await world.gate.pace(PlatformCall.connectivity);
    return !world._faults.contains(Fault.network);
  }

  @override
  void openDrawer() {}

  @override
  void syncTorExitPin(Iterable<WebViewModel> sites) {}

  @override
  Future<void> probeRenderer(
    WebViewModel model, {
    required String trigger,
  }) async =>
      world.recoveries.add('probe ${model.siteId} $trigger');

  /// Called as an activation ends.
  @override
  void backgroundSitesChanged() => world._buildWebViews();
}

/// The page's side of a commit: the controllers the world builds run as
/// the page's do; what is left writes nothing the model holds.
final class _WalkCommitHost implements SiteSetCommitHost {
  _WalkCommitHost(this.world);

  final ActivationWorld world;

  @override
  bool get mounted => true;

  @override
  void rebuild() => world._drawn = world.sites.shown;


  @override
  Future<void> closeArchives() =>
      throw UnsupportedError('no world imports a backup');

  @override
  Future<void> recordInArchive(SiteArchived change) =>
      world.archives.recordIn(change.site, into: change.into);

  @override
  void pruneLinkReferences() {}

  @override
  Future<void> reconcileLinkTabs() => world.tabs.reconcileLinkTabs();

  @override
  Future<void> closeIneligibleHostedTabs() =>
      world.tabs.closeIneligibleHostedTabs();

  @override
  void screenEmptied() {}

  @override
  Future<void> saveSelectedWebspaceId() async {}

  /// The page's sync unloads a site whose Tor pin lost to another's; an
  /// activation already unloads every one, so in the walk it unloads none.
  @override
  Future<void> syncTorHolders() async {
    final sites = world.sites;
    final order = {?sites.shown, ...sites.loaded.toList().reversed};
    final plan = SiteUnloadEngine.plan(
      _WalkResidency(world),
      event: TorExitSettled([for (final m in order) sites.models.indexOf(m)]),
    );
    expect(plan.unloads, isEmpty,
        reason: 'a commit\'s Tor sync would unload a site; run it as the '
            'page does');
  }

  /// Not awaited by the commit, and the relay's table is not the model's.
  @override
  Future<void> refreshRoutes({WebViewModel? active}) async {}

  @override
  Future<void> persistSites() async {}

  @override
  Future<void> saveWebspaces() async {}

  @override
  void backgroundSitesChanged() {}

  @override
  Future<void> sweepOrphans() async {}
}

/// The walk edits and deletes no webspace; it only switches between them.
final class _WalkWebspacePrompts implements WebspacePrompts {
  const _WalkWebspacePrompts();

  @override
  Future<void> edit(
    Webspace webspace, {
    required List<WebViewModel> sites,
    required bool readOnly,
    required void Function(Webspace saved) onSave,
  }) => throw UnsupportedError('the walk edits no webspace');

  @override
  Future<bool> confirmDelete(Webspace webspace) =>
      throw UnsupportedError('the walk deletes no webspace');
}

/// The page's side of a nested open, as the platform answers it: the
/// proxy's move and the screen's pop are replies a schedule releases.
final class _WalkNestedScreen implements NestedScreenHost {
  _WalkNestedScreen(this.world);

  final ActivationWorld world;

  @override
  Future<void> switchWebspaceFor(WebViewModel target) => Future.value();

  @override
  Future<void> applyProxyOf(WebViewModel target) => world._route.claim(
    (use: RouteUse.nested, site: target.siteId),
    route: ProxyConflictEngine.routeOf(
      target.proxySettings,
      siteId: target.siteId,
    ),
    write: world._writeRule,
  );

  /// A failure the walk did not plant is a bug.
  @override
  void reportProxyFailure(Object error) {
    if (world._faults.contains(Fault.proxy)) return;
    world._violations.add('a nested open\'s proxy failed: $error');
  }

  @override
  Future<void> launch(WebViewModel target, {required String url}) =>
      world.gate.pace(PlatformCall.nestedScreen);

  @override
  void closed(WebViewModel target) =>
      world._route.release((use: RouteUse.nested, site: target.siteId));
}

/// The app's side of a wake, as the platform answers it: the route's move,
/// each headless open and close, and the reloads' settle are replies a
/// schedule releases; the pages post nothing and show no count.
final class _WalkWake implements BackgroundWakeHost<WebViewModel> {
  _WalkWake(this.world);

  final ActivationWorld world;

  /// Whether this wake's settle has waited on the platform yet: once, so
  /// the step it runs in waits on one call.
  bool paced = false;
  DateTime _now = DateTime(2026, 10, 13);

  @override
  RuntimeVars<WebViewModel> get vars => world.sites.vars;

  @override
  WebViewModel siteOf(SiteId siteId) => world.sites.byId(siteId)!;

  @override
  bool routeFree(WebViewModel site) => world.activation.routeFreeFor(site);

  @override
  bool get nestedOpening => world.activation.opensNested;

  /// The opens under way, which the app's return waits out, as the page's
  /// host does.
  final Set<Future<void>> _opening = {};

  @override
  void closeAllHeadless() => unawaited(world._route.vacateEvery(
    RouteUse.headless,
    close: () => Future.wait([..._opening]),
  ));

  @override
  void leave(SiteId siteId) =>
      world._route.release((use: RouteUse.headless, site: siteId));

  @override
  List<WakeCandidate> wakeCandidates() => [
    for (final m in world.sites.models)
      WakeCandidate(
        site: WakeSite(siteId: m.siteId, name: m.name),
        notificationsEnabled: world.wakes,
        live: world.sites.loaded.contains(m),
        headlessBlocked:
            world.page.containers ? null : WakeSkip.legacyIsolation,
      ),
  ];

  @override
  Future<void> reload(SiteId siteId) async {}

  @override
  Future<bool> applyRoute(SiteId siteId) async {
    if (world.proxies?.scope != WalkScope.global) return true;
    try {
      await world._route.claim(
        (use: RouteUse.headless, site: siteId),
        route: ProxyConflictEngine.routeOf(
          siteOf(siteId).proxySettings,
          siteId: siteId,
        ),
        write: world._writeRule,
      );
    } on ProxyRefused {
      return false;
    }
    return true;
  }

  @override
  void releaseRoute() => world._route.releaseEvery(RouteUse.headless);

  @override
  Future<WakeSkip?> openHeadless(SiteId siteId) async {
    final ended = Completer<void>();
    _opening.add(ended.future);
    try {
      await world.gate.pace(PlatformCall.headlessOpen);
      return world.sites.fore ? WakeSkip.appInForeground : null;
    } finally {
      _opening.remove(ended.future);
      ended.complete();
    }
  }

  @override
  Future<void> closeHeadless(SiteId siteId) => world._route.vacate(
    [(use: RouteUse.headless, site: siteId)],
    close: () => world.gate.pace(PlatformCall.headlessClose),
  );

  @override
  bool? isLoading(SiteId siteId) => false;

  @override
  Future<String?> title(SiteId siteId) async => null;

  @override
  bool postedSince(SiteId siteId, {required DateTime since}) => false;

  @override
  Future<void> post({
    required SiteId siteId,
    required String siteName,
    required String body,
  }) async {}

  @override
  DateTime now() => _now;

  @override
  Future<void> delay(Duration d) async {
    _now = _now.add(d);
    if (paced) return;
    paced = true;
    await world.gate.pace(PlatformCall.wakeSettle);
  }
}

/// The page's `_ResidencyHost` (webspace_page.dart), forwarding to the same
/// [SiteRuntime] methods.
final class _WalkResidency implements ResidencyHost {
  @override
  ResidencyCaps get caps => world.caps;

  _WalkResidency(this.world);

  final ActivationWorld world;

  @override
  List<WebViewModel> get models => world.sites.models;

  @override
  RuntimeVars<WebViewModel> get vars => world.sites.vars;

  @override
  Isolation get isolation => world.sites.isolation;

  @override
  NavCapture? beginNavCapture(WebViewModel model) =>
      world.activation.beginNavCapture(model);

  @override
  void noteUnloaded(WebViewModel model, {required UnloadReason reason}) =>
      world._noteUnloaded(model, reason: reason);

  @override
  List<WebViewModel> identities({int? except}) =>
      world.sites.slotIdentities(except: except);

  @override
  SiteRetentionPriority priorityOf(int index) =>
      world.sites.retentionPriority(index);

  @override
  ProxyTopology get proxyTopology => ProxyTopology.of(
    linux: false,
    android: world.proxies?.scope != WalkScope.session &&
        world.proxies != null,
    routerActive: world.proxies?.scope == WalkScope.router,
    sharesDefaultSession: world._inDefaultSession,
  );

  @override
  bool get torAvailable => world._torRuntime;
}

/// The page's answers to the tab handlers, minus the widgets: a tab flow's
/// activation is the world's, so the walk sees it as it sees a tap; a
/// rebuild only draws, and the rebind's frame is built at its mark.
final class _WalkTabsHost implements TabsHost {
  _WalkTabsHost(this.world);

  final ActivationWorld world;

  @override
  bool get mounted => true;

  @override
  void rebuild() => world._drawn = world.sites.shown;

  @override
  void toast(
    String Function(AppLocalizations loc) message, {
    Duration duration = const Duration(seconds: 4),
    bool floating = false,
  }) {}

  @override
  Future<void> commitSites(SiteSetChange change) => world._commit(change);

  @override
  NavCapture? beginNavCapture(WebViewModel model) =>
      world.activation.beginNavCapture(model);

  @override
  void cancelPendingCapture(SiteId siteId) {}

  @override
  void evictCache(SiteId siteId) {}

  @override
  void enterFullscreen() {}

  /// Its own flow: it runs beside the handler that asked for it.
  @override
  Future<void> activate(WebViewModel site) =>
      inFlow(flow: world._nextSpawned--, () => world._activate(site));

  @override
  Future<void> saveCurrentIndex() async {}

  @override
  Future<void> saveSelectedWebspace() async {}

  @override
  Future<void> revealSite(WebViewModel model) async {}

  @override
  void offerOpenTab(WebViewModel model, {required TabId tabId}) {}

  @override
  List<DispatchableSite> tabHostsIn(
    WebViewModel owner, {
    required WebViewModel opener,
  }) => [
    for (final m in world.sites.models)
      if (!identical(m, opener) &&
          (identical(m, owner) || world.tabs.mayHost(m, owner: owner)))
        SiteRoute(m),
  ];

  @override
  void noteUnloaded(WebViewModel model, {required String why}) =>
      world.unloads.add('${model.siteId}:$why');
}

/// The page as an archive sees it: its commits land as the page's
/// `_commitSites` does, after a turn of the page's own queue; a frame is
/// waited for and unmounts what is no longer loaded.
final class _WalkArchiveHost implements ArchiveHost {
  _WalkArchiveHost(this.world);

  final ActivationWorld world;

  @override
  bool get mounted => true;

  @override
  void rebuild() => world._drawn = world.sites.shown;

  @override
  void toast(
    String Function(AppLocalizations loc) message, {
    Duration duration = const Duration(seconds: 4),
    bool floating = false,
  }) {}

  @override
  Future<void> commitSites(SiteSetChange change) async {
    await world.gate.pace(PlatformCall.siteSetCommit);
    if (change is ArchiveClosed) world._noteRowsAtDrop(overwrite: true);
    await world._commit(change);
  }

  @override
  SiteSetStage stageSites(SiteSetChange change) => _WalkStage(
    world,
    change: change,
    before: () => world._noteRowsAtDrop(overwrite: change is ArchiveClosed),
  );

  @override
  Future<List<Cookie>> captureCookies(WebViewModel model) async =>
      List.of(model.cookies);

  @override
  Future<void> endOfFrame() async {
    await world.gate.pace(PlatformCall.frame);
    world._unmountGone();
  }
}

/// The page's side of a delete: its commit, the funnel the page runs, and
/// the frame it waits for.
final class _WalkDeletionHost implements SiteDeletionHost {
  _WalkDeletionHost(this.world);

  final ActivationWorld world;

  @override
  bool get mounted => true;

  @override
  void rebuild() => world._drawn = world.sites.shown;

  @override
  void toast(
    String Function(AppLocalizations loc) message, {
    Duration duration = const Duration(seconds: 4),
    bool floating = false,
  }) {}

  @override
  Future<void> commitSites(SiteSetChange change) async {
    await world.gate.pace(PlatformCall.siteSetCommit);
    world._noteRowsAtDrop(overwrite: false);
    await world._commit(change);
  }

  @override
  SiteSetStage stageSites(SiteSetChange change) => _WalkStage(
    world,
    change: change,
    before: () => world._noteRowsAtDrop(overwrite: false),
  );

  @override
  Future<void> endOfFrame() async {
    await world.gate.pace(PlatformCall.frame);
    world._unmountGone();
  }
}

/// The page's funnel run in parts, behind the platform reply the walk
/// paces: the drop's call waits on it, then the funnel's own preparation.
final class _WalkStage implements SiteSetStage {
  _WalkStage(
    this.world, {
    required SiteSetChange change,
    required void Function() before,
  }) : _inner = world._siteSetCommit.stage(change),
       _before = before;

  final ActivationWorld world;
  final SiteSetStage _inner;
  final void Function() _before;

  @override
  Future<void> prepare() async {
    await world.gate.pace(PlatformCall.siteSetCommit);
    _before();
    await _inner.prepare();
  }

  @override
  void land({required Commit commit}) => _inner.land(commit: commit);

  @override
  Future<void> follow() => _inner.follow();
}

/// A passphrase for every archive, and yes to creating one.
final class _WalkArchivePrompts implements ArchivePrompts {
  const _WalkArchivePrompts();

  @override
  Future<String?> passphrase(PassphrasePurpose purpose) async => 'walk';

  @override
  Future<bool> createArchive(PassphrasePurpose purpose) async => true;

  @override
  Future<bool> includeOpenArchives(int count) async => false;
}

/// Stand-in for Argon2id: a pure function of passphrase and salt, in
/// microseconds (archive_test.dart pins the real derivation).
Future<Uint8List> _deriveArchiveKey(
  String passphrase, {
  required Uint8List? salt,
}) {
  final material = Uint8List(32);
  final src = salt ?? Uint8List.fromList(utf8.encode('legacy-salt'));
  for (var i = 0; i < material.length; i++) {
    material[i] = src[i % src.length];
  }
  return ArchiveCrypto.hmac(material, info: passphrase);
}
