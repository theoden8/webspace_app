import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';

import 'web_view_model.dart';
import 'add_site.dart';
import 'settings_page.dart';

String extractDomain(String url) {
  Uri uri = Uri.tryParse(url) ?? Uri();
  String? domain = uri.host;
  return domain.isEmpty ? url : domain;
}

Future<String?> getFaviconUrl(String url) async {
  Uri? uri = Uri.tryParse(url);
  if (uri == null) return null;

  try {
    final response = await http.get(Uri.parse('$uri/favicon.ico'));
    if (response.statusCode == 200) {
      return '$uri/favicon.ico';
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
      home: MyHomePage(onThemeModeChanged: _setThemeMode),
    );
  }
}

class MyHomePage extends StatefulWidget {
  final Function(ThemeMode) onThemeModeChanged;

  MyHomePage({required this.onThemeModeChanged});

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int? _currentIndex;
  final List<WebViewModel> _webViewModels = [];
  ThemeMode _themeMode = ThemeMode.system;

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
          .map((webViewModelJson) => WebViewModel.fromJson(jsonDecode(webViewModelJson)))
          .toList();

      setState(() {
        _webViewModels.addAll(loadedWebViewModels);
      });
    }
  }

  Future<void> _restoreAppState() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      _currentIndex = prefs.getInt('currentIndex') ?? 0;
      _themeMode = ThemeMode.values[prefs.getInt('themeMode') ?? 0];
    });
    await _loadWebViewModels();
  }

  Future<void> launchUrl(String url) async {
    if (await canLaunch(url)) {
      await launch(url);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not launch $url')),
      );
    }
  }

  AppBar _buildAppBar() {
    return AppBar(
      title: _currentIndex != null && _currentIndex! < _webViewModels.length
          ? Text(extractDomain(_webViewModels[_currentIndex!].url))
          : Text('No Site Selected'),
      actions: [
        if (_currentIndex != null && _currentIndex! < _webViewModels.length)
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: () {
              _webViewModels[_currentIndex!].getController().reload();
            },
          ),
        IconButton(
          icon: Icon(Theme.of(context).brightness == Brightness.light ? Icons.wb_sunny : Icons.nights_stay),
          onPressed: () {
            setState(() {
              if (Theme.of(context).brightness == Brightness.light) {
                _themeMode = ThemeMode.dark;
              } else {
                _themeMode = ThemeMode.light;
              }
            });
            widget.onThemeModeChanged(_themeMode);
            _saveThemeMode();
          },
        ),
        if (_currentIndex != null && _currentIndex! < _webViewModels.length)
          IconButton(
            icon: Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SettingsPage(webViewModel: _webViewModels[_currentIndex!]),
                ),
              );
              _saveWebViewModels();
            },
          ),
      ],
    );
  }

  Widget _buildWebView(WebViewModel webViewModel) {
    return WebViewWidget(
      controller: webViewModel.getController()
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (NavigationRequest request) async {
              String requestDomain = extractDomain(request.url);
              String initialDomain = extractDomain(webViewModel.url);

              // Extract top-level and second-level domains
              List<String> requestDomainParts = requestDomain.split('.');
              List<String> initialDomainParts = initialDomain.split('.');

              // Compare top-level and second-level domains
              bool sameTopLevelDomain = requestDomainParts.last == initialDomainParts.last;
              bool sameSecondLevelDomain = requestDomainParts[requestDomainParts.length - 2] ==
                  initialDomainParts[initialDomainParts.length - 2];

              if (sameTopLevelDomain && sameSecondLevelDomain) {
                return NavigationDecision.navigate;
              } else {
                await launchUrl(request.url);
                return NavigationDecision.prevent;
              }
            },
          ),
        ),
    );
  }

  void _addSite() async {
    final url = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => AddSite()),
    );
    if (url != null) {
      setState(() {
        _webViewModels.add(WebViewModel(url: url));
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
                      future: getFaviconUrl(_webViewModels[index].url),
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
                    title: Text(extractDomain(_webViewModels[index].url)),
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
              children: _webViewModels.map<Widget>((webViewModel) => _buildWebView(webViewModel)).toList(),
            ),
      floatingActionButton: !(_currentIndex == null || _currentIndex! >= _webViewModels.length) ? null : FloatingActionButton(
        onPressed: () async {
          _addSite();
        },
        child: Icon(Icons.add),
      ),
    );
  }
}
