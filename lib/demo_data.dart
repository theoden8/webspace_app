import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
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
  print('========================================');
  print('SEEDING DEMO DATA');
  print('========================================');

  final prefs = await SharedPreferences.getInstance();

  // Clear existing data
  print('Clearing existing data...');
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

  print('Created ${sites.length} sites');
  for (var i = 0; i < sites.length; i++) {
    print('  Site $i: ${sites[i].name} - ${sites[i].initUrl}');
  }

  // Create sample webspaces
  final webspaces = <Webspace>[
    Webspace.all(), // The "All" webspace
    Webspace(
      id: 'webspace_work',
      name: 'Work',
      siteIndices: [4, 5, 6], // GitHub, Hacker News, W&B
    ),
    Webspace(
      id: 'webspace_privacy',
      name: 'Privacy',
      siteIndices: [0, 1, 2], // DuckDuckGo, Piped, Nitter
    ),
    Webspace(
      id: 'webspace_social',
      name: 'Social',
      siteIndices: [2, 3, 7], // Nitter, Reddit, Wikipedia
    ),
  ];

  print('Created ${webspaces.length} webspaces');
  for (var i = 0; i < webspaces.length; i++) {
    final ws = webspaces[i];
    print('  Webspace $i: ${ws.name} (${ws.siteIndices.length} sites)');
  }

  // Serialize and save
  print('Saving to SharedPreferences...');
  final sitesJson = sites.map((s) => jsonEncode(s.toJson())).toList();
  final webspacesJson = webspaces.map((w) => jsonEncode(w.toJson())).toList();

  await prefs.setStringList('webViewModels', sitesJson);
  await prefs.setStringList('webspaces', webspacesJson);
  await prefs.setString('selectedWebspaceId', kAllWebspaceId);
  await prefs.setInt('currentIndex', 10000); // No site selected
  // Map theme string to ThemeMode index: system=0, light=1, dark=2
  final themeIndex = switch (theme) {
    'light' => 1,
    'dark' => 2,
    _ => 0, // system (default)
  };
  await prefs.setInt('themeMode', themeIndex);
  await prefs.setBool('showUrlBar', false);

  print('Data saved successfully!');
  print('');
  print('Verifying saved data...');

  // Verify
  final savedSites = prefs.getStringList('webViewModels');
  final savedWebspaces = prefs.getStringList('webspaces');
  final selectedId = prefs.getString('selectedWebspaceId');

  print('webViewModels: ${savedSites?.length} items');
  print('webspaces: ${savedWebspaces?.length} items');
  print('selectedWebspaceId: $selectedId');

  if (savedSites != null && savedSites.isNotEmpty) {
    print('First site: ${savedSites[0].substring(0, savedSites[0].length < 100 ? savedSites[0].length : 100)}...');
  }

  print('');
  print('========================================');
  print('DEMO DATA SEEDING COMPLETE');
  print('========================================');
  print('The app will load with ${sites.length} sites in ${webspaces.length} webspaces.');

  // Enable demo mode to prevent any further saves during the session
  isDemoMode = true;
  print('Demo mode enabled - changes will NOT be persisted to storage');
}
