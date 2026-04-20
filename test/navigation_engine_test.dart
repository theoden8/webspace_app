import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/navigation_engine.dart';

void main() {
  group('NavigationEngine.isHomeUrl', () {
    test('treats trailing-slash and bare URL as equal', () {
      expect(NavigationEngine.isHomeUrl('https://example.com/', 'https://example.com'), isTrue);
      expect(NavigationEngine.isHomeUrl('https://example.com', 'https://example.com/'), isTrue);
    });

    test('equal URLs match regardless of scheme', () {
      expect(NavigationEngine.isHomeUrl('http://example.com', 'http://example.com'), isTrue);
      expect(NavigationEngine.isHomeUrl('https://example.com/', 'https://example.com/'), isTrue);
    });

    test('different paths do not match', () {
      expect(NavigationEngine.isHomeUrl('https://example.com/about', 'https://example.com'), isFalse);
      expect(NavigationEngine.isHomeUrl('https://example.com/', 'https://example.com/about'), isFalse);
    });

    test('different hosts do not match', () {
      expect(NavigationEngine.isHomeUrl('https://other.com/', 'https://example.com/'), isFalse);
    });

    test('does not collapse multiple trailing slashes', () {
      expect(NavigationEngine.isHomeUrl('https://example.com//', 'https://example.com/'), isFalse);
    });

    test('query strings matter', () {
      expect(NavigationEngine.isHomeUrl('https://example.com/?q=1', 'https://example.com'), isFalse);
    });

    test('empty strings match', () {
      expect(NavigationEngine.isHomeUrl('', ''), isTrue);
    });

    test('case-sensitive comparison (does not canonicalize host)', () {
      expect(NavigationEngine.isHomeUrl('https://Example.com/', 'https://example.com/'), isFalse);
    });
  });

  group('NavigationEngine.trySyncCanGoBack', () {
    test('returns false when no active site', () {
      expect(
        NavigationEngine.trySyncCanGoBack(
          currentIndex: null,
          siteCount: 3,
          currentUrl: null,
          initUrl: null,
          hasController: true,
        ),
        isFalse,
      );
    });

    test('returns false when currentIndex is out of bounds', () {
      expect(
        NavigationEngine.trySyncCanGoBack(
          currentIndex: 5,
          siteCount: 3,
          currentUrl: 'https://example.com/',
          initUrl: 'https://example.com',
          hasController: true,
        ),
        isFalse,
      );
    });

    test('returns false when currentIndex is negative', () {
      expect(
        NavigationEngine.trySyncCanGoBack(
          currentIndex: -1,
          siteCount: 3,
          currentUrl: 'https://example.com/',
          initUrl: 'https://example.com',
          hasController: true,
        ),
        isFalse,
      );
    });

    test('returns false when on home URL even if controller present', () {
      expect(
        NavigationEngine.trySyncCanGoBack(
          currentIndex: 0,
          siteCount: 1,
          currentUrl: 'https://example.com/',
          initUrl: 'https://example.com',
          hasController: true,
        ),
        isFalse,
      );
    });

    test('returns false when on home URL even without controller', () {
      expect(
        NavigationEngine.trySyncCanGoBack(
          currentIndex: 0,
          siteCount: 1,
          currentUrl: 'https://example.com/',
          initUrl: 'https://example.com',
          hasController: false,
        ),
        isFalse,
      );
    });

    test('returns false when no controller attached', () {
      expect(
        NavigationEngine.trySyncCanGoBack(
          currentIndex: 0,
          siteCount: 1,
          currentUrl: 'https://example.com/about',
          initUrl: 'https://example.com',
          hasController: false,
        ),
        isFalse,
      );
    });

    test('returns null (ask controller) when off-home with a controller', () {
      expect(
        NavigationEngine.trySyncCanGoBack(
          currentIndex: 0,
          siteCount: 1,
          currentUrl: 'https://example.com/about',
          initUrl: 'https://example.com',
          hasController: true,
        ),
        isNull,
      );
    });

    test('returns null when URLs unknown but controller present and index valid', () {
      expect(
        NavigationEngine.trySyncCanGoBack(
          currentIndex: 0,
          siteCount: 1,
          currentUrl: null,
          initUrl: null,
          hasController: true,
        ),
        isNull,
      );
    });
  });
}
