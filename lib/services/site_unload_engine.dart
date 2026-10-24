import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/nav_capture.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/proxy_conflict_engine.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

/// Default cap on concurrently loaded webviews. Keeps memory bounded when
/// container mode lets sites stay resident across webspace switches; without
/// it, a heavy user could accumulate dozens of live native webviews.
const int kMaxLoadedSites = 20;

/// Why a loaded site leaves the loaded set, short of being deleted. The label
/// is what the background log names (DEVTOOLS-012).
enum UnloadReason {
  domainConflict('domain conflict'),
  proxyMismatch('proxy mismatch'),
  torExitMismatch('Tor exit-country mismatch'),
  loadedSiteCap('loaded-site cap'),
  memoryPressure('memory pressure'),
  webspaceSwitch('webspace switch'),

  /// An always-open-home or incognito site sent back to its home page: by a
  /// shortcut launch, or before a link opens in it (LIR-011).
  homeReset('home reset');

  const UnloadReason(this.label);

  final String label;

  /// Whether the back stack is saved for the next activation (PAUSE-007).
  bool get keepsNavState => switch (this) {
    UnloadReason.domainConflict ||
    UnloadReason.proxyMismatch ||
    UnloadReason.torExitMismatch ||
    UnloadReason.loadedSiteCap ||
    UnloadReason.memoryPressure ||
    UnloadReason.webspaceSwitch => true,
    // It goes back to its home page, which is the point (always-open-home).
    UnloadReason.homeReset => false,
  };

  /// Whether the plan chose the site rather than being bound to unload it:
  /// retention priority's picks, a webspace switch's (WEBSPACE-013) and a
  /// home reset's.
  /// A choice spares the site on screen and an activation's target when it
  /// is made, and backs off if its site has become one of them by the time
  /// it would be disposed (PAUSE-006, BUG-033).
  bool get chosen => switch (this) {
    UnloadReason.loadedSiteCap ||
    UnloadReason.memoryPressure ||
    UnloadReason.webspaceSwitch ||
    UnloadReason.homeReset => true,
    UnloadReason.domainConflict ||
    UnloadReason.proxyMismatch ||
    UnloadReason.torExitMismatch => false,
  };

  /// An unload the user did not ask for and will notice logs as a warning.
  LogLevel get logLevel => switch (this) {
    UnloadReason.domainConflict ||
    UnloadReason.proxyMismatch ||
    UnloadReason.torExitMismatch ||
    UnloadReason.memoryPressure => LogLevel.warning,
    UnloadReason.loadedSiteCap ||
    UnloadReason.webspaceSwitch ||
    UnloadReason.homeReset => LogLevel.info,
  };
}

/// What [SiteUnloadEngine.unloadFlow] reads and writes on the page.
abstract interface class SiteUnloadHost {
  List<WebViewModel> get models;

  /// The runtime's variables: the loaded sites, which an unload's dispose
  /// takes its site out of, and the site on screen and the activation in
  /// flight, which say whether a site may go.
  RuntimeVars<WebViewModel> get vars;

  /// Under containers each site's jar is its own; the legacy engine's sites
  /// share one, which an unload captures from in its turn.
  Isolation get isolation;

  /// A capture of [model]'s back stack for its next activation; null when
  /// it keeps none.
  NavCapture? beginNavCapture(WebViewModel model);

  void noteUnloaded(WebViewModel model, {required UnloadReason reason});

  /// How hard the site at [index] is to evict, read again when an unload
  /// [UnloadReason.chosen] reaches its dispose.
  SiteRetentionPriority priorityOf(int index);
}

/// What [SiteUnloadEngine.plan] reads beyond what an unload needs.
/// How many sites may stay loaded, and how many of those resident before
/// the proactive cache clear; a test runs smaller ones so its few sites
/// reach them (`MaxLoaded`, `MaxResident`).
typedef ResidencyCaps = ({int loaded, int resident});

/// The caps a device runs with.
const ResidencyCaps kResidencyCaps = (
  loaded: kMaxLoadedSites,
  resident: kMaxResidentSites,
);

abstract interface class ResidencyHost implements SiteUnloadHost {
  ResidencyCaps get caps;

  /// What each slot runs as (LIR-024): a slot showing a hosted tab reads as
  /// its host. The slot at [except] reads as its own site.
  List<WebViewModel> identities({int? except});

  ProxyTopology get proxyTopology;

  /// Whether a Tor runtime exists here, so loaded sites can disagree about
  /// its exit country (TOR-014).
  bool get torAvailable;
}

/// What can change which sites stay loaded. [SiteUnloadEngine.plan] answers
/// every kind in one switch, so a new event is a case it must handle.
sealed class ResidencyEvent {
  const ResidencyEvent();
}

/// [target] is about to be shown: the loaded sites it conflicts with go
/// (ISO-001, PROXY-008, TOR-014), then whatever the loaded-site cap and the
/// resident cap take (PAUSE-012).
final class Activating extends ResidencyEvent {
  const Activating(this.target);

  final int target;
}

/// The selected webspace changed, and stopped showing the sites at
/// [leaving]. Only a shared cookie jar unloads for it (CONT-003), and only
/// the ones that may go (WEBSPACE-013).
final class WebspaceSwitched extends ResidencyEvent {
  const WebspaceSwitched({required this.leaving});

  final Set<int> leaving;
}

