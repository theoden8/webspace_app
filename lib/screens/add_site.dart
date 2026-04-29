import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart' show extractDomain;
import '../services/icon_service.dart' show getFaviconUrlStream, getSvgContent, onSvgContentCached, invalidateFaviconFor, IconUpdate;
import '../settings/proxy.dart';
import '../utils/url_utils.dart';

/// Persistent cache for favicon URLs and SVG content
class FaviconUrlCache {
  static const String _prefix = 'favicon_url_';
  static const String _svgPrefix = 'favicon_svg_';
  static SharedPreferences? _prefs;

  static Future<void> initialize() async {
    _prefs ??= await SharedPreferences.getInstance();
    // Wire up SVG content persistence
    onSvgContentCached = (url, content) async {
      await setSvg(url, content);
    };
  }

  static String? get(String siteUrl) {
    return _prefs?.getString('$_prefix$siteUrl');
  }

  static Future<void> set(String siteUrl, String faviconUrl) async {
    await _prefs?.setString('$_prefix$siteUrl', faviconUrl);
  }

  static String? getSvg(String faviconUrl) {
    return _prefs?.getString('$_svgPrefix$faviconUrl');
  }

  static Future<void> setSvg(String faviconUrl, String svgContent) async {
    await _prefs?.setString('$_svgPrefix$faviconUrl', svgContent);
  }

  /// Invalidate cached favicon for a site, triggering re-fetch
  static Future<void> invalidate(String siteUrl) async {
    final oldUrl = _prefs?.getString('$_prefix$siteUrl');
    await _prefs?.remove('$_prefix$siteUrl');
    if (oldUrl != null) {
      await _prefs?.remove('$_svgPrefix$oldUrl');
    }
    // Also clear in-memory caches
    invalidateFaviconFor(siteUrl);
  }
}

class SiteSuggestion {
  final String name;
  final String url;
  final String domain;

  const SiteSuggestion({
    required this.name,
    required this.url,
    required this.domain,
  });
}

// Unified favicon widget with progressive loading
// Icons update as better quality versions are found:
// 1. DuckDuckGo (fast, ~64px) - shows first
// 2. Google Favicons (128px, 256px) - upgrades the icon
// 3. Site-specific high-res icons via HTML parsing - final upgrade
class UnifiedFaviconImage extends StatefulWidget {
  final String url;
  final double size;
  final String? domain;
  /// Per-site proxy of the site this favicon belongs to. When null (e.g. for
  /// search-suggestion thumbnails with no specific site context), the
  /// app-global outbound proxy applies. When set, [resolveEffectiveProxy]
  /// chooses per-site if explicit, or global if the per-site type is DEFAULT.
  final UserProxySettings? proxy;

  const UnifiedFaviconImage({
    required this.url,
    required this.size,
    this.domain,
    this.proxy,
  });

  @override
  State<UnifiedFaviconImage> createState() => _UnifiedFaviconImageState();
}

class _UnifiedFaviconImageState extends State<UnifiedFaviconImage> {
  String? _currentIconUrl;
  String? _svgContent; // Cached SVG content for offline display
  int _currentQuality = 0;
  bool _isLoading = true;
  Stream<IconUpdate>? _iconStream;

