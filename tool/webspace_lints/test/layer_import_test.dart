import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'package:webspace_lints/src/layer_import.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(LayerImportTest);
  });
  test('each place in lib/ has the layer CLAUDE.md names', () {
    expect(
      {
        for (final path in [
          'screens/a.dart',
          'widgets/a.dart',
          'controllers/a.dart',
          'theme/a.dart',
          'design_gallery/a.dart',
          'design_app/a.dart',
          'main.dart',
          'app.dart',
          'web_view_model.dart',
          'web_view_model_search.dart',
          'demo_data.dart',
          'diag_seed.dart',
          'settings_import_engine.dart',
          'services/a.dart',
          'third_party/favicon/a.dart',
          'settings/a.dart',
          'utils/a.dart',
          'l10n/gen/a.dart',
          'webspace_model.dart',
          'platform/a.dart',
          'misc/a.dart',
          'services.dart',
          'web.dart',
        ])
          path: Layer.of(path),
      },
      {
        'screens/a.dart': Layer.ui,
        'widgets/a.dart': Layer.ui,
        'controllers/a.dart': Layer.ui,
        'theme/a.dart': Layer.ui,
        'design_gallery/a.dart': Layer.ui,
        'design_app/a.dart': Layer.ui,
        'main.dart': Layer.ui,
        'app.dart': Layer.ui,
        'web_view_model.dart': Layer.model,
        'web_view_model_search.dart': Layer.model,
        'demo_data.dart': Layer.model,
        'diag_seed.dart': Layer.model,
        'settings_import_engine.dart': Layer.model,
        'services/a.dart': Layer.service,
        'third_party/favicon/a.dart': Layer.service,
        'settings/a.dart': Layer.value,
        'utils/a.dart': Layer.value,
        'l10n/gen/a.dart': Layer.value,
        'webspace_model.dart': Layer.value,
        'platform/a.dart': Layer.platform,
        'misc/a.dart': null,
        'services.dart': null,
        'web.dart': null,
      },
    );
  });
}

@reflectiveTest
class LayerImportTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = LayerImport();
    super.setUp();
    for (final (path, name) in [
      ('web_view_model.dart', 'Model'),
      ('web_view_model_search.dart', 'Search'),
      ('screens/page.dart', 'Page'),
      ('services/engine.dart', 'Engine'),
      ('services/engine_io.dart', 'EngineIo'),
      ('settings/pref.dart', 'Pref'),
      ('platform/host.dart', 'Host'),
    ]) {
      newFile('$testPackageLibPath/$path', 'class $name {}');
    }
  }

  /// The file at [path] under `lib/`, its directives [directives] and a use
  /// of each class they import ([uses]), so no import goes unused.
  String _file(String path, {required String directives, String uses = ''}) {
    final file = '$testPackageLibPath/$path';
    newFile(file, '$directives\n$uses\n');
    return file;
  }

  /// That [directives] in a file at [path] are reported where `/*here*/`
  /// marks, as importing [target] from [from] up into [to].
  Future<void> _caught(
    String path, {
    required String directives,
    String uses = '',
    required String target,
    required String to,
    required String from,
  }) async {
    final source = '$directives\n$uses\n';
    final at = source.indexOf('/*here*/') + '/*here*/'.length;
    final length = source.indexOf('/*end*/') - at;
    await assertDiagnosticsInFile(
      _file(path, directives: directives, uses: uses),
      [
        lint(
          at,
          length,
          messageContainsAll: [
            "'$target' is in the $to layer, above this file's $from layer",
          ],
        ),
      ],
    );
  }

  Future<void> test_a_service_importing_the_model() => _caught(
    'services/import.dart',
    directives: "import /*here*/'package:test/web_view_model.dart'/*end*/;",
    uses: 'Model? m;',
    target: 'web_view_model.dart',
    to: 'model',
    from: 'services',
  );

  Future<void> test_a_relative_import_is_resolved() => _caught(
    'services/relative.dart',
    directives: "import /*here*/'../web_view_model.dart'/*end*/;",
    uses: 'Model? m;',
    target: 'web_view_model.dart',
    to: 'model',
    from: 'services',
  );

  Future<void> test_a_part_of_the_model_is_the_model() => _caught(
    'services/search.dart',
    directives: "import /*here*/'../web_view_model_search.dart'/*end*/;",
    uses: 'Search? s;',
    target: 'web_view_model_search.dart',
    to: 'model',
    from: 'services',
  );

  Future<void> test_each_uri_of_a_conditional_export() => _caught(
    'services/conditional.dart',
    directives:
        "export 'engine.dart' "
        "if (dart.library.io) /*here*/'../screens/page.dart'/*end*/;",
    target: 'screens/page.dart',
    to: 'UI',
    from: 'services',
  );

  Future<void> test_a_value_importing_a_service() => _caught(
    'settings/up.dart',
    directives: "import /*here*/'../services/engine.dart'/*end*/;",
    uses: 'Engine? e;',
    target: 'services/engine.dart',
    to: 'services',
    from: 'values',
  );

  Future<void> test_the_platform_importing_a_value() => _caught(
    'platform/up.dart',
    directives: "import /*here*/'package:test/settings/pref.dart'/*end*/;",
    uses: 'Pref? p;',
    target: 'settings/pref.dart',
    to: 'values',
    from: 'platform',
  );

  Future<void> test_down_and_across_are_allowed() async {
    await assertNoDiagnosticsInFile(
      _file(
        'screens/down.dart',
        directives:
            "import 'dart:async';\n"
            "import 'package:test/web_view_model.dart';\n"
            "import '../services/engine.dart';\n"
            "import 'page.dart';\n"
            "export 'package:test/platform/host.dart';",
        uses: 'Model? m; Engine? e; Page? p; Future<void>? f;',
      ),
    );
    await assertNoDiagnosticsInFile(
      _file(
        'services/across.dart',
        directives:
            "import 'engine.dart';\n"
            "export 'engine.dart' if (dart.library.io) 'engine_io.dart';",
        uses: 'Engine? e;',
      ),
    );
    await assertNoDiagnosticsInFile(
      _file(
        'web_view_model_hosts.dart',
        directives:
            "import 'web_view_model.dart';\n"
            "import 'services/engine.dart';",
        uses: 'Model? m; Engine? e;',
      ),
    );
  }

  Future<void> test_a_file_with_no_layer() async {
    await assertDiagnosticsInFile(
      _file(
        'misc/stray.dart',
        directives: "import '../web_view_model.dart';",
        uses: 'Model? m;',
      ),
      [
        lint(
          0,
          0,
          name: 'layer_unplaced',
          messageContainsAll: ["No layer is named for 'misc/stray.dart'"],
        ),
      ],
    );
  }

  Future<void> test_outside_lib_nothing_is_held() async {
    final file = '$testPackageRootPath/test/up_test.dart';
    newFile(
      file,
      "import 'package:test/screens/page.dart';\n"
      'Page? p;\n',
    );
    await assertNoDiagnosticsInFile(file);
  }
}
