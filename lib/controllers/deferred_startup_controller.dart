import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/page_orphan_sweep.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/services/deferred_startup_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/theme/app_theme.dart';

/// The page's side of [DeferredStartupEngine], which runs the post-paint
/// startup work (notification sites loading, timezones re-baked, the orphan
/// sweep). Everything is addressed by siteId and translated to a position
/// fresh per call, so a site added or deleted while that work awaits can
/// never make it act on a stale position.
class DeferredStartupController implements DeferredStartupHost {
  DeferredStartupController(
    this._sites, {
    required PageHost host,
    required ShellStore shell,
    required SiteActivationController activation,
    required WebViewStateStorage navStates,
    required PageOrphanSweep sweep,
  })  : _host = host,
        _shell = shell,
        _activation = activation,
        _navStates = navStates,
        _sweep = sweep;

  final SiteRuntime _sites;
  final PageHost _host;
  final ShellStore _shell;
  final SiteActivationController _activation;
  final WebViewStateStorage _navStates;
  final PageOrphanSweep _sweep;

  @override
  List<DeferredSite> currentSites() => [
        for (final m in _sites.models)
          DeferredSite(
            siteId: m.siteId,
            notificationsEnabled: m.effectiveNotificationsEnabled,
            spoofTimezoneFromLocation: m.spoofTimezoneFromLocation,
            trackingProtectionEnabled: m.trackingProtectionEnabled,
            spoofLatitude: m.spoofLatitude,
            spoofLongitude: m.spoofLongitude,
          ),
      ];

  @override
  bool get isMounted => _host.mounted;

  @override
  bool isLive(String siteId) => _sites.byId(siteId) != null;

  @override
  bool isLoaded(String siteId) {
    final i = _sites.models.indexWhere((m) => m.siteId == siteId);
    return i >= 0 && _sites.loaded.contains(i);
  }

  @override
  void markLoaded(String siteId) {
    final i = _sites.models.indexWhere((m) => m.siteId == siteId);
    if (i >= 0) _sites.loaded.add(i);
  }

  @override
  Future<void> preloadHtml(String siteId) async {
    final m = _sites.byId(siteId);
    if (m != null) await _activation.ensureSiteHtmlForModel(m);
  }

  @override
  Future<void> applyTheme(String siteId) async {
    final m = _sites.byId(siteId);
    if (m != null) {
      await m.setTheme(_shell.theme.themeMode.webViewTheme);
    }
  }

  /// PAUSE-019: pre-queue the saved back/forward stack for a site that
  /// is about to enter `_sites.loaded` without going through
  /// `setCurrentIndex` (auto-loaded notification sites). Once it's in
  /// the set, the activation path skips its restore fetch, so a queue
  /// here is the only chance the bytes get applied on this run.
  @override
  Future<void> queueNavStateRestore(String siteId) async {
    final model = _sites.byId(siteId);
    if (model == null) return;
    // A live controller can't consume queued bytes — restoreState only
    // applies to a freshly-created one.
    if (!model.activeTabPersistsNavState || model.controller != null) return;
    final bytes = await _navStates.loadState(model.activeStateKey);
    if (bytes == null) return;
    // Re-resolve after the disk read: the site may have been deleted.
    if (_sites.byId(siteId) == null) return;
    model.schedulePendingRestoreState(bytes);
    LogTag.webViewState.debug(
        'Queued ${bytes.length} restore bytes for auto-loaded site '
        '"${model.name}" (siteId: $siteId)', sensitive: true);
  }

  @override
  void requestRebuild() => _host.rebuild();

  @override
  Future<bool> loadTimezoneDataset() =>
      TimezoneLocationService.instance.loadFromCacheIfPresent();

  @override
  String? resolveTimezone(double latitude, {required double longitude}) =>
      TimezoneLocationService.instance.lookup(latitude, longitude: longitude);

  @override
  bool setSpoofTimezone(String siteId, {required String timezone}) {
    final m = _sites.byId(siteId);
    if (m != null && m.spoofTimezone != timezone) {
      m.spoofTimezone = timezone;
      return true;
    }
    return false;
  }

  @override
  Future<void> persist() => _host.commitSites(const SitesEdited());

  @override
  Set<String> liveSiteIds() => _sites.siteIds;

  @override
  Set<String> liveNonIncognitoSiteIds() => _sites.nonIncognitoSiteIds;

  @override
  Future<void> sweepOrphanStorage(
    Set<String> activeSiteIds, {
    required Set<String> nonIncognitoSiteIds,
  }) =>
      _sweep.atLaunch(activeSiteIds, nonIncognitoSiteIds: nonIncognitoSiteIds);
}
