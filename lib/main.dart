import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;

import 'package:webspace/web_view_model.dart';
import 'package:webspace/platform/unified_webview.dart';
import 'package:webspace/platform/webview_factory.dart';
import 'package:webspace/screens/add_site.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/screens/inappbrowser.dart';
import 'package:webspace/widgets/find_toolbar.dart';

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

Future<String?> getFaviconUrl(String url) async {
  // Check cache first
  if (_faviconCache.containsKey(url)) {
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

  if (scheme.isEmpty || host.isEmpty) {
    _faviconCache[url] = null;
    return null;
  }

  String baseUrl = port != null 
      ? '$scheme://$host:$port'
      : '$scheme://$host';

  try {
    // Strategy 1: Try to parse the HTML page and find <link rel="icon"> tags
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
      // Priority order: icon, shortcut icon, apple-touch-icon
      List<String> iconRels = ['icon', 'shortcut icon', 'apple-touch-icon'];
      
      for (String rel in iconRels) {
        var linkElements = document.querySelectorAll('link[rel*="$rel"]');
        for (var link in linkElements) {
          String? href = link.attributes['href'];
          if (href != null && href.isNotEmpty) {
            // Resolve relative URLs
            String faviconUrl;
            if (href.startsWith('http://') || href.startsWith('https://')) {
              faviconUrl = href;
            } else if (href.startsWith('//')) {
              faviconUrl = '$scheme:$href';
            } else if (href.startsWith('/')) {
              faviconUrl = '$baseUrl$href';
            } else {
              faviconUrl = '$baseUrl/$href';
            }
            
            // Verify the favicon URL is accessible
            try {
              final iconResponse = await http.head(Uri.parse(faviconUrl)).timeout(
                Duration(seconds: 2),
              );
              if (iconResponse.statusCode == 200) {
                _faviconCache[url] = faviconUrl;
                return faviconUrl;
              }
            } catch (e) {
              // Try next icon
              continue;
            }
          }
        }
      }
    }
  } catch (e) {
    // HTML parsing failed, try fallback
  }

  // Strategy 2: Fallback to /favicon.ico at root
  String faviconUrl = '$baseUrl/favicon.ico';
  try {
    final response = await http.get(Uri.parse(faviconUrl)).timeout(
      Duration(seconds: 2),
      onTimeout: () => throw TimeoutException('Favicon fetch timeout'),
    );
    if (response.statusCode == 200) {
      _faviconCache[url] = faviconUrl;
      return faviconUrl;
    }
  } catch (e) {
    // Silently cache the failure
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

void main() {
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

  bool _isFindVisible = false;

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
      _currentIndex = prefs.getInt('currentIndex') ?? 0;
      _themeMode = ThemeMode.values[prefs.getInt('themeMode') ?? 0];
      widget.onThemeModeChanged(_themeMode);
    });
    await _loadWebViewModels();

    // Apply saved theme to all restored webviews
    final webViewTheme = _themeModeToWebViewTheme(_themeMode);
    for (var webViewModel in _webViewModels) {
      await webViewModel.setTheme(webViewTheme);
    }
  }

  Future<void> launchUrl(String url) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => InAppWebViewScreen(url: url),
      ),
    );
  }

  void _toggleFind() {
    setState(() {
      _isFindVisible = !_isFindVisible;
    });
  }

  UnifiedWebViewController? getController() {
    if(_currentIndex == null) {
      return null;
    }
    return _webViewModels[_currentIndex!].getController(launchUrl, _cookieManager, _saveWebViewModels);
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
          : Text('No Site Selected'),
      actions: [
        IconButton(
          icon: Icon(Theme.of(context).brightness == Brightness.light ? Icons.wb_sunny : Icons.nights_stay),
          onPressed: () async {
            setState(() {
              if (Theme.of(context).brightness == Brightness.light) {
                _themeMode = ThemeMode.dark;
              } else {
                _themeMode = ThemeMode.light;
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
            }
          },
        ),
      ],
    );
  }

  void _addSite() async {
    final url = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => AddSiteScreen()),
    );
    if (url != null) {
      // Try to fetch page title for platforms without native title support
      final pageTitle = await getPageTitle(url);
      
      setState(() {
        final model = WebViewModel(initUrl: url, stateSetterF: () {setState((){});});
        if (pageTitle != null && pageTitle.isNotEmpty) {
          model.name = pageTitle;
          model.pageTitle = pageTitle;
        }
        _webViewModels.add(model);
        _currentIndex = _webViewModels.length - 1;
        _saveCurrentIndex();
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
              decoration: InputDecoration(
                labelText: 'Site Name',
                hintText: 'Enter a custom name',
              ),
            ),
            SizedBox(height: 16),
            TextField(
              controller: urlController,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      drawer: Drawer(
        child: Column(
          children: [
            Container(
              height: 100,
              width: double.infinity,
              child: Icon(
                Icons.menu_book,
                size: 72,
                color: Theme.of(context).primaryColor,
              ),
              alignment: Alignment.center,
            ),
            Expanded(
              child: ReorderableListView.builder(
                itemCount: _webViewModels.length,
                onReorder: (int oldIndex, int newIndex) {
                  setState(() {
                    if (newIndex > oldIndex) {
                      newIndex -= 1;
                    }
                    final WebViewModel item = _webViewModels.removeAt(oldIndex);
                    _webViewModels.insert(newIndex, item);
                  });
                  _saveWebViewModels();
                },
                itemBuilder: (BuildContext context, int index) {
                  return ListTile(
                    key: Key('site_$index'),
                    leading: FutureBuilder<String?>(
                      future: getFaviconUrl(_webViewModels[index].initUrl),
                      builder: (context, snapshot) {
                        if (snapshot.hasData) {
                          return CachedNetworkImage(
                            imageUrl: snapshot.data!,
                            errorWidget: (context, url, error) => Icon(Icons.link),
                            width: 20,
                            height: 20,
                            fit: BoxFit.cover,
                          );
                        } else {
                          return SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(),
                          );
                        }
                      },
                    ),
                    title: Text(
                      _webViewModels[index].getDisplayName(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                    subtitle: Text(extractDomain(_webViewModels[index].initUrl), 
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
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
                          onPressed: () {
                            setState(() {
                              _webViewModels.removeAt(index);
                              if (_currentIndex == index) {
                                _currentIndex = null;
                                _saveCurrentIndex();
                              }
                            });
                            _saveWebViewModels();
                            Navigator.pop(context);
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
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
          ? Center(child: Text('No WebView selected'))
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
