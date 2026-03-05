import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'abp_filter_parser.dart';

/// A filter list entry with metadata.
class FilterList {
  final String id;
  String name;
  String url;
  bool enabled;
  DateTime? lastUpdated;
  int ruleCount;
  int skippedCount;

  FilterList({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = false,
    this.lastUpdated,
    this.ruleCount = 0,
    this.skippedCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'enabled': enabled,
        'lastUpdated': lastUpdated?.toIso8601String(),
        'ruleCount': ruleCount,
        'skippedCount': skippedCount,
      };

  factory FilterList.fromJson(Map<String, dynamic> json) => FilterList(
        id: json['id'],
        name: json['name'],
        url: json['url'],
        enabled: json['enabled'] ?? false,
        lastUpdated: json['lastUpdated'] != null
            ? DateTime.tryParse(json['lastUpdated'])
            : null,
        ruleCount: json['ruleCount'] ?? 0,
        skippedCount: json['skippedCount'] ?? 0,
      );
}

/// Default filter lists added on first initialization.
const List<Map<String, String>> _defaultLists = [
  {
    'id': 'easylist',
    'name': 'EasyList',
    'url': 'https://easylist.to/easylist/easylist.txt',
  },
  {
    'id': 'easyprivacy',
    'name': 'EasyPrivacy',
    'url': 'https://easylist.to/easylist/easyprivacy.txt',
  },
  {
    'id': 'fanboy-social',
    'name': "Fanboy's Social",
    'url': 'https://easylist.to/easylist/fanboy-social.txt',
  },
  {
    'id': 'fanboy-annoyance',
    'name': "Fanboy's Annoyance",
    'url': 'https://easylist.to/easylist/fanboy-annoyance.txt',
  },
];

/// Singleton service for managing ABP filter lists.
///
/// Uses two mechanisms instead of InAppWebView's contentBlockers (which does
/// O(n) regex per request on Android):
/// 1. **Domain blocking** — O(1) hash set lookup in shouldOverrideUrlLoading
/// 2. **Cosmetic filtering** — JavaScript injection with MutationObserver
class ContentBlockerService {
  static const String _listsKey = 'content_blocker_lists';
  static const String _cacheDir = 'content_blocker_cache';

  static ContentBlockerService? _instance;
  static ContentBlockerService get instance =>
      _instance ??= ContentBlockerService._();

  ContentBlockerService._();

  List<FilterList> _lists = [];

  /// Aggregated blocked domains from all enabled lists.
  Set<String> _blockedDomains = {};

  /// Aggregated cosmetic selectors: domain -> selectors.
  /// Key '' = global selectors.
  Map<String, List<String>> _cosmeticSelectors = {};

  /// Aggregated text-based hiding rules: domain -> rules.
  Map<String, List<TextHideRule>> _textHideRules = {};

  /// All configured filter lists.
  List<FilterList> get lists => List.unmodifiable(_lists);

  /// Total rule count across all enabled lists.
  int get totalRuleCount =>
      _lists.where((l) => l.enabled).fold(0, (sum, l) => sum + l.ruleCount);

  /// Whether any rules are loaded.
  bool get hasRules => _blockedDomains.isNotEmpty || _cosmeticSelectors.isNotEmpty || _textHideRules.isNotEmpty;

  /// Check if a URL's domain (or any parent domain) is blocked.
  bool isBlocked(String url) {
    if (_blockedDomains.isEmpty) return false;
    try {
      final host = Uri.parse(url).host.toLowerCase();
      if (host.isEmpty) return false;
      // Check exact and parent domains: a.b.example.com -> b.example.com -> example.com
      String domain = host;
      while (domain.isNotEmpty) {
        if (_blockedDomains.contains(domain)) return true;
        final dotIdx = domain.indexOf('.');
        if (dotIdx < 0) break;
        domain = domain.substring(dotIdx + 1);
      }
    } catch (_) {}
    return false;
  }

  /// Collect applicable selectors and text rules for a page URL.
  ({List<String> selectors, List<TextHideRule> textRules}) _collectRules(String pageUrl) {
    final selectors = <String>[];
    final textRules = <TextHideRule>[];

    final globalSel = _cosmeticSelectors[''];
    if (globalSel != null) selectors.addAll(globalSel);
    final globalText = _textHideRules[''];
    if (globalText != null) textRules.addAll(globalText);

    try {
      final host = Uri.parse(pageUrl).host.toLowerCase();
      String domain = host;
      while (domain.isNotEmpty) {
        final ds = _cosmeticSelectors[domain];
        if (ds != null) selectors.addAll(ds);
        final tr = _textHideRules[domain];
        if (tr != null) textRules.addAll(tr);
        final dotIdx = domain.indexOf('.');
        if (dotIdx < 0) break;
        domain = domain.substring(dotIdx + 1);
      }
    } catch (_) {}

    return (selectors: selectors, textRules: textRules);
  }

