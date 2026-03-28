import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/add_site.dart' show SiteSuggestion;

/// Default suggested sites for non-fdroid builds.
const List<SiteSuggestion> kDefaultSuggestions = [
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

const String _prefsKey = 'suggested_sites';

/// Whether the current build is the fdroid flavor.
bool get isFdroidFlavor {
  const flavor = String.fromEnvironment('FLUTTER_APP_FLAVOR');
  return flavor == 'fdroid';
}

/// Returns the flavor-appropriate default suggestions.
List<SiteSuggestion> get flavorDefaultSuggestions =>
    isFdroidFlavor ? const [] : kDefaultSuggestions;

/// Load user-customized suggested sites from SharedPreferences.
/// Returns null if user has not customized (use defaults).
Future<List<SiteSuggestion>?> loadSuggestedSites() async {
  final prefs = await SharedPreferences.getInstance();
  final json = prefs.getString(_prefsKey);
  if (json == null) return null;
  try {
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => SiteSuggestion(
              name: e['name'] as String,
              url: e['url'] as String,
              domain: e['domain'] as String,
            ))
        .toList();
  } catch (_) {
    return null;
  }
}

/// Save user-customized suggested sites to SharedPreferences.
Future<void> saveSuggestedSites(List<SiteSuggestion> sites) async {
  final prefs = await SharedPreferences.getInstance();
  final json = jsonEncode(sites
      .map((s) => {'name': s.name, 'url': s.url, 'domain': s.domain})
      .toList());
  await prefs.setString(_prefsKey, json);
}

/// Reset suggested sites to flavor defaults (removes customization).
Future<void> resetSuggestedSites() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_prefsKey);
}

/// Get the effective suggested sites list: user-customized or flavor default.
Future<List<SiteSuggestion>> getEffectiveSuggestedSites() async {
  final custom = await loadSuggestedSites();
  return custom ?? flavorDefaultSuggestions;
}
