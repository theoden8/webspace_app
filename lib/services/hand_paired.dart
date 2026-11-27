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


  /// An archive open with none of its sites gone
  /// (`Archive # {} /\ Archive \cap gone = {}`).
  archiveOpen,



  /// The site on screen, the model's `current`, as a tab handler reads it.
  tabSiteOnScreen,

  /// The bytes' label (`fl[f].label`), the model's alone: the code holds
  /// the bytes.
  tabLabel,

  /// The site on screen among those whose tabs the model follows
  /// (`current \in Tabbed`).
  tabbedOnScreen,

  /// The listed sites with tabs a child tab may open in: those with a
  /// fresh tab id left in the model's pool.
  childSites,

  /// The sites a child tab may run as: any listed site where containers
  /// keep their cookies apart (LIR-032), else its own.
  childHosts,

  /// The site a child tab runs as while its opener routes outbound links,
  /// none (`0`) for one no link opened (LIR-034).
  childLinks,

  /// The site whose switch a child tab follows, which its handler names as
  /// the link is pressed: the page's, or the tab it is a sibling of; none
  /// (`0`) for one no link opened (LIR-034).
  childOpeners,

  /// The tabs a landing may name: the site's, and a fresh one while the
  /// pool has one.
  landingTabs,

  /// The tabs a target has to be among, none once the page is gone.
  targetAmong,

  /// A duplicate's source still the site's, with the page there
  /// (`fl[f].tab \in tabs[fl[f].site]`).
  duplicateSourceStays,

  /// The notification sites a wake checks headless
  /// (`IF Containers THEN (Notified \cap Listed) \ loaded ELSE {}`): a site
  /// off the list has no candidate to check.
  offlineNotified,

  /// The first headless check still open (`CHOOSE s \in headless : TRUE`).
  anyHeadless,

  /// A jar plan run by a flow of the model (`fl[f].kind # "none"`).
  modeledPlan,

  /// The levels a prune may drop as it is asked: any held but the app-wide
  /// level and those a listed site asks for (DNS-021).
  dnsPrunes,

  /// An argument of the DNS level's definition, by its name.
  levelAsk,

  /// A capture still keyed to its tab (`tab \in tabs[site]`): the key names
  /// the tab's container too, which nothing in the model flips.
  captureHolds,

  /// A capture with nothing to read (`site \in NoNavState`, or a flow that
  /// keeps no back stack).
  captureNone,

  /// An unload whose reason keeps the back stack, which the model knows by
  /// its flow's kind (PAUSE-007).
  unloadKeeps,
}
