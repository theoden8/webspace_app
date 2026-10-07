// Design-time gallery entrypoint. Not shipped: builds only for the web
// target, which exists so real widgets can be rendered in a browser and
// screenshotted. The native WebView never renders here; cards that need one
// draw a placeholder in its place.
//
//   flutter build web -t lib/design_gallery/main.dart
//   ?card=<id>&theme=light|dark&accent=<name>&locale=<code>
//
// Without ?card the page shows every card at once for human browsing.
// Workflow and constraints: tool/design_gallery/CLAUDE.md

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/proxy_library.dart';
import 'package:webspace/services/proxy_health_service.dart';
import 'package:webspace/services/proxy_test_service.dart';
import 'package:webspace/screens/saved_proxies.dart';
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/http_auth_prompt.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/http_auth_secure_storage.dart';
import 'package:webspace/services/url_host.dart';
import 'package:webspace/widgets/proxy_auth_section.dart';
import 'package:webspace/widgets/proxy_test_tile.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';
import 'package:webspace/widgets/unproxied_block.dart';
import 'package:webspace/demo_data.dart'
    show demoBlockStatsSiteNames, seedDemoBlockStats;
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/main.dart' show AppThemeSettings, AccentColor;
import 'package:webspace/screens/add_site.dart';
import 'package:webspace/screens/app_appearance.dart';
import 'package:webspace/screens/app_backup.dart';
import 'package:webspace/screens/app_behaviour.dart';
import 'package:webspace/screens/app_developer.dart';
import 'package:webspace/screens/app_network.dart';
import 'package:webspace/screens/app_privacy.dart';
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/screens/content_blocker_settings.dart';
import 'package:webspace/screens/block_stats.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/screens/location_picker.dart';
import 'package:webspace/screens/link_handling_settings.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/screens/site_behaviour.dart';
import 'package:webspace/screens/site_network.dart';
import 'package:webspace/screens/trusted_certificates.dart';
import 'package:webspace/screens/user_scripts.dart';
import 'package:webspace/screens/webspace_detail.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_info_sheet.dart';
import 'package:webspace/widgets/url_bar.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_return_engine.dart';
import 'package:webspace/widgets/tabs_sheet.dart';
import 'package:webspace/widgets/web_search_sheet.dart';
import 'package:webspace/widgets/search_site_picker.dart';
import 'package:webspace/widgets/datasets.dart';
import 'package:webspace/widgets/dataset_tile.dart';
import 'package:webspace/services/site_search_list_service.dart';
import 'package:webspace/services/web_search_engine.dart';

const Map<String, Color> galleryAccents = {
  'blue': accentBlue,
  'green': accentGreen,
  'purple': accentPurple,
  'orange': accentOrange,
  'red': accentRed,
  'pink': accentPink,
  'teal': accentTeal,
  'yellow': accentYellow,
};

class GalleryCard {
  const GalleryCard({
    required this.id,
    required this.label,
    required this.builder,
    this.fullBleed = false,
  });

  final String id;
  final String label;
  final WidgetBuilder builder;

  /// Whole screens bring their own Scaffold: no card padding, and a phone-sized
  /// frame on the index page.
  final bool fullBleed;
}

