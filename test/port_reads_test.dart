// A port names the model's variables its uses read (`Port(reads:)`), and
// the printed footprint, the walks' read gate and the schedules' reduction
// take that declaration as true. Nothing at run time sees what a port's own
// code reads, so this resolves `lib` and follows each port's code: its `of:`
// closure and every member of the interface it hands a table, through every
// call into our code, each interface call to every implementation in `lib`.
// A field that holds one of the model's variables, read on the way, must be
// a variable the port declares. Rung 5: Dart has no read effects a type can
// state; a read token a port's code must hold, as a write needs a Commit,
// would lift it to the compiler.
//
// Where a variable lives is read off the code too: the backing fields a
// `Shared` or `SharedAt` cell reads and the fields that hold the cell, and
// the field a `Var` leaf's `read:` ends at. A variable only the platform
// holds (`Mutable.remote`, `Indexed.remote`) is reached only through a
// call, which its port declares; it has no field here.
//
// What runs after an await every path takes runs in a later turn, not the
// one that calls the port, so an asynchronous body is followed only up to
// it.
//
// Not followed: the step-table core (`step_table.dart` and its parts),
// whose reads of the model are leaves the runner notes as a step lands, so
// the walks' read gate holds them; a closure called through a function
// value, which no static call names; and code outside this package.

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:flutter_test/flutter_test.dart';

String _sdk() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) return '$root/bin/cache/dart-sdk';
  final at = Platform.resolvedExecutable.indexOf('/bin/cache/');
  return '${Platform.resolvedExecutable.substring(0, at)}/bin/cache/dart-sdk';
}

/// A port's code reading a variable it does not declare, with the calls
/// that reach the read.
typedef PortRead = ({String port, String variable, List<String> path});

/// Every port under [lib] whose code reads a variable it does not declare,
/// and the ports this cannot check, by why.
Future<({List<PortRead> undeclared, List<String> unchecked})> portReads({
  required AnalysisSession session,
  required List<String> files,
}) async {
  final units = <ResolvedUnitResult>[];
  for (final f in files) {
    final got = await session.getResolvedUnit(f);
    if (got case final ResolvedUnitResult u) {
      units.add(u);
    }
  }
  final storage = _Storage();
  for (final u in units) {
    u.unit.accept(storage);
  }
  final ports = _Ports();
  for (final u in units) {
    ports.path = u.path;
    u.unit.accept(ports);
  }
  final hierarchy = _Hierarchy([for (final u in units) u.libraryElement]);
  final undeclared = <PortRead>[];
  for (final port in ports.found) {
    final walk = _Walk(
      session: session,
      storage: storage.byField,
      hierarchy: hierarchy,
    );
    await walk.run(port);
    for (final MapEntry(key: variable, value: path) in walk.read.entries) {
      if (!port.reads.contains(variable)) {
        undeclared.add((port: port.at, variable: variable, path: path));
      }
    }
  }
  return (undeclared: undeclared, unchecked: ports.unchecked);
}

bool _ours(Element? e) =>
    e?.library?.uri.toString().startsWith('package:webspace/') ?? false;

bool _core(Element? e) {
  final uri = e?.library?.uri.toString();
  return uri == 'package:webspace/services/step_table.dart';
}

String? _modelVar(Expression e) => switch (e) {
  PrefixedIdentifier(
    prefix: SimpleIdentifier(name: 'ModelVar'),
    :final identifier,
  ) =>
    identifier.name,
  _ => null,
};

Element? _base(Element? e) => e?.baseElement;

/// The fields that hold each of the model's variables, as the code builds
/// its cells and leaves.
final class _Storage extends RecursiveAstVisitor<void> {
  final byField = <Element, String>{};

  void _fieldsIn(AstNode? node, {required String variable}) {
    node?.accept(_FieldReads((f) => byField[f] = variable));
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.constructorName.type.element?.name;
    final ctor = node.constructorName.name?.name;
    final args = node.argumentList.arguments;
    Expression? named(String n) => [
      for (final a in args)
        if (a is NamedExpression && a.name.label.name == n) a.expression,
    ].firstOrNull;
    final positional = [
      for (final a in args)
        if (a is! NamedExpression) a,
    ];
    switch ((type, ctor)) {
      case ('Shared', null) || ('SharedAt', null):
        if (positional.firstOrNull case final v? when _modelVar(v) != null) {
          _fieldsIn(named('read'), variable: _modelVar(v)!);
          _holder(node, variable: _modelVar(v)!);
        }
      case ('Var', null) || ('Mutable', null) || ('Indexed', null):
        if (positional.firstOrNull case final v? when _modelVar(v) != null) {
          if (named('read') case FunctionExpression(:final body)) {
            if (_last(body) case final f?) byField[f] = _modelVar(v)!;
          }
        }
    }
    super.visitInstanceCreationExpression(node);
  }

