// The planted mistakes: each mutant's tables and definitions, a copy of
// the code's with the fault, which TLC must catch and the schedules too
// (`planted`).
part of 'models.dart';

/// [ops] with the definition named as [def] replaced by it.
List<Def<Object?, Object?>> _withDef(
  List<Def<Object?, Object?>> ops, {
  required Def<Object?, Object?> def,
}) => [
  for (final d in ops)
    if (d.name == def.name) def else d,
];

/// [table] with [step]'s arms replaced by [arms].
StepTable<W, P> _withArms<W, P extends Enum>(
  StepTable<W, P> table, {
  required ActivationStep step,
  required Step<W, P> Function(Step<W, P> s) arms,
}) => StepTable(
  [...table.places],
  ending: table.ending,
  awaited: table.awaited,
  vars: table.vars,
  at: (place) => switch (table.at(place)) {
    final Step<W, P> s when s.name == step => arms(s),
    final at => at,
  },
);

/// [table] with [step]'s branch for [outcome] taken out.
StepTable<W, P> _without<W, P extends Enum>(
  StepTable<W, P> table, {
  required ActivationStep step,
  required StepOutcome outcome,
}) => _withArms(
  table,
  step: step,
  arms: (s) => s.withArms(
    branches: [
      for (final b in s.branches)
        if (b.outcome != outcome) b,
    ],
    otherwise: s.otherwise,
  ),
);

/// `RouteFree` holding for any site: a background load that repoints a
/// loaded site's proxy, as the preload's guard did before it asked.
Def<bool, Object?> _routeFreeAlways() {
  final a = Bound<WebViewModel, Object?>('a');
  return Def(
    ModelDef.routeFree,
    params: [a],
    body: Expr.constant(true, tla: 'TRUE'),
  );
}

/// `Reopens` without the nested screen: a retired slot opens again beside
/// it.
Def<bool, TabFlow> _reopensBesideNested() {
  const s = Bound<WebViewModel, TabFlow>('s');
  return Def(
    ModelDef.reopens,
    params: const [s],
    body: TabTable.shownOrTarget(s.it),
  );
}

/// `MovesRule` with [body] over its two sites in place of the code's.
Def<bool, TabFlow> _movesRuleOf(
  Expr<bool, TabFlow> Function({
    required Expr<WebViewModel, TabFlow> from,
    required Expr<WebViewModel, TabFlow> to,
  }) body,
) {
  const a = Bound<WebViewModel, TabFlow>('a');
  const b = Bound<WebViewModel, TabFlow>('b');
  return Def(
    ModelDef.movesRule,
    params: const [a, b],
    body: body(from: a.it, to: b.it),
  );
}

/// `ProxyContenders` with the loaded slots read without the asking site's
/// own (`t # a`): what a site's nested screen asks for no longer sees that
/// site's slot, whatever it runs as.
Def<List<int>, ProxySlots> _contendersSkippingOwnSlot() {
  const a = Bound<int, ProxySlots>('a');
  const t = Bound<int, ProxySlots>('t');
  final world = Port<ProxySlots, ProxySlots>(
    'world',
    reads: const {},
    changes: const {},
    of: (w) => w,
  );
  final loaded = Var<Iterable<int>, ProxySlots>(
    ModelVar.loaded,
    read: (w) => w.loaded,
  ).value;
  final pages = ModelDef.pages.named<Iterable<int>, ProxySlots>(
    run: (c) => world.from(c).pages,
  );
  final contending = Members<int, ProxySlots>(
    ModelConst.contending,
    test: (w, {required member}) => w.topology.contends(w.sites[member]),
  );
  final route = Indexed<int, ProxyRouteKey, ProxySlots>.fixed(
    ModelConst.route,
    read: (w, {required at}) => ProxyConflictEngine.routeOf(
      w.sites[at].proxySettings,
      siteId: w.sites[at].siteId,
    ),
  );
  Expr<int, ProxySlots> runsAs(Expr<int, ProxySlots> slot) => ModelDef.runsAs.over(
    [slot],
    run: (c) {
      final w = world.from(c);
      return w.sites.indexOf(w.slots[slot.run(c)]);
    },
  );
  Expr<bool, ProxySlots> differs(Expr<int, ProxySlots> as) =>
      contending.has(as) & route.at(as).neq(route.at(a.it));
  return Def(
    ModelDef.proxyContenders,
    params: const [a],
    body: Expr.choose(
      when: ~contending.has(a.it),
      then: Expr.none(),
      otherwise: loaded
          .where(t, holds: t.it.neq(a.it) & differs(runsAs(t.it)))
          .union(pages.where(t, holds: differs(t.it))),
    ),
  );
}

