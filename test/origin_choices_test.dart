import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/settings/origin_choices.dart';
import 'package:webspace/settings/site_field.dart';
import 'package:webspace/settings/site_permission_state.dart';
import 'package:webspace/settings_import_engine.dart';
import 'package:webspace/web_view_model.dart';

const _a = 'https://a.example';
const _b = 'https://b.example';

/// What other origins inside a site were answered (PERM-002): kept per
/// capability, saved with the site, never carried off the device.
void main() {
  final some = OriginChoices.none
      .remember(SitePermission.camera, origin: _a, allowed: true)
      .remember(SitePermission.camera, origin: _b, allowed: false)
      .remember(SitePermission.location, origin: _a, allowed: false);

  group('OriginChoices', () {
    test('an answer is kept per capability and origin', () {
      expect(some.of(SitePermission.camera, origin: _a), isTrue);
      expect(some.of(SitePermission.camera, origin: _b), isFalse);
      expect(some.of(SitePermission.location, origin: _a), isFalse);
      expect(some.of(SitePermission.microphone, origin: _a), isNull);
      expect(some.listed(SitePermission.camera).keys, [_a, _b]);
    });

    test('a flipped answer keeps its place in the list', () {
      final flipped =
          some.remember(SitePermission.camera, origin: _a, allowed: false);
      expect(flipped.listed(SitePermission.camera), {_a: false, _b: false});
    });

    test('forget drops one origin, or every origin of a capability', () {
      expect(some.forget(SitePermission.camera, origin: _a)
          .listed(SitePermission.camera), {_b: false});
      final gone = some.forget(SitePermission.camera);
      expect(gone.listed(SitePermission.camera), isEmpty);
      expect(gone.of(SitePermission.location, origin: _a), isFalse);
      expect(OriginChoices.none
          .remember(SitePermission.camera, origin: _a, allowed: true)
          .forget(SitePermission.camera, origin: _a), OriginChoices.none);
    });

    test('a move of the site to Block or Ask forgets that capability', () {
      for (final to in [SitePermissionState.blocked, SitePermissionState.ask]) {
        expect(
            some
                .afterModeChange(SitePermission.camera,
                    from: SitePermissionState.allowed, to: to)
                .listed(SitePermission.camera),
            isEmpty,
            reason: '$to');
      }
      for (final to in [
        SitePermissionState.allowed,
        SitePermissionState.simulated,
      ]) {
        expect(
            some.afterModeChange(SitePermission.camera,
                from: SitePermissionState.ask, to: to),
            some,
            reason: '$to keeps what was answered');
      }
      expect(
          some.afterModeChange(SitePermission.camera,
              from: SitePermissionState.ask, to: SitePermissionState.ask),
          some,
          reason: 'no move, nothing forgotten');
    });

    test('JSON round-trips, and a wrong-typed entry reads as absent', () {
      expect(OriginChoices.fromJson(some.toJson()), some);
      expect(
          OriginChoices.fromJson({
            'camera': {_a: true, _b: 'yes', 3: false},
            'telepathy': {_a: true},
            'location': 'everywhere',
          }),
          OriginChoices.none
              .remember(SitePermission.camera, origin: _a, allowed: true));
      expect(OriginChoices.fromJson(null), OriginChoices.none);
    });
  });

  group('a site carries its origin choices', () {
    WebViewModel site() =>
        WebViewModel(initUrl: 'https://site.example')..originChoices = some;

    test("in the site's own JSON", () {
      final json = site().toJson();
      expect(WebViewModel.fromJson(json, stateSetterF: () {}).originChoices,
          some);
    });

    test('never in a backup (PERM-002)', () {
      expect(SiteField.originChoices.backup, BackupShare.withheld);
      final backup = SettingsBackupService.createBackup(
        webViewModels: [site()],
        webspaces: const [],
        themeMode: 0,
      );
      expect(backup.sites.single.containsKey(SiteField.originChoices.key),
          isFalse);
      expect(backup.toJson().toString(), isNot(contains(_a)));
    });

    test('never in a QR share', () {
      expect(SiteField.originChoices.qr, QrShare.withheld);
    });

    test('dropped from a hand-written backup on import', () {
      final imported = site();
      sanitizeImportedSites([imported], globalScripts: const []);
      expect(imported.originChoices, OriginChoices.none);
    });
  });
}
