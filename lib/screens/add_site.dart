import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

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

class AddSiteScreen extends StatefulWidget {
  @override
  _AddSiteScreenState createState() => _AddSiteScreenState();
}

class _AddSiteScreenState extends State<AddSiteScreen> {
  final TextEditingController _controller = TextEditingController();

  static const List<SiteSuggestion> _suggestions = [
    SiteSuggestion(name: 'DuckDuckGo', url: 'https://duckduckgo.com', domain: 'duckduckgo.com'),
    SiteSuggestion(name: 'Claude', url: 'https://claude.ai', domain: 'claude.ai'),
    SiteSuggestion(name: 'ChatGPT', url: 'https://chatgpt.com', domain: 'chatgpt.com'),
    SiteSuggestion(name: 'Perplexity', url: 'https://perplexity.ai', domain: 'perplexity.ai'),
    SiteSuggestion(name: 'Instagram', url: 'https://instagram.com', domain: 'instagram.com'),
    SiteSuggestion(name: 'Facebook', url: 'https://facebook.com', domain: 'facebook.com'),
    SiteSuggestion(name: 'Piped', url: 'https://piped.video', domain: 'piped.video'),
    SiteSuggestion(name: 'X (Twitter)', url: 'https://x.com', domain: 'x.com'),
    SiteSuggestion(name: 'Google Chat', url: 'https://chat.google.com', domain: 'chat.google.com'),
    SiteSuggestion(name: 'GitLab', url: 'https://gitlab.com', domain: 'gitlab.com'),
    SiteSuggestion(name: 'Gitea', url: 'https://gitea.io', domain: 'gitea.io'),
    SiteSuggestion(name: 'Slack', url: 'https://slack.com', domain: 'slack.com'),
    SiteSuggestion(name: 'Gmail', url: 'https://gmail.com', domain: 'gmail.com'),
    SiteSuggestion(name: 'Reddit', url: 'https://reddit.com', domain: 'reddit.com'),
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
                // If no protocol specified, default to https
                if (!url.startsWith('http://') && !url.startsWith('https://')) {
                  url = 'https://$url';
                }
                Navigator.of(context).pop();
                Navigator.of(context).pop(url);
              },
              child: Text('Add'),
            ),
          ],
        );
      },
    );
  }

  String _getFaviconUrl(String domain) {
    return 'https://icons.duckduckgo.com/ip3/$domain.ico';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Add new site'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(labelText: 'Enter website URL'),
            ),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                String url = _controller.text.trim();
                // If no protocol specified, default to https
                if (!url.startsWith('http://') && !url.startsWith('https://')) {
                  url = 'https://$url';
                }
                Navigator.pop(context, url);
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
            Expanded(
              child: GridView.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 1,
                ),
                itemCount: _suggestions.length,
                itemBuilder: (context, index) {
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
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CachedNetworkImage(
                            imageUrl: _getFaviconUrl(suggestion.domain),
                            width: 40,
                            height: 40,
                            placeholder: (context, url) => SizedBox(
                              width: 40,
                              height: 40,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            errorWidget: (context, url, error) => Icon(
                              Icons.language,
                              size: 40,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            suggestion.name,
                            style: TextStyle(fontSize: 12),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
