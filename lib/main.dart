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
import 'package:webspace/platform/unified_webview.dart';
import 'package:webspace/platform/webview_factory.dart';
import 'package:webspace/screens/add_site.dart' show AddSiteScreen, UnifiedFaviconImage;
import 'package:webspace/screens/settings.dart';
import 'package:webspace/screens/inappbrowser.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/screens/webspace_detail.dart';
import 'package:webspace/widgets/find_toolbar.dart';
import 'package:webspace/widgets/url_bar.dart';
import 'package:webspace/demo_data.dart';

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

String extractDomain(String url) {
  Uri uri = Uri.tryParse(url) ?? Uri();
  String? domain = uri.host;
  return domain.isEmpty ? url : domain;
}

// Cache for favicon URLs to avoid repeated requests
final Map<String, String?> _faviconCache = {};
final Map<String, String?> _pageTitleCache = {};

// Domain substitution rules for better icon results
// Some services have different domains for their main site vs their icon-rich pages
const Map<String, String> _domainSubstitutions = {
  'gmail.com': 'mail.google.com',
  // Add more substitutions here as needed
  // 'example.com': 'icons.example.com',
};

// Apply domain substitution rules
String _applyDomainSubstitution(String domain) {
  return _domainSubstitutions[domain] ?? domain;
};

// Icon candidate with quality scoring
class _IconCandidate {
  final String url;
  final int quality;
  final bool verified; // Whether the URL has already been verified as accessible

  _IconCandidate(this.url, this.quality, {this.verified = false});
}

// Helper: Verify icon URL is accessible
Future<bool> _verifyIconUrl(String iconUrl) async {
  try {
    final iconResponse = await http.head(Uri.parse(iconUrl)).timeout(
      Duration(seconds: 2),
    );
    return iconResponse.statusCode == 200;
  } catch (e) {
    if (kDebugMode) {
      print('[Icon] Failed to verify $iconUrl: $e');
    }
    return false;
  }
}

// Helper: Resolve relative URLs to absolute
String _resolveIconUrl(String href, String scheme, String baseUrl) {
  if (href.startsWith('http://') || href.startsWith('https://')) {
    return href;
  } else if (href.startsWith('//')) {
    return '$scheme:$href';
  } else if (href.startsWith('/')) {
    return '$baseUrl$href';
  } else {
    return '$baseUrl/$href';
  }
}

// Helper: Try Google Favicon service
Future<String?> _tryGoogleFavicon(String domain, int size) async {
  try {
    final googleUrl = 'https://www.google.com/s2/favicons?domain=$domain&sz=$size';
    if (await _verifyIconUrl(googleUrl)) {
      if (kDebugMode) {
        print('[Icon] Found Google favicon at ${size}px for $domain');
      }
      return googleUrl;
    }
  } catch (e) {
    if (kDebugMode) {
      print('[Icon] Google ${size}px failed for $domain: $e');
    }
  }
  return null;
}

