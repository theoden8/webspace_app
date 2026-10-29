import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/utils/concurrency.dart';

/// One notification site as the background wake sees it.
class WakeSite {
  final SiteId siteId;
  final String name;

  const WakeSite({required this.siteId, required this.name});
}

/// How a wake checks a site (NOTIF-016).
enum WakeMode { live, headless }

/// Why a wake does not check a notification site (NOTIF-016). Each one is a
/// case where a headless check could send the site's traffic somewhere the
/// user did not ask for, or could not reach the site's session at all.
enum WakeSkip {
  legacyIsolation('sites share one cookie jar under legacy isolation'),
  localPage('it is an imported page, with nothing to fetch'),
  incognito('an incognito site keeps no session a headless check can use'),
  proxyUnavailable('its proxy cannot be bound'),
  onionNeedsProxy('it is an onion service and its route has no proxy'),
  torDown('it routes through Tor and Tor is not up'),
  proxyConflict('its proxy differs from the one this wake runs under'),
  activationInFlight('a site was opening when the wake came; the next wake '
      'checks it'),
  blockersNotAttached(
      'its DNS or content blocker did not attach to the headless webview'),
  headlessFailed('the headless webview could not be created'),
  appInForeground('the app came back to the foreground during the wake');

  const WakeSkip(this.reason);

  final String reason;
}

/// One site as the host reports it, before the engine decides what the wake
/// does with it.
class WakeCandidate {
  final WakeSite site;

  /// `effectiveNotificationsEnabled`.
  final bool notificationsEnabled;

  /// Loaded with a webview a reload reaches.
  final bool live;

  /// Why a headless check of this site must not run, or null.
  final WakeSkip? headlessBlocked;

  const WakeCandidate({
    required this.site,
    required this.notificationsEnabled,
    required this.live,
    this.headlessBlocked,
  });
}

/// What the wake does with one notification site: check it in [mode], or
/// skip it for [skip].
class WakePlanEntry {
  final WakeSite site;
  final WakeMode? mode;
  final WakeSkip? skip;

  const WakePlanEntry.check(this.site, {required WakeMode this.mode}) : skip = null;
  const WakePlanEntry.skip(this.site, {required WakeSkip this.skip}) : mode = null;
}

class WakePlan {
  final List<WakePlanEntry> entries;

  const WakePlan(this.entries);
}

/// What the wake needs from the app, so the orchestration runs against fakes,
/// over the app's sites of type [S] (the page's `WebViewModel`; a test's
/// `SiteId`).
abstract class BackgroundWakeHost<S extends Object> {
  /// The runtime's variables the wake's table writes: the checks it runs
  /// and the app on screen, beside the loaded sites it reads.
  RuntimeVars<S> get vars;

  /// The site [siteId] names, as the runtime holds it.
  S siteOf(SiteId siteId);

  /// Whether a check of [site], which runs as [site] itself, may run beside
  /// what runs now: the activation's own `RouteFree` over the running sites
  /// (PROXY-008, TOR-014).
  bool routeFree(S site);

  /// Whether a nested open is in flight, its screen not yet up: its pop
  /// may bring the site on screen back on another route, so a check waits
  /// it out as it does an activation (BUG-037).
  bool get nestedOpening;

  /// The app is back on screen: every check closes, in the proxy rule's
  /// turn, and no other opens.
  void closeAllHeadless();

  /// Every site, in check order. The engine picks the notification sites
  /// ([BackgroundWakeEngine.plan]); the host only reports.
  List<WakeCandidate> wakeCandidates();

  Future<void> reload(SiteId siteId);

  /// Points the process-wide route (Android's proxy override, Tor's exit
  /// country) at [siteId]'s, which nothing running needs another of. False
  /// when it could not be applied, in which case its check does not start.
  Future<bool> applyRoute(SiteId siteId);

  /// Puts back the route the loaded sites need, once the checks are closed.
  void releaseRoute();

  /// [siteId]'s check did not open: the claim its route took goes.
  void leave(SiteId siteId);

  /// Opens [siteId] in a headless webview and starts its load. Null when it
  /// is loading, otherwise why it is not.
  Future<WakeSkip?> openHeadless(SiteId siteId);

  Future<void> closeHeadless(SiteId siteId);