/// A setting changed under loaded sites: the first Tor site in [order]
/// decides the exit pin, and the loaded Tor sites that want another go
/// before it is put in force (TOR-014).
final class TorExitSettled extends ResidencyEvent {
  const TorExitSettled(this.order);

  final Iterable<int> order;
}

/// A nested screen is about to run as [target] under its proxy, which
/// loaded sites contending for the same proxy cannot share (SEC-004).
final class NestedOpening extends ResidencyEvent {
  const NestedOpening(this.target);

  final int target;
}

/// The slot on screen at [slot] now runs as another site, so its proxy may
/// have changed under its contenders (LIR-024).
final class SlotIdentityChanged extends ResidencyEvent {
  const SlotIdentityChanged(this.slot);

  final int slot;
}

/// What a [ResidencyEvent] does to the loaded sites. Sites rather than
/// positions: a delete can shift the list while the plan runs.
final class ResidencyPlan {
  const ResidencyPlan({this.unloads = const [], this.cacheClears = const []});

  static const none = ResidencyPlan();

  /// In the order they run.
  final List<({WebViewModel site, UnloadReason reason})> unloads;

  /// Resident sites whose cache is cleared once the unloads ran.
  final List<WebViewModel> cacheClears;

  bool get isEmpty => unloads.isEmpty && cacheClears.isEmpty;
}

/// How the host scopes a proxy, which decides who contends for it when a
/// site with another proxy activates (PROXY-008, PROXY-013). Built only by
/// [ProxyTopology.of], so no caller can name a topology the host and the
/// router state did not produce.
sealed class ProxyTopology {
  const ProxyTopology();

  /// Whether a site running as [model] shares the proxy scope another site's
  /// activation repoints (`Contending` in the model).
  bool contends(WebViewModel model) => switch (this) {
    PerSessionProxy() => false,
    ProcessGlobalProxy() => true,
    RoutedProxy(:final sharesDefaultSession) => sharesDefaultSession(model),
  };

  /// Where the [binding] puts a proxy, until the router runs (Android only);
  /// [sharesDefaultSession] then names the sites that still share one
  /// credential.
  factory ProxyTopology.of({
    required ProxyBinding binding,
    required bool routerActive,
    required bool Function(WebViewModel model) sharesDefaultSession,
  }) {
    if (routerActive) return RoutedProxy._(sharesDefaultSession);
    return switch (binding) {
      ProxyBinding.perSite => const PerSessionProxy._(),
      ProxyBinding.processWide => const ProcessGlobalProxy._(),
    };
  }
}

/// iOS, macOS and Linux bind a proxy per session: nothing contends.
final class PerSessionProxy extends ProxyTopology {
  const PerSessionProxy._();
}

/// Android without the router: one process-global, last-write-wins override
/// (`ProxyController`). Every loaded site contends.
final class ProcessGlobalProxy extends ProxyTopology {
  const ProcessGlobalProxy._();
}

/// Router mode (PROXY-013): the process-wide rule names the loopback relay
/// and each site presents its own credential, bought by its container
/// profile. A site with no profile runs in the default one, whose single
/// cached credential every other such site presents too, so exactly that
/// group still contends.
final class RoutedProxy extends ProxyTopology {
  const RoutedProxy._(this.sharesDefaultSession);

  final bool Function(WebViewModel model) sharesDefaultSession;
}

/// What the proxy and Tor rules read: the sites by row, the site each slot
/// runs as by row, the rows whose traffic runs (loaded, or up in a nested
/// screen), and how the host scopes a proxy.
typedef ProxySlots = ({
  List<WebViewModel> sites,
  List<WebViewModel> slots,
  Set<int> running,
  ProxyTopology topology,
});

