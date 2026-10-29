import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

/// CLAUDE.md's Style, no catch-alls: a handler names the failures it
/// handles, read off the resolved types. A type that names no failure is
/// `Object`, `Exception`, `Error` or `dynamic`, through any alias; code of
/// ours throws a named type, never a plain `Exception(...)`, which only a
/// catch-all can catch.
class CatchAll extends MultiAnalysisRule {
  static const generic = LintCode(
    'catch_all',
    "'{0}' names no failure, so this also takes the ones nobody expected.",
    correctionMessage:
        'Name the types the call throws, read from its source; drop the '
        'handler when the failure already has an owner.',
    severity: DiagnosticSeverity.ERROR,
    uniqueName: 'LintCode.catch_all_generic',
  );

  static const untested = LintCode(
    'catch_all',
    "This '{0}' has no test:, so it also takes Errors, which are bugs.",
    correctionMessage: 'Pass test: naming the types it handles.',
    severity: DiagnosticSeverity.ERROR,
    uniqueName: 'LintCode.catch_all_untested',
  );

  static const dropped = LintCode(
    'catch_all',
    'This error handler drops its error, so every failure goes unseen.',
    correctionMessage:
        "Hand the error on, or use handleError(..., test:) naming the ones "
        'it expects.',
    severity: DiagnosticSeverity.ERROR,
    uniqueName: 'LintCode.catch_all_dropped',
  );

  static const plain = LintCode(
    'catch_all',
    'A plain Exception can only be caught as Exception.',
    correctionMessage: 'Throw a type that says what failed.',
    severity: DiagnosticSeverity.ERROR,
    uniqueName: 'LintCode.catch_all_plain',
  );

  CatchAll()
    : super(
        name: 'catch_all',
        description: 'A handler names the failures it handles.',
      );

  @override
  List<DiagnosticCode> get diagnosticCodes => const [
    generic,
    untested,
    dropped,
    plain,
  ];

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final visitor = _Visitor(rule: this);
    registry
      ..addCatchClause(this, visitor)
      ..addMethodInvocation(this, visitor)
      ..addInstanceCreationExpression(this, visitor);
  }
}

/// Where a call takes an error handler, and whether a `test:` narrows it.
enum _Handler {
  /// `Future.catchError`, `Stream.handleError`: a `test:` narrows them, and
  /// one without takes every failure.
  narrowed,

  /// `Future.onError<E>`: its type argument narrows it, and a `test:`
  /// narrows a generic one.
  typed,

  /// `Stream.listen(onError:)`, `Future.then(onError:)`,
  /// `StreamSubscription.onError`: nothing narrows them, so the handler
  /// must hand the error on.
  open,
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor({required this.rule});

  final MultiAnalysisRule rule;

  @override
  void visitCatchClause(CatchClause node) {
    final on = node.exceptionType;
    if (_names(on?.type) case final name? when on != null) {
      rule.reportAtNode(
        on,
        diagnosticCode: CatchAll.generic,
        arguments: [name],
      );
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final made = node.constructorName.element?.enclosingElement;
    if (made != null && _isCore(made, name: 'Exception')) {
      rule.reportAtNode(node, diagnosticCode: CatchAll.plain);
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final method = node.methodName.element;
    final handler = _handlerOf(method);
    if (handler == null) return;
    final arguments = node.argumentList.arguments;
    final test = _named(arguments, name: 'test');
    switch (handler) {
      case _Handler.narrowed:
        if (test == null) {
          rule.reportAtNode(
            node.methodName,
            diagnosticCode: CatchAll.untested,
            arguments: [node.methodName.name],
          );
        } else {
          _checkTest(test);
        }
      case _Handler.typed:
        final handled = node.typeArgumentTypes?.firstOrNull;
        if (test != null) {
          _checkTest(test);
        } else if (_names(handled) case final name?) {
          rule.reportAtNode(
            node.typeArguments ?? node.methodName,
            diagnosticCode: CatchAll.generic,
            arguments: [name],
          );
        }
      case _Handler.open:
        final onError = method?.name == 'onError'
            ? arguments.firstOrNull?.argumentExpression
            : _named(arguments, name: 'onError');
        if (onError is FunctionExpression && _drops(onError)) {
          rule.reportAtNode(onError, diagnosticCode: CatchAll.dropped);
        }
    }
  }

  /// A `test:` whose predicate admits a type that names no failure, or every
  /// value.
  void _checkTest(Expression test) {
    if (test is! FunctionExpression) return;
    final body = test.body;
    final result = switch (body) {
      ExpressionFunctionBody(:final expression) => expression,
      BlockFunctionBody(:final block) => switch (block.statements) {
        [ReturnStatement(:final expression?)] => expression,
        _ => null,
      },
      _ => null,
    };
    for (final admitted in _disjuncts(result)) {
      final name = switch (admitted) {
        IsExpression(notOperator: null, :final type) => _names(type.type),
        BooleanLiteral(value: true) => 'true',
        _ => null,
      };
      if (name != null) {
        rule.reportAtNode(
          admitted,
          diagnosticCode: CatchAll.generic,
          arguments: [name],
        );
      }
    }
  }

  static Iterable<Expression> _disjuncts(Expression? e) sync* {
    switch (e) {
      case null:
        return;
      case ParenthesizedExpression(:final expression):
        yield* _disjuncts(expression);
      case BinaryExpression(
            :final operator,
            :final leftOperand,
            :final rightOperand,
          )
          when operator.lexeme == '||':
        yield* _disjuncts(leftOperand);
        yield* _disjuncts(rightOperand);
      default:
        yield e;
    }
  }

  static Expression? _named(List<Argument> arguments, {required String name}) =>
      arguments
          .whereType<NamedArgument>()
          .where((a) => a.name.lexeme == name)
          .firstOrNull
          ?.argumentExpression;

  /// Whether [handler] never reads the error it is handed.
  static bool _drops(FunctionExpression handler) {
    final error = handler.parameters?.parameters.firstOrNull;
    if (error == null) return false;
    if (error.name?.lexeme == '_') return true;
    final element = error.declaredFragment?.element;
    if (element == null) return false;
    final reads = _Reads(element);
    handler.body.accept(reads);
    return !reads.found;
  }

  static _Handler? _handlerOf(Element? method) {
    if (method is! MethodElement) return null;
    final owner = method.enclosingElement;
    if (owner == null || !_inAsync(owner)) return null;
    return switch ((owner.name, method.name)) {
      ('Future', 'catchError') ||
      ('Stream', 'handleError') => _Handler.narrowed,
      ('FutureExtensions', 'onError') => _Handler.typed,
      ('Stream', 'listen') ||
      ('Future', 'then') ||
      ('StreamSubscription', 'onError') => _Handler.open,
      _ => null,
    };
  }

  /// The name of [type] when it names no failure: `Object`, `Exception`,
  /// `Error` or `dynamic`. A type parameter (`on E`) is named where its
  /// declaration is instantiated, which this does not follow.
  static String? _names(DartType? type) => switch (type) {
    DynamicType() => 'dynamic',
    InterfaceType(:final element)
        when const {
          'Object',
          'Exception',
          'Error',
        }.any((name) => _isCore(element, name: name)) =>
      element.name,
    _ => null,
  };

  static bool _isCore(Element element, {required String name}) =>
      element.name == name && element.library?.uri.toString() == 'dart:core';

  static bool _inAsync(Element element) =>
      element.library?.uri.toString() == 'dart:async';
}

/// Whether a body reads [error].
class _Reads extends RecursiveAstVisitor<void> {
  _Reads(this.error);

  final Element error;
  bool found = false;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.element == error) found = true;
  }
}