  /// Null once the site's webview, live or headless, is gone.
  bool? isLoading(SiteId siteId);

  Future<String?> title(SiteId siteId);

  /// Whether the site's own page posted a notification at or after [since].
  bool postedSince(SiteId siteId, {required DateTime since});

  Future<void> post({
    required SiteId siteId,
    required String siteName,
    required String body,
  });

  DateTime now();

  Future<void> delay(Duration d);
}

/// The unread count a page shows in its title, when it shows one: the first
/// parenthesised integer, as in "(3) WhatsApp" or "Inbox (12) - Gmail". A
/// trailing plus ("(99+)") reads as its number.
int? unreadCountFromTitle(String? title) {
  if (title == null) return null;
  final m = RegExp(r'\((\d{1,5})\+?\)').firstMatch(title);
  return m == null ? null : int.parse(m.group(1)!);
}

/// A wake posts on a site's behalf only when the site said nothing itself and
/// its unread count rose past a baseline taken while the user could see it.
/// An unknown baseline (first wake after a cold launch) posts nothing: the
/// count may be unread the user already knew about.
bool postsUnreadFallback({
  required int? baseline,
  required int? current,
  required bool sitePosted,
}) =>
    !sitePosted && baseline != null && current != null && current > baseline;

enum WakeSettleKind { loaded, neverLoaded, timedOut, gone }

/// How a site's reload ended inside a wake.
class WakeSettle {
  final WakeSettleKind kind;

  /// Time from the wake's start to the load finishing; [loaded] only.
  final Duration? after;

  const WakeSettle.loaded(Duration this.after) : kind = WakeSettleKind.loaded;
  const WakeSettle.neverLoaded()
      : kind = WakeSettleKind.neverLoaded,
        after = null;
  const WakeSettle.timedOut()
      : kind = WakeSettleKind.timedOut,
        after = null;
  const WakeSettle.gone()
      : kind = WakeSettleKind.gone,
        after = null;

  String describe() => switch (kind) {
        WakeSettleKind.loaded =>
          'loaded in ${(after!.inMilliseconds / 1000).toStringAsFixed(1)}s',
        WakeSettleKind.neverLoaded => 'no load observed',
        WakeSettleKind.timedOut => 'still loading at the deadline',
        WakeSettleKind.gone => 'webview gone',
      };
}

class WakeSiteOutcome {
  final WakeSite site;

  /// How the site was checked; null when it was skipped.
  final WakeMode? mode;
  final WakeSkip? skip;

  /// Null when the site was skipped.
  final WakeSettle? settle;
  final int? baseline;
  final int? current;
  final bool sitePosted;
  final bool fallbackPosted;

  const WakeSiteOutcome({
    required this.site,
    required WakeMode this.mode,
    required WakeSettle this.settle,
    required this.baseline,
    required this.current,
    required this.sitePosted,
    required this.fallbackPosted,
  }) : skip = null;

  const WakeSiteOutcome.skipped(this.site, {required WakeSkip this.skip})
      : mode = null,
        settle = null,
        baseline = null,
        current = null,
        sitePosted = false,
        fallbackPosted = false;
}

class WakeReport {
  final List<WakeSiteOutcome> sites;
  final Duration elapsed;

  const WakeReport({required this.sites, required this.elapsed});

  int get posted => sites.where((s) => s.fallbackPosted).length;

  int count(WakeMode mode) => sites.where((s) => s.mode == mode).length;

  int get skipped => sites.where((s) => s.skip != null).length;
}

/// Background-log lines for one site of a wake. [normal] names the site by
/// its position only, so it can be kept on disk and exported; [sensitive]
/// carries the name that position stands for.
({String normal, String sensitive}) describeWakeSite(
    WakeSiteOutcome o, {required int position, required int count}) {
  final sensitive = 'wake site $position/$count is "${o.site.name}" '
      '(siteId ${o.site.siteId})';
  final skip = o.skip;
  if (skip != null) {
    return (
      normal: 'wake site $position/$count skipped: ${skip.reason}',
      sensitive: sensitive,
    );
  }
  String unread(int? v) => v == null ? '?' : '$v';
  final verdict = o.fallbackPosted
      ? 'posted for it'
      : o.sitePosted
          ? 'page posted itself'
          : 'nothing posted';
  return (
    normal: 'wake site $position/$count (${o.mode!.name}): '
        '${o.settle!.describe()}, '
        'unread ${unread(o.baseline)} -> ${unread(o.current)}, $verdict',
    sensitive: sensitive,
  );
}

