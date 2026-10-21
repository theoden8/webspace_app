import 'dart:typed_data';

import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/tab_leaves.dart';

/// A capture of a site's back stack, keyed by the tab its webview was built
/// for as the capture began (TAB-003): [read] waits on the webview, then
/// [stillHolds] says whether that tab is still listed under the same key,
/// and [save] writes its file, answering whether the store took it. Two awaits, so a close or a rebind may land
/// between them; a flow has a step at each ([captureSteps]).
abstract interface class NavCapture {
  Future<Uint8List?> read();
  bool stillHolds();
  Future<bool> save(Uint8List bytes);
}

/// A flow's world, which holds the capture in flight between its steps.
abstract interface class Capturing {
  abstract NavCapture? capture;
}

/// What a capture needs of its flow: the [site], how its webview's tab is
/// read ([built]), how the capture [begin]s, what the steps mark ([marks],
/// the site unless the flow marks nothing), and, for a flow that keeps the
/// back stack it reads only sometimes, when it does ([keeps]): [begin]
/// reads it and begins no capture where it does not hold.
typedef CaptureOf<S, W> = ({
  Expr<S, W> site,
  TabId? Function(S site) built,
  NavCapture? Function(StepView<W> c) begin,
  Expr<Object?, W>? marks,
  Expr<bool, W>? keeps,
});

/// The steps' names, as `ActivationStep` has them.
typedef CaptureNames = ({ActivationStep read, ActivationStep save});

/// Where the save waits, and where both steps go on to.
typedef CapturePlaces<P, W> = ({P save, Expr<P, W> after});

/// The two steps of a capture of a site's back stack in a flow over [W]
/// (TAB-003): the read waits on the webview, keyed by the tab read as the
/// capture began (`Call.reads`), and goes on without a write (`skip`) when
/// the site keeps no back stack or that tab closed or moved meanwhile; the
/// save waits on the file write. The read's own [first] branches come
/// before the drop. The model decides the drop for the sites it follows
/// (`Tabbed`) and writes no file for the others; the code follows every
/// site.
({Step<W, P> read, Step<W, P> save})
captureSteps<S, W extends Capturing, P extends Enum>({
  required CaptureNames names,
  required CapturePlaces<P, W> places,
  required CaptureOf<S, W> of,
  List<Branch<W, P>> first = const [],
}) {
  final tab = capTab<W>();
  final bytes = capHist<W>();
  // The capture in flight, code-only state of the flow, whose save writes
  // the tab's file.
  final inFlight = Port<Capturing, W>(
    'capture',
    reads: const {},
    changes: {ModelVar.file},
    of: (w) => w,
  );
  final noBytes = Expr.constant<Uint8List?, W>(null, tla: '0');
  // The key names the tab's container too; no flip is modelled, so in the
  // model the tab's listing alone decides.
  final holds = Expr.handPaired<bool, W>(
    HandPaired.captureHolds,
    tla: '${tab.value.tla} \\in tabs[${of.site.tla}]',
    run: (c) => inFlight.from(c).capture?.stillHolds() ?? false,
    reads: tab.value.reads + of.site.reads + const Reads(vars: {ModelVar.tabs}),
  );
  // A site whose tab keeps no back stack gives the capture nothing to
  // read, whether or not the model follows its tabs, and neither does a
  // flow that keeps none.
  final keeps = of.keeps;
  final noNavState = '${of.site.tla} \\in NoNavState';
  final none = Expr.handPaired<bool, W>(
    HandPaired.captureNone,
    tla: keeps == null ? noNavState : '($noNavState) \\/ ~(${keeps.tla})',
    run: (c) => inFlight.from(c).capture == null,
    reads: of.site.reads + (keeps?.reads ?? Reads.none),
    needs: const {(of: ModelConst.noNavState, set: true)},
  );
  return (
    read: Step(
      names.read,
      holds: null,
      call: bytes.receives(
        run: (c) async {
          final capture = inFlight.from(c).capture = of.begin(c);
          return capture?.read();
        },
        reply: bytes.value,
        reads: captureStart<S, W>(of.site, built: of.built),
      ),
      site: of.marks,
      branches: [
        ...first,
        Branch(
          StepOutcome.skip,
          when: none |
              tabbedOf<S, W>().has(of.site) & (bytes.value.eq(noBytes) | ~holds),
          then: [],
          next: places.after,
        ),
      ],
      otherwise: Otherwise(StepOutcome.go, then: [], next: to(places.save)),
    ),
    save: Step(
      names.save,
      holds: null,
      call: Call.on(
        inFlight,
        run: (c) => c.api.capture!.save(bytes.of(c)!),
        writes: [captured<S, W>(of.site)],
      ),
      site: of.marks,
      otherwise: Otherwise(StepOutcome.none, then: [], next: places.after),
    ),
  );
}
