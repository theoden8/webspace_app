import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/tab_leaves.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

/// How a table names its sites ([S], an id or the object itself), the
/// object the tab variables live on found through the world, and back
/// (CONT-012).
typedef SiteKeys<S, W> = ({
  WebViewModel Function(W world, {required S key}) site,
  S Function(WebViewModel site) keyOf,
});

/// The model's variables for a site's tabs (TAB-003), as the code reads
/// them, over any world [W]: the tab ids a site lists (`tabs[s]`), its
/// active tab (`active[s]`), the site each tab runs as (`host[s][t]`,
/// LIR-018), the tab its one webview was built for (`built[s]`, the
/// binding's, which the frame that builds the webview sets), and what the
/// platform holds: the history the webview shows (`hist[s]`), the back
/// stack queued for the next build with the tab it was read for
/// (`queued[s]`), and each tab's saved file under the key of the site it
/// ran as (`file[s][t][h]`), each a label naming the tab whose history it
/// is. The model keeps a label only to catch a crossed one; the code holds
/// bytes.
///
/// The rules over them are definitions here, printed as `activation_ops`:
/// what a capture stores, what a build binds, shows and takes, what an
/// activation queues.
final class TabVars {
  const TabVars._();

  /// How [TabVars] names a table's sites: by id, as the model knows them,
  /// the object the tab variables live on found through the world.
  static SiteKeys<SiteId, W> ids<W extends SiteModels>() => (
    site: (w, {required key}) => w.siteOf(key),
    keyOf: (site) => site.siteId,
  );

  /// As the objects the tab variables live on, for the tables not yet on
  /// the runtime's id view (CONT-012).
  static SiteKeys<WebViewModel, W> objects<W>() =>
      (site: (_, {required key}) => key, keyOf: (site) => site);

  static Indexed<S, List<TabId>, W> tabs<S, W>({
    required SiteKeys<S, W> keys,
  }) => Indexed.reported(
    ModelVar.tabs,
    read: (w, {required at}) => [
      for (final t in keys.site(w, key: at).tabs) t.id,
    ],
  );

  static Indexed<S, TabId, W> active<S, W>({required SiteKeys<S, W> keys}) =>
      Indexed<WebViewModel, TabId, W>.over(
        ModelVar.active,
        cell: WebViewModel.activeTabCell,
      ).keyedBy<S>(keys.site);

  /// `host[s]`: the site each tab runs as, the site itself for one the list
  /// does not hold.
  static Indexed<S, Map<TabId, S>, W> host<S, W>({
    required SiteKeys<S, W> keys,
  }) => hostReported<S, W>(
    read: (w, {required site}) {
      final of = keys.site(w, key: site);
      return TabHosts({
        for (final MapEntry(:key, :value) in of.tabHosts.entries)
          key: keys.keyOf(value),
      }, site: keys.keyOf(of));
    },
  );

  /// `host` whole, for the writes a reroute, a duplicate and a close print;
  /// the code's are a tab's own ([SiteTab.hostCell]) or the list's.
  static Mutable<Map<S, Map<TabId, S>>, W> hostFn<S, W>() =>
      Mutable.remote(ModelVar.host);

  /// `link` whole, for the writes a duplicate and a close print; the code's
  /// is the list's.
  static Mutable<Map<S, Map<TabId, S?>>, W> linkFn<S, W>() =>
      Mutable.remote(ModelVar.link);

  /// `opener` whole, for the writes a child, a duplicate and a close print;
  /// the code's is the list's, or a tab's own ([SiteTab.openerCell]).
  static Mutable<Map<S, Map<TabId, S?>>, W> openerFn<S, W>() =>
      Mutable.remote(ModelVar.opener);

  /// The site [s]'s slot runs as (`RunsAs`, LIR-018): the host of its
  /// active tab ([WebViewModel.runningIdentity]).
  static Def<S, W> runsAs<S, W>({required SiteKeys<S, W> keys}) {
    final s = Bound<S, W>('s');
    return Def(
      ModelDef.runsAs,
      params: [s],
      body: slotHost<S, W>(s.it, keys: keys),
    );
  }

