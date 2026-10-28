import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/bounded_inflate.dart';
import 'package:webspace/services/dns_block_service.dart'
    show fetchDomainList, hageziMirrorUrls;
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/top_sites_engine.dart';
import 'package:webspace/settings/app_prefs.dart';

const String _rowsName = 'rows.csv';
const String _lastUpdatedPrefKey = 'top_sites_last_updated';
const String _filtersKeptPrefKey = 'top_sites_filters_kept';

/// How much of the gzipped list a download fetches: the rows down to
/// [kTopSitesRank] take about 90 KB of the whole list's 9 MB.
const int _rangeBytes = 256 * 1024;

/// Largest text the fetched range is inflated to.
const int _maxTextBytes = 4 * 1024 * 1024;

/// How long kept filter lists stand in for a download of them (SUGGEST-011).
const Duration kTopSitesFiltersKept = Duration(days: 30);

/// The popular sites list (SUGGEST-008): downloaded only when the user asks,
/// through the app-wide proxy, only its top rows, filtered, and kept in app
/// private storage until cleared. Read from disk only where it is used, the
/// add-site screen and its settings row, so a launch never waits on it.
class TopSitesService {
  static TopSitesService? _instance;
  static TopSitesService get instance => _instance ??= TopSitesService._();

  TopSitesService._() {
    AppPref.topSitesKeepFilters.listenable.addListener(_keepChanged);
  }

  @visibleForTesting
  static void resetForTest() {
    final instance = _instance;
    if (instance != null) {
      AppPref.topSitesKeepFilters.listenable
          .removeListener(instance._keepChanged);
    }
    _instance = null;
  }

  final FileStore _store = defaultFileStore('top_sites', kind: StoreKind.cache);

  TopSites _sites = TopSites.empty;
  DateTime? _lastUpdated;
  Future<void>? _loading;

  /// Bumped by every change after the stored list was read, so a read that
  /// finishes after a download or a clear does not undo it.
  int _version = 0;

  int get siteCount => _sites.length;

  bool get isLoaded => !_sites.isEmpty;

