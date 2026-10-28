import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/tab_leaves.dart';
import 'package:webspace/services/url_host.dart';
import 'package:webspace/utils/concurrency.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/cookie_manager.dart';

/// Whether [cookie] is on [baseDomain]: the model's `Base[x] = Base[s]`.
bool cookieMatchesBaseDomain(Cookie cookie, {required String baseDomain}) =>
    baseDomain.isNotEmpty && cookieBase(cookie) == baseDomain.toLowerCase();

/// Where an unload waits, by the model's `pc` names: the unload engine's
/// loop over its plan (`SiteUnloadEngine.unloadFlow`), with the jar's turn
/// nested in it at [uTurn], [uCap], [uSave] and [uKept]; [applied] and
/// [exit] are the activation's, where the loop ends.
enum UnloadPlace {
  next,
  uNav,
  uNavSave,
  uNavUnsave,
  uCaptured,
  uTurn,
  uCap,
  uSave,
  uKept,
  afterUnload,
  nextClear,
  cc,
  applied,
  exit,
}

/// The model's `tier[s]`: a site's lifecycle state, which every table that
/// moves a site between the tiers reads and writes through this.
Indexed<WebViewModel, SiteLifecycleState, W> tierOf<W>() =>
    Indexed.over(ModelVar.tier, cell: WebViewModel.tierCell);

/// The model's `Base[x]`: the base domain of a site, or of a cookie
/// ([cookieBase]), so a site's share of the jar is the cookies on its base.
Indexed<Object, String, W> baseOf<W>() => Indexed.fixed(
  ModelConst.base,
  read: (_, {required at}) => switch (at) {
    WebViewModel(:final initUrl) => getBaseDomain(initUrl),
    Cookie() => cookieBase(at),
    _ => throw ArgumentError.value(at, 'at', 'has no base domain'),
  },
);

/// The base domain a cookie is on: its domain, leading dot and case aside,
/// resolved as a site's host is.
String cookieBase(Cookie cookie) {
  var domain = (cookie.domain ?? '').trim().toLowerCase();
  if (domain.startsWith('.')) domain = domain.substring(1);
  return domain.isEmpty ? '' : getBaseDomain('https://$domain/');
}

/// The model's `Incognito`: the sites that keep nothing to capture or
/// restore, and conflict with no other on the shared jar.
Members<WebViewModel, W> incognitoOf<W>() => Members(
  ModelConst.incognito,
  test: (_, {required member}) => member.effectiveIncognito,
);

/// The variables an unload's dispose reads in world [W]: the loaded sites
/// it writes, and what says whether its victim may go.
typedef UnloadLeaves<W> = ({
  Mutable<Iterable<WebViewModel>, W> loaded,
  Expr<bool, W> picked,
  Expr<WebViewModel?, W> current,
  Expr<WebViewModel?, W> liveTarget,
});

/// The webview goes: the site leaves [UnloadLeaves.loaded] and moves to
/// "saved", the tier memory pressure never picks (the dispose, not the
/// capture before it, so a spared site keeps its own); and the site was
/// neither on screen under a priority pick nor the live activation's
/// target, which the model keeps as the ghost `evictedShown` and the code
/// asserts here (PAUSE-006, BUG-033). Every flow of the model has a kind;
/// a plan outside it (a settings save, a tab's, a home reset) keeps its
/// own staleness and is not held to the invariant.
Act<W> disposeOf<W>(
  Field<WebViewModel, W> victim, {
  required UnloadLeaves<W> over,
  required void Function(StepView<W> c) then,
}) {
  final kind = Field<Object?, W>(FlowField.kind);
  final modeled = Expr.handPaired<bool, W>(
    HandPaired.modeledPlan,
    tla: 'fl[f].kind # "none"',
    run: kind.isSet,
    reads: Reads.none,
  );
  return Act.of(
    [
      over.loaded.becomes(over.loaded.value.without(victim.value)),
      tierOf<W>().except(
        victim.value,
        to: Expr.constant(SiteLifecycleState.savedForRestore, tla: '"saved"'),
      ),
      ...webViewGone<WebViewModel, W>(victim.value),
      ghost(
        ModelVar.evictedShown,
        never:
            modeled &
            ((over.picked & over.current.eq(victim.value)) |
                over.liveTarget.eq(victim.value)),
        why:
            'an unload disposed the site on screen or the live activation\'s '
            'target (PAUSE-006, BUG-033)',
      ),
    ],
    then: (c) {
      final site = victim.of(c);
      site.disposeWebView(commit: c.commit);
      LogTag.cookieIsolation.debug(
        'Disposed webview for "${site.name}"',
        sensitive: true,
      );
      then(c);
    },
  );
}

/// The eviction backed off: a witness the model keeps.
Act<W> backoff<W>() =>
    modelOnly(
      'seen\' = seen \\cup {"backoff"}',
      writes: {ModelVar.seen},
      reads: const Reads(vars: {ModelVar.seen}),
    );

/// Memory pressure disposed a site while an activation ran: a witness.
Act<W> evictedMid<W>() => modelOnly(
  'seen\' = seen \\cup (IF Picked(f) /\\ MidActivation '
  'THEN {"evictMidActivation"} ELSE {})',
  writes: {ModelVar.seen},
  reads: const Reads(vars: {ModelVar.seen}, defs: {ModelDef.midActivation, ModelDef.picked}),
);

