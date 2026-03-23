import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart' show extractDomain;
import '../services/icon_service.dart' show getFaviconUrlStream, getSvgContent, onSvgContentCached, invalidateFaviconFor, IconUpdate;

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

  const UnifiedFaviconImage({
    required this.url,
    required this.size,
    this.domain,
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
    final content = await getSvgContent(url, persistedContent: persisted);
    if (mounted) {
      setState(() {
        _svgContent = content;
      });
    }
  }

  void _startIconStream() {
    _iconStream = getFaviconUrlStream(widget.url);
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

  AddSiteScreen({
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  @override
  _AddSiteScreenState createState() => _AddSiteScreenState();
}

class _AddSiteScreenState extends State<AddSiteScreen> {
  final TextEditingController _urlController = TextEditingController();
  bool _incognito = false;

  static const List<SiteSuggestion> _suggestions = [
    SiteSuggestion(name: 'DuckDuckGo', url: 'https://duckduckgo.com', domain: 'duckduckgo.com'),
    SiteSuggestion(name: 'Claude', url: 'https://claude.ai', domain: 'claude.ai'),
    SiteSuggestion(name: 'ChatGPT', url: 'https://chatgpt.com', domain: 'chatgpt.com'),
    SiteSuggestion(name: 'Perplexity', url: 'https://perplexity.ai', domain: 'perplexity.ai'),
    SiteSuggestion(name: 'Instagram', url: 'https://instagram.com', domain: 'instagram.com'),
    SiteSuggestion(name: 'Facebook', url: 'https://facebook.com', domain: 'facebook.com'),
    SiteSuggestion(name: 'X (Twitter)', url: 'https://x.com', domain: 'x.com'),
    SiteSuggestion(name: 'Google Chat', url: 'https://chat.google.com', domain: 'chat.google.com'),
    SiteSuggestion(name: 'GitHub', url: 'https://github.com', domain: 'github.com'),
    SiteSuggestion(name: 'GitLab', url: 'https://gitlab.com', domain: 'gitlab.com'),
    SiteSuggestion(name: 'Gitea', url: 'https://gitea.com', domain: 'gitea.com'),
    SiteSuggestion(name: 'Codeberg', url: 'https://codeberg.org', domain: 'codeberg.org'),
    SiteSuggestion(name: 'Slack', url: 'https://slack.com', domain: 'slack.com'),
    SiteSuggestion(name: 'Discord', url: 'https://discord.com/login', domain: 'discord.com'),
    SiteSuggestion(name: 'Mattermost', url: 'https://mattermost.com', domain: 'mattermost.com'),
    SiteSuggestion(name: 'Gmail', url: 'https://gmail.com', domain: 'gmail.com'),
    SiteSuggestion(name: 'LinkedIn', url: 'https://linkedin.com', domain: 'linkedin.com'),
    SiteSuggestion(name: 'Reddit', url: 'https://reddit.com', domain: 'reddit.com'),
    SiteSuggestion(name: 'Mastodon', url: 'https://mastodon.social', domain: 'mastodon.social'),
    SiteSuggestion(name: 'Bluesky', url: 'https://bsky.app', domain: 'bsky.app'),
    SiteSuggestion(name: 'Hugging Face', url: 'https://huggingface.co', domain: 'huggingface.co'),
  ];

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
                          incognito ? Icons.visibility_off : Icons.visibility_off_outlined,
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
                    if (!url.startsWith('http://') && !url.startsWith('https://')) {
                      url = 'https://$url';
                    }
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
                          suffixIcon: IconButton(
                            icon: Icon(
                              _incognito ? Icons.visibility_off : Icons.visibility_off_outlined,
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
                      ElevatedButton(
                        onPressed: () {
                          String url = _urlController.text.trim();
                          // If no protocol specified, default to https
                          if (!url.startsWith('http://') && !url.startsWith('https://')) {
                            url = 'https://$url';
                          }
                          Navigator.pop(context, {'url': url, 'name': '', 'incognito': _incognito});
                        },
                        child: Text('Add Site'),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Tip: Type http:// for HTTP sites, or just the domain for HTTPS',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 24),
                      Text(
                        'Suggested Sites',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 12),
                    ],
                  ),
                ),
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