/// `Capture` keying the bytes it read by the webview's tab at the save,
/// after a rebind may have moved it (BUG-036 attempt 1).
Def<Map<WebViewModel, Map<TabId, Map<WebViewModel, TabId?>>>, Object?>
_captureAtReply() {
  final s = Bound<WebViewModel, Object?>('s');
  final t = Bound<TabId?, Object?>('t');
  final h = Bound<TabId?, Object?>('h');
  final a = Bound<WebViewModel, Object?>('a');
  final built = TabVars.built<Object?>().at(s.it);
  final builtTab = built.unwrapped;
  final file = TabVars.file<Object?>().value;
  return Def(
    ModelDef.capture,
    params: [s, t, h, a],
    body: Expr.choose(
      when: built.neq(noTab()),
      then: file.exceptAt(s.it, at: builtTab, by: a.it, to: h.it),
      otherwise: file,
    ),
  );
}

/// `Takes` taking whatever back stack is queued, read for any tab.
/// The nav step's write of `queued`, its code half tagging the bytes with
/// the tab active as the reply lands.
final _queuedAtReply = () {
  const site = Field<WebViewModel, ActivationFlow>(FlowField.site);
  return Act.of(
    [
      TabVars.queued<ActivationFlow>().becomes(
        TabVars.staged<ActivationFlow>().call([
          site.value,
          const Field<WebViewModel, ActivationFlow>(FlowField.navAs).value,
          const Field<TabId, ActivationFlow>(FlowField.navTab).value,
        ]),
      ),
    ],
    then: (c) {
      final target = site.of(c);
      if (ActivationFlow.state.from(c).navBytes case final bytes?) {
        target.tabBinding.queue(bytes, tab: target.activeTabId, commit: c.commit);
      }
    },
  );
}();

Def<Map<WebViewModel, QueuedStack>, Object?> _stagedAtReply() {
  final s = Bound<WebViewModel, Object?>('s');
  final a = Bound<WebViewModel, Object?>('a');
  final t = Bound<TabId, Object?>('t');
  final queued = TabVars.queued<Object?>().value;
  final saved = TabVars.file<Object?>().value.at(s.it).at(t.it).at(a.it);
  return Def(
    ModelDef.staged,
    params: [s, a, t],
    body: Expr.choose(
      when: TabVars.tabbed<Object?>().has(s.it) & saved.neq(noTab()),
      then: queued.except(
        s.it,
        to: record(
          {'t': TabVars.active<Object?>().at(s.it), 'h': saved},
          run: (_) => throw StateError('queued is the platform\'s'),
        ),
      ),
      otherwise: queued,
    ),
  );
}

Def<bool, Object?> _takesAny() {
  final q = Bound<QueuedStack, Object?>('q');
  final tab = Bound<TabId?, Object?>('tab');
  return Def(
    ModelDef.takes,
    params: [q, tab],
    body: q.it.part('t', get: (x) => x.t).neq(noTab()),
  );
}

