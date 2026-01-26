import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// Global flag to indicate demo mode is active.
/// When true, the app will not persist any changes to storage.
/// This is used during screenshot tests to ensure the demo data
/// is not overwritten and normal app usage restores user settings.
bool isDemoMode = false;

/// Key to mark that demo mode was active in previous session
const String _demoModeMarkerKey = 'wasDemoMode';

/// Clears demo data if app was previously in demo mode.
/// Should be called when app starts normally (not during screenshot tests).
Future<void> clearDemoDataIfNeeded() async {
  final prefs = await SharedPreferences.getInstance();
  final wasDemoMode = prefs.getBool(_demoModeMarkerKey) ?? false;

  if (wasDemoMode) {
    print('========================================');
    print('CLEARING DEMO DATA FROM PREVIOUS SESSION');
    print('========================================');

    // Clear all demo data
    await prefs.remove('webViewModels');
    await prefs.remove('webspaces');
    await prefs.remove('selectedWebspaceId');
    await prefs.remove('currentIndex');
    await prefs.remove('themeMode');
    await prefs.remove('showUrlBar');
    await prefs.remove(_demoModeMarkerKey);

    print('Demo data cleared - app will start with clean state');
    print('========================================');
  }
}

/// Seeds demo/test data for screenshots and testing
Future<void> seedDemoData() async {
  print('========================================');
  print('SEEDING DEMO DATA');
  print('========================================');

  final prefs = await SharedPreferences.getInstance();

  // Set marker FIRST to indicate demo mode is active
  await prefs.setBool(_demoModeMarkerKey, true);

  // Enable demo mode to prevent any further saves during the session
  isDemoMode = true;
  print('Demo mode enabled - changes will NOT be persisted to storage');

  // Clear existing data
  print('Clearing existing data...');
  await prefs.remove('webViewModels');
  await prefs.remove('webspaces');
  await prefs.remove('selectedWebspaceId');
  await prefs.remove('currentIndex');

  // Create sample sites
  final sites = <WebViewModel>[
    WebViewModel(
      initUrl: 'https://duckduckgo.com',
      name: 'DuckDuckGo',
    ),
    WebViewModel(
      initUrl: 'https://piped.video',
      name: 'Piped',
    ),
    WebViewModel(
      initUrl: 'https://nitter.net',
      name: 'Nitter',
    ),
    WebViewModel(
      initUrl: 'https://www.reddit.com',
      name: 'Reddit',
    ),
    WebViewModel(
      initUrl: 'https://github.com',
      name: 'GitHub',
    ),
    WebViewModel(
      initUrl: 'https://news.ycombinator.com',
      name: 'Hacker News',
    ),
    WebViewModel(
      initUrl: 'https://wandb.ai',
      name: 'Weights & Biases',
    ),
    WebViewModel(
      initUrl: 'https://www.wikipedia.org',
      name: 'Wikipedia',
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
    print('  Webspace $i: ${webspaces[i].name} (${webspaces[i].siteIndices.length} sites)');
  }

  // Serialize and save
  print('Saving to SharedPreferences...');
  final sitesJson = sites.map((s) => jsonEncode(s.toJson())).toList();
  final webspacesJson = webspaces.map((w) => jsonEncode(w.toJson())).toList();

  await prefs.setStringList('webViewModels', sitesJson);
  await prefs.setStringList('webspaces', webspacesJson);
  await prefs.setString('selectedWebspaceId', kAllWebspaceId);
  await prefs.setInt('currentIndex', 10000); // No site selected
  await prefs.setInt('themeMode', 0); // Light theme
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
}