/// Back to the unload engine's loop over its plan: the victim is spent, and
/// the flow remembers that it disposed a site.
List<Effect<W>> unloadReturn<W>(
  Field<WebViewModel, W> victim, {
  required bool disposed,
}) => [
  victim.cleared(none: 0),
  if (disposed)
    Field<bool, W>(FlowField.unloaded).becomes(Expr.constant(true, tla: 'TRUE')),
];

/// Where a restore waits; [html] and [exit] are the activation's, where it
/// goes once the jar is refilled or when it was superseded.
enum RestorePlace {
  rTurn,
  rSnap,
  rSave,
  rNuke,
  rLoad,
  rSetT,
  rSetO,
  rRefused,
  html,
  exit,
}

/// Pure cookie-isolation logic, extracted so tests can exercise the real
/// code with mocked [CookieManager] and [CookieSecureStorage] instead of
/// re-implementing the orchestration in a test harness.
///
/// The engine operates on the page's loaded sites, passed into each method:
/// an unload's dispose takes its site out. All native cookie-jar writes go through
/// [cookieManager]; all per-site persistence goes through [storage].
///
/// Every operation takes its turn on the jar, one at a time (ISO-003): a
/// capture that read the jar while another operation had emptied it would
/// save the emptiness as the loaded sites' sessions (BUG-032). The turn is
/// a [JarTurn], made only by [_turn], and every read the engine saves and
/// every write it makes takes one, so code outside a turn cannot reach
/// them. A superseded activation's restore still bails at its version
/// checks, callers passing a version captured at entry and a
/// current-version getter.
///
/// The restore and the unload's capture are step tables ([restoreSteps],
/// [unloadSteps]): each step is written once, with what it does here and
/// what it is in `formal/activation.tla` side by side, and the model's
/// actions for them are printed from the tables.
class CookieIsolationEngine {
  final CookieManager _cookies;
  final CookieSecureStorage _storage;

  final SerialQueue _turns = SerialQueue('jarTurns');

  /// Between a restore's nuke and the end of its refill.
  bool _emptied = false;

  /// The flow whose turn on the jar it is.
  StepContext<JarWorld>? _holder;

  /// One turn on the jar: [body] runs with the turn as its proof, [flow],
  /// when the turn is a table's, as its holder.
  Future<T> _turn<T>(
    Future<T> Function(JarTurn turn) body, {
    StepContext<JarWorld>? flow,
  }) => _turns.run(() async {
    assert(_holder == null, 'two flows hold the jar\'s turn');
    _holder = flow;
    try {
      return await body(JarTurn._());
    } finally {
      _holder = null;
    }
  });

  CookieIsolationEngine({
    required CookieManager cookieManager,
    required CookieSecureStorage storage,
  }) : _cookies = cookieManager,
       _storage = storage;

  /// What the jar holds for [url], for the cookie inspector: a read nothing
  /// is saved from, so it takes no turn.
  Future<List<Cookie>> cookiesAt(Uri url) => _cookies.getCookies(url: url);

  /// The inspector's delete of one cookie.
  Future<void> deleteCookie(Cookie cookie, {required Uri url}) => _turn(
    (_) => _cookies.deleteCookie(
      url: url,
      name: cookie.name,
      domain: cookie.domain,
      path: cookie.path ?? '/',
    ),
  );

  // ── The jar and the stored sessions, in a turn ─────────────────────────

  /// The jar's cookies for [of]: the whole jar where the platform gives it,
  /// every URL of [of] where it is read per URL ([_candidateUrlsFor]).
  Future<List<Cookie>> _snapshot(
    JarTurn turn, {
    required Iterable<WebViewModel> of,
  }) {
    assert(!_emptied, 'a capture read the jar a restore emptied (BUG-032)');
    return _cookies.getAllCookies(candidateUrls: _candidateUrlsFor(of));
  }

  Future<void> _empty(JarTurn turn) => _cookies.deleteAllCookies();

  Future<List<Cookie>> _loadStored(
    JarTurn turn, {
    required WebViewModel site,
  }) => _storage.loadCookiesForSite(site.siteId);

  Future<void> _saveStored(
    JarTurn turn, {
    required WebViewModel site,
    required List<Cookie> cookies,
  }) => _storage.saveCookiesForSite(site.siteId, cookies: cookies);

  /// Empties the jar in its turn when no site is loaded then: at launch,
  /// queued before any site can be tapped, which makes it the jar's first
  /// turn, and after an import that activated nothing. What the jar holds
  /// then is no loaded site's, and a share of it saved as one's would hand
  /// that site another's session or a deleted one's (ISO-003). Emptied with
  /// a site loaded, the jar would lose that site's session, so then it
  /// keeps the jar as it is.
  Future<void> clearUnloaded({required Iterable<WebViewModel> loaded}) =>
      _turn((turn) async {
        if (loaded.isNotEmpty) return;
        await _empty(turn);
        ActivationSteps.mark(ActivationStep.clearJar);
      });