/// The tables with those named replaced: a mistake names only what it
/// changes, and a new table fails to compile here until it is given one.
Tables _with({
  StepTable<ActivationFlow, ActivationPlace>? activation,
  StepTable<TabFlow, TabPlace>? tabInputs,
  StepTable<TabFlow, TabPlace>? tabFlow,
  StepTable<UnloadFlow, UnloadPlace>? unload,
  StepTable<UnloadWorld, UnloadPlace>? jar,
  StepTable<RestoreWorld, RestorePlace>? restore,
  StepTable<WakeFlow<WebViewModel>, WakePlace>? wake,
  StepTable<DnsFlow, DnsPlace>? dns,
  StepTable<CloseFlow, ClosePlace>? archive,
  StepTable<DeleteFlow, DeletePlace>? delete,
  List<Def<Object?, Object?>>? ops,
}) => (
  activation: activation ?? tables.activation,
  tabInputs: tabInputs ?? tables.tabInputs,
  tabFlow: tabFlow ?? tables.tabFlow,
  unload: unload ?? tables.unload,
  jar: jar ?? tables.jar,
  restore: restore ?? tables.restore,
  wake: wake ?? tables.wake,
  dns: dns ?? tables.dns,
  archive: archive ?? tables.archive,
  delete: delete ?? tables.delete,
  ops: ops ?? tables.ops,
);

final _asks = wakeAsks<WebViewModel>();

/// [m] as code: each table and definition its tables replace, for the
/// runner to take in place of the code's while a test runs it.
Planted planted(Mutant m) {
  final t = mutated(m);
  return Planted(
    tables: [
      for (final of in ModelTable.values)
        if (!identical(_table(t, of: of), _table(tables, of: of)))
          (_table(tables, of: of), _table(t, of: of)),
    ],
    defs: {
      for (final (i, d) in t.ops.indexed)
        if (!identical(d, tables.ops[i])) d.id: d,
    },
  );
}

