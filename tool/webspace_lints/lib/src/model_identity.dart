import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

/// The model knows a site by its id. In a library that declares step tables
/// (it imports step_table.dart), two values that carry a key of the model's
/// (`ModelKeyed`: a site's id) are compared by that key, never as objects. An
/// import that carries a site again lists a new object under its id while a
/// flow in flight holds the old one, so an identity check there sees a site
/// gone that the model still lists: an activation deletes the carried
/// site's container that way. A check for the live object itself says so
/// with identical(). (CONT-012)
///
/// A type cannot hold this: Dart's `==`, `contains`, `indexOf` and a map's
/// keys take `Object`, so nothing static stops comparing two sites as
/// objects. Leaves typed `SiteId` (loaded, current, each flow's site) would,
/// and are owed in docs/security/policy_debt.tsv.
class ModelIdentity extends AnalysisRule {
  static const code = LintCode(
    'model_identity',
    "'{0}' compares sites as objects, and the model knows a site by its id.",
    correctionMessage:
        'Compare their siteId (or modelKey); a check for the live object '
        'itself says so with identical().',
    severity: DiagnosticSeverity.ERROR,
  );

  static const _tables = 'package:webspace/services/step_table.dart';

  ModelIdentity()
    : super(
        name: 'model_identity',
        description: 'Step code compares sites by id.',
      );

  @override
  DiagnosticCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    if (!context.isInLibDir) return;
    final library = context.libraryElement;
    if (library == null) return;
    final declaresTables = library.fragments.any(
      (f) => f.importedLibraries.any((l) => l.uri.toString() == _tables),
    );
    if (!declaresTables) return;
    final visitor = _Visitor(rule: this);
    registry
      ..addMethodInvocation(this, visitor)
      ..addBinaryExpression(this, visitor)
      ..addIndexExpression(this, visitor);
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor({required this.rule});

  final ModelIdentity rule;

  /// The collection members that find an element by its `==`.
  static const _byEquality = {
    'contains',
    'indexOf',
    'lastIndexOf',
    'remove',
    'containsKey',
    'containsValue',
  };

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    if (!_byEquality.contains(name)) return;
    if (!_isCollection(node.realTarget?.staticType)) return;
    final args = node.argumentList.arguments;
    if (args.isEmpty || !_keyed(args.first.argumentExpression.staticType)) {
      return;
    }
    rule.reportAtNode(node.methodName, arguments: [name]);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    final op = node.operator.type;
    if (op != TokenType.EQ_EQ && op != TokenType.BANG_EQ) return;
    if (!_keyed(node.leftOperand.staticType) ||
        !_keyed(node.rightOperand.staticType)) {
      return;
    }
    rule.reportAtToken(node.operator, arguments: [node.operator.lexeme]);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    final target = node.realTarget.staticType;
    if (target is! InterfaceType || !_isMap(target)) return;
    if (!_keyed(node.index.staticType)) return;
    rule.reportAtNode(node.index, arguments: ['[]']);
  }

  static bool _keyed(DartType? type) {
    if (type is! InterfaceType) return false;
    bool named(InterfaceType t) =>
        t.element.name == 'ModelKeyed' &&
        (t.element.library.uri.toString() == ModelIdentity._tables);
    return named(type) || type.element.allSupertypes.any(named);
  }

  static bool _isCollection(DartType? type) =>
      type is InterfaceType && (_isIterable(type) || _isMap(type));

  static bool _isIterable(InterfaceType type) => _isCore(type, 'Iterable');

  static bool _isMap(InterfaceType type) => _isCore(type, 'Map');

  static bool _isCore(InterfaceType type, String name) {
    bool core(InterfaceType t) =>
        t.element.name == name && t.element.library.isDartCore;
    return core(type) || type.element.allSupertypes.any(core);
  }
}