  /// Captures [site]'s cookies to siteId-keyed storage, then disposes its
  /// webview and takes it out of [loaded]; every unload reason comes through
  /// here (ISO-002).
  ///
  /// The native jar keeps the site's cookies until the next activation's
  /// [restoreCookiesForSite], which attributes the jar to the loaded sites
  /// only and then empties it, so this capture is all the site keeps.
  ///
  /// [spared], asked after the capture, keeps the site loaded instead;
  /// [disposed] runs right after the dispose, inside the jar's turn.
  ///
  /// A jar that cannot be read leaves the set the site last saved where it
  /// is, and the unload goes on: what unloads a site (a conflict, a cap,
  /// memory) does not wait for the jar (ISO-014).
  Future<void> unloadSiteForDomainSwitch({
    required WebViewModel site,
    required UnloadWorld world,
  }) async {
    final flow = StepContext(world);
    _victim.put(flow, value: site);
    await unloadInTurn(flow, from: UnloadPlace.uTurn);
  }

  /// The unload engine's flow at the jar's places: [unloadSteps] from
  /// [from], in the jar's turn, until it leaves them.
  Future<UnloadPlace> unloadInTurn(
    StepContext<UnloadWorld> flow, {
    required UnloadPlace from,
  }) => _turn(flow: flow, (turn) {
    flow.world.turn = turn;
    return unloadSteps.run(flow, from: from);
  });

  /// Restores cookies for [site] before it's activated:
  ///
  ///   1. Snapshot ALL native cookies via `getAllCookies()` (not URL-scoped
  ///      — that would miss sibling-subdomain cookies).
  ///   2. Attribute to every loaded non-incognito site (including target
  ///      if already loaded, so its live session is persisted before the
  ///      nuke) by base-domain match and save to siteId-keyed storage.
  ///   3. Nuke the native jar to evict cookies from deleted/legacy sites.
  ///   4. Restore target's cookies from storage, then every other
  ///      still-loaded site's cookies (parallel-loaded sites share the
  ///      native jar and must not lose their sessions).
  ///
  /// [versionAtEntry] against [vars]' version is the race guard: the
  /// restore bails after each await before the nuke if a newer caller has
  /// bumped the version, and never after it: once emptied, the jar is
  /// refilled before the turn passes on (BUG-032).
  ///
  /// False when the jar refused a read, the nuke or a write, which leaves
  /// the target unshown (ISO-014): a read that fails saves nothing and
  /// empties nothing, and a write that fails leaves the rest of the refill
  /// to run first, so the jar holds all of the stored sets the platform
  /// takes.
  Future<bool> restoreCookiesForSite({
    required WebViewModel site,
    required RuntimeVars<WebViewModel> vars,
    required int versionAtEntry,
  }) async {
    final flow = StepContext(RestoreWorld(engine: this, vars: vars));
    _target.put(flow, value: site);
    _v.put(flow, value: versionAtEntry);
    await restoreInTurn(flow, from: RestorePlace.rTurn);
    return !_unrestored.valueOr(none: false).run(flow);
  }

  /// The activation's flow at the jar's places: [restoreSteps] from [from],
  /// in the jar's turn, until it leaves them. Once emptied, the jar is
  /// refilled before the turn passes on (BUG-032).
  Future<RestorePlace> restoreInTurn(
    StepContext<RestoreWorld> flow, {
    required RestorePlace from,
  }) => _turn(flow: flow, (turn) async {
    flow.world.turn = turn;
    try {
      return await restoreSteps.run(flow, from: from);
    } finally {
      _emptied = false;
    }
  });

  // ── The steps ───────────────────────────────────────────────────────────

  /// The model's variables as the jar's steps read them: the turn's holder
  /// and the loaded sites, which the queue and the unloads write; the jar
  /// and the stored sessions, the platform's, which only a call reaches.
  static Var<Object?, W> _turnHolder<W extends JarWorld>() =>
      Var(ModelVar.holder, read: (w) => w.engine._holder);
  static Mutable<Iterable<WebViewModel>, W> _loaded<W extends JarWorld>() =>
      Mutable.over(ModelVar.loaded, of: (w) => w.vars.loaded);
  static Mutable<List<Cookie>, W> _jar<W>() => Mutable.remote(ModelVar.jar);
  static Indexed<WebViewModel, List<Cookie>, W> _stored<W>() =>
      Indexed.remote(ModelVar.stored);

  /// The platform's jar as a step in the turn reaches it.
  static Port<_JarCalls, W> _jarPort<W extends JarWorld>() => Port(
    'jar',
    reads: {ModelVar.jar},
    changes: {ModelVar.jar},
    of: (w) => _JarCalls(engine: w.engine, turn: w.turn),
  );

  /// The stored sessions as a step in the turn reaches them.
  static Port<_StoredCalls, W> _storedPort<W extends JarWorld>() => Port(
    'stored',
    reads: {ModelVar.stored},
    changes: {ModelVar.stored},
    of: (w) => _StoredCalls(engine: w.engine, turn: w.turn),
  );

  /// Past the step that grants it, a flow holds the jar's turn: no other
  /// operation reads or writes the jar meanwhile (ISO-003).
  static Expr<bool, W> _holdsTurn<W extends JarWorld>() =>
      _turnHolder<W>().value.eq(Expr.flow());

  /// Whether the platform may refuse a call on the jar: always, though no
  /// world but the one that asks lets it (ISO-014).
  static Expr<bool, W> _jarRefuses<W>() =>
      Expr.ofConstant(ModelConst.jarRefuses, run: (_) => true);

  /// How the jar refuses: a [CookieJarFailure].
  static const jarRefusal = Refusal<CookieJarFailure>();

  /// An incognito site keeps nothing to capture or restore.
  static Expr<bool, W> _incognito<W>(Expr<WebViewModel, W> site) =>
      incognitoOf<W>().has(site);

