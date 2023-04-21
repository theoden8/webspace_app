import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';

import 'package:webspace/web_view_model.dart';
import 'package:webspace/screens/add_site.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/screens/inappbrowser.dart';
import 'package:webspace/widgets/find_toolbar.dart';

String extractDomain(String url) {
  Uri uri = Uri.tryParse(url) ?? Uri();
  String? domain = uri.host;
  return domain.isEmpty ? url : domain;
}

Future<String?> getFaviconUrl(String url) async {
  Uri? uri = Uri.tryParse(url);
  if (uri == null) return null;

  String? scheme = uri.scheme;
  String? host = uri.host;

  if (scheme == null || host == null) return null;

  String faviconUrl = '$scheme://$host/favicon.ico';

  try {
    final response = await http.get(Uri.parse(faviconUrl));
    if (response.statusCode == 200) {
      return faviconUrl;
    }
  } catch (e) {
    print('Error fetching favicon: $e');
  }
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
  CookieManager _cookieManager = CookieManager.instance();

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

  Future<void> _saveAppState() async {
    await _saveCurrentIndex();
    await _saveThemeMode();
    await _saveWebViewModels();
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
            sameSite: cookie.sameSite,
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

  InAppWebViewController? getController() {
    if(_currentIndex == null) {
      return null;
    }
    return _webViewModels[_currentIndex!].getController(launchUrl, _cookieManager, _saveWebViewModels);
  }

  AppBar _buildAppBar() {
    return AppBar(
      title: _currentIndex != null && _currentIndex! < _webViewModels.length
          ? Text(extractDomain(_webViewModels[_currentIndex!].initUrl))
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
      setState(() {
        _webViewModels.add(WebViewModel(initUrl: url, stateSetterF: () {setState((){});}));
        _currentIndex = _webViewModels.length - 1;
        _saveCurrentIndex();
      });
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
                    title: Text(extractDomain(_webViewModels[index].initUrl)),
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
                          icon: Icon(Icons.delete),
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