  bool _isSvgUrl(String url) {
    return url.toLowerCase().endsWith('.svg') || url.contains('.svg?');
  }

  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  @override
  void didUpdateWidget(UnifiedFaviconImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _resetAndLoad();
    } else if (_currentIconUrl != null && FaviconUrlCache.get(widget.url) == null) {
      // Cache was invalidated (e.g. by refresh) — re-fetch
      _resetAndLoad();
    }
  }

  void _resetAndLoad() {
    _currentIconUrl = null;
    _svgContent = null;
    _currentQuality = 0;
    _isLoading = true;
    _loadIcon();
  }

  void _loadIcon() {
    // Check persistent cache first
    final cachedUrl = FaviconUrlCache.get(widget.url);
    if (cachedUrl != null) {
      // Use cached URL immediately, skip icon_service
      _currentIconUrl = cachedUrl;
      _currentQuality = 100;
      _isLoading = false;
      if (_isSvgUrl(cachedUrl)) {
        _fetchSvgContent(cachedUrl);
      } else {
        setState(() {});
      }
      return;
    }

    // No cache - fetch via icon_service
    _startIconStream();
  }

  Future<void> _fetchSvgContent(String url) async {
    final persisted = FaviconUrlCache.getSvg(url);
    final content = await getSvgContent(
      url,
      persistedContent: persisted,
      proxy: widget.proxy,
    );
    if (mounted) {
      setState(() {
        _svgContent = content;
      });
    }
  }

  void _startIconStream() {
    _iconStream = getFaviconUrlStream(widget.url, proxy: widget.proxy);
    _iconStream!.listen(
      (update) {
        if (mounted && update.quality > _currentQuality) {
          setState(() {
            _currentIconUrl = update.url;
            _currentQuality = update.quality;
            if (update.isFinal) {
              _isLoading = false;
              // Cache the final result
              FaviconUrlCache.set(widget.url, update.url);
            }
          });
          if (_isSvgUrl(update.url)) {
            _fetchSvgContent(update.url);
          }
        }
      },
      onDone: () {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          // Cache whatever we have
          if (_currentIconUrl != null) {
            FaviconUrlCache.set(widget.url, _currentIconUrl!);
          }
        }
      },
      onError: (e) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Show current best icon, or loading indicator if nothing yet
    if (_currentIconUrl == null) {
      if (_isLoading) {
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      } else {
        // No favicon found
        return Icon(
          Icons.language,
          size: widget.size,
          color: Theme.of(context).colorScheme.primary,
        );
      }
    }

    final iconUrl = _currentIconUrl!;

    // Use SvgPicture for SVG files, CachedNetworkImage for others
    if (_isSvgUrl(iconUrl)) {
      if (_svgContent == null) {
        // SVG not cached yet — show placeholder, never use SvgPicture.network
        return Icon(
          Icons.language,
          size: widget.size,
          color: Theme.of(context).colorScheme.primary,
        );
      }
      // Wrap in MediaQuery to pass app theme to SVG's CSS media queries
      // (e.g., @media (prefers-color-scheme: dark) in codeberg's favicon)
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(
          platformBrightness: Theme.of(context).brightness,
        ),
        child: SvgPicture.string(
          _svgContent!,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.contain,
        ),
      );
    } else {
      return CachedNetworkImage(
        imageUrl: iconUrl,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        placeholder: (context, url) => SizedBox(
          width: widget.size,
          height: widget.size,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        errorWidget: (context, url, error) => Icon(
          Icons.language,
          size: widget.size,
          color: Theme.of(context).colorScheme.primary,
        ),
      );
    }
  }
}

// Keep old FaviconImage for backward compatibility (just wraps UnifiedFaviconImage)
class FaviconImage extends StatelessWidget {
  final String domain;
  final double size;

  const FaviconImage({
    required this.domain,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return UnifiedFaviconImage(
      url: 'https://$domain',
      size: size,
      domain: domain,
    );
  }
}

class AddSiteScreen extends StatefulWidget {
  final ThemeMode themeMode;
  final Function(ThemeMode) onThemeModeChanged;
  final List<SiteSuggestion> suggestions;
  final Function(List<SiteSuggestion>) onSuggestionsChanged;

  AddSiteScreen({
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.suggestions,
    required this.onSuggestionsChanged,
  });

  @override
  _AddSiteScreenState createState() => _AddSiteScreenState();
}

class _AddSiteScreenState extends State<AddSiteScreen> {
  final TextEditingController _urlController = TextEditingController();
  bool _incognito = false;
  Timer? _debounceTimer;
  String? _previewUrl;
  late List<SiteSuggestion> _suggestions;

