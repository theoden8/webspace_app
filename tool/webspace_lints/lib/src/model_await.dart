import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

/// Code that acts after an await on what it read of the model's state
/// before it, and writes that state, takes a timing no step table takes,
/// which TLC does not check. A step of a table splits there, so the model
/// holds the read to the await and the write to the reply.
///
/// The state is read through a [Shared] cell's `value` or a getter marked
/// `@Modeled`, and written by a call handed a `Commit`, which every write of
/// it takes, or by `commitInput`. A read is held across an await when its
/// value is in a local the code reads after it, or when it decides the
/// branch or loop the await and the write run in; a branch that returns
/// keeps it deciding the rest of the block. A read of the state after the
/// await, before the write, ends the hold. Each path through a body is
/// followed alone, and each body alone: a write reached through a callee is
/// not seen, nor a held value handed to one; the walks' frame check still
/// holds those.
class ModelAwait extends AnalysisRule {
  static const code = LintCode(
    'model_await',
    "'{0}' is read before this await and '{1}' written after it, with no "
        'read between: a timing no step of the model takes.',
    correctionMessage:
        'Make the stretch a step of a table, read the state again after the '
        'await, or list the debt in test/js/lint_ignores.test.js.',
    severity: DiagnosticSeverity.ERROR,
  );

  ModelAwait()
    : super(
        name: 'model_await',
        description:
            "A read of the model's state is not held across an await to a "
            'write of it outside a step table.',
      );

  @override
  DiagnosticCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    if (!context.isInLibDir) return;
    registry.addBlockFunctionBody(this, _Visitor(rule: this));
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor({required this.rule});

  final AnalysisRule rule;

  @override
  void visitBlockFunctionBody(BlockFunctionBody node) {
    if (!node.isAsynchronous) return;
    _Walk(rule: rule).statement(node.block, paths: {const _Path([])});
  }
}

/// What a body does that the rule follows, in the order it runs.
sealed class _Event {}

final class _Read extends _Event {
  _Read({required this.what});

  final String what;
}

/// A local read, which may hold a value read from the state.
final class _Use extends _Event {
  _Use({required this.local});

  final Element local;
}

final class _Await extends _Event {
  _Await({required this.node});

  final AstNode node;
}

final class _Write extends _Event {
  _Write({required this.what});

  final String what;
}

/// A local taking a value: read from the state when [read] is set, or from
/// [from], the locals its value was made of.
final class _Bind extends _Event {
  _Bind({required this.local, required this.read, required this.from});

  final Element local;
  final _Read? read;
  final Set<Element> from;
}

/// A value read from the state that the code still acts on: in [local], or
/// as what decided the branch or loop [decision] it runs in. [crossed] is the
/// first await since the read, and [used] whether the local was read after
/// it.
final class _Hold {
  const _Hold({
    required this.read,
    this.local,
    this.decision,
    this.crossed,
    this.used = false,
  });

  final _Read read;
  final Element? local;
  final AstNode? decision;
  final _Await? crossed;
  final bool used;

  /// Whether code after [crossed] acts on the read.
  bool get acted => decision != null || used;

  _Hold copy({_Await? crossed, required bool used}) => _Hold(
    read: read,
    local: local,
    decision: decision,
    crossed: crossed,
    used: used,
  );

  @override
  bool operator ==(Object other) =>
      other is _Hold &&
      identical(other.read, read) &&
      other.local == local &&
      identical(other.decision, decision) &&
      identical(other.crossed, crossed) &&
      other.used == used;

  @override
  int get hashCode => Object.hash(read, local, decision, crossed, used);
}

/// The holds on one path through a body.
final class _Path {
  const _Path(this.holds);

  final List<_Hold> holds;

  _Path where(bool Function(_Hold) keep) => _Path([...holds.where(keep)]);

  @override
  bool operator ==(Object other) =>
      other is _Path &&
      other.holds.length == holds.length &&
      [
        for (var i = 0; i < holds.length; i++) i,
      ].every((i) => other.holds[i] == holds[i]);

  @override
  int get hashCode => Object.hashAll(holds);
}

/// Where a `break` or a `continue` takes the paths that reach it.
final class _Frame {
  _Frame({required this.loop});

  final bool loop;
  final Set<_Path> breaks = {};
  final Set<_Path> continues = {};
}