// Helper: Extract icons from HTML
Future<List<_IconCandidate>> _extractIconsFromHtml(
  String url,
  String scheme,
  String baseUrl,
) async {
  List<_IconCandidate> candidates = [];

  try {
    final pageResponse = await http.get(Uri.parse(url)).timeout(
      Duration(seconds: 3),
      onTimeout: () => throw TimeoutException('Page fetch timeout'),
    );

    if (pageResponse.statusCode == 200) {
      html_dom.Document document = html_parser.parse(pageResponse.body);

      // Extract and cache page title while we're at it
      final titleElement = document.querySelector('title');
      if (titleElement != null && titleElement.text.isNotEmpty) {
        _pageTitleCache[url] = titleElement.text;
      }

      // Look for favicon in <link> tags
      List<String> iconRels = ['icon', 'shortcut icon', 'apple-touch-icon'];

      for (String rel in iconRels) {
        var linkElements = document.querySelectorAll('link[rel*="$rel"]');
        for (var link in linkElements) {
          String? href = link.attributes['href'];
          String? type = link.attributes['type'];
          String? sizes = link.attributes['sizes'];

          if (href != null && href.isNotEmpty) {
            String iconUrl = _resolveIconUrl(href, scheme, baseUrl);
            int quality = 16; // default for unknown size

            // Check if it's an SVG icon (best quality!)
            bool isSvg = type == 'image/svg+xml' || href.toLowerCase().endsWith('.svg');
            if (isSvg) {
              quality = 1000;
            } else if (sizes != null) {
              // Parse sizes attribute (e.g., "128x128", "any")
              if (sizes.contains('256')) {
                quality = 256;
              } else if (sizes.contains('128') || sizes.contains('any')) {
                quality = 128;
              }
            }

            candidates.add(_IconCandidate(iconUrl, quality));
          }
        }
      }

      if (kDebugMode && candidates.isNotEmpty) {
        print('[Icon] Found ${candidates.length} icon(s) in HTML for $url');
      }
    }
  } catch (e) {
    if (kDebugMode) {
      print('[Icon] HTML parsing failed for $url: $e');
    }
  }

  return candidates;
}

