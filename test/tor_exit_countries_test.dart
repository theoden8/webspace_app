// The exit-country shortlist and its round trip through the stored pin.
// Spec: openspec/changes/add-ios-tor-proxy/specs/tor-proxy/spec.md (TOR-014).

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/tor_exit_countries.dart';

void main() {
  group('the shortlist itself', () {
    test('every code is a well-formed lowercase alpha-2', () {
      for (final c in kTorExitCountries) {
        expect(c.code, matches(RegExp(r'^[a-z]{2}$')),
            reason: '"${c.code}" is not a lowercase ISO 3166-1 alpha-2 code');
      }
    });

    test('no country appears twice', () {
      final codes = kTorExitCountries.map((c) => c.code).toList();
      expect(codes.toSet().length, codes.length);
    });

    test('every entry has a non-empty endonym', () {
      for (final c in kTorExitCountries) {
        expect(c.endonym.trim(), isNotEmpty, reason: c.code);
      }
    });

    test('every code survives the trip into tor ExitNodes syntax', () {
      // The shortlist is useless if an entry the picker offers is one the
      // validator then drops: the user would set a country and get no pin.
      for (final c in kTorExitCountries) {
        final settings =
            UserProxySettings(type: ProxyType.TOR, torExitCountry: c.code);
        expect(settings.exitNodesValue, '{${c.code}}', reason: c.code);
      }
    });
  });

  group('flag derivation', () {
    test('maps the code onto regional indicators', () {
      // U+1F1E9 U+1F1EA is the pair for "DE".
      expect(const TorExitCountry('de', 'Deutschland').flag.runes.toList(),
          [0x1F1E9, 0x1F1EA]);
    });

    test('is case-insensitive about the stored code', () {
      expect(const TorExitCountry('DE', 'Deutschland').flag,
          const TorExitCountry('de', 'Deutschland').flag);
    });

    test('a malformed code yields no flag rather than garbage', () {
      expect(const TorExitCountry('deu', 'x').flag, '');
      expect(const TorExitCountry('', 'x').flag, '');
    });

    test('the label carries endonym and uppercase code', () {
      final label = const TorExitCountry('de', 'Deutschland').label;
      expect(label, contains('Deutschland'));
      expect(label, contains('(DE)'));
    });
  });

  group('torExitCountryFor', () {
    test('finds a listed country', () {
      expect(torExitCountryFor('de')?.endonym, 'Deutschland');
    });

    test('tolerates the case and whitespace a stored value may carry', () {
      expect(torExitCountryFor(' DE ')?.code, 'de');
    });

    test('null and empty mean unpinned, not "not found"', () {
      expect(torExitCountryFor(null), isNull);
      expect(torExitCountryFor(''), isNull);
    });

    test('an unlisted but valid country returns null without throwing', () {
      // Arrives from a backup written by a build with a longer list, or by
      // hand. The caller keeps the pin and shows the bare code; dropping it
      // would silently unpin a site the user pinned.
      expect(torExitCountryFor('mx'), isNull);
      expect(
        UserProxySettings(type: ProxyType.TOR, torExitCountry: 'mx')
            .exitNodesValue,
        '{mx}',
        reason: 'the pin still reaches tor even when the picker cannot name it',
      );
    });
  });
}
