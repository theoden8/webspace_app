import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/tab_leaves.dart';
import 'package:webspace/web_view_model.dart';

/// The model's variables for a site's tabs (TAB-003), as the code reads
/// them, over any world [W]: the tab ids a site lists (`tabs[s]`), its
/// active tab (`active[s]`), the tab its one webview was built for
/// (`built[s]`, the binding's, which the frame that builds the webview
/// sets), and what the platform holds: the history the webview shows
/// (`hist[s]`), the back stack queued for the next build with the tab it
/// was read for (`queued[s]`), and each tab's saved file (`file[s][t]`),
/// each a label naming the tab whose history it is. The model keeps a
/// label only to catch a crossed one; the code holds bytes.
///
/// The rules over them are definitions here, printed as `activation_ops`:
/// what a capture stores, what a build binds, shows and takes, what an
/// activation queues.
final class TabVars {
  const TabVars._();

  static Indexed<WebViewModel, List<TabId>, W> tabs<W>() => Indexed.reported(
    ModelVar.tabs,
    read: (_, {required at}) => [for (final t in at.tabs) t.id],
  );

  static Indexed<WebViewModel, TabId, W> active<W>() =>
      Indexed.over(ModelVar.active, cell: WebViewModel.activeTabCell);

  static Indexed<WebViewModel, TabId?, W> built<W>() =>
      builtReported<WebViewModel, W>(read: (s) => s.tabBinding.built);

  /// `built` whole, for the writes the frame does.
  static Mutable<Map<WebViewModel, TabId?>, W> builtFn<W>() =>
      builtOf<WebViewModel, W>();

  static Mutable<Map<WebViewModel, TabId?>, W> hist<W>() =>
      histOf<WebViewModel, W>();

  static Mutable<Map<WebViewModel, QueuedStack>, W> queued<W>() =>
      queuedOf<WebViewModel, W>();

  static Mutable<Map<WebViewModel, Map<TabId, TabId?>>, W> file<W>() =>
      fileOf<WebViewModel, W>();

  /// The sites whose tabs the model follows; every site's in the code.
  static Members<WebViewModel, W> tabbed<W>() => tabbedOf<WebViewModel, W>();

  /// The frame builds a webview for [s] when it is a tabbed site among
  /// the loaded sites [l] it sees: one unloaded between the commit and the
  /// frame gets none, and one the same step loads gets its own.
  static Expr<bool, W> builds<W>(
    Bound<WebViewModel, W> s, {
    required Bound<Iterable<WebViewModel>, W> l,
  }) => tabbed<W>().has(s.it) & l.it.has(s.it);

  static Expr<QueuedStack, W> noQueued<W>() =>
      Expr.op('NoQueued', run: (_) => (t: null, h: null), reads: Reads.none);

  /// A capture's save stores the webview's bytes under the tab it was built
  /// for, [t], read as the capture started with the history [h] it showed;
  /// the read before it dropped a capture whose tab closed meanwhile
  /// (`NavCapture`, TAB-003).
  static Def<Map<WebViewModel, Map<TabId, TabId?>>, W> capture<W>() {
    final s = Bound<WebViewModel, W>('s');
    final t = Bound<TabId?, W>('t');
    final h = Bound<TabId?, W>('h');
    final tab = t.it.unwrapped;
    // A site the model does not follow has no tab to key by (`Tabbed`).
    return Def(
      ModelDef.capture,
      params: [s, t, h],
      body: Expr.choose(
        when: t.it.neq(noTab()),
        then: file<W>().value.exceptAt(s.it, at: tab, to: h.it),
        otherwise: file<W>().value,
      ),
    );
  }

  /// The frame that builds a site's webview binds it to the active tab.
  static Def<Map<WebViewModel, TabId?>, W> bound<W>() {
    final s = Bound<WebViewModel, W>('s');
    final l = Bound<Iterable<WebViewModel>, W>('l');
    final built = builtFn<W>().value;
    return Def(
      ModelDef.bound,
      params: [s, l],
      body: Expr.choose(
        when: builds(s, l: l),
        then: built.except(s.it, to: active<W>().at(s.it)),
        otherwise: built,
      ),
    );
  }

