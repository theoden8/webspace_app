import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/model_names.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

/// Where a page's sign-in is: its one step, and the place the input leaves
/// by.
enum SignInPlace { signIn, done }

/// What a sign-in runs against: the page's sites, the one whose page signs
/// in, and whether every flow has finished as it began.
final class SignInWorld implements SiteModels {
  SignInWorld(this._sites, {required this.site, required this.idle});

  final SiteRuntime _sites;
  final WebViewModel site;
  final bool idle;

  @override
  WebViewModel siteOf(SiteId id) => _sites.siteOf(id);
}

/// A loaded site's page signing in (`Login`): an input of the environment
/// that starts no flow. The app writes no cookie of its own; the page does,
/// into the shared jar, so this table is the fake platform's and the walk
/// runs it. Only at rest: a page write inside another site's
/// capture-nuke-restore is lost by design of the shared jar. The write is
/// the step's one await (`cookieSet`), so it lands in the stretch the step
/// is charged with, as a reply lands before its arm. On containers the
/// session goes to the site's own container, which the model does not
/// follow, and no step is taken.
abstract final class PageSignIn {
  /// [site]'s page signs in, its session written by [write].
  static Future<void> signIn(
    SiteRuntime sites, {
    required WebViewModel site,
    required bool idle,
    required Future<void> Function() write,
  }) async {
    final c = StepContext(SignInWorld(sites, site: site, idle: idle));
    final admitted = table.admits(SignInPlace.signIn, on: c);
    await write();
    if (admitted) table.runInput(c, from: SignInPlace.signIn);
  }

  static final StepTable<SignInWorld, SignInPlace> table = StepTable(
    SignInPlace.values,
    vars: [_loaded],
    ending: {SignInPlace.done},
    at: (place) => switch (place) {
      SignInPlace.signIn => Step.input(
        ActivationStep.login,
        pick: _each,
        site: _each.it,
        enabled: ~_containers & _idle & _loaded.value.has(_each.it),
        otherwise: Otherwise(
          StepOutcome.none,
          then: [
            Act.of([
              _jar.becomes(_jar.value.union(_each.it.asSet)),
              _signedIn.becomes(_signedIn.value.union(_each.it.asSet)),
            ]),
          ],
          next: to(SignInPlace.done),
        ),
      ),
      SignInPlace.done => const Leaves(),
    },
  );
}

/// The site whose page signs in, `s` in the model, any site its guard
/// admits.
final _each = Pick<SiteId, SignInWorld>(
  Expr.ofConstant(ModelConst.sites, run: (c) => [_named.from(c)]),
);

final _named = Port<SiteId, SignInWorld>(
  'site',
  reads: const {},
  changes: const {},
  of: (w) => w.site.siteId,
);

final _containers = Constant<bool, SignInWorld>(
  ModelConst.containers,
  read: (w) => w._sites.useContainers,
).value;

/// Every flow finished (`Idle`), as the walk counts them.
final _idle = Expr.base<bool, SignInWorld>(
  BaseOp.idle,
  args: const [],
  run: (c) => _rest.from(c),
);

final _rest = Port<bool, SignInWorld>(
  'idle',
  reads: const {},
  changes: const {},
  of: (w) => w.idle,
);

final _loaded = Mutable<Iterable<SiteId>, SignInWorld>.over(
  ModelVar.loaded,
  of: (w) => w._sites.vars.loaded,
);

/// `jar`, the sites whose sessions the shared jar holds, which the page's
/// write makes so.
final _jar = Mutable<Iterable<SiteId>, SignInWorld>.remote(ModelVar.jar);

/// `signedIn`, kept by the model alone.
final _signedIn = Mutable<Iterable<SiteId>, SignInWorld>.remote(
  ModelVar.signedIn,
);
