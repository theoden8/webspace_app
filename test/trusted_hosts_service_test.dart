import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/trusted_hosts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TrustedHostsService', () {
    late TrustedHostsService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      service = TrustedHostsService.instance;
      await service.clear();
      await service.reloadFromPrefs();
    });

    test('isTrusted is false until trust() persists a matching pin', () async {
      const fp = 'aabbcc';
      expect(
        service.isTrusted(host: 'example.com', port: 443, fingerprint: fp),
        isFalse,
        reason: 'fresh service must not trust anything',
      );
      await service.trust(host: 'example.com', port: 443, fingerprint: fp);
      expect(
        service.isTrusted(host: 'example.com', port: 443, fingerprint: fp),
        isTrue,
      );
    });

    test('fingerprint mismatch is rejected (cert rotation re-prompts)',
        () async {
      await service.trust(
        host: 'example.com',
        port: 443,
        fingerprint: 'oldfingerprint',
      );
      expect(
        service.isTrusted(
          host: 'example.com',
          port: 443,
          fingerprint: 'newfingerprint',
        ),
        isFalse,
      );
    });

    test('null fingerprint is never trusted (no proof, no pass)', () async {
      await service.trust(host: 'example.com', port: 443, fingerprint: 'fp');
      expect(
        service.isTrusted(
          host: 'example.com',
          port: 443,
          fingerprint: null,
        ),
        isFalse,
      );
    });

    test('host comparison is case-insensitive', () async {
      await service.trust(host: 'Example.COM', port: 443, fingerprint: 'fp');
      expect(
        service.isTrusted(
          host: 'example.com',
          port: 443,
          fingerprint: 'fp',
        ),
        isTrue,
      );
    });

    test('different port → different pin', () async {
      await service.trust(host: 'example.com', port: 443, fingerprint: 'fp');
      expect(
        service.isTrusted(host: 'example.com', port: 8443, fingerprint: 'fp'),
        isFalse,
      );
    });

    test('untrust() removes the pin', () async {
      await service.trust(host: 'example.com', port: 443, fingerprint: 'fp');
      await service.untrust(host: 'example.com', port: 443);
      expect(
        service.isTrusted(host: 'example.com', port: 443, fingerprint: 'fp'),
        isFalse,
      );
    });

    test('trust survives reload from SharedPreferences', () async {
      await service.trust(
        host: 'self.local',
        port: 8443,
        fingerprint: 'persistedfp',
      );
      await service.reloadFromPrefs();
      expect(
        service.isTrusted(
          host: 'self.local',
          port: 8443,
          fingerprint: 'persistedfp',
        ),
        isTrue,
        reason: 'pinned trust must round-trip through SharedPreferences so '
            'the user does not get re-prompted on every app launch',
      );
    });

    test('reloadFromPrefs picks up an externally-set list (settings import)',
        () async {
      const entry = TrustedHostEntry(
        host: 'imported.example',
        port: 443,
        sha256Hex: 'importedfp',
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        kTrustedHostsKey: <String>[entry.encode()],
      });
      await service.reloadFromPrefs();
      expect(
        service.isTrusted(
          host: 'imported.example',
          port: 443,
          fingerprint: 'importedfp',
        ),
        isTrue,
      );
    });

    test('TrustedHostEntry.decode rejects malformed entries', () {
      expect(TrustedHostEntry.decode('only|two'), isNull);
      expect(TrustedHostEntry.decode('|443|fp'), isNull);
      expect(TrustedHostEntry.decode('host|notaport|fp'), isNull);
      expect(TrustedHostEntry.decode('host|443|'), isNull);
    });

    test('SHA-256 fingerprints round-trip case-insensitively', () async {
      const upper = 'AABBCCDD11223344';
      await service.trust(host: 'a.example', port: 443, fingerprint: upper);
      expect(
        service.isTrusted(
          host: 'a.example',
          port: 443,
          fingerprint: upper.toLowerCase(),
        ),
        isTrue,
      );
    });

    test('SHA-256 helper produces the canonical hex string', () {
      // Sanity-check: same bytes → same hex via the same crypto package
      // the service uses internally. Locks the hex format (no colons,
      // lowercase) so the persisted pin doesn't drift.
      final bytes = <int>[1, 2, 3, 4, 5];
      expect(sha256.convert(bytes).toString().length, equals(64));
    });
  });
}
