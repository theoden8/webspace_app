import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/ios_universal_link_bypass.dart';

void main() {
  group('IosUniversalLinkBypass.isUniversalLinkUrl', () {
    test('matches maps.google.com on any path', () {
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://maps.google.com/'), isTrue);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://maps.google.com/maps'), isTrue);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://maps.google.com/maps?q=foo&gl=GB'), isTrue);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://maps.google.com/place/Foo'), isTrue);
    });

    test('matches www.google.com only on the /maps path prefix', () {
      // Hit (the actual bug case from user logs after consent.google.com).
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://www.google.com/maps'), isTrue);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://www.google.com/maps/'), isTrue);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://www.google.com/maps/place/Foo'), isTrue);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://www.google.com/maps?q=test'), isTrue);
      // Other www.google.com paths must not be intercepted — Google
      // Search, Gmail, Drive, etc. don't auto-launch any iOS app.
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://www.google.com/'), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://www.google.com/search?q=test'), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://www.google.com/mapsfoo'), isFalse);
    });

    test('matches apex google.com on /maps prefix too', () {
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://google.com/maps'), isTrue);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://google.com/'), isFalse);
    });

    test('matches Google Maps short links', () {
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://maps.app.goo.gl/abcXYZ'), isTrue);
    });

    test('matches subdomains of unrestricted-host rules', () {
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://www.maps.google.com/'), isTrue);
    });

    test('does not match other Google services', () {
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://accounts.google.com/'), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://consent.google.com/m'), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://drive.google.com/'), isFalse);
    });

    test('does not match unrelated domains that contain the substring', () {
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://maps.google.com.evil.example/'), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://example.com/maps.google.com'), isFalse);
    });

    test('handles uppercase hostnames', () {
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://Maps.Google.COM/'), isTrue);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'https://WWW.GOOGLE.COM/maps'), isTrue);
    });

    test('returns false for non-http URLs and malformed input', () {
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(''), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl('not a url'), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'about:blank'), isFalse);
      expect(IosUniversalLinkBypass.isUniversalLinkUrl(
          'comgooglemaps://?q=foo'), isFalse);
    });
  });

  group('IosUniversalLinkBypass approval memo', () {
    test('consumeApproval returns false when no entry exists', () {
      final bypass = IosUniversalLinkBypass();
      expect(bypass.consumeApproval('https://maps.google.com/'), isFalse);
    });

    test('after markApprovedContinue, consumeApproval returns true once', () {
      final bypass = IosUniversalLinkBypass();
      final t = DateTime(2026, 1, 1, 12, 0, 0);
      bypass.markApprovedContinue('https://maps.google.com/maps', now: t);
      // Reissued nav lands moments later — must pass through.
      expect(bypass.consumeApproval('https://maps.google.com/maps',
          now: t.add(const Duration(milliseconds: 50))), isTrue);
      // Subsequent navigation to the same URL must re-prompt (entry
      // is consumed on the first allowance).
      expect(bypass.consumeApproval('https://maps.google.com/maps',
          now: t.add(const Duration(milliseconds: 100))), isFalse);
    });

    test('approval expires after the window', () {
      final bypass = IosUniversalLinkBypass();
      final t = DateTime(2026, 1, 1, 12, 0, 0);
      bypass.markApprovedContinue('https://maps.google.com/', now: t);
      // 10 seconds later — well past the approval window.
      expect(bypass.consumeApproval('https://maps.google.com/',
          now: t.add(const Duration(seconds: 10))), isFalse);
    });

    test('different URLs are tracked independently', () {
      final bypass = IosUniversalLinkBypass();
      final t = DateTime(2026, 1, 1, 12, 0, 0);
      bypass.markApprovedContinue('https://maps.google.com/place/A', now: t);
      bypass.markApprovedContinue('https://maps.google.com/place/B', now: t);
      expect(bypass.consumeApproval('https://maps.google.com/place/A',
          now: t.add(const Duration(milliseconds: 100))), isTrue);
      expect(bypass.consumeApproval('https://maps.google.com/place/B',
          now: t.add(const Duration(milliseconds: 200))), isTrue);
      // Both consumed.
      expect(bypass.consumeApproval('https://maps.google.com/place/A',
          now: t.add(const Duration(milliseconds: 300))), isFalse);
      expect(bypass.consumeApproval('https://maps.google.com/place/B',
          now: t.add(const Duration(milliseconds: 400))), isFalse);
    });

    test('clear() resets the memo', () {
      final bypass = IosUniversalLinkBypass();
      final t = DateTime(2026, 1, 1, 12, 0, 0);
      bypass.markApprovedContinue('https://maps.google.com/', now: t);
      bypass.clear();
      expect(bypass.consumeApproval('https://maps.google.com/',
          now: t.add(const Duration(milliseconds: 50))), isFalse);
    });
  });
}
