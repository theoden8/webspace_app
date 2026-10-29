import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

/// CLAUDE.md rule 2: a signature takes at most one positional parameter, and
/// never a positional bool.
///
/// Exempt, because the signature is fixed from outside: overrides, operators,
/// setters, a top-level `main`, closures (typed by what they are passed as),
/// and a declaration its own library hands to code outside the package: torn
/// off into a parameter declared there or typed by a typedef declared there
/// (`List.sort`, `ValueChanged<bool>`), or a function type given to
/// `dart:ffi`'s `lookupFunction`, `asFunction` or `NativeFunction` (the C
/// ABI's shape).
class PositionalParameters extends AnalysisRule {
  static const LintCode code = LintCode(
    'positional_parameters',
    "'{0}' takes {1}.",
    correctionMessage:
        "Name every parameter past the first ('required' where it has no "
        'default), and a bool even when it is the first.',
    severity: DiagnosticSeverity.ERROR,
  );

  PositionalParameters()
    : super(
        name: 'positional_parameters',
        description:
            'A signature takes at most one positional parameter, never a bool.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    registry.addCompilationUnit(this, _Unit(rule: this, context: context));
  }
}

class _Unit extends SimpleAstVisitor<void> {
  _Unit({required this.rule, required this.context});

  final AnalysisRule rule;
  final RuleContext context;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    final scan = _Scan(context: context);
    node.accept(scan);
    for (final s in scan.signatures) {
      if (scan.fixedDeclarations.contains(s.element) ||
          scan.fixedTypes.contains(s.node.parent)) {
        continue;
      }
      rule.reportAtNode(s.node, arguments: [s.name, s.why]);
    }
  }
}

/// A signature the rule rejects unless something fixes it from outside.
typedef _Signature = ({
  FormalParameterList node,
  Element? element,
  String name,
  String why,
});

class _Scan extends RecursiveAstVisitor<void> {
  _Scan({required this.context});

  final RuleContext context;
  final signatures = <_Signature>[];

  /// The declarations code outside the package fixes the shape of.
  final fixedDeclarations = <Element>{};

  /// The inline function types code outside the package fixes the shape of.
  final fixedTypes = <GenericFunctionType>{};

  void _check({
    required String name,
    required FormalParameterList? parameters,
    required Element? element,
  }) {
    if (parameters == null) return;
    final positional = parameters.parameters
        .where((p) => p.isPositional)
        .toList();
    final bools = positional.where(_isBool).toList();
    if (positional.length < 2 && bools.isEmpty) return;
    final why = bools.isNotEmpty
        ? 'a positional bool ${bools.map((p) => p.name?.lexeme).join(', ')}'
        : '${positional.length} positional parameters';
    signatures.add((node: parameters, element: element, name: name, why: why));
  }

  static bool _isBool(FormalParameter p) {
    if (p.functionTypedSuffix != null) return false;
    if (p.declaredFragment?.element.type case final type?) {
      return type.isDartCoreBool;
    }
    final type = p.type;
    return type is NamedType && (type.type?.isDartCoreBool ?? false);
  }

  /// `@override` from dart:core, read off the annotation's element rather
  /// than `hasOverride`, which matches dart:core by its library name.
  static bool _overrides(Element? element) =>
      element?.metadata.annotations.any((a) {
        final target = a.element;
        return target?.name == 'override' && _inSdk(target, uri: 'dart:core');
      }) ??
      false;

  static bool _inSdk(Element? element, {required String uri}) =>
      element?.baseElement.library?.uri.toString() == uri;

  bool _foreign(Element? element) {
    final source = element?.baseElement.library?.firstFragment.source;
    if (source == null) return false;
    return !(context.package?.contains(source) ?? false);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final topLevelMain =
        node.parent is CompilationUnit && node.name.lexeme == 'main';
    if (!topLevelMain) {
      _check(
        name: node.name.lexeme,
        parameters: node.functionExpression.parameters,
        element: node.declaredFragment?.element,
      );
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final element = node.declaredFragment?.element;
    if (!_overrides(element) && !node.isOperator && !node.isSetter) {
      _check(
        name: node.name.lexeme,
        parameters: node.parameters,
        element: element,
      );
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    final owner = node.typeName?.name ?? '?';
    final named = node.name?.lexeme;
    _check(
      name: named == null ? owner : '$owner.$named',
      parameters: node.parameters,
      element: node.declaredFragment?.element,
    );
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitGenericFunctionType(GenericFunctionType node) {
    final alias = node.parent;
    _check(
      name: alias is GenericTypeAlias ? alias.name.lexeme : 'Function type',
      parameters: node.parameters,
      element: alias is GenericTypeAlias
          ? alias.declaredFragment?.element
          : null,
    );
    super.visitGenericFunctionType(node);
  }

  @override
  void visitFunctionTypedFormalParameterSuffix(
    FunctionTypedFormalParameterSuffix node,
  ) {
    final owner = node.parent;
    final name = owner is FormalParameter ? owner.name?.lexeme : null;
    _check(
      name: '${name ?? '?'} (function-typed parameter)',
      parameters: node.formalParameters,
      element: null,
    );
    super.visitFunctionTypedFormalParameterSuffix(node);
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    _check(
      name: node.name.lexeme,
      parameters: node.parameters,
      element: node.declaredFragment?.element,
    );
    super.visitFunctionTypeAlias(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    _tornOff(node, element: node.element);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    _tornOff(node, element: node.element);
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    _tornOff(node, element: node.propertyName.element);
    super.visitPropertyAccess(node);
  }

  /// A declaration passed as a value where code outside the package fixes
  /// what it must take.
  void _tornOff(Expression node, {required Element? element}) {
    if (element is! ExecutableElement) return;
    final parent = node.parent;
    final parameter = parent is NamedArgument
        ? parent.correspondingParameter
        : node.correspondingParameter;
    if (parameter == null) return;
    final type = parameter.type;
    final byForeignType = type is FunctionType && _foreign(type.alias?.element);
    if (_foreign(parameter) || byForeignType) {
      fixedDeclarations.add(element.baseElement);
    }
  }

  static const _binders = {'lookupFunction', 'asFunction', 'NativeFunction'};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_binders.contains(node.methodName.name) &&
        _inSdk(node.methodName.element, uri: 'dart:ffi')) {
      _native(node.typeArguments);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitNamedType(NamedType node) {
    if (_binders.contains(node.name.lexeme) &&
        _inSdk(node.element, uri: 'dart:ffi')) {
      _native(node.typeArguments);
    }
    super.visitNamedType(node);
  }

  void _native(TypeArgumentList? arguments) {
    for (final argument in arguments?.arguments ?? const <TypeAnnotation>[]) {
      switch (argument) {
        case GenericFunctionType():
          fixedTypes.add(argument);
        case NamedType(:final element?):
          fixedDeclarations.add(element.baseElement);
        case NamedType():
        case RecordTypeAnnotation():
          break;
      }
    }
  }
}
