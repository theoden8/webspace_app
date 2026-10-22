/// The model's names, each declared once: its variables, a flow's fields,
/// the engines' operators, the base's, and what a step reads of them. The
/// step tables' leaves take their names from here, and the printer
/// iterates these to write the model's declarations.
library;

import 'package:webspace/services/activation_step.dart';

/// Every variable of `formal/activation.tla`, in the order its module
/// declares them, with the comment that declaration prints: the one place
/// a variable is named. Every leaf takes its name from here, the printer
/// writes the `VARIABLES` block and every action's frame from here
/// (`activation_vars`), so a variable left out of a frame or named twice
/// cannot happen.
enum ModelVar {
  rows(
    'rows[q]: the site at position q',
    type: r'rows \in [Pos -> Sites]',
  ),
  loaded(
    'sites with a webview (SiteRuntime.loaded)',
    type: r'loaded \subseteq Sites',
  ),
  current(
    'site on screen, 0 for home (SiteRuntime.shown)',
    type: r'current \in Sites \cup {0}',
  ),
  version(
    'SiteRuntime.activationVersion',
    type: r'version \in Nat',
  ),
  marker(
    'SiteRuntime.activating: [t |-> site, v |-> version]',
    type: r'marker \in [t : Sites \cup {0}, v : Nat]',
  ),
  tier(
    'tier[s]: "resident", "cleared" (cacheCleared) or "saved" (savedForRestore)',
    type: r'tier \in [Sites -> {"resident", "cleared", "saved"}]',
  ),
  jar(
    'sites whose session the shared jar holds',
    type: r'jar \subseteq Sites',
  ),
  stored(
    "stored[s]: sites whose session s's storage holds",
    type: r'stored \in [Sites -> SUBSET Sites]',
  ),
  signedIn(
    'sites whose page set a session (ghost)',
    type: r'signedIn \subseteq Sites',
  ),
  holder(
    "the flow holding the jar's turn, 0 for none",
    type: r'holder \in Flows \cup {0}',
  ),
  queue(
    'flows waiting for the turn, in order; 0 is the jar clear queued at launch',
    type: r'queue \in Seq(Flows \cup {0})',
  ),
  fl(
    'fl[f]: the flow the f-th input started',
    type: r'fl \in [Flows -> FlowRecord]',
  ),
  inputs(
    'inputs so far',
    type: r'inputs \in Nat',
  ),
  newest(
    'the flow of the newest activation, 0 after home (ghost)',
    type: r'newest \in Flows \cup {0}',
  ),
  evictedShown(
    'a priority-picked unload disposed a protected site (ghost)',
    type: r'evictedShown \in BOOLEAN',
  ),
  seen(
    'the reachability witnesses met (ghost)',
    type: r'seen \subseteq STRING',
  ),
  last(
    'the step just taken: action, flow, outcome, site (ghost)',
    type: r'last.a = "init" \/ last.o \in Outcomes[last.a]',
  ),
  tabs(
    "tabs[s]: the ids of s's tabs (WebViewModel.tabs)",
    type: r'tabs \in [Sites -> SUBSET TabIds]',
  ),
  active(
    'active[s]: its active tab (activeTabId)',
    type: r'active \in [Sites -> TabIds]',
  ),
  built(
    'built[s]: the tab its webview was built for, 0 for none (WebViewTabBinding.built)',
    type: r'built \in [Sites -> TabIds \cup {0}]',
  ),
  hist(
    "hist[s]: the tab whose history the webview shows, 0 for none (the bytes' label)",
    type: r'hist \in [Sites -> TabIds \cup {0}]',
  ),
  queued(
    'queued[s]: the back stack queued for the next build: the tab it was read for and the tab whose history it is (WebViewTabBinding.queued)',
    type: r'queued \in [Sites -> [t : TabIds \cup {0}, h : TabIds \cup {0}]]',
  ),
  file(
    "file[s][t][h]: the tab whose history t's saved file under h's key holds, 0 for no file (WebViewStateStorage, webViewStateKey)",
    type: r'file \in [Sites -> [TabIds -> [Sites -> TabIds \cup {0}]]]',
  ),
  minted(
    'minted[s]: the last tab id s took (environment)',
    type: r'minted \in [Sites -> TabIds]',
  ),
  host(
    'host[s][t]: the site tab t of s runs as, s for its own (SiteTab.hostSiteId, LIR-018)',
    type: r'host \in [Sites -> [TabIds -> Sites]]',
  ),
  link(
    'link[s][t]: the site tab t of s runs as while s routes outbound links, 0 for a tab no link opened (SiteTab.followsOpener, LIR-034)',
    type: r'link \in [Sites -> [TabIds -> Sites \cup {0}]]',
  ),
  nested(
    'the site whose nested screen is up, 0 for none (SiteRuntime.nested)',
    type: r'nested \in Sites \cup {0}',
  ),
  headless(
    'sites a background wake checks in a headless webview (SiteRuntime.headless)',
    type: r'headless \subseteq Sites',
  ),
  fore(
    'the app on screen (environment)',
    type: r'fore \in BOOLEAN',
  ),
  dns(
    '[lvl |-> the app-wide DNS level, levels |-> the levels whose lists are downloaded] (DnsBlockService)',
    type: r'dns \in [lvl : 0..5, levels : SUBSET (1..5)]',
  ),
  told(
    "told[s]: the DNS level s's webview told its native interceptor, -1 for none (ViewBlockers)",
    type: r'told \in [Sites -> -1..5]',
  ),
  gone(
    'sites that left the list (SiteRuntime.models)',
    type: r'gone \subseteq Sites',
  ),
  views(
    'sites whose webview is mounted, binding its container (the platform)',
    type: r'views \subseteq Sites',
  ),
  boxes(
    'archive-tier sites whose container is on disk (ContainerNative)',
    type: r'boxes \subseteq Sites',
  );