/// Each mistake an engine once had, as the tables with it put back; the
/// check that catches it is the [Mutant]'s own.
Tables mutated(Mutant m) => switch (m) {
  // The refill goes on over a jar the refused nuke left as it was
  // (ISO-014).
  Mutant.nukeignored => _with(
    restore: _withArms(
      tables.restore,
      step: ActivationStep.restoreNukeReply,
      arms: (s) => s.withArms(
        refused: Refused<RestoreWorld, RestorePlace>(
          refusal: CookieIsolationEngine.jarRefusal,
          when: Expr.ofConstant(ModelConst.jarRefuses, run: (_) => true),
          then: [],
          next: to(RestorePlace.rLoad),
        ),
      ),
    ),
  ),
  // The restore takes in only the sites it saves, so a loaded incognito
  // site's session goes with the emptied jar (INC-001), as before the fix.
  Mutant.incognitonuked => _with(
    restore: _withArms(
      tables.restore,
      step: ActivationStep.grantRestore,
      arms: (s) => s.withArms(
        otherwise: Otherwise(
          s.otherwise.outcome,
          then: [
            s.otherwise.then.first,
            const Field<List<WebViewModel>, RestoreWorld>(FlowField.ls).becomes(
              Mutable<Iterable<WebViewModel>, RestoreWorld>.over(
                ModelVar.loaded,
                of: (w) => w.vars.loaded,
              ).value.minus(incognitoOf()),
            ),
          ],
          next: s.otherwise.next,
        ),
      ),
    ),
  ),
  // A close deletes its containers without waiting for the frame that
  // unmounts its sites' webviews, and a container a mounted webview still
  // binds is not deleted (LIR-023).
  Mutant.closenoframe => _with(
    archive: _withArms(
      tables.archive,
      step: ActivationStep.closeFrameReply,
      arms: (s) => Step(
        s.name,
        holds: s.holds,
        call: Call(run: (_) async {}, writes: const []),
        branches: s.branches,
        otherwise: s.otherwise,
      ),
    ),
  ),
  // A rebind that reroutes the slot takes it out of the loaded sites and
  // starts no activation, as the tab table printed it before its spawn
  // (LIR-024, BUG-037 attempt 13).
  Mutant.noreopen => _with(
    tabFlow: _withArms(
      tables.tabFlow,
      step: ActivationStep.tabRebind,
      arms: (s) => s.withArms(
        branches: [
          for (final b in s.branches)
            Branch(
              b.outcome,
              when: b.when,
              pick: b.pick,
              site: b.site,
              tab: b.tab,
              then: [
                for (final e in b.then)
                  if (e is! Spawn) e,
              ],
              next: b.next,
            ),
        ],
      ),
    ),
  ),
  // A reroute that moves a loaded slot to another site keeps it loaded
  // under one process-wide proxy, as it may off one: its webview is built
  // again on the new route beside the sites it contends with (LIR-024).
  Mutant.rerouteinplace => _with(
    tabFlow: _withArms(
      tables.tabFlow,
      step: ActivationStep.rerouteFlip,
      arms: (s) => s.withArms(
        branches: [
          for (final b in s.branches)
            if (b.outcome != StepOutcome.unload) b,
        ],
      ),
    ),
  ),
  // A landing moves a loaded site's pointer as it would one with no
  // webview, without the switch that rebinds it (TAB-014).
  Mutant.landinplace => _with(
    tabFlow: _withArms(
      tables.tabFlow,
      step: ActivationStep.homeLand,
      arms: (s) => s.withArms(
        branches: [
          for (final b in s.branches)
            if (b.outcome != StepOutcome.rebind) b,
        ],
      ),
    ),
  ),
  // An owner-run move moves a loaded site's pointer as it would one with no
  // webview, without the switch that rebinds it (LIR-018).
  Mutant.ownerruninplace => _with(
    tabFlow: _withArms(
      tables.tabFlow,
      step: ActivationStep.ownerLand,
      arms: (s) => s.withArms(
        branches: [
          for (final b in s.branches)
            if (b.outcome != StepOutcome.rebind) b,
        ],
      ),
    ),
  ),
  // A child tab opens by moving its site's pointer to it, without the
  // switch that rebinds a loaded site's webview (TAB-006).
  Mutant.childinplace => _with(
    tabFlow: _withArms(
      tables.tabFlow,
      step: ActivationStep.childOpen,
      arms: (s) => s.withArms(
        otherwise: Otherwise(
          s.otherwise.outcome,
          then: [
            Act.of([
              TabVars.active<TabFlow>().except(
                const Field<WebViewModel, TabFlow>(FlowField.site).value,
                to: const Field<TabId, TabFlow>(FlowField.tab).value,
              ),
            ]),
          ],
          next: to(TabPlace.done),
        ),
      ),
    ),
  ),
  // A delete deletes its site's container without waiting for the frame
  // that unmounts its webview (BUG-038).
  Mutant.deletenoframe => _with(
    delete: _withArms(
      tables.delete,
      step: ActivationStep.deleteFrameReply,
      arms: (s) => Step(
        s.name,
        holds: s.holds,
        call: Call(run: (_) async {}, writes: const []),
        branches: s.branches,
        otherwise: s.otherwise,
      ),
    ),
  ),
  // A tab switch moves the pointer at its capture's reply, before the nav
  // read (BUG-036 attempt 1): an await then sees a webview built for one
  // tab while the site names another.
  Mutant.pointerearly => _with(
    tabFlow: _withArms(
      tables.tabFlow,
      step: ActivationStep.tabCaptureReply,
      arms: (s) => s.withArms(
        otherwise: Otherwise(
          s.otherwise.outcome,
          then: [
            ...s.otherwise.then,
            Act.of([
              TabVars.active<TabFlow>().except(
                const Field<WebViewModel, TabFlow>(FlowField.site).value,
                to: const Field<TabId, TabFlow>(FlowField.tab).value,
              ),
            ]),
          ],
          next: s.otherwise.next,
        ),
      ),
    ),
  ),
  // A capture keys the bytes it read by the webview's tab at its reply, not
  // as it started (BUG-036 attempt 1's second shape): a rebind landing
  // between stores the outgoing tab's history under the incoming one.
  Mutant.captureatreply => _with(
    ops: _withDef(tables.ops, def: _captureAtReply()),
  ),
  // A preload loads a site whose proxy route a loaded site in its scope
  // does not run (PROXY-008): one site's traffic leaves through the
  // other's proxy.
  Mutant.preloadmismatch => _with(
    ops: _withDef(tables.ops, def: _routeFreeAlways()),
  ),
  // The build takes whatever back stack is queued, read for any tab.
  Mutant.takeany => _with(ops: _withDef(tables.ops, def: _takesAny())),
  // An activation queues the back stack it read for the tab active at the
  // read's reply, not the one it began on: a landing between moves it.
  // A close that does not wait for the tab gate: it starts while a switch
  // holds it, so two tab handlers run at once.
  Mutant.tabgateopen => _with(
    tabInputs: _without(
      tables.tabInputs,
      step: ActivationStep.closeTab,
      outcome: StepOutcome.busy,
    ),
  ),
  Mutant.navtagatreply => _with(
    activation: _withArms(
      tables.activation,
      step: ActivationStep.navReply,
      arms: (s) => s.withArms(
        otherwise: Otherwise(
          s.otherwise.outcome,
          then: [
            for (final e in s.otherwise.then)
              if (e case Act(:final writes) when writes.contains(ModelVar.queued))
                _queuedAtReply
              else
                e,
          ],
          next: s.otherwise.next,
        ),
      ),
    ),
    ops: _withDef(tables.ops, def: _stagedAtReply()),
  ),
  // An unload captures a site no longer loaded (BUG-032): no wait asks.
  Mutant.recapture => _with(
    ops: _withDef(
      tables.ops,
      def: Def<bool, UnloadFlow>.ofFlow(
        ModelDef.gone,
        body: Expr.constant(false, tla: 'FALSE'),
      ),
    ),
  ),
  // A superseded switch's conflict unload still disposes, taking the site a
  // newer tap opens (BUG-033).
  Mutant.staleplan => _with(
    ops: _withDef(
      tables.ops,
      def: SiteUnloadEngine.spareOf(stale: false, retry: true),
    ),
  ),
  // An unload picked by priority does not ask again before it disposes
  // (BUG-033).
  Mutant.noretry => _with(
    ops: _withDef(
      tables.ops,
      def: SiteUnloadEngine.spareOf(stale: true, retry: false),
    ),
  ),
  // A superseded switch leaves the screen on a site its residency unloaded
  // (BUG-029, LAZY-007).
  Mutant.nohome => _with(
    activation: _withArms(
      tables.activation,
      step: ActivationStep.exit,
      arms: (s) => s.withArms(branches: const []),
    ),
  ),
  // The marker is cleared by any activation with its target, as a double
  // tap's first did (CONT-003).
  Mutant.markerbytarget => _with(
    activation: _withArms(
      tables.activation,
      step: ActivationStep.exit,
      arms: (s) {
        final marker =
            Mutable<({WebViewModel target, int version})?, ActivationFlow>.over(
              ModelVar.marker,
              of: (w) => w.reach.sites.vars.marker,
            );
        final byTarget = Act.of([
          marker.becomes(
            Expr.choose(
              when:
                  ActivationTable.kind.isKind(FlowKind.tap) &
                  marker.value
                      .part('t', get: (m) => m?.target)
                      .eq(
                        const Field<WebViewModel, ActivationFlow>(
                          FlowField.site,
                        ).value,
                      ),
              then:
                  Expr.constant<
                    ({WebViewModel target, int version})?,
                    ActivationFlow
                  >(null, tla: 'NoMarker'),
              otherwise: marker.value,
            ),
          ),
        ]);
        List<Effect<ActivationFlow>> swap(
          List<Effect<ActivationFlow>> then,
        ) => [
          for (final e in then)
            if (e case Act(:final writes) when writes.contains(ModelVar.marker))
              byTarget
            else
              e,
        ];
        return s.withArms(
          branches: [
            for (final b in s.branches)
              Branch(
                b.outcome,
                when: b.when,
                pick: b.pick,
                site: b.site,
                then: swap(b.then),
                next: b.next,
              ),
          ],
          otherwise: Otherwise(
            s.otherwise.outcome,
            pick: s.otherwise.pick,
            site: s.otherwise.site,
            then: swap(s.otherwise.then),
            next: s.otherwise.next,
          ),
        );
      },
    ),
  ),
  // A preload marks its site loaded without restoring its session, over
  // what the last session left in the jar.
  // The frame after a preload's commit sees the loaded sites as the commit
  // found them, without the one it loads, so it binds no tab.
  Mutant.preloadunbound => _with(
    activation: _withArms(
      tables.activation,
      step: ActivationStep.commit,
      arms: (s) => s.withArms(
        branches: [
          s.branches.first,
          for (final b in s.branches.skip(1))
            Branch(
              b.outcome,
              when: b.when,
              pick: b.pick,
              site: b.site,
              tab: b.tab,
              then: [
                for (final e in b.then)
                  if (e is Act<ActivationFlow> &&
                      e.writes.contains(ModelVar.built))
                    TabVars.framed(
                      const Field<WebViewModel, ActivationFlow>(
                        FlowField.site,
                      ).value,
                      loaded:
                          Mutable<
                                Iterable<WebViewModel>,
                                ActivationFlow
                              >.remote(ModelVar.loaded)
                              .value,
                    )
                  else
                    e,
              ],
              next: b.next,
            ),
        ],
      ),
    ),
  ),
  Mutant.preloadbare => _with(
    activation: _withArms(
      tables.activation,
      step: ActivationStep.preloadNavReply,
      arms: (s) => s.withArms(
        otherwise: Otherwise(
          s.otherwise.outcome,
          then: const [],
          next: to(ActivationPlace.commit),
        ),
      ),
    ),
  ),
  // The capture, not the dispose, makes the site "saved" (BUG-033).
  // A nested open moves the proxy without asking again once it has, the
  // shape before BUG-037 attempt 6: a site that loaded during the move
  // stays beside the screen.
  Mutant.nestedonce => _with(
    activation: _without(
      tables.activation,
      step: ActivationStep.nestedApplyReply,
      outcome: StepOutcome.unload,
    ),
  ),
  // A slot that runs as another site from a tab's rebind opens again while
  // its own nested screen is up, on the screen's route, the shape before
  // BUG-037 attempt 19.
  Mutant.reopenbesidenested => _with(
    ops: _withDef(tables.ops, def: _reopensBesideNested()),
  ),
  // Going home, a capture's save that lands after its tab moved keeps the
  // file it wrote, under a key no tab holds.
  Mutant.savekeepsgone => _with(
    activation: _without(
      tables.activation,
      step: ActivationStep.homeCaptureSave,
      outcome: StepOutcome.gone,
    ),
  ),
  // The rebind a close of the active tab hands over to ends the flow, as a
  // switch's does, so the closed tab's file is never removed. The order
  // before BUG-036 attempt 6, the removals ahead of the list, spans four
  // actions, which no single mutant plants.
  Mutant.rebindskipsclose => _with(
    tabFlow: _withArms(
      tables.tabFlow,
      step: ActivationStep.tabRebind,
      // Its branches that go on to the removals are the first and third.
      arms: (s) => s.withArms(branches: [s.branches[1]]),
    ),
  ),
  // A slot that runs as another site under a Tor runtime stays loaded, the
  // shape before BUG-037 attempt 20: the one exit is no rule `MovesRule`
  // counts, so the slot's webview is built again on another exit beside
  // the sites on the first.
  Mutant.torkeepsslot => _with(
    ops: _withDef(
      tables.ops,
      def: _movesRuleOf(
        ({required from, required to}) =>
            TabTable.contending.has(from) | TabTable.contending.has(to),
      ),
    ),
  ),
  // A slot that moves into or out of the router's shared session stays
  // loaded, the shape before BUG-037 attempt 20: only one process-wide
  // proxy counts, so an activation planned while the slot ran as a site
  // outside the session commits beside it on another route.
  Mutant.sessionkeepsslot => _with(
    ops: _withDef(
      tables.ops,
      def: _movesRuleOf(
        ({required from, required to}) =>
            TabTable.globalProxy | TabTable.torRuntime,
      ),
    ),
  ),
  // The proxy rule skips the asking site's own slot, the shape before
  // BUG-037 attempt 19: a site whose active tab runs as another site opens
  // its nested screen beside its own slot on another route.
  Mutant.screenskipsslot => _with(
    ops: _withDef(tables.ops, def: _contendersSkippingOwnSlot()),
  ),
  // A preload commits without asking again, beside a nested screen that
  // went up since its input.
  Mutant.preloadunchecked => _with(
    activation: _without(
      tables.activation,
      step: ActivationStep.commit,
      outcome: StepOutcome.bail,
    ),
  ),
  // A wake's check that asks only whether the app came back, not the
  // rule, the shape before BUG-037 attempt 8: the wake took its route from
  // the notification sites alone and moved it under the site left on
  // screen.
  Mutant.wakeunchecked => _with(
    wake: _withArms(
      tables.wake,
      step: ActivationStep.wakeAsk,
      arms: (s) => s.withArms(
        branches: [
          for (final b in s.branches)
            Branch(
              b.outcome,
              when: Var<bool, WakeFlow<WebViewModel>>(
                ModelVar.fore,
                read: (w) => w.host.vars.fore.value,
              ).value,
              pick: b.pick,
              site: b.site,
              then: b.then,
              next: b.next,
            ),
        ],
      ),
    ),
  ),
  // A webspace switch whose input supersedes no activation in flight, as
  // before BUG-033 attempt 5: a tap begun on the list before it opens a
  // site the switch stopped showing.
  Mutant.spaceold => _with(
    activation: _withArms(
      tables.activation,
      step: ActivationStep.spaceSwitch,
      arms: (s) => s.withArms(
        otherwise: ActivationTable.spaceInputOf(supersedes: false).otherwise,
      ),
    ),
  ),
  // A wake's check that waits out an activation but not a nested open in
  // flight: the open's pop brings the site on screen back on its own route.
  Mutant.wakebesidenested => _with(
    wake: _withArms(
      tables.wake,
      step: ActivationStep.wakeAsk,
      arms: (s) => s.withArms(
        branches: [
          for (final b in s.branches)
            Branch(
              b.outcome,
              when: _asks.fore | _asks.activating | ~_asks.routeFree,
              pick: b.pick,
              site: b.site,
              then: b.then,
              next: b.next,
            ),
        ],
      ),
    ),
  ),
  // A wake's check that asks the rule over what runs but not whether an
  // activation is in flight: a tap whose plan ran before the check then
  // commits beside it on another route.
  Mutant.wakebesidetap => _with(
    wake: _withArms(
      tables.wake,
      step: ActivationStep.wakeAsk,
      arms: (s) => s.withArms(
        branches: [
          for (final b in s.branches)
            Branch(
              b.outcome,
              when: _asks.fore | ~_asks.routeFree,
              pick: b.pick,
              site: b.site,
              then: b.then,
              next: b.next,
            ),
        ],
      ),
    ),
  ),
  // A download's fold that tells the views their level before the new
  // app-wide level is in force, the shape c7376c8b fixed: listeners were
  // notified as the partition landed and read the level it replaced.
  Mutant.foldbeforelevel => _with(
    dns: _withArms(
      tables.dns,
      step: ActivationStep.dnsFolded,
      arms: (s) => s.withArms(
        otherwise: Otherwise(
          s.otherwise.outcome,
          then: [
            Act.of([
              dnsFoldWrites.inForce,
              dnsFoldWrites.toldUnder(
                level: dnsFoldWrites.levelInForce,
                levels: dnsFoldWrites.newLevels,
              ),
            ]),
            ...s.otherwise.then.skip(1),
          ],
          next: s.otherwise.next,
        ),
      ),
    ),
  ),
  Mutant.tierearly => _with(
    unload: _withArms(
      tables.unload,
      step: ActivationStep.unloadCaptured,
      arms: (s) {
        final early = Act.of([
          tierOf<UnloadFlow>().except(
            const Field<WebViewModel, UnloadFlow>(FlowField.victim).value,
            to: Expr.constant(
              SiteLifecycleState.savedForRestore,
              tla: '"saved"',
            ),
          ),
        ]);
        return s.withArms(
          branches: [
            for (final b in s.branches)
              if (b.outcome == StepOutcome.spared)
                Branch(
                  b.outcome,
                  when: b.when,
                  pick: b.pick,
                  site: b.site,
                  then: [early, ...b.then],
                  next: b.next,
                )
              else
                b,
          ],
          otherwise: Otherwise(
            s.otherwise.outcome,
            pick: s.otherwise.pick,
            site: s.otherwise.site,
            then: [early, ...s.otherwise.then],
            next: s.otherwise.next,
          ),
        );
      },
    ),
  ),
};