// Screens first: the app's own surfaces are what design review is about, and
// the element cards below exist to explain them.
final List<GalleryCard> galleryCards = [
  GalleryCard(id: 'user-scripts', label: 'User scripts screen', fullBleed: true, builder: (c) => const _UserScriptsCard()),
  GalleryCard(id: 'trusted-certificates', label: 'Trusted certificates screen', fullBleed: true, builder: (c) => const _TrustedCertificatesCard()),
  GalleryCard(id: 'location-picker', label: 'Location picker screen', fullBleed: true, builder: (c) => const _LocationPickerCard()),
  GalleryCard(id: 'webspaces', label: 'Webspaces screen', fullBleed: true, builder: (c) => const _WebspacesCard()),
  GalleryCard(id: 'webspace-detail', label: 'Webspace detail screen', fullBleed: true, builder: (c) => const _WebspaceDetailCard()),
  GalleryCard(id: 'site-settings', label: 'Site settings screen', fullBleed: true, builder: (c) => const _SiteSettingsCard()),
  GalleryCard(id: 'site-behaviour', label: 'Site behaviour screen', fullBleed: true, builder: (c) => const _SiteBehaviourCard()),
  GalleryCard(id: 'site-network', label: 'Site network screen', fullBleed: true, builder: (c) => const _SiteNetworkCard()),
  GalleryCard(id: 'site-network-saved', label: 'Site network screen, saved proxy', fullBleed: true, builder: (c) => const _SiteNetworkSavedCard()),
  GalleryCard(id: 'saved-proxies', label: 'Saved proxies screen', fullBleed: true, builder: (c) => const _SavedProxiesCard()),
  GalleryCard(id: 'saved-proxy-edit', label: 'Saved proxy form', fullBleed: true, builder: (c) => const _SavedProxyEditCard()),
  GalleryCard(id: 'saved-credentials-edit', label: 'Saved credentials form', fullBleed: true, builder: (c) => const _SavedCredentialsEditCard()),
  GalleryCard(id: 'app-settings', label: 'App settings screen', fullBleed: true, builder: (c) => const _AppSettingsCard()),
  GalleryCard(id: 'app-appearance', label: 'App appearance screen', fullBleed: true, builder: (c) => const _AppAppearanceCard()),
  GalleryCard(id: 'app-behaviour', label: 'App behaviour screen', fullBleed: true, builder: (c) => const _AppBehaviourCard()),
  GalleryCard(id: 'app-network', label: 'App network screen', fullBleed: true, builder: (c) => const AppNetworkScreen()),
  GalleryCard(id: 'app-privacy', label: 'App privacy screen', fullBleed: true, builder: (c) => const AppPrivacyScreen()),
  GalleryCard(id: 'app-content-blocker', label: 'Content blocker screen', fullBleed: true, builder: (c) => const ContentBlockerSettingsScreen()),
  GalleryCard(id: 'app-backup', label: 'Backup and archives screen', fullBleed: true, builder: (c) => const AppBackupScreen(offerRestoreArchive: true, offerCloseAllArchives: true)),
  GalleryCard(id: 'app-developer', label: 'Developer screen', fullBleed: true, builder: (c) => const AppDeveloperScreen(proxyRouterRunsHere: true)),
  GalleryCard(id: 'protection-report', label: 'Protection report screen', fullBleed: true, builder: (c) => const _ProtectionReportCard()),
  GalleryCard(id: 'protection-report-category', label: 'Protection report category', fullBleed: true, builder: (c) => const _ProtectionCategoryCard()),
  GalleryCard(id: 'add-site', label: 'Add site screen', fullBleed: true, builder: (c) => const _AddSiteCard()),
  GalleryCard(id: 'unproxied-block', label: 'Blocked navigation interstitial', fullBleed: true, builder: (c) => const _UnproxiedBlockCard()),
  GalleryCard(id: 'tabs-sheet', label: 'Tabs sheet', fullBleed: true, builder: (c) => const _TabsSheetCard()),
  GalleryCard(id: 'tabs-sheet-in-site', label: 'Tabs sheet, a site in other trees', fullBleed: true, builder: (c) => const _TabsSheetInSiteCard()),
  GalleryCard(id: 'tabs-sheet-way-back', label: 'Tabs sheet, after a jump to another tree', fullBleed: true, builder: (c) => const _TabsSheetWayBackCard()),
  GalleryCard(id: 'web-search-sheet', label: 'Web search sheet', fullBleed: true, builder: (c) => const _WebSearchSheetCard()),
  GalleryCard(id: 'web-search-empty', label: 'Web search sheet, no search sites', fullBleed: true, builder: (c) => const _WebSearchEmptyCard()),
  GalleryCard(id: 'web-search-default', label: 'Default search picker, two sites with one name', builder: (c) => const _WebSearchDefaultCard()),
  GalleryCard(id: 'site-search-list', label: 'Site search list row', builder: (c) => const _SiteSearchListCard()),
  GalleryCard(id: 'site-behaviour-search', label: 'Site behaviour, search learned from a SearXNG page', fullBleed: true, builder: (c) => const _SiteBehaviourSearchCard()),
  GalleryCard(id: 'color-roles', label: 'Color roles', builder: (c) => const _ColorRolesCard()),
  GalleryCard(id: 'type-scale', label: 'Type scale', builder: (c) => const _TypeScaleCard()),
  GalleryCard(id: 'radius-scale', label: 'Corner radii', builder: (c) => const _RadiusScaleCard()),
  GalleryCard(id: 'url-bar', label: 'URL bar', builder: (c) => const _UrlBarCard()),
  GalleryCard(id: 'site-info', label: 'Site info sheet', builder: (c) => const _SiteInfoCard()),
  GalleryCard(id: 'hint-button', label: 'Hint button', builder: (c) => const _HintButtonCard()),
  GalleryCard(id: 'proxy-auth', label: 'Proxy authentication + test', builder: (c) => const _ProxyAuthCard()),
  GalleryCard(id: 'http-auth', label: 'HTTP authentication sign-in', builder: (c) => const _HttpAuthCard()),
  GalleryCard(id: 'tab-corner-button', label: 'Tab corner button', builder: (c) => const _TabCornerCard()),
  GalleryCard(id: 'browser-chrome', label: 'Browser chrome', builder: (c) => const _BrowserChromeCard()),
];

/// CanvasKit pulls Roboto from fonts.gstatic.com; where that is unreachable it
/// draws no text at all. Serve it from web/fonts (see sync_fonts.js) instead.
Future<void> _loadRoboto() async {
  const faces = ['Roboto_400Regular', 'Roboto_500Medium', 'Roboto_700Bold'];
  final loader = FontLoader('Roboto');
  var loaded = 0;
  for (final face in faces) {
    try {
      final res = await http.get(Uri.parse('fonts/$face.ttf'));
      if (res.statusCode != 200) continue;
      loader.addFont(Future.value(ByteData.sublistView(res.bodyBytes)));
      loaded++;
    } catch (_) {}
  }
  if (loaded > 0) await loader.load();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _loadRoboto();
  _seedSavedProxies();
  _seedAppPrefs();
  final q = Uri.base.queryParameters;
  runApp(GalleryApp(
    cardId: q['card'],
    brightness: q['theme'] == 'dark' ? Brightness.dark : Brightness.light,
    accent: galleryAccents[q['accent']] ?? accentBlue,
    localeCode: q['locale'],
  ));
}

/// A library with one of each shape: a plain proxy with both halves typed
/// (the 1-1 case), a saved proxy built from a shared gateway and credentials,
/// and a second login on that gateway for a site to pick directly. The probe
/// is simulated: a browser cannot send a request through a proxy, so the real
/// one would report every proxy unreachable.
ProxyLibraryData _demoLibrary() => ProxyLibraryData(
      gateways: [
        SavedGateway(
            id: 'gw-us',
            name: 'Work VPN US',
            type: ProxyType.SOCKS5,
            address: 'us.gw.example:1080'),
        SavedGateway(
            id: 'gw-de',
            name: 'Work VPN DE',
            type: ProxyType.SOCKS5,
            address: 'de.gw.example:1080'),
      ],
      credentials: [
        SavedCredentials(
            id: 'cr-alice',
            name: 'Alice',
            username: 'alice',
            password: 'hunter2',
            gatewayIds: {'gw-us', 'gw-de'}),
        SavedCredentials(
            id: 'cr-mail',
            name: 'Mail session',
            username: 'alice-session-mail',
            password: 'hunter2',
            gatewayIds: {'gw-de'}),
      ],
      proxies: [
        SavedProxy(
          id: 'px-work',
          name: 'Work VPN',
          settings: UserProxySettings(
              type: ProxyType.GATEWAY,
              gatewayId: 'gw-us',
              credentialsId: 'cr-alice'),
        ),
        SavedProxy(
          id: 'px-office',
          name: 'Office proxy',
          settings: UserProxySettings(
              type: ProxyType.HTTP,
              address: 'proxy.corp.example:3128',
              username: 'alice'),
        ),
        SavedProxy(
          id: 'px-home',
          name: 'Home router',
          settings: UserProxySettings(
              type: ProxyType.HTTPS, address: '203.0.113.7:8443'),
        ),
      ],
    );

