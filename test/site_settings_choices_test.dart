import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/screens/site_behaviour.dart';
import 'package:webspace/screens/site_network.dart';
import 'package:webspace/screens/site_permissions.dart';
import 'package:webspace/screens/site_privacy.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/filter_list_id.dart';
import 'package:webspace/settings/network_interface.dart';
import 'package:webspace/settings/origin_choices.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/proxy_ids.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/dirty_guard.dart';

import 'helpers/isolations.dart';
import 'helpers/localized.dart';

/// Each edit [edits] names changes its record ([R]'s `==` sees it, so the
/// settings screen's snapshot does), and the model stores it and reads it
/// back, so a save keeps it.
void _eachEdit<R>({
  required R Function(WebViewModel) read,
  required void Function(WebViewModel, {required R choices}) write,
  required Map<String, R Function(R)> edits,
}) {
  for (final MapEntry(key: field, value: edit) in edits.entries) {
    final site = WebViewModel(initUrl: 'https://example.com/');
    final before = read(site);
    final after = edit(before);
    expect(after, isNot(before), reason: '$field: the record compares it');
    write(site, choices: after);
    expect(read(site), after, reason: '$field: the model stores it');
  }
}

/// The settings screen's dirty snapshot holds each Site screen's choices as
/// one record, so an edit to any field of it makes the screen dirty, which a
/// hand-kept list of fields did not do for kiosk mode or the Tor exit
/// country (EDIT-009, BUG-006).
void main() {
  setUpAll(() => SharedPreferences.setMockInitialValues({}));

  group('every field of a choices record counts and is saved (EDIT-009)', () {
    test('privacy', () {
      _eachEdit<PrivacyChoices>(
        read: (m) => m.privacyChoices,
        write: (m, {required choices}) => m.privacyChoices = choices,
        edits: {
          'trackingProtectionEnabled': (c) => c.copyWith(
              trackingProtectionEnabled: !c.trackingProtectionEnabled),
          'clearUrlEnabled': (c) =>
              c.copyWith(clearUrlEnabled: !c.clearUrlEnabled),
          'dnsBlockEnabled': (c) =>
              c.copyWith(dnsBlockEnabled: !c.dnsBlockEnabled),
          'dnsBlockLevel': (c) => c.copyWith(dnsBlockLevel: const Own(3)),
          'contentBlockEnabled': (c) =>
              c.copyWith(contentBlockEnabled: !c.contentBlockEnabled),
          'disabledFilterLists': (c) => c.copyWith(
              disabledFilterLists: ValueSet({FilterListId('easylist')})),
          'localCdnEnabled': (c) =>
              c.copyWith(localCdnEnabled: !c.localCdnEnabled),
          'thirdPartyCookiesEnabled': (c) => c.copyWith(
              thirdPartyCookiesEnabled: !c.thirdPartyCookiesEnabled),
          'httpsUpgrade': (c) => c.copyWith(httpsUpgrade: const Own(false)),
          'lockdownMode': (c) => c.copyWith(lockdownMode: const Own(true)),
          'letterboxEnabled': (c) =>
              c.copyWith(letterboxEnabled: !c.letterboxEnabled),
          'incognito': (c) => c.copyWith(incognito: !c.incognito),
          'blockScreenshots': (c) =>
              c.copyWith(blockScreenshots: !c.blockScreenshots),
          'javascriptEnabled': (c) =>
              c.copyWith(javascriptEnabled: !c.javascriptEnabled),
        },
      );
    });

    test('behaviour', () {
      _eachEdit<BehaviourChoices>(
        read: (m) => m.behaviourChoices,
        write: (m, {required choices}) => m.behaviourChoices = choices,
        edits: {
          'alwaysOpenHome': (c) =>
              c.copyWith(alwaysOpenHome: !c.alwaysOpenHome),
          'kioskMode': (c) => c.copyWith(kioskMode: !c.kioskMode),
          'fullscreenMode': (c) =>
              c.copyWith(fullscreenMode: !c.fullscreenMode),
          'tabsEnabled': (c) => c.copyWith(tabsEnabled: const Own(false)),
          'htmlCachingEnabled': (c) =>
              c.copyWith(htmlCachingEnabled: !c.htmlCachingEnabled),
          'externalLinkMode': (c) =>
              c.copyWith(externalLinkMode: const Own(ExternalLinkMode.block)),
          'routeOutboundLinks': (c) =>
              c.copyWith(routeOutboundLinks: !c.routeOutboundLinks),
          'outboundPreferences': (c) => c.copyWith(
                outboundPreferences: ValueList([
                  OutboundPreference(
                    claim: DomainClaim.exactHost('github.com'),
                    targetSiteId: SiteId('gh'),
                  ),
                ]),
              ),
          'signInPopups': (c) => c.copyWith(signInPopups: const Own(false)),
          'searchAddress': (c) =>
              c.copyWith(searchAddress: ('https://example.com/?q=%s',)),
          'searchesWeb': (c) => c.copyWith(searchesWeb: !c.searchesWeb),
          'searchSites': (c) =>
              c.copyWith(searchSites: ValueList([SiteId('gh')])),
          'searchDefault': (c) =>
              c.copyWith(searchDefault: Own(SiteId('gh'))),
        },
      );
    });

    test('permissions', () {
      _eachEdit<PermissionChoices>(
        read: (m) => m.permissionChoices,
        write: (m, {required choices}) => m.permissionChoices = choices,
        edits: {
          'captures': (c) => c.copyWith(
              captures: c.captures.copyWith(
                  camera: (mode: CameraAccessMode.block, source: null))),
          'originChoices': (c) => c.copyWith(
              originChoices: c.originChoices.remember(SitePermission.camera,
                  origin: 'https://player.example', allowed: true)),
          'notificationsEnabled': (c) =>
              c.copyWith(notificationsEnabled: !c.notificationsEnabled),
          'backgroundAudioEnabled': (c) =>
              c.copyWith(backgroundAudioEnabled: !c.backgroundAudioEnabled),
          'protectedContentAllowed': (c) =>
              c.copyWith(protectedContentAllowed: (false,)),
          'liveLocationGranularity': (c) => c.copyWith(
              liveLocationGranularity: LocationGranularity.gsm),
          'spoofTimezone': (c) =>
              c.copyWith(spoofTimezone: ('Europe/Paris',)),
          'spoofTimezoneFromLocation': (c) => c.copyWith(
              spoofTimezoneFromLocation: !c.spoofTimezoneFromLocation),
        },
      );
    });

    test('network: each field counts, and the route lands on the proxy', () {
      final NetworkChoices base = (
        proxyType: ProxyType.DEFAULT,
        torExitCountry: null,
        savedProxyId: null,
        gatewayId: null,
        credentialsId: null,
        leavesBy: const SystemRouting(),
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      final edits = <String, NetworkChoices>{
        'proxyType': base.copyWith(proxyType: ProxyType.TOR),
        'torExitCountry': base.copyWith(torExitCountry: ('de',)),
        'savedProxyId': base.copyWith(savedProxyId: (SavedProxyId('work'),)),
        'gatewayId': base.copyWith(gatewayId: (GatewayId('de'),)),
        'credentialsId': base.copyWith(credentialsId: (CredentialsId('mail'),)),
        'leavesBy': base.copyWith(
            leavesBy: NamedInterface(InterfaceName.parse('wg0')!)),
        'webRtcPolicy': base.copyWith(webRtcPolicy: WebRtcPolicy.disabled),
      };
      final stored = UserProxySettings(type: ProxyType.DEFAULT);
      for (final MapEntry(key: field, value: after) in edits.entries) {
        expect(after, isNot(base), reason: '$field: the record compares it');
        final proxy = after.over(stored);
        expect(
          (
            proxy.type,
            proxy.torExitCountry,
            proxy.savedProxyId,
            proxy.gatewayId,
            proxy.credentialsId,
            proxy.leavesBy,
          ),
          (
            after.proxyType,
            after.torExitCountry,
            after.savedProxyId,
            after.gatewayId,
            after.credentialsId,
            after.leavesBy,
          ),
          reason: '$field: the route carries it',
        );
      }
    });
  });

  // The edit BUG-006 shipped without a prompt (#454): kiosk mode alone.
  testWidgets('kiosk mode alone makes the settings screen ask on back',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final site = WebViewModel(initUrl: 'https://example.org/');
    await tester.pumpWidget(localizedApp(Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => SettingsScreen(
              webViewModel: site,
              appTheme: WebViewTheme.system,
              letGo: () {},
              isolation: fakeSharedJar(),
            ),
          ),
        ),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Behaviour'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.ancestor(
            of: find.text('Kiosk mode'), matching: find.byType(ListTile)),
        matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    expect(site.kioskMode, isFalse);
  });
}