  /// `Shared.ofSet(set, variable:)`, a cell over a set of the code's.
  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'ofSet' && _core(node.methodName.element)) {
      final args = node.argumentList.arguments;
      final variable = [
        for (final a in args)
          if (a is NamedExpression && a.name.label.name == 'variable')
            ?_modelVar(a.expression),
      ].firstOrNull;
      if (variable != null) {
        _fieldsIn(args.firstOrNull, variable: variable);
        _holder(node, variable: variable);
      }
    }
    super.visitMethodInvocation(node);
  }

  /// The field the cell [node] is kept in: a field's initializer, or a
  /// constructor's argument for a field formal.
  void _holder(Expression node, {required String variable}) {
    switch (node.parent) {
      case VariableDeclaration(:final declaredFragment?):
        if (_base(declaredFragment.element) case final f?) {
          byField[f] = variable;
        }
      case NamedExpression(:final element?):
        if (element case FieldFormalParameterElement(:final field?)) {
          byField[_base(field)!] = variable;
        }
    }
  }

  /// The field a leaf's read ends at: the last property it reads of ours.
  Element? _last(FunctionBody body) {
    Expression? e = switch (body) {
      ExpressionFunctionBody(:final expression) => expression,
      _ => null,
    };
    while (e != null) {
      switch (e) {
        case PropertyAccess(:final propertyName, :final target):
          if (_held(propertyName.element) case final f?) return f;
          e = target;
        case PrefixedIdentifier(:final identifier, :final prefix):
          if (_held(identifier.element) case final f?) return f;
          e = prefix;
        case MethodInvocation(:final target):
          e = target;
        default:
          e = null;
      }
    }
    return null;
  }
}

/// The field [e] reads, unless it is the core's own accessor of a cell
/// (`Shared.value`), which is no storage of a variable.
Element? _held(Element? e) => _ours(e) && !_core(e) ? _variable(e) : null;

Element? _variable(Element? e) => switch (e) {
  GetterElement(:final variable) => _base(variable),
  FieldElement() => _base(e),
  _ => null,
};

/// Calls [found] with each field of ours read under the node it visits.
final class _FieldReads extends RecursiveAstVisitor<void> {
  _FieldReads(this.found);

  final void Function(Element field) found;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (!_ours(node.element)) return;
    if (_variable(node.element) case final f?) found(f);
  }
}

typedef _Port = ({
  String name,
  Set<String> reads,
  FunctionExpression of,
  String at,
});

/// The ports the code declares with a literal `reads:` and an `of:`
/// closure; the rest, by why they are not checked.
final class _Ports extends RecursiveAstVisitor<void> {
  final found = <_Port>[];
  final unchecked = <String>[];
  late String path;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (node.constructorName.type.element?.name == 'Port' &&
        _core(node.constructorName.type.element)) {
      final args = node.argumentList.arguments;
      final name = switch (args.firstOrNull) {
        SimpleStringLiteral(:final value) => value,
        _ => '?',
      };
      Expression? named(String n) => [
        for (final a in args)
          if (a is NamedExpression && a.name.label.name == n) a.expression,
      ].firstOrNull;
      final at = '${path.substring(Directory.current.path.length + 1)} $name';
      final reads = switch (named('reads')) {
        SetOrMapLiteral(:final elements) => {
          for (final e in elements)
            if (e is Expression) ?_modelVar(e),
        },
        _ => null,
      };
      if (reads == null) {
        unchecked.add('$at: reads is not a literal set');
      } else if (named('of') case final FunctionExpression of) {
        found.add((name: name, reads: reads, of: of, at: at));
      } else {
        unchecked.add('$at: of is not a closure');
      }
    }
    super.visitInstanceCreationExpression(node);
  }
}

/// Every class of ours, and the classes below each.
final class _Hierarchy {
  _Hierarchy(List<LibraryElement> libraries) {
    for (final l in {...libraries}) {
      for (final c in [...l.classes, ...l.mixins, ...l.enums]) {
        all.add(c);
      }
    }
  }

  final all = <InterfaceElement>[];