  /// A site's share of the jar: the cookies on its base domain, which in
  /// the model are the sessions of the sites on that domain.
  static Def<List<Cookie>, W> share<W>() {
    final s = Bound<WebViewModel, W>('s');
    final cookies = Bound<List<Cookie>, W>('cookies');
    final x = Bound<Cookie, W>('x');
    final base = baseOf<W>();
    return Def(
      ModelDef.share,
      params: [s, cookies],
      body: cookies.it.where(x, holds: base.at(x.it).eq(base.at(s.it))),
    );
  }

  static Expr<List<Cookie>, W> _shareOf<W>(
    Expr<WebViewModel, W> site, {
    required Expr<List<Cookie>, W> of,
  }) => share<W>().call([site, of]);

  static Act<W> _takeTurn<W>() =>
      modelOnly(
        'TakeTurn(f)',
        writes: {ModelVar.holder, ModelVar.queue},
        reads: const Reads(base: {BaseOp.takeTurn}),
      );
  static Act<W> _passTurn<W>() =>
      modelOnly(
        'PassTurn',
        writes: {ModelVar.holder, ModelVar.queue},
        reads: const Reads(base: {BaseOp.passTurn}),
      );
  static Act<W> _release<W>() => modelOnly(
    'Release',
    writes: {ModelVar.holder},
    reads: const Reads(base: {BaseOp.release}),
  );

  static const _unloadSnap = Field<List<Cookie>, UnloadWorld>(FlowField.snap);
  static const _victim = Field<WebViewModel, UnloadWorld>(FlowField.victim);
  /// The unload engine's answers about the victim, which change nothing the
  /// model holds: the definitions it owns, run by name, and the note of a
  /// dispose.
  static final _unload = Port<UnloadAnswers, UnloadWorld>(
    'unload',
    reads: const {},
    changes: const {},
    of: (w) => w.answers,
  );
  static final _unloadVars = RuntimeVars.port<WebViewModel, UnloadWorld>(
    reads: {ModelVar.marker, ModelVar.version},
    of: (w) => w.vars,
  );
  static final _spare = ModelDef.spare.ofFlow<bool, UnloadWorld>(
    run: (c) => _unload.from(c).spared(),
  );
  static final _dispose = disposeOf<UnloadWorld>(
    _victim,
    over: (
      loaded: _loaded(),
      picked: ModelDef.picked.ofFlow(run: (c) => _unload.from(c).picked()),
      current: Var<WebViewModel?, UnloadWorld>(
        ModelVar.current,
        read: (w) => w.vars.current.value,
      ).value,
      liveTarget: Expr.op(
        HandPaired.jarLiveTarget,
        tla: 'LiveTarget',
        run: (c) => _unloadVars.from(c).liveTarget,
        reads: const Reads(base: {BaseOp.liveTarget}),
      ),
    ),
    then: (c) => _unload.from(c).disposed(),
  );

  /// Back to the unload engine's loop over its plan.
  static List<Effect<UnloadWorld>> _unloadReturn({required bool disposed}) => [
    ...unloadReturn(_victim, disposed: disposed),
    _unloadSnap.becomes(Expr.none()),
  ];

  /// Once the capture saved, or could not read the jar: the site stays if a
  /// tap opened it meanwhile, else it goes.
  static final _sparedAfterCapture = Branch<UnloadWorld, UnloadPlace>(
    StepOutcome.spared,
    when: _spare,
    then: [_release(), backoff(), ..._unloadReturn(disposed: false)],
    next: to(UnloadPlace.afterUnload),
  );
  static final _disposedAfterCapture = Otherwise<UnloadWorld, UnloadPlace>(
    StepOutcome.disposed,
    then: [
      _dispose,
      _release(),
      evictedMid(),
      ..._unloadReturn(disposed: true),
    ],
    next: to(UnloadPlace.afterUnload),
  );

