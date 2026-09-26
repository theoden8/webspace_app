/// One notification site as the background wake sees it.
class WakeSite {
  final String siteId;
  final String name;

  const WakeSite({required this.siteId, required this.name});
}

/// What the wake needs from the app, so the orchestration runs against fakes.
abstract class BackgroundWakeHost {
  /// Loaded notification sites with a live webview, in reload order.
  List<WakeSite> wakeSites();

  Future<void> reload(String siteId);

  /// Null once the site's webview is gone.
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

/// NOTIF-013 / NOTIF-014: a background wake (iOS `BGAppRefreshTask`, the
/// Android `WorkManager`) reloads every notification site, keeps the
/// wake open until those loads settle and their JS has had a moment to post,
/// then posts on behalf of any site that stayed silent while its unread count
/// rose.
///
/// Returning is what ends the OS task. Before this the wake returned as soon
/// as the reloads were issued, so the OS could suspend the app before any page
/// loaded, and a wake never ran page JS at all.
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

  /// Runs one wake and returns how many fallback notifications it posted.
  Future<int> wake(BackgroundWakeHost host) async {
    final sites = host.wakeSites();
    if (sites.isEmpty) return 0;
    final started = host.now();
    for (final s in sites) {
      await host.reload(s.siteId);
    }
    await _awaitSettled(host, sites, started);
    await host.delay(postGrace);

    var posted = 0;
    for (final s in sites) {
      final title = await host.title(s.siteId);
      if (postsUnreadFallback(
        baseline: _baselines[s.siteId],
        current: unreadCountFromTitle(title),
        sitePosted: host.postedSince(s.siteId, started),
      )) {
        await host.post(siteId: s.siteId, siteName: s.name, body: title!);
        posted++;
      }
      noteBaseline(s.siteId, title);
    }
    return posted;
  }

  /// A reload is settled once its load has been seen to start and then stop,
  /// or once it never started within the first second (a reload the engine
  /// refused, or one that finished before the first poll).
  Future<void> _awaitSettled(
      BackgroundWakeHost host, List<WakeSite> sites, DateTime started) async {
    final seenLoading = <String>{};
    final deadline = started.add(settleDeadline);
    final startGrace = started.add(const Duration(seconds: 1));
    while (true) {
      var pending = false;
      final now = host.now();
      for (final s in sites) {
        final loading = host.isLoading(s.siteId);
        if (loading == null) continue;
        if (loading) {
          seenLoading.add(s.siteId);
          pending = true;
        } else if (!seenLoading.contains(s.siteId) && now.isBefore(startGrace)) {
          pending = true;
        }
      }
      if (!pending || !host.now().isBefore(deadline)) return;
      await host.delay(poll);
    }
  }
}