  /// [member] and every member of ours that overrides or implements it.
  Iterable<ExecutableElement> overrides(ExecutableElement member) sync* {
    yield member;
    final owner = member.enclosingElement;
    final name = member.name;
    if (owner is! InterfaceElement || name == null || member.isStatic) return;
    for (final c in all) {
      if (identical(c, owner)) continue;
      if (!c.allSupertypes.any((t) => identical(t.element, owner))) continue;
      final own = switch (member) {
        GetterElement() => c.getGetter(name),
        MethodElement() => c.getMethod(name),
        _ => null,
      };
      if (own != null && identical(own.enclosingElement, c)) yield own;
    }
  }
}

/// What a port's code reaches: the fields of the model's variables it reads,
/// each with the first calls that reach it.
final class _Walk {
  _Walk({
    required this.session,
    required this.storage,
    required this.hierarchy,
  });

  final AnalysisSession session;
  final Map<Element, String> storage;
  final _Hierarchy hierarchy;
  final read = <String, List<String>>{};
  final _seen = <Element>{};
  final _libraries = <LibraryElement, ResolvedLibraryResult?>{};

  Future<void> run(_Port port) async {
    final queue = <({AstNode node, List<String> path})>[
      (node: port.of, path: ['${port.name}.of']),
    ];
    final type = switch (port.of.staticType) {
      FunctionType(:final returnType) => returnType,
      _ => null,
    };
    if (type case InterfaceType(:final element) when _ours(element)) {
      for (final m in [...element.methods, ...element.getters]) {
        for (final o in hierarchy.overrides(m)) {
          if (await _node(o) case final n?) {
            queue.add((node: n, path: ['${element.name}.${o.name}']));
          }
        }
      }
    }
    while (queue.isNotEmpty) {
      final (:node, :path) = queue.removeLast();
      final calls = <ExecutableElement>[];
      node.accept(
        _Reach(
          field: (f) {
            if (storage[f] case final v? when !read.containsKey(v)) {
              read[v] = [...path, '${f.enclosingElement?.name}.${f.name}'];
            }
          },
          call: calls.add,
        ),
      );
      for (final c in calls) {
        for (final o in hierarchy.overrides(c)) {
          if (!_seen.add(o) || _core(o)) continue;
          if (await _node(o) case final n?) {
            queue.add((
              node: n,
              path: [...path, '${o.enclosingElement?.name}.${o.name}'],
            ));
          }
        }
      }
    }
  }

  Future<AstNode?> _node(ExecutableElement e) async {
    final library = e.library;
    if (!_ours(e)) return null;
    final result = _libraries[library] ??= switch (await session
        .getResolvedLibraryByElement(library)) {
      final ResolvedLibraryResult r => r,
      _ => null,
    };
    return result?.getFragmentDeclaration(e.firstFragment)?.node;
  }
}

/// Calls [field] with each field of ours read and [call] with each member of
/// ours called under the node it visits.
final class _Reach extends RecursiveAstVisitor<void> {
  _Reach({required this.field, required this.call});

  final void Function(Element field) field;
  final void Function(ExecutableElement member) call;

