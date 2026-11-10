import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/step_flow.dart';
import 'package:webspace/services/step_table.dart';

/// The step that deletes the containers of [sites] once the frame has
/// unmounted their webviews: a container a mounted webview still binds is
/// kept (CONT-010). A delete and an archive's close place it; each names its
/// [step], where it waits ([at]), the [port] that deletes, and what follows
/// ([next]).
Await<W, P> retireContainers<E, W, P extends Enum>(
  ActivationStep step, {
  required P at,
  required Port<Future<void> Function(), W> port,
  required Expr<Iterable<E>, W> sites,
  required Mutable<Iterable<E>, W> boxes,
  required Mutable<Iterable<E>, W> views,
  required Then<W, P> next,
}) => Await<W, P>(
  step,
  at: at,
  holds: null,
  call: Call.on(
    port,
    run: (c) => c.api(),
    writes: [boxes.becomes(boxes.value.less(sites.less(views.value)))],
  ),
  decide: Ends(StepOutcome.none, next: next),
);
