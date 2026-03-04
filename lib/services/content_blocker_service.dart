import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'abp_filter_parser.dart';

/// Maximum number of content blocker rules to avoid performance issues.
const int maxContentBlockerRules = 50000;

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

/// Singleton service for managing ABP filter lists and generating ContentBlocker rules.
class ContentBlockerService {
  static const String _listsKey = 'content_blocker_lists';
  static const String _cacheDir = 'content_blocker_cache';

  static ContentBlockerService? _instance;
  static ContentBlockerService get instance =>
      _instance ??= ContentBlockerService._();

  ContentBlockerService._();

  List<FilterList> _lists = [];
  List<ContentBlocker> _contentBlockers = [];

  /// All configured filter lists.
  List<FilterList> get lists => List.unmodifiable(_lists);

  /// Aggregated content blocker rules from all enabled lists.
  List<ContentBlocker> get contentBlockers => _contentBlockers;

  /// Total rule count across all enabled lists.
  int get totalRuleCount =>
      _lists.where((l) => l.enabled).fold(0, (sum, l) => sum + l.ruleCount);

  /// Whether any rules are loaded.
  bool get hasRules => _contentBlockers.isNotEmpty;

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
      await _rebuildContentBlockers();

      if (kDebugMode) {
        debugPrint(
            '[ContentBlocker] Initialized: ${_lists.length} lists, ${_contentBlockers.length} rules');
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

      // Parse — skip exception rules on platforms that don't support IGNORE_PREVIOUS_RULES
      final skipExceptions = !kIsWeb && (Platform.isAndroid || Platform.isLinux || Platform.isWindows);
      final result =
          await parseAbpFilterList(response.body, skipExceptions: skipExceptions);

      list.ruleCount = result.convertedCount;
      list.skippedCount = result.skippedCount;
      list.lastUpdated = DateTime.now();
      list.enabled = true;

      await _saveLists();
      await _rebuildContentBlockers();

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
    await _rebuildContentBlockers();
  }

  /// Toggle a filter list enabled/disabled.
  Future<void> toggleList(String id, bool enabled) async {
    final list = _lists.firstWhere((l) => l.id == id);
    list.enabled = enabled;
    await _saveLists();
    await _rebuildContentBlockers();
  }

  /// Rebuild aggregated content blockers from all enabled lists' cached files.
  Future<void> _rebuildContentBlockers() async {
    final allRules = <ContentBlocker>[];
    final skipExceptions = !kIsWeb && (Platform.isAndroid || Platform.isLinux || Platform.isWindows);

    for (final list in _lists) {
      if (!list.enabled) continue;

      try {
        final cacheFile = await _getCacheFile(list.id);
        if (!await cacheFile.exists()) continue;

        final text = await cacheFile.readAsString();
        final result = parseAbpFilterListSync(text, skipExceptions: skipExceptions);
        allRules.addAll(result.rules);

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

    // Cap at max rules
    if (allRules.length > maxContentBlockerRules) {
      _contentBlockers = allRules.sublist(0, maxContentBlockerRules);
      if (kDebugMode) {
        debugPrint(
            '[ContentBlocker] Capped rules from ${allRules.length} to $maxContentBlockerRules');
      }
    } else {
      _contentBlockers = allRules;
    }
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
    _contentBlockers = [];
  }

  /// Exposed for testing: set lists directly.
  @visibleForTesting
  void setLists(List<FilterList> lists) {
    _lists = lists;
  }
}