  void _element(Element? e) {
    if (!_ours(e)) return;
    if (_variable(e) case final f?) field(f);
    if (e case final ExecutableElement x
        when !(x is GetterElement && !x.isOriginDeclaration)) {
      call(_base(x)! as ExecutableElement);
    }
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    _element(node.element);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    for (final n in _syncPart(node.body)) {
      n.accept(this);
    }
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    for (final n in _syncPart(node.body)) {
      n.accept(this);
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _element(node.constructorName.element);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    _element(node.element);
    super.visitBinaryExpression(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    _element(node.element);
    super.visitIndexExpression(node);
  }
}

/// What of [body] runs in the turn that calls it: all of a synchronous
/// body; of an asynchronous one, its statements up to the first that awaits
/// on every path, whose continuation runs in a later turn.
List<AstNode> _syncPart(FunctionBody body) {
  if (!body.isAsynchronous || body.isGenerator) return [body];
  return switch (body) {
    BlockFunctionBody(:final block) => _untilAwait(block.statements),
    ExpressionFunctionBody(:final expression) => [expression],
    _ => const [],
  };
}

List<AstNode> _untilAwait(List<Statement> statements) {
  final out = <AstNode>[];
  for (final s in statements) {
    out.add(s);
    if (_ends(s)) break;
  }
  return out;
}

/// Whether nothing after [s] runs in the turn [s] starts in: it awaits on
/// every path, or leaves.
bool _ends(Statement s) => switch (s) {
  ReturnStatement() => true,
  ExpressionStatement(expression: ThrowExpression()) => true,
  ExpressionStatement(:final expression) => _awaits(expression),
  VariableDeclarationStatement(:final variables) => variables.variables.any(
    (v) => v.initializer != null && _awaits(v.initializer!),
  ),
  Block(:final statements) => statements.any(_ends),
  IfStatement(:final expression, :final thenStatement, :final elseStatement) =>
    _awaits(expression) ||
        (elseStatement != null && _ends(thenStatement) && _ends(elseStatement)),
  ForStatement(:final awaitKeyword?) => awaitKeyword.length > 0,
  _ => false,
};

/// Whether evaluating [e] awaits on every path through it.
bool _awaits(Expression e) {
  final straight = _Straight();
  e.accept(straight);
  return straight.found;
}

/// Finds an await evaluated on every path: not under a branch of a
/// conditional, the right of `&&`, `||` or `??`, a null-aware call's
/// arguments, or a closure.
final class _Straight extends RecursiveAstVisitor<void> {
  var found = false;

  @override
  void visitAwaitExpression(AwaitExpression node) => found = true;

  @override
  void visitFunctionExpression(FunctionExpression node) {}

  @override
  void visitConditionalExpression(ConditionalExpression node) =>
      node.condition.accept(this);

  @override
  void visitBinaryExpression(BinaryExpression node) {
    switch (node.operator.lexeme) {
      case '&&' || '||' || '??':
        node.leftOperand.accept(this);
      default:
        super.visitBinaryExpression(node);
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.isNullAware) {
      node.target?.accept(this);
    } else {
      super.visitMethodInvocation(node);
    }
  }

  @override
  void visitSwitchExpression(SwitchExpression node) =>
      node.expression.accept(this);
}

List<String> _dartFiles(String root) => [
  for (final f in Directory(root).listSync(recursive: true).whereType<File>())
    if (f.path.endsWith('.dart')) f.absolute.path,
];

/// The variables a port's code reads beyond what it declares, by port
/// (its file and name), each with what lifts it. Only shrinks: an entry the
/// gate no longer finds fails, as a new one does.
const _owed = <String, Set<String>>{
  // The tab table's calls back into the controller read the site's tabs,
  // its active tab, the site on screen and, as a tab activates its site,
  // the loaded sites, in the step's turn; a reroute's flips read the site
  // each tab runs as as they rewrite it. Lifted when the tab table reads
  // them through its leaves.
  'lib/controllers/tab_table.dart page': {
    'tabs',
    'active',
    'host',
    'current',
    'loaded',
  },
  // The activation's calls read the live target (marker, version), the
  // site on screen, and the loaded sites' slot identities off their active
  // tabs' hosts as the Tor pin syncs. Lifted the same way.
  'lib/controllers/activation_flow.dart page': {
    'marker',
    'version',
    'current',
    'loaded',
    'active',
    'tabs',
    'host',
  },
  // A stage lands and follows through the funnel (SiteRuntime.apply, the
  // archive's record of a closed site, the link tabs' reconcile), which
  // reads the screen, the version, the loaded sites and their tabs in the
  // stage's turn, each tab's host and opener among them as the record
  // writes the tabs. Lifted when those steps of the funnel are table steps
  // that read through leaves.
  'lib/controllers/archive_controller.dart drop': {
    'active',
    'tabs',
    'host',
    'link',
    'current',
    'version',
    'loaded',
  },
  'lib/controllers/site_deletion.dart drop': {
    'active',
    'tabs',
    'host',
    'link',
    'current',
    'version',
    'loaded',
  },
  'lib/controllers/archive_controller.dart frame': {
    'active',
    'tabs',
    'host',
    'link',
    'loaded',
  },
  'lib/controllers/site_deletion.dart frame': {
    'active',
    'tabs',
    'host',
    'link',
    'loaded',
  },
  // The delete's retire reads whether the site is loaded and takes the
  // jar's turn for its cookie cleanup, reading the turn's holder.
  'lib/controllers/site_deletion.dart retire': {'holder', 'loaded'},
  // The residency plan's capture begins on the outgoing tab, read off the
  // site's tabs and keyed by the site it runs as, and its unload notes the
  // background sites' counts over the loaded ones. Lifted by recording
  // them as the steps' start (Call.reads).
  'lib/services/site_unload_engine.dart plan': {'tabs', 'host', 'loaded'},
  // A snapshot asks the platform for the cookies of each site's current
  // URL, read off its active tab as the call is issued. Lifted by a
  // Call.reads field the model's snapshot reads.
  'lib/services/cookie_isolation.dart jar': {'active', 'tabs'},
};

/// The ports this gate cannot follow, each with why: a port built by a
/// helper whose callers pass its reads, or whose interface is a value
/// passed in. Only shrinks.
const _unchecked = {
  'lib/services/runtime_vars.dart vars: reads is not a literal set',
  'lib/services/dns_level_mask_engine.dart ?: of is not a closure',
  'lib/services/background_wake_engine.dart wake: of is not a closure',
};

/// A port each way the gate must judge: one that reads a variable it does
/// not declare, the same port declaring it, and a read after an await that
/// every path takes, which runs in a later turn.
const _probePath = 'lib/_port_reads_probe.dart';
const _probe = """
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/services/step_table.dart';

final class ProbeCalls {
  ProbeCalls(this._sites);
  final SiteRuntime _sites;
  int count() => _sites.loaded.length;
}

final class LaterCalls {
  LaterCalls(this._sites);
  final SiteRuntime _sites;
  Future<int> count() async {
    await Future<void>.value();
    return _sites.loaded.length;
  }
}

final class SoonerCalls {
  SoonerCalls(this._sites);
  final SiteRuntime _sites;
  Future<int> count() async {
    final n = _sites.loaded.length;
    await Future<void>.value();
    return n;
  }
}

final undeclared = Port<ProbeCalls, SiteRuntime>(
  'undeclared',
  reads: const {},
  changes: const {},
  of: (w) => ProbeCalls(w),
);

final declared = Port<ProbeCalls, SiteRuntime>(
  'declared',
  reads: {ModelVar.loaded},
  changes: const {},
  of: (w) => ProbeCalls(w),
);

final later = Port<LaterCalls, SiteRuntime>(
  'later',
  reads: const {},
  changes: const {},
  of: (w) => LaterCalls(w),
);

final sooner = Port<SoonerCalls, SiteRuntime>(
  'sooner',
  reads: const {},
  changes: const {},
  of: (w) => SoonerCalls(w),
);
""";

final Future<({List<PortRead> undeclared, List<String> unchecked})> _analysis =
    () async {
      final lib = Directory('lib').absolute.path;
      final probe = '${Directory.current.path}/$_probePath';
      final files = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE)
        ..setOverlay(probe, content: _probe, modificationStamp: 0);
      final contexts = AnalysisContextCollection(
        includedPaths: [lib],
        resourceProvider: files,
        sdkPath: _sdk(),
      );
      try {
        return await portReads(
          session: contexts.contextFor(lib).currentSession,
          files: [..._dartFiles(lib), probe],
        );
      } finally {
        await contexts.dispose();
      }
    }();

Map<String, Set<String>> _byPort(Iterable<PortRead> reads) {
  final out = <String, Set<String>>{};
  for (final r in reads) {
    (out[r.port] ??= {}).add(r.variable);
  }
  return out;
}

void main() {
  const timeout = Timeout(Duration(minutes: 10));

  test('a port\'s code reads only the variables the port declares', () async {
    final found = await _analysis;
    final real = [
      for (final r in found.undeclared)
        if (!r.port.startsWith(_probePath)) r,
    ];
    final paths = {
      for (final r in real) '${r.port} ${r.variable}': r.path.join(' > '),
    };
    final over = <String>[
      for (final MapEntry(key: port, value: vars) in _byPort(real).entries)
        for (final v in vars.difference(_owed[port] ?? const {}))
          '$port reads $v: ${paths['$port $v']}',
    ];
    expect(
      over,
      isEmpty,
      reason: 'declare the read in the port\'s reads:, or narrow its interface',
    );
    final stale = <String>[
      for (final MapEntry(key: port, value: vars) in _owed.entries)
        for (final v in vars.difference(_byPort(real)[port] ?? const {}))
          '$port $v',
    ];
    expect(
      stale,
      isEmpty,
      reason: 'the gate no longer finds these: drop them from _owed',
    );
  }, timeout: timeout);

  test('the gate follows every port but those it names', () async {
    expect((await _analysis).unchecked.toSet(), _unchecked);
  }, timeout: timeout);

  test('a planted port reading what it does not declare is caught', () async {
    final probes = _byPort([
      for (final r in (await _analysis).undeclared)
        if (r.port.startsWith(_probePath)) r,
    ]);
    expect(
      probes,
      {
        '$_probePath undeclared': {'loaded'},
        '$_probePath sooner': {'loaded'},
      },
      reason:
          'declared reads pass, and a read after an await every path takes '
          'runs in a later turn',
    );
  }, timeout: timeout);
}
