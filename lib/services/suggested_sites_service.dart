import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/settings/site_suggestion.dart';

const String _prefsKey = 'suggested_sites';

/// The suggested sites the user saved, or none: every build ships an empty
/// list, so no flavor changes the compiled Dart (SUGGEST-001).
Future<List<SiteSuggestion>> loadSuggestedSites() async {
  final prefs = await SharedPreferences.getInstance();
  final json = prefs.getString(_prefsKey);
  if (json == null) return const [];
  final Object? list;
  try {
    list = jsonDecode(json);
  } on FormatException {
    return const [];
  }
  if (list is! List) return const [];
  return [
    for (final e in list)
      if (e case {
        'name': final String name,
        'url': final String url,
        'domain': final String domain,
      })
        SiteSuggestion(name: name, url: url, domain: domain),
  ];
}

Future<void> saveSuggestedSites(List<SiteSuggestion> sites) async {
  final prefs = await SharedPreferences.getInstance();
  final json = jsonEncode(sites
      .map((s) => {'name': s.name, 'url': s.url, 'domain': s.domain})
      .toList());
  await prefs.setString(_prefsKey, json);
}
