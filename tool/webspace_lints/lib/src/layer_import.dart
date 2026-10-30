import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

/// The layers of `lib/`, lowest first (CLAUDE.md, Coding principles, rule 4).
enum Layer {
  platform('platform'),
  value('values'),
  service('services'),
  model('model'),
  ui('UI');

  const Layer(this.label);

  /// Its name in CLAUDE.md's map.
  final String label;

  /// The layer of the file at [path] under `lib/`; null where none is named,
  /// which [LayerImport] reports, so a new directory is placed before its
  /// imports go unchecked.
  static Layer? of(String path) => switch (path.split('/')) {
    [
      'screens' ||
          'widgets' ||
          'controllers' ||
          'theme' ||
          'design_gallery' ||
          'design_app',
      _,
      ...,
    ] ||
    ['main.dart' || 'app.dart'] => ui,
    // The model's parts are named after it; these three build models.
    ['demo_data.dart' || 'diag_seed.dart' || 'settings_import_engine.dart'] =>
      model,
    [final file] when file.startsWith('web_view_model') => model,
    ['services' || 'third_party', _, ...] => service,
    // A Webspace is a persisted value (id, name, siteIds).
    ['settings' || 'utils' || 'l10n', _, ...] ||
    ['webspace_model.dart'] => value,
    ['platform', _, ...] => platform,
    _ => null,
  };
}

/// CLAUDE.md rule 4: a file in `lib/` imports or exports its own layer or a
/// lower one. A directive's target is its URI resolved against the library's
/// own, so a relative import and each URI of a conditional one are held as a
/// package import is.
class LayerImport extends MultiAnalysisRule {
  static const upward = LintCode(
    'layer_import',
    "'{0}' is in the {1} layer, above this file's {2} layer.",
    correctionMessage:
        'Import this layer or a lower one, passing what is needed down as a '
        'narrow type; an edge still owed carries an ignore listed in '
        'test/js/lint_ignores.test.js.',
    severity: DiagnosticSeverity.ERROR,
  );

  static const unplaced = LintCode(
    'layer_unplaced',
    "No layer is named for '{0}', so its imports go unchecked.",
    correctionMessage: 'Name its layer in Layer.of.',
    severity: DiagnosticSeverity.ERROR,
  );

  LayerImport()
    : super(
        name: 'layer_import',
        description: 'A file imports its own layer or a lower one.',
      );

  @override
  List<DiagnosticCode> get diagnosticCodes => [upward, unplaced];

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    if (!context.isInLibDir) return;
    final library = context.libraryElement?.uri;
    if (library == null || library.scheme != 'package') return;
    if (library.pathSegments case [final package, ...final path]) {
      final visitor = _Visitor(
        rule: this,
        library: library,
        package: package,
        path: path.join('/'),
      );
      registry
        ..addCompilationUnit(this, visitor)
        ..addImportDirective(this, visitor)
        ..addExportDirective(this, visitor);
    }
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor({
    required this.rule,
    required this.library,
    required this.package,
    required this.path,
  }) : layer = Layer.of(path);

  final LayerImport rule;
  final Uri library;
  final String package;
  final String path;
  final Layer? layer;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    if (layer != null) return;
    rule.reportAtOffset(
      0,
      0,
      diagnosticCode: LayerImport.unplaced,
      arguments: [path],
    );
  }

  @override
  void visitImportDirective(ImportDirective node) => _check(node);

  @override
  void visitExportDirective(ExportDirective node) => _check(node);

  void _check(NamespaceDirective node) {
    final from = layer;
    if (from == null) return;
    for (final uri in [node.uri, for (final c in node.configurations) c.uri]) {
      final target = _inPackage(uri.stringValue);
      if (target == null) continue;
      final to = Layer.of(target);
      if (to != null && to.index > from.index) {
        rule.reportAtNode(
          uri,
          diagnosticCode: LayerImport.upward,
          arguments: [target, to.label, from.label],
        );
      }
    }
  }

  /// [uri]'s path under this package's `lib/`, or null outside it.
  String? _inPackage(String? uri) {
    if (uri == null) return null;
    final resolved = library.resolve(uri);
    if (resolved.scheme != 'package') return null;
    return switch (resolved.pathSegments) {
      [final p, ...final rest] when p == package => rest.join('/'),
      _ => null,
    };
  }
}
