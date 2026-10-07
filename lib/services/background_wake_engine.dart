/// One notification site as the background wake sees it.
class WakeSite {
  final String siteId;
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
  torDown('it routes through Tor and Tor is not up'),
  proxyConflict('its proxy differs from the one this wake runs under'),
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

  /// The process-wide route this site needs (Android's proxy override
  /// outside router mode, Tor's exit country), as a fingerprint two sites
  /// share exactly when one route serves both. Null when nothing it needs is
  /// process-wide.
  final String? route;

  const WakeCandidate({
    required this.site,
    required this.notificationsEnabled,
    required this.live,
    this.headlessBlocked,
    this.route,
  });
}

/// What the wake does with one notification site: check it in [mode], or
/// skip it for [skip].
class WakePlanEntry {
  final WakeSite site;
  final WakeMode? mode;
  final WakeSkip? skip;

  const WakePlanEntry.check(this.site, WakeMode this.mode) : skip = null;
  const WakePlanEntry.skip(this.site, WakeSkip this.skip) : mode = null;
}

class WakePlan {
  final List<WakePlanEntry> entries;

  /// The site whose process-wide route the wake applies before any headless
  /// load, or null when the route in force already serves every check.
  final String? routeOwner;

  const WakePlan(this.entries, {this.routeOwner});
}

/// What the wake needs from the app, so the orchestration runs against fakes.
abstract class BackgroundWakeHost {
  /// Every site, in check order. The engine picks the notification sites
  /// ([BackgroundWakeEngine.plan]); the host only reports.
  List<WakeCandidate> wakeCandidates();

  Future<void> reload(String siteId);

  /// Points the process-wide route (Android's proxy override, Tor's exit
  /// country) at [siteId]'s. False when it could not be applied, in which
  /// case no headless check may start.
  Future<bool> applyRoute(String siteId);

  /// Puts back the route the loaded sites need, after [applyRoute].
  Future<void> releaseRoute();

  /// Opens [siteId] in a headless webview and starts its load. Null when it
  /// is loading, otherwise why it is not.
  Future<WakeSkip?> openHeadless(String siteId);

  Future<void> closeHeadless(String siteId);

  /// Null once the site's webview, live or headless, is gone.
  bool? isLoading(String siteId);

  Future<String?> title(String siteId);

  /// Whether the site's own page posted a notification at or after [since].
  bool postedSince(String siteId, DateTime since);