  /// The capture and the dispose of an unload, in the jar's turn.
  static final unloadSteps = StepTable<UnloadWorld, UnloadPlace>(
    UnloadPlace.values,
    vars: [_turnHolder<UnloadWorld>(), _loaded<UnloadWorld>()],
    at: (place) => switch (place) {
      UnloadPlace.uTurn => Step(
        ActivationStep.grantUnload,
        holds: null,
        granted: true,
        site: _victim.value,
        branches: [
          // A site no longer loaded was captured when it left, and the jar
          // has been refilled without it since: capturing again would save
          // nothing over its session (BUG-032). Two plans can both name it.
          Branch(
            StepOutcome.gone,
            when: ModelDef.gone.ofFlow(run: (c) => _unload.from(c).gone()),
            then: [_passTurn(), ..._unloadReturn(disposed: false)],
            next: to(UnloadPlace.afterUnload),
          ),
          // An incognito site keeps nothing, so it has nothing to capture.
          Branch(
            StepOutcome.spared,
            when: _incognito(_victim.value) & _spare,
            then: [_passTurn(), backoff(), ..._unloadReturn(disposed: false)],
            next: to(UnloadPlace.afterUnload),
          ),
          Branch(
            StepOutcome.disposed,
            when: _incognito(_victim.value),
            then: [
              _passTurn(),
              _dispose,
              evictedMid(),
              ..._unloadReturn(disposed: true),
            ],
            next: to(UnloadPlace.afterUnload),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.capture,
          then: [
            _takeTurn(),
            Note(
              (c) => LogTag.cookieIsolation.debug(
                'Unloading site "${_victim.of(c).name}" '
                '(siteId: ${_victim.of(c).siteId})',
                sensitive: true,
              ),
            ),
          ],
          next: to(UnloadPlace.uCap),
        ),
      ),
      UnloadPlace.uCap => Step(
        ActivationStep.unloadCapReply,
        holds: _holdsTurn(),
        // Snapshot the full native jar and attribute by base domain, so
        // sibling-subdomain cookies (`accounts.google.com` for a
        // `mail.google.com` site) are kept: a URL-scoped capture would only
        // return cookies for the site's primary URL.
        call: _unloadSnap.receivesOn(
          _jarPort(),
          run: (c) => c.api.snapshot(of: [_victim.of(c)]),
          reply: _jar<UnloadWorld>().value,
        ),
        site: _victim.value,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [],
          next: to(UnloadPlace.uSave),
        ),
        // A jar that cannot be read saves nothing over the site's stored
        // session, which then stays as it was (ISO-014).
        refused: Refused<UnloadWorld, UnloadPlace>(
          refusal: jarRefusal,
          when: _jarRefuses(),
          then: [
            Note(
              (c) => LogTag.cookieIsolation.warning(
                'Capture for "${_victim.of(c).name}" failed, its stored '
                'cookies stay',
                sensitive: true,
              ),
            ),
          ],
          next: to(UnloadPlace.uKept),
        ),
      ),
      UnloadPlace.uSave => Step(
        ActivationStep.unloadSaveReply,
        holds: _holdsTurn(),
        call: Call.on(
          _storedPort(),
          run: (c) async {
            final victim = _victim.of(c);
            victim.cookies = _shareOf(_victim.value, of: _unloadSnap.value).run(c);
            await c.api.save(site: victim, cookies: victim.cookies);
            LogTag.cookieIsolation.debug(
              'Captured ${victim.cookies.length} cookies for "${victim.name}"',
              sensitive: true,
            );
          },
          writes: [
            _stored<UnloadWorld>().except(
              _victim.value,
              to: _shareOf(_victim.value, of: _unloadSnap.value),
            ),
          ],
        ),
        site: _victim.value,
        branches: [_sparedAfterCapture],
        otherwise: _disposedAfterCapture,
      ),
      UnloadPlace.uKept => Step(
        ActivationStep.unloadKept,
        holds: _holdsTurn(),
        site: _victim.value,
        branches: [_sparedAfterCapture],
        otherwise: _disposedAfterCapture,
      ),
      UnloadPlace.next ||
      UnloadPlace.uNav ||
      UnloadPlace.uNavSave ||
      UnloadPlace.uNavUnsave ||
      UnloadPlace.uCaptured ||
      UnloadPlace.afterUnload ||
      UnloadPlace.nextClear ||
      UnloadPlace.cc ||
      UnloadPlace.applied ||
      UnloadPlace.exit => const Leaves(),
    },
  );

  /// The sites loaded as the restore took its turn, incognito ones too:
  /// every one shares the jar the restore empties.
  static const _ls = Field<List<WebViewModel>, RestoreWorld>(FlowField.ls);
  static const _snap = Field<List<Cookie>, RestoreWorld>(FlowField.snap);
  static const _todo = Field<List<WebViewModel>, RestoreWorld>(FlowField.todo);

  /// The loaded sites whose share is saved: an incognito site's is held
  /// in memory only (INC-001).
  static final _saves = _ls.value.minus(incognitoOf());

  /// A loaded incognito site keeps its share of the snapshot in memory, to
  /// be set back once the jar is emptied (INC-001).
  static final _holdIncognito = () {
    final u = Bound<WebViewModel, RestoreWorld>('u');
    final shares = _ls.value
        .where(u, holds: incognitoOf<RestoreWorld>().has(u.it))
        .mapTo(u, to: _shareOf(u.it, of: _snap.value));
    return Note<RestoreWorld>((c) {
      for (final MapEntry(key: site, value: cookies) in shares.run(c).entries) {
        site.cookies = cookies;
      }
    });
  }();
  static const _tmp = Field<List<Cookie>, RestoreWorld>(FlowField.tmp);
  static const _target = Field<WebViewModel, RestoreWorld>(FlowField.site);
  static const _unrestored = Field<bool, RestoreWorld>(FlowField.unrestored);
  static const _v = Field<int, RestoreWorld>(FlowField.v);
  static final _version = Var<int, RestoreWorld>(
    ModelVar.version,
    read: (w) => w.vars.version.value,
  );
  static final _restoreStale = ~_v.value.eq(_version.value);
  static final _eachTodo = Pick(_todo.value);
  static final _picked = _eachTodo.it;
  static final _others = _ls.value.without(_target.value);

  /// The activation goes on, or leaves if it was superseded meanwhile or
  /// the jar refused a call of the restore.
  static final Expr<RestorePlace, RestoreWorld> _restoreDone = Expr.choose(
    when: _restoreStale | _unrestored.valueOr(none: false),
    then: to(RestorePlace.exit),
    otherwise: to(RestorePlace.html),
  );

