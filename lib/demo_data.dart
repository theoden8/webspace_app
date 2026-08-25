import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// Global flag to indicate demo mode is active.
/// When true, the app will not persist any changes to storage.
/// This is used during screenshot tests to ensure the demo data
/// is not overwritten and normal app usage restores user settings.
bool isDemoMode = false;

/// Seeds demo/test data for screenshots and testing.
///
/// The [theme] parameter sets the initial theme mode:
/// - 'system' (default): Use system theme
/// - 'light': Use light theme
/// - 'dark': Use dark theme
///
/// The [language] parameter sets the language for all sites:
/// - null (default): Use per-site settings or system default
/// - 'en', 'es', etc.: Override all sites with this language
Future<void> seedDemoData({String theme = 'system', String? language}) async {
  void log(String msg) =>
      LogService.instance.log('DemoData', msg, level: LogLevel.info);

  log('========================================');
  log('SEEDING DEMO DATA');
  log('========================================');

  final prefs = await SharedPreferences.getInstance();

  log('Clearing existing data...');
  await prefs.remove('webViewModels');
  await prefs.remove('webspaces');
  await prefs.remove('selectedWebspaceId');
  await prefs.remove('currentIndex');

  // Create sample sites
  // Language can be explicitly set per site (null = system default)
  // If a language parameter is passed to seedDemoData, it overrides all sites
  final sites = <WebViewModel>[
    WebViewModel(
      initUrl: 'https://searx.be',
      name: 'SearXNG',
      language: language,
    ),
    WebViewModel(
      initUrl: 'https://piped.video',
      name: 'Piped',
      language: language,
    ),
    WebViewModel(
      initUrl: 'https://nitter.net',
      name: 'Nitter',
      language: language,
    ),
    WebViewModel(
      initUrl: 'https://www.reddit.com',
      name: 'Reddit',
      language: language,
    ),
    WebViewModel(
      initUrl: 'https://github.com',
      name: 'GitHub',
      language: language ?? 'en', // English by default for GitHub
    ),
    WebViewModel(
      initUrl: 'https://news.ycombinator.com',
      name: 'Hacker News',
      language: language ?? 'en', // English by default for HN
    ),
    WebViewModel(
      initUrl: 'https://wandb.ai',
      name: 'Weights & Biases',
      language: language ?? 'en', // English by default for W&B
    ),
    WebViewModel(
      initUrl: 'https://www.wikipedia.org',
      name: 'Wikipedia',
      language: language, // System default for Wikipedia (multi-language)
    ),
  ];

  log('Created ${sites.length} sites');
  for (var i = 0; i < sites.length; i++) {
    log('  Site $i: ${sites[i].name} - ${sites[i].initUrl}');
  }

  // Create sample webspaces. Membership is persisted by siteId (not
  // positional index) so it survives reorderings and add/delete of
  // unrelated sites — pluck siteIds off the freshly-constructed
  // models above rather than hard-coding positions.
  final webspaces = <Webspace>[
    Webspace.all(), // The "All" webspace
    Webspace(
      id: 'webspace_work',
      name: 'Work',
      siteIds: [sites[4].siteId, sites[5].siteId, sites[6].siteId],
    ),
    Webspace(
      id: 'webspace_privacy',
      name: 'Privacy',
      siteIds: [sites[0].siteId, sites[1].siteId, sites[2].siteId],
    ),
    Webspace(
      id: 'webspace_social',
      name: 'Social',
      siteIds: [sites[2].siteId, sites[3].siteId, sites[7].siteId],
    ),
  ];

  log('Created ${webspaces.length} webspaces');
  for (var i = 0; i < webspaces.length; i++) {
    final ws = webspaces[i];
    log('  Webspace $i: ${ws.name} (${ws.siteIds.length} sites)');
  }

  log('Saving to SharedPreferences...');
  final sitesJson = sites.map((s) => jsonEncode(s.toJson())).toList();
  final webspacesJson = webspaces.map((w) => jsonEncode(w.toJson())).toList();

  await prefs.setStringList('webViewModels', sitesJson);
  await prefs.setStringList('webspaces', webspacesJson);
  await prefs.setString('selectedWebspaceId', kAllWebspaceId);
  await prefs.setInt('currentIndex', 10000); // No site selected
  // Map theme string to themeSettings storage index
  // Format: themeMode.index * 10 + accentColor.index
  // ThemeMode: system=0, light=1, dark=2
  // AccentColor: blue=0 (default)
  final themeSettingsIndex = switch (theme) {
    'light' => 10, // light (1) * 10 + blue (0)
    'dark' => 20,  // dark (2) * 10 + blue (0)
    _ => 0,        // system (0) * 10 + blue (0)
  };
  await prefs.setInt('themeSettings', themeSettingsIndex);
  await prefs.setBool('showUrlBar', false);

  log('Data saved successfully!');
  log('Verifying saved data...');

  // Verify
  final savedSites = prefs.getStringList('webViewModels');
  final savedWebspaces = prefs.getStringList('webspaces');
  final selectedId = prefs.getString('selectedWebspaceId');

  log('webViewModels: ${savedSites?.length} items');
  log('webspaces: ${savedWebspaces?.length} items');
  log('selectedWebspaceId: $selectedId');

  if (savedSites != null && savedSites.isNotEmpty) {
    log('First site: ${savedSites[0].substring(0, savedSites[0].length < 100 ? savedSites[0].length : 100)}...');
  }

  log('========================================');
  log('DEMO DATA SEEDING COMPLETE');
  log('========================================');
  log('The app will load with ${sites.length} sites in ${webspaces.length} webspaces.');

  isDemoMode = true;
  log('Demo mode enabled - changes will NOT be persisted to storage');
}

