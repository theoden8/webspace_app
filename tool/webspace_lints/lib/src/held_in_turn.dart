import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

/// A member marked `@Held(#q)` runs only inside the turn of `q`, a
/// `SerialQueue` of its class or library: called from a closure handed to
/// `q.run` or `q.enqueue`, or from another member held in `q`, on the same
/// object, with its future awaited or returned so the turn outlasts it.
class HeldInTurn extends MultiAnalysisRule {
  static const outside = LintCode(
    'held_in_turn',
    "'{0}' runs in {1}'s turn, and this code is not in it.",
    correctionMessage:
        "Call it from the closure passed to {1}.run or {1}.enqueue, or from "
        'a member marked @Held(#{1}).',
    severity: DiagnosticSeverity.ERROR,
    uniqueName: 'LintCode.held_in_turn_outside',
  );

  static const dropped = LintCode(
    'held_in_turn',
    "{1}'s turn can end before '{0}' does.",
    correctionMessage: 'Await or return its future.',
    severity: DiagnosticSeverity.ERROR,
    uniqueName: 'LintCode.held_in_turn_dropped',
  );

  static const unknown = LintCode(
    'held_in_turn',
    "'{0}' names no SerialQueue of its class or library.",
    correctionMessage: 'Name a SerialQueue field declared beside the member.',
    severity: DiagnosticSeverity.ERROR,
    uniqueName: 'LintCode.held_in_turn_unknown',
  );

  HeldInTurn()
    : super(
        name: 'held_in_turn',
        description: "A member marked @Held runs only inside its queue's turn.",
      );

  @override
  List<DiagnosticCode> get diagnosticCodes => const [outside, dropped, unknown];

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final visitor = _Visitor(rule: this);
    registry
      ..addMethodDeclaration(this, visitor)
      ..addFunctionDeclaration(this, visitor)
      ..addMethodInvocation(this, visitor)
      ..addSimpleIdentifier(this, visitor);
  }
}

/// The queue a member is held in: its `@Held` names it, and it resolves to a
/// `SerialQueue` field or top-level variable beside the member.
sealed class _Hold {}

final class _Unheld extends _Hold {}

final class _Unresolved extends _Hold {
  _Unresolved({required this.annotation, required this.name});

  final ElementAnnotation annotation;
  final String name;
}

final class _HeldIn extends _Hold {
  _HeldIn({required this.queue});

  final VariableElement queue;

  String get name => queue.name ?? '?';
}

