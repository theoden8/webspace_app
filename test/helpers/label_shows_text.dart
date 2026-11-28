import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every tappable node's name holds the text it shows (WCAG 2.5.3, label in
/// name): Voice Control and Voice Access press a control by saying what is on
/// it, so a label that replaces the visible words leaves it unreachable.
///
/// A text counts as shown by the node its render object reports into, or the
/// node that one merges into. Text that is not on stage (an offstage route,
/// an `IndexedStack`'s other children) is skipped, as the semantics walk
/// skips it; text hidden only from the reader (`ExcludeSemantics`,
/// `excludeSemantics: true`) is not, since a sighted user still reads it.
/// Icon glyphs are not text.
const AccessibilityGuideline labelShowsTextGuideline = _LabelShowsText();

class _LabelShowsText extends AccessibilityGuideline {
  const _LabelShowsText();

  @override
  String get description =>
      "A tappable node's label contains the text it shows";

  @override
  FutureOr<Evaluation> evaluate(WidgetTester tester) {
    var result = const Evaluation.pass();
    for (final view in tester.binding.renderViews) {
      final failures = <String>{};
      _walk(view, node: null, failures: failures);
      for (final failure in failures) {
        result += Evaluation.fail(failure);
      }
    }
    return result;
  }

  void _walk(RenderObject object,
      {required SemanticsNode? node, required Set<String> failures}) {
    final owned = object.debugSemantics ?? node;
    if (object is RenderParagraph) _check(object, node: owned, failures: failures);
    void visit(RenderObject child) =>
        _walk(child, node: owned, failures: failures);
    final hiddenFromReaderOnly = switch (object) {
      RenderExcludeSemantics(:final excluding) => excluding,
      RenderSemanticsAnnotations(:final excludeSemantics) => excludeSemantics,
      _ => false,
    };
    if (hiddenFromReaderOnly) {
      object.visitChildren(visit);
    } else {
      object.visitChildrenForSemantics(visit);
    }
  }

  void _check(RenderParagraph paragraph,
      {required SemanticsNode? node, required Set<String> failures}) {
    final shown = _plain(paragraph.text.toPlainText());
    if (shown.isEmpty || !paragraph.hasSize || paragraph.size.isEmpty) return;
    var control = node;
    while (control != null && control.isMergedIntoParent) {
      control = control.parent;
    }
    if (control == null ||
        control.isInvisible ||
        control.flagsCollection.isHidden ||
        control.flagsCollection.isTextField) {
      return;
    }
    final data = control.getSemanticsData();
    if (!data.hasAction(SemanticsAction.tap) &&
        !data.hasAction(SemanticsAction.longPress)) {
      return;
    }
    if (_plain(data.label).contains(shown) ||
        _plain(data.tooltip).contains(shown)) {
      return;
    }
    failures.add('$control shows "$shown", but its label is '
        '"${data.label}"${data.tooltip.isEmpty ? '' : ' and its tooltip '
            '"${data.tooltip}"'}');
  }

  static final _space = RegExp(r'\s+');

  /// Private-use code points are icon glyphs; U+FFFC holds a widget span's
  /// place.
  static final _notText = RegExp('[-￼]|[\u{F0000}-\u{10FFFF}]',
      unicode: true);

  static String _plain(String text) =>
      text.replaceAll(_notText, '').replaceAll(_space, ' ').trim();
}
