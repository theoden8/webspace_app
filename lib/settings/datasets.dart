/// The App Settings datasets, each adapted to [DownloadableDataset] so one
/// [DatasetTile] renders them all.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/firefox_user_agent_service.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/site_search_list_service.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/widgets/dataset_tile.dart';

/// State read back from disk, so a reload that finishes after a newer one
/// started is dropped rather than shown.
abstract class _LoadedDataset extends ChangeNotifier
    implements DownloadableDataset {
  _LoadedDataset() {
    _reload();
  }

  int _generation = 0;
  bool _disposed = false;

  /// Reads the state, writing it only while [isCurrent] still holds.
  Future<void> load(bool Function() isCurrent);

  Future<void> _reload() async {
    final generation = ++_generation;
    await load(() => !_disposed && generation == _generation);
    if (generation == _generation) _notify();
  }

  /// A download can outlive the row that started it.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Timezone polygons behind the per-site "From picked location" timezone.
/// Reads the dataset on disk, not the in-memory one: only the lookup paths
/// load it, so a downloaded dataset is usually not in memory here (LOC-010).
class TimezoneDataset extends _LoadedDataset implements ClearableDataset {
  TimezoneDataset() {
    _service.addListener(_reload);
  }

  final _service = TimezoneLocationService.instance;
  bool _cached = false;
  DateTime? _updated;
  int? _zones;

  @override
  Future<void> load(bool Function() isCurrent) async {
    final cached = await _service.hasCachedDataset();
    final updated = await _service.getLastUpdated();
    final zones = cached ? await _service.cachedZoneCount() : null;
    if (!isCurrent()) return;
    _cached = cached && zones != null;
    _updated = updated;
    _zones = zones;
  }

  @override
  bool get ready => _cached;

  @override
  DateTime? get lastUpdated => _cached ? _updated : null;

  @override
  String? status(AppLocalizations loc) => _cached
      ? loc.appSettingsZonesCount(compactCount(_zones!))
      : loc.appSettingsNotDownloaded;

  @override
  Future<String> download(AppLocalizations loc) async =>
      await _service.download()
      ? loc.appSettingsTimezonesLoaded(_service.zoneCount)
      : loc.appSettingsTimezonesDownloadFailed;

  @override
  Future<String?> clear(AppLocalizations loc) async {
    await _service.clear();
    return null;
  }

  @override
  void dispose() {
    _service.removeListener(_reload);
    super.dispose();
  }
}

class ClearUrlsDataset extends _LoadedDataset {
  final _service = ClearUrlService.instance;
  DateTime? _updated;

  @override
  Future<void> load(bool Function() isCurrent) async {
    final updated = await _service.getLastUpdated();
    if (isCurrent()) _updated = updated;
  }

  @override
  bool get ready => _updated != null;

  @override
  DateTime? get lastUpdated => _updated;

  @override
  String? status(AppLocalizations loc) =>
      ready ? null : loc.appSettingsNotDownloaded;

  @override
  Future<String> download(AppLocalizations loc) async {
    if (!await _service.downloadRules()) {
      return loc.appSettingsClearUrlsDownloadFailed;
    }
    await _reload();
    return loc.appSettingsClearUrlsUpdated;
  }
}

/// The Hagezi blocklist. The level slider under the row picks which level a
/// download fetches; the row reads as current only while it names the level
/// that is on disk.
class DnsBlocklistDataset extends _LoadedDataset {
  final _service = DnsBlockService.instance;
  late int _level = _service.level;
  late int _picked = _level;
  DateTime? _updated;

  int get picked => _picked;

  void pick(int level) {
    _picked = level;
    _notify();
  }

  @override
  Future<void> load(bool Function() isCurrent) async {
    final updated = await _service.getLastUpdated();
    if (!isCurrent()) return;
    _updated = updated;
    _level = _service.level;
  }

  @override
  bool get ready => _picked == _level;

  @override
  DateTime? get lastUpdated => _updated;

  @override
  String? status(AppLocalizations loc) => _level > 0
      ? loc.appSettingsDnsBlockLevelDomains(
          dnsBlockLevelNames[_level],
          compactCount(_service.domainCount),
        )
      : loc.appSettingsNotConfigured;

  @override
  Future<String> download(AppLocalizations loc) async {
    final level = _picked;
    if (!await _service.downloadList(level)) {
      return loc.appSettingsDnsBlocklistDownloadFailed;
    }
    await _reload();
    // The service re-pushes domains to the native interceptor on change;
    // webviews still need (re)attaching.
    await WebInterceptNative.attachToWebViews();
    return level == 0
        ? loc.appSettingsDnsBlocklistDisabled
        : loc.appSettingsDnsBlocklistUpdated(
            compactCount(_service.domainCount),
          );
  }
}

class LocalCdnDataset extends _LoadedDataset implements ClearableDataset {
  final _service = LocalCdnService.instance;
  int _count = 0;
  String _size = LocalCdnService.formatSize(0);
  DateTime? _updated;
  String? _progress;

  @override
  Future<void> load(bool Function() isCurrent) async {
    final size = await _service.cacheSize;
    final updated = await _service.getLastUpdated();
    if (!isCurrent()) return;
    _count = _service.resourceCount;
    _size = LocalCdnService.formatSize(size);
    _updated = updated;
  }

  @override
  bool get ready => _count > 0;

  @override
  DateTime? get lastUpdated => _updated;

  @override
  String? status(AppLocalizations loc) {
    final progress = _progress;
    if (progress != null) return loc.appSettingsDownloadingProgress(progress);
    return ready
        ? loc.appSettingsLocalCdnResources(_count, _size)
        : loc.appSettingsNotDownloaded;
  }

  @override
  Future<String> download(AppLocalizations loc) async {
    final downloaded = await _service.downloadPopularResources(
      onProgress: (completed, total) {
        _progress = '$completed/$total';
        _notify();
      },
    );
    _progress = null;
    await _reload();
    return loc.appSettingsLocalCdnDownloaded(downloaded);
  }

  @override
  Future<String?> clear(AppLocalizations loc) async {
    await _service.clearCache();
    await _reload();
    return loc.appSettingsLocalCdnCacheCleared;
  }
}

/// The downloaded site search list (LIR-036), fetched only from its row.
class SiteSearchListDataset extends ChangeNotifier implements ClearableDataset {
  SiteSearchListDataset() {
    _service.addListener(notifyListeners);
  }

  final _service = SiteSearchListService.instance;

  @override
  bool get ready => _service.isLoaded;

  @override
  DateTime? get lastUpdated => ready ? _service.lastUpdated : null;

  @override
  String? status(AppLocalizations loc) => ready
      ? loc.webSearchSiteListCount(compactCount(_service.siteCount))
      : loc.appSettingsNotDownloaded;

  @override
  Future<String> download(AppLocalizations loc) async =>
      await _service.download()
      ? loc.webSearchSiteListLoaded(compactCount(_service.siteCount))
      : loc.webSearchSiteListFailed;

  @override
  Future<String?> clear(AppLocalizations loc) async {
    await _service.clear();
    return null;
  }

  @override
  void dispose() {
    _service.removeListener(notifyListeners);
    super.dispose();
  }
}

/// The Firefox version generated User-Agents render at (DM-004). Always has
/// a value (the bundled default), so the row only ever refreshes it.
class FirefoxVersionDataset extends _LoadedDataset {
  final _service = FirefoxUserAgentService.instance;

  /// Whether the weekly check at startup is armed.
  bool get autoRefresh => AppPref.firefoxUaAutoRefresh.value;

  Future<void> setAutoRefresh(bool value) async {
    final saved = AppPref.firefoxUaAutoRefresh.set(value);
    _notify();
    await saved;
  }

  @override
  Future<void> load(bool Function() isCurrent) async {
    final prefs = await SharedPreferences.getInstance();
    if (isCurrent()) AppPref.firefoxUaAutoRefresh.load(prefs);
  }

  @override
  bool get ready => true;

  @override
  DateTime? get lastUpdated => _service.lastChecked;

  @override
  String? status(AppLocalizations loc) =>
      loc.appSettingsFirefoxVersionCurrent(_service.majorVersion);

  @override
  Future<String> download(AppLocalizations loc) async {
    final result = await _service.refresh();
    _notify();
    final version = _service.majorVersion;
    return switch (result) {
      FirefoxVersionRefreshResult.updated =>
        loc.appSettingsFirefoxVersionUpdated(version),
      FirefoxVersionRefreshResult.unchanged =>
        loc.appSettingsFirefoxVersionUnchanged(version),
      FirefoxVersionRefreshResult.failed => loc.appSettingsFirefoxVersionFailed,
    };
  }
}