void _seedSavedProxies() {
  ProxyLibrary.setInMemory(_demoLibrary());
  ProxyHealthService.instance = ProxyHealthService(probe: (s) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return switch (s.address) {
      'us.gw.example:1080' || 'de.gw.example:1080' =>
        const ProxyTestResult(ProxyTestOutcome.reachable, statusCode: 200),
      'proxy.corp.example:3128' =>
        const ProxyTestResult(ProxyTestOutcome.authRejected, statusCode: 407),
      _ => const ProxyTestResult(ProxyTestOutcome.unreachable,
          detail: 'Connection refused'),
    };
  });
}

class _DemoLibraryStore extends ProxyLibraryStore {
  const _DemoLibraryStore();

  @override
  Future<void> save(ProxyLibraryData data) async =>
      ProxyLibrary.setInMemory(data);
}

/// The real Saved proxies screen: three saved proxies, each showing a
/// different answer from the connection indicator, and the gateways and
/// credentials they share.
class _SavedProxiesCard extends StatelessWidget {
  const _SavedProxiesCard();

  @override
  Widget build(BuildContext context) => ProxyLibraryScreen(
        siteProxies: () => [
          for (var i = 0; i < 3; i++)
            UserProxySettings(type: ProxyType.SAVED, savedProxyId: 'px-work'),
          UserProxySettings(
              type: ProxyType.GATEWAY,
              gatewayId: 'gw-de',
              credentialsId: 'cr-mail'),
          UserProxySettings(type: ProxyType.SAVED, savedProxyId: 'px-office'),
        ],
        appWideProxy: () =>
            UserProxySettings(type: ProxyType.SAVED, savedProxyId: 'px-work'),
        onChanged: () {},
        store: const _DemoLibraryStore(),
      );
}

/// The form for a saved proxy made of a saved gateway and saved credentials.
class _SavedProxyEditCard extends StatelessWidget {
  const _SavedProxyEditCard();

  @override
  Widget build(BuildContext context) {
    final lib = _demoLibrary();
    return SavedProxyEditScreen(
      initial: lib.proxies.first,
      library: lib,
      usageCount: 3,
      usedByAppWide: true,
    );
  }
}

/// The form for credentials, ticked for the gateways they sign in on.
class _SavedCredentialsEditCard extends StatelessWidget {
  const _SavedCredentialsEditCard();

  @override
  Widget build(BuildContext context) {
    final lib = _demoLibrary();
    return SavedCredentialsEditScreen(
      initial: lib.credentials.last,
      gateways: lib.gateways,
      usageCount: 1,
    );
  }
}

/// The per-site Network screen for a site on a saved gateway with saved
/// credentials: the picker names the gateway, the row under it shows the
/// route and whether it answers, and the credentials picker offers only the
/// credentials that list this gateway.
class _SiteNetworkSavedCard extends StatefulWidget {
  const _SiteNetworkSavedCard();

  @override
  State<_SiteNetworkSavedCard> createState() => _SiteNetworkSavedCardState();
}

class _SiteNetworkSavedCardState extends State<_SiteNetworkSavedCard> {
  final model =
      WebViewModel(initUrl: 'https://mail.example.com/', name: 'Mail');
  final address = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();

  @override
  void dispose() {
    address.dispose();
    username.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SiteNetworkScreen(
        host: 'mail.example.com',
        siteId: model.siteId,
        values: const SiteNetworkValues(
          proxyType: ProxyType.GATEWAY,
          gatewayId: 'gw-de',
          credentialsId: 'cr-mail',
          webRtcPolicy: WebRtcPolicy.relayOnly,
        ),
        onChanged: (_) {},
        proxySupported: true,
        proxyAddressController: address,
        proxyUsernameController: username,
        proxyPasswordController: password,
        showSavedSignIns: false,
      );
}

class GalleryApp extends StatelessWidget {
  const GalleryApp({
    super.key,
    this.cardId,
    this.brightness = Brightness.light,
    this.accent = accentBlue,
    this.localeCode,
  });

  final String? cardId;
  final Brightness brightness;
  final Color accent;
  final String? localeCode;

  @override
  Widget build(BuildContext context) {
    final scheme = buildAccentColorScheme(accent, brightness);
    final single = cardId == null
        ? null
        : galleryCards.where((c) => c.id == cardId).firstOrNull;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: localeCode == null ? null : Locale(localeCode!),
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor:
            brightness == Brightness.light ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
      ),
      home: single == null
          ? const _GalleryIndex()
          : single.fullBleed
              ? single.builder(context)
              : Scaffold(body: SafeArea(child: Padding(padding: const EdgeInsets.all(16), child: single.builder(context)))),
    );
  }
}

