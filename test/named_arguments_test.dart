// CLAUDE.md rule 2: a call names its arguments past the first, and never
// passes a bool positionally. Rung 5: no lint counts positional parameters
// (`avoid_positional_boolean_parameters` sees only public bools), so this
// parses every Dart source we own and checks each signature we declare.
//
// Exempt, because the signature is fixed from outside: overrides, operators,
// setters, `main`, closures (typed by the function type they are passed as),
// generated localizations, the function types given to `lookupFunction`,
// `asFunction` or `NativeFunction` (their shape is the C ABI's), and the
// declarations in `_fixedFromOutside`, torn off as a callback we do not own.

import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

const _roots = ['lib', 'test', 'integration_test', 'test_driver', 'tool'];

/// Declarations torn off as a callback whose type is not ours, which fixes
/// their shape. Each names that type.
const _fixedFromOutside = {
  'lib/screens/webspace_page.dart _onSystemUiChange': 'SystemUiChangeCallback',
  'lib/services/block_stats_detail.dart _byCountThenRecency': 'List.sort',
  'lib/widgets/external_tor_tiles.dart _setSwitch': 'ValueChanged<bool>',
  'test/settings_backup_compat_test.dart _compareTags': 'List.sort',
};

void main() {
  test('every signature takes at most one positional parameter, never a bool',
      () {
    final violations = <String>[];
    final exempted = <String>{};
    for (final root in _roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final file in dir.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart') || file.path.contains('l10n/gen/')) {
          continue;
        }
        final parsed = parseFile(
          path: file.absolute.path,
          featureSet: FeatureSet.latestLanguageVersion(),
        );
        final native = _NativeBindings();
        parsed.unit.accept(native);
        parsed.unit.accept(_Signatures(
          path: file.path,
          lines: parsed.lineInfo,
          native: native,
          violations: violations,
          exempted: exempted,
        ));
      }
    }
    final stale = _fixedFromOutside.keys.toSet().difference(exempted);
    expect(stale, isEmpty,
        reason: 'These exemptions no longer match a positional signature; '
            'drop them from _fixedFromOutside.');
    if (violations.isNotEmpty) {
      fail('Make every parameter past the first named (`required` where it '
          'has no default), and a bool named even when it is the first:\n'
          '${violations.join('\n')}');
    }
  });
}

class _Signatures extends RecursiveAstVisitor<void> {
  _Signatures({
    required this.path,
    required this.lines,
    required this.native,
    required this.violations,
    required this.exempted,
  });

  final String path;
  final LineInfo lines;
  final _NativeBindings native;
  final List<String> violations;
  final Set<String> exempted;

  void _check(String name, {required FormalParameterList? parameters}) {
    if (parameters == null) return;
    final positional =
        parameters.parameters.where((p) => p.isPositional).toList();
    final bools = positional.where(_isBool).toList();
    if (positional.length < 2 && bools.isEmpty) return;
    if (_fixedFromOutside.containsKey('$path $name')) {
      exempted.add('$path $name');
      return;
    }
    final line = lines.getLocation(parameters.offset).lineNumber;
    final why = bools.isNotEmpty
        ? 'positional bool ${bools.map((p) => p.name?.lexeme).join(', ')}'
        : '${positional.length} positional parameters';
    violations.add('$path:$line $name: $why');
  }

  static bool _isBool(FormalParameter p) {
    final inner = p is DefaultFormalParameter ? p.parameter : p;
    final type = switch (inner) {
      SimpleFormalParameter(:final type) => type,
      FieldFormalParameter(:final type) => type,
      SuperFormalParameter(:final type) => type,
      _ => null,
    };
    return type is NamedType && type.name.lexeme == 'bool';
  }

  static bool _overrides(NodeList<Annotation> metadata) =>
      metadata.any((a) => a.name.name == 'override');

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final topLevelMain =
        node.parent is CompilationUnit && node.name.lexeme == 'main';
    if (!topLevelMain) {
      _check(node.name.lexeme,
          parameters: node.functionExpression.parameters);
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (!_overrides(node.metadata) && !node.isOperator && !node.isSetter) {
      _check(node.name.lexeme, parameters: node.parameters);
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    final owner = node.typeName?.name ?? '?';
    final named = node.name?.lexeme;
    _check(named == null ? owner : '$owner.$named',
        parameters: node.parameters);
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitGenericFunctionType(GenericFunctionType node) {
    if (!native.binds(node)) {
      _check('Function type', parameters: node.parameters);
    }
    super.visitGenericFunctionType(node);
  }

  @override
  void visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) {
    _check('${node.name.lexeme} (function-typed parameter)',
        parameters: node.parameters);
    super.visitFunctionTypedFormalParameter(node);
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    _check(node.name.lexeme, parameters: node.parameters);
    super.visitFunctionTypeAlias(node);
  }
}

/// The function types a file hands to dart:ffi, inline or through a typedef.
class _NativeBindings extends RecursiveAstVisitor<void> {
  static const _binders = {'lookupFunction', 'asFunction', 'NativeFunction'};

  final _types = <GenericFunctionType>{};
  final _aliases = <String>{};

  bool binds(GenericFunctionType type) {
    final alias = type.parent;
    return _types.contains(type) ||
        (alias is GenericTypeAlias && _aliases.contains(alias.name.lexeme));
  }

  void _collect(TypeArgumentList? arguments) {
    for (final argument in arguments?.arguments ?? const <TypeAnnotation>[]) {
      switch (argument) {
        case GenericFunctionType():
          _types.add(argument);
        case NamedType(:final name):
          _aliases.add(name.lexeme);
        default:
          break;
      }
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_binders.contains(node.methodName.name)) _collect(node.typeArguments);
    super.visitMethodInvocation(node);
  }

  @override
  void visitNamedType(NamedType node) {
    if (_binders.contains(node.name.lexeme)) _collect(node.typeArguments);
    super.visitNamedType(node);
  }
}
