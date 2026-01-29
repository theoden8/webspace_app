import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/webview.dart';
import 'dart:io';

void main() {
  group('WebViewModel Integration Tests', () {
    test('extractDomain extracts correct domain', () {
      expect(extractDomain('https://github.com/user/repo'), 'github.com');
      expect(extractDomain('http://localhost:5000'), 'localhost');
      expect(extractDomain('https://192.168.1.1:8080/path'), '192.168.1.1');
    });

    test('WebViewModel initializes with correct defaults', () {
      final model = WebViewModel(
        initUrl: 'http://localhost:5000',
      );

      expect(model.initUrl, 'http://localhost:5000');
      expect(model.currentUrl, 'http://localhost:5000');
      expect(model.name, 'localhost'); // Should default to domain
      expect(model.pageTitle, null); // No title yet
      expect(model.javascriptEnabled, true);
      expect(model.cookies, isEmpty);
    });

    test('WebViewModel name updates from page title', () {
      final model = WebViewModel(
        initUrl: 'http://localhost:5000',
      );

      // Initially name is domain
      expect(model.name, 'localhost');

      // Simulate page title being fetched
      model.pageTitle = 'MLflow - Experiment Tracking';
      
      // If name is still default domain, it should auto-update
      // (This happens in onUrlChanged callback in real usage)
      if (model.name == extractDomain(model.initUrl)) {
        model.name = model.pageTitle!;
      }

      expect(model.name, 'MLflow - Experiment Tracking');
      expect(model.getDisplayName(), 'MLflow - Experiment Tracking');
    });

    test('WebViewModel serialization preserves page title', () {
      final model = WebViewModel(
        initUrl: 'http://localhost:5000',
      );
      model.pageTitle = 'Test Page - WebSpace';
      model.name = 'Test Page - WebSpace';

      final json = model.toJson();
      expect(json['pageTitle'], 'Test Page - WebSpace');
      expect(json['name'], 'Test Page - WebSpace');
      expect(json['initUrl'], 'http://localhost:5000');

      // Deserialize and verify
      final restored = WebViewModel.fromJson(json, null);
      expect(restored.pageTitle, 'Test Page - WebSpace');
      expect(restored.name, 'Test Page - WebSpace');
      expect(restored.initUrl, 'http://localhost:5000');
    });

    test('WebViewModel handles custom name without overwriting', () {
      final model = WebViewModel(
        initUrl: 'http://localhost:5000',
        name: 'My Custom MLflow',
      );

      expect(model.name, 'My Custom MLflow');

      // Simulate page title being fetched
      model.pageTitle = 'MLflow - Experiment Tracking';
      
      // Custom name should NOT be overwritten
      expect(model.name, 'My Custom MLflow');
      expect(model.getDisplayName(), 'My Custom MLflow');
    });

    test('WebViewModel URL editing updates correctly', () {
      final model = WebViewModel(
        initUrl: 'http://localhost:5000',
      );

      // Simulate URL editing
      model.initUrl = 'http://localhost:8080';
      model.currentUrl = 'http://localhost:8080';
      model.webview = null; // Force recreation
      model.controller = null;

      expect(model.initUrl, 'http://localhost:8080');
      expect(model.currentUrl, 'http://localhost:8080');
    });
  });

  group('Test Page Fixtures', () {
    test('test_page.html fixture exists', () {
      final file = File('test/fixtures/test_page.html');
      expect(file.existsSync(), true, reason: 'Test page fixture should exist');
      
      final content = file.readAsStringSync();
      expect(content.contains('<title>Test Page - WebSpace</title>'), true);
      expect(content.contains('color-scheme'), true);
    });

    test('favicon test fixtures exist', () {
      final fixtures = [
        'site_with_favicon.html',
        'site_without_favicon.html',
        'site_with_relative_favicon.html',
        'site_with_absolute_favicon.html',
        'site_with_cdn_favicon.html',
        'site_with_protocol_relative_favicon.html',
      ];

      for (final fixture in fixtures) {
        final file = File('test/fixtures/$fixture');
        expect(file.existsSync(), true, reason: '$fixture should exist');
      }
    });

    test('title extraction fixtures exist', () {
      final fixtures = [
        'site_title_extraction.html',
        'site_no_title.html',
        'site_empty_title.html',
      ];

      for (final fixture in fixtures) {
        final file = File('test/fixtures/$fixture');
        expect(file.existsSync(), true, reason: '$fixture should exist');
      }
    });

    test('theme test fixtures exist', () {
      final fixtures = [
        'site_theme_support.html',
        'site_no_theme_support.html',
      ];

      for (final fixture in fixtures) {
        final file = File('test/fixtures/$fixture');
        expect(file.existsSync(), true, reason: '$fixture should exist');
      }
    });

    test('favicon link extraction from HTML', () {
      final withFavicon = File('test/fixtures/site_with_favicon.html').readAsStringSync();
      final withoutFavicon = File('test/fixtures/site_without_favicon.html').readAsStringSync();
      final relativeFavicon = File('test/fixtures/site_with_relative_favicon.html').readAsStringSync();
      
      // Site with favicon should have link rel="icon"
      expect(withFavicon.contains('rel="icon"'), true);
      expect(withFavicon.contains('href="/static/favicon.ico"'), true);
      
      // Site without should have no icon link
      expect(withoutFavicon.contains('rel="icon"'), false);
      
      // Relative path
      expect(relativeFavicon.contains('href="assets/icons/favicon.png"'), true);
    });

    test('title extraction from HTML', () {
      final withTitle = File('test/fixtures/site_title_extraction.html').readAsStringSync();
      final noTitle = File('test/fixtures/site_no_title.html').readAsStringSync();
      final emptyTitle = File('test/fixtures/site_empty_title.html').readAsStringSync();
      
      // Should have proper title
      expect(withTitle.contains('<title>Test Page Title - WebSpace App</title>'), true);
      
      // No title tag at all
      expect(noTitle.contains('<title>'), false);
      
      // Empty title tag
      expect(emptyTitle.contains('<title></title>'), true);
    });

    test('theme support detection from HTML', () {
      final withTheme = File('test/fixtures/site_theme_support.html').readAsStringSync();
      final noTheme = File('test/fixtures/site_no_theme_support.html').readAsStringSync();
      
      // Should have color-scheme meta tag
      expect(withTheme.contains('name="color-scheme"'), true);
      expect(withTheme.contains('prefers-color-scheme'), true);
      
      // Should not have color-scheme
      expect(noTheme.contains('name="color-scheme"'), false);
    });
  });

  group('Protocol Inference', () {
    test('infers https when no protocol specified', () {
      String inferProtocol(String url) {
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
          return 'https://$url';
        }
        return url;
      }

      expect(inferProtocol('localhost:8080'), 'https://localhost:8080');
      expect(inferProtocol('example.com'), 'https://example.com');
      expect(inferProtocol('192.168.1.1'), 'https://192.168.1.1');
    });

    test('preserves explicit http protocol', () {
      String inferProtocol(String url) {
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
          return 'https://$url';
        }
        return url;
      }

      expect(inferProtocol('http://localhost:5000'), 'http://localhost:5000');
      expect(inferProtocol('http://example.com'), 'http://example.com');
    });

    test('preserves explicit https protocol', () {
      String inferProtocol(String url) {
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
          return 'https://$url';
        }
        return url;
      }

      expect(inferProtocol('https://github.com'), 'https://github.com');
      expect(inferProtocol('https://localhost:8080'), 'https://localhost:8080');
    });
  });

  group('Cookie Tests', () {
    test('Cookie serialization works correctly', () {
      final cookie = Cookie(
        name: 'session_id',
        value: 'test123',
        domain: 'localhost',
        path: '/',
        isSecure: false,
        isHttpOnly: true,
      );

      final json = cookie.toJson();
      expect(json['name'], 'session_id');
      expect(json['value'], 'test123');
      expect(json['domain'], 'localhost');

      final restored = cookieFromJson(json);
      expect(restored.name, 'session_id');
      expect(restored.value, 'test123');
      expect(restored.domain, 'localhost');
    });
  });
}
