import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

const _camSrc = VirtualVisualSource(
  kind: 'image',
  dataUrl: 'data:image/png;base64,AAAA',
  fileName: 'qr.png',
);
const _micSrc = VirtualAudioSource(
  dataUrl: 'data:audio/mpeg;base64,AAAA',
  fileName: 'tone.mp3',
);

/// A site whose every stored choice differs from what Tracking Protection or
/// the archive tier would force, so each forced field shows up as a change.
WebViewModel _site({required bool tp, required bool archived}) {
  final m = WebViewModel(
    initUrl: 'https://bank.example',
    siteId: 'site-a',
    trackingProtectionEnabled: tp,
    isArchiveTier: archived,
    clearUrlEnabled: false,
    dnsBlockEnabled: false,
    dnsBlockLevel: 2,
    contentBlockEnabled: false,
    localCdnEnabled: false,
    thirdPartyCookiesEnabled: true,
    httpsUpgradeEnabled: false,
    incognito: false,
    notificationsEnabled: true,
    protectedContentAllowed: true,
    captures: const CaptureGrants(
      camera: (mode: CameraAccessMode.virtual, source: _camSrc),
      microphone: (mode: MicrophoneAccessMode.real, source: _micSrc),
      screenShare: (mode: ScreenShareMode.ask, source: null),
    ),
    externalLinkMode: ExternalLinkMode.browser,
    proxySettings: UserProxySettings(
      type: ProxyType.SOCKS5,
      address: '127.0.0.1:1080',
    ),
    spoofLatitude: 52.52,
    spoofLongitude: 13.405,
    spoofTimezone: 'Europe/Berlin',
    language: 'de',
    zoomPercent: 125,
  );
  if (archived) m.archiveContainerId = 'opaque-a';
  return m;
}

SitePosture _posture(WebViewModel m) =>
    m.sitePosture(globalUserScripts: const <UserScriptConfig>[]);