  @override
  void initState() {
    super.initState();
    _suggestions = List.of(widget.suggestions);
    _urlController.addListener(_onUrlChanged);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _urlController.removeListener(_onUrlChanged);
    _urlController.dispose();
    super.dispose();
  }

  void _onUrlChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 600), () {
      _updatePreview();
    });
  }

  /// Check if a host is an IP address or localhost (no DNS needed)
  bool _isDirectHost(String host) {
    return host == 'localhost' ||
        host.contains(':') || // IPv6
        RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(host); // IPv4
  }

  Future<void> _updatePreview() async {
    final text = _urlController.text.trim();
    if (text.isEmpty) {
      if (_previewUrl != null) {
        setState(() => _previewUrl = null);
      }
      return;
    }

    String url = ensureUrlScheme(text);

    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty ||
        !(uri.host.contains('.') || uri.host.contains(':') || uri.host == 'localhost')) {
      if (_previewUrl != null) {
        setState(() => _previewUrl = null);
      }
      return;
    }

    // Skip DNS check for IP addresses and localhost
    if (!_isDirectHost(uri.host)) {
      try {
        await InternetAddress.lookup(uri.host);
      } catch (_) {
        // DNS lookup failed — domain doesn't exist
        if (mounted && _previewUrl != null) {
          setState(() => _previewUrl = null);
        }
        return;
      }
    }

    if (!mounted) return;
    final newPreview = '${uri.scheme}://${uri.host}';
    if (_previewUrl != newPreview) {
      setState(() => _previewUrl = newPreview);
    }
  }

  Future<void> _importHtmlFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['html', 'htm'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      String htmlContent;

      if (file.bytes != null) {
        htmlContent = String.fromCharCodes(file.bytes!);
      } else if (file.path != null) {
        htmlContent = await File(file.path!).readAsString();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not read the selected file')),
          );
        }
        return;
      }

      if (!mounted) return;

      // Use filename (without extension) as the site name
      final fileName = file.name;
      final nameWithoutExt = fileName.replaceAll(RegExp(r'\.(html?|htm)$', caseSensitive: false), '');

      Navigator.pop(context, {
        'url': 'file://$fileName',
        'name': nameWithoutExt,
        'incognito': _incognito,
        'htmlContent': htmlContent,
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    }
  }

  void _removeSuggestion(int index) {
    setState(() {
      _suggestions.removeAt(index);
    });
    widget.onSuggestionsChanged(_suggestions);
  }

  void _showAddSuggestionDialog() {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Add Suggested Site'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 8),
              TextField(
                controller: urlController,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: 'URL',
                  border: OutlineInputBorder(),
                  hintText: 'https://example.com',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final name = nameController.text.trim();
                var url = urlController.text.trim();
                if (name.isEmpty || url.isEmpty) return;
                url = ensureUrlScheme(url);
                final uri = Uri.tryParse(url);
                if (uri == null || uri.host.isEmpty) return;
                final suggestion = SiteSuggestion(
                  name: name,
                  url: url,
                  domain: uri.host,
                );
                Navigator.of(context).pop();
                setState(() {
                  _suggestions.add(suggestion);
                });
                widget.onSuggestionsChanged(_suggestions);
              },
              child: Text('Add'),
            ),
          ],
        );
      },
    );
  }

  void _showSuggestionDialog(SiteSuggestion suggestion) {
    final TextEditingController urlController = TextEditingController(text: suggestion.url);
    bool incognito = false;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('Add ${suggestion.name}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: urlController,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: 'Site URL',
                      border: OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          incognito ? MdiIcons.incognito : MdiIcons.incognitoOff,
                          color: incognito ? Theme.of(context).colorScheme.primary : null,
                        ),
                        tooltip: incognito ? 'Incognito mode on' : 'Incognito mode off',
                        onPressed: () {
                          setDialogState(() {
                            incognito = !incognito;
                          });
                        },
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    String url = urlController.text.trim();
                    // If no protocol specified, default to https
                    url = ensureUrlScheme(url);
                    Navigator.of(context).pop();
                    Navigator.of(context).pop({'url': url, 'name': '', 'incognito': incognito});
                  },
                  child: Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  IconData _getThemeIcon() {
    switch (widget.themeMode) {
      case ThemeMode.light:
        return Icons.wb_sunny;
      case ThemeMode.dark:
        return Icons.nights_stay;
      case ThemeMode.system:
        return Icons.brightness_auto;
    }
  }

  String _getThemeTooltip() {
    switch (widget.themeMode) {
      case ThemeMode.light:
        return 'Light theme';
      case ThemeMode.dark:
        return 'Dark theme';
      case ThemeMode.system:
        return 'System theme';
    }
  }

  void _toggleTheme() {
    ThemeMode newMode;
    switch (widget.themeMode) {
      case ThemeMode.light:
        newMode = ThemeMode.dark;
        break;
      case ThemeMode.dark:
        newMode = ThemeMode.system;
        break;
      case ThemeMode.system:
        newMode = ThemeMode.light;
        break;
    }
    widget.onThemeModeChanged(newMode);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Add new site'),
        actions: [
          IconButton(
            icon: Icon(_getThemeIcon()),
            tooltip: _getThemeTooltip(),
            onPressed: _toggleTheme,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tileSize = (constraints.maxWidth - 36) / 4; // 4 columns with 12px spacing
            final iconSize = tileSize * 0.7; // Icon takes 70% of tile size

            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _urlController,
                        autofocus: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardType: TextInputType.url,
                        decoration: InputDecoration(
                          labelText: 'Enter website URL',
                          prefixIcon: _previewUrl != null
                              ? Padding(
                                  padding: const EdgeInsets.all(12.0),
                                  child: SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: UnifiedFaviconImage(
                                      url: _previewUrl!,
                                      size: 24,
                                    ),
                                  ),
                                )
                              : null,
                          suffixIcon: IconButton(
                            icon: Icon(
                              _incognito ? MdiIcons.incognito : MdiIcons.incognitoOff,
                              color: _incognito ? Theme.of(context).colorScheme.primary : null,
                            ),
                            tooltip: _incognito ? 'Incognito mode on' : 'Incognito mode off',
                            onPressed: () {
                              setState(() {
                                _incognito = !_incognito;
                              });
                            },
                          ),
                        ),
                      ),
                      SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () {
                                String url = _urlController.text.trim();
                                // If no protocol specified, default to https
                                url = ensureUrlScheme(url);
                                Navigator.pop(context, {'url': url, 'name': '', 'incognito': _incognito});
                              },
                              child: Text('Add Site'),
                            ),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _importHtmlFile,
                              icon: Icon(Icons.file_open),
                              label: Text('Import file'),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Tip: Type http:// for HTTP sites, or just the domain for HTTPS',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Suggested Sites',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.add, size: 20),
                            tooltip: 'Add suggested site',
                            onPressed: _showAddSuggestionDialog,
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      SizedBox(height: 12),
                    ],
                  ),
                ),
                if (_suggestions.isNotEmpty)
                  SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 1,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final suggestion = _suggestions[index];
                        return InkWell(
                          onTap: () => _showSuggestionDialog(suggestion),
                          onLongPress: () {
                            showDialog(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: Text('Remove ${suggestion.name}?'),
                                content: Text('Remove this site from suggestions?'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(context).pop(),
                                    child: Text('Cancel'),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      Navigator.of(context).pop();
                                      _removeSuggestion(index);
                                    },
                                    child: Text('Remove'),
                                  ),
                                ],
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(4.0),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Center(
                                      child: FaviconImage(
                                        domain: suggestion.domain,
                                        size: iconSize,
                                      ),
                                    ),
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    suggestion.name,
                                    style: TextStyle(fontSize: 10),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                      childCount: _suggestions.length,
                    ),
                  ),
                if (_suggestions.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24.0),
                      child: Center(
                        child: Text(
                          'No suggested sites. Tap + to add some.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).padding.bottom,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
