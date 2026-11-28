import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

/// A control exposes its action through semantics (the accessibility spec's
/// "every control has a name, a role and an action"): a `Listener` that acts
/// on `onPointerUp` is a tap a screen reader or Switch Access cannot press,
/// since only a gesture recognizer or a `Semantics` gives a node its tap. In
/// `lib/` such a `Listener` sits inside a `Semantics` with `onTap:` in the
/// same build expression, the one a reader presses. A `GestureDetector` with
/// `onTap:` gives its node the tap itself, so it needs none.
class RawTap extends AnalysisRule {
  static const code = LintCode(
    'raw_tap',
    "This 'Listener' acts on a raw pointer up that no screen reader can press.",
    correctionMessage:
        "Wrap it in a 'Semantics' whose 'onTap:' does the same, or use a "
        "'GestureDetector'.",
    severity: DiagnosticSeverity.ERROR,
  );

  RawTap()
    : super(
        name: 'raw_tap',
        description: 'A raw tap is also a semantic tap.',
      );

  @override
  DiagnosticCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    if (!context.isInLibDir) return;
    registry.addInstanceCreationExpression(this, _Visitor(rule: this));
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor({required this.rule});

  final RawTap rule;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (!_isFlutter(node, name: 'Listener')) return;
    if (!_gives(node, argument: 'onPointerUp')) return;
    for (AstNode? up = node.parent; up != null; up = up.parent) {
      if (up is MethodDeclaration || up is CompilationUnitMember) break;
      if (up is InstanceCreationExpression &&
          _isFlutter(up, name: 'Semantics') &&
          _gives(up, argument: 'onTap')) {
        return;
      }
    }
    rule.reportAtNode(node.constructorName);
  }

  static bool _isFlutter(InstanceCreationExpression node, {required String name}) {
    final made = node.constructorName.element?.enclosingElement;
    return made != null &&
        made.name == name &&
        made.library.uri.toString().startsWith('package:flutter/');
  }

  static bool _gives(InstanceCreationExpression node, {required String argument}) {
    final given = node.argumentList.arguments
        .whereType<NamedArgument>()
        .where((a) => a.name.lexeme == argument)
        .firstOrNull;
    return given != null && given.argumentExpression is! NullLiteral;
  }
}
