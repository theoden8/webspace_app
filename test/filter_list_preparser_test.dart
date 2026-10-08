// uBO pre-parser directives (CB-017). adblock-rust reads every `!` line as a
// comment, so `!#if` and `!#include` are resolved before the engine sees the
// text; each case here pins behaviour to uBO's `utils.preparser` and
// `assets.fetchFilterList`.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/filter_list_preparser.dart';
import 'package:webspace/services/outbound_http.dart';

import 'helpers/fake_outbound.dart';

final androidEnv =
    preparserEnv(android: true, ios: false, macos: false, linux: false);
final macEnv =
    preparserEnv(android: false, ios: false, macos: true, linux: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('expressions', () {
    test('tokens follow the webview engine', () {
      expect(evaluatePreparserExpr('env_chromium', env: androidEnv), isTrue);
      expect(evaluatePreparserExpr('env_mobile', env: androidEnv), isTrue);
      expect(evaluatePreparserExpr('env_safari', env: androidEnv), isFalse);
      expect(evaluatePreparserExpr('env_safari', env: macEnv), isTrue);
      expect(evaluatePreparserExpr('env_mobile', env: macEnv), isFalse);
      expect(evaluatePreparserExpr('env_firefox', env: androidEnv), isFalse);
      expect(evaluatePreparserExpr('ext_ublock', env: macEnv), isTrue);
    });

    test('negation, and/or, parentheses', () {
      expect(evaluatePreparserExpr('!env_firefox', env: androidEnv), isTrue);
      expect(
          evaluatePreparserExpr('env_firefox || env_chromium', env: androidEnv),
          isTrue);
      expect(
          evaluatePreparserExpr('(env_chromium && env_mobile)',
              env: androidEnv),
          isTrue);
      expect(
          evaluatePreparserExpr('env_chromium && !env_mobile', env: androidEnv),
          isFalse);
    });

    test('false and ext_abp never hold, their negation always does', () {
      expect(evaluatePreparserExpr('false', env: androidEnv), isFalse);
      expect(evaluatePreparserExpr('!false', env: androidEnv), isTrue);
      expect(evaluatePreparserExpr('ext_abp', env: androidEnv), isFalse);
      expect(evaluatePreparserExpr('!ext_abp', env: androidEnv), isTrue);
    });

    test('an unknown cap_ token is false, any other unknown token is unknown',
        () {
      expect(
          evaluatePreparserExpr('cap_future_thing', env: androidEnv), isFalse);
      expect(evaluatePreparserExpr('env_future', env: androidEnv), isNull);
      expect(evaluatePreparserExpr('&& env_chromium', env: androidEnv), isNull);
    });
  });

  group('pruning', () {
    test('a false branch is dropped, its else kept', () {
      const list = '!#if env_firefox\n'
          'firefox-only.example##.a\n'
          '!#else\n'
          'other.example##.b\n'
          '!#endif\n'
          '||always.example^\n';
      final out = pruneFilterList(list, env: androidEnv);
      expect(out, isNot(contains('firefox-only')));
      expect(out, contains('other.example##.b'));
      expect(out, contains('||always.example^'));
    });

    test('a nested false block inside a true one is dropped', () {
      const list = '!#if env_chromium\n'
          'a.example##.x\n'
          '!#if env_safari\n'
          'b.example##.y\n'
          '!#endif\n'
          'c.example##.z\n'
          '!#endif\n';
      final out = pruneFilterList(list, env: androidEnv);
      expect(out, contains('a.example'));
      expect(out, isNot(contains('b.example')));
      expect(out, contains('c.example'));
    });

    test('a block under an unknown token is kept, as uBO keeps it', () {
      const list = '!#if env_future\nkept.example##.x\n!#endif\n';
      expect(pruneFilterList(list, env: androidEnv), contains('kept.example'));
    });

    test('a list with no directives is returned untouched', () {
      const list = '||a.example^\n! comment\n##.ad\n';
      expect(identical(pruneFilterList(list, env: androidEnv), list), isTrue);
    });
  });

  group('includes', () {
    Future<String?> Function(String) server(
        Map<String, String> files, {required List<String> fetched}) {
      return (url) async {
        fetched.add(url);
        return files[url];
      };
    }

    test('a sublist resolves against its parent and nests', () async {
      final fetched = <String>[];
      final out = await expandFilterListIncludes(
        '||top.example^\n!#include sub/a.txt\n',
        url: 'https://lists.example/filters/main.txt',
        env: androidEnv,
        fetch: server({
          'https://lists.example/filters/sub/a.txt':
              '||a.example^\n!#include b.txt\n',
          'https://lists.example/filters/sub/b.txt': '||b.example^',
        }, fetched: fetched),
      );
      expect(fetched, [
        'https://lists.example/filters/sub/a.txt',
        'https://lists.example/filters/sub/b.txt',
      ]);
      expect(out, contains('||top.example^'));
      expect(out, contains('||a.example^'));
      expect(out, contains('||b.example^'));
    });

    test('an include uBO refuses is never fetched', () async {
      final fetched = <String>[];
      await expandFilterListIncludes(
        '!#include https://evil.example/x.txt\n'
        '!#include ../secret.txt\n'
        '!#include %2e%2e/secret.txt\n'
        '!#include a\\..\\b.txt\n',
        url: 'https://lists.example/filters/main.txt',
        env: androidEnv,
        fetch: server(const {}, fetched: fetched),
      );
      expect(fetched, isEmpty);
    });

    test('an include inside a false !#if is not fetched', () async {
      final fetched = <String>[];
      final out = await expandFilterListIncludes(
        '!#if env_firefox\n!#include firefox.txt\n!#endif\n'
        '!#if env_chromium\n!#include chromium.txt\n!#endif\n',
        url: 'https://lists.example/main.txt',
        env: androidEnv,
        fetch: server({'https://lists.example/chromium.txt': '||c.example^'},
            fetched: fetched),
      );
      expect(fetched, ['https://lists.example/chromium.txt']);
      expect(out, contains('||c.example^'));
    });

    test('a sublist named twice is fetched once', () async {
      final fetched = <String>[];
      await expandFilterListIncludes(
        '!#include a.txt\n!#include a.txt\n',
        url: 'https://lists.example/main.txt',
        env: androidEnv,
        fetch: server({'https://lists.example/a.txt': '!#include a.txt\n'},
            fetched: fetched),
      );
      expect(fetched, ['https://lists.example/a.txt']);
    });

    test('a sublist that cannot be fetched fails the whole list', () async {
      await expectLater(
        expandFilterListIncludes(
          '!#include missing.txt\n',
          url: 'https://lists.example/main.txt',
          env: androidEnv,
          fetch: server(const {}, fetched: []),
        ),
        throwsA(isA<FilterListIncludeError>()),
      );
    });

    test('the sublist count is bounded', () async {
      final files = {
        for (var i = 0; i < 5; i++)
          'https://lists.example/$i.txt': '!#include ${i + 1}.txt\n',
      };
      await expectLater(
        expandFilterListIncludes('!#include 0.txt\n',
            url: 'https://lists.example/main.txt',
            env: androidEnv,
            fetch: server(files, fetched: []),
            maxSublists: 3),
        throwsA(isA<FilterListIncludeError>()),
      );
    });
  });

  group('download', () {
    final service = ContentBlockerService.instance;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      service.reset();
      service.store = MemoryFileStore();
    });

    tearDown(resetOutboundHttp);

    test('a downloaded list carries its sublists into the rule set', () async {
      outboundHttp = FakeOutbound(responder: (req) {
        switch (req.url.toString()) {
          case 'https://lists.example/f/filters.txt':
            return http.Response('||main.example^\n!#include more.txt\n', 200);
          case 'https://lists.example/f/more.txt':
            return http.Response('||included.example^\n', 200);
        }
        return http.Response('', 404);
      });
      final id = await service.addCustomList(
          'uBO filters', url: 'https://lists.example/f/filters.txt');

      expect(await service.downloadList(id), isTrue);
      expect(service.abpNetworkBlockHosts,
          containsAll(['main.example', 'included.example']));
    });

    test('a failed sublist fails the download and caches nothing', () async {
      outboundHttp = FakeOutbound(responder: (req) =>
          req.url.path.endsWith('filters.txt')
              ? http.Response('||main.example^\n!#include gone.txt\n', 200)
              : http.Response('', 404));
      final id = await service.addCustomList(
          'uBO filters', url: 'https://lists.example/f/filters.txt');

      expect(await service.downloadList(id), isFalse);
      expect(service.lists.singleWhere((l) => l.id == id).lastUpdated, isNull);
      expect(service.abpNetworkBlockHosts, isNot(contains('main.example')));
    });
  });
}