  /// The jar refused a read or the nuke: nothing more is written, and the
  /// target is not shown (ISO-014).
  static Refused<RestoreWorld, RestorePlace> _refusedEnd({
    required String at,
  }) => Refused(
    refusal: jarRefusal,
    when: _jarRefuses(),
    then: [
      _unrestored.becomes(Expr.constant(true, tla: 'TRUE')),
      ..._restoreEnd,
      Note(
        (c) => LogTag.cookieIsolation.error(
          'Restore for "${_target.of(c).name}" failed at the $at, not '
          'shown',
          sensitive: true,
        ),
      ),
    ],
    next: to(RestorePlace.exit),
  );

  /// The jar refused a write of the refill: the rest is still written, and
  /// then the target is not shown (ISO-014).
  static Refused<RestoreWorld, RestorePlace> _refusedSet({
    required Expr<List<WebViewModel>, RestoreWorld> todo,
  }) => Refused(
    refusal: jarRefusal,
    when: _jarRefuses(),
    then: [
      _unrestored.becomes(Expr.constant(true, tla: 'TRUE')),
      _todo.becomes(todo),
      Note(
        (c) => LogTag.cookieIsolation.error(
          'Restore for "${_target.of(c).name}" refused a cookie, not shown',
          sensitive: true,
        ),
      ),
    ],
    next: to(RestorePlace.rRefused),
  );

  /// The turn passes on and the activation checks its version.
  static final List<Effect<RestoreWorld>> _restoreEnd = [
    _release(),
    _snap.becomes(Expr.none()),
    _ls.becomes(Expr.none()),
    _tmp.becomes(Expr.none()),
    _todo.becomes(Expr.none()),
  ];

