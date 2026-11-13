part of 'tabs_controller.dart';

/// The places a tab flow waits at, as `activation.tla` names them: the
/// inputs, the switch (its capture, its nav read, the rebind), a close's
/// removals, a duplicate's read, write and insert, a reroute's removals,
/// and the landings that pick a tab or insert a child.
enum TabPlace {
  openTab,
  newTab,
  closeTab,
  duplicateTab,
  reroute,
  homeLanding,
  ownerRun,
  childTab,
  parkChild,
  reopenTab,
  tCap,
  tCapSave,
  tNav,
  tRebind,
  tClosed,
  tRemove,
  tDupRead,
  tDupSave,
  tDupInsert,
  tDupRemove,
  rFlip,
  rRemove,
  hLand,
  oLand,
  cLand,
  cOpen,
  pLand,
  reLand,
  reSave,
  reInsert,
  done,
}

/// A link tab its opener's switch moves to [host] (null: its [owner]).
typedef LinkFlip = ({
  WebViewModel owner,
  SiteTab tab,
  WebViewModel opener,
  SiteId? host,
});

/// What a tab flow keeps for itself: the site and tab its handler named,
/// what it minted and decided, and what it leaves the handler to finish.
/// Code-only, none of it a variable of the model.
abstract interface class TabState {
  WebViewModel get site;
  abstract List<LinkFlip> flips;
  abstract Set<WebViewModel> loadedBefore;
  abstract Map<TabId, String> dropped;
  Map<TabId, Uint8List> get taken;
  TabId? get requested;
  List<SiteTab>? get landed;
  String? get url;
  bool get subtree;
  abstract SiteTab? fresh;
  SiteId? get namedOpener;
  abstract TabCloseResult? result;
  abstract ClosedTabs? closed;
  abstract ClosedTab? reopening;
  abstract bool rebound;
  abstract bool commitAfter;
  abstract TabId? offer;
}

/// What the tab steps ask of the page and do to it, through their `page`
/// port: whether it is still there, the gate, whether the proxy is the
/// process's, a capture's start, and the redraws and rebinds a step's act
/// finishes with.
final class TabCalls {
  TabCalls(this._c, {required SitesById sites}) : _sites = sites;
  final SitesById _sites;

  final TabsController _c;

  bool get mounted => _c._host.mounted;
  bool get gateBusy => _c._gate.busy;
  bool get processGlobal => _c.residency.proxyTopology is ProcessGlobalProxy;
  bool get torRuntime => _c.residency.torAvailable;

  /// The tab table's `MovesRule(from, to)`, where no step's guard reads it.
  bool movesRule({required WebViewModel from, required WebViewModel to}) {
    final topology = _c.residency.proxyTopology;
    return topology.contends(from) || topology.contends(to) || torRuntime;
  }
  bool isShown(SiteId site) => _c._sites.vars.current.value == site;
  bool isLoaded(SiteId site) => _c._sites.vars.loaded.value.contains(site);

  NavCapture? beginCapture(SiteId site) {
    _c._host.cancelPendingCapture(site);
    return _c._host.beginNavCapture(_sites.siteOf(site));
  }

  void rebind(CommitView<TabFlow> c) => _c._rebind(c);
  void rebindAs(CommitView<TabFlow> c) => _c._rebindAs(c);
  void reroute(CommitView<TabFlow> c) => _c._reroute(c);
  void landed(CommitView<TabFlow> c) =>
      TabTable._flow.from(c).site.activeTab.lastActiveAt = DateTime.now();
  Set<WebViewModel> get loaded => {..._c._sites.loaded};

  /// An activation of [site], its input run before this returns.
  void activate(SiteId site) =>
      unawaited(_c._host.activate(_sites.siteOf(site)));
  void closed(StepView<TabFlow> c) => _c._closed(c);
  void duplicated(StepView<TabFlow> c) => _c._duplicated(c);
  void parked(StepView<TabFlow> c) => _c._parked(c);
  void reopened(StepView<TabFlow> c) => _c._reopened(c);

  /// The site [tab], a child of [owner]'s not yet listed, runs as, as
  /// [WebViewModel.tabHosts] reports it once it is.
  SiteId childHost(SiteTab tab, {required SiteId owner}) {
    final site = _sites.siteOf(owner);
    return (site.hostOf(tab) ?? site).siteId;
  }
}

/// What a child tab not listed yet follows (`link`, LIR-034), read as
/// [TabsController.linkHosts] reads a listed one's.
final class ChildLinks {
  ChildLinks(this._c, {required SitesById sites}) : _sites = sites;
  final SitesById _sites;
  final TabsController _c;

  SiteId? of(SiteTab tab, {required SiteId owner}) =>
      _c._linkOf(_sites.siteOf(owner), tab: tab)?.siteId;
}

/// What a tab flow's steps run against: the controller, the site, what the
/// handler was asked, and what the flow found on its way.
final class TabFlow implements Capturing, TabState, SitesById {
  TabFlow(
    this._c, {
    required this.site,
    this.requested,
    this.landed,
    this.url,
    this.subtree = false,
  }) : _known = _c._sites.known();

  final TabsController _c;
  @override
  final WebViewModel site;

  /// The sites the runtime found as the flow started, for an id the flow
  /// names after its site left the list.
  final Map<SiteId, WebViewModel> _known;

  @override
  WebViewModel siteOf(SiteId id) {
    final site = _c._sites.find(id) ?? _known[id];
    assert(site != null, 'a flow names a site listed or held as it ran');
    return site!;
  }

  @override
  NavCapture? capture;

  /// A reroute's flips, the loaded sites as its input found them, and each
  /// flipped tab's key under the site it left, whose file its removals take.
  @override
  List<LinkFlip> flips = const [];
  @override
  Set<WebViewModel> loadedBefore = const {};
  @override
  Map<TabId, String> dropped = const {};

  /// The back stacks a close's removals took from its tabs' files, kept
  /// for a reopen (TAB-022).
  @override
  final Map<TabId, Uint8List> taken = {};

  /// The tab the handler names (openTab, closeTab, a landing's).
  @override
  final TabId? requested;

  /// The list a reset's landing installs (TAB-014).
  @override
  final List<SiteTab>? landed;

  /// A new tab's URL when not the site's home (a search, LIR-030).
  @override
  final String? url;

  /// Whether a close takes the tab's subtree with it.
  @override
  final bool subtree;

  /// A tab this flow minted: a new tab, the home tab after the last close,
  /// a duplicate's copy.
  @override
  SiteTab? fresh;

  /// The site a child tab's press named as its opener, the input's own
  /// payload, which [fresh] carries as it lands (LIR-034). The input reads
  /// it here: a tab no list holds is no tab of the model's `opener`.
  @override
  SiteId? namedOpener;

  /// The close the engine decided.
  @override
  TabCloseResult? result;

  /// What the close takes, kept once it lands for a reopen (TAB-022).
  @override
  ClosedTabs? closed;

  /// The closed tab a reopen puts back, with the history it writes.
  @override
  ClosedTab? reopening;

  /// What the flow leaves for the handler to finish: the shell and the
  /// save a rebind owes, the offer a duplicate makes.
  @override
  bool rebound = false;
  @override
  bool commitAfter = false;
  @override
  TabId? offer;
}