class _GalleryIndex extends StatelessWidget {
  const _GalleryIndex();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('WebSpace design gallery'),
        backgroundColor: theme.colorScheme.primaryContainer,
        foregroundColor: theme.colorScheme.onPrimaryContainer,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Wrap(
          spacing: 24,
          runSpacing: 24,
          children: [
            for (final card in galleryCards)
              SizedBox(
                width: 460,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(card.label, style: theme.textTheme.titleSmall),
                    Text('?card=${card.id}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: theme.colorScheme.outlineVariant),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      clipBehavior: card.fullBleed ? Clip.antiAlias : Clip.none,
                      padding: card.fullBleed ? EdgeInsets.zero : const EdgeInsets.all(12),
                      child: card.fullBleed
                          ? SizedBox(height: 620, child: card.builder(context))
                          : card.builder(context),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _UnproxiedBlockCard extends StatelessWidget {
  const _UnproxiedBlockCard();

  @override
  Widget build(BuildContext context) {
    return const UnproxiedNavigationBlock(
      siteName: 'Acme Bank',
      blockedUrl: 'https://analytics.tracker.example.org/collect?id=42',
      onGoBack: _noop,
      onOpenProxySettings: _noop,
    );
  }
}

void _noop() {}

class _ColorRolesCard extends StatelessWidget {
  const _ColorRolesCard();

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final roles = <String, (Color, Color)>{
      'primary': (s.primary, s.onPrimary),
      'primaryContainer': (s.primaryContainer, s.onPrimaryContainer),
      'secondary': (s.secondary, s.onSecondary),
      'surface': (s.surface, s.onSurface),
      'surfaceContainerHighest': (s.surfaceContainerHighest, s.onSurfaceVariant),
      'error': (s.error, s.onError),
      'outline': (s.outline, s.surface),
      'outlineVariant': (s.outlineVariant, s.onSurface),
    };
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final e in roles.entries)
          Container(
            width: 200,
            height: 56,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: e.value.$1,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: s.outlineVariant),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.key, style: TextStyle(color: e.value.$2, fontSize: 12)),
                Text(
                  '#${(e.value.$1.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
                  style: TextStyle(color: e.value.$2, fontSize: 10),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _TypeScaleCard extends StatelessWidget {
  const _TypeScaleCard();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final styles = <String, TextStyle?>{
      'titleLarge': t.titleLarge,
      'titleMedium': t.titleMedium,
      'bodyLarge': t.bodyLarge,
      'bodyMedium': t.bodyMedium,
      'bodySmall': t.bodySmall,
      'labelSmall': t.labelSmall,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final e in styles.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('${e.key} ${e.value?.fontSize?.toStringAsFixed(0)}px', style: e.value),
          ),
      ],
    );
  }
}

class _RadiusScaleCard extends StatelessWidget {
  const _RadiusScaleCard();

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final r in Radii.scale)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: s.primaryContainer,
                  borderRadius: BorderRadius.circular(r),
                ),
              ),
              const SizedBox(height: 4),
              Text(r.toStringAsFixed(0), style: TextStyle(fontSize: 11, color: s.onSurfaceVariant)),
            ],
          ),
      ],
    );
  }
}

class _UrlBarCard extends StatelessWidget {
  const _UrlBarCard();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        UrlBar(
          currentUrl: 'https://codeberg.org/theoden8/webspace',
          onUrlSubmitted: (_) {},
          onSiteInfo: () {},
          searchSites: const [
            UrlBarSearchSite('ddg', 'DuckDuckGo'),
            UrlBarSearchSite('kagi', 'Kagi'),
          ],
          onSearch: (_, _) {},
        ),
        const SizedBox(height: 16),
        UrlBar(currentUrl: 'http://example.org', onUrlSubmitted: (_) {}, onSiteInfo: () {}),
        const SizedBox(height: 16),
        Directionality(
          textDirection: TextDirection.rtl,
          child: UrlBar(currentUrl: 'https://codeberg.org/theoden8/webspace', onUrlSubmitted: (_) {}, onSiteInfo: () {}),
        ),
      ],
    );
  }
}

/// The sheet the URL bar's info button opens, for a routed GitHub page. Drawn
/// in a sheet-shaped surface rather than through showModalBottomSheet, so the
/// card needs no tap to show it.
class _SiteInfoCard extends StatelessWidget {
  const _SiteInfoCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.only(top: 24),
        child: SiteInfoSheet(
          info: SiteInfo(
            siteName: 'GitHub',
            tabOf: 'DuckDuckGo',
            pageUrl: 'https://github.com/theoden8/webspace_app',
            containerId: 'ws-3f9c2a7e',
            containerColor: 0,
            incognito: false,
            proxy: UserProxySettings(
              type: ProxyType.SAVED,
              savedProxyId: 'px-work',
            ),
          ),
        ),
      ),
    );
  }
}

class _HintButtonCard extends StatelessWidget {
  const _HintButtonCard();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Tracking protection'),
        HintButton(
          title: 'Tracking protection',
          description: 'Forces ClearURLs, DNS blocklist, content blocker and LocalCDN on, '
              'and injects the anti-fingerprinting shim.',
        ),
      ],
    );
  }
}

class _TabCornerCard extends StatelessWidget {
  const _TabCornerCard();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TabBarCornerButton(
          dragging: false,
          onTap: () {},
          onDragBegin: (_) {},
          onDragUpdate: (_) {},
          onDragEnd: () {},
        ),
        const SizedBox(width: 32),
        TabBarCornerButton(
          dragging: true,
          onTap: () {},
          onDragBegin: (_) {},
          onDragUpdate: (_) {},
          onDragEnd: () {},
        ),
      ],
    );
  }
}

/// The real UserScriptsScreen, live: add, edit, toggle, delete and the push to
/// the editor all work against local state.
class _UserScriptsCard extends StatefulWidget {
  const _UserScriptsCard();

  @override
  State<_UserScriptsCard> createState() => _UserScriptsCardState();
}

class _UserScriptsCardState extends State<_UserScriptsCard> {
  late List<UserScriptConfig> _scripts = [
    UserScriptConfig(
      name: 'Dark reader',
      source: "document.documentElement.style.filter = 'invert(1) hue-rotate(180deg)';",
      injectionTime: UserScriptInjectionTime.atDocumentEnd,
    ),
    UserScriptConfig(
      name: 'Hide cookie banners',
      source: "document.querySelectorAll('[id*=cookie],[class*=consent]').forEach(n => n.remove());",
      injectionTime: UserScriptInjectionTime.atDocumentStart,
      enabled: false,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return UserScriptsScreen(
      title: 'User scripts',
      userScripts: _scripts,
      isGlobalLibrary: true,
      onSave: (scripts) => setState(() => _scripts = scripts),
    );
  }
}

List<Webspace> _demoWebspaces() => [
      Webspace(name: 'Work', siteIds: ['a', 'b', 'c'], siteIndices: [0, 1, 2]),
      Webspace(name: 'Reading', siteIds: ['d', 'e'], siteIndices: [3, 4]),
      Webspace(name: 'Banking', siteIds: ['f'], siteIndices: [5]),
    ];

/// The real WebspacesListScreen: the collections a user switches between,
/// with per-collection site counts and reordering.
class _WebspacesCard extends StatefulWidget {
  const _WebspacesCard();

  @override
  State<_WebspacesCard> createState() => _WebspacesCardState();
}

class _WebspacesCardState extends State<_WebspacesCard> {
  final List<Webspace> _webspaces = _demoWebspaces();
  String? _selected;