  Future<void> post({
    required String siteId,
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

  const WakeSiteOutcome.skipped(this.site, WakeSkip this.skip)
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
    WakeSiteOutcome o, int position, int count) {
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
class BackgroundWakeEngine {
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

  final Map<String, int> _baselines = {};

  /// Record what the user could see. Called when the app leaves the screen,
  /// and after every wake so one rise posts once.
  void noteBaseline(String siteId, String? title) {
    final count = unreadCountFromTitle(title);
    if (count == null) {
      _baselines.remove(siteId);
    } else {
      _baselines[siteId] = count;
    }
  }

  int? baseline(String siteId) => _baselines[siteId];

  void forget(Set<String> liveSiteIds) =>
      _baselines.removeWhere((id, _) => !liveSiteIds.contains(id));

  /// The baselines of [siteIds], for a store that keeps them past the
  /// process.
  Map<String, int> baselinesOf(Set<String> siteIds) => {
        for (final e in _baselines.entries)
          if (siteIds.contains(e.key)) e.key: e.value,
      };

  /// Restores what a store kept. A baseline already taken in this process is
  /// newer and wins.
  void restoreBaselines(Map<String, int> kept) {
    for (final e in kept.entries) {
      _baselines.putIfAbsent(e.key, () => e.value);
    }
  }

  /// Which sites a wake checks and how (NOTIF-016): every site with
  /// notifications on, live or not. Only a reason in [WakeSkip] keeps one
  /// out, and the plan says which.
  static WakePlan plan(List<WakeCandidate> candidates) {
    final sites = [for (final c in candidates) if (c.notificationsEnabled) c];
    String? routeInForce;
    for (final c in sites) {
      if (c.live && c.route != null) {
        routeInForce = c.route;
        break;
      }
    }
    String? routeOwner;
    if (routeInForce == null) {
      for (final c in sites) {
        if (c.headlessBlocked == null && c.route != null) {
          routeInForce = c.route;
          routeOwner = c.site.siteId;
          break;
        }
      }
    }
    return WakePlan(
      [
        for (final c in sites)
          if (c.live)
            WakePlanEntry.check(c.site, WakeMode.live)
          else if (c.headlessBlocked != null)
            WakePlanEntry.skip(c.site, c.headlessBlocked!)
          else if (c.route != null && c.route != routeInForce)
            WakePlanEntry.skip(c.site, WakeSkip.proxyConflict)
          else
            WakePlanEntry.check(c.site, WakeMode.headless),
      ],
      routeOwner: routeOwner,
    );
  }

  /// Runs one wake and reports what each site did. Every headless webview it
  /// opened is closed before it returns, however it returns.
  Future<WakeReport> wake(BackgroundWakeHost host) async {
    final plan = BackgroundWakeEngine.plan(host.wakeCandidates());
    final started = host.now();
    if (plan.entries.isEmpty) {
      return WakeReport(sites: const [], elapsed: Duration.zero);
    }
    final routeOwner = plan.routeOwner;
    final routeApplied =
        routeOwner == null ? true : await host.applyRoute(routeOwner);

    final skipped = <String, WakeSkip>{};
    final checked = <WakePlanEntry>[];
    final issuedAt = <String, DateTime>{};
    final opened = <String>[];
    try {
      for (final e in plan.entries) {
        final id = e.site.siteId;
        final skip = e.skip;
        if (skip != null) {
          skipped[id] = skip;
          continue;
        }
        if (e.mode == WakeMode.live) {
          await host.reload(id);
        } else if (!routeApplied) {
          skipped[id] = WakeSkip.proxyUnavailable;
          continue;
        } else {
          final refused = await host.openHeadless(id);
          if (refused != null) {
            skipped[id] = refused;
            continue;
          }
          opened.add(id);
        }
        checked.add(e);
        issuedAt[id] = host.now();
      }
      final settle = await _awaitSettled(host, checked, started, issuedAt);
      if (checked.isNotEmpty) await host.delay(postGrace);

      final outcomes = <WakeSiteOutcome>[];
      for (final e in plan.entries) {
        final s = e.site;
        final skip = skipped[s.siteId];
        if (skip != null) {
          outcomes.add(WakeSiteOutcome.skipped(s, skip));
          continue;
        }
        final title = await host.title(s.siteId);
        final baseline = _baselines[s.siteId];
        final current = unreadCountFromTitle(title);
        final sitePosted = host.postedSince(s.siteId, started);
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
        noteBaseline(s.siteId, title);
      }
      return WakeReport(
          sites: outcomes, elapsed: host.now().difference(started));
    } finally {
      for (final id in opened) {
        await host.closeHeadless(id);
      }
      if (routeOwner != null && routeApplied) await host.releaseRoute();
    }
  }

  /// A load is settled once it has been seen to start and then stop, or once
  /// it never started within a second of being issued (a reload the engine
  /// refused, or one that finished before the first poll).
  Future<Map<String, WakeSettle>> _awaitSettled(
    BackgroundWakeHost host,
    List<WakePlanEntry> sites,
    DateTime started,
    Map<String, DateTime> issuedAt,
  ) async {
    final seenLoading = <String>{};
    final settledAt = <String, Duration>{};
    final deadline = started.add(settleDeadline);
    while (true) {
      var pending = false;
      final now = host.now();
      final state = <String, WakeSettle>{};
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
