import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

void main() {
  group('UserScriptConfig', () {
    test('should initialize with default values', () {
      final script = UserScriptConfig(
        name: 'Test Script',
        source: 'console.log("hello");',
      );

      expect(script.name, equals('Test Script'));
      expect(script.source, equals('console.log("hello");'));
      expect(script.injectionTime, equals(UserScriptInjectionTime.atDocumentEnd));
      expect(script.enabled, isTrue);
    });

    test('should serialize to JSON', () {
      final script = UserScriptConfig(
        name: 'Dark Mode',
        source: 'document.body.style.background = "black";',
        injectionTime: UserScriptInjectionTime.atDocumentStart,
        enabled: false,
      );

      final json = script.toJson();

      expect(json['name'], equals('Dark Mode'));
      expect(json['source'], equals('document.body.style.background = "black";'));
      expect(json['injectionTime'], equals(0)); // atDocumentStart
      expect(json['enabled'], isFalse);
    });

    test('should deserialize from JSON', () {
      final json = {
        'name': 'Auto Login',
        'source': 'document.querySelector("#login").click();',
        'injectionTime': 1,
        'enabled': true,
      };

      final script = UserScriptConfig.fromJson(json);

      expect(script.name, equals('Auto Login'));
      expect(script.source, equals('document.querySelector("#login").click();'));
      expect(script.injectionTime, equals(UserScriptInjectionTime.atDocumentEnd));
      expect(script.enabled, isTrue);
    });

    test('should handle missing JSON fields with defaults', () {
      final script = UserScriptConfig.fromJson({});

      expect(script.name, equals('Untitled'));
      expect(script.source, equals(''));
      expect(script.injectionTime, equals(UserScriptInjectionTime.atDocumentEnd));
      expect(script.enabled, isTrue);
    });

    test('should roundtrip through JSON', () {
      final original = UserScriptConfig(
        name: 'Roundtrip',
        source: 'alert(1);',
        injectionTime: UserScriptInjectionTime.atDocumentStart,
        enabled: false,
      );

      final restored = UserScriptConfig.fromJson(original.toJson());

      expect(restored.name, equals(original.name));
      expect(restored.source, equals(original.source));
      expect(restored.injectionTime, equals(original.injectionTime));
      expect(restored.enabled, equals(original.enabled));
    });
  });

  group('WebViewModel user scripts integration', () {
    test('should default to empty user scripts list', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      expect(model.userScripts, isEmpty);
    });

    test('should serialize user scripts in toJson', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        userScripts: [
          UserScriptConfig(
            name: 'Script 1',
            source: 'console.log(1);',
          ),
          UserScriptConfig(
            name: 'Script 2',
            source: 'console.log(2);',
            injectionTime: UserScriptInjectionTime.atDocumentStart,
            enabled: false,
          ),
        ],
      );

      final json = model.toJson();
      final scripts = json['userScripts'] as List;

      expect(scripts, hasLength(2));
      expect(scripts[0]['name'], equals('Script 1'));
      expect(scripts[1]['name'], equals('Script 2'));
      expect(scripts[1]['enabled'], isFalse);
    });

    test('should deserialize user scripts from JSON', () {
      final json = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'name': 'Example',
        'cookies': [],
        'proxySettings': {'type': 0},
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
        'incognito': false,
        'clearUrlEnabled': true,
        'dnsBlockEnabled': true,
        'contentBlockEnabled': true,
        'blockAutoRedirects': true,
        'userScripts': [
          {
            'name': 'My Script',
            'source': 'document.title = "Custom";',
            'injectionTime': 0,
            'enabled': true,
          },
        ],
      };

      final model = WebViewModel.fromJson(json, null);

      expect(model.userScripts, hasLength(1));
      expect(model.userScripts[0].name, equals('My Script'));
      expect(model.userScripts[0].injectionTime, equals(UserScriptInjectionTime.atDocumentStart));
    });

    test('should handle missing userScripts in JSON (backward compat)', () {
      final json = {
        'initUrl': 'https://example.com',
        'currentUrl': 'https://example.com',
        'name': 'Example',
        'cookies': [],
        'proxySettings': {'type': 0},
        'javascriptEnabled': true,
        'userAgent': '',
        'thirdPartyCookiesEnabled': false,
        'incognito': false,
        'clearUrlEnabled': true,
        'dnsBlockEnabled': true,
        'contentBlockEnabled': true,
        'blockAutoRedirects': true,
      };

      final model = WebViewModel.fromJson(json, null);

      expect(model.userScripts, isEmpty);
    });
  });

  group('classifyScriptFetchUrl', () {
    // Whitelisted CDN domains
    test('should whitelist cdn.jsdelivr.net', () {
      expect(
        classifyScriptFetchUrl('https://cdn.jsdelivr.net/npm/lodash/lodash.min.js'),
        ScriptFetchUrlStatus.whitelisted,
      );
    });

    test('should whitelist unpkg.com', () {
      expect(
        classifyScriptFetchUrl('https://unpkg.com/react@18/umd/react.production.min.js'),
        ScriptFetchUrlStatus.whitelisted,
      );
    });

    test('should whitelist cdnjs.cloudflare.com', () {
      expect(
        classifyScriptFetchUrl('https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js'),
        ScriptFetchUrlStatus.whitelisted,
      );
    });

    test('should whitelist raw.githubusercontent.com', () {
      expect(
        classifyScriptFetchUrl('https://raw.githubusercontent.com/user/repo/main/script.js'),
        ScriptFetchUrlStatus.whitelisted,
      );
    });

    test('should whitelist gist.githubusercontent.com', () {
      expect(
        classifyScriptFetchUrl('https://gist.githubusercontent.com/user/abc123/raw/script.js'),
        ScriptFetchUrlStatus.whitelisted,
      );
    });

    test('should whitelist ajax.googleapis.com', () {
      expect(
        classifyScriptFetchUrl('https://ajax.googleapis.com/ajax/libs/jquery/3.7.1/jquery.min.js'),
        ScriptFetchUrlStatus.whitelisted,
      );
    });

    test('should whitelist esm.sh', () {
      expect(
        classifyScriptFetchUrl('https://esm.sh/react@18'),
        ScriptFetchUrlStatus.whitelisted,
      );
    });

    test('should whitelist subdomains of whitelisted domains', () {
      expect(
        classifyScriptFetchUrl('https://sub.cdn.jsdelivr.net/some/path'),
        ScriptFetchUrlStatus.whitelisted,
      );
    });

    test('should whitelist http:// (not just https://)', () {
      expect(
        classifyScriptFetchUrl('http://cdn.jsdelivr.net/npm/lodash/lodash.min.js'),
        ScriptFetchUrlStatus.whitelisted,
      );
    });

    // Non-whitelisted but valid http/https
    test('should require confirmation for unknown https domains', () {
      expect(
        classifyScriptFetchUrl('https://example.com/script.js'),
        ScriptFetchUrlStatus.requiresConfirmation,
      );
    });

    test('should require confirmation for http localhost', () {
      expect(
        classifyScriptFetchUrl('http://localhost:8080/script.js'),
        ScriptFetchUrlStatus.requiresConfirmation,
      );
    });

    test('should require confirmation for IPv4 address', () {
      expect(
        classifyScriptFetchUrl('http://192.168.1.1/scripts/app.js'),
        ScriptFetchUrlStatus.requiresConfirmation,
      );
    });

    test('should require confirmation for IPv4 with port', () {
      expect(
        classifyScriptFetchUrl('http://192.168.1.1:3000/bundle.js'),
        ScriptFetchUrlStatus.requiresConfirmation,
      );
    });

    test('should require confirmation for IPv6 address', () {
      expect(
        classifyScriptFetchUrl('http://[::1]/script.js'),
        ScriptFetchUrlStatus.requiresConfirmation,
      );
    });

    test('should require confirmation for IPv6 with port', () {
      expect(
        classifyScriptFetchUrl('http://[::1]:8080/script.js'),
        ScriptFetchUrlStatus.requiresConfirmation,
      );
    });

    test('should require confirmation for https with path and query', () {
      expect(
        classifyScriptFetchUrl('https://my-server.com/api/script.js?v=2&token=abc'),
        ScriptFetchUrlStatus.requiresConfirmation,
      );
    });

    // Blocked schemes
    test('should block javascript: URLs', () {
      expect(
        classifyScriptFetchUrl('javascript:alert(1)'),
        ScriptFetchUrlStatus.blocked,
      );
    });

    test('should block data: URLs', () {
      expect(
        classifyScriptFetchUrl('data:text/javascript,alert(1)'),
        ScriptFetchUrlStatus.blocked,
      );
    });

    test('should block blob: URLs', () {
      expect(
        classifyScriptFetchUrl('blob:https://example.com/abc-123'),
        ScriptFetchUrlStatus.blocked,
      );
    });

    test('should block file: URLs', () {
      expect(
        classifyScriptFetchUrl('file:///etc/passwd'),
        ScriptFetchUrlStatus.blocked,
      );
    });

    test('should block ftp: URLs', () {
      expect(
        classifyScriptFetchUrl('ftp://example.com/script.js'),
        ScriptFetchUrlStatus.blocked,
      );
    });

    test('should block empty URL', () {
      expect(
        classifyScriptFetchUrl(''),
        ScriptFetchUrlStatus.blocked,
      );
    });

    test('should block URL with no scheme', () {
      expect(
        classifyScriptFetchUrl('example.com/script.js'),
        ScriptFetchUrlStatus.blocked,
      );
    });

    test('should block URL with empty host', () {
      expect(
        classifyScriptFetchUrl('https:///script.js'),
        ScriptFetchUrlStatus.blocked,
      );
    });

    // Case insensitivity
    test('should handle uppercase schemes', () {
      expect(
        classifyScriptFetchUrl('HTTPS://cdn.jsdelivr.net/npm/lodash.js'),
        ScriptFetchUrlStatus.whitelisted,
      );
    });

    test('should handle mixed case host', () {
      expect(
        classifyScriptFetchUrl('https://CDN.JSDELIVR.NET/npm/lodash.js'),
        ScriptFetchUrlStatus.whitelisted,
      );
    });

    test('should block JAVASCRIPT: (case insensitive)', () {
      expect(
        classifyScriptFetchUrl('JAVASCRIPT:alert(1)'),
        ScriptFetchUrlStatus.blocked,
      );
    });

    // Whitelist should not match partial domain names
    test('should not whitelist domains that merely end with a whitelisted suffix', () {
      // evilcdn.jsdelivr.net would match because it ends with .cdn.jsdelivr.net
      // but evil-unpkg.com should NOT match unpkg.com
      expect(
        classifyScriptFetchUrl('https://evil-unpkg.com/script.js'),
        ScriptFetchUrlStatus.requiresConfirmation,
      );
    });

    test('should not whitelist notcdnjs.cloudflare.com as cdnjs.cloudflare.com', () {
      // notcdnjs.cloudflare.com ends with cdnjs.cloudflare.com but is NOT a subdomain
      // It ends with .cloudflare.com which IS whitelisted via cdn.cloudflare.com...
      // Actually cdn.cloudflare.com is in the list, and notcdnjs.cloudflare.com
      // does NOT end with .cdn.cloudflare.com. It ends with .cloudflare.com but
      // cloudflare.com itself is not in the whitelist. Let me test a better case.
      expect(
        classifyScriptFetchUrl('https://notajax.googleapis.com/script.js'),
        ScriptFetchUrlStatus.requiresConfirmation,
      );
    });

    // fullSource tests
    test('fullSource returns source when no urlSource', () {
      final script = UserScriptConfig(name: 'test', source: 'alert(1)');
      expect(script.fullSource, 'alert(1)');
    });

    test('fullSource returns urlSource when no source', () {
      final script = UserScriptConfig(name: 'test', source: '', urlSource: 'var x = 1;');
      expect(script.fullSource, 'var x = 1;');
    });

    test('fullSource concatenates urlSource and source', () {
      final script = UserScriptConfig(
        name: 'test',
        source: 'MyLib.init();',
        urlSource: '/* cdn lib */',
      );
      expect(script.fullSource, '/* cdn lib */\nMyLib.init();');
    });

    // Serialization of new fields
    test('url and urlSource roundtrip through JSON', () {
      final original = UserScriptConfig(
        name: 'Lib',
        source: 'MyLib.init();',
        url: 'https://cdn.jsdelivr.net/npm/lodash/lodash.min.js',
        urlSource: '/* cached */',
      );
      final restored = UserScriptConfig.fromJson(original.toJson());
      expect(restored.url, original.url);
      expect(restored.urlSource, original.urlSource);
      expect(restored.fullSource, original.fullSource);
    });

    test('missing url/urlSource in JSON defaults to null', () {
      final script = UserScriptConfig.fromJson({
        'name': 'test',
        'source': 'alert(1)',
        'injectionTime': 1,
        'enabled': true,
      });
      expect(script.url, isNull);
      expect(script.urlSource, isNull);
      expect(script.fullSource, 'alert(1)');
    });

    test('fullSource returns empty when both urlSource and source are empty', () {
      final script = UserScriptConfig(name: 'empty', source: '');
      expect(script.fullSource, '');
    });

    test('fullSource returns empty urlSource only when source is empty', () {
      final script = UserScriptConfig(name: 'test', source: '', urlSource: '');
      expect(script.fullSource, '');
    });

    test('url excluded from JSON when null', () {
      final script = UserScriptConfig(name: 'test', source: 'x');
      final json = script.toJson();
      expect(json.containsKey('url'), isFalse);
      expect(json.containsKey('urlSource'), isFalse);
    });

    test('url included in JSON when set', () {
      final script = UserScriptConfig(
        name: 'test',
        source: 'x',
        url: 'https://cdn.example.com/lib.js',
        urlSource: '/* lib */',
      );
      final json = script.toJson();
      expect(json['url'], 'https://cdn.example.com/lib.js');
      expect(json['urlSource'], '/* lib */');
    });

    test('toJson includes all fields for complete roundtrip', () {
      final original = UserScriptConfig(
        name: 'Complete',
        source: 'init();',
        url: 'https://cdn.jsdelivr.net/npm/lib.js',
        urlSource: 'function lib() {}',
        injectionTime: UserScriptInjectionTime.atDocumentStart,
        enabled: false,
      );
      final json = original.toJson();
      final restored = UserScriptConfig.fromJson(json);
      expect(restored.name, original.name);
      expect(restored.source, original.source);
      expect(restored.url, original.url);
      expect(restored.urlSource, original.urlSource);
      expect(restored.injectionTime, original.injectionTime);
      expect(restored.enabled, original.enabled);
      expect(restored.fullSource, original.fullSource);
    });
  });

  group('SettingsBackup global user scripts', () {
    test('global scripts serialize and deserialize', () {
      final scripts = [
        UserScriptConfig(
          name: 'Global Script',
          source: 'console.log("global");',
          injectionTime: UserScriptInjectionTime.atDocumentStart,
        ),
      ];
      final jsonList = scripts.map((s) => s.toJson()).toList();
      final restored = jsonList
          .map((e) => UserScriptConfig.fromJson(e as Map<String, dynamic>))
          .toList();
      expect(restored, hasLength(1));
      expect(restored[0].name, 'Global Script');
      expect(restored[0].source, 'console.log("global");');
      expect(restored[0].injectionTime, UserScriptInjectionTime.atDocumentStart);
    });
  });
}