  /// `RunsAs`'s body over [s], for a read a spawned input makes, which
  /// reads the variables its arm writes as primed names.
  static Expr<S, W> slotHost<S, W>(
    Expr<S, W> s, {
    required SiteKeys<S, W> keys,
  }) => host<S, W>(keys: keys).at(s).at(active<S, W>(keys: keys).at(s));

  /// The tabs [s] lists now and [kept] leaves out run as [s] again and
  /// follow no link: the model keeps a closed tab's entry as a tab not yet
  /// made.
  static List<Write<W>> dropped<S, W>(
    Expr<S, W> s, {
    required SiteKeys<S, W> keys,
    required Expr<Iterable<TabId>, W> kept,
  }) {
    final t = Bound<TabId, W>('t');
    final gone = tabs<S, W>(keys: keys).at(s).less(kept);
    final none = Expr.constant<S?, W>(null, tla: '0');
    return [
      hostFn<S, W>().becomes(
        hostFn<S, W>().value.except(
          s,
          to: hostFn<S, W>().value.at(s).exceptEach(gone, x: t, to: s),
        ),
      ),
      for (final f in [linkFn<S, W>(), openerFn<S, W>()])
        f.becomes(
          f.value.except(
            s,
            to: f.value.at(s).exceptEach(gone, x: t, to: none),
          ),
        ),
    ];
  }

  /// What a commit that takes [gone] off the list leaves the tabs they
  /// opened following, in that step (LIR-034, `SiteRuntime.apply`):
  /// nothing, so they have no link; and a tab whose link led to one of
  /// them runs as its opener while that routes, its link's one host gone.
  static List<Write<W>> openersGone<S, W>(Expr<Iterable<S>, W> gone) {
    final opener = Mutable<Map<S, Map<TabId, S?>>, W>.remote(ModelVar.opener);
    final link = Mutable<Map<S, Map<TabId, S?>>, W>.remote(ModelVar.link);
    final o = Bound<S, W>('go');
    final t = Bound<TabId, W>('gt');
    final none = Expr.constant<S?, W>(null, tla: '0');
    final by = opener.value.at(o.it).at(t.it);
    final to = link.value.at(o.it).at(t.it);
    return [
      opener.becomes(
        opener.value.remap(
          o,
          j: t,
          to: Expr.choose(when: gone.has(by), then: none, otherwise: by),
        ),
      ),
      link.becomes(
        link.value.remap(
          o,
          j: t,
          to: Expr.choose(
            when: gone.has(by),
            then: none,
            otherwise: Expr.choose(when: gone.has(to), then: by, otherwise: to),
          ),
        ),
      ),
    ];
  }

  static Indexed<S, TabId?, W> built<S, W>({required SiteKeys<S, W> keys}) =>
      builtReported<S, W>(
        read: (w, {required site}) => keys.site(w, key: site).tabBinding.built,
      );

  /// `built` whole, for the writes the frame does.
  static Mutable<Map<S, TabId?>, W> builtFn<S, W>() => builtOf<S, W>();

  static Mutable<Map<S, TabId?>, W> hist<S, W>() => histOf<S, W>();

  static Mutable<Map<S, QueuedStack>, W> queued<S, W>() => queuedOf<S, W>();

  static Mutable<Map<S, Map<TabId, Map<S, TabId?>>>, W> file<S, W>() =>
      fileOf<S, W>();

  /// The sites whose tabs the model follows; every site's in the code.
  static Members<S, W> tabbed<S, W>() => tabbedOf<S, W>();

  /// The frame builds a webview for [s] when it is a tabbed site among
  /// the loaded sites [l] it sees: one unloaded between the commit and the
  /// frame gets none, and one the same step loads gets its own.
  static Expr<bool, W> builds<S, W>(
    Bound<S, W> s, {
    required Bound<Iterable<S>, W> l,
  }) => tabbed<S, W>().has(s.it) & l.it.has(s.it);

  static Expr<QueuedStack, W> noQueued<W>() => Expr.op(
    HandPaired.noQueued,
    tla: 'NoQueued',
    run: (_) => (t: null, h: null),
    reads: Reads.none,
  );

