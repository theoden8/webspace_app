import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/ios_universal_link_bypass.dart';

void main() {
  group('IosUniversalLinkBypass.isUniversalLinkDomain', () {
    test('matches maps.google.com exactly', () {
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'https://maps.google.com/'), isTrue);
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'https://maps.google.com/maps'), isTrue);
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'https://maps.google.com/maps?q=foo&gl=GB'), isTrue);
    });

    test('matches subdomain of maps.google.com (defense in depth)', () {
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'https://www.maps.google.com/'), isTrue);
    });

    test('matches Google Maps short links (maps.app.goo.gl)', () {
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'https://maps.app.goo.gl/abcXYZ'), isTrue);
    });

    test('does not match other Google services', () {
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'https://www.google.com/maps'), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'https://google.com/'), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'https://accounts.google.com/'), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'https://consent.google.com/m'), isFalse);
    });

    test('does not match unrelated domains that contain the substring', () {
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'https://maps.google.com.evil.example/'), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'https://mapsxgoogle.com/'), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'https://example.com/maps.google.com'), isFalse);
    });

    test('handles uppercase hostnames', () {
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'https://Maps.Google.COM/'), isTrue);
    });

    test('returns false for non-http URLs and malformed input', () {
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(''), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkDomain('not a url'), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'about:blank'), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkDomain(
          'comgooglemaps://?q=foo'), isFalse);
    });
  });

  group('IosUniversalLinkBypass.shouldCancelAndReissue', () {
    test('first pass returns true (caller cancels + reissues)', () {
      final bypass = IosUniversalLinkBypass();
      expect(bypass.shouldCancelAndReissue('https://maps.google.com/maps'),
          isTrue);
    });

    test('second pass within memo window returns false (caller allows)', () {
      final bypass = IosUniversalLinkBypass();
      final t = DateTime(2026, 1, 1, 12, 0, 0);
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps', now: t), isTrue);
      // Reissued nav arrives 50ms later — must be allowed through.
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps',
          now: t.add(const Duration(milliseconds: 50))), isFalse);
    });

    test('third pass after second pass triggers bypass again', () {
      final bypass = IosUniversalLinkBypass();
      final t = DateTime(2026, 1, 1, 12, 0, 0);
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps', now: t), isTrue);
      // Second pass consumes the memo entry.
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps',
          now: t.add(const Duration(milliseconds: 50))), isFalse);
      // A real new navigation later (e.g. user re-enters the URL) is
      // bypassed again, not allowed silently.
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps',
          now: t.add(const Duration(seconds: 30))), isTrue);
    });

    test('memo expires after the window even without a second pass', () {
      // If the reissued nav never arrives (e.g. user navigates away
      // mid-flight), the memo entry shouldn't pin the URL forever — a
      // future navigation 5s later still triggers bypass.
      final bypass = IosUniversalLinkBypass();
      final t = DateTime(2026, 1, 1, 12, 0, 0);
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps', now: t), isTrue);
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps',
          now: t.add(const Duration(seconds: 5))), isTrue);
    });

    test('different URLs are tracked independently', () {
      final bypass = IosUniversalLinkBypass();
      final t = DateTime(2026, 1, 1, 12, 0, 0);
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/place/A', now: t), isTrue);
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/place/B',
          now: t.add(const Duration(milliseconds: 100))), isTrue);
      // Each URL's reissue arrives separately.
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/place/A',
          now: t.add(const Duration(milliseconds: 200))), isFalse);
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/place/B',
          now: t.add(const Duration(milliseconds: 300))), isFalse);
    });

    test('clear() resets the memo', () {
      final bypass = IosUniversalLinkBypass();
      final t = DateTime(2026, 1, 1, 12, 0, 0);
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps', now: t), isTrue);
      bypass.clear();
      // After clear, the next call to the same URL bypasses again
      // (memo no longer says "you just reissued me").
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps',
          now: t.add(const Duration(milliseconds: 50))), isTrue);
    });
  });
}
