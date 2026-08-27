// A trailing root dot in the host is a normalization bypass: chromium keeps
// the FQDN form (`tracker.example.com.`) in the URL it hands the blocking
// stack, DNS resolves it identically, and no filter list writes hostnames
// that way. `extractHost` already folds it away, but adblock-rust parses the
// URL itself and never sees that output — so every engine entry point has to
// hand it a URL that was normalized first.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/host_lookup.dart';

bool _libraryExists() {
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  return File('${Directory.current.path}'
          '/rust/webspace_adblock/target/release/libwebspace_adblock.$ext')
      .existsSync();
}

void main() {
  group('stripRootDot', () {
    test('drops the host root dot and leaves the rest byte-identical', () {
      expect(stripRootDot('https://tracker.example.com./collect?a=b.#f'),
          'https://tracker.example.com/collect?a=b.#f');
      expect(stripRootDot('http://example.com.:8080/x'),
          'http://example.com:8080/x');
      expect(stripRootDot('https://user:pa.ss@example.com./x'),
          'https://user:pa.ss@example.com/x');
      expect(stripRootDot('https://example.com.'), 'https://example.com');
    });

    test('leaves a URL with nothing to drop untouched', () {
      for (final url in const [
        'https://example.com/path.',
        'https://example.com/',
        'about:blank',
        'data:text/html,<p>.</p>',
        '',
      ]) {
        expect(stripRootDot(url), url, reason: url);
      }
    });

    test('drops at most one dot', () {
      expect(stripRootDot('https://example.com../x'),
          'https://example.com./x',
          reason: '`example.com..` is not a valid FQDN form');
    });

    test('leaves bracketed IPv6 literals alone', () {
      expect(stripRootDot('https://[2001:db8::1]/x'),
          'https://[2001:db8::1]/x');
      expect(stripRootDot('https://[2001:db8::1]:443/x'),
          'https://[2001:db8::1]:443/x');
    });

    test('agrees with extractHost on what the host is', () {
      for (final url in const [
        'https://tracker.example.com./collect',
        'https://example.com.:8080/x',
        'https://user@example.com./x',
      ]) {
        expect(extractHost(url), extractHost(stripRootDot(url)), reason: url);
      }
    });
  });

  group('engine entry points normalize before matching', () {
    final libExists = _libraryExists();
    final service = ContentBlockerService.instance;

    tearDown(() => service.setRustEngineForTest(null));

    test('a trailing-dot host is blocked like its bare form', () {
      service.reset();
      service.setRustEngineForTest(AdblockEngine.load('||tracker.com^\n'));

      expect(service.isBlocked('https://tracker.com/pixel.gif'), isTrue,
          reason: 'baseline');
      expect(service.isBlocked('https://tracker.com./pixel.gif'), isTrue,
          reason: 'the FQDN form must not evade the engine');
      expect(service.isBlocked('https://tracker.com.:443/pixel.gif'), isTrue);
      expect(service.isBlocked('https://safe.example./pixel.gif'), isFalse);
    }, skip: libExists ? false : 'library not built');

    test('a trailing-dot sourceUrl matches \$domain= the same way', () {
      service.reset();
      service.setRustEngineForTest(
          AdblockEngine.load('||ads.example^\$domain=news.example\n'));

      expect(
          service.isBlocked('https://ads.example/a.js',
              sourceUrl: 'https://news.example/', requestType: 'script'),
          isTrue,
          reason: 'baseline');
      expect(
          service.isBlocked('https://ads.example./a.js',
              sourceUrl: 'https://news.example./', requestType: 'script'),
          isTrue,
          reason: 'neither the request nor its origin may evade \$domain=');
    }, skip: libExists ? false : 'library not built');
  });
}
