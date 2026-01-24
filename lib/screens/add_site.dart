import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../main.dart' show getFaviconUrl, extractDomain;

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

// Unified favicon widget that uses getFaviconUrl which tries all sources:
// 1. Google Favicons at 256px and 128px
// 2. HTML parsing for native icons (prioritizing SVG)
// 3. DuckDuckGo favicon service
// 4. /favicon.ico fallback
// Then picks the best quality icon found
class UnifiedFaviconImage extends StatelessWidget {
  final String url;
  final double size;
  final String? domain;

  const UnifiedFaviconImage({
    required this.url,
    required this.size,
    this.domain,
  });

  bool _isSvgUrl(String url) {
    return url.toLowerCase().endsWith('.svg') || url.contains('.svg?');
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: getFaviconUrl(url),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        }

        if (snapshot.hasData && snapshot.data != null) {
          final iconUrl = snapshot.data!;

          // Use SvgPicture for SVG files, CachedNetworkImage for others
          if (_isSvgUrl(iconUrl)) {
            return SvgPicture.network(
              iconUrl,
              width: size,
              height: size,
              fit: BoxFit.contain,
              placeholderBuilder: (context) => SizedBox(
                width: size,
                height: size,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          } else {
            return CachedNetworkImage(
              imageUrl: iconUrl,
              width: size,
              height: size,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              placeholder: (context, url) => SizedBox(
                width: size,
                height: size,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              errorWidget: (context, url, error) => Icon(
                Icons.language,
                size: size,
                color: Theme.of(context).colorScheme.primary,
              ),
            );
          }
        }

        // No favicon found
        return Icon(
          Icons.language,
          size: size,
          color: Theme.of(context).colorScheme.primary,
        );
      },
    );
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
  final TextEditingController _nameController = TextEditingController();

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
    SiteSuggestion(name: 'Mattermost', url: 'https://mattermost.com', domain: 'mattermost.com'),
    SiteSuggestion(name: 'Gmail', url: 'https://gmail.com', domain: 'gmail.com'),
    SiteSuggestion(name: 'Reddit', url: 'https://reddit.com', domain: 'reddit.com'),
    SiteSuggestion(name: 'Mastodon', url: 'https://mastodon.social', domain: 'mastodon.social'),
    SiteSuggestion(name: 'Bluesky', url: 'https://bsky.app', domain: 'bsky.app'),
  ];

  void _showSuggestionDialog(SiteSuggestion suggestion) {
    final TextEditingController nameController = TextEditingController(text: suggestion.name);
    final TextEditingController urlController = TextEditingController(text: suggestion.url);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Add Site'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Site Name',
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 16),
              TextField(
                controller: urlController,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: 'Site URL',
                  border: OutlineInputBorder(),
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
                String name = nameController.text.trim();
                // If no protocol specified, default to https
                if (!url.startsWith('http://') && !url.startsWith('https://')) {
                  url = 'https://$url';
                }
                Navigator.of(context).pop();
                Navigator.of(context).pop({'url': url, 'name': name});
              },
              child: Text('Add'),
            ),
          ],
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
                        controller: _nameController,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: 'Site Name (optional)',
                          helperText: 'Leave empty to fetch from website',
                        ),
                      ),
                      SizedBox(height: 16),
                      TextField(
                        controller: _urlController,
                        autofocus: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardType: TextInputType.url,
                        decoration: InputDecoration(labelText: 'Enter website URL'),
                      ),
                      SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () {
                          String url = _urlController.text.trim();
                          String name = _nameController.text.trim();
                          // If no protocol specified, default to https
                          if (!url.startsWith('http://') && !url.startsWith('https://')) {
                            url = 'https://$url';
                          }
                          Navigator.pop(context, {'url': url, 'name': name});
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
              ],
            );
          },
        ),
      ),
    );
  }
}
