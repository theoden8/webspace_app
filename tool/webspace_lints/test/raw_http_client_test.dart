import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'package:webspace_lints/src/raw_http_client.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(RawHttpClientTest);
  });
}

/// dart:io's client, which the mock SDK leaves out.
const _ioClient = r'''
abstract interface class HttpClient {
  factory HttpClient() => throw 0;
}
''';

/// The cases' own declarations: a seam, a look-alike of package:http's
/// names that opens nothing, and package:http's testing client.
const _ours = r'''
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';

abstract class OutboundHttpFactory {
  http.Client clientFor();
}

class Client {}
Future<void> get(Uri url) async {}

// Each library the cases name, used once so no import goes unused.
HttpClient? io;
IOClient? ioClient;
MockClient? testing;
''';

@reflectiveTest
class RawHttpClientTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = RawHttpClient();
    newPackage('http')
      ..addFile('lib/http.dart', r'''
export 'src/client.dart';
Future<Object> get(Uri url) async => 0;
Future<Object> post(Uri url) async => 0;
Future<String> read(Uri url) async => '';
''')
      ..addFile('lib/src/client.dart', r'''
abstract interface class Client {
  factory Client() => throw 0;
}
''')
      ..addFile('lib/io_client.dart', r'''
import 'dart:io';
import 'src/client.dart';
class IOClient implements Client {
  IOClient([HttpClient? inner]);
}
''')
      ..addFile('lib/testing.dart', r'''
import 'src/client.dart';
class MockClient implements Client {
  MockClient(Object handler);
}
''');
    super.setUp();
    final io = sdkRoot.getFolder('lib').getFile('io/io.dart');
    newFile(io.path, '${io.readAsStringSync()}$_ioClient');
  }

  String _case(String body) =>
      '''
$_ours
void run() {
  $body
}
''';

  Future<void> _ok(String body) => assertNoDiagnostics(_case(body));

  Future<void> _caught(String body, {required String made}) async {
    final source = _case(body);
    final at = source.indexOf('/*here*/') + '/*here*/'.length;
    final length = source.indexOf('/*end*/') - at;
    await assertDiagnostics(source, [
      lint(at, length, messageContainsAll: ["'$made' opens a connection"]),
    ]);
  }

  Future<void> test_http_client() =>
      _caught('final c = /*here*/http.Client()/*end*/;', made: 'Client');

  Future<void> test_io_client() =>
      _caught('final c = /*here*/IOClient()/*end*/;', made: 'IOClient');

  Future<void> test_dart_io_client() =>
      _caught('final c = /*here*/HttpClient()/*end*/;', made: 'HttpClient');

  Future<void> test_http_get() =>
      _caught('http./*here*/get/*end*/(Uri());', made: 'http.get');

  Future<void> test_http_read() =>
      _caught('http./*here*/read/*end*/(Uri());', made: 'http.read');

  Future<void> test_a_client_held_for_later() => _caught(
    'final make = () => /*here*/http.Client()/*end*/;',
    made: 'Client',
  );

  Future<void> test_a_default_beside_a_given_client() async {
    final source =
        '''
$_ours
class Fetcher {
  Fetcher({http.Client? client}) : _client = client ?? /*here*/http.Client()/*end*/;
  final http.Client _client;
}
''';
    final at = source.indexOf('/*here*/') + '/*here*/'.length;
    await assertDiagnostics(source, [
      lint(
        at,
        source.indexOf('/*end*/') - at,
        messageContainsAll: ["'Client' opens a connection"],
      ),
    ]);
  }

  Future<void> test_the_seam_makes_clients() => assertNoDiagnostics('''
$_ours
class DefaultOutboundHttpFactory implements OutboundHttpFactory {
  @override
  http.Client clientFor() => IOClient(_inner());
  static HttpClient _inner() => HttpClient();
}
''');

  Future<void> test_a_wrapper_of_the_seam_is_the_seam() =>
      assertNoDiagnostics('''
$_ours
class Wrapping implements OutboundHttpFactory {
  @override
  http.Client clientFor() => http.Client();
}
''');

  Future<void> test_a_seam_by_name_alone_is_not() async {
    final source =
        '''
$_ours
class DefaultOutboundHttpFactory {
  http.Client clientFor() => /*here*/http.Client()/*end*/;
}
''';
    final at = source.indexOf('/*here*/') + '/*here*/'.length;
    await assertDiagnostics(source, [
      lint(
        at,
        source.indexOf('/*end*/') - at,
        messageContainsAll: ["'Client' opens a connection"],
      ),
    ]);
  }

  Future<void> test_outside_lib_a_test_talks_to_its_own_server() async {
    final path = '$testPackageRootPath/test/server_test.dart';
    newFile(path, _case('final c = http.Client();'));
    await assertNoDiagnosticsInFile(path);
  }

  Future<void> test_a_test_client() => _ok('final c = MockClient(0);');

  Future<void> test_a_look_alike_of_ours() =>
      _ok('final c = Client(); get(Uri());');

  Future<void> test_a_type_annotation_opens_nothing() =>
      _ok('http.Client? c; HttpClient? d;');
}