  const ModelVar(this.doc, {required this.type});

  /// What the declaration says of it.
  final String doc;

  /// The values it can hold, as a predicate over it: a conjunct of the
  /// printed `TypeOK`.
  final String type;
}

/// Every field a flow's record carries (`fl[f].<field>`), with what it is
/// when no flow runs (`NoFlow`, printed from here): the one place a field
/// is named, which every [Field] takes its name from.
enum FlowField {
  kind('"none"', range: r'FlowKinds'),
  pc('"done"', range: r'Places'),
  site('0', range: r'Sites \cup {0}'),
  v('0', range: r'Nat'),
  victims('{}', range: r'SUBSET Sites'),
  clears('{}', range: r'SUBSET Sites'),
  picked('{}', range: r'SUBSET Sites'),
  victim('0', range: r'Sites \cup {0}'),
  snap('{}', range: r'SUBSET Sites'),
  ls('{}', range: r'SUBSET Sites'),
  todo('{}', range: r'SUBSET Sites'),
  tmp('{}', range: r'SUBSET Sites'),
  unloaded('FALSE', range: r'BOOLEAN'),
  tab('0', range: r'TabIds \cup {0}'),
  keep('FALSE', range: r'BOOLEAN'),
  rest('{}', range: r'SUBSET TabIds'),
  closing('{}', range: r'SUBSET TabIds'),
  copy('0', range: r'TabIds \cup {0}'),

  /// The site a duplicate's copy runs as, its source's when the copy was
  /// made, whose key its file takes.
  copyAs('0', range: r'Sites \cup {0}'),
  label('0', range: r'TabIds \cup {0}'),
  wrote('FALSE', range: r'BOOLEAN'),

  /// What a capture read as it started: the webview's tab, the history it
  /// showed and the site whose key it writes under, held for the file
  /// write its reply makes (`Capture`).
  capTab('0', range: r'TabIds \cup {0}'),
  capHist('0', range: r'TabIds \cup {0}'),
  capAs('0', range: r'Sites \cup {0}'),

  /// The site whose key an activation's read of its target's saved back
  /// stack names, as the read started (`Staged`).
  navAs('0', range: r'Sites \cup {0}'),

  /// The notification sites a wake has still to check headless.
  checks('{}', range: r'SUBSET Sites'),

  /// The sites a webspace switch stops showing, which its plan unloads
  /// once the device is online (WEBSPACE-013).
  away('{}', range: r'SUBSET Sites'),

  /// The site an activation the switch superseded was opening, which goes
  /// on loading behind the list instead of going with the rest
  /// (WEBSPACE-013).
  behind('0', range: r'Sites \cup {0}'),

  /// The DNS level a download fetches, and whether it becomes the
  /// app-wide level.
  lvl('0', range: r'0..5'),
  appWide('FALSE', range: r'BOOLEAN'),

  /// A call of the restore on the shared jar was refused, so its target is
  /// not shown once the rest of the refill is written (ISO-014).
  unrestored('FALSE', range: r'BOOLEAN');

  const FlowField(this.none, {required this.range});

  /// Its value in `NoFlow`.
  final String none;

  /// The values it can hold: its field of the printed `FlowRecord`.
  final String range;
}