  /// A capture's save stores the webview's bytes under the tab it was built
  /// for, [t], keyed by the site [a] that tab ran as, read as the capture
  /// started with the history [h] it showed; the read before it dropped a
  /// capture whose tab closed or moved to another key meanwhile
  /// (`NavCapture`, TAB-003).
  static Def<Map<S, Map<TabId, Map<S, TabId?>>>, W> capture<S, W>() {
    final s = Bound<S, W>('s');
    final t = Bound<TabId?, W>('t');
    final h = Bound<TabId?, W>('h');
    final a = Bound<S, W>('a');
    final tab = t.it.unwrapped;
    // A site the model does not follow has no tab to key by (`Tabbed`).
    return Def(
      ModelDef.capture,
      params: [s, t, h, a],
      body: Expr.choose(
        when: t.it.neq(noTab()),
        then: file<S, W>().value.exceptAt(s.it, at: tab, by: a.it, to: h.it),
        otherwise: file<S, W>().value,
      ),
    );
  }

  /// The frame that builds a site's webview binds it to the active tab.
  static Def<Map<S, TabId?>, W> bound<S, W>({required SiteKeys<S, W> keys}) {
    final s = Bound<S, W>('s');
    final l = Bound<Iterable<S>, W>('l');
    final built = builtFn<S, W>().value;
    return Def(
      ModelDef.bound,
      params: [s, l],
      body: Expr.choose(
        when: builds(s, l: l),
        then: built.except(s.it, to: active<S, W>(keys: keys).at(s.it)),
        otherwise: built,
      ),
    );
  }

  /// What the built webview shows: the back stack queued for the tab it is
  /// built for, when `Takes` says the build takes it, else that tab's own
  /// fresh history (`WebViewTabBinding.take`).
  static Def<Map<S, TabId?>, W> shown<S, W>({required SiteKeys<S, W> keys}) {
    final s = Bound<S, W>('s');
    final hist = TabVars.hist<S, W>().value;
    final queued = TabVars.queued<S, W>().value.at(s.it);
    final target = active<S, W>(keys: keys).at(s.it);
    final l = Bound<Iterable<S>, W>('l');
    return Def(
      ModelDef.shown,
      params: [s, l],
      body: Expr.choose(
        when: builds(s, l: l),
        then: hist.except(
          s.it,
          to: Expr.choose(
            when: takesOf<W>().call([queued, target]),
            then: queued.part('h', get: (q) => q.h),
            otherwise: target,
          ),
        ),
        otherwise: hist,
      ),
    );
  }

  /// The build takes the queued back stack, whichever tab it was for.
  static Def<Map<S, QueuedStack>, W> taken<S, W>() {
    final s = Bound<S, W>('s');
    final queued = TabVars.queued<S, W>().value;
    final l = Bound<Iterable<S>, W>('l');
    return Def(
      ModelDef.taken,
      params: [s, l],
      body: Expr.choose(
        when: builds(s, l: l),
        then: queued.except(s.it, to: noQueued()),
        otherwise: queued,
      ),
    );
  }

  /// An activation reads a tab's saved file before the build, the tab [t]
  /// active and the site [a] it ran as when the read began, and queues it
  /// for that tab (the nav step, and a preload's: PAUSE-035): a build of
  /// another tab drops it (`Shown`).
  static Def<Map<S, QueuedStack>, W> staged<S, W>() {
    final s = Bound<S, W>('s');
    final a = Bound<S, W>('a');
    final t = Bound<TabId, W>('t');
    final queued = TabVars.queued<S, W>().value;
    final saved = file<S, W>().value.at(s.it).at(t.it).at(a.it);
    return Def(
      ModelDef.staged,
      params: [s, a, t],
      body: Expr.choose(
        when: tabbed<S, W>().has(s.it) & saved.neq(noTab()),
        then: queued.except(
          s.it,
          to: record({
            't': t.it,
            'h': saved,
          }, run: (_) => throw StateError('queued is the platform\'s')),
        ),
        otherwise: queued,
      ),
    );
  }

