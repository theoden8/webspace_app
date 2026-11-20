import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

/// A button that shows only an icon names itself (the accessibility spec's
/// "every control has a name"), or a screen
/// reader announces "button" and Voice Control has nothing to say. An
/// `IconButton` or a `FloatingActionButton` in `lib/` takes a `tooltip:`,
/// which is both its accessible name and the hint a pointer hovers for. A
/// `FloatingActionButton.extended` shows its label and is named by it.
class UnnamedButton extends AnalysisRule {
  static const code = LintCode(
    'unnamed_button',
    "'{0}' shows only an icon and has no name.",
    correctionMessage:
        "Pass 'tooltip:' with what the button does, from the localizations.",
    severity: DiagnosticSeverity.ERROR,
  );

  UnnamedButton()
    : super(
        name: 'unnamed_button',
        description: 'An icon-only button names itself.',
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

  final UnnamedButton rule;

  static const _iconOnly = {'IconButton', 'FloatingActionButton'};

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final constructor = node.constructorName.element;
    final made = constructor?.enclosingElement;
    if (made == null || !_iconOnly.contains(made.name)) return;
    if (!made.library.uri.toString().startsWith('package:flutter/')) return;
    if (made.name == 'FloatingActionButton' &&
        constructor?.name == 'extended') {
      return;
    }
    final tooltip = node.argumentList.arguments
        .whereType<NamedArgument>()
        .where((a) => a.name.lexeme == 'tooltip')
        .firstOrNull;
    if (tooltip != null && tooltip.argumentExpression is! NullLiteral) return;
    rule.reportAtNode(node.constructorName, arguments: [made.name ?? 'button']);
  }
}
