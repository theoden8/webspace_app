import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;

import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/screens/add_site.dart' show AddSiteScreen, UnifiedFaviconImage;
import 'package:webspace/screens/settings.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/screens/inappbrowser.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/screens/webspace_detail.dart';
import 'package:webspace/widgets/find_toolbar.dart';
import 'package:webspace/widgets/url_bar.dart';
import 'package:webspace/demo_data.dart' show seedDemoData, isDemoMode;
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/settings/proxy.dart';

// Helper to convert ThemeMode to WebViewTheme
WebViewTheme _themeModeToWebViewTheme(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.dark:
      return WebViewTheme.dark;
    case ThemeMode.light:
      return WebViewTheme.light;
    case ThemeMode.system:
      return WebViewTheme.system;
  }
}

// extractDomain and getNormalizedDomain are imported from web_view_model.dart

// Cache for page titles
final Map<String, String?> _pageTitleCache = {};

// Get page title by parsing HTML (fallback for platforms without native title support)
Future<String?> getPageTitle(String url) async {
  // Check cache first
  if (_pageTitleCache.containsKey(url)) {
    return _pageTitleCache[url];
  }

  try {
    final response = await http.get(Uri.parse(url)).timeout(
      Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Page fetch timeout'),
    );

    if (response.statusCode == 200) {
      html_dom.Document document = html_parser.parse(response.body);
      final titleElement = document.querySelector('title');
      if (titleElement != null) {
        final title = titleElement.text.trim();
        if (title.isNotEmpty) {
          _pageTitleCache[url] = title;
          return title;
        }
      }
    }
  } catch (e) {
    // Silently handle errors
  }

  _pageTitleCache[url] = null;
  return null;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize platform info to detect proxy support before UI loads
  await PlatformInfo.initialize();
  runApp(WebSpaceApp());
}

class WebSpaceApp extends StatefulWidget {
  @override
  _WebSpaceAppState createState() => _WebSpaceAppState();
}

class _WebSpaceAppState extends State<WebSpaceApp> {
  ThemeMode _themeMode = ThemeMode.light;

  void _setThemeMode(ThemeMode themeMode) {
    setState(() {
      _themeMode = themeMode;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Color magicGreen = Color(0xFF7be592);
    return MaterialApp(
      title: 'WebSpace',
      theme: ThemeData.light().copyWith(
        primaryColor: Color(0xFF123456),
        colorScheme: ColorScheme.light().copyWith(
          secondary: magicGreen,
        ),
        scaffoldBackgroundColor: Color(0xFFFFFFFF),
      ),
      darkTheme: ThemeData.dark().copyWith(
        primaryColor: Color(0xFF123456),
        colorScheme: ColorScheme.dark().copyWith(
          secondary: magicGreen,
        ),
        scaffoldBackgroundColor: Color(0xFF000000),
      ),
      themeMode: _themeMode,
      home: WebSpacePage(onThemeModeChanged: _setThemeMode),
      debugShowCheckedModeBanner: false,
    );
  }
}

class WebSpacePage extends StatefulWidget {
  final Function(ThemeMode) onThemeModeChanged;

  WebSpacePage({required this.onThemeModeChanged});

  @override
  _WebSpacePageState createState() => _WebSpacePageState();
}

class _WebSpacePageState extends State<WebSpacePage> {
  int? _currentIndex;
  final List<WebViewModel> _webViewModels = [];
  ThemeMode _themeMode = ThemeMode.system;
  final CookieManager _cookieManager = CookieManager();
  final CookieSecureStorage _cookieSecureStorage = CookieSecureStorage();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _isFindVisible = false;
  bool _showUrlBar = false;

  // Webspace-related state
  final List<Webspace> _webspaces = [];
  String? _selectedWebspaceId;

  // Track which webview indices have been loaded (for lazy loading)
  // Only webviews in this set will be created - others remain as placeholders
  final Set<int> _loadedIndices = {};

  @override
  void initState() {
    super.initState();
    _restoreAppState();
  }

  Future<void> _saveWebViewModels() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();

    // Save cookies to secure storage, keyed by siteId for per-site isolation
    final Map<String, List<Cookie>> cookiesBySiteId = {};
    for (final webViewModel in _webViewModels) {
      if (webViewModel.cookies.isNotEmpty && !webViewModel.incognito) {
        cookiesBySiteId[webViewModel.siteId] = List.from(webViewModel.cookies);
      }
    }
    await _cookieSecureStorage.saveCookies(cookiesBySiteId);

    // Save models to SharedPreferences (cookies will be empty in SharedPreferences)
    List<String> webViewModelsJson = _webViewModels.map((webViewModel) {
      final json = webViewModel.toJson();
      json['cookies'] = []; // Don't store cookies in SharedPreferences
      return jsonEncode(json);
    }).toList();
    prefs.setStringList('webViewModels', webViewModelsJson);
  }

  Future<void> _saveCurrentIndex() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('currentIndex', _currentIndex == null ? 10000 : _currentIndex!);
  }

