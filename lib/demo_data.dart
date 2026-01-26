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

/// Demo data keys - separate from user data keys
const String demoWebViewModelsKey = 'demo_webViewModels';
const String demoWebspacesKey = 'demo_webspaces';
const String demoSelectedWebspaceIdKey = 'demo_selectedWebspaceId';
const String demoCurrentIndexKey = 'demo_currentIndex';
const String demoThemeModeKey = 'demo_themeMode';
const String demoShowUrlBarKey = 'demo_showUrlBar';

/// Checks if demo mode marker is set (screenshot test was run)
Future<bool> isDemoModeActive() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_demoModeMarkerKey) ?? false;
}

/// Clears demo data and marker when app starts normally.
/// Should be called when app starts normally (not during screenshot tests).
Future<void> clearDemoDataIfNeeded() async {
  final prefs = await SharedPreferences.getInstance();
  final wasDemoMode = prefs.getBool(_demoModeMarkerKey) ?? false;

  print('[DEMO MODE] Checking for demo data cleanup...');
  print('[DEMO MODE] wasDemoMode marker: $wasDemoMode');

  if (wasDemoMode) {
    print('========================================');
    print('CLEARING DEMO DATA FROM PREVIOUS SESSION');
    print('========================================');

    // Show what's being cleared
    print('[DEMO MODE] Keys before cleanup:');
    print('  demo_webViewModels: ${prefs.getStringList(demoWebViewModelsKey)?.length ?? 0} items');
    print('  demo_webspaces: ${prefs.getStringList(demoWebspacesKey)?.length ?? 0} items');
    print('  Regular webViewModels: ${prefs.getStringList('webViewModels')?.length ?? 0} items');
    print('  Regular webspaces: ${prefs.getStringList('webspaces')?.length ?? 0} items');

    // Clear all demo data keys
    await prefs.remove(demoWebViewModelsKey);
    await prefs.remove(demoWebspacesKey);
    await prefs.remove(demoSelectedWebspaceIdKey);
    await prefs.remove(demoCurrentIndexKey);
    await prefs.remove(demoThemeModeKey);
    await prefs.remove(demoShowUrlBarKey);
    await prefs.remove(_demoModeMarkerKey);

    print('[DEMO MODE] Demo data keys removed');
    print('[DEMO MODE] Keys after cleanup:');
    print('  Regular webViewModels: ${prefs.getStringList('webViewModels')?.length ?? 0} items');
    print('  Regular webspaces: ${prefs.getStringList('webspaces')?.length ?? 0} items');
    print('Demo data cleared - app will load user data');
    print('========================================');
  } else {
    print('[DEMO MODE] No demo mode marker found - normal startup');
  }
}

/// Seeds demo/test data for screenshots and testing
Future<void> seedDemoData() async {
  print('========================================');
  print('SEEDING DEMO DATA');
  print('========================================');

  final prefs = await SharedPreferences.getInstance();

  // Show existing user data before seeding
  print('[DEMO MODE] User data before seeding:');
  print('  webViewModels: ${prefs.getStringList('webViewModels')?.length ?? 0} items');
  print('  webspaces: ${prefs.getStringList('webspaces')?.length ?? 0} items');

  // Set marker FIRST to indicate demo mode is active
  await prefs.setBool(_demoModeMarkerKey, true);

  // Enable demo mode to prevent any further saves during the session
  isDemoMode = true;
  print('Demo mode enabled - changes will NOT be persisted to storage');
  print('User data will be preserved - demo data written to separate keys');

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

  // Serialize and save to DEMO keys (not regular keys)
  print('Saving to SharedPreferences (demo keys)...');
  final sitesJson = sites.map((s) => jsonEncode(s.toJson())).toList();
  final webspacesJson = webspaces.map((w) => jsonEncode(w.toJson())).toList();

  await prefs.setStringList(demoWebViewModelsKey, sitesJson);
  await prefs.setStringList(demoWebspacesKey, webspacesJson);
  await prefs.setString(demoSelectedWebspaceIdKey, kAllWebspaceId);
  await prefs.setInt(demoCurrentIndexKey, 10000); // No site selected
  await prefs.setInt(demoThemeModeKey, 0); // Light theme
  await prefs.setBool(demoShowUrlBarKey, false);

  print('Data saved successfully to demo keys!');
  print('');
  print('Verifying saved data...');

  // Verify
  final savedSites = prefs.getStringList(demoWebViewModelsKey);
  final savedWebspaces = prefs.getStringList(demoWebspacesKey);
  final selectedId = prefs.getString(demoSelectedWebspaceIdKey);

  print('demo_webViewModels: ${savedSites?.length} items');
  print('demo_webspaces: ${savedWebspaces?.length} items');
  print('demo_selectedWebspaceId: $selectedId');

  if (savedSites != null && savedSites.isNotEmpty) {
    print('First site: ${savedSites[0].substring(0, savedSites[0].length < 100 ? savedSites[0].length : 100)}...');
  }

  print('');
  print('========================================');
  print('DEMO DATA SEEDING COMPLETE');
  print('========================================');
  print('The app will load with ${sites.length} sites in ${webspaces.length} webspaces.');

  print('[DEMO MODE] Final state in SharedPreferences:');
  print('  User webViewModels: ${prefs.getStringList('webViewModels')?.length ?? 0} items');
  print('  User webspaces: ${prefs.getStringList('webspaces')?.length ?? 0} items');
  print('  Demo webViewModels: ${prefs.getStringList(demoWebViewModelsKey)?.length ?? 0} items');
  print('  Demo webspaces: ${prefs.getStringList(demoWebspacesKey)?.length ?? 0} items');
  print('  wasDemoMode marker: ${prefs.getBool(_demoModeMarkerKey)}');
}