/// NOTIF-013 / NOTIF-014 / NOTIF-016: a background wake (iOS
/// `BGAppRefreshTask`, the Android `WorkManager`) checks every notification
/// site, reloading a live webview in place and opening any other site in a
/// headless webview, keeps the wake open until those loads settle and their
/// JS has had a moment to post, then posts on behalf of any site that stayed
/// silent while its unread count rose.
///
/// Returning is what ends the OS task.
class BackgroundWakeEngine<S extends Object> {
  BackgroundWakeEngine({
    this.settleDeadline = const Duration(seconds: 20),
    this.postGrace = const Duration(seconds: 3),
    this.poll = const Duration(milliseconds: 500),
  });

  /// Longest the wake waits for loads to finish. iOS gives a refresh task
  /// about 30 s and the Android worker caps Dart at 60 s, so this plus
  /// [postGrace] stays inside both.
  final Duration settleDeadline;

  /// Time for a settled page's own JS to post before its title is read.
  final Duration postGrace;

  final Duration poll;

  final Map<SiteId, int> _baselines = {};

  /// Record what the user could see on a running page: as the app leaves the
  /// screen, and after the page posts from the background. A title with no
  /// count is none unread, which is how a site shows it, so the first message
  /// after it posts; only a title that could not be read is unknown.
  void noteBaseline(SiteId siteId, {required String? title}) {
    if (title == null) {
      _baselines.remove(siteId);
    } else {
      _baselines[siteId] = unreadCountFromTitle(title) ?? 0;
    }
  }

  int? baseline(SiteId siteId) => _baselines[siteId];

  void forget(Set<SiteId> liveSiteIds) =>
      _baselines.removeWhere((id, _) => !liveSiteIds.contains(id));

  /// The baselines of [siteIds], for a store that keeps them past the
  /// process.
  Map<SiteId, int> baselinesOf(Set<SiteId> siteIds) => {
        for (final e in _baselines.entries)
          if (siteIds.contains(e.key)) e.key: e.value,
      };

  /// Restores what a store kept. A baseline already taken in this process is
  /// newer and wins.
  void restoreBaselines(Map<SiteId, int> kept) {
    for (final e in kept.entries) {
      _baselines.putIfAbsent(e.key, () => e.value);
    }
  }

  /// Which sites a wake checks and how (NOTIF-016): every site with
  /// notifications on, live or not. Only a reason in [WakeSkip] keeps one
  /// out, and the plan says which; whether a headless one may run beside
  /// what runs is asked as its check opens ([wakeTable]).
  static WakePlan plan(List<WakeCandidate> candidates) => WakePlan([
    for (final c in candidates)
      if (!c.notificationsEnabled)
        ...const <WakePlanEntry>[]
      else if (c.live)
        WakePlanEntry.check(c.site, mode: WakeMode.live)
      else if (c.headlessBlocked != null)
        WakePlanEntry.skip(c.site, skip: c.headlessBlocked!)
      else
        WakePlanEntry.check(c.site, mode: WakeMode.headless),
  ]);

  _WakeTable<S> get _table => _WakeTable.of<S>();

  /// The table a wake runs from, printed into the model.
  StepTable<WakeFlow<S>, WakePlace> get table => _table.table;

  final SingleFlight<(), WakeReport> _flight = SingleFlight();
  bool _waking = false;

  /// Whether a wake is under way: the model's `"wake" \in Kinds`, set once
  /// its input has run.
  bool get waking => _waking;

  /// Runs one wake and reports what each site did. Every headless webview it
  /// opened is closed before it returns, however it returns. A wake asked
  /// for while one runs joins it: one at a time.
  Future<WakeReport> wake(BackgroundWakeHost<S> host) =>
      _flight.run((), call: () => _wake(host));