  DateTime? get lastUpdated => _lastUpdated;

  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback l) => _listeners.add(l);
  void removeListener(VoidCallback l) => _listeners.remove(l);
  void _notify() {
    for (final l in List<VoidCallback>.from(_listeners)) {
      l();
    }
  }

  /// The addresses the list offers for [typed], best first, less those of
  /// [added]; none until loaded.
  List<String> match(String typed, {required Set<String> added}) =>
      _sites.match(typed, added: added);

  /// Hold [csv], a CrUX list, without storing it, in place of what is
  /// stored: demo, gallery and tests.
  void setInMemory(String csv, {DateTime? updated}) {
    _version++;
    _loading = Future.value();
    _sites = TopSites.fromCrux(csv);
    _lastUpdated = updated;
    _notify();
  }

  /// Read the stored list, once; nothing is fetched.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final version = _version;
    final String? text;
    try {
      text = await _store.readText(_rowsName);
    } on IOException catch (e) {
      LogTag.topSites.warning('Stored list unreadable: $e');
      return;
    }
    if (text == null) return;
    final sites = await compute(TopSites.fromCrux, text);
    final prefs = await SharedPreferences.getInstance();
    if (version != _version) return;
    _sites = sites;
    _lastUpdated =
        DateTime.tryParse(prefs.getString(_lastUpdatedPrefKey) ?? '');
    _notify();
  }

  /// Download the list's top rows and keep them, dropped through every
  /// [TopSitesFilter]. True on success; a failure of any list leaves the
  /// stored list as it was.
  Future<bool> download({Duration timeout = const Duration(minutes: 1)}) async {
    bool failed(Exception e) {
      LogTag.topSites.error('Download error: $e');
      return false;
    }

    try {
      final filters = await _filters(timeout: timeout);
      if (filters == null) return false;
      final fetched = await fetchViaAppProxy(Uri.parse(kTopSitesUrl),
          tag: LogTag.topSites, timeout: timeout, firstBytes: _rangeBytes);
      final response = switch (fetched) {
        Fetched(:final response) => response,
        FetchRefused() || FetchFailed() => null,
      };
      if (response == null) return false;
      final head =
          await compute(_head, (gz: response.bodyBytes, filters: filters));
      final sites = await compute(TopSites.fromCrux, head);
      if (sites.isEmpty) {
        LogTag.topSites.error('Download held no usable row');
        return false;
      }
      await _store.writeText(_rowsName, contents: head);
      final now = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastUpdatedPrefKey, now.toIso8601String());
      _version++;
      _sites = sites;
      _lastUpdated = now;
      LogTag.topSites.debug('Downloaded ${sites.length} popular sites');
      _notify();
      return true;
    } on FormatException catch (e) {
      return failed(e);
    } on IOException catch (e) {
      return failed(e);
    } on PlatformException catch (e) {
      return failed(e);
    } on MissingPluginException catch (e) {
      return failed(e);
    }
  }

  /// Every [TopSitesFilter]'s lists (SUGGEST-011): the kept ones while
  /// [AppPref.topSitesKeepFilters] is on and they are younger than
  /// [kTopSitesFiltersKept], else fetched now, and kept while it is on. Null
  /// when one cannot be fetched.
  Future<List<FilterLists>?> _filters({required Duration timeout}) async {
    final keep = AppPref.topSitesKeepFilters.value;
    if (keep) {
      final kept = await _keptFilters();
      if (kept != null) return kept;
    }
    final fetched = await Future.wait([
      for (final filter in TopSitesFilter.values)
        _fetchFilter(filter, timeout: timeout),
    ]);
    if (fetched.contains(null)) return null;
    final filters = fetched.nonNulls.toList();
    if (keep) await _keepFilters(filters);
    return filters;
  }

  Future<FilterLists?> _fetchFilter(TopSitesFilter filter,
      {required Duration timeout}) async {
    Future<String?> fetch(FilterSource source, {required bool tlds}) =>
        fetchDomainList(
          switch (source) {
            HageziFile(:final path) => hageziMirrorUrls(path),
            FixedUrls(:final urls) => urls,
          },
          tag: LogTag.topSites,
          timeout: timeout,
          tlds: tlds,
        );
    final allowSource = filter.allow;
    final (block, allow) = await (
      fetch(filter.block, tlds: filter.tlds),
      allowSource == null
          ? Future<String?>.value('')
          : fetch(allowSource, tlds: false),
    ).wait;
    if (block == null || allow == null) return null;
    return (block: block, allow: allow);
  }

  /// The kept lists, or null where they are too old or not all there.
  Future<List<FilterLists>?> _keptFilters() async {
    final prefs = await SharedPreferences.getInstance();
    final kept = DateTime.tryParse(prefs.getString(_filtersKeptPrefKey) ?? '');
    if (kept == null ||
        DateTime.now().difference(kept) > kTopSitesFiltersKept) {
      return null;
    }
    List<FilterLists>? unreadable(Exception e) {
      LogTag.topSites.warning('Kept filter lists unreadable: $e');
      return null;
    }

    try {
      final packed = <Uint8List>[];
      for (final filter in TopSitesFilter.values) {
        final bytes = await _store.readBytes(_keptName(filter));
        if (bytes == null) return null;
        packed.add(bytes);
      }
      return await compute(_unpack, packed);
    } on FormatException catch (e) {
      return unreadable(e);
    } on IOException catch (e) {
      return unreadable(e);
    }
  }

  /// Keep [filters] for the next download; one that cannot be kept is
  /// fetched again then.
  Future<void> _keepFilters(List<FilterLists> filters) async {
    final packed = await compute(_pack, filters);
    try {
      for (final (i, filter) in TopSitesFilter.values.indexed) {
        await _store.writeBytes(_keptName(filter), bytes: packed[i]);
      }
    } on IOException catch (e) {
      LogTag.topSites.warning('Filter lists not kept: $e');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _filtersKeptPrefKey, DateTime.now().toIso8601String());
  }

  void _keepChanged() {
    if (!AppPref.topSitesKeepFilters.value) unawaited(_forgetFilters());
  }

  Future<void> _forgetFilters() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_filtersKeptPrefKey);
    try {
      for (final filter in TopSitesFilter.values) {
        await _store.delete(_keptName(filter));
      }
    } on IOException catch (e) {
      LogTag.topSites.warning('Kept filter lists not removed: $e');
    }
  }

  /// Drop the stored list, the kept filter lists, and every match they gave.
  Future<void> clear() async {
    _version++;
    _sites = TopSites.empty;
    _lastUpdated = null;
    try {
      await _store.deleteAll();
    } on IOException catch (e) {
      LogTag.topSites.warning('Stored list not removed: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastUpdatedPrefKey);
    await prefs.remove(_filtersKeptPrefKey);
    _notify();
  }
}

String _keptName(TopSitesFilter filter) => '${filter.name}.gz';

/// The rows a [TopSites] reads from the start of the gzipped list `gz`,
/// less those `filters` drop.
String _head(({Uint8List gz, List<FilterLists> filters}) fetched) => cruxHead(
    utf8.decode(
        inflatePrefix(hostGzipDecoder,
            compressed: fetched.gz, limit: _maxTextBytes),
        allowMalformed: true),
    filters: fetched.filters);

/// Each filter's lists as one gzipped JSON pair, as kept on disk.
List<Uint8List> _pack(List<FilterLists> filters) => [
      for (final f in filters)
        Uint8List.fromList(hostGzipEncoder
            .convert(utf8.encode(jsonEncode([f.block, f.allow])))),
    ];

List<FilterLists> _unpack(List<Uint8List> packed) => [
      for (final bytes in packed)
        switch (jsonDecode(utf8.decode(hostGzipDecoder.convert(bytes)))) {
          [final String block, final String allow] =>
            (block: block, allow: allow),
          _ => throw const FormatException('not a kept filter'),
        },
    ];
