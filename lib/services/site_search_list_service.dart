import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/host_storage.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/site_search_list_engine.dart';

const String _cacheFileName = 'site_search_list.json';
const String _lastUpdatedPrefKey = 'site_search_list_last_updated';

/// Largest download read. The list is about 2 MB today.
const int _maxDownloadBytes = 16 * 1024 * 1024;

/// The site search list (LIR-036): downloaded only when the user asks, through
/// the app-wide proxy, reduced to one address per site and kept in app
/// private storage until cleared. Same opt-in pattern as the timezone dataset
/// and the blocklists.
class SiteSearchListService {
  static SiteSearchListService? _instance;
  static SiteSearchListService get instance =>
      _instance ??= SiteSearchListService._();

  SiteSearchListService._();

  @visibleForTesting
  static void resetForTest() => _instance = null;

  Map<String, String> _table = const {};
  DateTime? _lastUpdated;

  /// Sites the loaded list has an address for; 0 when none is loaded.
  int get siteCount => _table.length;

  bool get isLoaded => _table.isNotEmpty;

  DateTime? get lastUpdated => _lastUpdated;

  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback l) => _listeners.add(l);
  void removeListener(VoidCallback l) => _listeners.remove(l);
  void _notify() {
    for (final l in List<VoidCallback>.from(_listeners)) {
      l();
    }
  }

  /// Hold [table] as the list without storing it: demo and gallery data.
  void setInMemory(Map<String, String> table, {DateTime? updated}) {
    _table = Map.unmodifiable(table);
    _lastUpdated = updated;
    _notify();
  }

  /// The address the list names for the site at [initUrl], or null.
  String? addressFor(String initUrl) =>
      listedAddressFor(_table, initUrl: initUrl);

  /// Load the stored list, if any. Called at startup; nothing is fetched.
  Future<void> initialize() async {
    final text = await hostReadDocumentText(_cacheFileName);
    if (text == null) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      LogTag.searchList.warning('Stored list unreadable: $e');
      return;
    }
    if (decoded is! Map) return;
    _table = {
      for (final e in decoded.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    };
    final prefs = await SharedPreferences.getInstance();
    _lastUpdated =
        DateTime.tryParse(prefs.getString(_lastUpdatedPrefKey) ?? '');
    _notify();
  }

  /// Download the list and keep its reduction. True on success; a failure
  /// leaves the stored list as it was.
  Future<bool> download({Duration timeout = const Duration(minutes: 2)}) async {
    final fetched = await fetchViaAppProxy(Uri.parse(kSiteSearchListUrl),
        tag: LogTag.searchList, timeout: timeout, maxBytes: _maxDownloadBytes);
    final response = switch (fetched) {
      Fetched(:final response) => response,
      FetchRefused() || FetchFailed() => null,
    };
    if (response == null) return false;
    try {
      final table = await compute(_reduce, response.body);
      if (table.isEmpty) {
        LogTag.searchList.error('Download held no usable entry');
        return false;
      }
      await hostWriteDocumentText(_cacheFileName, contents: jsonEncode(table));
      final now = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastUpdatedPrefKey, now.toIso8601String());
      _table = table;
      _lastUpdated = now;
      LogTag.searchList.debug('Downloaded ${table.length} site searches');
      _notify();
      return true;
    } on Exception catch (e) {
      // A body that is not JSON, or the store's own failure. Errors are bugs
      // and still reach the caller.
      LogTag.searchList.error('Download error: $e');
      return false;
    }
  }

  /// Drop the stored list and forget every address it gave.
  Future<void> clear() async {
    _table = const {};
    _lastUpdated = null;
    await hostDeleteFile('${await hostDocumentsPath()}/$_cacheFileName');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastUpdatedPrefKey);
    _notify();
  }
}

Map<String, String> _reduce(String body) => siteSearchTable(jsonDecode(body));