  Future<WakeReport> _wake(BackgroundWakeHost<S> host) async {
    final flow = WakeFlow<S>(this, host: host)
      ..plan = plan(host.wakeCandidates())
      ..started = host.now();
    final c = StepContext(flow);
    final next = table.runInput(c, from: WakePlace.wake);
    _waking = true;
    try {
      await table.run(c, from: next);
    } finally {
      try {
        // A failed step leaves its checks open: the table closes them.
        if (flow.report == null && host.vars.headless.value.isNotEmpty) {
          _table.closeFirst(c);
          await table.run(c, from: WakePlace.wClose);
        }
      } finally {
        _waking = false;
      }
    }
    return flow.report!;
  }

  /// The app left the screen (`background`) or came back (`foreground`):
  /// the inputs of the wake's table that the app's lifecycle makes.
  void background(BackgroundWakeHost<S> host) =>
      table.runInput(StepContext(WakeFlow<S>(this, host: host)), from: WakePlace.background);

  void foreground(BackgroundWakeHost<S> host) =>
      table.runInput(StepContext(WakeFlow<S>(this, host: host)), from: WakePlace.foreground);

  /// Between the opens and the closes: the live sites reloaded, every check
  /// settled, the titles read and the fallback posts made.
  Future<void> _middle(WakeFlow<S> w) async {
    final host = w.host;
    final plan = w.plan!;
    for (final e in plan.entries) {
      if (e.mode != WakeMode.live) continue;
      await host.reload(e.site.siteId);
      w.checked.add(e);
      w.issuedAt[e.site.siteId] = host.now();
    }
    final settle = await _awaitSettled(host,
        sites: w.checked, started: w.started, issuedAt: w.issuedAt);
    if (w.checked.isNotEmpty) await host.delay(postGrace);

    final outcomes = <WakeSiteOutcome>[];
    for (final e in plan.entries) {
      final s = e.site;
      final skip = e.skip ?? w.skipped[s.siteId];
      if (skip != null) {
        outcomes.add(WakeSiteOutcome.skipped(s, skip: skip));
        continue;
      }
      final title = await host.title(s.siteId);
      final baseline = _baselines[s.siteId];
      final current = unreadCountFromTitle(title);
      final sitePosted = host.postedSince(s.siteId, since: w.started);
      final fallback = postsUnreadFallback(
        baseline: baseline,
        current: current,
        sitePosted: sitePosted,
      );
      if (fallback) {
        await host.post(siteId: s.siteId, siteName: s.name, body: title!);
      }
      outcomes.add(WakeSiteOutcome(
        site: s,
        mode: e.mode!,
        settle: settle[s.siteId]!,
        baseline: baseline,
        current: current,
        sitePosted: sitePosted,
        fallbackPosted: fallback,
      ));
      // A page the wake just loaded may not show its count yet, so a title
      // without one says nothing; one with one moves the baseline, so one
      // rise posts once.
      if (current != null) _baselines[s.siteId] = current;
    }
    w.report =
        WakeReport(sites: outcomes, elapsed: host.now().difference(w.started));
  }

  /// A load is settled once it has been seen to start and then stop, or once
  /// it never started within a second of being issued (a reload the engine
  /// refused, or one that finished before the first poll).
  Future<Map<SiteId, WakeSettle>> _awaitSettled(
    BackgroundWakeHost<S> host, {
    required List<WakePlanEntry> sites,
    required DateTime started,
    required Map<SiteId, DateTime> issuedAt,
  }) async {
    final seenLoading = <SiteId>{};
    final settledAt = <SiteId, Duration>{};
    final deadline = started.add(settleDeadline);
    while (true) {
      var pending = false;
      final now = host.now();
      final state = <SiteId, WakeSettle>{};
      for (final s in sites) {
        final id = s.site.siteId;
        final loading = host.isLoading(id);
        if (loading == null) {
          state[id] = const WakeSettle.gone();
        } else if (loading) {
          seenLoading.add(id);
          settledAt.remove(id);
          pending = true;
          state[id] = const WakeSettle.timedOut();
        } else if (seenLoading.contains(id)) {
          state[id] = WakeSettle.loaded(
              settledAt.putIfAbsent(id, () => now.difference(started)));
        } else if (now.isBefore(
            issuedAt[id]!.add(const Duration(seconds: 1)))) {
          pending = true;
          state[id] = const WakeSettle.timedOut();
        } else {
          state[id] = const WakeSettle.neverLoaded();
        }
      }
      if (!pending || !host.now().isBefore(deadline)) return state;
      await host.delay(poll);
    }
  }
}