/// One body's paths, statement by statement. A loop's body is followed
/// twice, so a hold one pass leaves reaches the next.
class _Walk {
  _Walk({required this.rule});

  final AnalysisRule rule;
  final Set<AstNode> _reported = {};
  final List<_Frame> _frames = [];

  /// The paths after each await of the try bodies being walked, where a
  /// catch can take them.
  final List<Set<_Path>> _tries = [];

  /// The paths that go on past [node], from those that reach it.
  Set<_Path> statement(Statement node, {required Set<_Path> paths}) {
    if (paths.isEmpty) return paths;
    switch (node) {
      case Block(:final statements):
        var at = paths;
        for (final s in statements) {
          at = statement(s, paths: at);
        }
        return at;
      case ReturnStatement(:final expression):
        _run([expression], paths: paths);
        return {};
      case ExpressionStatement(
        expression: final e && (ThrowExpression() || RethrowExpression()),
      ):
        _run([e], paths: paths);
        return {};
      case IfStatement(:final elseStatement):
        final decided = _decide(
          [node.expression, node.caseClause],
          paths: paths,
          decision: node,
        );
        return _leave(
          node,
          branches: [
            statement(node.thenStatement, paths: decided),
            if (elseStatement != null)
              statement(elseStatement, paths: decided)
            else
              decided,
          ],
        );
      case SwitchStatement(:final members):
        final decided = _decide(
          [node.expression],
          paths: paths,
          decision: node,
        );
        final frame = _Frame(loop: false);
        _frames.add(frame);
        final branches = <Set<_Path>>[];
        for (final member in members) {
          if (member.statements.isEmpty) continue;
          var at = decided;
          if (member case SwitchPatternCase(:final guardedPattern)) {
            at = _run([guardedPattern.whenClause], paths: at);
          }
          for (final s in member.statements) {
            at = statement(s, paths: at);
          }
          branches.add(at);
        }
        _frames.removeLast();
        if (!members.any((m) => m is SwitchDefault)) branches.add(decided);
        branches.add(frame.breaks);
        return _leave(node, branches: branches);
      case ForStatement(:final forLoopParts, :final body):
        return _for(node, parts: forLoopParts, body: body, paths: paths);
      case WhileStatement(:final condition, :final body):
        final frame = _Frame(loop: true);
        _frames.add(frame);
        final out = <_Path>{};
        var top = paths;
        for (var pass = 0; pass < 2; pass++) {
          final checked = _decide([condition], paths: top, decision: node);
          out.addAll(checked);
          top = {...statement(body, paths: checked), ...frame.continues};
        }
        _frames.removeLast();
        return _strip(node, paths: {...out, ...frame.breaks});
      case DoStatement(:final condition, :final body):
        final frame = _Frame(loop: true);
        _frames.add(frame);
        final out = <_Path>{};
        var top = paths;
        for (var pass = 0; pass < 2; pass++) {
          top = _run(
            [condition],
            paths: {
              ...statement(body, paths: top),
              ...frame.continues,
            },
          );
          out.addAll(top);
        }
        _frames.removeLast();
        return {...out, ...frame.breaks};
      case TryStatement(:final catchClauses, :final finallyBlock):
        final atAwaits = <_Path>{};
        _tries.add(atAwaits);
        final done = statement(node.body, paths: paths);
        _tries.removeLast();
        final failed = {...paths, ...atAwaits, ...done};
        var out = {
          ...done,
          for (final c in catchClauses) ...statement(c.body, paths: failed),
        };
        if (finallyBlock != null) out = statement(finallyBlock, paths: out);
        return out;
      case BreakStatement():
        if (_frames.isNotEmpty) _frames.last.breaks.addAll(paths);
        return {};
      case ContinueStatement():
        for (final frame in _frames.reversed) {
          if (!frame.loop) continue;
          frame.continues.addAll(paths);
          break;
        }
        return {};
      case LabeledStatement(statement: final inner):
        return statement(inner, paths: paths);
      case FunctionDeclarationStatement():
        return paths;
      default:
        // The rest hold no statement: what runs in them is their events.
        return _run([node], paths: paths);
    }
  }