  /// `file[s][t][host[s][t]]`: the label [tab]'s saved file holds under
  /// the key of the site it runs as.
  static Expr<TabId?, W> savedFor<S, W>(
    Expr<S, W> site, {
    required SiteKeys<S, W> keys,
    required Expr<TabId, W> tab,
  }) => file<S, W>().value
      .at(site)
      .at(tab)
      .at(host<S, W>(keys: keys).at(site).at(tab));

  /// [tab]'s file under the key of the site it runs as removed.
  static Write<W> removed<S, W>(
    Expr<S, W> site, {
    required Expr<TabId, W> tab,
    required SiteKeys<S, W> keys,
  }) => removedAs(
    site,
    tab: tab,
    as: host<S, W>(keys: keys).at(site).at(tab),
  );

  /// [tab]'s file under [as]'s key removed.
  static Write<W> removedAs<S, W>(
    Expr<S, W> site, {
    required Expr<TabId, W> tab,
    required Expr<S, W> as,
  }) => file<S, W>().becomes(
    file<S, W>().value.exceptAt(site, at: tab, by: as, to: noTab()),
  );

  /// A duplicate's file written with what was read of its source: the
  /// source's own history becomes the copy's own; any other label stays
  /// crossed.
  static Write<W> copied<S, W>(
    Expr<S, W> site, {
    required Expr<TabId, W> copy,
    required Expr<TabId, W> source,
    required Expr<S, W> as,
    required Expr<TabId?, W> label,
  }) => file<S, W>().becomes(
    file<S, W>().value.exceptAt(
      site,
      at: copy,
      by: as,
      to: Expr.choose(when: label.eq(source), then: copy, otherwise: label),
    ),
  );

  /// What a duplicate reads of its loaded source's webview: its back
  /// stack when the webview is the source's, else none.
  static Expr<TabId?, W> dupShown<S, W>(
    Expr<S, W> site, {
    required SiteKeys<S, W> keys,
    required Expr<TabId, W> source,
  }) => Expr.choose(
    when: built<S, W>(keys: keys).at(site).eq(source),
    then: hist<S, W>().value.at(site),
    otherwise: noTab(),
  );

  /// A tab switch's one turn, after the bytes it read for [tab] ([label]):
  /// the old webview goes and the rebuild frame builds one for [tab] from
  /// them, when the site is loaded; else they stay queued for its next
  /// build.
  static List<Write<W>> rebound<S, W>(
    Expr<S, W> site, {
    required Expr<TabId, W> tab,
    required Expr<TabId?, W> label,
    required Expr<Iterable<S>, W> loaded,
  }) {
    final isLoaded = loaded.has(site);
    return [
      builtFn<S, W>().becomes(
        builtFn<S, W>().value.except(
          site,
          to: Expr.choose(when: isLoaded, then: tab, otherwise: noTab()),
        ),
      ),
      hist<S, W>().becomes(
        hist<S, W>().value.except(
          site,
          to: Expr.choose(
            when: ~isLoaded,
            then: noTab(),
            otherwise: Expr.choose(
              when: label.neq(noTab()),
              then: label,
              otherwise: tab,
            ),
          ),
        ),
      ),
      queued<S, W>().becomes(
        Expr.choose(
          when: isLoaded,
          then: queued<S, W>().value.except(site, to: noQueued()),
          otherwise: Expr.choose(
            when: label.neq(noTab()),
            then: queued<S, W>().value.except(
              site,
              to: record({
                't': tab,
                'h': label,
              }, run: (_) => throw StateError('queued is the platform\'s')),
            ),
            otherwise: queued<S, W>().value,
          ),
        ),
      ),
    ];
  }

  /// The frame after a commit built the site's webview: bound to its
  /// active tab, showing what was queued for that tab, the queue taken,
  /// among the [loaded] sites the frame sees.
  static Act<W> framed<S, W>(
    Expr<S, W> site, {
    required SiteKeys<S, W> keys,
    required Expr<Iterable<S>, W> loaded,
  }) => Act.of([
    builtFn<S, W>().becomes(bound<S, W>(keys: keys).call([site, loaded])),
    hist<S, W>().becomes(shown<S, W>(keys: keys).call([site, loaded])),
    queued<S, W>().becomes(taken<S, W>().call([site, loaded])),
  ]);
}