/// The places a wake waits at, as `activation.tla` names them: the inputs
/// (a wake, the app leaving the screen and coming back), each check's ask,
/// route and open, the reloads and reads between, and each check's close.
enum WakePlace {
  wake,
  background,
  foreground,
  wAsk,
  wApply,
  wOpen,
  wMiddle,
  wClose,
  done,
}

/// What a wake's steps run against: the engine, the host, the plan its
/// input made and what the wake found on its way.
final class WakeFlow<S extends Object> {
  WakeFlow(this.engine, {required this.host});

  final BackgroundWakeEngine<S> engine;
  final BackgroundWakeHost<S> host;

  /// What the wake checks and how, made before its input runs.
  WakePlan? plan;
  late final DateTime started;
  final Map<SiteId, WakeSkip> skipped = {};
  final List<WakePlanEntry> checked = [];
  final Map<SiteId, DateTime> issuedAt = {};

  /// Whether a check applied its route, which the wake puts back at its
  /// end, and what the last route apply and open answered.
  bool routed = false;
  bool applied = false;
  WakeSkip? refused;

  WakeReport? report;

  /// The entry the plan made for [site].
  WakePlanEntry entryOf(S site) => plan!.entries.firstWhere(
    (e) => identical(host.siteOf(e.site.siteId), site),
  );
}

/// What a wake's steps reach of their flow ([wakeTable]'s `wake` port):
/// the plan's entries, the record of what each check came to, and the
/// host's calls on a check, each by the site the step names.
final class WakeCalls<S extends Object> {
  WakeCalls(this._w);

  final WakeFlow<S> _w;

  SiteId _id(S site) => _w.entryOf(site).site.siteId;

  /// The notification sites the plan checks headless.
  List<S> get offline => [
    for (final e in _w.plan!.entries)
      if (e.mode == WakeMode.headless) _w.host.siteOf(e.site.siteId),
  ];

  bool routeFree(S site) => _w.host.routeFree(site);

  bool get nestedOpening => _w.host.nestedOpening;

  /// The last route apply did not take.
  bool get refused => !_w.applied;

  /// Why the last open was refused, if it was.
  WakeSkip? get openRefused => _w.refused;

  void skip(S site, {required WakeSkip why}) => _w.skipped[_id(site)] = why;

  void checked(S site) {
    final e = _w.entryOf(site);
    _w.checked.add(e);
    _w.issuedAt[e.site.siteId] = _w.host.now();
  }

  Future<void> applyRoute(S site) async {
    _w.routed = true;
    _w.applied = await _w.host.applyRoute(_id(site));
  }

  Future<void> open(S site) async =>
      _w.refused = await _w.host.openHeadless(_id(site));

  void leave(S site) => _w.host.leave(_id(site));

  Future<void> close(S site) => _w.host.closeHeadless(_id(site));

  void closeAll() => _w.host.closeAllHeadless();

  Future<void> middle() => _w.engine._middle(_w);

  /// The route the loaded sites need, back once a check applied its own,
  /// unless the app came back ([fore]).
  void release({required bool fore}) {
    if (_w.routed && !fore) _w.host.releaseRoute();
  }
}

/// A background wake as a step table (NOTIF-013, NOTIF-014, NOTIF-016),
/// printed into `activation.tla`: the checks it runs headless are running
/// sites (`headless`), so the proxy rules range over them as over the
/// loaded sites and a nested screen. Each check asks the activation's
/// `RouteFree` and claims its place before its route and open await, so a
/// preload that lands meanwhile sees it; it leaves at its close, or at once
/// when the app comes back to the screen.
StepTable<WakeFlow<S>, WakePlace> wakeTable<S extends Object>() =>
    _WakeTable.of<S>().table;

/// What a wake's check asks before it opens ([WakePlace.wAsk]), each a
/// reason to skip its site: the app back on screen, an activation or a
/// nested open in flight, a route the running sites do not leave free.
typedef WakeAsks<S extends Object> = ({
  Expr<bool, WakeFlow<S>> fore,
  Expr<bool, WakeFlow<S>> activating,
  Expr<bool, WakeFlow<S>> nestedOpening,
  Expr<bool, WakeFlow<S>> routeFree,
});

