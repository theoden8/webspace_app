import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/platform/unified_webview.dart';

void main() {
  group('UnifiedCookie', () {
    test('should serialize to JSON correctly', () {
      final cookie = UnifiedCookie(
        name: 'test_cookie',
        value: 'test_value',
        domain: 'example.com',
        path: '/',
        expiresDate: 1234567890,
        isSecure: true,
        isHttpOnly: false,
        isSessionOnly: false,
        sameSite: 'Lax',
      );

      final json = cookie.toJson();

      expect(json['name'], equals('test_cookie'));
      expect(json['value'], equals('test_value'));
      expect(json['domain'], equals('example.com'));
      expect(json['path'], equals('/'));
      expect(json['expiresDate'], equals(1234567890));
      expect(json['isSecure'], equals(true));
      expect(json['isHttpOnly'], equals(false));
      expect(json['isSessionOnly'], equals(false));
      expect(json['sameSite'], equals('Lax'));
    });

    test('should deserialize from JSON correctly', () {
      final json = {
        'name': 'test_cookie',
        'value': 'test_value',
        'domain': 'example.com',
        'path': '/',
        'expiresDate': 1234567890,
        'isSecure': true,
        'isHttpOnly': false,
        'isSessionOnly': false,
        'sameSite': 'Lax',
      };

      final cookie = UnifiedCookie.fromJson(json);

      expect(cookie.name, equals('test_cookie'));
      expect(cookie.value, equals('test_value'));
      expect(cookie.domain, equals('example.com'));
      expect(cookie.path, equals('/'));
      expect(cookie.expiresDate, equals(1234567890));
      expect(cookie.isSecure, equals(true));
      expect(cookie.isHttpOnly, equals(false));
      expect(cookie.isSessionOnly, equals(false));
      expect(cookie.sameSite, equals('Lax'));
    });

    test('should handle null values in serialization', () {
      final cookie = UnifiedCookie(
        name: 'test_cookie',
        value: 'test_value',
      );

      final json = cookie.toJson();

      expect(json['name'], equals('test_cookie'));
      expect(json['value'], equals('test_value'));
      expect(json['domain'], isNull);
      expect(json['path'], isNull);
      expect(json['expiresDate'], isNull);
      expect(json['isSecure'], isNull);
      expect(json['isHttpOnly'], isNull);
      expect(json['isSessionOnly'], isNull);
      expect(json['sameSite'], isNull);
    });

    test('should round-trip through JSON correctly', () {
      final original = UnifiedCookie(
        name: 'session_id',
        value: 'abc123xyz',
        domain: 'test.example.com',
        path: '/api',
        expiresDate: 9999999999,
        isSecure: true,
        isHttpOnly: true,
        isSessionOnly: false,
        sameSite: 'Strict',
      );

      final json = original.toJson();
      final restored = UnifiedCookie.fromJson(json);

      expect(restored.name, equals(original.name));
      expect(restored.value, equals(original.value));
      expect(restored.domain, equals(original.domain));
      expect(restored.path, equals(original.path));
      expect(restored.expiresDate, equals(original.expiresDate));
      expect(restored.isSecure, equals(original.isSecure));
      expect(restored.isHttpOnly, equals(original.isHttpOnly));
      expect(restored.isSessionOnly, equals(original.isSessionOnly));
      expect(restored.sameSite, equals(original.sameSite));
    });
  });

  group('UnifiedFindMatchesResult', () {
    test('should initialize with zero matches', () {
      final result = UnifiedFindMatchesResult();

      expect(result.activeMatchOrdinal, equals(0));
      expect(result.numberOfMatches, equals(0));
    });

    test('should allow updating match counts', () {
      final result = UnifiedFindMatchesResult();

      result.activeMatchOrdinal = 3;
      result.numberOfMatches = 10;

      expect(result.activeMatchOrdinal, equals(3));
      expect(result.numberOfMatches, equals(10));
    });
  });
}
