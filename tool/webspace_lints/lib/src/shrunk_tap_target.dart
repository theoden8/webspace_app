import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

/// A control the user taps keeps Flutter's padded tap target: Android's 48dp
/// floor, above iOS's 44pt. `MaterialTapTargetSize.shrinkWrap` gives that
/// up, which the drawer's back row did at 32dp. The rule refuses it on a
/// widget given a tap handler (`onPressed:`, `onTap:`, ...), passed directly
/// or through the `style:` a `styleFrom` builds; on a widget nothing taps (a
/// label chip) it may stay. A type cannot say this: the size is a value.
class ShrunkTapTarget extends AnalysisRule {
  static const code = LintCode(
    'shrunk_tap_target',
    'A tappable {0} shrinks its tap target below the platform floor.',
    correctionMessage:
        'Drop the shrinkWrap: the padded tap target is 48dp, the drawn '
        'control can stay smaller.',
    severity: DiagnosticSeverity.ERROR,
  );

  ShrunkTapTarget()
    : super(
        name: 'shrunk_tap_target',
        description: 'A tappable control keeps its padded tap target.',
      );

  @override
  DiagnosticCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    if (!context.isInLibDir) return;
    final visitor = _Visitor(rule: this);
    registry
      ..addPrefixedIdentifier(this, visitor)
      ..addPropertyAccess(this, visitor);
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor({required this.rule});

  final ShrunkTapTarget rule;

  static const _taps = {
    'onPressed',
    'onTap',
    'onLongPress',
    'onSelected',
    'onChanged',
  };

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) =>
      _check(node, element: node.element);

  @override
  void visitPropertyAccess(PropertyAccess node) =>
      _check(node, element: node.propertyName.element);

  void _check(Expression node, {required Element? element}) {
    if (element is! FieldElement && element is! PropertyAccessorElement) {
      return;
    }
    final owner = element?.enclosingElement;
    if (element?.name != 'shrinkWrap' ||
        owner?.name != 'MaterialTapTargetSize' ||
        !(owner?.library?.uri.toString().startsWith('package:flutter/') ??
            false)) {
      return;
    }
    final widget = _tappedWidget(node);
    if (widget == null) return;
    rule.reportAtNode(node, arguments: [widget]);
  }

  /// The widget [value] sizes, when something taps it: the creation whose
  /// argument it is, or the one a `styleFrom` holding it is the style of.
  String? _tappedWidget(Expression value) {
    final args = value.parent is NamedArgument ? value.parent!.parent : null;
    if (args is! ArgumentList) return null;
    final call = args.parent;
    if (call is InstanceCreationExpression) {
      return _taps.any((t) => _given(args, name: t)) ? _name(call) : null;
    }
    if (call is MethodInvocation && call.methodName.name == 'styleFrom') {
      final style = call.parent;
      if (style is! NamedArgument || style.name.lexeme != 'style') return null;
      return _tappedWidget(call);
    }
    return null;
  }

  static bool _given(ArgumentList args, {required String name}) => args
      .arguments
      .whereType<NamedArgument>()
      .any((a) => a.name.lexeme == name && a.argumentExpression is! NullLiteral);

  static String _name(InstanceCreationExpression call) =>
      call.constructorName.type.name.lexeme;
}