WakeAsks<S> wakeAsks<S extends Object>() => _WakeTable.of<S>().asks;

final class _WakeTable<S extends Object> {
  _WakeTable._();

  /// One per site type, so every engine runs the table the model prints
  /// and a test plants a mistake over.
  static _WakeTable<S> of<S extends Object>() {
    if (_bySite[S] case final _WakeTable<S> made) return made;
    final made = _WakeTable<S>._();
    _bySite[S] = made;
    return made;
  }

  static final _bySite = <Type, _WakeTable<Object>>{};

  late final _kind = Field<FlowKind, WakeFlow<S>>(FlowField.kind);
  late final _site = Field<S, WakeFlow<S>>(FlowField.site);
  late final _checks = Field<List<S>, WakeFlow<S>>(FlowField.checks);

  late final _loaded = Mutable<Iterable<S>, WakeFlow<S>>.over(
    ModelVar.loaded,
    of: (w) => w.host.vars.loaded,
  );
  late final _headless = Mutable<Iterable<S>, WakeFlow<S>>.over(
    ModelVar.headless,
    of: (w) => w.host.vars.headless,
  );
  /// The app goes to the background and the OS wakes it: always in the
  /// code, in the configs that follow it in the model (`Waking`).
  late final _wakes = Constant<bool, WakeFlow<S>>(
    ModelConst.waking,
    read: (_) => true,
  ).value;
  late final _fore = Mutable<bool, WakeFlow<S>>.over(
    ModelVar.fore,
    of: (w) => w.host.vars.fore,
  );
  late final _marker = Mutable<ActivationMarker<S>?, WakeFlow<S>>.over(
    ModelVar.marker,
    of: (w) => w.host.vars.marker,
  );
  late final _noMarker = Expr.constant<ActivationMarker<S>?, WakeFlow<S>>(
    null,
    tla: 'NoMarker',
  );

  late final _yes = Expr.constant<bool, WakeFlow<S>>(true);
  late final _no = Expr.constant<bool, WakeFlow<S>>(false);

  /// What the wake's steps do beyond the model's variables: the plan's
  /// entries, the record of what each check came to, and the host's calls
  /// that route, open and close the checks. None of it is a variable of
  /// the model: the steps write `headless` and `fore` themselves, and the
  /// proxy rule has its own model (`process_route.tla`).
  late final _calls = Port<WakeCalls<S>, WakeFlow<S>>(
    'wake',
    reads: const {},
    changes: const {},
    of: WakeCalls.new,
  );

  /// Whether a wake runs already, which the model reads off every flow.
  late final _running = Port<bool, WakeFlow<S>>(
    'waking',
    reads: {ModelVar.fl},
    changes: const {},
    of: (w) => w.engine.waking,
  );

  /// A nested open in flight: the model's `"nested" \in Kinds`.
  late final _nestedOpening = Expr.inFlight<WakeFlow<S>>(
    FlowKind.nested,
    run: (c) => _calls.from(c).nestedOpening,
  );

  /// One wake at a time: the model's `"wake" \in Kinds`.
  late final _waking = Expr.inFlight<WakeFlow<S>>(
    FlowKind.wake,
    run: _running.from,
  );

  /// The notification sites the wake checks headless: under containers,
  /// every one with no webview and nothing that keeps it out (the pages
  /// have no such reason); under the shared jar, none (legacyIsolation).
  late final _offlineSites = Port<List<S>, WakeFlow<S>>(
    'offline',
    reads: {ModelVar.loaded},
    changes: const {},
    of: (w) => WakeCalls(w).offline,
  );
  late final _offline = Expr.op<List<S>, WakeFlow<S>>(
    HandPaired.offlineNotified,
    tla: 'IF Containers THEN Notified \\ loaded ELSE {}',
    run: _offlineSites.from,
    reads: const Reads(vars: {ModelVar.loaded}),
    needs: const {
      (of: ModelConst.containers, set: true),
      (of: ModelConst.notified, set: true),
    },
  );

  late final _eachCheck = Pick<S, WakeFlow<S>>(_checks.value);
  late final _chosen = _eachCheck.it;