  String _buildCssText(List<String> selectors) {
    final cssRules = StringBuffer();
    for (final s in selectors) {
      final escaped = s.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
      cssRules.write('$escaped { display: none !important; } ');
    }
    return cssRules.toString();
  }

  /// Get CSS-only JavaScript for early injection at DOCUMENT_START.
  /// Injects a <style> tag with display:none rules before content renders.
  /// Returns null if no CSS selectors apply.
  String? getEarlyCssScript(String pageUrl) {
    final rules = _collectRules(pageUrl);
    if (rules.selectors.isEmpty) return null;

    final cssText = _buildCssText(rules.selectors);

    return '''
(function() {
  var ID = '_webspace_content_blocker_style';
  if (document.getElementById(ID)) return;
  var s = document.createElement('style');
  s.id = ID;
  s.textContent = '$cssText';
  (document.head || document.documentElement || document).appendChild(s);
})();
''';
  }

  /// Get full JavaScript for injection after page load.
  /// Sets up MutationObserver for dynamic content and text-based hiding.
  /// Returns null if no cosmetic rules apply.
  String? getCosmeticScript(String pageUrl) {
    final rules = _collectRules(pageUrl);
    if (rules.selectors.isEmpty && rules.textRules.isEmpty) return null;

    final cssText = _buildCssText(rules.selectors);

    // Batch selectors for querySelectorAll resilience
    final escapedForJs = rules.selectors
        .map((s) => s.replaceAll('\\', '\\\\').replaceAll("'", "\\'"))
        .toList();
    final batches = <String>[];
    for (var i = 0; i < escapedForJs.length; i += 20) {
      final end = (i + 20 < escapedForJs.length) ? i + 20 : escapedForJs.length;
      batches.add(escapedForJs.sublist(i, end).join(', '));
    }
    final batchArray = batches.map((b) => "'$b'").join(',');

    // Build text-match rules array for JS
    final textRulesJs = StringBuffer('[');
    for (var i = 0; i < rules.textRules.length; i++) {
      if (i > 0) textRulesJs.write(',');
      final r = rules.textRules[i];
      final sel = r.selector.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
      final pats = r.textPatterns
          .map((p) => "'${p.replaceAll('\\', '\\\\').replaceAll("'", "\\'")}'")
          .join(',');
      textRulesJs.write("{sel:'$sel',pats:[$pats]}");
    }
    textRulesJs.write(']');

    return '''
(function() {
  var ID = '_webspace_content_blocker_style';
  if (!document.getElementById(ID)) {
    var s = document.createElement('style');
    s.id = ID;
    s.textContent = '$cssText';
    (document.head || document.documentElement).appendChild(s);
  }
  var BATCHES = [$batchArray];
  var TEXT_RULES = $textRulesJs;
  function hideCSS() {
    for (var i = 0; i < BATCHES.length; i++) {
      try { document.querySelectorAll(BATCHES[i]).forEach(function(el) { el.style.display = 'none'; }); } catch(e) {}
    }
  }
  function hideText() {
    for (var i = 0; i < TEXT_RULES.length; i++) {
      var r = TEXT_RULES[i];
      try {
        document.querySelectorAll(r.sel).forEach(function(el) {
          var text = el.textContent || '';
          for (var j = 0; j < r.pats.length; j++) {
            if (text.indexOf(r.pats[j]) !== -1) {
              el.style.display = 'none';
              break;
            }
          }
        });
      } catch(e) {}
    }
  }
  function hide() { hideCSS(); hideText(); }
  hide();
  var t = null;
  var obs = new MutationObserver(function() {
    if (t) clearTimeout(t);
    t = setTimeout(hide, 50);
  });
  if (document.body) {
    obs.observe(document.body, { childList: true, subtree: true });
  } else {
    document.addEventListener('DOMContentLoaded', function() {
      hide();
      if (document.body) obs.observe(document.body, { childList: true, subtree: true });
    });
  }
})();
''';
  }

  /// Initialize: load list metadata from prefs, parse cached files for enabled lists.
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final listsJson = prefs.getString(_listsKey);