/// What a constant of the model is where no world sets it, which a need
/// of it is measured against: a set empty, a switch off or on, a function
/// the same at every site, a bound the device's, or data no world changes.
enum ConstKind { set, off, on, uniform, bound, fixed }

/// Every constant of the model a table reads, named once: the leaves that
/// read one ([Constant], [Members], `Indexed.fixed`) take its name from
/// here, and a world sets one (`Env`) or leaves it as the base gives it.
/// One the base defines over others is set wherever one of them is
/// ([follows]).
enum ModelConst {
  containers(ConstKind.off, range: r'BOOLEAN'),
  coldStart(ConstKind.off, range: r'BOOLEAN'),
  tabbed(ConstKind.set, range: r'SUBSET Sites'),
  maxTabs(ConstKind.bound, range: r'Nat'),
  routed(ConstKind.set, range: r'SUBSET Sites'),
  contending(ConstKind.set, range: r'SUBSET Sites'),
  globalProxy(ConstKind.off, range: r'BOOLEAN'),
  links(ConstKind.set, range: r'SUBSET [s : Sites, t : TabIds, h : Sites]'),
  route(ConstKind.uniform, range: r'[Sites -> Nat]'),
  torExit(ConstKind.uniform, range: r'[Sites -> Nat]'),
  torRuntime(ConstKind.off, range: r'BOOLEAN'),
  maxLoaded(ConstKind.bound, range: r'Nat'),
  maxResident(ConstKind.bound, range: r'Nat'),
  linked(ConstKind.set, range: r'SUBSET Sites'),
  proxyRefused(ConstKind.off, range: r'BOOLEAN'),
  jarRefuses(ConstKind.off, range: r'BOOLEAN'),
  notified(ConstKind.set, range: r'SUBSET Sites'),
  waking(ConstKind.off, range: r'BOOLEAN'),
  siteLevel(ConstKind.uniform, range: r'[Sites -> -1..5]'),
  dnsLevels(ConstKind.set, range: r'SUBSET (1..5)'),
  away(ConstKind.set, range: r'SUBSET SUBSET Sites'),
  online(ConstKind.on, range: r'BOOLEAN'),
  archive(ConstKind.set, range: r'SUBSET Sites'),
  deletable(ConstKind.set, range: r'SUBSET Sites'),
  resettable(ConstKind.set, range: r'SUBSET Sites'),
  boxed(ConstKind.set, range: r'SUBSET Sites', follows: {archive, deletable}),
  incognito(ConstKind.set, range: r'SUBSET Sites', follows: {archive}),
  noNavState(ConstKind.set, range: r'SUBSET Sites', follows: {archive, incognito}),
  sites(ConstKind.fixed, range: r'SUBSET Nat'),
  base(ConstKind.fixed, range: r'[Sites -> Nat]');

  const ModelConst(this.kind, {required this.range, this.follows = const {}});

  final ConstKind kind;
  final Set<ModelConst> follows;

  /// The values a world may give it, which a proof assumes.
  final String range;

  /// Its name in the model: the enum's, capitalised.
  String get tla => '${name[0].toUpperCase()}${name.substring(1)}';
}

/// A constant a value needs to hold: [of] set by the world, or left as
/// the base gives it ([set] false). A condition's needs are what must
/// hold for it to be true, a set's what must hold for it to be non-empty;
/// each is necessary, never sufficient, so an action no world gives its
/// needs is one no world takes.
typedef Need = ({ModelConst of, bool set});

/// Every operator an engine defines ([Def]), named once: the printer
/// answers each with the definition that owns it, in a `switch` the
/// compiler holds exhaustive, so a definition cannot be left unprinted.
enum ModelDef {
  evictable,
  running,
  runsAs,
  midActivation,
  pressureResident,
  pressureCleared,
  stale,
  conflicts,
  proxyContenders,
  torDissenters,
  routeFree,
  ruled,
  kept,
  picked,
  spare,
  gone,
  share,
  tabBusy,
  capture,
  bound,
  takes,
  shown,
  taken,
  staged,
  resolveLevel;

  /// Its name in the model: the enum's, capitalised.
  String get tla => '${name[0].toUpperCase()}${name.substring(1)}';
}

/// The operators of the hand-written model (`activation_base.tla`) that a
/// table's text calls and that read its state, with what each reads and
/// writes of it, which the footprint gate holds to the definition's text.
/// The base's constant data (`Routed`, `Archive`) reads nothing and is not
/// named.
enum BaseOp {
  kinds(reads: {ModelVar.fl}),
  listed(reads: {ModelVar.gone}),