  /// Whether [s] may run beside what runs: the activation's `RouteFree`,
  /// the one rule of the proxy and the Tor exit (PROXY-008, TOR-014).
  late final WakeAsks<S> asks = (
    fore: _fore.value,
    activating: _marker.value.neq(_noMarker),
    nestedOpening: _nestedOpening,
    routeFree: _routeFree(_chosen),
  );

  Expr<bool, WakeFlow<S>> _routeFree(Expr<S, WakeFlow<S>> s) =>
      ModelDef.routeFree.over(
        [s],
        run: (c) => _calls.from(c).routeFree(s.run(c)),
      );

  late final _refused = Expr.ofConstant<bool, WakeFlow<S>>(
    ModelConst.proxyRefused,
    run: (c) => _calls.from(c).refused,
  );
  late final _openRefused = Expr.op<bool, WakeFlow<S>>(
    HandPaired.headlessOpenRefused,
    tla: 'FALSE',
    run: (c) => _calls.from(c).openRefused != null,
    reads: Reads.none,
  );

  /// Where a wake goes once a check is placed or passed over: the next
  /// check, or the reloads and reads once none is left.
  Expr<WakePlace, WakeFlow<S>> _onward(Expr<Iterable<S>, WakeFlow<S>> left) =>
      Expr.choose(
        when: left.isEmpty,
        then: to(WakePlace.wMiddle),
        otherwise: to(WakePlace.wAsk),
      );

  late final _leaving = Act.of([
    _headless.becomes(_headless.value.without(_site.value)),
  ], then: (c) => _calls.from(c).leave(_site.of(c)));