void main() {
  group('Tracking Protection x tier', () {
    for (final tp in [false, true]) {
      for (final archived in [false, true]) {
        final cell = 'tp=$tp archived=$archived';

        test('$cell: blockers are forced on by TP only (ETP-002, ETP-030)', () {
          final b = _posture(_site(tp: tp, archived: archived)).blocking;
          expect(b.clearUrls, tp, reason: cell);
          expect(b.dns, tp, reason: cell);
          expect(b.contentBlock, tp, reason: cell);
          expect(b.localCdn, tp && !archived, reason: cell);
          expect(b.httpsUpgrade, tp, reason: cell);
          expect(b.dnsLevel, archived ? isNull : 2, reason: cell);
          expect(b.contributesStats, !archived, reason: cell);
        });

        test(
          '$cell: container follows tier and TP (ETP-024, ARCH-006/007)',
          () {
            final c = _posture(_site(tp: tp, archived: archived)).container;
            expect(c.incognito, archived, reason: cell);
            expect(
              c.archiveContainerId,
              archived ? 'opaque-a' : isNull,
              reason: cell,
            );
            expect(c.thirdPartyCookies, !tp, reason: cell);
            expect(
              c.httpAuthMemory,
              archived ? HttpAuthMemory.off : HttpAuthMemory.readWrite,
              reason: cell,
            );
            expect(c.passkeys, !archived, reason: cell);
          },
        );

        test(
          '$cell: media and page follow tier and TP (ETP-023, ARCH-006)',
          () {
            final p = _posture(_site(tp: tp, archived: archived));
            expect(
              p.media.protectedContent,
              (tp || archived) ? isFalse : isTrue,
              reason: cell,
            );
            expect(
              p.media.capture.camera.mode,
              archived ? CameraAccessMode.block : CameraAccessMode.virtual,
              reason: cell,
            );
            expect(
              p.media.capture.microphone.mode,
              archived ? MicrophoneAccessMode.block : MicrophoneAccessMode.real,
              reason: cell,
            );
            expect(
              p.media.capture.screenShare.mode,
              archived ? ScreenShareMode.block : ScreenShareMode.ask,
              reason: cell,
            );
            expect(p.page.notifications, !archived, reason: cell);
            expect(
              p.page.externalLinks,
              archived ? ExternalLinkMode.inApp : ExternalLinkMode.browser,
              reason: cell,
            );
            expect(
              p.location.webRtc,
              tp ? WebRtcPolicy.relayOnly : WebRtcPolicy.defaultPolicy,
              reason: cell,
            );
          },
        );
      }
    }
  });

  test('LocalCDN follows the site\'s own choice without TP (LCDN-007)', () {
    final on = _site(tp: false, archived: false)..localCdnEnabled = true;
    expect(_posture(on).blocking.localCdn, isTrue);
    expect(_posture(on).forNested().blocking.localCdn, isTrue);
    final archivedOn = _site(tp: false, archived: true)..localCdnEnabled = true;
    expect(_posture(archivedOn).blocking.localCdn, isFalse);
  });

  group('a nested screen runs under the opening site\'s posture', () {
    test('everything but the capture grants is the root\'s, unchanged', () {
      for (final tp in [false, true]) {
        for (final archived in [false, true]) {
          final root = _posture(_site(tp: tp, archived: archived));
          final nested = root.forNested();
          expect(nested.siteId, root.siteId);
          expect(nested.container, root.container);
          expect(nested.blocking, root.blocking);
          expect(nested.fingerprint, root.fingerprint);
          expect(nested.location, root.location);
          expect(nested.page, root.page);
          expect(nested.media.capture.screenShare,
              root.media.capture.screenShare);
          expect(nested.media.protectedContent, root.media.protectedContent);
        }
      }
    });

    test('a real capture grant is asked again, others are inherited '
        '(CAM-005, MIC-005, SEC-007)', () {
      final root = _posture(_site(tp: false, archived: false));
      final nested = root.forNested();
      expect(root.media.capture.microphone.mode, MicrophoneAccessMode.real);
      expect(nested.media.capture.microphone.mode, MicrophoneAccessMode.ask);
      expect(nested.media.capture.microphone.source, same(_micSrc));
      expect(nested.media.capture.camera.mode, CameraAccessMode.virtual);
      expect(nested.media.capture.camera.source, same(_camSrc));

      for (final mode in CameraAccessMode.values) {
        final p = _posture(
          WebViewModel(
            initUrl: 'https://cam.example',
            captures: CaptureGrants.none.copyWith(
              camera: (mode: mode, source: null),
            ),
          ),
        ).forNested();
        expect(
          p.media.capture.camera.mode,
          mode == CameraAccessMode.real ? CameraAccessMode.ask : mode,
        );
      }
    });

    test('TP with picked coordinates keeps the resolved zone one hop out '
        '(BUG-025)', () {
      final root = _posture(_site(tp: true, archived: false));
      expect(root.location.timezone, 'Europe/Berlin');
      expect(root.forNested().location.timezone, 'Europe/Berlin');
    });

    test('an opted-in global script reaches the nested screen too', () {
      final global = UserScriptConfig(
        id: 'g1',
        name: 'global',
        source: 'void 0',
        enabled: false,
      );
      final m = WebViewModel(initUrl: 'https://a.example')
        ..enabledGlobalScriptIds = {'g1'};
      final scripts = m
          .sitePosture(globalUserScripts: [global])
          .forNested()
          .page
          .userScripts;
      expect(scripts.single.id, 'g1');
      expect(scripts.single.enabled, isTrue);
    });

    test('an opted-in global script keeps every field but enabled', () {
      // A field-by-field copy dropped bypassSitePolicy, so a global script
      // that needs the privileged bridge ran without it on every site.
      final global = UserScriptConfig(
        id: 'g1',
        name: 'global',
        source: 'void 0',
        url: 'https://cdn.example/lib.js',
        urlSource: 'lib()',
        injectionTime: UserScriptInjectionTime.atDocumentStart,
        enabled: false,
        bypassSitePolicy: true,
      );
      final m = WebViewModel(initUrl: 'https://a.example')
        ..enabledGlobalScriptIds = {'g1'};
      final script =
          m.sitePosture(globalUserScripts: [global]).page.userScripts.single;
      expect(script.toJson(), {...global.toJson(), 'enabled': true});
    });
  });

  test('a posture is only ever resolved, never assembled by hand', () {
    // Anything else building one could hand a webview a raw stored value
    // that the resolver would have overridden.
    final builders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final n = RegExp(r'\bSitePosture\(').allMatches(f.readAsStringSync());
      for (var i = 0; i < n.length; i++) {
        builders.add(f.path.replaceAll(r'\', '/'));
      }
    }
    builders.sort();
    expect(builders, [
      'lib/services/site_posture.dart', // the constructor
      'lib/services/site_posture.dart', // forNested
      'lib/web_view_model.dart', // sitePosture
    ]);
  });
}