  /// What the built webview shows: the back stack queued for the tab it is
  /// built for, when `Takes` says the build takes it, else that tab's own
  /// fresh history (`WebViewTabBinding.take`).
  static Def<Map<WebViewModel, TabId?>, W> shown<W>() {
    final s = Bound<WebViewModel, W>('s');
    final hist = TabVars.hist<W>().value;
    final queued = TabVars.queued<W>().value.at(s.it);
    final target = active<W>().at(s.it);
    final l = Bound<Iterable<WebViewModel>, W>('l');
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
  static Def<Map<WebViewModel, QueuedStack>, W> taken<W>() {
    final s = Bound<WebViewModel, W>('s');
    final queued = TabVars.queued<W>().value;
    final l = Bound<Iterable<WebViewModel>, W>('l');
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

  /// An activation reads the active tab's saved file before the build and
  /// queues it for that tab (the nav step, and a preload's: PAUSE-035).
  static Def<Map<WebViewModel, QueuedStack>, W> staged<W>() {
    final s = Bound<WebViewModel, W>('s');
    final queued = TabVars.queued<W>().value;
    final target = active<W>().at(s.it);
    final saved = file<W>().value.at(s.it).at(target);
    return Def(
      ModelDef.staged,
      params: [s],
      body: Expr.choose(
        when: tabbed<W>().has(s.it) & saved.neq(noTab()),
        then: queued.except(
          s.it,
          to: record(
            {'t': target, 'h': saved},
            run: (_) => throw StateError('queued is the platform\'s'),
          ),
        ),
        otherwise: queued,
      ),
    );
  }

  /// `file[s][t]`: the label [tab]'s saved file holds.
  static Expr<TabId?, W> savedFor<W>(
    Expr<WebViewModel, W> site, {
    required Expr<TabId, W> tab,
  }) => file<W>().value.at(site).at(tab);

  /// [tab]'s file removed.
  static Write<W> removed<W>(Expr<WebViewModel, W> site, {required Expr<TabId, W> tab}) =>
      file<W>().becomes(file<W>().value.exceptAt(site, at: tab, to: noTab()));

  /// A duplicate's file written with what was read of its source: the
  /// source's own history becomes the copy's own; any other label stays
  /// crossed.
  static Write<W> copied<W>(
    Expr<WebViewModel, W> site, {
    required Expr<TabId, W> copy,
    required Expr<TabId, W> source,
    required Expr<TabId?, W> label,
  }) => file<W>().becomes(
    file<W>().value.exceptAt(
      site,
      at: copy,
      to: Expr.choose(when: label.eq(source), then: copy, otherwise: label),
    ),
  );

  /// What a duplicate reads of its source: the webview's back stack when
  /// the site is loaded and the webview is the source's, else its file.
  static Expr<TabId?, W> dupSource<W>(
    Expr<WebViewModel, W> site, {
    required Expr<TabId, W> source,
    required Expr<Iterable<WebViewModel>, W> loaded,
  }) => Expr.choose(
    when: loaded.has(site),
    then: Expr.choose(
      when: built<W>().at(site).eq(source),
      then: hist<W>().value.at(site),
      otherwise: noTab(),
    ),
    otherwise: savedFor(site, tab: source),
  );

  /// A tab switch's one turn, after the bytes it read for [tab] ([label]):
  /// the old webview goes and the rebuild frame builds one for [tab] from
  /// them, when the site is loaded; else they stay queued for its next
  /// build.
  static List<Write<W>> rebound<W>(
    Expr<WebViewModel, W> site, {
    required Expr<TabId, W> tab,
    required Expr<TabId?, W> label,
    required Expr<Iterable<WebViewModel>, W> loaded,
  }) {
    final isLoaded = loaded.has(site);
    return [
      builtFn<W>().becomes(
        builtFn<W>().value.except(
          site,
          to: Expr.choose(when: isLoaded, then: tab, otherwise: noTab()),
        ),
      ),
      hist<W>().becomes(
        hist<W>().value.except(
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
      queued<W>().becomes(
        Expr.choose(
          when: isLoaded,
          then: queued<W>().value.except(site, to: noQueued()),
          otherwise: Expr.choose(
            when: label.neq(noTab()),
            then: queued<W>().value.except(
              site,
              to: record(
                {'t': tab, 'h': label},
                run: (_) => throw StateError('queued is the platform\'s'),
              ),
            ),
            otherwise: queued<W>().value,
          ),
        ),
      ),
    ];
  }

  /// A capture of [site]'s back stack saved: `file' = Capture(site, t, h)`
  /// over what the capture read as it started.
  static Write<W> captured<W>(Expr<WebViewModel, W> site) => file<W>().becomes(
    capture<W>().call([site, capTab<W>().value, capHist<W>().value]),
  );

  /// The frame after a commit built the site's webview: bound to its
  /// active tab, showing what was queued for that tab, the queue taken,
  /// among the [loaded] sites the frame sees.
  static Act<W> framed<W>(
    Expr<WebViewModel, W> site, {
    required Expr<Iterable<WebViewModel>, W> loaded,
  }) => Act.of([
    builtFn<W>().becomes(bound<W>().call([site, loaded])),
    hist<W>().becomes(shown<W>().call([site, loaded])),
    queued<W>().becomes(taken<W>().call([site, loaded])),
  ]);
}
