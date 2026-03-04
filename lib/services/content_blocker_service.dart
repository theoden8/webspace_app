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

  /// Cached CSS injection script (rebuilt when rules change).
  String? _cosmeticScript;

  /// All configured filter lists.
  List<FilterList> get lists => List.unmodifiable(_lists);

  /// Total rule count across all enabled lists.
  int get totalRuleCount =>
      _lists.where((l) => l.enabled).fold(0, (sum, l) => sum + l.ruleCount);

  /// Whether any rules are loaded.
  bool get hasRules => _blockedDomains.isNotEmpty || _cosmeticSelectors.isNotEmpty;

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

  /// Get JavaScript to inject for cosmetic filtering on a given page URL.
  /// Returns null if no cosmetic rules apply.
  String? getCosmeticScript(String pageUrl) {
    if (_cosmeticSelectors.isEmpty) return null;

    // Collect applicable selectors: global + domain-specific
    final selectors = <String>[];

    final global = _cosmeticSelectors[''];
    if (global != null) selectors.addAll(global);

    try {
      final host = Uri.parse(pageUrl).host.toLowerCase();
      // Check domain-specific selectors for this host and parent domains
      String domain = host;
      while (domain.isNotEmpty) {
        final domainSelectors = _cosmeticSelectors[domain];
        if (domainSelectors != null) selectors.addAll(domainSelectors);
        final dotIdx = domain.indexOf('.');
        if (dotIdx < 0) break;
        domain = domain.substring(dotIdx + 1);
      }
    } catch (_) {}

    if (selectors.isEmpty) return null;

    // Build JS that:
    // 1. Injects a <style> with display:none for all selectors
    // 2. Uses MutationObserver to re-apply to dynamically added content
    final escapedSelectors = selectors
        .map((s) => s.replaceAll('\\', '\\\\').replaceAll("'", "\\'"))
        .join(', ');

    return '''
(function() {
  var SEL = '$escapedSelectors';
  var ID = '_webspace_content_blocker_style';
  if (document.getElementById(ID)) return;
  function inject() {
    if (!document.head && !document.documentElement) return;
    var s = document.createElement('style');
    s.id = ID;
    s.textContent = SEL + ' { display: none !important; }';
    (document.head || document.documentElement).appendChild(s);
  }
  inject();
  if (!document.getElementById(ID)) {
    // head not ready yet — retry when DOM is available
    document.addEventListener('DOMContentLoaded', function() { inject(); });
  }
  function hide() {
    try { document.querySelectorAll(SEL).forEach(function(el) { el.style.display = 'none'; }); } catch(e) {}
  }
  hide();
  var obs = new MutationObserver(function() { hide(); });
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

    for (final list in _lists) {
      if (!list.enabled) continue;

      try {
        final cacheFile = await _getCacheFile(list.id);
        if (!await cacheFile.exists()) continue;

        final text = await cacheFile.readAsString();
        final result = parseAbpFilterListSync(text);
        allDomains.addAll(result.blockedDomains);

        // Merge cosmetic selectors
        for (final entry in result.cosmeticSelectors.entries) {
          allSelectors.putIfAbsent(entry.key, () => []).addAll(entry.value);
        }

        // Update counts from re-parse
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
    _cosmeticScript = null; // Invalidate cached script
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
    _cosmeticScript = null;
  }

  /// Exposed for testing: set lists directly.
  @visibleForTesting
  void setLists(List<FilterList> lists) {
    _lists = lists;
  }
}
