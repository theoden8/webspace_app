import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/ios_universal_link_bypass.dart';

void main() {
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
          'https://www.google.com/maps',
          now: t.add(const Duration(milliseconds: 100))), isTrue);
      // Each URL's reissue arrives separately.
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/place/A',
          now: t.add(const Duration(milliseconds: 200))), isFalse);
      expect(bypass.shouldCancelAndReissue(
          'https://www.google.com/maps',
          now: t.add(const Duration(milliseconds: 300))), isFalse);
    });

    test('treats every URL as eligible — no domain filtering', () {
      // Generic bypass: the class doesn't decide which URLs are
      // AASA-matching. The webview-side gate (Platform.isIOS,
      // main frame, http(s), hasGesture) does that filtering. Here
      // we just confirm the memo doesn't accidentally exempt some
      // URLs by host.
      final bypass = IosUniversalLinkBypass();
      expect(bypass.shouldCancelAndReissue('https://example.com/'), isTrue);
      expect(bypass.shouldCancelAndReissue('https://github.com/foo'), isTrue);
      expect(bypass.shouldCancelAndReissue('http://insecure.example/'), isTrue);
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