  @override
  Widget build(BuildContext context) => WebspacesListScreen(
        webspaces: _webspaces,
        selectedWebspaceId: _selected,
        totalSitesCount: 6,
        accentColor: AccentColor.blue,
        onSelectWebspace: (w) => setState(() => _selected = w.id),
        onAddWebspace: () {},
        onEditWebspace: (_) {},
        onDeleteWebspace: (w) => setState(() => _webspaces.remove(w)),
        onReorder: (from, to) => setState(() {
          final moved = _webspaces.removeAt(from);
          _webspaces.insert(to > from ? to - 1 : to, moved);
        }),
      );
}

/// The real WebspaceDetailScreen: which sites belong to one collection.
class _WebspaceDetailCard extends StatelessWidget {
  const _WebspaceDetailCard();

  @override
  Widget build(BuildContext context) => WebspaceDetailScreen(
        webspace: _demoWebspaces().first,
        allSites: [
          WebViewModel(initUrl: 'https://codeberg.org', name: 'Codeberg'),
          WebViewModel(initUrl: 'https://news.ycombinator.com', name: 'HN'),
          WebViewModel(initUrl: 'https://wikipedia.org', name: 'Wikipedia'),
        ],
        onSave: (_) {},
      );
}

/// The protection report on seeded counters (STATS-003).
class _ProtectionReportCard extends StatelessWidget {
  const _ProtectionReportCard();

  @override
  Widget build(BuildContext context) {
    seedDemoBlockStats();
    return const BlockStatsScreen(siteNames: demoBlockStatsSiteNames);
  }
}

/// One category of the report, opened from its row (STATS-008).
class _ProtectionCategoryCard extends StatelessWidget {
  const _ProtectionCategoryCard();

  @override
  Widget build(BuildContext context) {
    seedDemoBlockStats();
    return const BlockStatsCategoryScreen(
      category: BlockCategory.filterList,
      rangeDays: 7,
      siteNames: demoBlockStatsSiteNames,
    );
  }
}

class _AppSettingsCard extends StatelessWidget {
  const _AppSettingsCard();

  @override
  Widget build(BuildContext context) => AppSettingsScreen(
        currentSettings: const AppThemeSettings(),
        onSettingsChanged: (_) {},
        onExportSettings: () {},
        onImportSettings: () {},
        onOpenLinkHandlingSettings: () {},
      );
}

/// App appearance: language, theme mode and every accent swatch.
class _AppAppearanceCard extends StatelessWidget {
  const _AppAppearanceCard();

  @override
  Widget build(BuildContext context) => AppAppearanceScreen(
        settings: const AppThemeSettings(),
        onSettingsChanged: (_) {},
      );
}

/// App behaviour, with the tab strip pinned by [_seedAppPrefs] so the
/// full-screen choice under it shows.
class _AppBehaviourCard extends StatelessWidget {
  const _AppBehaviourCard();

  @override
  Widget build(BuildContext context) => AppBehaviourScreen(
        onOpenLinkHandlingSettings: () {},
      );
}

/// Off their defaults where that shows more of App settings: the tab strip
/// pinned, so Behaviour shows its full-screen choice, with a width set, and
/// full screen on shortcut off. Demo mode keeps what a designer toggles out
/// of the browser's storage.
void _seedAppPrefs() {
  isDemoMode = true;
  AppPref.showTabStrip.debugValue = true;
  AppPref.tabMaxWidth.debugValue = 180;
  AppPref.fullscreenOnShortcut.debugValue = false;
}

/// The proxy credentials fold and the connection test, as the network
/// section of site settings draws them. All three states of the fold at
/// once, because which one a user lands in is the whole point of it: it
/// opens on whatever is stored, and says so when the pair is half-filled.
class _ProxyAuthCard extends StatelessWidget {
  const _ProxyAuthCard();

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProxyAuthSection(
            usernameController: TextEditingController(),
            passwordController: TextEditingController(),
          ),
          ProxyAuthSection(
            usernameController: TextEditingController(),
            passwordController: TextEditingController(text: 'hunter2'),
          ),
          ProxyAuthSection(
            usernameController: TextEditingController(text: 'proxy-user'),
            passwordController: TextEditingController(text: 'hunter2'),
          ),
          ProxyTestTile(
            settings: () => UserProxySettings(
              type: ProxyType.SOCKS5,
              address: '127.0.0.1:1080',
            ),
            target: Uri.parse('https://codeberg.org/'),
          ),
        ],
      );
}

/// The HTTP authentication sign-in dialog, first attempt and after a refused
/// password.
class _HttpAuthCard extends StatelessWidget {
  const _HttpAuthCard();

  @override
  Widget build(BuildContext context) => const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HttpAuthDialog(
            request: HttpAuthPromptRequest(
              host: 'nas.example.com',
              isRetry: false,
              canRemember: true,
            ),
          ),
          HttpAuthDialog(
            request: HttpAuthPromptRequest(
              host: 'nas.example.com',
              isRetry: true,
              canRemember: true,
              initialUsername: 'alice',
              rememberByDefault: true,
            ),
          ),
        ],
      );
}

/// The real per-site Network screen for a site on a SOCKS5 proxy with
/// credentials and two saved sign-ins, so every proxy row, the sign-ins count
/// and an enabled Clear show.
class _SiteNetworkCard extends StatefulWidget {
  const _SiteNetworkCard();

  @override
  State<_SiteNetworkCard> createState() => _SiteNetworkCardState();
}

class _SiteNetworkCardState extends State<_SiteNetworkCard> {
  final model = WebViewModel(initUrl: 'https://nas.example.com/', name: 'NAS');
  final address = TextEditingController(text: '127.0.0.1:1080');
  final username = TextEditingController(text: 'proxy-user');
  final password = TextEditingController(text: 'hunter2');
  late final Future<void> _seeded = () async {
    const c = HttpAuthCredential(username: 'alice', password: 's3cret');
    await HttpAuthSecureStorage.instance
        .save(model.siteId, Host('nas.example.com'), 'Files', c);
    await HttpAuthSecureStorage.instance
        .save(model.siteId, Host('nas.example.com'), 'Admin', c);
  }();