      if (listsJson != null) {
        final List<dynamic> decoded = jsonDecode(listsJson);
        _lists = decoded
            .map((e) => FilterList.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      } else {
        // First run: add default lists (disabled until downloaded)
        _lists = _defaultLists
            .map((d) => FilterList(
                  id: d['id']!,
                  name: d['name']!,
                  url: d['url']!,
                ))
            .toList();
        await _saveLists();
      }

      // Parse cached filter text for enabled lists
      await _rebuildRules();

      if (kDebugMode) {
        debugPrint(
            '[ContentBlocker] Initialized: ${_lists.length} lists, '
            '${_blockedDomains.length} blocked domains, '
            '${_cosmeticSelectors.values.fold<int>(0, (s, l) => s + l.length)} cosmetic selectors');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ContentBlocker] Error initializing: $e');
      }
    }
  }

  /// Download a filter list by ID. Returns true on success.
  Future<bool> downloadList(String id) async {
    final list = _lists.firstWhere((l) => l.id == id,
        orElse: () => throw Exception('List not found: $id'));

    try {
      final response = await http
          .get(Uri.parse(list.url))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint(
              '[ContentBlocker] Download failed for ${list.name}: HTTP ${response.statusCode}');
        }
        return false;
      }

      // Cache raw text to disk
      final cacheFile = await _getCacheFile(id);
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsString(response.body);

      // Parse
      final result = await parseAbpFilterList(response.body);

      list.ruleCount = result.convertedCount;
      list.skippedCount = result.skippedCount;
      list.lastUpdated = DateTime.now();
      list.enabled = true;

      await _saveLists();
      await _rebuildRules();

      if (kDebugMode) {
        debugPrint(
            '[ContentBlocker] Downloaded ${list.name}: ${result.convertedCount} rules, ${result.skippedCount} skipped');
      }

      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ContentBlocker] Error downloading ${list.name}: $e');
      }
      return false;
    }
  }

  /// Download all enabled lists. Returns number of successful downloads.
  Future<int> downloadAllLists() async {
    int success = 0;
    for (final list in _lists) {
      if (list.enabled) {
        if (await downloadList(list.id)) {
          success++;
        }
      }
    }
    return success;
  }

  /// Add a custom filter list. Returns the new list's ID.
  Future<String> addCustomList(String name, String url) async {
    final id =
        'custom_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    _lists.add(FilterList(id: id, name: name, url: url));
    await _saveLists();
    return id;
  }

  /// Remove a filter list by ID.
  Future<void> removeList(String id) async {
    _lists.removeWhere((l) => l.id == id);

    // Delete cached file
    try {
      final cacheFile = await _getCacheFile(id);
      if (await cacheFile.exists()) {
        await cacheFile.delete();
      }
    } catch (_) {}

    await _saveLists();
    await _rebuildRules();
  }

  /// Toggle a filter list enabled/disabled.
  Future<void> toggleList(String id, bool enabled) async {
    final list = _lists.firstWhere((l) => l.id == id);
    list.enabled = enabled;
    await _saveLists();
    await _rebuildRules();
  }

  /// Rebuild aggregated rules from all enabled lists' cached files.
  Future<void> _rebuildRules() async {
    final allDomains = <String>{};
    final allSelectors = <String, List<String>>{};
    final allTextRules = <String, List<TextHideRule>>{};

    for (final list in _lists) {
      if (!list.enabled) continue;

      try {
        final cacheFile = await _getCacheFile(list.id);
        if (!await cacheFile.exists()) continue;

        final text = await cacheFile.readAsString();
        final result = parseAbpFilterListSync(text);
        allDomains.addAll(result.blockedDomains);

        for (final entry in result.cosmeticSelectors.entries) {
          allSelectors.putIfAbsent(entry.key, () => []).addAll(entry.value);
        }
        for (final entry in result.textHideRules.entries) {
          allTextRules.putIfAbsent(entry.key, () => []).addAll(entry.value);
        }

        list.ruleCount = result.convertedCount;
        list.skippedCount = result.skippedCount;
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
              '[ContentBlocker] Error parsing cached list ${list.name}: $e');
        }
      }
    }

    _blockedDomains = allDomains;
    _cosmeticSelectors = allSelectors;
    _textHideRules = allTextRules;
  }

  Future<void> _saveLists() async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(_lists.map((l) => l.toJson()).toList());
    await prefs.setString(_listsKey, json);
  }

  Future<File> _getCacheFile(String id) async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/$_cacheDir/$id.txt');
  }

  /// Exposed for testing: reset singleton state.
  @visibleForTesting
  void reset() {
    _lists = [];
    _blockedDomains = {};
    _cosmeticSelectors = {};
    _textHideRules = {};
  }

  /// Exposed for testing: set lists directly.
  @visibleForTesting
  void setLists(List<FilterList> lists) {
    _lists = lists;
  }
}