  /// The newest tap's target while it stands: that row's version and site.
  liveTarget(
    reads: {ModelVar.fl, ModelVar.newest, ModelVar.version},
    rows: {
      (kind: FlowKind.tap, field: FlowField.v),
      (kind: FlowKind.tap, field: FlowField.site),
    },
  ),
  hasFresh(reads: {ModelVar.minted}),
  mint(reads: {ModelVar.minted}),
  enqueue(reads: {ModelVar.holder, ModelVar.queue}, writes: {ModelVar.queue}),
  takeTurn(reads: {ModelVar.queue}, writes: {ModelVar.holder, ModelVar.queue}),
  passTurn(reads: {ModelVar.queue}, writes: {ModelVar.holder, ModelVar.queue}),
  release(writes: {ModelVar.holder}),
  granted(reads: {ModelVar.holder, ModelVar.queue}),

  /// An input, which lands only where `Lands` lets it: on the page when no
  /// nested screen covers it, and on screen unless the OS made it.
  input(reads: {ModelVar.fore, ModelVar.nested});

  const BaseOp({this.reads = const {}, this.writes = const {}, this.rows = const {}});

  /// The model's variables its definition reads and writes, apart from
  /// the checkers' own (`last`, `inputs`, `seen`).
  final Set<ModelVar> reads;
  final Set<ModelVar> writes;

  /// The other flows' rows it reads, as [Reads.rows] says them.
  final Set<RowRead> rows;

  /// Its name in the model: the enum's, capitalised.
  String get tla => '${name[0].toUpperCase()}${name.substring(1)}';
}

/// A read of other flows' rows: [field] of every row of [kind]. A flow
/// writes only its own row, so the read meets only the steps that can run
/// in a row of [kind] and write [field] (`activation_footprints.tsv`).
typedef RowRead = ({FlowKind kind, FlowField field});

/// What one arm of a step does to its flow's own row, as the composition
/// reads it: the places it may go to (each with what going there needs,
/// when the next place is a choice), the kind it gives the flow when it
/// sets one, the fields it writes, whether it ends the flow (every field
/// back to `NoFlow`), what the model's constants must be for it to be
/// taken ([needs]), the kinds of flow it is taken for ([only], null
/// for any), the rows of the flows it starts ([spawns]), and the shared
/// variables it writes, the flows it starts' with them ([writes]).
typedef ArmRow = ({
  Map<String, Set<Need>> next,
  FlowKind? kind,
  bool ends,
  Set<FlowField> fields,
  Set<Need> needs,
  Set<ModelVar> writes,
  Set<FlowKind>? only,
  List<SpawnRow> spawns,
});

/// The row of a flow an arm starts in its own turn (`Spawn`): the kind its
/// input gives it, the places it goes to, the fields it writes, and what
/// starting it needs beyond the arm.
typedef SpawnRow = ({
  FlowKind kind,
  Map<String, Set<Need>> next,
  Set<FlowField> fields,
  Set<Need> needs,
});

/// One step's action as the composition reads it: the place it waits at,
/// what it reads and writes of the shared state, what the model's
/// constants must be for it to be taken at all ([needs]: its input's
/// condition and the set it picks from), and its arms' rows.
typedef Footprint = ({
  ActivationStep step,
  String place,
  bool input,
  Reads reads,
  Set<ModelVar> writes,
  Set<Need> needs,

  /// The variables an input's guard reads (`enabled`): an input that writes
  /// one of them is what lets it land.
  Set<ModelVar> guard,
  List<ArmRow> arms,
});

/// What a value of a step reads of the model's shared state: its
/// variables, the engines' definitions it calls by name, the base's
/// operators, and the fields of other flows' rows it reads, by kind. A
/// flow's own row (`fl[f]`) is its own and is not here. Every leaf says
/// what it reads and every operator unions its operands', so an action's
/// footprint is a function of its declarations
/// (`activation_footprints.tsv`).
final class Reads {
  const Reads({
    this.vars = const {},
    this.defs = const {},
    this.base = const {},
    this.rows = const {},
  });

  final Set<ModelVar> vars;
  final Set<ModelDef> defs;
  final Set<BaseOp> base;
  final Set<RowRead> rows;

  static const none = Reads();

  Reads operator +(Reads other) => Reads(
    vars: {...vars, ...other.vars},
    defs: {...defs, ...other.defs},
    base: {...base, ...other.base},
    rows: {...rows, ...other.rows},
  );

  /// Everything [all] read.
  static Reads of(Iterable<Reads> all) => all.fold(none, (a, b) => a + b);
}
