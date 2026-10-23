/// The values of the model whose engine code and TLA+ text are written
/// apart, each named once, so the code's list of them is an enum the
/// compiler holds.
library;

/// What names a value of the model whose run and text are written apart
/// (`Expr.op`, `Expr.handPaired`): [HandPaired] in the code, a test's own
/// enum in a test.
abstract interface class Pairing implements Enum {}

/// Every value of the code's tables whose run and TLA+ text are written
/// apart, one per site. Only the replay holds the two to each other, so a
/// value leaves this list when its text is read off the code (a leaf, a
/// `Def`, a tree of the core's operators). `test/declare_to_use_test.dart`
/// fails on a site that names none, and on a value no site or two sites
/// name.
enum HandPaired implements Pairing {
  /// The site on screen, the model's `current`, as the activation reads it.
  onScreen,

  /// The sites on the list (`Listed`) a pick ranges over.
  listedSites,

  /// The sites on the list a reset may send home (`Listed \cap Resettable`).
  resettableSites,

  /// The sites on the list a pick keeps (`Listed`).
  keptSites,

  /// The activation's site taken off the list (`site \in gone`).
  activationSiteGone,

  /// The activation's target while it runs (`LiveTarget`).
  liveTarget,

  /// An archive open with none of its sites gone
  /// (`Archive # {} /\ Archive \cap gone = {}`).
  archiveOpen,

  /// An archive too big to close, which the model never takes (`FALSE`).
  archiveTooBig,

  /// The sites on the list a delete may take (`Listed \cap Deletable`).
  deletableSites,

  /// The delete's site taken off the list first (`site \in gone`).
  deleteSiteGone,

  /// The back stack queued for no tab (`NoQueued`).
  noQueued,

  /// The site on screen, the model's `current`, as a tab handler reads it.
  tabSiteOnScreen,

  /// The bytes' label (`fl[f].label`), the model's alone: the code holds
  /// the bytes.
  tabLabel,

  /// The site on screen among those whose tabs the model follows
  /// (`current \in Tabbed`).
  tabbedOnScreen,

  /// A fresh tab id left in the model's pool (`HasFresh(current)`).
  hasFreshTab,

  /// The fresh tab id for the site on screen (`Mint(current)`).
  mintOnScreen,

  /// The fresh tab id for the flow's site (`Mint(fl[f].site)`).
  mintForSite,

  /// The sites with tabs a reset lands at home
  /// (`Listed \cap Resettable \cap Tabbed`).
  landedSites,

  /// The tabs a landing may name: the site's, and a fresh one while the
  /// pool has one.
  landingTabs,

  /// A close's surviving tabs (`tabs[current] \ {s}`). The code's close
  /// takes the tab's subtree, which no schedule reaches (`TabRemoveReply`'s
  /// `more` in `steps_uncovered.tsv`), so no assert can hold the two.
  tabsAfterClose,

  /// A close's closed ids (`{s}`), the subtree in the code as above.
  closedTabIds,

  /// The ids of the tabs left to install (`fl[f].rest`).
  restTabIds,

  /// The list a tab flow installs, its rest or else the site's.
  installedTabs,

  /// The tabs a target has to be among, none once the page is gone.
  targetAmong,

  /// A duplicate's source still the site's, with the page there
  /// (`fl[f].tab \in tabs[fl[f].site]`).
  duplicateSourceStays,

  /// The notification sites a wake checks headless
  /// (`IF Containers THEN Notified \ loaded ELSE {}`).
  offlineNotified,

  /// A headless check the platform refuses to open, which the model never
  /// takes (`FALSE`).
  headlessOpenRefused,

  /// The first headless check still open (`CHOOSE s \in headless : TRUE`).
  anyHeadless,

  /// A jar plan run by a flow of the model (`fl[f].kind # "none"`).
  modeledPlan,

  /// The activation's target as the jar's dispose reads it (`LiveTarget`).
  jarLiveTarget,

  /// A DNS download that fails, which the model never takes (`FALSE`).
  dnsFails,

  /// An argument of the DNS level's definition, by its name.
  levelAsk,

  /// A capture still keyed to its tab (`tab \in tabs[site]`): the key names
  /// the tab's container too, which nothing in the model flips.
  captureHolds,

  /// A capture with nothing to read (`site \in NoNavState`, or a flow that
  /// keeps no back stack).
  captureNone,

  /// The activation's target as the unload's dispose reads it (`LiveTarget`).
  unloadLiveTarget,

  /// An unload whose reason keeps the back stack, which the model knows by
  /// its flow's kind (PAUSE-007).
  unloadKeeps,
}
