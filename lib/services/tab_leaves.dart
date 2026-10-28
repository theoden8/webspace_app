import 'dart:typed_data';

import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';

/// A site's queued back stack as the model names it: the tab it was read
/// for and the tab whose history it is (`[t |-> .., h |-> ..]`).
typedef QueuedStack = ({TabId? t, TabId? h});

/// The model's variables for a site's tabs that the platform holds, over
/// sites of type [S] and any world [W]: the tab a site's one webview was
/// built for (`built[s]`, set by the frame that builds it), the history
/// that webview shows (`hist[s]`), the back stack queued for the next
/// build with the tab it was read for (`queued[s]`), and each tab's saved
/// file under the key of each site it may run as (`file[s][t][h]`), each a
/// label naming the tab whose history it is.
/// The model keeps a label only to catch a crossed one; the code holds
/// bytes, so a write of these prints and the platform does it. The rules
/// over them are the activation's (`TabVars`); an engine names one.
Mutable<Map<S, TabId?>, W> builtOf<S, W>() => Mutable.remote(ModelVar.built);

/// `built[s]` as the code reads it off a site's binding ([read]); the
/// frame alone writes it.
Indexed<S, TabId?, W> builtReported<S, W>({
  required TabId? Function(S site) read,
}) => Indexed.reported(ModelVar.built, read: (_, {required at}) => read(at));
Mutable<Map<S, TabId?>, W> histOf<S, W>() => Mutable.remote(ModelVar.hist);
Mutable<Map<S, QueuedStack>, W> queuedOf<S, W>() => Mutable.remote(ModelVar.queued);
Mutable<Map<S, Map<TabId, Map<S, TabId?>>>, W> fileOf<S, W>() =>
    Mutable.remote(ModelVar.file);

/// `host[s]`: the site each of a site's tabs runs as ([read], the tab's
/// host or the site itself); a file's key names it (`webViewStateKey`).
Indexed<S, Map<TabId, S>, W> hostReported<S, W>({
  required Map<TabId, S> Function(S site) read,
}) => Indexed.reported(ModelVar.host, read: (_, {required at}) => read(at));

/// No tab: `0`.
Expr<TabId?, W> noTab<W>() => Expr.constant(null, tla: '0');

/// Whether a build for [tab] takes the back stack [q] queued: only one read
/// for that tab (`Takes`, TAB-003). The binding's take runs it and `Shown`
/// prints it, so a mistake in it is the code's.
Def<bool, W> takesOf<W>() {
  final q = Bound<QueuedStack, W>('q');
  final tab = Bound<TabId?, W>('tab');
  final forTab = q.it.part('t', get: (x) => x.t);
  return Def(
    ModelDef.takes,
    params: [q, tab],
    body: forTab.neq(noTab()) & forTab.eq(tab.it),
  );
}

/// The sites whose tabs the model follows (`Tabbed`): every site's in the
/// code, so a config picks the few it checks.
Members<S, W> tabbedOf<S, W>() =>
    Members(ModelConst.tabbed, test: (_, {required member}) => true);

/// The webview went: nothing is built or shown for the site.
List<Write<W>> webViewGone<S, W>(Expr<S, W> site) => [
  builtOf<S, W>().becomes(builtOf<S, W>().value.except(site, to: noTab())),
  histOf<S, W>().becomes(histOf<S, W>().value.except(site, to: noTab())),
];

/// [webViewGone] for every site of [sites] at once.
List<Write<W>> webViewsGone<S, W>(Expr<Iterable<S>, W> sites) => [
  builtOf<S, W>().becomes(builtOf<S, W>().value.exceptAll(sites, to: noTab())),
  histOf<S, W>().becomes(histOf<S, W>().value.exceptAll(sites, to: noTab())),
];

/// What a capture of [site] reads as it starts: the tab its webview was
/// built for ([built]), the history it shows, and the site that tab runs
/// as, whose key the save writes under ([hosts]), held in the flow for the
/// file write its save makes ([captured]), since a rebind or a reroute may
/// land between.
List<Assign<W>> captureStart<S, W>(
  Expr<S, W> site, {
  required TabId? Function(S site) built,
  required Map<TabId, S> Function(S site) hosts,
}) {
  final tab = builtReported<S, W>(read: built).at(site);
  return [
    capTab<W>().becomes(tab),
    capHist<W>().fromPlatform(histOf<S, W>().value.at(site)),
    capAs<S, W>().becomes(
      Expr.choose(
        when: tab.eq(noTab()),
        then: Expr.constant<S?, W>(null, tla: '0'),
        otherwise: hostReported<S, W>(read: hosts).at(site).at(tab.unwrapped),
      ),
    ),
  ];
}

Field<TabId?, W> capTab<W>() => Field(FlowField.capTab);

/// The site whose key the capture writes under, none where it read no
/// webview.
Field<S?, W> capAs<S, W>() => Field(FlowField.capAs);

/// The history the capture read: the webview's bytes in the code, the
/// label of the tab whose history they are in the model.
Field<Uint8List?, W> capHist<W>() => Field(FlowField.capHist);

/// A capture of [site]'s back stack saved: the file write the activation
/// defines (`Capture`, TAB-003) over what the capture read as it started,
/// named here.
Write<W> captured<S, W>(Expr<S, W> site) => fileOf<S, W>().becomes(
  ModelDef.capture.over(
    [site, capTab<W>().value, capHist<W>().value, capAs<S, W>().value],
    run: (_) => throw StateError('the platform holds file'),
  ),
);

/// What [captured] wrote taken back: its tab closed or moved while the save
/// was out, so the file it wrote is under a key no tab holds.
Write<W> uncaptured<S, W>(Expr<S, W> site) => fileOf<S, W>().becomes(
  ModelDef.capture.over(
    [site, capTab<W>().value, noTab<W>(), capAs<S, W>().value],
    run: (_) => throw StateError('the platform holds file'),
  ),
);