  Set<_Path> _for(
    ForStatement node, {
    required ForLoopParts parts,
    required Statement body,
    required Set<_Path> paths,
  }) {
    final frame = _Frame(loop: true);
    _frames.add(frame);
    final out = <_Path>{};
    if (parts is ForEachParts) {
      // Each element was in the iterable as the loop read it.
      final decided = _decide([parts.iterable], paths: paths, decision: node);
      final next = node.awaitKeyword == null ? null : _Await(node: node);
      Set<_Path> fetch(Set<_Path> at) =>
          next == null ? at : _apply([next], paths: at);
      var top = decided;
      out.addAll(top);
      for (var pass = 0; pass < 2; pass++) {
        top = {...statement(body, paths: fetch(top)), ...frame.continues};
        out.addAll(top);
      }
      _frames.removeLast();
      return _strip(node, paths: {...fetch(out), ...frame.breaks});
    }
    final start = switch (parts) {
      ForPartsWithDeclarations(:final variables) => variables,
      ForPartsWithExpression(:final initialization) => initialization,
      ForPartsWithPattern(:final variables) => variables,
      _ => null,
    };
    final (condition, updaters) = parts is ForParts
        ? (parts.condition, parts.updaters)
        : (null, const <Expression>[]);
    var top = _run([start], paths: paths);
    for (var pass = 0; pass < 2; pass++) {
      final checked = _decide([condition], paths: top, decision: node);
      out.addAll(checked);
      top = _run(
        updaters,
        paths: {
          ...statement(body, paths: checked),
          ...frame.continues,
        },
      );
    }
    _frames.removeLast();
    return _strip(node, paths: {...out, ...frame.breaks});
  }

  /// The paths after [nodes] run, each of [nodes] in turn.
  Set<_Path> _run(List<AstNode?> nodes, {required Set<_Path> paths}) =>
      _apply(_eventsOf(nodes), paths: paths);

  Set<_Path> _apply(List<_Event> events, {required Set<_Path> paths}) => {
    for (final path in paths)
      events.fold(path, (at, event) => _step(at, event: event)),
  };

  /// The paths after [nodes] run and decide [decision]: from the first read
  /// of the state among them, or of a local holding one, it holds there.
  Set<_Path> _decide(
    List<AstNode?> nodes, {
    required Set<_Path> paths,
    required AstNode decision,
  }) {
    final events = _eventsOf(nodes);
    return {
      for (final path in paths)
        () {
          var at = path.where((h) => !identical(h.decision, decision));
          var decided = false;
          for (final event in events) {
            final read = decided
                ? null
                : switch (event) {
                    _Read() => event,
                    _Use(:final local) => _heldIn(at, local: local),
                    _ => null,
                  };
            at = _step(at, event: event);
            if (read != null) {
              at = _Path([...at.holds, _Hold(read: read, decision: decision)]);
              decided = true;
            }
          }
          return at;
        }(),
    };
  }

  /// The paths going on past [node] from its [branches]: what decided it
  /// still decides them where only one branch goes on.
  Set<_Path> _leave(AstNode node, {required List<Set<_Path>> branches}) {
    final on = {for (final b in branches) ...b};
    return branches.where((b) => b.isNotEmpty).length > 1
        ? _strip(node, paths: on)
        : on;
  }

  Set<_Path> _strip(AstNode node, {required Set<_Path> paths}) => {
    for (final path in paths) path.where((h) => !identical(h.decision, node)),
  };

  _Path _step(_Path path, {required _Event event}) {
    switch (event) {
      case _Read():
        return _Path([
          for (final h in path.holds) h.copy(crossed: null, used: false),
        ]);
      case _Use(:final local):
        return _Path([
          for (final h in path.holds)
            h.local == local && h.crossed != null
                ? h.copy(crossed: h.crossed, used: true)
                : h,
        ]);
      case _Await():
        final after = _Path([
          for (final h in path.holds)
            h.crossed == null ? h.copy(crossed: event, used: false) : h,
        ]);
        for (final at in _tries) {
          at.add(after);
        }
        return after;
      case _Write():
        return _Path([
          for (final h in path.holds)
            if (h.crossed case final crossed? when h.acted)
              _report(h, at: crossed, write: event)
            else
              h,
        ]);
      case _Bind(:final local, :final read, :final from):
        final source =
            read ??
            from.map((l) => _heldIn(path, local: l)).nonNulls.firstOrNull;
        return _Path([
          ...path.holds.where((h) => h.local != local),
          if (source != null) _Hold(read: source, local: local),
        ]);
    }
  }

