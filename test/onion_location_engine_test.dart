import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/onion_location.dart';
import 'package:webspace/services/onion_location_engine.dart';

const _proton =
    'protonmailrmez3lotccipshtkleegetolb73fuirgj7r4o4vfu7ozyd.onion';
const _torProject =
    '2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion';

final _endpoint =
    OnionEndpoint.of(from: 'https://proton.me', to: 'https://$_proton/')!;
final _now = DateTime.utc(2026, 11, 21);

SiteOnion _saved({
  OnionAnswer? answer = OnionAnswer.accepted,
  OnionFallback fallback = OnionFallback.none,
  Duration age = Duration.zero,
}) =>
    SiteOnion(
        endpoint: _endpoint,
        checked: _now.subtract(age),
        answer: answer,
        fallback: fallback);

void main() {
  group('onionCheckDue', () {
    test('ONION-007: never off Tor', () {
      expect(
          onionCheckDue(null,
              tor: false, pageUrl: 'https://proton.me/', now: _now),
          isFalse);
      expect(
          onionCheckDue(_saved(age: const Duration(days: 90)),
              tor: false, pageUrl: 'https://proton.me/', now: _now),
          isFalse);
    });

    test('a clearnet page is always due, nothing learned or not', () {
      expect(
          onionCheckDue(null,
              tor: true, pageUrl: 'https://proton.me/', now: _now),
          isTrue);
      expect(
          onionCheckDue(_saved(),
              tor: true, pageUrl: 'https://proton.me/', now: _now),
          isTrue);
    });

    test('a page on the onion is due only after 30 days', () {
      expect(
          onionCheckDue(_saved(age: const Duration(days: 29)),
              tor: true, pageUrl: 'https://$_proton/mail', now: _now),
          isFalse);
      expect(
          onionCheckDue(_saved(age: const Duration(days: 31)),
              tor: true, pageUrl: 'https://$_proton/mail', now: _now),
          isTrue);
    });
  });

  group('learnFrom', () {
    test('a failed check keeps everything', () {
      for (final saved in [null, _saved()]) {
        expect(
            learnFrom(const OnionCheckFailed('down'), saved: saved, now: _now),
            isA<OnionKept>());
      }
    });

    test('ONION-003: a site that stops announcing is forgotten', () {
      expect(learnFrom(const NothingAnnounced(), saved: _saved(), now: _now),
          isA<OnionForgotten>());
      expect(learnFrom(const NothingAnnounced(), saved: null, now: _now),
          isA<OnionKept>());
    });

    test('ONION-008: the same address is checked again without asking', () {
      final learned = learnFrom(OnionAnnounced(_endpoint),
              saved: _saved(
                  fallback: OnionFallback.clearnet,
                  age: const Duration(days: 40)),
              now: _now)
          as OnionLearned;
      expect(learned.asks, isFalse);
      expect(learned.onion.checked, _now);
      expect(learned.onion.answer, OnionAnswer.accepted);
      expect(learned.onion.fallback, OnionFallback.clearnet);
    });

    test('a declined address stays declined, an unanswered one asks again',
        () {
      expect(
          (learnFrom(OnionAnnounced(_endpoint),
                  saved: _saved(answer: OnionAnswer.declined), now: _now)
              as OnionLearned)
              .asks,
          isFalse);
      expect(
          (learnFrom(OnionAnnounced(_endpoint),
                  saved: _saved(answer: null), now: _now) as OnionLearned)
              .asks,
          isTrue);
    });

    test('a new address asks, keeping the fallback chosen', () {
      final other = OnionEndpoint.of(
          from: 'https://proton.me', to: 'http://$_torProject/')!;
      final learned = learnFrom(OnionAnnounced(other),
          saved: _saved(fallback: OnionFallback.clearnet), now: _now)
          as OnionLearned;
      expect(learned.asks, isTrue);
      expect(learned.onion.endpoint, other);
      expect(learned.onion.fallback, OnionFallback.clearnet);
      expect(
          (learnFrom(OnionAnnounced(_endpoint), saved: null, now: _now)
                  as OnionLearned)
              .onion
              .fallback,
          OnionFallback.none);
    });
  });
}