/// Design-time counters for the protection report, so the shield badge, the
/// chart and the per-category drill-down have something to draw.
///
/// Kept out of [seedDemoData] on purpose: the integration screenshots seed
/// through that and should not gain a badge they never asserted. Fills the
/// engine and the session detail directly rather than going through
/// `record`, which would stamp every event with today.
void seedDemoBlockStats({DateTime? now}) {
  final engine = BlockStatsService.instance.engine;
  final detail = BlockStatsService.instance.detail;
  if (engine.allTimeTotal > 0) return;
  final at = now ?? DateTime.now();

  const perDay = <BlockCategory, List<int>>{
    BlockCategory.filterList: [38, 61, 55, 44, 74, 66, 91],
    BlockCategory.dnsBlocklist: [18, 24, 12, 31, 27, 22, 35],
    BlockCategory.trackingParam: [4, 9, 6, 3, 11, 7, 12],
    BlockCategory.localCdn: [2, 5, 3, 6, 4, 8, 5],
  };
  perDay.forEach((category, days) {
    for (var i = 0; i < days.length; i++) {
      engine.record(
        category,
        count: days[i],
        now: DateTime(at.year, at.month, at.day - (days.length - 1 - i)),
      );
    }
  });

  const items = <BlockCategory, Map<String, int>>{
    BlockCategory.filterList: {
      'doubleclick.net': 34,
      'googlesyndication.com': 21,
      'scorecardresearch.com': 12,
      'adservice.google.com': 9,
      'outbrain.com': 5,
    },
    BlockCategory.dnsBlocklist: {
      'graph.facebook.com': 16,
      'analytics.tiktok.com': 11,
      'app-measurement.com': 7,
      'branch.io': 4,
    },
    BlockCategory.trackingParam: {
      'utm_medium, utm_source': 8,
      'fbclid': 5,
      'gclid': 3,
      'igshid': 2,
    },
    BlockCategory.localCdn: {
      'cdnjs.cloudflare.com': 6,
      'ajax.googleapis.com': 4,
      'fonts.gstatic.com': 3,
    },
  };
  const sites = <BlockCategory, Map<String, int>>{
    BlockCategory.filterList: {'demo-reddit': 48, 'demo-hn': 22, 'demo-github': 11},
    BlockCategory.dnsBlocklist: {'demo-reddit': 24, 'demo-github': 9, 'demo-hn': 5},
    BlockCategory.trackingParam: {'demo-reddit': 12, 'demo-hn': 6},
    BlockCategory.localCdn: {'demo-github': 8, 'demo-hn': 5},
  };
  items.forEach((category, byLabel) {
    byLabel.forEach((label, count) {
      detail.record(category, siteId: 'demo', label: label, count: count);
    });
  });
  sites.forEach((category, bySite) {
    bySite.forEach((siteId, count) {
      detail.record(category, siteId: siteId, count: count);
    });
  });
}

/// Display names for the sites [seedDemoBlockStats] attributes blocks to.
const Map<String, String> demoBlockStatsSiteNames = {
  'demo-reddit': 'Reddit',
  'demo-hn': 'Hacker News',
  'demo-github': 'GitHub',
};
