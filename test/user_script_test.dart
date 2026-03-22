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
}