/// Pure-Dart unload policy engine.
///
/// Owns the three orthogonal "should this site be unloaded?" rules:
///
///   1. Webspace switch — under legacy isolation only, sites visible only in
///      the previous webspace are unloaded so the shared cookie jar stays
///      clean. Under container isolation, sites stay resident across
///      switches.
///   2. Proxy mismatch — on Android, the WebView proxy is process-global
///      (`inapp.ProxyController` last-write-wins). Activating a site with a
///      different effective proxy would silently re-route any other loaded
///      site's next request through the new proxy, defeating the user's
///      per-site proxy choice. Force-unload conflicting sites so they can't
///      leak.
///   3. LRU cap — bound the number of concurrently loaded webviews so memory
///      stays under control. Uses [SiteRetentionPriority] to decide eviction
///      order: lowest priority (highest enum index) first, LRU within each
///      tier.
class SiteUnloadEngine {
  /// Every rule deciding which loaded sites go, and in what order, for
  /// [event]. Each rule reads the loaded set the rules before it leave.
  static ResidencyPlan plan(
    ResidencyHost host, {
    required ResidencyEvent event,
  }) {
    final models = host.models;
    // Rows hold for the plan, which awaits nothing; it names sites.
    final loaded = {for (final m in host.vars.loaded.value) models.indexOf(m)};
    final unloads = <({WebViewModel site, UnloadReason reason})>[];
    void unload(Iterable<int> indices, {required UnloadReason reason}) {
      for (final i in indices.toList()) {
        if (i < 0 || i >= models.length || !loaded.remove(i)) continue;
        unloads.add((site: models[i], reason: reason));
      }
    }

    Set<int> proxyContenders(int target, {int? except}) =>
        indicesToUnloadForProxyMismatch(
          targetIndex: target,
          sites: models,
          models: host.identities(except: except),
          loadedIndices: loaded,
          topology: host.proxyTopology,
        );
    Set<int> torDissenters(int anchor) => host.torAvailable
        ? indicesToUnloadForTorExitMismatch(
            targetIndex: anchor,
            sites: models,
            models: host.identities(),
            loadedIndices: loaded,
          )
        : const {};
    Map<int, SiteLifecycleState> tiers() => {
      for (final i in loaded)
        if (i >= 0 && i < models.length) i: models[i].lifecycleState,
    };

    switch (event) {
      case Activating(:final target):
        unload(
          [
            for (final m in conflictsOf(host, site: models[target]))
              models.indexOf(m),
          ],
          reason: UnloadReason.domainConflict,
        );
        unload(proxyContenders(target), reason: UnloadReason.proxyMismatch);
        unload(torDissenters(target), reason: UnloadReason.torExitMismatch);
        unload(
          indicesToEvictForLruCap(
            targetIndex: target,
            loadedIndices: loaded,
            maxLoadedSites: host.caps.loaded,
            priorityOf: host.priorityOf,
          ),
          reason: UnloadReason.loadedSiteCap,
        );
        final cacheClears =
            SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
              loadedIndices: loaded,
              states: tiers(),
              maxResidentSites: host.caps.resident,
              priorityOf: host.priorityOf,
            );
        return ResidencyPlan(
          unloads: unloads,
          cacheClears: [for (final i in cacheClears) models[i]],
        );
      case WebspaceSwitched(:final leaving):
        unload(
          indicesToUnloadOnWebspaceSwitch(
            useContainers: host.isolation is Containers,
            loadedIndices: loaded,
            leaving: leaving,
          ).where((i) => host.vars.isEvictable(models[i])),
          reason: UnloadReason.webspaceSwitch,
        );
      case TorExitSettled(:final order):
        final anchor = torExitAnchor(indices: order, models: host.identities());
        if (anchor != null) {
          unload(torDissenters(anchor), reason: UnloadReason.torExitMismatch);
        }
      case NestedOpening(:final target):
        // The nested screen runs as [target] itself, whatever its slot shows.
        unload(
          proxyContenders(target, except: target),
          reason: UnloadReason.proxyMismatch,
        );
        unload(torDissenters(target), reason: UnloadReason.torExitMismatch);
      case SlotIdentityChanged(:final slot):
        unload(proxyContenders(slot), reason: UnloadReason.proxyMismatch);
    }
    return ResidencyPlan(unloads: unloads);
  }

  /// The loaded sites [site] cannot share the jar with: those on its base
  /// domain, under the legacy engine (ISO-001); under containers each site's
  /// jar is its own, so same-base-domain sites coexist (CONT-003), and an
  /// incognito site keeps nothing in the jar.
  static final conflicts = () {
    final loaded = Var<Iterable<WebViewModel>, SiteUnloadHost>(
      ModelVar.loaded,
      read: (w) => w.vars.loaded.value,
    );
    final containers = Constant<bool, SiteUnloadHost>(
      ModelConst.containers,
      read: (w) => w.isolation is Containers,
    ).value;
    final base = baseOf<SiteUnloadHost>();
    final incognito = incognitoOf<SiteUnloadHost>();
    const s = Bound<WebViewModel, SiteUnloadHost>('s');
    const t = Bound<WebViewModel, SiteUnloadHost>('t');
    return Def<List<WebViewModel>, SiteUnloadHost>(
      ModelDef.conflicts,
      params: const [s],
      body: Expr.choose(
        when: containers | incognito.has(s.it),
        then: Expr.none(),
        otherwise: loaded.value
            .minus(incognito)
            .where(
              t,
              holds: t.it.neq(s.it) & base.at(t.it).eq(base.at(s.it)),
            ),
      ),
    );
  }();

  static List<WebViewModel> conflictsOf(
    SiteUnloadHost host, {
    required WebViewModel site,
  }) => conflicts.evaluate(host, args: [site]);

  /// Runs [plan] through [unloadFlow]. A site no longer loaded when its
  /// turn comes is skipped. False when [isStale] turned true across an
  /// await, in which case the rest of the plan did not run.
  static Future<bool> apply(
    SiteUnloadHost host, {
    required ResidencyPlan plan,
    required bool Function() isStale,
  }) async {
    final flow = _start(
      host,
      plan: plan,
      isStale: isStale,
      victims: [for (final u in plan.unloads) u.site],
    );
    final left = await unloadFlow.run(
      flow,
      from: _afterUnloads(
        victims: _victims.value,
        clears: _clears.value,
      ).run(flow),
    );
    if (left == UnloadPlace.exit) return false;
    ActivationSteps.mark(ActivationStep.applied);
    return true;
  }

  static StepContext<UnloadFlow> _start(
    SiteUnloadHost host, {
    required ResidencyPlan plan,
    required bool Function() isStale,
    required List<WebViewModel> victims,
  }) {
    final flow = StepContext(
      UnloadFlow(host: host, plan: plan, isStale: isStale),
    );
    _victims.put(flow, value: victims);
    _clears.put(flow, value: plan.cacheClears);
    _pickedVictims.put(flow, value: pickedOf(plan));
    return flow;
  }

  /// The sites [plan] chose, which an unload asks again about before it
  /// disposes (`fl[f].picked`).
  static List<WebViewModel> pickedOf(ResidencyPlan plan) => [
    for (final u in plan.unloads)
      if (u.reason.chosen) u.site,
  ];

  // ── The steps ───────────────────────────────────────────────────────────

  static const _victims = Field<List<WebViewModel>, UnloadFlow>(FlowField.victims);
  static const _clears = Field<List<WebViewModel>, UnloadFlow>(FlowField.clears);
  static const _pickedVictims = Field<List<WebViewModel>, UnloadFlow>(FlowField.picked);
  static const _victim = Field<WebViewModel, UnloadFlow>(FlowField.victim);
  static final _eachVictim = Pick(_victims.value);
  static final _eachClear = Pick(_clears.value);
  static final _loaded = Mutable<Iterable<WebViewModel>, UnloadFlow>.over(
    ModelVar.loaded,
    of: (w) => w.host.vars.loaded,
  );
  static final _tier = tierOf<UnloadFlow>();

  /// What the plan's maker answers and the page is told, none of it the
  /// model's: the activation's `Stale`, run by name, a victim's reason, the
  /// note of its dispose and the start of its capture, and the isolation
  /// the jar's steps are nested under.
  static final _plan = Port<PlanAnswers, UnloadFlow>(
    'plan',
    reads: const {},
    changes: const {},
    of: (w) => (
      isStale: w.isStale,
      reasonOf: w.reasonOf,
      disposed: w.disposed,
      beginNavCapture: w.host.beginNavCapture,
      isolation: w.host.isolation,
    ),
  );

  /// The runtime's variables, for the definitions over them run by name.
  static final _vars = RuntimeVars.port<WebViewModel, UnloadFlow>(
    reads: {ModelVar.marker, ModelVar.version},
    of: (w) => w.host.vars,
  );

  /// The plan was superseded: the plan's maker says (the activation's
  /// `Stale`; a plan outside the model, a settings save's or a tab's,
  /// carries its own).
  static final stale = ModelDef.stale.ofFlow<bool, UnloadFlow>(
    run: (c) => _plan.from(c).isStale(),
  );

  /// The plan chose the victim: a pressure plan's pick, the loaded-site
  /// cap's, or a webspace switch's (UnloadReason.chosen).
  static final picked = Def<bool, UnloadFlow>.ofFlow(
    ModelDef.picked,
    body: _pickedVictims.value.has(_victim.value),
  );
  static final _picked = picked.value;
  static final _evictable = ModelDef.evictable.over<bool, UnloadFlow>(
    [_victim.value],
    run: (c) => _vars.from(c).isEvictable(_victim.of(c)),
  );

  /// Asked again just before the dispose, with no await between them: a
  /// superseded plan's unload backs off, and so does one picked by priority
  /// whose site is no longer evictable (BUG-033). [stale] and [retry] name
  /// the disjuncts, so a mutant of the rule is one left out.
  static Def<bool, UnloadFlow> spareOf({
    required bool stale,
    required bool retry,
  }) => Def.ofFlow(
    ModelDef.spare,
    body: [
      if (stale) SiteUnloadEngine.stale,
      if (retry) _picked & ~_evictable,
    ].reduce((a, b) => a | b),
  );
  static final spare = spareOf(stale: true, retry: true);
  static final _spare = spare.value;

  /// The victim left the loaded sites while the unload waited: another plan
  /// disposed it, or a delete took it. Asked at every wait, so a site
  /// captured when it left is never captured again over a jar refilled
  /// without it (BUG-032).
  static final gone = Def<bool, UnloadFlow>.ofFlow(
    ModelDef.gone,
    body: ~_loaded.value.has(_victim.value),
  );
  static final _containers = Constant<bool, UnloadFlow>(
    ModelConst.containers,
    read: (w) => w.host.isolation is Containers,
  ).value;
  static Expr<bool, UnloadFlow> _resident(Expr<WebViewModel, UnloadFlow> s) =>
      _tier.at(s).eq(Expr.constant(SiteLifecycleState.resident));
  static final _dispose = disposeOf<UnloadFlow>(
    _victim,
    over: (
      loaded: _loaded,
      picked: _picked,
      current: Var<WebViewModel?, UnloadFlow>(
        ModelVar.current,
        read: (w) => w.host.vars.current.value,
      ).value,
      liveTarget: Expr.op(
        HandPaired.unloadLiveTarget,
        tla: 'LiveTarget',
        run: (c) => _vars.from(c).liveTarget,
        reads: const Reads(base: {BaseOp.liveTarget}),
      ),
    ),
    then: (c) => _plan.from(c).disposed(_victim.of(c)),
  );
  static final _clearTier = Act.of([
    _tier.except(
      _victim.value,
      to: Expr.constant(SiteLifecycleState.cacheCleared, tla: '"cleared"'),
    ),
  ]);

  /// Where the plan goes on once a victim or a clear is spent: the next of
  /// either, else back to the activation. One rule for every table that
  /// runs the plan, each naming its own places.
  static Expr<P, W> afterUnloads<P extends Enum, W>({
    required Expr<List<WebViewModel>, W> victims,
    required Expr<List<WebViewModel>, W> clears,
    required P next,
    required P nextClear,
    required P applied,
  }) => Expr.choose(
    when: ~victims.isEmpty,
    then: to(next),
    otherwise: Expr.choose(
      when: ~clears.isEmpty,
      then: to(nextClear),
      otherwise: to(applied),
    ),
  );

  static Expr<UnloadPlace, UnloadFlow> _afterUnloads({
    required Expr<List<WebViewModel>, UnloadFlow> victims,
    required Expr<List<WebViewModel>, UnloadFlow> clears,
  }) => afterUnloads(
    victims: victims,
    clears: clears,
    next: UnloadPlace.next,
    nextClear: UnloadPlace.nextClear,
    applied: UnloadPlace.applied,
  );

  /// The jar's places are the jar engine's table, run in the jar's turn
  /// over a view of this flow (ISO-002).
  static Future<UnloadPlace> _inJar(
    StepView<UnloadFlow> c, {
    required UnloadPlace from,
  }) => switch (_plan.from(c).isolation) {
    SharedJar(:final jar) => jar.unloadInTurn(
      StepContext.sharing(
        c,
        world: UnloadWorld(
          engine: jar,
          vars: _vars.from(c),
          answers: (
            spared: () => _spare.run(c),
            disposed: () => _plan.from(c).disposed(_victim.of(c)),
            picked: () => _picked.run(c),
            gone: () => gone.value.run(c),
          ),
        ),
      ),
      from: from,
    ),
    Containers() => throw StateError(
      'a flow at ${from.name} under containers: the jar\'s places are '
      'reached only by the jar path out of uNav',
    ),
  };

  /// The plan's unloads, then its cache clears.
  /// The victim's back stack captured before it goes, when its reason
  /// keeps one.
  static final _capture = captureSteps<WebViewModel, UnloadFlow, UnloadPlace>(
    names: (read: ActivationStep.unloadNavReply, save: ActivationStep.unloadNavSave),
    places: (save: UnloadPlace.uNavSave, after: to(UnloadPlace.uCaptured)),
    of: (
      site: _victim.value,
      built: (s) => s.tabBinding.built,
      hosts: (s) => s.tabHosts,
      begin: (c) {
        final site = _victim.of(c);
        final plan = _plan.from(c);
        final reason = plan.reasonOf(site);
        LogService.instance.log(
          LogTag.siteUnload,
          message: 'Unloading site "${site.name}": ${reason.label}',
          level: reason.logLevel,
          sensitivity: LogSensitivity.sensitive,
        );
        return _keeps.run(c) ? plan.beginNavCapture(site) : null;
      },
      marks: _victim.value,
      keeps: _keeps,
    ),
  );

  /// Whether the victim's reason keeps its back stack (PAUSE-007): a home
  /// reset's does not, which the model knows by its flow's kind.
  static final _keeps = () {
    final notReset = const Field<FlowKind, UnloadFlow>(FlowField.kind).value
        .neq(Expr.constant(FlowKind.unload));
    return Expr.handPaired<bool, UnloadFlow>(
      HandPaired.unloadKeeps,
      tla: notReset.tla,
      run: (c) {
        final keeps = _plan.from(c).reasonOf(_victim.of(c)).keepsNavState;
        assert(
          !const Field<FlowKind, UnloadFlow>(FlowField.kind).isSet(c) ||
              keeps == notReset.run(c),
          'a home reset, and no other unload, keeps no back stack',
        );
        return keeps;
      },
      reads: notReset.reads,
    );
  }();

  static final unloadFlow = StepTable<UnloadFlow, UnloadPlace>(
    UnloadPlace.values,
    awaited: {UnloadPlace.afterUnload},
    vars: [_loaded],
    at: (place) => switch (place) {
      // The next site of the plan, unloaded if still loaded.
      UnloadPlace.next => Step(
        ActivationStep.nextUnload,
        holds: null,
        pick: _eachVictim,
        site: _eachVictim.it,
        branches: [
          Branch(
            StepOutcome.skip,
            when: ~_loaded.value.has(_eachVictim.it),
            then: [_victims.becomes(_victims.value.without(_eachVictim.it))],
            next: _afterUnloads(
              victims: _victims.value.without(_eachVictim.it),
              clears: _clears.value,
            ),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.unload,
          then: [
            _victims.becomes(_victims.value.without(_eachVictim.it)),
            _victim.becomes(_eachVictim.it),
          ],
          next: to(UnloadPlace.uNav),
        ),
      ),
      // The victim's back stack captured, in the capture's two steps.
      UnloadPlace.uNav => _capture.read,
      UnloadPlace.uNavSave => _capture.save,
      // The container path disposes here, the jar path waits for the jar's
      // turn.
      UnloadPlace.uCaptured => Step(
        ActivationStep.unloadCaptured,
        holds: null,
        site: _victim.value,
        branches: [
          Branch(
            StepOutcome.gone,
            when: gone.value,
            then: unloadReturn(_victim, disposed: false),
            next: to(UnloadPlace.afterUnload),
          ),
          Branch(
            StepOutcome.spared,
            when: _spare,
            then: [backoff(), ...unloadReturn(_victim, disposed: false)],
            next: to(UnloadPlace.afterUnload),
          ),
          Branch(
            StepOutcome.disposed,
            when: _containers,
            then: [
              _dispose,
              evictedMid(),
              ...unloadReturn(_victim, disposed: true),
            ],
            next: to(UnloadPlace.afterUnload),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.queued,
          then: [
            modelOnly(
              'Enqueue(f)',
              writes: {ModelVar.queue, ModelVar.seen},
              reads: const Reads(base: {BaseOp.enqueue}),
            ),
          ],
          next: to(UnloadPlace.uTurn),
        ),
      ),
      UnloadPlace.uTurn ||
      UnloadPlace.uCap ||
      UnloadPlace.uSave ||
      UnloadPlace.uKept => const Within(_inJar),
      // isStale between unloads.
      UnloadPlace.afterUnload => Step(
        ActivationStep.afterUnload,
        holds: null,
        branches: [
          Branch(
            StepOutcome.stale,
            when: stale,
            then: [],
            next: to(UnloadPlace.exit),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [],
          next: _afterUnloads(victims: _victims.value, clears: _clears.value),
        ),
      ),
      // The plan's next cache clear, run if the site is still a loaded
      // resident.
      UnloadPlace.nextClear => Step(
        ActivationStep.nextClear,
        holds: null,
        pick: _eachClear,
        site: _eachClear.it,
        branches: [
          Branch(
            StepOutcome.clear,
            when: _loaded.value.has(_eachClear.it) & _resident(_eachClear.it),
            then: [
              _clears.becomes(_clears.value.without(_eachClear.it)),
              _victim.becomes(_eachClear.it),
            ],
            next: to(UnloadPlace.cc),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.skip,
          then: [_clears.becomes(_clears.value.without(_eachClear.it))],
          next: _afterUnloads(
            victims: _victims.value,
            clears: _clears.value.without(_eachClear.it),
          ),
        ),
      ),
      // clearWebViewCache returns: the site moves to "cleared" if it is
      // still a loaded resident; a concurrent path may have promoted or
      // unloaded it meanwhile.
      UnloadPlace.cc => Step(
        ActivationStep.cacheReply,
        holds: null,
        call: Call(
          run: (c) {
            final site = _victim.of(c);
            LogTag.siteUnload.debug(
              'Clearing the cache of site "${site.name}"',
              sensitive: true,
            );
            return site.clearWebViewCache();
          },
          writes: const [],
        ),
        site: _victim.value,
        branches: [
          Branch(
            StepOutcome.stale,
            when: stale,
            then: [_victim.cleared(none: 0)],
            next: to(UnloadPlace.exit),
          ),
          Branch(
            StepOutcome.cleared,
            when: _loaded.value.has(_victim.value) & _resident(_victim.value),
            then: [_clearTier, _victim.cleared(none: 0)],
            next: _afterUnloads(victims: _victims.value, clears: _clears.value),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.kept,
          then: [_victim.cleared(none: 0)],
          next: _afterUnloads(victims: _victims.value, clears: _clears.value),
        ),
      ),
      UnloadPlace.applied || UnloadPlace.exit => const Leaves(),
    },
  );

  /// The loaded sites a webspace switch leaves behind: none under
  /// containers, where each keeps its own jar; on the shared jar, those it
  /// stops showing.
  static Set<int> indicesToUnloadOnWebspaceSwitch({
    required bool useContainers,
    required Set<int> loadedIndices,
    required Set<int> leaving,
  }) => useContainers ? const <int>{} : loadedIndices.intersection(leaving);

  /// The running sites [site]'s activation would repoint the proxy of:
  /// [site] read as the site its slot runs as, or as itself for a nested
  /// screen ([asItself]).
  static List<WebViewModel> proxyContendersOf(
    ResidencyHost host, {
    required WebViewModel site,
    required bool asItself,
  }) {
    final row = host.models.indexOf(site);
    return [
      for (final i in indicesToUnloadForProxyMismatch(
        targetIndex: row,
        sites: host.models,
        models: host.identities(except: asItself ? row : null),
        loadedIndices: _runningRows(host),
        topology: host.proxyTopology,
      ))
        host.models[i],
    ];
  }

  /// The running sites whose Tor exit [site]'s activation would repoint.
  static List<WebViewModel> torDissentersOf(
    ResidencyHost host, {
    required WebViewModel site,
  }) => [
    for (final i in indicesToUnloadForTorExitMismatch(
      targetIndex: host.models.indexOf(site),
      sites: host.models,
      models: host.identities(),
      loadedIndices: _runningRows(host),
    ))
      host.models[i],
  ];

  static Set<int> _runningRows(SiteUnloadHost host) => {
    for (final m in host.vars.running) host.models.indexOf(m),
  };

  /// Sites that must be unloaded because activating [targetIndex] would
  /// repoint a proxy they share out from under them: every mismatched
  /// sibling that contends for it under [topology], so at most one proxy is
  /// ever in force for a contending group. [models] is what each of the
  /// [sites]' slots runs as, the target's included.
  static Set<int> indicesToUnloadForProxyMismatch({
    required int targetIndex,
    required List<WebViewModel> sites,
    required List<WebViewModel> models,
    required Set<int> loadedIndices,
    required ProxyTopology topology,
  }) => _overSlots(
    proxyContenders,
    target: targetIndex,
    slots: (
      sites: sites,
      slots: models,
      running: loadedIndices,
      topology: topology,
    ),
  );

  /// The loaded slots that share the proxy scope the site [a] contends for
  /// and run another route: activating [s] as [a] would repoint their
  /// proxy (PROXY-008). Each slot is read as the site it runs as (LIR-024).
  /// With the site id, two Tor sites differ by their isolation tags, so one
  /// rule never carries both and puts them on one circuit (TOR-003).
  static final proxyContenders = () {
    const s = Bound<int, ProxySlots>('s');
    const a = Bound<int, ProxySlots>('a');
    const t = Bound<int, ProxySlots>('t');
    return Def<List<int>, ProxySlots>(
      ModelDef.proxyContenders,
      params: const [s, a],
      body: Expr.choose(
        when: ~_contending.has(a.it),
        then: Expr.none(),
        otherwise: _slotsRunning.where(
          t,
          holds:
              t.it.neq(s.it) &
              _contending.has(_runsAs(t.it)) &
              _route.at(_runsAs(t.it)).neq(_route.at(a.it)),
        ),
      ),
    );
  }();

  /// The loaded slots whose Tor exit constraint differs from [a]'s, when
  /// [a], the site [s]'s slot runs as, routes through Tor: activating it
  /// repoints the one `ExitNodes`.
  static final torDissenters = () {
    const s = Bound<int, ProxySlots>('s');
    const a = Bound<int, ProxySlots>('a');
    const t = Bound<int, ProxySlots>('t');
    return Def<List<int>, ProxySlots>(
      ModelDef.torDissenters,
      params: const [s, a],
      body: Expr.choose(
        when: _exit.at(a.it).eq(_noExit),
        then: Expr.none(),
        otherwise: _slotsRunning.where(
          t,
          holds:
              t.it.neq(s.it) &
              _exit.at(_runsAs(t.it)).neq(_noExit) &
              _exit.at(_runsAs(t.it)).neq(_exit.at(a.it)),
        ),
      ),
    );
  }();

  /// The row of the site [slot] runs as (`RunsAs`, the tabs' definition).
  static Expr<int, ProxySlots> _runsAs(Expr<int, ProxySlots> slot) =>
      ModelDef.runsAs.over([slot], run: (c) => _rowOf(_world.from(c), slot: slot.run(c)));

  static int _rowOf(ProxySlots w, {required int slot}) {
    final row = w.sites.indexOf(w.slots[slot]);
    assert(row >= 0, 'slot $slot runs as a site that is not listed');
    return row;
  }

  static final _world = Port<ProxySlots, ProxySlots>(
    'world',
    reads: const {},
    changes: const {},
    of: (w) => w,
  );

  /// The slots whose traffic runs, by row, as the proxy rules read them:
  /// the loaded ones and a nested screen's (the model's `Running`).
  static final _slots = Port<Iterable<int>, ProxySlots>(
    'slots',
    reads: const {},
    changes: const {},
    of: (w) => w.running,
  );
  static final _slotsRunning = ModelDef.running.named<Iterable<int>, ProxySlots>(
    run: _slots.from,
  );

  /// The sites that share a contended proxy scope (`Contending`): every
  /// site under a process-global proxy, those in the default session under
  /// the router, none per session.
  static final _contending = Members<int, ProxySlots>(
    ModelConst.contending,
    test: (w, {required member}) => w.topology.contends(w.sites[member]),
  );

  /// The route a site's traffic takes (`Route`): its effective settings.
  static final _route = Indexed<int, ProxyRouteKey, ProxySlots>.fixed(
    ModelConst.route,
    read: (w, {required at}) => ProxyConflictEngine.routeOf(
      w.sites[at].proxySettings,
      siteId: w.sites[at].siteId,
    ),
  );

  /// A site's Tor exit constraint (`TorExit`), `0` when it does not route
  /// through Tor.
  static final _exit = Indexed<int, String?, ProxySlots>.fixed(
    ModelConst.torExit,
    read: (w, {required at}) => _torExitPin(w.sites[at]),
  );
  static final _noExit = Expr.constant<String?, ProxySlots>(null, tla: '0');

  /// [rule] for the slot [target] over [slots], skipping rows no slot has.
  static Set<int> _overSlots(
    Def<List<int>, ProxySlots> rule, {
    required int target,
    required ProxySlots slots,
  }) {
    final n = slots.slots.length;
    if (target < 0 || target >= n) return const <int>{};
    assert(slots.sites.length == n, 'a slot for each site');
    final world = (
      sites: slots.sites,
      slots: slots.slots,
      running: {for (final i in slots.running) if (i >= 0 && i < n) i},
      topology: slots.topology,
    );
    return rule
        .call([
          Expr.constant<int, ProxySlots>(target),
          Expr.constant<int, ProxySlots>(_rowOf(world, slot: target)),
        ])
        .run(StepContext(world))
        .toSet();
  }

  /// Sites that must be unloaded because activating [targetIndex] would
  /// repoint the process-global Tor `ExitNodes` out from under them.
  ///
  /// Same shape as [indicesToUnloadForProxyMismatch] and for the same
  /// reason: `ExitNodes`/`StrictNodes` are global client options in
  /// `tor(1)` — unlike the isolation flags they cannot be scoped to a
  /// `SocksPort`, so one tor cannot serve two countries at once, and iOS
  /// forbids a second process to run a second tor in. Two loaded sites
  /// pinned to different countries would therefore share whichever pin was
  /// written last, which is precisely the silent mis-routing the
  /// fail-closed posture exists to prevent (TOR-014).
  ///
  /// Any difference conflicts, *including* unpinned against pinned. An
  /// unpinned Tor site is not indifferent: leaving it loaded beside a `{de}`
  /// site would route it through Germany too, because there is only one
  /// `ExitNodes` — a country the user never chose for it, silently, on
  /// account of an unrelated site. "No pin" therefore reads as "must be
  /// unrestricted" and is a constraint like any other.
  ///
  /// Sites that do not route through Tor at all are untouched: `ExitNodes`
  /// says nothing about where their traffic goes.
  static Set<int> indicesToUnloadForTorExitMismatch({
    required int targetIndex,
    required List<WebViewModel> sites,
    required List<WebViewModel> models,
    required Set<int> loadedIndices,
  }) => _overSlots(
    torDissenters,
    target: targetIndex,
    slots: (
      sites: sites,
      slots: models,
      running: loadedIndices,
      topology: const PerSessionProxy._(),
    ),
  );

  /// The `ExitNodes` value that should be in force while [indices] are the
  /// loaded sites, or null when nothing among them wants a pinned exit.
  ///
  /// Well-defined only because [indicesToUnloadForTorExitMismatch] has
  /// already evicted every site that disagrees: the loaded Tor sites share
  /// one constraint by construction, so the first one found answers for all
  /// of them. Pass the site being activated first, since it is the one
  /// whose constraint the eviction was computed against.
  ///
  /// Derived from the loaded set rather than from a single site so that
  /// clearing a pin in settings, or unloading the site that held it, drops
  /// the pin instead of leaving it applied to whatever loads next.
  static String? torExitNodesFor({
    required Iterable<int> indices,
    required List<WebViewModel> models,
  }) {
    for (final i in indices) {
      if (i < 0 || i >= models.length) continue;
      final pin = _torExitPin(models[i]);
      if (pin == null) continue;
      return pin == _torUnpinned ? null : pin;
    }
    return null;
  }

  /// The site whose exit constraint wins among [indices], in their order:
  /// the first that routes through Tor. Null when none does.
  ///
  /// [torExitNodesFor] reads the pin off the same site, so evicting what
  /// [indicesToUnloadForTorExitMismatch] names against it leaves every
  /// loaded Tor site agreeing with the pin that goes into force.
  static int? torExitAnchor({
    required Iterable<int> indices,
    required List<WebViewModel> models,
  }) {
    for (final i in indices) {
      if (i < 0 || i >= models.length) continue;
      if (_torExitPin(models[i]) != null) return i;
    }
    return null;
  }

  /// Whether the Tor sites among [indices] are all archive-tier.
  ///
  /// Such a pin may use a GeoIP table already on the device but must not
  /// download one (ARCH-006): the file would be a trace outside the
  /// archive's keyspace, and with no app-tier site pinned, its presence
  /// would say an archived site was. False when no Tor site is among them.
  static bool torExitPinIsArchiveOnly({
    required Iterable<int> indices,
    required List<WebViewModel> models,
  }) {
    var any = false;
    for (final i in indices) {
      if (i < 0 || i >= models.length) continue;
      if (_torExitPin(models[i]) == null) continue;
      if (!models[i].isArchiveTier) return false;
      any = true;
    }
    return any;
  }

  /// Stands in for a Tor site that pins no country. Distinct from null,
  /// which means the site does not use Tor and so is indifferent to
  /// `ExitNodes` entirely. Not a legal `ExitNodes` value, so it cannot
  /// collide with a real pin.
  static const String _torUnpinned = '<unpinned>';

  /// The site's effective exit-country constraint, or null when it has
  /// none because it does not route through Tor.
  ///
  /// Read off the *effective* settings, so a site on DEFAULT inherits the
  /// global proxy's country, and a country left over on a site since
  /// switched to SOCKS5 constrains nothing.
  static String? torExitConstraint(WebViewModel model) => _torExitPin(model);

  static String? _torExitPin(WebViewModel model) {
    final effective = resolveEffectiveProxy(
      model.proxySettings,
      siteId: model.siteId,
    );
    if (effective.type != ProxyType.TOR) return null;
    return effective.exitNodesValue ?? _torUnpinned;
  }

  /// LRU eviction set. Returns the indices to evict (oldest first) so that
  /// [loadedIndices] plus [targetIndex] fits within [maxLoadedSites].
  static List<int> indicesToEvictForLruCap({
    required int targetIndex,
    required Set<int> loadedIndices,
    required int maxLoadedSites,
    required SiteRetentionResolver priorityOf,
  }) {
    final projected = loadedIndices.contains(targetIndex)
        ? loadedIndices.length
        : loadedIndices.length + 1;
    final overflow = projected - maxLoadedSites;
    if (overflow <= 0) return const [];
    return evictionOrder(
      loadedIndices.where((i) => i != targetIndex),
      priorityOf: priorityOf,
    ).take(overflow).toList();
  }
}

/// What an unload's steps ask of the plan's maker and tell the page
/// ([SiteUnloadEngine]'s `plan` port).
typedef PlanAnswers = ({
  bool Function() isStale,
  UnloadReason Function(WebViewModel site) reasonOf,
  void Function(WebViewModel site) disposed,
  NavCapture? Function(WebViewModel site) beginNavCapture,
  Isolation isolation,
});

/// What the unload engine's flow runs against: the plan, its page, and
/// whether the activation that made it was superseded.
final class UnloadFlow implements Capturing {
  UnloadFlow({required this.host, required this.plan, required this.isStale});

  final SiteUnloadHost host;
  final ResidencyPlan plan;
  final bool Function() isStale;

  @override
  NavCapture? capture;

  UnloadReason reasonOf(WebViewModel site) =>
      plan.unloads.firstWhere((u) => u.site == site).reason;

  void disposed(WebViewModel site) =>
      host.noteUnloaded(site, reason: reasonOf(site));
}
