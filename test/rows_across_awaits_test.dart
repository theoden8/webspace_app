// BUG-029: a row of the site list names a site only until the next await,
// since any await lets a move, a delete or an import shift the list. Rung 5:
// Dart has no type for "an int valid until the next suspension", so the joins
// that cross awaits take the site itself (`SiteActivationController.activate`,
// the tab and editing operations) and this parses lib/ for an async function
// that reads a row past an await: an `int` parameter named as a row, or a
// local read from the site list (`models.indexOf`, `models.indexWhere`,
// `_sites.current`, `filteredIndices()`), used after an await that follows
// it. Resolve the site before the await and its row, when one is needed,
// after it.

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

final _rowName = RegExp(r'(^|[a-z])(index|row)$|^(index|row)', caseSensitive: false);
final _rowRead = RegExp(
    r'models\.index(Of|Where)\(|_sites\.current\b|filteredIndices\(\)');

class _Uses extends RecursiveAstVisitor<void> {
  _Uses(this.name);
  final String name;
  final uses = <int>[];
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.name == name) uses.add(node.offset);
  }
}

class _Awaits extends RecursiveAstVisitor<void> {
  final ends = <int>[];
  @override
  void visitAwaitExpression(AwaitExpression node) {
    ends.add(node.end);
    super.visitAwaitExpression(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    if (node.awaitKeyword != null) ends.add(node.forLoopParts.end);
    super.visitForStatement(node);
  }
}

class _Rows extends RecursiveAstVisitor<void> {
  _Rows({required this.path, required this.unit});
  final String path;
  final CompilationUnit unit;
  final found = <String>[];

  void _check(FunctionBody body, {required String fn}) {
    if (body is! BlockFunctionBody || !body.isAsynchronous) return;
    final awaits = (_Awaits()..visitBlockFunctionBody(body)).ends;
    if (awaits.isEmpty) return;
    void readPast(String name, {required int from}) {
      final after = awaits.where((a) => a > from).toList();
      if (after.isEmpty) return;
      final first = after.reduce((a, b) => a < b ? a : b);
      final uses = (_Uses(name)..visitBlockFunctionBody(body)).uses;
      final use = uses.where((u) => u > first).firstOrNull;
      if (use == null) return;
      final line = unit.lineInfo.getLocation(use).lineNumber;
      found.add('$path:$line $fn: $name is read past an await');
    }

    final params = switch (body.parent) {
      MethodDeclaration(:final parameters) => parameters,
      FunctionExpression(:final parameters) => parameters,
      _ => null,
    };
    for (final p in params?.parameters ?? const <FormalParameter>[]) {
      final simple = switch (p) {
        DefaultFormalParameter(:final parameter) => parameter,
        _ => p,
      };
      final name = simple.name?.lexeme;
      if (simple is! SimpleFormalParameter || name == null) continue;
      final type = simple.type?.toSource();
      if ((type == 'int' || type == 'int?') && _rowName.hasMatch(name)) {
        readPast(name, from: body.offset);
      }
    }
    body.accept(_Locals(readPast));
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _check(node.body, fn: node.name.lexeme);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    final parent = node.parent;
    _check(node.body,
        fn: parent is FunctionDeclaration ? parent.name.lexeme : '<closure>');
    super.visitFunctionExpression(node);
  }
}

/// Every local read from the site list.
class _Locals extends RecursiveAstVisitor<void> {
  _Locals(this.onRow);
  final void Function(String name, {required int from}) onRow;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final init = node.initializer;
    final name = node.name.lexeme;
    if (init != null &&
        _rowRead.hasMatch(init.toSource()) &&
        !init.toSource().contains('await ')) {
      onRow(name, from: node.end);
    }
    super.visitVariableDeclaration(node);
  }

  // A nested function is checked on its own.
  @override
  void visitFunctionExpression(FunctionExpression node) {}
}

void main() {
  test('no async function in lib reads a site row past an await (BUG-029)',
      () {
    final found = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.contains('/l10n/gen/')) continue;
      final unit = parseString(
              content: f.readAsStringSync(), throwIfDiagnostics: false)
          .unit;
      final rows = _Rows(path: f.path, unit: unit);
      unit.accept(rows);
      found.addAll(rows.found);
    }
    expect(found, isEmpty,
        reason: 'a row read before an await can name another site after '
            'it; hold the site instead:\n${found.join('\n')}');
  });
}