  Future<void> _saveThemeMode() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('themeMode', _themeMode.index);
  }

  Future<void> _saveShowUrlBar() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showUrlBar', _showUrlBar);
  }

  Future<void> _saveWebspaces() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> webspacesJson = _webspaces.map((webspace) => jsonEncode(webspace.toJson())).toList();
    prefs.setStringList('webspaces', webspacesJson);
  }

  Future<void> _saveSelectedWebspaceId() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (_selectedWebspaceId != null) {
      await prefs.setString('selectedWebspaceId', _selectedWebspaceId!);
    } else {
      await prefs.remove('selectedWebspaceId');
    }
  }

  /// Set the current index and mark it as loaded for lazy webview creation.
  /// This ensures only visited webviews are created, not all webviews at once.
  /// Also handles domain conflict detection for per-site cookie isolation.
  Future<void> _setCurrentIndex(int? index) async {
    if (index == null || index < 0 || index >= _webViewModels.length) {
      _currentIndex = index;
      return;
    }

    final target = _webViewModels[index];

    if (kDebugMode) {
      debugPrint('[CookieIsolation] Switching to site $index: "${target.name}" (siteId: ${target.siteId})');
      debugPrint('[CookieIsolation] Target domain: ${getBaseDomain(target.initUrl)}');
      debugPrint('[CookieIsolation] Currently loaded indices: $_loadedIndices');
    }

    // Only check for domain conflicts if target is not incognito
    if (!target.incognito) {
      // Use second-level domain for cookie isolation (e.g., all *.google.com sites conflict)
      final targetDomain = getBaseDomain(target.initUrl);

      // Find and unload any conflicting sites (same domain, already loaded)
      for (final loadedIndex in List.from(_loadedIndices)) {
        if (loadedIndex == index) continue;
        if (loadedIndex >= _webViewModels.length) continue;

        final loaded = _webViewModels[loadedIndex];
        if (loaded.incognito) continue; // Skip incognito sites

        final loadedDomain = getBaseDomain(loaded.initUrl);
        if (kDebugMode) {
          debugPrint('[CookieIsolation] Checking loaded site $loadedIndex: "${loaded.name}" domain: $loadedDomain');
        }
        if (loadedDomain == targetDomain) {
          // Domain conflict - unload the conflicting site
          if (kDebugMode) {
            debugPrint('[CookieIsolation] CONFLICT! Unloading site $loadedIndex');
          }
          await _unloadSiteForDomainSwitch(loadedIndex);
          break; // Only one conflict possible at a time
        }
      }
    }

    // Restore cookies for target site before loading
    await _restoreCookiesForSite(index);

    _currentIndex = index;
    _loadedIndices.add(index);
    if (kDebugMode) {
      debugPrint('[CookieIsolation] After switch, loaded indices: $_loadedIndices');
    }
  }

  /// Unloads a site due to domain conflict with another site.
  /// Captures cookies for ALL loaded sites, clears CookieManager, disposes conflicting webview.
  Future<void> _unloadSiteForDomainSwitch(int index) async {
    if (index < 0 || index >= _webViewModels.length) return;

    final model = _webViewModels[index];

    if (kDebugMode) {
      debugPrint('[CookieIsolation] Unloading site $index: "${model.name}" (siteId: ${model.siteId})');
    }

    // Capture cookies for ALL loaded sites before clearing
    // This preserves cookies for sites on other domains
    for (final loadedIndex in _loadedIndices) {
      if (loadedIndex >= _webViewModels.length) continue;
      final loadedModel = _webViewModels[loadedIndex];
      if (loadedModel.incognito) continue;

      await loadedModel.captureCookies(_cookieManager);
      await _cookieSecureStorage.saveCookiesForSite(loadedModel.siteId, loadedModel.cookies);

      if (kDebugMode) {
        debugPrint('[CookieIsolation] Captured ${loadedModel.cookies.length} cookies for site $loadedIndex: "${loadedModel.name}"');
      }
    }

    // Clear ALL cookies from CookieManager
    // We use deleteAllCookies() because sites like Google set cookies on multiple
    // domains (.google.com, accounts.google.com, etc.) that wouldn't be captured
    // by a single URL query.
    await _cookieManager.deleteAllCookies();

    if (kDebugMode) {
      debugPrint('[CookieIsolation] Cleared ALL cookies from CookieManager');
    }

    // Dispose webview for the conflicting site only
    model.disposeWebView();

    if (kDebugMode) {
      debugPrint('[CookieIsolation] Disposed webview for site $index');
    }

    // Remove from loaded indices
    _loadedIndices.remove(index);
  }

  /// Restores cookies for a site from secure storage before loading.
  Future<void> _restoreCookiesForSite(int index) async {
    if (index < 0 || index >= _webViewModels.length) return;

    final model = _webViewModels[index];
    if (model.incognito) return; // Don't restore cookies for incognito sites

    // Load persisted cookies by siteId
    final cookies = await _cookieSecureStorage.loadCookiesForSite(model.siteId);
    model.cookies = cookies;

    if (kDebugMode) {
      debugPrint('[CookieIsolation] Restoring ${cookies.length} cookies for site $index: "${model.name}" (siteId: ${model.siteId})');
    }

    // Restore cookies to CookieManager
    final url = Uri.parse(model.initUrl);
    for (final cookie in cookies) {
      if (cookie.value.isEmpty) continue;
      await _cookieManager.setCookie(
        url: url,
        name: cookie.name,
        value: cookie.value,
        domain: cookie.domain,
        path: cookie.path ?? '/',
        expiresDate: cookie.expiresDate,
        isSecure: cookie.isSecure,
        isHttpOnly: cookie.isHttpOnly,
      );
    }
  }

  /// Shows a popup window for handling window.open() requests from webviews.
  /// Used for Cloudflare Turnstile challenges and other popup-based flows.
  Future<void> _showPopupWindow(int windowId, String url) async {
    if (!mounted) return;

    if (kDebugMode) {
      debugPrint('[PopupWindow] Opening popup window with id: $windowId, url: $url');
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return Dialog(
          insetPadding: EdgeInsets.all(16),
          child: Container(
            width: MediaQuery.of(dialogContext).size.width * 0.9,
            height: MediaQuery.of(dialogContext).size.height * 0.8,
            child: Column(
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Verification', style: TextStyle(fontWeight: FontWeight.bold)),
                      IconButton(
                        icon: Icon(Icons.close),
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: WebViewFactory.createPopupWebView(
                    windowId: windowId,
                    onCloseWindow: () {
                      if (Navigator.of(dialogContext).canPop()) {
                        Navigator.of(dialogContext).pop();
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (kDebugMode) {
      debugPrint('[PopupWindow] Popup window closed');
    }
  }

  Future<void> _loadWebspaces() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? webspacesJson = prefs.getStringList('webspaces');

    if (webspacesJson != null) {
      List<Webspace> loadedWebspaces = webspacesJson
          .map((webspaceJson) => Webspace.fromJson(jsonDecode(webspaceJson)))
          .toList();

      setState(() {
        _webspaces.addAll(loadedWebspaces);
      });
    }

    // Ensure "All" webspace always exists
    _ensureAllWebspaceExists();

    _selectedWebspaceId = prefs.getString('selectedWebspaceId');

    // If no webspace is selected, select "All" by default
    if (_selectedWebspaceId == null) {
      _selectedWebspaceId = kAllWebspaceId;
    }
  }

  void _ensureAllWebspaceExists() {
    // Check if "All" webspace already exists
    final hasAll = _webspaces.any((ws) => ws.id == kAllWebspaceId);

    if (!hasAll) {
      setState(() {
        _webspaces.insert(0, Webspace.all());
      });
    } else {
      // Ensure "All" is at the beginning
      final allIndex = _webspaces.indexWhere((ws) => ws.id == kAllWebspaceId);
      if (allIndex > 0) {
        setState(() {
          final allWebspace = _webspaces.removeAt(allIndex);
          _webspaces.insert(0, allWebspace);
        });
      }
    }
  }

  Future<void> _loadWebViewModels() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? webViewModelsJson = prefs.getStringList('webViewModels');

    if (webViewModelsJson != null) {
      List<WebViewModel> loadedWebViewModels = webViewModelsJson
          .map((webViewModelJson) => WebViewModel.fromJson(jsonDecode(webViewModelJson), (){setState((){});}))
          .toList();

      // Load cookies from secure storage (keyed by siteId or legacy domain)
      final secureCookies = await _cookieSecureStorage.loadCookies();

      // Load cookies into models by siteId (or migrate from domain-keyed)
      for (final webViewModel in loadedWebViewModels) {
        // Try siteId first (new format)
        var siteCookies = secureCookies[webViewModel.siteId];
        if (siteCookies == null || siteCookies.isEmpty) {
          // Fallback: try domain-keyed (legacy migration)
          final domain = extractDomain(webViewModel.initUrl);
          siteCookies = secureCookies[domain];
        }
        if (siteCookies != null && siteCookies.isNotEmpty) {
          webViewModel.cookies = siteCookies;
        }
      }

      setState(() {
        _webViewModels.addAll(loadedWebViewModels);
      });

      // NOTE: We don't restore cookies to CookieManager here anymore.
      // Cookies are restored per-site via _restoreCookiesForSite() when
      // a site is selected via _setCurrentIndex(). This enables per-site
      // cookie isolation for same-domain sites.

      // Re-save to migrate cookies to siteId-keyed format
      await _saveWebViewModels();
    }
  }

  Future<void> _restoreAppState() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      _themeMode = ThemeMode.values[prefs.getInt('themeMode') ?? 0];
      _showUrlBar = prefs.getBool('showUrlBar') ?? false;
      widget.onThemeModeChanged(_themeMode);
    });
    await _loadWebspaces();
    await _loadWebViewModels();

    // Validate and determine the index to restore
    int? indexToRestore;
    int? savedIndex = prefs.getInt('currentIndex');
    if (savedIndex != null && savedIndex < _webViewModels.length && savedIndex != 10000) {
      // Check if the index is valid for the selected webspace
      if (_selectedWebspaceId != null) {
        final filteredIndices = _getFilteredSiteIndices();
        if (filteredIndices.contains(savedIndex)) {
          indexToRestore = savedIndex;
        }
      }
    }

    // Set current index (async for cookie restoration)
    await _setCurrentIndex(indexToRestore);
    setState(() {}); // Trigger UI update after async operation

    // Apply saved theme to all restored webviews
    final webViewTheme = _themeModeToWebViewTheme(_themeMode);
    for (var webViewModel in _webViewModels) {
      await webViewModel.setTheme(webViewTheme);
    }
  }

  Future<void> launchUrl(String url, {String? homeTitle}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => InAppWebViewScreen(url: url, homeTitle: homeTitle),
      ),
    );
  }

  void _toggleFind() {
    setState(() {
      _isFindVisible = !_isFindVisible;
    });
  }

  // Webspace management methods
  void _addWebspace() async {
    final webspace = Webspace(name: '');
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WebspaceDetailScreen(
          webspace: webspace,
          allSites: _webViewModels,
          onSave: (updatedWebspace) {
            setState(() {
              _webspaces.add(updatedWebspace);
            });
            _saveWebspaces();
          },
        ),
      ),
    );
  }

  void _editWebspace(Webspace webspace) async {
    // For "All" webspace, show all sites as selected but read-only
    final webspaceToEdit = webspace.id == kAllWebspaceId
        ? Webspace(
            id: kAllWebspaceId,
            name: 'All',
            siteIndices: List<int>.generate(_webViewModels.length, (index) => index),
          )
        : webspace;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WebspaceDetailScreen(
          webspace: webspaceToEdit,
          allSites: _webViewModels,
          isReadOnly: webspace.id == kAllWebspaceId,
          onSave: (updatedWebspace) {
            // Don't save changes for "All" webspace
            if (updatedWebspace.id == kAllWebspaceId) return;

            setState(() {
              final index = _webspaces.indexWhere((ws) => ws.id == updatedWebspace.id);
              if (index != -1) {
                _webspaces[index] = updatedWebspace;
              }
            });
            _saveWebspaces();
          },
        ),
      ),
    );
  }

  void _deleteWebspace(Webspace webspace) async {
    // Prevent deletion of "All" webspace
    if (webspace.id == kAllWebspaceId) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot delete the "All" webspace')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete Webspace'),
        content: Text('Are you sure you want to delete "${webspace.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final wasSelected = _selectedWebspaceId == webspace.id;
      setState(() {
        _webspaces.removeWhere((ws) => ws.id == webspace.id);
        if (wasSelected) {
          _selectedWebspaceId = kAllWebspaceId; // Select "All" instead of null
        }
      });
      if (wasSelected) {
        await _setCurrentIndex(null);
      }
      await _saveWebspaces();
      await _saveSelectedWebspaceId();
      await _saveCurrentIndex();
    }
  }

  void _selectWebspace(Webspace webspace) async {
    setState(() {
      _selectedWebspaceId = webspace.id;
    });
    await _setCurrentIndex(null);
    setState(() {}); // Update UI
    _saveSelectedWebspaceId();
    _saveCurrentIndex();
    // Open drawer after selecting workspace
    _scaffoldKey.currentState?.openDrawer();
  }

  void _reorderWebspaces(int oldIndex, int newIndex) {
    // Don't allow reordering if "All" is involved (it stays at index 0)
    if (oldIndex == 0 || newIndex == 0) return;

    setState(() {
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      final webspace = _webspaces.removeAt(oldIndex);
      _webspaces.insert(newIndex, webspace);
    });
    _saveWebspaces();
  }

  List<int> _getFilteredSiteIndices() {
    if (_selectedWebspaceId == null) {
      return [];
    }

    // If "All" webspace is selected, return all site indices
    if (_selectedWebspaceId == kAllWebspaceId) {
      return List<int>.generate(_webViewModels.length, (index) => index);
    }

    final webspace = _webspaces.firstWhere(
      (ws) => ws.id == _selectedWebspaceId,
      orElse: () => Webspace(name: '', siteIndices: []),
    );
    // Filter out indices that are out of bounds
    return webspace.siteIndices
        .where((index) => index >= 0 && index < _webViewModels.length)
        .toList();
  }

  void _cleanupWebspaceIndices() {
    // Clean up invalid indices in all webspaces after site deletion/reordering
    for (var webspace in _webspaces) {
      webspace.siteIndices = webspace.siteIndices
          .where((index) => index >= 0 && index < _webViewModels.length)
          .toList();
    }
    _saveWebspaces();
  }

  // Export settings to a file
  Future<void> _exportSettings() async {
    await SettingsBackupService.exportAndSave(
      context,
      webViewModels: _webViewModels,
      webspaces: _webspaces,
      themeMode: _themeMode.index,
      showUrlBar: _showUrlBar,
      selectedWebspaceId: _selectedWebspaceId,
      currentIndex: _currentIndex,
    );
  }

  // Import settings from a file
  Future<void> _importSettings() async {
    final backup = await SettingsBackupService.pickAndImport(context);
    if (backup == null) {
      return;
    }

    // Show confirmation dialog with backup info
    final sitesCount = backup.sites.length;
    final webspacesCount = backup.webspaces.length;
    final exportDate = backup.exportedAt.toLocal().toString().split('.')[0];

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Import Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Import $sitesCount site(s) and $webspacesCount webspace(s)?'),
            SizedBox(height: 12),
            Text(
              'Exported: $exportDate',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            SizedBox(height: 16),
            Text(
              'Your login sessions will be preserved for matching domains. '
              'Logins for removed sites will be cleared.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Import'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    // Apply the imported settings
    setState(() {
      // Clear existing data
      _webViewModels.clear();
      _webspaces.clear();
      _loadedIndices.clear(); // Clear lazy loading state

      // Restore sites
      _webViewModels.addAll(
        SettingsBackupService.restoreSites(backup, () {
          setState(() {});
        }),
      );

      // Restore webspaces
      _webspaces.addAll(SettingsBackupService.restoreWebspaces(backup));

      // Restore other settings
      _themeMode = ThemeMode.values[backup.themeMode.clamp(0, ThemeMode.values.length - 1)];
      _showUrlBar = backup.showUrlBar;

      // Restore selection state
      if (backup.selectedWebspaceId != null &&
          _webspaces.any((ws) => ws.id == backup.selectedWebspaceId)) {
        _selectedWebspaceId = backup.selectedWebspaceId;
      } else {
        _selectedWebspaceId = kAllWebspaceId;
      }
    });

    // Restore current index if valid (async for cookie handling)
    int? indexToRestore;
    if (backup.currentIndex != null &&
        backup.currentIndex! >= 0 &&
        backup.currentIndex! < _webViewModels.length) {
      indexToRestore = backup.currentIndex;
    }
    await _setCurrentIndex(indexToRestore);
    setState(() {}); // Update UI after async operation

    // Apply theme to app
    widget.onThemeModeChanged(_themeMode);

    // Save all settings
    await _saveWebViewModels();
    await _saveWebspaces();
    await _saveThemeMode();
    await _saveShowUrlBar();
    await _saveSelectedWebspaceId();
    await _saveCurrentIndex();

    // Clean up orphaned cookies (cookies for siteIds no longer in any site)
    final activeSiteIds = _webViewModels
        .map((model) => model.siteId)
        .toSet();
    await _cookieSecureStorage.removeOrphanedCookies(activeSiteIds);

    // Apply theme to all webviews
    final webViewTheme = _themeModeToWebViewTheme(_themeMode);
    for (var webViewModel in _webViewModels) {
      await webViewModel.setTheme(webViewTheme);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Settings imported successfully')),
      );
    }
  }

  WebViewController? getController() {
    if(_currentIndex == null) {
      return null;
    }
    return _webViewModels[_currentIndex!].getController(launchUrl, _cookieManager, _saveWebViewModels);
  }

  IconData _getThemeIcon() {
    switch (_themeMode) {
      case ThemeMode.light:
        return Icons.wb_sunny;
      case ThemeMode.dark:
        return Icons.nights_stay;
      case ThemeMode.system:
        return Icons.brightness_auto;
    }
  }

  String _getThemeTooltip() {
    switch (_themeMode) {
      case ThemeMode.light:
        return 'Light theme';
      case ThemeMode.dark:
        return 'Dark theme';
      case ThemeMode.system:
        return 'System theme';
    }
  }

  AppBar _buildAppBar() {
    return AppBar(
      title: _currentIndex != null && _currentIndex! < _webViewModels.length
          ? GestureDetector(
              onTap: () {
                _editSite(_currentIndex!);
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      _webViewModels[_currentIndex!].getDisplayName(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                  SizedBox(width: 8),
                  Icon(Icons.edit, size: 18),
                ],
              ),
            )
          : Text(_selectedWebspaceId != null
              ? _webspaces.firstWhere(
                  (ws) => ws.id == _selectedWebspaceId,
                  orElse: () => Webspace(name: 'Unknown'),
                ).name
              : 'No Webspace Selected'),
      actions: [
        if (_currentIndex != null && _currentIndex! < _webViewModels.length)
          IconButton(
            icon: Icon(Icons.arrow_back),
            tooltip: 'Go Back',
            onPressed: () async {
              final controller = getController();
              if (controller != null) {
                final canGoBack = await controller.canGoBack();
                if (canGoBack) {
                  await controller.goBack();
                }
              }
            },
          ),
        if (_currentIndex != null && _currentIndex! < _webViewModels.length)
          IconButton(
            icon: Icon(Icons.home),
            tooltip: 'Go to Home',
            onPressed: () async {
              final controller = getController();
              if (controller != null) {
                await controller.loadUrl(_webViewModels[_currentIndex!].initUrl);
              }
            },
          ),
        IconButton(
          icon: Icon(_getThemeIcon()),
          tooltip: _getThemeTooltip(),
          onPressed: () async {
            setState(() {
              // Cycle through light → dark → system
              switch (_themeMode) {
                case ThemeMode.light:
                  _themeMode = ThemeMode.dark;
                  break;
                case ThemeMode.dark:
                  _themeMode = ThemeMode.system;
                  break;
                case ThemeMode.system:
                  _themeMode = ThemeMode.light;
                  break;
              }
            });
            widget.onThemeModeChanged(_themeMode);
            await _saveThemeMode();

            // Apply theme to all webviews
            final webViewTheme = _themeModeToWebViewTheme(_themeMode);
            for (var webViewModel in _webViewModels) {
              await webViewModel.setTheme(webViewTheme);
            }
          },
        ),
        PopupMenuButton<String>(
          itemBuilder: (BuildContext context) {
            final bool onWebspacesList = _currentIndex == null || _currentIndex! >= _webViewModels.length;
            return [
              if (_currentIndex != null && _currentIndex! < _webViewModels.length)
              PopupMenuItem<String>(
                value: "refresh",
                child: Row(
                  children: [
                    Icon(Icons.refresh),
                    SizedBox(width: 8),
                    Text("Refresh"),
                  ],
                ),
              ),
              if (_currentIndex != null && _currentIndex! < _webViewModels.length)
              PopupMenuItem<String>(
                value: "search",
                child: Row(
                  children: [
                    Icon(Icons.search),
                    SizedBox(width: 8),
                    Text("Find"),
                  ],
                ),
              ),
              if (_currentIndex != null && _currentIndex! < _webViewModels.length)
              PopupMenuItem<String>(
                value: "clear",
                child: Row(
                  children: [
                    Icon(Icons.cookie),
                    SizedBox(width: 8),
                    Text("Clear Cookies"),
                  ],
                ),
              ),
              if (_currentIndex != null && _currentIndex! < _webViewModels.length)
              PopupMenuItem<String>(
                value: "toggleUrlBar",
                child: Row(
                  children: [
                    Icon(_showUrlBar ? Icons.visibility_off : Icons.visibility),
                    SizedBox(width: 8),
                    Text(_showUrlBar ? "Hide URL Bar" : "Show URL Bar"),
                  ],
                ),
              ),
              if (_currentIndex != null && _currentIndex! < _webViewModels.length)
              PopupMenuItem<String>(
                value: "settings",
                child: Row(
                  children: [
                    Icon(Icons.settings),
                    SizedBox(width: 8),
                    Text("Settings"),
                  ],
                ),
              ),
              // Import/Export options (only visible on webspaces list screen)
              if (onWebspacesList)
              PopupMenuItem<String>(
                value: "export",
                child: Row(
                  children: [
                    Icon(Icons.upload),
                    SizedBox(width: 8),
                    Text("Export Settings"),
                  ],
                ),
              ),
              if (onWebspacesList)
              PopupMenuItem<String>(
                value: "import",
                child: Row(
                  children: [
                    Icon(Icons.download),
                    SizedBox(width: 8),
                    Text("Import Settings"),
                  ],
                ),
              ),
            ];
          },
          onSelected: (String value) async {
            switch(value) {
              case 'search':
                _toggleFind();
              break;
              case 'refresh':
                getController()?.reload();
              break;
              case 'settings':
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => SettingsScreen(
                      webViewModel: _webViewModels[_currentIndex!],
                      onProxySettingsChanged: (newProxySettings) {
                        // Sync proxy settings to all WebViewModels (proxy is global)
                        setState(() {
                          for (var model in _webViewModels) {
                            model.proxySettings = UserProxySettings(
                              type: newProxySettings.type,
                              address: newProxySettings.address,
                            );
                          }
                        });
                        // Persist the changes immediately
                        _saveWebViewModels();
                      },
                    ),
                  ),
                );
                _saveWebViewModels();
              break;
              case 'clear':
                _webViewModels[_currentIndex!].deleteCookies(_cookieManager);
                _saveWebViewModels();
                getController()?.reload();
              break;
              case 'toggleUrlBar':
                setState(() {
                  _showUrlBar = !_showUrlBar;
                });
                _saveShowUrlBar();
              break;
              case 'export':
                await _exportSettings();
              break;
              case 'import':
                await _importSettings();
              break;
            }
          },
        ),
      ],
    );
  }

  void _addSite() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddSiteScreen(
          themeMode: _themeMode,
          onThemeModeChanged: (ThemeMode mode) async {
            setState(() {
              _themeMode = mode;
            });
            widget.onThemeModeChanged(_themeMode);
            await _saveThemeMode();

            // Apply theme to all webviews
            final webViewTheme = _themeModeToWebViewTheme(_themeMode);
            for (var webViewModel in _webViewModels) {
              await webViewModel.setTheme(webViewTheme);
            }
          },
        ),
      ),
    );
    if (result != null && result is Map<String, dynamic>) {
      final url = result['url'] as String;
      final customName = result['name'] as String;
      final incognito = result['incognito'] as bool? ?? false;

      // Try to fetch page title if custom name not provided
      String? pageTitle;
      if (customName.isEmpty) {
        pageTitle = await getPageTitle(url);
      }

      final model = WebViewModel(
        initUrl: url,
        incognito: incognito,
        stateSetterF: () {setState((){});},
      );
      if (customName.isNotEmpty) {
        model.name = customName;
        model.pageTitle = customName;
      } else if (pageTitle != null && pageTitle.isNotEmpty) {
        model.name = pageTitle;
        model.pageTitle = pageTitle;
      }

      setState(() {
        _webViewModels.add(model);
      });

      final newSiteIndex = _webViewModels.length - 1;

      // If a non-"All" webspace is currently selected, add the new site to it
      if (_selectedWebspaceId != null && _selectedWebspaceId != kAllWebspaceId) {
        final webspaceIndex = _webspaces.indexWhere((ws) => ws.id == _selectedWebspaceId);
        if (webspaceIndex != -1) {
          _webspaces[webspaceIndex].siteIndices.add(newSiteIndex);
          _saveWebspaces();
        }
      }

      // Set current index (async for cookie handling)
      await _setCurrentIndex(newSiteIndex);
      setState(() {}); // Update UI after async operation

      _saveCurrentIndex();
      _saveWebViewModels();

      // Apply current theme to new webview
      final webViewTheme = _themeModeToWebViewTheme(_themeMode);
      await model.setTheme(webViewTheme);
    }
  }

  void _editSite(int index) async {
    final nameController = TextEditingController(text: _webViewModels[index].name);
    final urlController = TextEditingController(text: _webViewModels[index].initUrl);

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit Site'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Site Name',
                hintText: 'Enter a custom name',
              ),
            ),
            SizedBox(height: 16),
            TextField(
              controller: urlController,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'URL',
                hintText: 'http://example.com:8080',
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Tip: Include http:// for HTTP sites, or leave it out for HTTPS',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final name = nameController.text.trim();
              var url = urlController.text.trim();

              // Infer protocol if not specified
              if (!url.startsWith('http://') && !url.startsWith('https://')) {
                url = 'https://$url';
              }

              Navigator.pop(context, {'name': name, 'url': url});
            },
            child: Text('Save'),
          ),
        ],
      ),
    );

    if (result != null) {
      final newName = result['name'];
      final newUrl = result['url'];

      if (newName != null && newName.isNotEmpty) {
        setState(() {
          _webViewModels[index].name = newName;
        });
      }

      if (newUrl != null && newUrl != _webViewModels[index].initUrl) {
        setState(() {
          _webViewModels[index].initUrl = newUrl;
          _webViewModels[index].currentUrl = newUrl;
          _webViewModels[index].webview = null; // Force recreation with new URL
          _webViewModels[index].controller = null;
        });
      }

      _saveWebViewModels();
    }
  }

  Widget _buildSiteListTile(BuildContext context, int index) {
    return Semantics(
      key: Key('site_$index'),
      label: _webViewModels[index].getDisplayName(),
      button: true,
      enabled: true,
      child: ListTile(
      leading: UnifiedFaviconImage(
        url: _webViewModels[index].initUrl,
        size: 20,
      ),
      title: Text(
        _webViewModels[index].getDisplayName(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
      ),
      subtitle: Text(
        extractDomain(_webViewModels[index].initUrl),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: TextStyle(fontSize: 12, color: Colors.grey),
      ),
      onTap: () async {
        Navigator.pop(context);
        await _setCurrentIndex(index);
        setState(() {});
        _saveCurrentIndex();
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(Icons.refresh),
            tooltip: 'Refresh title',
            iconSize: 20,
            onPressed: () async {
              final title = await getPageTitle(_webViewModels[index].initUrl);
              if (title != null && title.isNotEmpty) {
                setState(() {
                  _webViewModels[index].name = title;
                  _webViewModels[index].pageTitle = title;
                });
                _saveWebViewModels();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Title updated to: $title')),
                );
              }
            },
          ),
          IconButton(
            icon: Icon(Icons.edit),
            tooltip: 'Edit',
            iconSize: 20,
            onPressed: () {
              _editSite(index);
            },
          ),
          IconButton(
            icon: Icon(Icons.delete),
            tooltip: 'Delete',
            iconSize: 20,
            onPressed: () async {
              final siteName = _webViewModels[index].getDisplayName();
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('Delete Site'),
                  content: Text('Are you sure you want to delete "$siteName"?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text('Delete'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.red,
                      ),
                    ),
                  ],
                ),
              );

              if (confirmed == true) {
                final wasCurrentIndex = _currentIndex == index;
                setState(() {
                  _webViewModels.removeAt(index);
                  // Update _loadedIndices after deletion (shift indices down)
                  _loadedIndices.remove(index);
                  _loadedIndices.removeWhere((i) => i >= _webViewModels.length);
                  final updatedIndices = _loadedIndices
                      .map((i) => i > index ? i - 1 : i)
                      .toSet();
                  _loadedIndices.clear();
                  _loadedIndices.addAll(updatedIndices);
                  // Update webspace indices after deletion
                  for (var webspace in _webspaces) {
                    webspace.siteIndices = webspace.siteIndices
                        .where((i) => i != index)
                        .map((i) => i > index ? i - 1 : i)
                        .toList();
                  }
                });
                if (wasCurrentIndex) {
                  await _setCurrentIndex(null);
                  _saveCurrentIndex();
                }
                _saveWebViewModels();
                _saveWebspaces();
                Navigator.pop(context);
              }
            },
          ),
        ],
      ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: _buildAppBar(),
      drawer: Drawer(
        child: Column(
          children: [
            SafeArea(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: () async {
                        await _setCurrentIndex(null);
                        setState(() {});
                        _saveSelectedWebspaceId();
                        _saveCurrentIndex();
                        Navigator.pop(context);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          children: [
                            Icon(
                              Icons.workspaces,
                              size: 72,
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                          SizedBox(height: 8),
                          Text(
                            _selectedWebspaceId != null
                                ? _webspaces.firstWhere((ws) => ws.id == _selectedWebspaceId, orElse: () => Webspace(name: 'Unknown')).name
                                : 'No webspace',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Semantics(
                    label: 'Back to Webspaces',
                    button: true,
                    enabled: true,
                    child: TextButton.icon(
                      onPressed: () async {
                        await _setCurrentIndex(null);
                        setState(() {});
                        _saveSelectedWebspaceId();
                        _saveCurrentIndex();
                        Navigator.pop(context);
                      },
                      icon: Icon(Icons.arrow_back, size: 16),
                      label: Text('Back to Webspaces', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ),
            ),
            ),
            Expanded(
              child: _selectedWebspaceId == null
                  ? Center(
                      child: Text('Select a webspace to view sites'),
                    )
                  : () {
                      final filteredIndices = _getFilteredSiteIndices();
                      if (filteredIndices.isEmpty) {
                        return Center(
                          child: Text('No sites in this webspace'),
                        );
                      }

                      // Use ListView for "All" webspace (no reordering)
                      // Use ReorderableListView for custom webspaces
                      final isAllWebspace = _selectedWebspaceId == kAllWebspaceId;

                      if (isAllWebspace) {
                        return ListView.builder(
                          itemCount: filteredIndices.length,
                          itemBuilder: (BuildContext context, int listIndex) {
                            final index = filteredIndices[listIndex];
                            return _buildSiteListTile(context, index);
                          },
                        );
                      }

                      return ReorderableListView.builder(
                        itemCount: filteredIndices.length,
                        onReorder: (int oldListIndex, int newListIndex) {
                          setState(() {
                            // Adjust newListIndex if moving down
                            if (newListIndex > oldListIndex) {
                              newListIndex -= 1;
                            }

                            // Get the webspace and reorder its siteIndices
                            final webspace = _webspaces.firstWhere(
                              (ws) => ws.id == _selectedWebspaceId,
                            );

                            // Remove from old position and insert at new position
                            final movedIndex = webspace.siteIndices.removeAt(oldListIndex);
                            webspace.siteIndices.insert(newListIndex, movedIndex);
                          });
                          _saveWebspaces();
                        },
                        itemBuilder: (BuildContext context, int listIndex) {
                          final index = filteredIndices[listIndex];
                          return _buildSiteListTile(context, index);
                        },
                      );
                    }(),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    _addSite();
                  },
                  icon: Icon(Icons.add),
                  label: Text('Add Site'),
                ),
              ),
            ),
            SizedBox(height: 8.0),
          ],
        ),
      ),
      body: _currentIndex == null || _currentIndex! >= _webViewModels.length
          ? WebspacesListScreen(
              webspaces: _webspaces,
              selectedWebspaceId: _selectedWebspaceId,
              totalSitesCount: _webViewModels.length,
              onSelectWebspace: _selectWebspace,
              onAddWebspace: _addWebspace,
              onEditWebspace: _editWebspace,
              onDeleteWebspace: _deleteWebspace,
              onReorder: _reorderWebspaces,
            )
          : IndexedStack(
              index: _currentIndex!,
              // Lazy loading: only create webviews for indices that have been visited
              // This prevents all webviews from loading simultaneously when any site is selected
              children: _webViewModels.asMap().entries.map<Widget>((entry) {
                final index = entry.key;
                final webViewModel = entry.value;

                // Only create actual webview if this index has been loaded
                if (!_loadedIndices.contains(index)) {
                  return const SizedBox.shrink(); // Placeholder for unvisited sites
                }

                return Column(
                  key: ValueKey(webViewModel.siteId), // Ensure correct widget identity
                  children: [
                    if(_isFindVisible && _currentIndex == index && getController() != null)
                      FindToolbar(
                        webViewController: getController(),
                        matches: webViewModel.findMatches,
                        onClose: () {
                          _toggleFind();
                        },
                      ),
                    if(_showUrlBar && _currentIndex == index)
                      UrlBar(
                        currentUrl: webViewModel.currentUrl,
                        onUrlSubmitted: (url) async {
                          final controller = webViewModel.getController(launchUrl, _cookieManager, _saveWebViewModels);
                          if (controller != null) {
                            await controller.loadUrl(url, language: webViewModel.language);
                            setState(() {
                              webViewModel.currentUrl = url;
                            });
                            await _saveWebViewModels();
                          }
                        },
                      ),
                    Expanded(
                      child: webViewModel.getWebView(
                        launchUrl,
                        _cookieManager,
                        _saveWebViewModels,
                        onWindowRequested: _showPopupWindow,
                        language: webViewModel.language,
                      )
                    ),
                  ],
                );
              }).toList(),
            ),
      floatingActionButton:
          !(_currentIndex == null || _currentIndex! >= _webViewModels.length) ? null
          : FloatingActionButton(
              onPressed: () async {
                _addSite();
              },
              child: Icon(Icons.add),
            ),
    );
  }
}