Future<String?> getFaviconUrl(String url) async {
  // Check cache first - return immediately if cached
  if (_faviconCache.containsKey(url)) {
    if (kDebugMode) {
      print('[Icon] Using cached icon for $url');
    }
    return _faviconCache[url];
  }

  Uri? uri = Uri.tryParse(url);
  if (uri == null) {
    _faviconCache[url] = null;
    return null;
  }

  String scheme = uri.scheme;
  String host = uri.host;
  int? port = uri.hasPort ? uri.port : null;
  String domain = _applyDomainSubstitution(host);

  if (scheme.isEmpty || host.isEmpty) {
    _faviconCache[url] = null;
    return null;
  }

  String baseUrl = port != null ? '$scheme://$host:$port' : '$scheme://$host';

  if (kDebugMode) {
    print('[Icon] Fetching icon for $url (domain: $domain)');
  }

  // Quality scoring:
  // 1000: SVG (scale-invariant, best quality)
  // 256: Google 256px
  // 128: Google 128px, HTML high-res icons
  // 64: DuckDuckGo
  // 32: /favicon.ico fallback
  // 16: HTML unknown size icons

  // Try all sources IN PARALLEL to avoid UI freezing
  final results = await Future.wait([
    // Google 256px (already verified by _tryGoogleFavicon)
    _tryGoogleFavicon(domain, 256).then((url) =>
      url != null ? _IconCandidate(url, 256, verified: true) : null
    ),
    // Google 128px (already verified by _tryGoogleFavicon)
    _tryGoogleFavicon(domain, 128).then((url) =>
      url != null ? _IconCandidate(url, 128, verified: true) : null
    ),
    // HTML parsing for native icons (NOT verified yet)
    _extractIconsFromHtml(url, scheme, baseUrl),
    // DuckDuckGo (verified here)
    Future(() async {
      try {
        final ddg = 'https://icons.duckduckgo.com/ip3/$domain.ico';
        if (await _verifyIconUrl(ddg)) {
          if (kDebugMode) {
            print('[Icon] Found DuckDuckGo icon for $domain');
          }
          return _IconCandidate(ddg, 64, verified: true);
        }
      } catch (e) {
        if (kDebugMode) {
          print('[Icon] DuckDuckGo failed for $domain: $e');
        }
      }
      return null;
    }),
    // /favicon.ico at root (verified here)
    Future(() async {
      try {
        final faviconIco = '$baseUrl/favicon.ico';
        if (await _verifyIconUrl(faviconIco)) {
          if (kDebugMode) {
            print('[Icon] Found /favicon.ico for $url');
          }
          return _IconCandidate(faviconIco, 32, verified: true);
        }
      } catch (e) {
        if (kDebugMode) {
          print('[Icon] /favicon.ico failed for $url: $e');
        }
      }
      return null;
    }),
  ]);

  // Collect all candidates from parallel results
  List<_IconCandidate> candidates = [];
  for (var result in results) {
    if (result is _IconCandidate) {
      candidates.add(result);
    } else if (result is List<_IconCandidate>) {
      candidates.addAll(result);
    }
  }

  // Pick the best quality icon from all sources
  if (candidates.isEmpty) {
    if (kDebugMode) {
      print('[Icon] No icon found for $url');
    }
    _faviconCache[url] = null;
    return null;
  }

  // Sort by quality (highest first)
  candidates.sort((a, b) => b.quality.compareTo(a.quality));

  if (kDebugMode) {
    print('[Icon] Found ${candidates.length} candidate(s) for $url');
  }

  // Return the best candidate, verifying only if needed
  for (var candidate in candidates) {
    // Skip verification if already verified
    if (candidate.verified) {
      if (kDebugMode) {
        print('[Icon] Using pre-verified icon with quality ${candidate.quality} for $url: ${candidate.url}');
      }
      _faviconCache[url] = candidate.url;
      return candidate.url;
    }

    // Verify unverified candidates (e.g., from HTML)
    if (await _verifyIconUrl(candidate.url)) {
      if (kDebugMode) {
        print('[Icon] Using verified icon with quality ${candidate.quality} for $url: ${candidate.url}');
      }
      _faviconCache[url] = candidate.url;
      return candidate.url;
    }
  }

  if (kDebugMode) {
    print('[Icon] All candidates failed verification for $url');
  }
  _faviconCache[url] = null;
  return null;
}

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
  final UnifiedCookieManager _cookieManager = UnifiedCookieManager();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _isFindVisible = false;
  bool _showUrlBar = false;

  // Webspace-related state
  final List<Webspace> _webspaces = [];
  String? _selectedWebspaceId;

  @override
  void initState() {
    super.initState();
    _restoreAppState();
  }

  Future<void> _saveWebViewModels() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> webViewModelsJson = _webViewModels.map((webViewModel) => jsonEncode(webViewModel.toJson())).toList();
    prefs.setStringList('webViewModels', webViewModelsJson);
  }

  Future<void> _saveCurrentIndex() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('currentIndex', _currentIndex == null ? 10000 : _currentIndex!);
  }

  Future<void> _saveThemeMode() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('themeMode', _themeMode.index);
  }

  Future<void> _saveShowUrlBar() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showUrlBar', _showUrlBar);
  }

  Future<void> _saveWebspaces() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> webspacesJson = _webspaces.map((webspace) => jsonEncode(webspace.toJson())).toList();
    prefs.setStringList('webspaces', webspacesJson);
  }

  Future<void> _saveSelectedWebspaceId() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (_selectedWebspaceId != null) {
      await prefs.setString('selectedWebspaceId', _selectedWebspaceId!);
    } else {
      await prefs.remove('selectedWebspaceId');
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

      setState(() {
        _webViewModels.addAll(loadedWebViewModels);
      });
      for (WebViewModel webViewModel in loadedWebViewModels) {
        for(final cookie in webViewModel.cookies) {
          // Skip cookies with empty values to prevent assertion failures
          if (cookie.value.isEmpty) {
            continue;
          }
          await _cookieManager.setCookie(
            url: Uri.parse(webViewModel.initUrl),
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path ?? "/",
            expiresDate: cookie.expiresDate,
            isSecure: cookie.isSecure,
            isHttpOnly: cookie.isHttpOnly,
          );
        }
      }
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

    // Validate and set current index
    setState(() {
      int? savedIndex = prefs.getInt('currentIndex');
      if (savedIndex != null && savedIndex < _webViewModels.length && savedIndex != 10000) {
        // Check if the index is valid for the selected webspace
        if (_selectedWebspaceId != null) {
          final filteredIndices = _getFilteredSiteIndices();
          if (filteredIndices.contains(savedIndex)) {
            _currentIndex = savedIndex;
          } else {
            _currentIndex = null;
          }
        } else {
          _currentIndex = null;
        }
      } else {
        _currentIndex = null;
      }
    });

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
      setState(() {
        _webspaces.removeWhere((ws) => ws.id == webspace.id);
        if (_selectedWebspaceId == webspace.id) {
          _selectedWebspaceId = kAllWebspaceId; // Select "All" instead of null
          _currentIndex = null;
        }
      });
      await _saveWebspaces();
      await _saveSelectedWebspaceId();
      await _saveCurrentIndex();
    }
  }

  void _selectWebspace(Webspace webspace) {
    setState(() {
      _selectedWebspaceId = webspace.id;
      _currentIndex = null;
    });
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

  UnifiedWebViewController? getController() {
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
                    builder: (context) => SettingsScreen(webViewModel: _webViewModels[_currentIndex!]),
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

      // Try to fetch page title if custom name not provided
      String? pageTitle;
      if (customName.isEmpty) {
        pageTitle = await getPageTitle(url);
      }

      setState(() {
        final model = WebViewModel(initUrl: url, stateSetterF: () {setState((){});});
        if (customName.isNotEmpty) {
          model.name = customName;
          model.pageTitle = customName;
        } else if (pageTitle != null && pageTitle.isNotEmpty) {
          model.name = pageTitle;
          model.pageTitle = pageTitle;
        }
        _webViewModels.add(model);
        final newSiteIndex = _webViewModels.length - 1;
        _currentIndex = newSiteIndex;
        _saveCurrentIndex();

        // If a non-"All" webspace is currently selected, add the new site to it
        if (_selectedWebspaceId != null && _selectedWebspaceId != kAllWebspaceId) {
          final webspaceIndex = _webspaces.indexWhere((ws) => ws.id == _selectedWebspaceId);
          if (webspaceIndex != -1) {
            _webspaces[webspaceIndex].siteIndices.add(newSiteIndex);
            _saveWebspaces();
          }
        }
      });
      _saveWebViewModels();

      // Apply current theme to new webview
      final webViewTheme = _themeModeToWebViewTheme(_themeMode);
      await _webViewModels[_webViewModels.length - 1].setTheme(webViewTheme);
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
      onTap: () {
        setState(() {
          _currentIndex = index;
          _saveCurrentIndex();
        });
        Navigator.pop(context);
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
                setState(() {
                  _webViewModels.removeAt(index);
                  if (_currentIndex == index) {
                    _currentIndex = null;
                    _saveCurrentIndex();
                  }
                  // Update webspace indices after deletion
                  for (var webspace in _webspaces) {
                    webspace.siteIndices = webspace.siteIndices
                        .where((i) => i != index)
                        .map((i) => i > index ? i - 1 : i)
                        .toList();
                  }
                });
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
                      onTap: () {
                        setState(() {
                          _currentIndex = null;
                        });
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
                      onPressed: () {
                        setState(() {
                          _currentIndex = null;
                        });
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
              children: _webViewModels.map<Widget>((webViewModel) => Column(
                children: [
                  if(_isFindVisible && getController() != null)
                    FindToolbar(
                      webViewController: getController(),
                      matches: webViewModel.findMatches,
                      onClose: () {
                        _toggleFind();
                      },
                    ),
                  if(_showUrlBar)
                    UrlBar(
                      currentUrl: webViewModel.currentUrl,
                      onUrlSubmitted: (url) async {
                        final controller = webViewModel.getController(launchUrl, _cookieManager, _saveWebViewModels);
                        if (controller != null) {
                          await controller.loadUrl(url);
                          setState(() {
                            webViewModel.currentUrl = url;
                          });
                          await _saveWebViewModels();
                        }
                      },
                    ),
                  Expanded(
                    child: webViewModel.getWebView(launchUrl, _cookieManager, _saveWebViewModels)
                  ),
                ]
              )).toList(),
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