  /// A restore, in the jar's turn: the snapshot, a save of each loaded
  /// site's share, the nuke, then the target's stored session and each
  /// other loaded site's share back. No bail once the jar is nuked.
  static final restoreSteps = StepTable<RestoreWorld, RestorePlace>(
    RestorePlace.values,
    vars: [_turnHolder<RestoreWorld>(), _loaded<RestoreWorld>(), _version],
    at: (place) => switch (place) {
      RestorePlace.rTurn => Step(
        ActivationStep.grantRestore,
        holds: null,
        granted: true,
        branches: [
          // Superseded while waiting for its turn.
          Branch(
            StepOutcome.stale,
            when: _restoreStale,
            then: [_passTurn()],
            next: to(RestorePlace.exit),
          ),
          Branch(
            StepOutcome.skip,
            when: _incognito(_target.value),
            then: [_passTurn(), ..._restoreEnd],
            next: _restoreDone,
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.snap,
          then: [
            _takeTurn(),
            _ls.becomes(_loaded<RestoreWorld>().value.inOrder),
          ],
          next: to(RestorePlace.rSnap),
        ),
      ),
      RestorePlace.rSnap => Step(
        ActivationStep.restoreSnapReply,
        holds: _holdsTurn(),
        call: _snap.receivesOn(
          _jarPort(),
          run: (c) {
            final ls = _ls.of(c);
            final target = _target.of(c);
            return c.api.snapshot(of: [...ls, if (!ls.contains(target)) target]);
          },
          reply: _jar<RestoreWorld>().value,
        ),
        branches: [
          Branch(
            StepOutcome.stale,
            when: _restoreStale,
            then: [_release()],
            next: to(RestorePlace.exit),
          ),
          Branch(
            StepOutcome.nuke,
            when: _saves.isEmpty,
            then: [_holdIncognito, _todo.becomes(_saves)],
            next: to(RestorePlace.rNuke),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.save,
          then: [_holdIncognito, _todo.becomes(_saves)],
          next: to(RestorePlace.rSave),
        ),
        refused: _refusedEnd(at: 'snapshot'),
      ),
      RestorePlace.rSave => Step(
        ActivationStep.restoreSaveReply,
        holds: _holdsTurn(),
        pick: _eachTodo,
        call: Call.on(
          _storedPort(),
          run: (c) {
            final site = _picked.run(c);
            site.cookies = _shareOf(_picked, of: _snap.value).run(c);
            return c.api.save(site: site, cookies: site.cookies);
          },
          writes: [
            _stored<RestoreWorld>().except(
              _picked,
              to: _shareOf(_picked, of: _snap.value),
            ),
          ],
        ),
        site: _picked,
        branches: [
          Branch(
            StepOutcome.stale,
            when: _restoreStale,
            then: [_release(), _todo.becomes(Expr.none())],
            next: to(RestorePlace.exit),
          ),
          Branch(
            StepOutcome.nuke,
            when: _todo.value.isOnly(_picked),
            then: [_todo.becomes(_todo.value.without(_picked))],
            next: to(RestorePlace.rNuke),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.more,
          then: [_todo.becomes(_todo.value.without(_picked))],
          next: to(RestorePlace.rSave),
        ),
      ),
      RestorePlace.rNuke => Step(
        ActivationStep.restoreNukeReply,
        holds: _holdsTurn(),
        call: Call.on(
          _jarPort(),
          run: (c) => c.api.empty(),
          writes: [_jar<RestoreWorld>().becomes(Expr.none())],
        ),
        otherwise: Otherwise(
          StepOutcome.none,
          then: [],
          next: to(RestorePlace.rLoad),
        ),
        refused: _refusedEnd(at: 'nuke'),
      ),
      RestorePlace.rLoad => Step(
        ActivationStep.restoreLoadReply,
        holds: _holdsTurn(),
        call: _tmp.receivesOn(
          _storedPort(),
          run: (c) async {
            final target = _target.of(c);
            final cookies = await c.api.load(site: target);
            target.cookies = cookies;
            LogTag.cookieIsolation.debug(
              'Restoring ${cookies.length} cookies for "${target.name}" '
              '(siteId: ${target.siteId})',
              sensitive: true,
            );
            return cookies;
          },
          reply: _stored<RestoreWorld>().at(_target.value),
        ),
        otherwise: Otherwise(
          StepOutcome.none,
          then: [],
          next: to(RestorePlace.rSetT),
        ),
      ),
      RestorePlace.rSetT => Step(
        ActivationStep.restoreSetTargetReply,
        holds: _holdsTurn(),
        call: Call.on(
          _jarPort(),
          run: (c) => c.api.set(site: _target.of(c), cookies: _tmp.of(c)),
          writes: [
            _jar<RestoreWorld>().becomes(
              _jar<RestoreWorld>().value.union(_tmp.value),
            ),
          ],
        ),
        branches: [
          Branch(
            StepOutcome.end,
            when: _others.isEmpty,
            then: _restoreEnd,
            next: _restoreDone,
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.others,
          then: [_todo.becomes(_others)],
          next: to(RestorePlace.rSetO),
        ),
        refused: _refusedSet(todo: _others),
      ),
      RestorePlace.rSetO => Step(
        ActivationStep.restoreSetOtherReply,
        holds: _holdsTurn(),
        pick: _eachTodo,
        call: Call.on(
          _jarPort(),
          run: (c) {
            final site = _picked.run(c);
            return c.api.set(site: site, cookies: site.cookies);
          },
          writes: [
            _jar<RestoreWorld>().becomes(
              _jar<RestoreWorld>().value.union(
                _shareOf(_picked, of: _snap.value),
              ),
            ),
          ],
        ),
        site: _picked,
        branches: [
          Branch(
            StepOutcome.end,
            when: _todo.value.isOnly(_picked),
            then: _restoreEnd,
            next: _restoreDone,
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.more,
          then: [_todo.becomes(_todo.value.without(_picked))],
          next: to(RestorePlace.rSetO),
        ),
        refused: _refusedSet(todo: _todo.value.without(_picked)),
      ),
      RestorePlace.rRefused => Step(
        ActivationStep.restoreRefused,
        holds: _holdsTurn(),
        branches: [
          Branch(
            StepOutcome.end,
            when: _todo.value.isEmpty,
            then: _restoreEnd,
            next: to(RestorePlace.exit),
          ),
        ],
        otherwise: Otherwise(
          StepOutcome.more,
          then: [],
          next: to(RestorePlace.rSetO),
        ),
      ),
      RestorePlace.html || RestorePlace.exit => const Leaves(),
    },
  );

  /// Clears native cookies for a site about to be deleted. If a loaded
  /// same-base-domain site exists, snapshots its session first and
  /// restores after — the URL-scoped delete would otherwise evict the
  /// surviving site's live cookies too.
  ///
  /// The site's stored cookies go first, whatever the jar does. A jar that
  /// fails is left as it is, with nothing deleted past the failure: the next
  /// activation empties it before any site shows (ISO-012, ISO-014).
  Future<void> preDeleteCookieCleanup({
    required WebViewModel deletedModel,
    required Iterable<WebViewModel> loaded,
  }) => _turn(
    (turn) => _preDelete(turn, deletedModel: deletedModel, loaded: loaded),
  );

  Future<void> _preDelete(
    JarTurn turn, {
    required WebViewModel deletedModel,
    required Iterable<WebViewModel> loaded,
  }) async {
    await _saveStored(turn, site: deletedModel, cookies: []);
    try {
      await _clearDeletedFromJar(
        turn,
        deletedModel: deletedModel,
        loaded: loaded,
      );
    } on CookieJarFailure catch (e) {
      LogTag.cookieIsolation.warning(
          'Clearing deleted site "${deletedModel.name}" from the jar failed; '
          'the next activation empties it: $e',
          sensitive: true);
    }
  }

  Future<void> _clearDeletedFromJar(
    JarTurn turn, {
    required WebViewModel deletedModel,
    required Iterable<WebViewModel> loaded,
  }) async {
    final deletedBase = getBaseDomain(deletedModel.initUrl);

    final survivingSameBase = [
      for (final m in loaded)
        if (!identical(m, deletedModel) &&
            !m.effectiveIncognito &&
            getBaseDomain(m.initUrl) == deletedBase)
          m,
    ];

    List<Cookie> survivingSnapshot = const [];
    if (survivingSameBase.isNotEmpty) {
      final allCookies = await _snapshot(turn, of: survivingSameBase);
      survivingSnapshot = allCookies
          .where((c) => cookieMatchesBaseDomain(c, baseDomain: deletedBase))
          .toList();
    }

    await _cookies.deleteAllCookiesForUrl(Uri.parse(deletedModel.initUrl));
    if (deletedModel.currentUrl.isNotEmpty &&
        deletedModel.currentUrl != deletedModel.initUrl) {
      await _cookies.deleteAllCookiesForUrl(Uri.parse(deletedModel.currentUrl));
    }

    if (survivingSameBase.isNotEmpty && survivingSnapshot.isNotEmpty) {
      final refused = await _writeAll(
        turn,
        url: Uri.parse(survivingSameBase.first.initUrl),
        cookies: survivingSnapshot,
      );
      if (refused != null) throw refused;
    }
  }

  /// Candidate URLs passed to `CookieManager.getAllCookies` on Android (where
  /// there's no native "get all" API and we aggregate per-URL instead). We
  /// include each model's `initUrl`, `currentUrl` (if different), and a
  /// bare `https://<baseDomain>/` to pick up parent-domain cookies like
  /// `Domain=.example.com`. On iOS this list is ignored.
  static List<Uri> _candidateUrlsFor(Iterable<WebViewModel> models) {
    final urls = <String>{};
    for (final m in models) {
      if (m.initUrl.isNotEmpty) urls.add(m.initUrl);
      if (m.currentUrl.isNotEmpty && m.currentUrl != m.initUrl) {
        urls.add(m.currentUrl);
      }
      final base = getBaseDomain(m.initUrl);
      if (base.isNotEmpty) urls.add('https://$base/');
    }
    return urls.map(Uri.tryParse).whereType<Uri>().toList();
  }

  /// [site]'s [cookies] into the jar, but the ones it blocks; see
  /// [_writeAll].
  Future<CookieJarFailure?> _setCookies(
    JarTurn turn, {
    required WebViewModel site,
    required List<Cookie> cookies,
  }) => _writeAll(
    turn,
    url: Uri.parse(site.initUrl),
    cookies: cookies.where(
      (c) => !site.isCookieBlocked(c.name, domain: c.domain),
    ),
  );

  /// Writes every one of [cookies] the jar takes at [url]: one it refuses
  /// does not stop the rest. Returns the first refusal, null when none.
  Future<CookieJarFailure?> _writeAll(
    JarTurn turn, {
    required Uri url,
    required Iterable<Cookie> cookies,
  }) async {
    CookieJarFailure? refused;
    for (final cookie in cookies) {
      if (cookie.value.isEmpty) continue;
      try {
        await _cookies.setCookie(
          url: url,
          name: cookie.name,
          value: cookie.value,
          domain: cookie.domain,
          path: cookie.path ?? '/',
          expiresDate: cookie.expiresDate,
          isSecure: cookie.isSecure,
          isHttpOnly: cookie.isHttpOnly,
        );
      } on CookieJarFailure catch (e) {
        refused ??= e;
      }
    }
    return refused;
  }
}

/// Proof that the running code holds the jar's turn (ISO-003): made only
/// by [CookieIsolationEngine._turn], so the jar's reads and writes, which
/// take one, cannot be reached from outside a turn.
final class JarTurn {
  JarTurn._();
}

/// What a flow through one of the jar's tables runs against, holding the
/// turn its steps run in, over the runtime's variables.
/// The operations a step in the jar's turn makes on the platform's jar:
/// what the jar's port hands a call.
final class _JarCalls {
  const _JarCalls({required this._engine, required this._turn});

  final CookieIsolationEngine _engine;
  final JarTurn _turn;

  Future<List<Cookie>> snapshot({required Iterable<WebViewModel> of}) =>
      _engine._snapshot(_turn, of: of);

  Future<void> empty() async {
    await _engine._empty(_turn);
    _engine._emptied = true;
  }

  /// A refill's write: fails with the first cookie the jar refused, once
  /// the rest are written.
  Future<void> set({
    required WebViewModel site,
    required List<Cookie> cookies,
  }) async {
    if (await _engine._setCookies(_turn, site: site, cookies: cookies)
        case final refused?) {
      throw refused;
    }
  }
}

/// The operations a step in the jar's turn makes on the stored sessions:
/// what the stored sessions' port hands a call.
final class _StoredCalls {
  const _StoredCalls({required this._engine, required this._turn});

  final CookieIsolationEngine _engine;
  final JarTurn _turn;

  Future<void> save({
    required WebViewModel site,
    required List<Cookie> cookies,
  }) => _engine._saveStored(_turn, site: site, cookies: cookies);

  Future<List<Cookie>> load({required WebViewModel site}) =>
      _engine._loadStored(_turn, site: site);
}

abstract base class JarWorld {
  CookieIsolationEngine get engine;
  RuntimeVars<WebViewModel> get vars;
  late final JarTurn turn;
}

/// What the jar's unload steps run against: the unload engine's flow seen
/// from the jar ([SiteUnloadEngine.unloadFlow] nests them), the victim in
/// the flow's `victim` field, and the engine's answers about it.
final class UnloadWorld extends JarWorld {
  UnloadWorld({required this.engine, required this.vars, required this.answers});

  @override
  final CookieIsolationEngine engine;
  @override
  final RuntimeVars<WebViewModel> vars;
  final UnloadAnswers answers;
}

/// What the unload engine answers the jar about the victim it nests the
/// jar's steps for.
typedef UnloadAnswers = ({
  /// Asked just before the dispose: whether the site stays after all
  /// (`Spare(f)`).
  bool Function() spared,

  /// Runs right after the dispose.
  void Function() disposed,

  /// Whether the victim was picked by retention priority (`Picked(f)`).
  bool Function() picked,

  /// Whether the victim left the loaded sites meanwhile (`Gone(f)`).
  bool Function() gone,
});

/// What a restore's steps run against.
final class RestoreWorld extends JarWorld {
  RestoreWorld({required this.engine, required this.vars});

  @override
  final CookieIsolationEngine engine;
  @override
  final RuntimeVars<WebViewModel> vars;
}