  late final table = StepTable<WakeFlow<S>, WakePlace>(
    WakePlace.values,
    ending: {WakePlace.done},
    vars: [_loaded, _headless, _fore, _marker],
    at: (place) => switch (place) {
      // The OS wakes the app in the background (NOTIF-016): the live
      // notification sites reload where they are, the rest are checked
      // headless, one wake at a time.
      WakePlace.wake => Step.input(
        ActivationStep.wake,
        enabled: _wakes & ~_fore.value & ~_waking,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            _kind.becomes(Expr.constant(FlowKind.wake)),
            _checks.becomes(_offline),
          ],
          next: _onward(_offline),
        ),
      ),
      // The app leaves the screen; a wake may come.
      WakePlace.background => Step.input(
        ActivationStep.background,
        enabled: _wakes & _fore.value,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [Act.of([_fore.becomes(_no)])],
          next: to(WakePlace.done),
        ),
      ),
      // The app is back: every check closes at once, in the proxy rule's
      // turn (ProcessRoute.vacate), and no other opens. A webview the user
      // opens next waits for that turn before its first load, so nothing
      // it loads meets a check still running.
      WakePlace.foreground => Step.input(
        ActivationStep.foreground,
        enabled: _wakes & ~_fore.value,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            Act.of([
              _fore.becomes(_yes),
              _headless.becomes(Expr.none()),
            ], then: (c) => _calls.from(c).closeAll()),
          ],
          next: to(WakePlace.done),
        ),
      ),
      // A check runs only beside what may run with it, and as a preload
      // does, never beside an activation in flight, whose plan ran before
      // the check was there; one that may takes its place among the
      // running sites before its first await.
      WakePlace.wAsk => Step(
        ActivationStep.wakeAsk,
        holds: null,
        pick: _eachCheck,
        site: _chosen,
        branches: [
          Branch(
            StepOutcome.skip,
            when:
                asks.fore |
                asks.activating |
                asks.nestedOpening |
                ~asks.routeFree,
            then: [
              Note(
                (c) => _calls.from(c).skip(
                  _chosen.run(c),
                  why: _fore.value.run(c)
                      ? WakeSkip.appInForeground
                      : _marker.value.run(c) != null ||
                            _nestedOpening.run(c)
                      ? WakeSkip.activationInFlight
                      : WakeSkip.proxyConflict,
                ),
              ),
              _checks.becomes(_checks.value.without(_chosen)),
            ],
            next: _onward(_checks.value.without(_chosen)),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [
            _site.becomes(_chosen),
            _checks.becomes(_checks.value.without(_chosen)),
            Act.of([_headless.becomes(_headless.value.union(_chosen.asSet))]),
          ],
          next: to(WakePlace.wApply),
        ),
      ),
      // The route the check runs on put in force: nothing running needs
      // another (it asked), so this moves the rule under nobody.
      WakePlace.wApply => Step(
        ActivationStep.wakeApplyReply,
        holds: null,
        site: _site.value,
        call: Call.on(
          _calls,
          run: (c) => c.api.applyRoute(_site.of(c)),
          writes: const [],
        ),
        branches: [
          Branch(
            StepOutcome.bail,
            when: _refused,
            then: [
              Note(
                (c) => _calls.from(c).skip(_site.of(c), why: WakeSkip.proxyUnavailable),
              ),
              _leaving,
            ],
            next: _onward(_checks.value),
          ),
        ],
        otherwise: Otherwise(StepOutcome.go, then: [], next: to(WakePlace.wOpen)),
      ),
      // The headless webview is up and loading, or was refused; one the app
      // came back over is closed by the host and never counts.
      WakePlace.wOpen => Step(
        ActivationStep.wakeOpenReply,
        holds: null,
        site: _site.value,
        call: Call.on(
          _calls,
          run: (c) => c.api.open(_site.of(c)),
          writes: const [],
        ),
        branches: [
          Branch(
            StepOutcome.skip,
            when: _openRefused | _fore.value,
            then: [
              Note(
                (c) {
                  final w = _calls.from(c);
                  w.skip(_site.of(c), why: w.openRefused ?? WakeSkip.appInForeground);
                },
              ),
              _leaving,
            ],
            next: _onward(_checks.value),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.go,
          then: [
            Note((c) => _calls.from(c).checked(_site.of(c))),
          ],
          next: _onward(_checks.value),
        ),
      ),
      // The live sites reloaded, every check settled and read, the fallback
      // posts made (NOTIF-013, NOTIF-014): nothing the model holds. The
      // first check still open is the one to close.
      WakePlace.wMiddle => Step(
        ActivationStep.wakeMiddle,
        holds: null,
        call: Call.on(_calls, run: (c) => c.api.middle(), writes: const []),
        branches: [
          Branch(
            StepOutcome.end,
            when: _headless.value.isEmpty,
            then: [_release],
            next: to(WakePlace.done),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.go,
          pick: _eachOpen,
          then: [_site.becomes(_eachOpen.it)],
          next: to(WakePlace.wClose),
        ),
      ),
      // Each check disposed, then gone from the running sites; the route
      // the loaded sites need comes back once the last is. One the app's
      // return closed meanwhile is gone already.
      WakePlace.wClose => Step(
        ActivationStep.wakeCloseReply,
        holds: null,
        site: _site.value,
        call: Call.on(
          _calls,
          run: (c) => c.api.close(_site.of(c)),
          writes: const [],
        ),
        branches: [
          Branch(
            StepOutcome.end,
            when: _headless.value.without(_site.value).isEmpty,
            then: [
              Act.of([_headless.becomes(_headless.value.without(_site.value))]),
              _release,
            ],
            next: to(WakePlace.done),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.more,
          pick: _eachLeft,
          then: [
            Act.of([_headless.becomes(_headless.value.without(_site.value))]),
            _site.becomes(_eachLeft.it),
          ],
          next: to(WakePlace.wClose),
        ),
      ),
      WakePlace.done => const Leaves(),
    },
  );

  late final _eachOpen = Pick<S, WakeFlow<S>>(_headless.value);
  late final _eachLeft = Pick<S, WakeFlow<S>>(
    _headless.value.without(_site.value),
  );

  /// The route the loaded sites need put back once a check applied its
  /// own, unless the app came back: its return closed the checks in the
  /// rule's turn, and the site the user opens next takes the rule.
  late final _release = Note<WakeFlow<S>>(
    (c) => _calls.from(c).release(fore: _fore.value.run(c)),
    reads: _fore.value.reads,
  );

  /// Points the close at the first check still open, for a wake whose
  /// step failed before it reached its closes.
  void closeFirst(StepContext<WakeFlow<S>> c) => _site
      .becomes(
        Expr.op(
          HandPaired.anyHeadless,
          tla: 'CHOOSE s \\in headless : TRUE',
          run: (c) => _headless.value.run(c).first,
          reads: const Reads(vars: {ModelVar.headless}),
        ),
      )
      .run(c);
}