_Hold _holdOf(Element? member) {
  final element = member?.baseElement;
  if (element == null) return _Unheld();
  for (final annotation in element.metadata.annotations) {
    final constructor = annotation.element;
    if (constructor is! ConstructorElement) continue;
    final library = constructor.library;
    final queueClass = library.getClass('SerialQueue');
    if (constructor.enclosingElement.name != 'Held' || queueClass == null) {
      continue;
    }
    final name = annotation
        .computeConstantValue()
        ?.getField('queue')
        ?.toSymbolValue();
    if (name == null) return _Unheld();
    final owner = element.enclosingElement;
    final queue = switch (owner) {
      InterfaceElement() => owner.getField(name),
      LibraryElement() =>
        owner.topLevelVariables.where((v) => v.name == name).firstOrNull,
      _ => null,
    };
    final type = queue?.type;
    final isQueue =
        type is InterfaceType && identical(type.element, queueClass);
    return queue != null && isQueue
        ? _HeldIn(queue: queue)
        : _Unresolved(annotation: annotation, name: name);
  }
  return _Unheld();
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor({required this.rule});

  final MultiAnalysisRule rule;

  @override
  void visitMethodDeclaration(MethodDeclaration node) =>
      _checkDeclared(node, element: node.declaredFragment?.element);

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) =>
      _checkDeclared(node, element: node.declaredFragment?.element);

  void _checkDeclared(Declaration node, {required Element? element}) {
    if (_holdOf(element) case _Unresolved(:final name)) {
      final at = node.metadata.where(
        (a) => a.elementAnnotation != null && a.name.name == 'Held',
      );
      rule.reportAtNode(
        at.firstOrNull ?? node,
        diagnosticCode: HeldInTurn.unknown,
        arguments: [name],
      );
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final callee = node.methodName.element;
    if (_holdOf(callee) case _HeldIn hold) {
      final onThis = switch (node.target) {
        null || ThisExpression() => true,
        _ => hold.queue.isStatic,
      };
      if (!onThis || !_inTurn(node, hold: hold)) {
        _report(
          node.methodName,
          code: HeldInTurn.outside,
          callee: callee,
          hold: hold,
        );
      } else if (callee is ExecutableElement &&
          callee.returnType.isDartAsyncFuture &&
          !_kept(node)) {
        _report(
          node.methodName,
          code: HeldInTurn.dropped,
          callee: callee,
          hold: hold,
        );
      }
    }
  }

  /// A held member torn off: only as the task a queue's `run` or `enqueue`
  /// is handed.
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final parent = node.parent;
    if (parent is MethodInvocation && identical(parent.methodName, node)) {
      return;
    }
    if (node.thisOrAncestorOfType<CommentReference>() != null) return;
    final element = node.element;
    if (element is! ExecutableElement) return;
    if (_holdOf(element) case _HeldIn hold) {
      final list = parent is ArgumentList ? parent : null;
      final task = list?.parent;
      if (task is! MethodInvocation || !_isTaskOf(task, hold: hold)) {
        _report(node, code: HeldInTurn.outside, callee: element, hold: hold);
      }
    }
  }

  void _report(
    AstNode node, {
    required LintCode code,
    required Element? callee,
    required _HeldIn hold,
  }) => rule.reportAtNode(
    node,
    diagnosticCode: code,
    arguments: [callee?.name ?? '?', hold.name],
  );

  /// Whether the innermost function around [node] is [hold]'s turn: a closure
  /// handed to its queue's `run` or `enqueue`, or a member held in it.
  static bool _inTurn(AstNode node, {required _HeldIn hold}) {
    AstNode? at = node.parent;
    while (at != null && at is! FunctionBody) {
      at = at.parent;
    }
    final function = at?.parent;
    final declared = switch (function) {
      MethodDeclaration() => function.declaredFragment?.element,
      FunctionExpression(parent: final FunctionDeclaration d) =>
        d.declaredFragment?.element,
      _ => null,
    };
    if (declared != null) {
      return switch (_holdOf(declared)) {
        _HeldIn(:final queue) => identical(
          queue.baseElement,
          hold.queue.baseElement,
        ),
        _Unheld() || _Unresolved() => false,
      };
    }
    if (function is FunctionExpression) {
      final task = function.parent?.parent;
      return task is MethodInvocation && _isTaskOf(task, hold: hold);
    }
    return false;
  }

  /// Whether [invocation] is `queue.run(...)` or `queue.enqueue(...)` on
  /// [hold]'s queue, reached through `this` when the queue is a field of it.
  static bool _isTaskOf(MethodInvocation invocation, {required _HeldIn hold}) {
    final method = invocation.methodName.element;
    if (method is! MethodElement ||
        method.enclosingElement?.name != 'SerialQueue' ||
        !const {'run', 'enqueue'}.contains(method.name)) {
      return false;
    }
    final (target, onThis) = switch (invocation.target) {
      SimpleIdentifier(:final element) => (element, true),
      PropertyAccess(:final target, :final propertyName) => (
        propertyName.element,
        target is ThisExpression,
      ),
      PrefixedIdentifier(:final element) => (element, false),
      _ => (null, false),
    };
    final variable = target is PropertyAccessorElement ? target.variable : null;
    return variable != null &&
        identical(variable.baseElement, hold.queue.baseElement) &&
        (onThis || hold.queue.isStatic);
  }

  /// Whether the future [node] returns is awaited or handed back, so the turn
  /// that called it waits for it.
  static bool _kept(MethodInvocation node) => switch (node.parent) {
    AwaitExpression() || ReturnStatement() || ExpressionFunctionBody() => true,
    _ => false,
  };
}
