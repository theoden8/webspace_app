import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

/// Where a row's move is: its one step, and the place the input leaves by.
enum MovePlace { move, done }

/// A move of the list's rows, as `SitesMoved` names it: the site at [from]
/// takes the place [to], both among the listed sites, counted from 0.
typedef RowMove = ({int from, int to});

/// What a move runs against: the page's sites, the move, and the land that
/// makes it.
final class MoveWorld implements SiteModels {
  MoveWorld(this._sites, {required this.move, required this.land});

  final SiteRuntime _sites;
  final RowMove move;

  /// The rows move, in [commit].
  final void Function({required Commit commit}) land;

  @override
  WebViewModel siteOf(SiteId id) => _sites.siteOf(id);
}

/// A row moving in the list (`Move`): an input that starts no flow. It
/// permutes the listed rows as the code's list is permuted and keeps a row
/// off the list in place, so a move after an archive's close is one the
/// model takes too. What the runtime and every flow hold names sites, so a
/// move changes nothing else and supersedes no flow in flight (BUG-029).
/// `SiteRuntime.apply` runs it for a `SitesMoved` that moves a row.
abstract final class MoveTable {
  /// The rows move as [move] says, by [land].
  static void move(
    SiteRuntime sites, {
    required RowMove move,
    required void Function({required Commit commit}) land,
  }) {
    assert(move.from != move.to, 'a move to its own place is none');
    table.runInput(
      StepContext(MoveWorld(sites, move: move, land: land)),
      from: MovePlace.move,
    );
  }

  static final StepTable<MoveWorld, MovePlace> table = StepTable(
    MovePlace.values,
    vars: const [],
    ending: {MovePlace.done},
    at: (place) => switch (place) {
      MovePlace.move => Step.input(
        ActivationStep.move,
        pick: _each,
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            Act.of(
              [
                _rows.becomes(
                  Expr.base(
                    BaseOp.movedRows,
                    args: [_each.it],
                    run: (_) => throw StateError(
                      'the rows a move leaves are the land\'s to make',
                    ),
                  ),
                ),
              ],
              then: (c) => _land.from(c)(commit: c.commit),
            ),
            midFlight('movedMidFlight'),
          ],
          next: to(MovePlace.done),
        ),
      ),
      MovePlace.done => const Leaves(),
    },
  );
}

/// The move the user makes, `mv` in the model, among the moves they can
/// (`MovePairs`): the code's, its places counted from 1.
final _each = Pick<RowMove, MoveWorld>(
  Expr.base(
    BaseOp.movePairs,
    args: const [],
    run: (c) {
      final (:from, :to) = _move.from(c);
      return [(from: from + 1, to: to + 1)];
    },
  ),
);

final _move = Port<RowMove, MoveWorld>(
  'move',
  reads: const {},
  changes: const {},
  of: (w) => w.move,
);

/// `rows`, which the land writes as it moves the code's list.
final _rows = Mutable<Iterable<SiteId>, MoveWorld>.remote(ModelVar.rows);

/// The land, which moves the row.
final _land = Port<void Function({required Commit commit}), MoveWorld>(
  'land',
  reads: const {},
  changes: {ModelVar.rows},
  of: (w) => w.land,
);
