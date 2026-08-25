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
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';
import 'package:webspace/demo_data.dart'
    show demoBlockStatsSiteNames, seedDemoBlockStats;
import 'package:webspace/main.dart' show AppThemeSettings, AccentColor;
import 'package:webspace/screens/add_site.dart';
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/screens/block_stats.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/screens/location_picker.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/screens/trusted_certificates.dart';
import 'package:webspace/screens/user_scripts.dart';
import 'package:webspace/screens/webspace_detail.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/url_bar.dart';

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
  GalleryCard(id: 'app-settings', label: 'App settings screen', fullBleed: true, builder: (c) => const _AppSettingsCard()),
  GalleryCard(id: 'protection-report', label: 'Protection report screen', fullBleed: true, builder: (c) => const _ProtectionReportCard()),
  GalleryCard(id: 'protection-report-category', label: 'Protection report category', fullBleed: true, builder: (c) => const _ProtectionCategoryCard()),
  GalleryCard(id: 'add-site', label: 'Add site screen', fullBleed: true, builder: (c) => const _AddSiteCard()),
  GalleryCard(id: 'color-roles', label: 'Color roles', builder: (c) => const _ColorRolesCard()),
  GalleryCard(id: 'type-scale', label: 'Type scale', builder: (c) => const _TypeScaleCard()),
  GalleryCard(id: 'radius-scale', label: 'Corner radii', builder: (c) => const _RadiusScaleCard()),
  GalleryCard(id: 'url-bar', label: 'URL bar', builder: (c) => const _UrlBarCard()),
  GalleryCard(id: 'hint-button', label: 'Hint button', builder: (c) => const _HintButtonCard()),
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
  final q = Uri.base.queryParameters;
  runApp(GalleryApp(
    cardId: q['card'],
    brightness: q['theme'] == 'dark' ? Brightness.dark : Brightness.light,
    accent: galleryAccents[q['accent']] ?? accentBlue,
    localeCode: q['locale'],
  ));
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
        UrlBar(currentUrl: 'https://codeberg.org/theoden8/webspace', onUrlSubmitted: (_) {}),
        const SizedBox(height: 16),
        UrlBar(currentUrl: 'http://example.org', onUrlSubmitted: (_) {}),
      ],
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

/// The real AppSettingsScreen: the global preferences surface.
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
        showTabStrip: true,
        onShowTabStripChanged: (_) {},
        tabStripInFullscreen: false,
        onTabStripInFullscreenChanged: (_) {},
        fullscreenOnShortcut: false,
        onFullscreenOnShortcutChanged: (_) {},
        backOpensMenu: false,
        onBackOpensMenuChanged: (_) {},
        tabBarButton: true,
        onTabBarButtonChanged: (_) {},
        tabMaxWidth: 180,
        onTabMaxWidthChanged: (_) {},
        showStatsBanner: false,
        onShowStatsBannerChanged: (_) {},
        localeOverride: '',
        onLocaleOverrideChanged: (_) {},
        linkHandlingEnabled: false,
        onLinkHandlingEnabledChanged: (_) {},
        onOpenLinkHandlingSettings: () {},
      );
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