  @override
  void dispose() {
    address.dispose();
    username.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
        future: _seeded,
        builder: (context, snap) => snap.connectionState == ConnectionState.done
            ? SiteNetworkScreen(
                host: 'nas.example.com',
                siteId: model.siteId,
                values: const SiteNetworkValues(
                  proxyType: ProxyType.SOCKS5,
                  webRtcPolicy: WebRtcPolicy.relayOnly,
                ),
                onChanged: (_) {},
                proxySupported: true,
                trackingProtectionEnabled: true,
                proxyAddressController: address,
                proxyUsernameController: username,
                proxyPasswordController: password,
                proxyTest: ProxyTestTile(
                  settings: () => UserProxySettings(
                    type: ProxyType.SOCKS5,
                    address: address.text,
                  ),
                  target: Uri.parse('https://nas.example.com/'),
                ),
              )
            : const SizedBox.shrink(),
      );
}

/// The real per-site Behaviour screen, in the in-app mode with routing on, so
/// the routing rows show under the option they belong to. The choice is live:
/// picking another option hides them.
class _SiteBehaviourCard extends StatelessWidget {
  const _SiteBehaviourCard();

  @override
  Widget build(BuildContext context) {
    final model = WebViewModel(
      initUrl: 'https://duckduckgo.com/',
      name: 'DuckDuckGo',
      routeOutboundLinks: true,
    );
    final github = WebViewModel(initUrl: 'https://github.com/', name: 'GitHub');
    return SiteBehaviourScreen(
      host: 'duckduckgo.com',
      incognito: false,
      values: const SiteBehaviourValues(
        archived: false,
        alwaysOpenHome: false,
        kioskMode: false,
        fullscreenMode: false,
        htmlCachingEnabled: false,
        externalLinkMode: ExternalLinkMode.inApp,
        routeOutboundLinks: true,
      ),
      onChanged: (_) {},
      routingTargets: [github],
      domainClaims: DomainClaimsEditor(
        model: model,
        otherSites: [github],
        onChanged: (next) => model.domainClaims = next,
      ),
    );
  }
}

/// The real AddSiteScreen: the URL entry and suggestion surface.
class _AddSiteCard extends StatelessWidget {
  const _AddSiteCard();

  @override
  Widget build(BuildContext context) => AddSiteScreen(
        themeMode: ThemeMode.light,
        onThemeModeChanged: (_) {},
        suggestions: const [],
        onSuggestionsChanged: (_) {},
      );
}

/// The real per-site SettingsScreen, driven by a seeded WebViewModel. Every
/// section is the app's own: privacy, proxy, capture permissions, scripts.
class _SiteSettingsCard extends StatelessWidget {
  const _SiteSettingsCard();

  @override
  Widget build(BuildContext context) {
    final model = WebViewModel(
      initUrl: 'https://codeberg.org/theoden8/webspace',
      name: 'Codeberg',
    );
    return SettingsScreen(webViewModel: model, useContainers: true);
  }
}

/// The real LocationPickerScreen, opened on a seeded coordinate. The map tiles
/// come from the network, so an offline gallery shows the grid and the pin
/// without imagery.
class _LocationPickerCard extends StatelessWidget {
  const _LocationPickerCard();

  @override
  Widget build(BuildContext context) => const LocationPickerScreen(
        initialLatitude: 52.3676,
        initialLongitude: 4.9041,
        initialAccuracy: 120,
      );
}

/// The real TrustedCertificatesScreen, seeded with pinned hosts so the list,
/// its delete affordance and the empty state are all reachable.
class _TrustedCertificatesCard extends StatefulWidget {
  const _TrustedCertificatesCard();

  @override
  State<_TrustedCertificatesCard> createState() => _TrustedCertificatesCardState();
}

class _TrustedCertificatesCardState extends State<_TrustedCertificatesCard> {
  late final Future<void> _seeded = _seed();

  Future<void> _seed() async {
    await TrustedHostsService.instance.trust(
      host: 'intranet.example.org',
      port: 443,
      fingerprint: '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
    );
    await TrustedHostsService.instance.trust(
      host: 'router.local',
      port: 8443,
      fingerprint: '2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae',
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _seeded,
      builder: (context, snapshot) => snapshot.connectionState == ConnectionState.done
          ? const TrustedCertificatesScreen()
          : const Scaffold(body: Center(child: CircularProgressIndicator())),
    );
  }
}

/// The chrome around a site, composed from the real primitives. The content
/// area is a placeholder: the native WebView has no web implementation.
class _BrowserChromeCard extends StatelessWidget {
  const _BrowserChromeCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: s.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 56,
            color: s.primaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Icon(Icons.menu, color: s.onPrimaryContainer),
                const SizedBox(width: 16),
                Expanded(
                  child: Text('Codeberg',
                      style: theme.textTheme.titleMedium?.copyWith(color: s.onPrimaryContainer)),
                ),
                Icon(Icons.refresh, color: s.onPrimaryContainer),
                const SizedBox(width: 16),
                Icon(Icons.more_vert, color: s.onPrimaryContainer),
              ],
            ),
          ),
          SizedBox(
            height: 220,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: s.surfaceContainerHighest,
                    child: Center(
                      child: Text('site content (native WebView)',
                          style: TextStyle(color: s.onSurfaceVariant, fontSize: 12)),
                    ),
                  ),
                ),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: TabBarCornerButton(
                    dragging: false,
                    onTap: () {},
                    onDragBegin: (_) {},
                    onDragUpdate: (_) {},
                    onDragEnd: () {},
                  ),
                ),
              ],
            ),
          ),
          UrlBar(currentUrl: 'https://codeberg.org/theoden8/webspace', onUrlSubmitted: (_) {}),
        ],
      ),
    );
  }
}

/// A site whose tabs are [tabs], with [active] bound to its webview.
WebViewModel _siteWithTabs(
    String name, String initUrl, List<SiteTab> tabs, String active,
    {String? siteId, int? containerColor}) {
  final m = WebViewModel(
      initUrl: initUrl, name: name, siteId: siteId, containerColor: containerColor);
  m.tabs = tabs;
  m.activeTabId = active;
  return m;
}

