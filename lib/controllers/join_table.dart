import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

/// Where a site's join is: its one step, and the place the input leaves by.
enum JoinPlace { join, done }

/// What a join runs against: the page's sites, the site that joins (an add,
/// one of an archive's as it opens) and the land that lists it.
final class JoinWorld implements SiteModels {
  JoinWorld(this._sites, {required this.site, required this.land});

  final SiteRuntime _sites;
  final WebViewModel site;

  /// The site takes its row at the end of the list, in [commit]: the
  /// model's row for it was there all along.
  final void Function({required Commit commit}) land;

  @override
  WebViewModel siteOf(SiteId id) => _sites.siteOf(id);
}

/// A site joining the list (`Join`): an input that starts no flow, where a
/// site off the list a world lets join takes its row, under its own id
/// unless a listed site holds it, else a fresh one (ARCH-016, SEC-044).
/// `SiteRuntime.apply` runs it for each site an add or an archive's open
/// lists, in the land's turn, after admitting them against the rows then
/// (BUG-046).
abstract final class JoinTable {
  /// [site] joins the list, by [land].
  static void join(
    SiteRuntime sites, {
    required WebViewModel site,
    required void Function({required Commit commit}) land,
  }) {
    table.runInput(
      StepContext(JoinWorld(sites, site: site, land: land)),
      from: JoinPlace.join,
    );
  }

  static final StepTable<JoinWorld, JoinPlace> table = StepTable(
    JoinPlace.values,
    vars: [_offList],
    ending: {JoinPlace.done},
    at: (place) => switch (place) {
      JoinPlace.join => Step.input(
        ActivationStep.join,
        pick: _each,
        site: _each.it,
        enabled: _offList.value.has(_each.it),
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            Act.of(
              [_gone.becomes(_offList.value.less(_each.it.asSet))],
              then: (c) => _land.from(c)(commit: c.commit),
            ),
            _admitted,
            _joinedMidFlight,
          ],
          next: to(JoinPlace.done),
        ),
      ),
      JoinPlace.done => const Leaves(),
    },
  );
}

/// The site a join names, `s` in the model, from the sites a world lets
/// join (`Joining`).
final _each = Pick<SiteId, JoinWorld>(
  Expr.ofConstant(ModelConst.joining, run: (c) => [_named.from(c)]),
);

final _named = Port<SiteId, JoinWorld>(
  'site',
  reads: const {},
  changes: const {},
  of: (w) => w.site.siteId,
);

/// `gone` as the join reads it: of the sites off the list, the one it
/// names, while no listed site is it.
final _offList = Var<Iterable<SiteId>, JoinWorld>(
  ModelVar.gone,
  read: (w) => [if (!w._sites.models.holdsObject(w.site)) w.site.siteId],
);
final _gone = Mutable<Iterable<SiteId>, JoinWorld>.remote(ModelVar.gone);

/// The land, which lists the site.
final _land = Port<void Function({required Commit commit}), JoinWorld>(
  'land',
  reads: const {},
  changes: {ModelVar.gone, ModelVar.ids},
  of: (w) => w.land,
);

/// The id it runs under, which the land chose as it admitted it against the
/// rows then: its own, or a fresh one where a listed site holds it.
final _admitted = modelOnly<JoinWorld>(
  "ids' = [ids EXCEPT ![s] = IF \\E t \\in Sites \\ gone : ids[t] = ids[s] "
  'THEN FreshId(s) ELSE ids[s]]',
  writes: {ModelVar.ids},
  reads: const Reads(vars: {ModelVar.ids, ModelVar.gone}),
);

/// A witness only the model keeps: a site joined while a flow was out.
final _joinedMidFlight = modelOnly<JoinWorld>(
  "seen' = seen \\cup (IF Idle THEN {} ELSE {\"joinedMidFlight\"})",
  writes: {ModelVar.seen},
  reads: const Reads(vars: {ModelVar.seen, ModelVar.fl}),
);
