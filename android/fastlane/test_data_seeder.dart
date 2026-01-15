import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// Standalone script to seed test data for screenshot tests.
/// Run this with: flutter run -d <device> test_data_seeder.dart
/// Then the data will be persisted for the screenshot test to use.
void main() async {
  print('========================================');
  print('SEEDING TEST DATA FOR SCREENSHOTS');
  print('========================================');

  final prefs = await SharedPreferences.getInstance();

  // Clear existing data
  print('Clearing existing data...');
  await prefs.remove('webViewModels');
  await prefs.remove('webspaces');
  await prefs.remove('selectedWebspaceId');
  await prefs.remove('currentIndex');

  // Create sample sites
  final sites = <WebViewModel>[
    WebViewModel(
      initUrl: 'https://example.com/blog',
      name: 'My Blog',
    ),
    WebViewModel(
      initUrl: 'https://tasks.example.com',
      name: 'Tasks',
    ),
    WebViewModel(
      initUrl: 'https://notes.example.com',
      name: 'Notes',
    ),
    WebViewModel(
      initUrl: 'http://homeserver.local:8080',
      name: 'Home Dashboard',
    ),
    WebViewModel(
      initUrl: 'http://192.168.1.100:3000',
      name: 'Personal Wiki',
    ),
    WebViewModel(
      initUrl: 'http://192.168.1.101:8096',
      name: 'Media Server',
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
      siteIndices: [0, 1, 2], // Blog, Tasks, Notes
    ),
    Webspace(
      id: 'webspace_homeserver',
      name: 'Home Server',
      siteIndices: [3, 4, 5], // Dashboard, Wiki, Media
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
    print('First site: ${savedSites[0].substring(0, 100)}...');
  }

  print('');
  print('========================================');
  print('TEST DATA SEEDING COMPLETE');
  print('========================================');
  print('');
  print('Now you can run the screenshot tests and the data will be available.');
  print('The app will load with ${sites.length} sites in ${webspaces.length} webspaces.');
}