class _WebSearchSheetCard extends StatelessWidget {
  const _WebSearchSheetCard();

  static SearchSite _site(String id, String name, String url) => SearchSite(
        siteId: id,
        name: name,
        initUrl: url,
        capability: WebSearchEngine.capabilityOf(initUrl: url),
      );

  @override
  Widget build(BuildContext context) => _SearchSheetFrame(
        title: 'GitHub',
        sheet: WebSearchSheet(
          identity: _site('gh', 'GitHub', 'https://github.com/'),
          candidates: [
            _site('ddg', 'DuckDuckGo', 'https://duckduckgo.com/'),
            _site('kagi', 'Kagi', 'https://kagi.com/'),
            _site('pplx', 'Perplexity', 'https://www.perplexity.ai/'),
          ],
          containerColors: const {'gh': 0, 'ddg': 6, 'kagi': 2, 'pplx': 4},
        ),
      );
}

/// Default search with a work and a personal DuckDuckGo: the name alone
/// cannot tell them apart, the id and its container colour can (LIR-029).
class _WebSearchDefaultCard extends StatelessWidget {
  const _WebSearchDefaultCard();

  @override
  Widget build(BuildContext context) => const SearchSiteChoiceDialog(
        title: 'Default search',
        selected: 'ddg-work',
        cancelLabel: 'Cancel',
        sites: [
          (siteId: 'ddg-work', name: 'DuckDuckGo', containerColor: 0),
          (siteId: 'ddg-home', name: 'DuckDuckGo', containerColor: 6),
          (siteId: 'kagi', name: 'Kagi', containerColor: 2),
          (siteId: 'searx-lan', name: 'SearXNG', containerColor: 4),
        ],
      );
}

/// The site search list row once downloaded (LIR-036), on a list of the size
/// Kagi's reduces to.
class _SiteSearchListCard extends StatefulWidget {
  const _SiteSearchListCard();

  @override
  State<_SiteSearchListCard> createState() => _SiteSearchListCardState();
}