  _Hold _report(_Hold hold, {required _Await at, required _Write write}) {
    if (_reported.add(at.node)) {
      rule.reportAtNode(at.node, arguments: [hold.read.what, write.what]);
    }
    return hold.copy(crossed: null, used: false);
  }

  static _Read? _heldIn(_Path path, {required Element local}) =>
      path.holds.where((h) => h.local == local).firstOrNull?.read;

  static List<_Event> _eventsOf(List<AstNode?> nodes) {
    final events = _Events();
    for (final node in nodes) {
      node?.accept(events);
    }
    return events.events;
  }
}

/// A node's reads, uses, awaits, binds and writes, in the order they run:
/// a call or an await once its operands have, a read where it is. A closure
/// is its own body, but a local it captures is used where it is made.
class _Events extends RecursiveAstVisitor<void> {
  final List<_Event> events = [];
  var _closures = 0;

  @override
  void visitFunctionExpression(FunctionExpression node) {
    _closures++;
    super.visitFunctionExpression(node);
    _closures--;
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    super.visitAwaitExpression(node);
    if (_closures == 0) events.add(_Await(node: node));
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final element = node.element;
    if (_reads(element)) {
      if (_closures == 0) events.add(_Read(what: _source(node)));
    } else if (element is LocalVariableElement ||
        element is FormalParameterElement) {
      events.add(_Use(local: element!));
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final start = events.length;
    super.visitVariableDeclaration(node);
    final local = node.declaredFragment?.element;
    if (_closures == 0 &&
        local is LocalVariableElement &&
        node.initializer != null) {
      events.add(_bind(local, made: events.sublist(start)));
    }
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final start = events.length;
    super.visitAssignmentExpression(node);
    final local = node.writeElement;
    if (_closures == 0 &&
        (local is LocalVariableElement || local is FormalParameterElement)) {
      events.add(_bind(local!, made: events.sublist(start)));
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);
    if (_closures == 0 &&
        _writes(node.methodName.element, arguments: node.argumentList)) {
      events.add(_Write(what: node.methodName.name));
    }
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    super.visitFunctionExpressionInvocation(node);
    if (_closures == 0 && _writes(node.element, arguments: node.argumentList)) {
      events.add(_Write(what: node.function.toSource()));
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    super.visitInstanceCreationExpression(node);
    if (_closures == 0 &&
        _writes(node.constructorName.element, arguments: node.argumentList)) {
      events.add(_Write(what: node.constructorName.toSource()));
    }
  }

  static _Bind _bind(Element local, {required List<_Event> made}) => _Bind(
    local: local,
    read: made.whereType<_Read>().firstOrNull,
    from: {for (final use in made.whereType<_Use>()) use.local},
  );

  /// The expression a read names: the identifier with what it is read from.
  static String _source(SimpleIdentifier node) => switch (node.parent) {
    PrefixedIdentifier p => p.toSource(),
    PropertyAccess p when identical(p.propertyName, node) => p.toSource(),
    _ => node.name,
  };
}

/// Whether [element] reads the model's state: a [Shared] cell's `value`, or
/// a getter marked `@Modeled`.
bool _reads(Element? element) {
  if (element is! GetterElement) return false;
  final owner = element.enclosingElement;
  if (owner is ClassElement &&
      owner.name == 'Shared' &&
      element.name == 'value' &&
      _isStepTable(owner.library)) {
    return true;
  }
  return [element, element.variable].any(
    (declared) => declared.metadata.annotations.any((a) {
      final constructor = a.element;
      return constructor is ConstructorElement &&
          constructor.enclosingElement.name == 'Modeled';
    }),
  );
}

/// Whether a call of [callee] with [arguments] writes the model's state:
/// it is handed a `Commit`, or it is `commitInput`.
bool _writes(Element? callee, {required ArgumentList arguments}) {
  if (callee is TopLevelFunctionElement &&
      callee.name == 'commitInput' &&
      _isStepTable(callee.library)) {
    return true;
  }
  for (final argument in arguments.arguments) {
    final type = argument.argumentExpression.staticType;
    if (type is InterfaceType &&
        type.element.name == 'Commit' &&
        _isStepTable(type.element.library)) {
      return true;
    }
  }
  return false;
}

/// The library that declares the model's cells and the turn that writes
/// them (`lib/services/step_table.dart`), known by declaring both.
bool _isStepTable(LibraryElement library) =>
    library.getClass('Shared') != null && library.getClass('Commit') != null;
