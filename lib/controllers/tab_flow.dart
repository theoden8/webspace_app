part of 'tabs_controller.dart';

/// The places a tab flow waits at, as `activation.tla` names them: the
/// inputs, the switch (its capture, its nav read, the rebind), a close's
/// removals, a duplicate's read, write and insert, and a reroute's
/// removals.
enum TabPlace {
  openTab,
  newTab,
  closeTab,
  duplicateTab,
  reroute,
  homeLanding,
  ownerRun,
  tCap,
  tCapSave,
  tNav,
  tRebind,
  tRemove,
  tDupRead,
  tDupSave,
  tDupInsert,
  tDupRemove,
  rFlip,
  rRemove,
  hLand,
  oLand,
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
  TabId? get requested;
  List<SiteTab>? get landed;
  String? get url;
  bool get subtree;
  abstract SiteTab? fresh;
  abstract TabCloseResult? result;
  abstract bool rebound;
  abstract bool commitAfter;
  abstract TabId? offer;
}

/// What the tab steps ask of the page and do to it, through their `page`
/// port: whether it is still there, the gate, whether the proxy is the
/// process's, a capture's start, and the redraws and rebinds a step's act
/// finishes with.
final class TabCalls {
  TabCalls(this._c);

  final TabsController _c;

  bool get mounted => _c._host.mounted;
  bool get gateBusy => _c._gate.busy;
  bool get processGlobal => _c.residency.proxyTopology is ProcessGlobalProxy;
  bool isShown(WebViewModel site) => identical(site, _c._sites.shown);
  bool isLoaded(WebViewModel site) => _c._sites.loaded.contains(site);

  NavCapture? beginCapture(WebViewModel site) {
    _c._host.cancelPendingCapture(site.siteId);
    return _c._host.beginNavCapture(site);
  }

  void rebind(CommitView<TabFlow> c) => _c._rebind(c);
  void rebindAs(CommitView<TabFlow> c) => _c._rebindAs(c);
  void reroute(CommitView<TabFlow> c) => _c._reroute(c);
  void landed(CommitView<TabFlow> c) =>
      TabTable._flow.from(c).site.activeTab.lastActiveAt = DateTime.now();
  Set<WebViewModel> get loaded => {..._c._sites.loaded};

  /// An activation of [site], its input run before this returns.
  void activate(WebViewModel site) => unawaited(_c._host.activate(site));
  void closed(StepView<TabFlow> c) => _c._closed(c);
  void duplicated(StepView<TabFlow> c) => _c._duplicated(c);
}

/// What a tab flow's steps run against: the controller, the site, what the
/// handler was asked, and what the flow found on its way.
final class TabFlow implements Capturing, TabState {
  TabFlow(
    this._c, {
    required this.site,
    this.requested,
    this.landed,
    this.url,
    this.subtree = false,
  });

  final TabsController _c;
  @override
  final WebViewModel site;

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

  /// The close the engine decided.
  @override
  TabCloseResult? result;

  /// What the flow leaves for the handler to finish: the shell and the
  /// save a rebind owes, the offer a duplicate makes.
  @override
  bool rebound = false;
  @override
  bool commitAfter = false;
  @override
  TabId? offer;
}