class _SiteSearchListCardState extends State<_SiteSearchListCard> {
  @override
  void initState() {
    super.initState();
    SiteSearchListService.instance.setInMemory(
      {for (var i = 0; i < 7392; i++) 'site$i.example': 'https://site$i.example/?q=%s'},
      updated: DateTime(2026, 10, 6, 14, 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return DatasetTile(
      create: SiteSearchListDataset.new,
      icon: Icons.manage_search,
      title: loc.webSearchSiteListTitle,
      hint: loc.webSearchSiteListHint,
    );
  }
}

/// A SearXNG instance whose pages declared its search (LIR-035): the Behaviour
/// screen shows the address it learned and that it searches the whole web, and
/// its pickers tell the two DuckDuckGo sites apart.
class _SiteBehaviourSearchCard extends StatelessWidget {
  const _SiteBehaviourSearchCard();

  @override
  Widget build(BuildContext context) => SiteBehaviourScreen(
        host: 'searx.lan',
        incognito: false,
        values: const SiteBehaviourValues(
          archived: false,
          alwaysOpenHome: false,
          kioskMode: false,
          fullscreenMode: false,
          htmlCachingEnabled: false,
          externalLinkMode: ExternalLinkMode.inApp,
          routeOutboundLinks: false,
          searchSites: ['ddg-work', 'ddg-home'],
        ),
        onChanged: (_) {},
        tabsAvailable: true,
        initUrl: 'https://searx.lan/',
        discoveredSearchAddress: 'https://searx.lan/search?q=%s',
        discoveredSearchesWeb: true,
        routingTargets: [
          WebViewModel(
              siteId: 'ddg-work',
              initUrl: 'https://duckduckgo.com/',
              name: 'DuckDuckGo',
              containerColor: 0),
          WebViewModel(
              siteId: 'ddg-home',
              initUrl: 'https://duckduckgo.com/',
              name: 'DuckDuckGo',
              containerColor: 6),
        ],
      );
}

class _WebSearchEmptyCard extends StatelessWidget {
  const _WebSearchEmptyCard();

  @override
  Widget build(BuildContext context) => const _SearchSheetFrame(
        title: 'Blog',
        sheet: WebSearchSheet(
          identity: SearchSite(
            siteId: 'blog',
            name: 'Blog',
            initUrl: 'https://blog.example/',
            capability: null,
          ),
          candidates: [],
        ),
      );
}

class _SearchSheetFrame extends StatelessWidget {
  const _SearchSheetFrame({required this.title, required this.sheet});

  final String title;
  final Widget sheet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: theme.colorScheme.surfaceContainerHighest)),
          const Positioned.fill(child: ColoredBox(color: Colors.black54)),
          Align(
            alignment: Alignment.bottomCenter,
            child: BottomSheet(
              enableDrag: false,
              onClosing: _noop,
              builder: (_) => Padding(
                padding: const EdgeInsets.only(top: Spacing.lg),
                child: sheet,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The sites the two Tabs sheet cards share, one set of models so a tab one
/// site's tree holds shows in the other's list too (TAB-017). GitHub's
/// routing is off: a Wikipedia link it opened runs as GitHub in Wikipedia's
/// domain (LIR-034), while a search it ran in DuckDuckGo runs as DuckDuckGo
/// (LIR-030). Each site has its colour (TAB-018).
abstract final class _TabsDemo {
  static final WebViewModel github = _siteWithTabs('GitHub', 'https://github.com/', [
    SiteTab.primary(url: 'https://github.com/theoden8/webspace_app', title: 'theoden8/webspace_app'),
    SiteTab(id: 'pulls', url: 'https://github.com/theoden8/webspace_app/pulls', title: 'Pull requests', parentId: kPrimaryTabId),
    SiteTab(id: 'pr659', url: 'https://github.com/theoden8/webspace_app/pull/659', title: 'Let the routing switch pick the site #659', parentId: 'pulls'),
    SiteTab(id: 'search', url: 'https://duckduckgo.com/?q=flutter+inappwebview', title: 'flutter inappwebview at DuckDuckGo', parentId: kPrimaryTabId, hostSiteId: 'ddg'),
    SiteTab(id: 'result', url: 'https://github.com/pichillilorenzo/flutter_inappwebview', title: 'flutter_inappwebview', parentId: 'search'),
    SiteTab(id: 'wiki', url: 'https://en.wikipedia.org/wiki/Tree_(data_structure)', title: 'Tree (data structure)', parentId: 'pr659', openerSiteId: 'gh', homeUrl: 'https://en.wikipedia.org/wiki/Tree_(data_structure)'),
  ], 'pr659', siteId: 'gh', containerColor: 0);

  static final WebViewModel mastodon = _siteWithTabs('Mastodon', 'https://mastodon.social/', [
    SiteTab.primary(url: 'https://mastodon.social/home', title: 'Home'),
    SiteTab(id: 'thread', url: 'https://mastodon.social/@flutter/113', title: 'Thread by @flutter', parentId: kPrimaryTabId),
  ], 'thread', siteId: 'mastodon', containerColor: 6);

  static final WebViewModel wikipedia = _siteWithTabs('Wikipedia', 'https://en.wikipedia.org/', [
    SiteTab.primary(url: 'https://en.wikipedia.org/wiki/Tab_(interface)', title: 'Tab (interface)'),
  ], kPrimaryTabId, siteId: 'wiki', containerColor: 2);

  static final WebViewModel duckduckgo = _siteWithTabs('DuckDuckGo', 'https://duckduckgo.com/', [
    SiteTab.primary(url: 'https://duckduckgo.com/?q=webview+containers', title: 'webview containers at DuckDuckGo'),
    SiteTab(id: 'own', url: 'https://duckduckgo.com/?q=tab+trees', title: 'tab trees at DuckDuckGo', parentId: kPrimaryTabId),
    SiteTab(id: 'issue', url: 'https://github.com/theoden8/webspace_app/issues/422', title: 'Web search #422', parentId: 'own', hostSiteId: 'gh', openerSiteId: 'ddg', homeUrl: 'https://github.com/theoden8/webspace_app/issues/422'),
  ], kPrimaryTabId, siteId: 'ddg', containerColor: 4);

  static final Map<String, WebViewModel> _byId = {
    for (final m in [github, mastodon, wikipedia, duckduckgo]) m.siteId: m,
  };

  /// Hosted rows resolve the site they run as through this, as the app's do.
  static void bindLookup() => WebViewModel.siteLookup = (id) => _byId[id];

  static List<TabsSheetSite> sites({required WebViewModel current}) => [
        for (final (i, m) in [github, mastodon, wikipedia, duckduckgo].indexed)
          TabsSheetSite(
            index: i,
            model: m,
            isCurrent: identical(m, current),
            isLoaded: identical(m, current) || identical(m, mastodon),
          ),
      ];
}

/// The real TabsSheet over a page, as the app's modal presents it. GitHub is
/// on screen, Mastodon is loaded in the background, the rest hold no webview
/// (TAB-011); GitHub's tree runs tabs as three sites, each row marked with
/// the colour of the one it runs as, and DuckDuckGo's tree holds a GitHub tab
/// under one of its own, listed with it under "In DuckDuckGo" (TAB-017).
class _TabsSheetCard extends StatelessWidget {
  const _TabsSheetCard();

  @override
  Widget build(BuildContext context) {
    _TabsDemo.bindLookup();
    return const _TabsSheetOver(title: 'GitHub', current: 0);
  }
}

/// DuckDuckGo's Tabs sheet: its own tree, then GitHub's, folded around the
/// tab it runs as DuckDuckGo, under "In GitHub" (TAB-017).
class _TabsSheetInSiteCard extends StatelessWidget {
  const _TabsSheetInSiteCard();

  @override
  Widget build(BuildContext context) {
    _TabsDemo.bindLookup();
    return const _TabsSheetOver(title: 'DuckDuckGo', current: 3);
  }
}

/// The same sheet once that tab was tapped: GitHub is on screen on it, so the
/// list is still DuckDuckGo's, with the highlight in GitHub's tree and
/// DuckDuckGo's tab marked as where the user was (TAB-019).
class _TabsSheetWayBackCard extends StatelessWidget {
  const _TabsSheetWayBackCard();

  @override
  Widget build(BuildContext context) {
    _TabsDemo.bindLookup();
    final github = _siteWithTabs('GitHub', 'https://github.com/',
        _TabsDemo.github.tabs, 'search', siteId: 'gh', containerColor: 0);
    return _TabsSheetOver(
      title: 'GitHub',
      current: 0,
      sites: [
        TabsSheetSite(index: 0, model: github, isCurrent: true, isLoaded: true),
        for (final (i, m) in [_TabsDemo.mastodon, _TabsDemo.wikipedia, _TabsDemo.duckduckgo].indexed)
          TabsSheetSite(index: i + 1, model: m, isCurrent: false, isLoaded: identical(m, _TabsDemo.duckduckgo)),
      ],
      wayBack: const TabReturn(
          fromSiteId: 'ddg', fromTabId: kPrimaryTabId, toSiteId: 'gh', toTabId: 'search'),
    );
  }
}

class _TabsSheetOver extends StatelessWidget {
  const _TabsSheetOver({required this.title, required this.current, this.sites, this.wayBack});

  final String title;
  final int current;
  final List<TabsSheetSite>? sites;
  final TabReturn? wayBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sites = this.sites ??
        _TabsDemo.sites(
            current: [_TabsDemo.github, _TabsDemo.mastodon, _TabsDemo.wikipedia, _TabsDemo.duckduckgo][current]);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: theme.colorScheme.surfaceContainerHighest)),
          const Positioned.fill(child: ColoredBox(color: Colors.black54)),
          Align(
            alignment: Alignment.bottomCenter,
            child: BottomSheet(
              enableDrag: false,
              onClosing: _noop,
              builder: (_) => TabsSheet(
                sites: sites,
                currentIndex: current,
                onOpenTab: (_, _) {},
                onNewTab: (_) {},
                onWebSearch: () {},
                onCloseTab: (_, _) {},
                onCloseSubtree: (_, _) {},
                wayBack: wayBack,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
