import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'package:webspace_lints/src/model_identity.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ModelIdentityTest);
  });
}

/// A library of step tables and its sites, as the app's: a site carries the
/// model's key, its id.
const _tables = r'''
import 'package:webspace/services/step_table.dart';

class Site implements ModelKeyed {
  Site(this.siteId);
  final String siteId;
  @override
  Object get modelKey => siteId;
}

final listed = <Site>[];
final loaded = <Site>{};
final tabs = <Site, int>{};
''';

@reflectiveTest
class ModelIdentityTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = ModelIdentity();
    newPackage('webspace').addFile('lib/services/step_table.dart', r'''
abstract interface class ModelKeyed {
  Object get modelKey;
}
''');
    super.setUp();
  }

  Future<void> _caught(String body, {required String what}) async {
    final source = '$_tables\nvoid run(Site site, Site other, Site? maybe) {\n  $body\n}\n';
    final at = source.indexOf('/*here*/') + '/*here*/'.length;
    await assertDiagnostics(source, [
      lint(
        at,
        source.indexOf('/*end*/') - at,
        messageContainsAll: ["'$what' compares sites as objects"],
      ),
    ]);
  }

  Future<void> _ok(String body) => assertNoDiagnostics(
    '$_tables\nvoid run(Site site, Site other, Site? maybe) {\n  $body\n}\n',
  );

  Future<void> test_contains() => _caught(
    'final gone = !listed./*here*/contains/*end*/(site);',
    what: 'contains',
  );

  Future<void> test_index_of() =>
      _caught('final row = listed./*here*/indexOf/*end*/(site);', what: 'indexOf');

  Future<void> test_set_membership() => _caught(
    'final on = loaded./*here*/contains/*end*/(site);',
    what: 'contains',
  );

  Future<void> test_remove() =>
      _caught('loaded./*here*/remove/*end*/(site);', what: 'remove');

  Future<void> test_equality() =>
      _caught('final same = site /*here*/==/*end*/ other;', what: '==');

  Future<void> test_map_lookup() =>
      _caught('final t = tabs[/*here*/site/*end*/];', what: '[]');

  Future<void> test_by_id() => _ok(
    'for (final m in listed) { if (m.siteId == site.siteId) return; }',
  );

  Future<void> test_live_object_said_so() =>
      _ok('for (final m in listed) { if (identical(m, site)) return; }');

  Future<void> test_against_null() => _ok('if (maybe == null) return;');

  Future<void> test_a_library_without_tables() => assertNoDiagnostics(r'''
class Site {
  Site(this.siteId);
  final String siteId;
}
final listed = <Site>[];
bool gone(Site site) => !listed.contains(site);
''');
}
