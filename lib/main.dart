import 'dart:convert';
import 'dart:async';
import 'dart:math' show min, max;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp
    show InAppWebViewController, ServiceWorkerController, SslCertificate;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/controllers/app_lifecycle_controller.dart';
import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/controllers/background_sites_controller.dart';
import 'package:webspace/controllers/link_controller.dart';
import 'package:webspace/controllers/site_network_controller.dart';
import 'package:webspace/controllers/shortcut_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/screens/add_site.dart' show AddSiteScreen, UnifiedFaviconImage, FaviconUrlCache, SiteSuggestion;
import 'package:webspace/screens/settings.dart';
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/screens/block_stats.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/startup_init_engine.dart';
import 'package:webspace/screens/inappbrowser.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/screens/webspace_detail.dart';
import 'package:webspace/services/tab_bar_corner.dart';
import 'package:webspace/services/fullscreen_system_ui.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';
import 'package:webspace/widgets/find_toolbar.dart';
import 'package:webspace/widgets/tabs_sheet.dart';
import 'package:webspace/services/web_search_engine.dart';
import 'package:webspace/widgets/site_info_sheet.dart';
import 'package:webspace/widgets/url_bar.dart';
import 'package:webspace/demo_data.dart' show isDemoMode;
import 'package:webspace/services/image_cache_service.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/http_auth_secure_storage.dart';
import 'package:webspace/services/html_source.dart';
import 'package:webspace/services/deferred_startup_engine.dart';
import 'package:webspace/services/timezone_spoof_policy.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/settings_import_engine.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/surface_diag_native.dart';
import 'package:webspace/services/surface_route_observer.dart';
import 'package:webspace/services/diag_seed.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/archive.dart' show ArchiveHandle;
import 'package:webspace/services/archive_membership_engine.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/container_cookie_manager.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/services/site_search_list_service.dart';
import 'package:webspace/services/site_activation_engine.dart';
import 'package:webspace/services/site_icon_store.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/site_teardown_engine.dart';
import 'package:webspace/services/app_lifecycle_engine.dart';
import 'package:webspace/services/back_gesture_engine.dart';
import 'package:webspace/services/site_data_clear_engine.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/container_color_engine.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/orphan_sweep_engine.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/page_title.dart';
import 'package:webspace/controllers/site_list_store.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/nav_state_capture_debouncer.dart';
import 'package:webspace/services/webview_state_secure_storage.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/services/startup_restore_engine.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/ubo_backup_import.dart' show UboTrustedSite, hostTrustedBy;
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/firefox_user_agent_service.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/services/launch_context.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/screen_capture_guard.dart';
import 'package:webspace/services/shortcut_service.dart';
import 'package:webspace/services/background_log.dart';
import 'package:webspace/services/link_intent_dispatch_engine.dart';
import 'package:webspace/services/nested_open_engine.dart';
import 'package:webspace/screens/link_handling_settings.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/suggested_sites_service.dart' as suggested_sites;
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/pref_read.dart';
import 'package:webspace/settings/app_locale.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/external_tor.dart';
import 'package:webspace/settings/setting_labels.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/services/virtual_media_picker.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/proxy_library.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webspace/widgets/download_button.dart';
import 'package:webspace/widgets/edit_site_dialog.dart';
import 'package:webspace/widgets/external_url_prompt.dart';
import 'package:webspace/widgets/root_messenger.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/site_webview_stack.dart';
import 'package:webspace/widgets/tab_count_pill.dart';
import 'package:webspace/widgets/fullscreen_overlays.dart';
import 'package:webspace/widgets/archive_prompts.dart';
import 'package:webspace/widgets/link_prompts.dart';
import 'package:webspace/widgets/page_load_bar.dart';
import 'package:webspace/widgets/protection_shield_button.dart';
import 'package:webspace/widgets/theme_mode_button.dart';
import 'package:webspace/widgets/shortcut_prompts.dart';
import 'package:webspace/widgets/surface_nudge_scope.dart';
import 'package:webspace/widgets/http_auth_prompt.dart';
import 'package:webspace/widgets/untrusted_cert_prompt.dart';

// Accent color enum
enum AccentColor {
  blue,
  green,
  purple,
  orange,
  red,
  pink,
  teal,
  yellow,
}

/// LicenseEntry that emits one [LicenseParagraph] per source line,
/// so structural single line breaks (license titles, numbered
/// section headers, template lines) survive the renderer.
///
/// `LicenseEntryWithLineBreaks` only breaks on blank lines and
/// folds every other `\n` into a space, which collapses Apache-2.0
/// title blocks and similar multi-line headers into one wrapping
/// paragraph. The license texts the `license` Rust crate emits
/// (and the bundled assets/licenses/*.txt files) all use single
/// `\n` for structural breaks AND keep paragraph bodies as single
/// long lines, so per-line preservation renders correctly without
/// hurting paragraph flow.
class _PerLineLicenseEntry extends LicenseEntry {
  _PerLineLicenseEntry(this.packages, this._text);

  @override
  final Iterable<String> packages;
  final String _text;

  @override
  Iterable<LicenseParagraph> get paragraphs sync* {
    for (final line in const LineSplitter().convert(_text)) {
      var leading = 0;
      while (leading < line.length && line[leading] == ' ') {
        leading++;
      }
      // LicenseParagraph indents are integer levels (0..8 roughly);
      // map every 2 leading spaces to one indent step so indented
      // numbered items / template snippets still look indented.
      final indent = (leading ~/ 2).clamp(0, 8);
      yield LicenseParagraph(line.substring(leading), indent);
    }
  }
}

// App theme settings - combines theme mode and accent color
class AppThemeSettings {
  final ThemeMode themeMode;
  final AccentColor accentColor;

  const AppThemeSettings({
    this.themeMode = ThemeMode.system,
    this.accentColor = AccentColor.blue,
  });

  AppThemeSettings copyWith({
    ThemeMode? themeMode,
    AccentColor? accentColor,
  }) {
    return AppThemeSettings(
      themeMode: themeMode ?? this.themeMode,
      accentColor: accentColor ?? this.accentColor,
    );
  }

  // For backward compatibility - convert to index for storage
  int toStorageIndex() {
    // Store as: themeMode * 10 + accentColor
    return themeMode.index * 10 + accentColor.index;
  }

  // Restore from storage index
  static AppThemeSettings fromStorageIndex(int index) {
    final themeModeIndex = index ~/ 10;
    final accentColorIndex = index % 10;
    return AppThemeSettings(
      themeMode: themeModeIndex < ThemeMode.values.length
          ? ThemeMode.values[themeModeIndex]
          : ThemeMode.system,
      accentColor: accentColorIndex < AccentColor.values.length
          ? AccentColor.values[accentColorIndex]
          : AccentColor.blue,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppThemeSettings &&
        other.themeMode == themeMode &&
        other.accentColor == accentColor;
  }

  @override
  int get hashCode => themeMode.hashCode ^ accentColor.hashCode;
}

// Legacy AppTheme enum for backward compatibility
enum AppTheme {
  lightBlue,    // Light mode with blue accent (default)
  darkBlue,     // Dark mode with blue accent
  lightGreen,   // Light mode with green accent
  darkGreen,    // Dark mode with green accent
  system,       // Follow system theme (blue accent)
}

// Convert legacy AppTheme to new AppThemeSettings
AppThemeSettings _legacyAppThemeToSettings(AppTheme appTheme) {
  switch (appTheme) {
    case AppTheme.lightBlue:
      return AppThemeSettings(themeMode: ThemeMode.light, accentColor: AccentColor.blue);
    case AppTheme.darkBlue:
      return AppThemeSettings(themeMode: ThemeMode.dark, accentColor: AccentColor.blue);
    case AppTheme.lightGreen:
      return AppThemeSettings(themeMode: ThemeMode.light, accentColor: AccentColor.green);
    case AppTheme.darkGreen:
      return AppThemeSettings(themeMode: ThemeMode.dark, accentColor: AccentColor.green);
    case AppTheme.system:
      return AppThemeSettings(themeMode: ThemeMode.system, accentColor: AccentColor.blue);
  }
}

// Get accent color from AccentColor enum
Color _accentColorToColor(AccentColor accentColor) {
  switch (accentColor) {
    case AccentColor.blue:
      return accentBlue;
    case AccentColor.green:
      return accentGreen;
    case AccentColor.purple:
      return accentPurple;
    case AccentColor.orange:
      return accentOrange;
    case AccentColor.red:
      return accentRed;
    case AccentColor.pink:
      return accentPink;
    case AccentColor.teal:
      return accentTeal;
    case AccentColor.yellow:
      return accentYellow;
  }
}

/// Recolor RGBA pixel buffer in-place for logo display.
/// Exported for testing.
void recolorLogoPixels(Uint8List pixels, AccentColor accentColor, {required bool isLight}) {
  final accent = _accentColorToColor(accentColor);
  final skipRecolor = accentColor == AccentColor.blue;

  for (int i = 0; i < pixels.length; i += 4) {
    final c0 = pixels[i];
    final c1 = pixels[i + 1];
    final c2 = pixels[i + 2];

    final cMin = min(c0, min(c1, c2));
    final cMax = max(c0, max(c1, c2));

    // Compute alpha: map background to transparent, content to opaque,
    // with smooth falloff in between to anti-alias edges cleanly.
    int alpha;
    if (isLight) {
      if (cMin >= 200) {
        alpha = 0;
      } else if (cMin <= 100) {
        alpha = 255;
      } else {
        alpha = 255 * (200 - cMin) ~/ 100;
      }
    } else {
      if (cMax <= 55) {
        alpha = 0;
      } else if (cMax >= 155) {
        alpha = 255;
      } else {
        alpha = 255 * (cMax - 55) ~/ 100;
      }
    }

    // Determine final RGB
    int r = c0, g = c1, b = c2;

    // Recolor blue pixels to accent (skip for blue accent)
    if (!skipRecolor && alpha > 0 && cMax - cMin > 40 && cMax > 60) {
      r = accent.red;
      g = accent.green;
      b = accent.blue;
    }

    // Premultiply: Skia/Impeller expect premultiplied RGBA
    if (alpha == 0) {
      pixels[i] = 0;
      pixels[i + 1] = 0;
      pixels[i + 2] = 0;
      pixels[i + 3] = 0;
    } else if (alpha < 255) {
      pixels[i] = (r * alpha) ~/ 255;
      pixels[i + 1] = (g * alpha) ~/ 255;
      pixels[i + 2] = (b * alpha) ~/ 255;
      pixels[i + 3] = alpha;
    } else {
      pixels[i] = r;
      pixels[i + 1] = g;
      pixels[i + 2] = b;
      pixels[i + 3] = 255;
    }
  }
}

/// Widget that displays the WebSpace logo tinted to the current accent color.
/// Processes icon pixels directly:
/// - Background (white in light / black in dark) → transparent
/// - Structural (black in light / white in dark) → kept as-is
/// - Colored (blue) → replaced with accent color
/// Results are cached per (accentColor, brightness) pair.
class AccentLogo extends StatefulWidget {
  final AccentColor accentColor;
  final double size;
  final Brightness brightness;

  const AccentLogo({
    super.key,
    required this.accentColor,
    required this.size,
    this.brightness = Brightness.light,
  });

  @override
  State<AccentLogo> createState() => _AccentLogoState();
}

class _AccentLogoState extends State<AccentLogo> {
  ui.Image? _image;
  static final Map<String, ui.Image> _cache = {};

  @override
  void initState() {
    super.initState();
    _loadAndProcess();
  }

  @override
  void didUpdateWidget(AccentLogo old) {
    super.didUpdateWidget(old);
    if (old.accentColor != widget.accentColor || old.brightness != widget.brightness) {
      _loadAndProcess();
    }
  }

  String get _cacheKey => '${widget.accentColor.name}_${widget.brightness.name}';

  Future<void> _loadAndProcess() async {
    final key = _cacheKey;
    // Capture widget properties before any awaits to avoid race conditions:
    // if the widget updates mid-flight, stale reads would corrupt the cache.
    final accentColor = widget.accentColor;
    final brightness = widget.brightness;

    if (_cache.containsKey(key)) {
      setState(() => _image = _cache[key]);
      return;
    }

    // Clear stale image while processing so we don't flash the old color
    if (_image != null) {
      setState(() => _image = null);
    }

    final asset = brightness == Brightness.dark
        ? 'assets/webspace_icon_dark.png'
        : 'assets/webspace_icon.png';
    final data = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    final src = frame.image;
    final byteData = await src.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return;

    final pixels = Uint8List.fromList(byteData.buffer.asUint8List());
    final isLight = brightness == Brightness.light;
    recolorLogoPixels(pixels, accentColor, isLight: isLight);

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels, src.width, src.height, ui.PixelFormat.rgba8888,
      (result) => completer.complete(result),
    );
    final processed = await completer.future;
    _cache[key] = processed;

    if (mounted && _cacheKey == key) {
      setState(() => _image = processed);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_image == null) {
      return SizedBox(width: widget.size, height: widget.size);
    }
    return RawImage(
      image: _image,
      width: widget.size,
      height: widget.size,
      filterQuality: FilterQuality.medium,
    );
  }
}

// Helper to convert ThemeMode to WebViewTheme
WebViewTheme _themeModeToWebViewTheme(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.dark:
      return WebViewTheme.dark;
    case ThemeMode.light:
      return WebViewTheme.light;
    case ThemeMode.system:
      return WebViewTheme.system;
  }
}

/// Test seam: when set, the page state uses this store instead of
/// constructing a [SecureWebViewStateStorage]. Lets integration tests
/// inject an in-memory store that survives a simulated restart (re-run of
/// [main]) without a platform keychain backend.
@visibleForTesting
WebViewStateStorage? debugWebViewStateStorageOverride;

/// Test seam: live reference to the current run's loaded site models, so
/// integration tests can reach a webview controller (URL, back/forward,
/// restore state) the widget tree doesn't otherwise expose.
@visibleForTesting
List<WebViewModel>? debugWebViewModels;

/// One-shot migration: copy file-import HTML out of [HtmlCacheService]
/// into [HtmlImportStorage] before the cache wipes itself on app
/// upgrade. Called from [HtmlCacheService.initialize] via the
/// `beforeUpgradeWipe` hook — at that point the cache's encryption is
/// initialized with the still-current key so [loadHtml] can decrypt.
///
/// On a fresh install the WebViewModels list is absent and this is a
/// no-op. On every subsequent upgrade once imports stop landing in the
/// cache (this version onward), the lookup finds nothing and returns
/// silently — keeping the call wired keeps the path safe against
/// future regressions without behavioral cost.
Future<void> _migrateFileImportsToStorage() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('webViewModels');
    if (raw == null || raw.isEmpty) return;

    var migrated = 0;
    for (final entry in raw) {
      try {
        final m = jsonDecode(entry) as Map<String, dynamic>;
        final initUrl = m['initUrl'] as String? ?? '';
        if (!initUrl.startsWith('file://')) continue;
        final siteId = m['siteId'] as String?;
        if (siteId == null || siteId.isEmpty) continue;

        if (await HtmlImportStorage.instance.hasImport(siteId)) continue;
        final cached = await HtmlCacheService.instance.loadHtml(siteId);
        if (cached == null) continue;
        await HtmlImportStorage.instance.saveHtml(siteId, cached.$2, cached.$1);
        migrated++;
      } catch (_) {
        // Skip malformed entries — the cache wipe is happening either way.
      }
    }
    if (migrated > 0) {
      LogService.instance.log('HtmlImport',
          'Migrated $migrated file-import page(s) from cache to import storage',
          level: LogLevel.info);
    }
  } catch (e) {
    LogService.instance.log('HtmlImport',
        'File-import migration failed: $e',
        level: LogLevel.error);
  }
}

/// Debug-only per-step timing for the cold-start critical path. Logs under
/// the 'Startup' tag; compiled out of release builds via kDebugMode. Steps in
/// the concurrent init group overlap and contend on the main isolate, so their
/// reported ms can sum to more than the group wall-clock — read them as
/// "which step is heaviest", not as additive. The serial-tail steps are
/// additive.
Future<void> _runTimed(String label, AsyncStep step) async {
  if (!kDebugMode) return step();
  final sw = Stopwatch()..start();
  try {
    await step();
  } finally {
    LogService.instance.log('Startup', '  $label: ${sw.elapsedMilliseconds}ms');
  }
}

void main([List<String> args = const []]) async {
  launchedForBackgroundWake = args.contains(kBackgroundWakeArg);
  WidgetsFlutterBinding.ensureInitialized();

  // Debug-only startup phase timing (see 'Startup' tag in the log screen /
  // console). Compiled out of release builds via kDebugMode.
  final swMain = kDebugMode ? (Stopwatch()..start()) : null;

  // Externally-driven test tiers (INTEG-011/012): a debug launch may
  // carry a seeded site list (Android intent extra, or WS_DIAG_SEED env
  // for a simctl driver); it must land in prefs before the page state
  // reads them.
  if (kDebugMode) {
    await DiagSeed.applyFromLaunch();
  }

  // Imported HTML files are the only copy of user-supplied content, so they
  // live in their own persistent store and survive upgrades. The HTML cache
  // (re-fetchable fetched-page snapshots, safe to drop on upgrade) must
  // initialize after the import store: its pre-wipe hook copies imports left
  // in the legacy cache (from versions before the import store existed) into
  // HtmlImportStorage before they're nuked.
  Future<void> htmlInit() async {
    await HtmlImportStorage.instance.initialize();
    await HtmlCacheService.instance.initialize(
      beforeUpgradeWipe: _migrateFileImportsToStorage,
    );
  }

  // Disable network loads from any service worker registered by a visited
  // site. Service workers stay alive across page navigations (tied to the
  // origin, not the document), and on Android System WebView there are open
  // chromium regressions where a SW's fetch-handler tasks race against
  // parent-page navigation and trip MiraclePtr's dangling-raw_ptr detector on
  // the IO thread. We never use service-worker functionality ourselves (no
  // offline pages, no push), so blocking SW network is no functional loss.
  Future<void> blockServiceWorkerNetwork() async {
    try {
      await inapp.ServiceWorkerController.setBlockNetworkLoads(true);
      await inapp.ServiceWorkerController.instance()
          .setServiceWorkerClient(null);
      LogService.instance.log('WebView',
          'Service worker network loads blocked at WebView layer');
    } catch (e) {
      LogService.instance.log('WebView',
          'Failed to block service worker network loads: $e',
          level: LogLevel.error);
    }
  }

  // Native interceptor bridge for sub-resource DNS + ABP blocking and LocalCDN
  // serving (Android). The Dart shouldInterceptRequest callback only fires for
  // main-document navigations on modern Chromium WebView, so everything
  // per-subresource goes through the native path. It's the bridgeSetup step:
  // ContentBlockerService.initialize feeds the engine from inside, so the
  // bridge must exist before the parallel group runs.
  //
  // The independent inits touch disjoint storage (each upgrade check keys off
  // its own version pref) and feed independent subsystems, so they overlap
  // rather than run serially. The adblock-rust engine spin-up
  // (ContentBlockerService) and the DNS/timezone dataset loads dominate
  // cold-launch latency; concurrency keeps them off the serial critical path
  // while still completing before runApp, so the fail-closed blocking posture
  // is unchanged. Timezone-polygon lookups are synchronous, so the per-site
  // shim builder needs that data ready before it runs (missing/empty cache is
  // fine — the "From picked location" option just stays disabled).
  final swServices = kDebugMode ? (Stopwatch()..start()) : null;
  await StartupInitEngine.runIndependentInits(
    <AsyncStep>[
      () => _runTimed('html', htmlInit),
      () => _runTimed('clearUrl', ClearUrlService.instance.initialize),
      () => _runTimed('dns', DnsBlockService.instance.initialize),
      () => _runTimed('firefoxUa', FirefoxUserAgentService.instance.initialize),
      () => _runTimed('adblock', ContentBlockerService.instance.initialize),
      () => _runTimed('localCdn', LocalCdnService.instance.initialize),
      () => _runTimed('searchList', SiteSearchListService.instance.initialize),
      () => _runTimed('blockStats', BlockStatsService.instance.initialize),
      if (hostIsAndroid)
        () => _runTimed('swBlock', blockServiceWorkerNetwork),
    ],
    bridgeSetup: WebInterceptNative.initialize,
  );
  if (swServices != null) {
    LogService.instance.log(
        'Startup', 'parallel service init: ${swServices.elapsedMilliseconds}ms');
  }

  // Opt-in weekly Firefox-version auto-refresh (DM-004). Fire-and-forget:
  // a network scrape must never sit on the startup path, and preset UAs
  // re-render from the cached version on the next webview build anyway.
  unawaited(FirefoxUserAgentService.instance.maybeAutoRefresh());

  if (DnsBlockService.instance.hasBlocklist) {
    await _runTimed(
        'dnsSend(${DnsBlockService.instance.domainCount})',
        () => WebInterceptNative.sendDnsLevelGroups(
            DnsBlockService.instance.levelGroups));
  }

  // Keep the DNS-side native domain push in sync when the DNS list
  // changes. (Android's native interceptor consumes the raw domains;
  // the iOS/macOS JS prefilter consumes the merged bloom below.)
  DnsBlockService.instance.addBlocklistChangedListener(() {
    WebInterceptNative.sendDnsLevelGroups(DnsBlockService.instance.levelGroups);
  });
  ContentBlockerService.instance.addRulesChangedListener(() {
    // Feed the ABP `||host^` block hosts into the merged prefilter Bloom
    // so the iOS/macOS interceptor trips for ABP-only hosts instead of
    // hard-allowing them on a bloom miss. Also invalidates the bloom.
    DnsBlockService.instance.setAbpNetworkHosts(
        ContentBlockerService.instance.abpNetworkBlockHosts);
  });
  // Seed the merged bloom with the ABP hosts harvested by the initial
  // engine build — that build ran during init, before the listener
  // above existed, so its rules-changed notification was not delivered.
  DnsBlockService.instance.setAbpNetworkHosts(
      ContentBlockerService.instance.abpNetworkBlockHosts);

  // Seed the native interceptor with CDN patterns + the current cache
  // index, and keep its copy in sync whenever the cache changes.
  await _runTimed(
      'cdnSend',
      () async {
        await WebInterceptNative.sendCdnPatterns(
            LocalCdnService.instance.cdnPatternStrings);
        await WebInterceptNative.sendCdnCacheIndex(
            LocalCdnService.instance.cacheIndexSnapshot);
      });
  LocalCdnService.instance.addCacheChangeListener(() {
    WebInterceptNative.sendCdnCacheIndex(
        LocalCdnService.instance.cacheIndexSnapshot);
  });

  // Register custom licenses. The list pairs a display name with the path
  // to a bundled license text under `assets/licenses/`; see that directory
  // for the originals. The pubspec asset glob pulls each `.txt` in.
  const customLicenses = <(List<String>, String)>[
    (['WebSpace Assets'], 'assets/LICENSE'),
    (['favicon (modified)'], 'assets/licenses/favicon.txt'),
    (['ClearURLs (rules data)'], 'assets/licenses/clearurls.txt'),
    (['Hagezi DNS Blocklists (domain data)'], 'assets/licenses/hagezi.txt'),
    (['EasyList filter lists (filter data)'], 'assets/licenses/easylist.txt'),
    (
      // uBO ships the redirect-resource bodies (noop.js, 1x1.gif,
      // neutered trackers, etc.) we embed at build time. uBO isn't
      // a Rust crate so the transitive-deps SPDX extractor below
      // can't reach it — the bundled file carries the MPL-2.0 text
      // for that contribution. The `adblock` and `webspace_adblock`
      // crates themselves flow through the transitive enumeration
      // with canonical SPDX text from the `license` crate.
      ['uBlock Origin web-accessible resources (redirect bodies)'],
      'assets/licenses/ubo_resources.txt'
    ),
    (['cdnjs (LocalCDN resource data)'], 'assets/licenses/cdnjs.txt'),
    (['OpenStreetMap (map data and tiles)'], 'assets/licenses/openstreetmap.txt'),
    (
      ['IPFire Location Database (Tor exit-country data)'],
      'assets/licenses/ipfire_location.txt'
    ),
    (['Kagi Bangs (site search list data)'], 'assets/licenses/kagi_bangs.txt'),
  ];
  for (final (packages, assetPath) in customLicenses) {
    LicenseRegistry.addLicense(() async* {
      final text = await rootBundle.loadString(assetPath);
      yield _PerLineLicenseEntry(packages, text);
    });
  }

  // Transitive Rust dependency attribution. Loaded from the
  // adblock_rust shared library's static metadata blob (see
  // rust/webspace_adblock/build.rs). Surfaces every crate
  // adblock-rust pulls in (regex, serde, flatbuffers, idna, …) with
  // its SPDX license + canonical SPDX text (sourced at build time
  // via the `license` crate's vendored license-list-data, NOT
  // hand-typed). Dual-licensed crates ship every relevant text.
  LicenseRegistry.addLicense(() async* {
    for (final dep in AdblockEngine.depLicenses()) {
      final name = dep['name'] as String? ?? '';
      if (name.isEmpty) continue;
      final version = dep['version'] as String? ?? '';
      final license = dep['license'] as String? ?? '<unspecified>';
      final repo = dep['repository'] as String? ?? '';
      final desc = dep['description'] as String? ?? '';
      final texts = (dep['license_texts'] as List? ?? const [])
          .cast<Map<String, dynamic>>();

      final parts = <String>[
        if (desc.isNotEmpty) desc,
        '',
        'Version: $version',
        'License: $license',
        if (repo.isNotEmpty) 'Source: $repo',
        if (repo.isEmpty) 'Source: https://crates.io/crates/$name',
      ];
      if (texts.isEmpty) {
        parts.add('');
        parts.add(
            'Canonical SPDX license text was not resolvable for "$license". '
            'See the upstream source above for the original.');
      } else {
        for (final lt in texts) {
          final id = lt['id'] as String? ?? '';
          final lname = lt['name'] as String? ?? id;
          final text = lt['text'] as String? ?? '';
          if (text.isEmpty) continue;
          parts.add('');
          parts.add('--- $lname (SPDX: $id) ---');
          parts.add('');
          parts.add(text);
        }
      }
      yield _PerLineLicenseEntry(
        ['$name (Rust crate, transitive via adblock-rust)'],
        parts.join('\n'),
      );
    }
  });

  // Initialize platform info to detect proxy support before UI loads
  await _runTimed('platformInfo', PlatformInfo.initialize);

  // Prime ConnectivityService.lastKnownOnline before the first webview
  // is constructed. The offline cached-HTML render path needs a sync
  // answer to decide between live URL and `initialData` at construction
  // time — without this the first webview always sees `null` and
  // defaults to live load even when the device is offline.
  await _runTimed(
      'connectivity', ConnectivityService.instance.primeLastKnownOnline);

  // HTML caches are NOT bulk-preloaded here anymore: that decrypted every
  // cached + imported page (e.g. a 9.7 MB notif import) before the first
  // frame, even when the launched site needs none of them. Instead each site's
  // page is decrypted on demand via `HtmlCacheService.preloadOne` /
  // `HtmlImportStorage.preloadOne` right before it enters `_sites.loaded`
  // (in `_setCurrentIndex` and the deferred notification-site load), so the
  // build's synchronous `getHtmlSync` still hits but only for sites that
  // actually build.

  // Load the global outbound proxy from SharedPreferences. Synchronous
  // callers (flutter_map TileProvider, per-site DEFAULT fallthrough) read
  // GlobalOutboundProxy.current after this.
  await _runTimed('proxyInit', GlobalOutboundProxy.initialize);
  // Before any site resolves a proxy: a site that uses a library entry that
  // has not loaded yet fails closed until it does.
  await _runTimed('proxyLibraryInit', ProxyLibrary.initialize);
  // Teach the outbound seams how to expand ProxyType.TOR. Until this is
  // installed every TOR request blocks rather than connecting directly,
  // which is the right failure but a useless one, so install it early —
  // before any site can build a webview or fetch a favicon.
  torProxyResolver = (tag) => TorService.instance.socksFor(
        siteId: tag == kTorAppGlobalTag ? null : tag,
      );
  // Hydrate user-approved TLS exceptions so a self-signed site the user
  // already trusted in a previous session loads without a prompt — and
  // so the Dart-side `HttpClient.badCertificateCallback` (favicon
  // probes, downloads, …) sees the same pinned set.
  await TrustedHostsService.instance.initialize();
  // Gate for diagnostic-only affordances; read directly by the menus rather
  // than plumbed, so it must be hydrated before the first frame.
  await DeveloperModeService.instance.initialize();
  // A process the OS started for a background task reports a lifecycle other
  // than resumed here, which is how the background log tells a cold wake from
  // a launch the user made.
  BackgroundLog.instance.record(
    'Lifecycle',
    'process started (app '
        '${WidgetsBinding.instance.lifecycleState?.name ?? 'state not reported yet'})',
  );
  await ExperimentalFeaturesService.instance.initialize();
  // Before anything touches TorService.instance, which picks its tor from
  // this on first use and on every runtimeChoiceChanged (TOR-025).
  await ExternalTorSettings.initialize();
  TorService.wantsExternal = () =>
      externalTorRunsHere &&
      ExperimentalFeaturesService.instance
          .isEnabled(ExperimentalFeature.externalTor);
  // Before any webview exists, and only here: a process runs one composition
  // mode, so the Experimental switch applies from the next launch (PAUSE-032).
  WebViewFactory.hybridComposition = !ExperimentalFeaturesService.instance
      .isEnabled(ExperimentalFeature.textureRendering);
  // Re-fetch favicons whose initial request died on
  // CERTIFICATE_VERIFY_FAILED once the user later approves the cert
  // via the webview trust prompt. Subscribes before any pin can fire,
  // so even an immediate trust on first launch is observed.
  wireFaviconTrustInvalidation();
  // One-shot reset: the initial release of the trust prompt
  // (commit 5ef1174) intercepted every TLS handshake on iOS/macOS
  // because the Dart handler short-circuited Apple Keychain
  // validation. Users ended up pinning leaf fingerprints for dozens
  // of valid public CA sites. Clear those pins once so the new
  // OS-default-first flow has a clean slate; legitimate self-signed
  // pins (the only ones a user would have wanted) get re-prompted on
  // next visit.
  {
    final prefs = await SharedPreferences.getInstance();
    const resetKey = 'trustedHostsResetForOsDefaultV1';
    if (!(prefs.getBool(resetKey) ?? false)) {
      await TrustedHostsService.instance.clear();
      await prefs.setBool(resetKey, true);
    }
  }
  if (swMain != null) {
    LogService.instance.log(
        'Startup', 'main() pre-runApp init: ${swMain.elapsedMilliseconds}ms');
  }
  runApp(WebSpaceApp());
}

class WebSpaceApp extends StatefulWidget {
  @override
  _WebSpaceAppState createState() => _WebSpaceAppState();
}

class _WebSpaceAppState extends State<WebSpaceApp> {
  AppThemeSettings _themeSettings = const AppThemeSettings();

  void _setThemeSettings(AppThemeSettings settings) {
    setState(() {
      _themeSettings = settings;
    });
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<String>(
        valueListenable: AppPref.appLocaleOverride.listenable,
        builder: (context, localeTag, _) => _buildApp(localeFromTag(localeTag)),
      );

  Widget _buildApp(Locale? locale) {
    final Color accentColor = _accentColorToColor(_themeSettings.accentColor);
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      // Lets every webview-hosting screen learn when an opaque route above it
      // pops, which re-attaches its platform view blank (PAUSE-024/BUG-001).
      navigatorObservers: [surfaceRouteObserver],
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      // Fall back to English for any device locale we don't ship, instead of
      // gen_l10n's default of supportedLocales.first (alphabetically 'af').
      localeListResolutionCallback: resolveSupportedLocale,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      theme: ThemeData(
        colorScheme: buildAccentColorScheme(accentColor, Brightness.light),
        scaffoldBackgroundColor: Color(0xFFFFFFFF),
      ),
      darkTheme: ThemeData(
        colorScheme: buildAccentColorScheme(accentColor, Brightness.dark),
        scaffoldBackgroundColor: Color(0xFF000000),
      ),
      themeMode: _themeSettings.themeMode,
      home: WebSpacePage(onThemeSettingsChanged: _setThemeSettings),
      debugShowCheckedModeBanner: false,
    );
  }
}

class WebSpacePage extends StatefulWidget {
  final Function(AppThemeSettings) onThemeSettingsChanged;

  WebSpacePage({required this.onThemeSettingsChanged});

  @override
  _WebSpacePageState createState() => _WebSpacePageState();
}

class _WebSpacePageState extends State<WebSpacePage>
    with WidgetsBindingObserver, RouteAware
    implements DeferredStartupHost, MediaPrompter {
  final SiteRuntime _sites = SiteRuntime();
  late final ShortcutController _shortcuts =
      ShortcutController(_sites, _PageHost(this), DialogShortcutPrompts(context));
  late final SurfaceRepaintController _surface = SurfaceRepaintController(
    _PageHost(this),
    repaints: hostIsAndroid,
    traceSuffix: '',
  );
  late final BackgroundSitesController _background =
      BackgroundSitesController(_sites, _PageHost(this));
  late final AppLifecycleController _lifecycle = AppLifecycleController(
    _sites,
    _PageHost(this),
    surface: _surface,
    shortcuts: _shortcuts,
    background: _background,
    cookies: _cookieManager,
  );
  late final SiteNetworkController _network = SiteNetworkController(
    _sites,
    _PageHost(this),
    residency: _ResidencyHost(this),
    background: _background,
    containers: _containerIsolation,
  );
  late final TabsController _tabs = TabsController(
    _sites,
    _PageHost(this),
    navStates: _stateStorage,
    residency: _ResidencyHost(this),
  );
  late final LinkController _links = LinkController(
    _sites,
    _PageHost(this),
    DialogLinkPrompts(context),
    tabs: _tabs,
  );
  late final ArchiveController _archives = ArchiveController(
    _sites,
    _PageHost(this),
    DialogArchivePrompts(context),
    containers: _containerIsolation,
    cookieStore: _cookieSecureStorage,
    proxyPasswords: _proxyPasswordStorage,
    navStates: _stateStorage,
  );
  AppThemeSettings _themeSettings = const AppThemeSettings();
  final CookieManager _cookieManager = CookieManager();
  final CookieSecureStorage _cookieSecureStorage = CookieSecureStorage();
  late final SiteListStore _siteStore = SiteListStore(
    cookies: _cookieSecureStorage,
    proxyPasswords: _proxyPasswordStorage,
  );
  final ProxyPasswordSecureStorage _proxyPasswordStorage =
      ProxyPasswordSecureStorage();
  late final CookieIsolationEngine _cookieIsolation = CookieIsolationEngine(
    cookieManager: _cookieManager,
    storage: _cookieSecureStorage,
  );
  late final ContainerIsolationEngine _containerIsolation =
      ContainerIsolationEngine(containerNative: ContainerNative.instance);

  /// Container-mode cookie manager. Non-null when `_sites.useContainers ==
  /// true`; null in legacy mode (the existing `_cookieManager` covers
  /// that path). Resolved alongside `_sites.useContainers` in
  /// `_restoreAppState` so the branches stay tied to the same
  /// runtime decision. The WebViewModel cookie-blocking path branches
  /// on `containerCookieManager != null`.
  late final ContainerCookieManager? _containerCookieManager;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Height of the page-load progress bar pinned to the AppBar's bottom
  /// edge. Reserved (as an empty strut) whenever a site is current, so the
  /// webview surface below doesn't shift by a few pixels every time a
  /// navigation starts or ends.

  final _backGuard = ReentryGuard();
  final _siteSettingsGuard = ReentryGuard();
  bool _isFindVisible = false;
  bool _isFullscreen = false; // Runtime fullscreen state (hides appBar, tabStrip, system UI)
  Timer? _revealedBarsHideTimer;
  /// When true, a full-screen opaque mask covers every webview so the
  /// OS task-switcher / recents snapshot doesn't capture archive-tier
  /// content (ARCH-009). Set on `inactive`/`paused` when at least one
  /// archive is open; cleared on `resumed`. Apps without an open
  /// archive get the normal screenshot as before — this is a purely
  /// additive guard.
  bool _maskBackground = false;
  // NAV-009: what the back gesture does at the start of a site's history.
  // Off by default — the gesture only walks webview history (issue #369);
  // turning it on opens the drawer there, and again to leave the app (#431).
  // Pinned off where the setting is not offered.
  BackAtHistoryStart get _backAtHistoryStart =>
      _backAtHistoryStartOffered && AppPref.backOpensMenu.value
          ? BackAtHistoryStart.openMenu
          : BackAtHistoryStart.ignore;
  bool get _backAtHistoryStartOffered => backAtHistoryStartConfigurable(
        isIOS: hostIsIOS,
        isMacOS: hostIsMacOS,
      );
  // True while the drawer showing is the one the back gesture itself opened.
  // Only that drawer escalates to leaving the app on the next gesture.
  bool _drawerOpenedByBackGesture = false;
  // Runtime-only: whether the tab-bar button has revealed the tab strip.
  // Reset on exiting fullscreen and on site switch; never persisted.
  bool _tabBarOverlayVisible = false;

  Completer<void>? _webspaceSwitchCompleter;

  // Drops concurrent `_handleMemoryPressure` invocations. The OS may
  // fire `didHaveMemoryPressure` repeatedly under sustained pressure;
  // the first handler runs to completion, then the next event picks up
  // the new state. Without this, in legacy (non-container) mode the
  // capture-then-dispose await window lets two handlers pick the same
  // victim and double-write its captured cookies to storage.
  final _memoryPressureGuard = ReentryGuard();
  int _selectWebspaceVersion = 0;

  // AES-encrypted on-disk storage for per-site `controller.saveState()`
  // bytes. The same encryption pattern as the HTML cache: a 256-bit
  // AES key in `FlutterSecureStorage`, per-site files under
  // `<docs>/webview_state/<siteId>.enc`. Bytes survive webspace
  // switches, LRU evictions, memory-pressure disposals, AND cold
  // starts (cleared on app-version upgrade alongside the key).
  //
  // Sites in [SiteLifecycleState.savedForRestore] have an entry here
  // keyed by siteId; re-activation reads it and pre-populates the
  // model's `_pendingRestoreState` so onControllerCreated can apply
  // it to the freshly-built controller.
  final WebViewStateStorage _stateStorage =
      debugWebViewStateStorageOverride ?? SecureWebViewStateStorage();

  // Trailing-edge debounce for navigation-driven state captures
  // (PAUSE-009): one saveState() IPC per navigation burst, fired after
  // the burst settles, so the on-disk back/forward stack stays fresh
  // for kill paths that never deliver `paused` (app-switcher
  // swipe-kill) and for background sites navigating while another site
  // is current.
  final ScreenCaptureGuard _screenCaptureGuard = ScreenCaptureGuard();
  final NavStateCaptureDebouncer _navStateDebouncer =
      NavStateCaptureDebouncer();

  // Configurable suggested sites
  List<SiteSuggestion> _suggestedSites = [];

  // Global user scripts (shared across all sites)
  List<UserScriptConfig> _globalUserScripts = [];

  // KIOSK-002: set when the current session entered via a home-shortcut tap
  // targeting a kiosk-mode site. While true the app shell hides all navigation
  // and configuration affordances (drawer, tab strip, app-bar actions, context
  // menus). Re-derived on every shortcut launch from the target's kioskMode, so
  // a normal launch (no shortcut) or a shortcut to a non-kiosk site clears it.
  bool _kioskLocked = false;

  @override
  void initState() {
    super.initState();
    debugWebViewModels = _sites.models;
    WebViewModel.siteLookup = _sites.byId;
    WidgetsBinding.instance.addObserver(this);
    AppPref.anyChange.addListener(_onAppPrefChanged);
    AppPref.tabStripInFullscreen.listenable.addListener(_onTabStripPrefChanged);
    AppPref.tabBarButton.listenable.addListener(_onTabStripPrefChanged);
    _restoreAppState();
    _shortcuts.refreshPinned();
    _shortcuts.probeAppIntents();
    _network.start();
    // Only Android's embedder implements the listener; elsewhere registering
    // it throws MissingPluginException.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      SystemChrome.setSystemUIChangeCallback(_onSystemUiChange);
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onAppPrefChanged() => _rebuild();

  void _onTabStripPrefChanged() {
    if (!AppPref.tabBarButton.value) _tabBarOverlayVisible = false;
    if (_isFullscreen) _applyFullscreenSystemUi();
  }

  /// Push the per-site settings screen for the site at [index].
  ///
  /// Three call sites want it: the two overflow menus, and the
  /// blocked-navigation interstitial, which has to reach the proxy row of
  /// the site it is covering (LEAK-010).
  Future<void> _openSiteSettings(int index) async {
    if (index < 0 || index >= _sites.models.length) return;
    await _siteSettingsGuard.run(() async {
      final model = _sites.models[index];
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => SettingsScreen(
            webViewModel: model,
            otherSites: _sites.models
                .where((m) => m.siteId != model.siteId)
                .toList(growable: false),
            routingTargets: _links.outboundCandidates(model)
                .where((m) => m.siteId != model.siteId)
                .toList(growable: false),
            useContainers: _sites.useContainers,
            notificationsBlockedBySite: _background.notificationsBlockedBy(model),
            globalUserScripts: _globalUserScripts,
            onGlobalUserScriptsChanged: (scripts) {
              _globalUserScripts = scripts;
              _saveGlobalUserScripts();
              _resetAllWebViews();
            },
            onScriptsChanged: _resetCurrentSiteWebView,
            onClearCookies: () => _clearSiteData(index),
            onSettingsSaved: _handlePerSiteSettingsSaved,
          ),
        ),
      );
      if (!mounted) return;
      await _commitSites(const SiteSettingsClosed());
    });
  }

  /// [_openSiteSettings] for the site [siteId] names, for call sites that
  /// carry the id rather than the index (the nested webview screen).
  Future<void> _openSiteSettingsById(String? siteId) async {
    if (siteId == null) return;
    final index = _sites.models.indexWhere((m) => m.siteId == siteId);
    if (index == -1) return;
    await _openSiteSettings(index);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) surfaceRouteObserver.subscribe(this, route);
  }

  /// An opaque route pushed over this page has popped and the webview is
  /// visible again. While it was covered the platform view was not composited,
  /// so Android detached its SurfaceView and re-attaches it here — blank, and
  /// through none of the other chokepoints: the site did not change
  /// (`_setCurrentIndex`), the controller was not recreated
  /// (`onControllerReady`), nothing navigated, and the app never left the
  /// foreground. See PAUSE-024 / BUG-001.
  @override
  void didPopNext() {
    _surface.nudge('route-return');
  }

  @override
  void dispose() {
    _background.dispose();
    _surface.dispose();
    _navStateDebouncer.dispose();
    _network.dispose();
    AppPref.anyChange.removeListener(_onAppPrefChanged);
    AppPref.tabStripInFullscreen.listenable
        .removeListener(_onTabStripPrefChanged);
    AppPref.tabBarButton.listenable.removeListener(_onTabStripPrefChanged);
    _revealedBarsHideTimer?.cancel();
    SystemChrome.setSystemUIChangeCallback(null);
    surfaceRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // A warm-start SurfaceView re-attach lands here, typically after the
    // resume's one-shot nudge drained (PAUSE-020 / BUG-001).
    _surface.metricsChanged();
  }

  @override
  void didChangeTextScaleFactor() => _lifecycle.textScaleChanged();

  @override
  void didHaveMemoryPressure() {
    // OS is signaling memory pressure. Trim one loaded site per
    // event so the system controls the curve — if pressure persists
    // the callback fires again and we evict the next victim. The
    // active site is hard-protected; sites in the active webspace
    // are soft-keep (evicted only after every other candidate).
    unawaited(_handleMemoryPressure());
  }

  Future<void> _handleMemoryPressure() async {
    // Drop concurrent invocations: if the OS fires repeatedly while
    // we're still applying the previous promotion's transition
    // (clearCache, or saveState+dispose), we'd otherwise pick the
    // same victim twice and re-apply the same transition.
    await _memoryPressureGuard.run(() async {
      // The active site and an in-flight activation's target are never
      // picked (PAUSE-006): disposing the soon-to-be-active webview would
      // silently wipe its state.
      final plan = _residencyPlan(const MemoryPressure());
      if (plan.isEmpty) return;
      if (!await _applyResidency(plan, isStale: () => !mounted)) return;
      if (plan.unloads.isNotEmpty) {
        // The pin in force follows the loaded sites (TOR-014). Left for the
        // next activation, the pin of a site evicted here was cleared at
        // whatever moment that came, often after a long suspension had cost
        // the control socket.
        _network.syncTorExitPin(<int>{?_sites.current, ..._sites.loaded});
      }
      setState(() {});

      // The pressure event itself — not our eviction — can blank the VISIBLE
      // site: iOS may jettison its frontmost WKWebView's content process, and
      // the Android hybrid-composition SurfaceView can drop its buffer under a
      // low-memory GL reclaim. The active site is hard-protected from eviction,
      // so neither the promotion above nor `_setCurrentIndex` runs against it —
      // it would otherwise stay blank until the next navigation. Probe + nudge
      // it here, covering both outcomes: a dead renderer (recreate) and a
      // live-but-unpainted surface (nudge). See PAUSE-019.
      final activeIdx = AppLifecycleEngine.activeLoadedIndex(
        currentIndex: _sites.current,
        siteCount: _sites.models.length,
        loadedIndices: _sites.loaded,
      );
      if (activeIdx != null) {
        await _lifecycle.probeRenderer(_sites.models[activeIdx],
            trigger: 'memory-pressure');
        if (!mounted) return;
        _surface.nudge('memory-pressure');
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Mask any visible archive content the moment focus leaves the app
    // (well before `paused`) so the OS snapshot for the task switcher
    // / recents preview never captures an archive-tier site. False
    // positives (popup dialog, app-switcher peek) cost a brief visual
    // overlay flash, not data — acceptable trade for the snapshot
    // guarantee. Armed only while an archive is open (ARCH-009).
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_archives.anyOpen && !_maskBackground) {
        setState(() => _maskBackground = true);
      }
    }
    if (state == AppLifecycleState.resumed && _maskBackground) {
      setState(() => _maskBackground = false);
    }
    _lifecycle.changed(state);
  }

  /// User asked for a repaint from the menu (PAUSE-028).
  ///
  /// Every other repaint trigger is a code path the app recognised as a
  /// surface (re)attach; BUG-001 recurs precisely when a path nobody
  /// enumerated reaches a blank surface, and the user is the only one who can
  /// see that it happened. Probe first so a dead renderer is rebuilt rather
  /// than nudged (the two blank classes look alike), then try the next
  /// mechanism. Android-only.
  void _repaintCurrentSurface() {
    final shown = _sites.shown;
    if (shown != null) {
      unawaited(_lifecycle.probeRenderer(shown, trigger: 'manual'));
    }
    final mechanism = _surface.nextManual();
    switch (mechanism) {
      case ManualRepaint.inset1 || ManualRepaint.inset16:
        _surface.nudge('manual');
      case ManualRepaint.unpaint:
        unawaited(_surface.holdUnpainted());
      case ManualRepaint.nativeInvalidate || ManualRepaint.nativeVisibility:
        unawaited(SurfaceDiagNative.nativeRepaint(
                mechanism.label.substring('native-'.length))
            .then((views) => LogService.instance.log('SurfaceDiag',
                'manual ${mechanism.label} reached ${views ?? 0} view(s)')));
      case ManualRepaint.recreate:
        _resetCurrentSiteWebView();
    }
  }

  /// LIR-011: open as a nested webview using the chosen site's settings.
  /// LIR-015: a routed outbound link opens the same way over [source], the
  /// site it came from. The ordering lives in [NestedOpenEngine].
  Future<void> _executeOpenNested(
    DispatchOpenNested a, {
    WebViewModel? source,
  }) async {
    final index =
        _sites.models.indexWhere((m) => m.siteId == a.siteId);
    if (index < 0) return;
    await NestedOpenEngine.run<WebViewModel>(
      _NestedOpenHost(this, fromTab: a.sourceIsParent && source != null),
      target: _sites.models[index],
      url: a.url,
      source: a.sourceIsParent ? source : null,
    );
  }

  /// The one place a nested screen opens for an existing site from this
  /// widget. Resolves the posture the way `WebViewModel.getWebView`'s own
  /// launches do, so a share, deep link or URL-bar submission carries the same
  /// per-site posture as a tapped link (NESTED-010).
  ///
  /// [opensFromTab] is false for a screen a share opened, which came from no
  /// tab and so has none to hand a link to (LIR-032).
  Future<void> _launchNestedForModel(
    WebViewModel model,
    String url, {
    bool opensFromTab = true,
  }) =>
      launchUrl(
        url,
        model.sitePosture(globalUserScripts: _globalUserScripts),
        opensFromTab: opensFromTab,
        homeTitle: model.name,
      );

  /// WEBSPACE-012 helper: switch the active webspace to "All" if [model]
  /// isn't a member of the current named webspace, with a snackbar.
  Future<void> _maybeSwitchToAllForSite(WebViewModel model, int index) async {
    if (_sites.selectedWebspaceId == null ||
        _sites.selectedWebspaceId == kAllWebspaceId) {
      return;
    }
    final ws = _sites.webspaces.firstWhere(
      (w) => w.id == _sites.selectedWebspaceId,
      orElse: () => _sites.webspaces.first,
    );
    if (ws.siteIndices.contains(index)) return;
    setState(() {
      _sites.selectedWebspaceId = kAllWebspaceId;
    });
    await _saveSelectedWebspaceId();
    _toast((loc) => loc.homeSwitchedToAllToOpen(model.getDisplayName()));
  }

  /// Adds [model] to the selected named webspace too, persists, and with
  /// [activate] puts it on screen. Pass false when the app, not the user,
  /// chose to create it: an unattended entry point must not put a stranger's
  /// page on screen.
  Future<void> _registerNewSite(WebViewModel model, {bool activate = true}) async {
    // Before the first build: initialHtml reads currentTheme to pick the dark
    // prelude for cached HTML (file:// imports especially, which never reload
    // to live), and the model defaults to WebViewTheme.light.
    await model.setTheme(_themeModeToWebViewTheme(_themeSettings.themeMode));
    await _commitSites(SiteAdded(model));
    if (!activate || !mounted) return;
    await _setCurrentIndex(_sites.models.indexOf(model));
    if (!mounted) return;
    setState(() {});
    await _saveCurrentIndex();
  }

  /// TAB-018: give every app-tier site without a container colour the least
  /// used one. Only app-tier sites count, so what the app-tier list stores
  /// never depends on an archive being open (ARCH-001).
  void _assignContainerColors() {
    final sites = [
      for (final m in _sites.models)
        if (!m.isArchiveTier) m,
    ];
    if (sites.every((m) => m.containerColor != null)) return;
    final given = ContainerColorEngine.assign(
      [for (final m in sites) m.containerColor],
      kContainerPaletteSize,
    );
    for (var i = 0; i < sites.length; i++) {
      sites[i].containerColor = given[i];
    }
  }

  /// The one way the set of sites changes, and what runs after any change to
  /// a site. The order is fixed; [SiteSetChange.effects] decides which steps
  /// run, never in what order.
  Future<void> _commitSites(SiteSetChange change) async {
    // Before anything moves. LIR-023: a deleted site's hosted tabs close
    // before its container goes. ARCH-010: open archives seal before an
    // import replaces the rows they were materialised into.
    switch (change) {
      case SiteRemoved(:final site):
        await _retireSite(site);
        if (!mounted) return;
      case SitesReplaced():
        await _archives.closeAll();
        if (!mounted) return;
      case SitesEdited() ||
            SiteSettingsSaved() ||
            SiteSettingsClosed() ||
            SitesLoaded() ||
            SiteAdded() ||
            SitesMoved() ||
            ArchiveOpened() ||
            ArchiveClosed() ||
            SiteArchived() ||
            SiteUnarchived():
        break;
    }
    final shownBefore = _sites.shown;
    final selectionBefore = _sites.selectedWebspaceId;
    _sites.apply(change);
    _rebuild();
    final effects = change.effects;
    // TAB-018: a site added since the last commit is drawn and written with
    // its colour.
    _assignContainerColors();
    if (effects.prunesReferences) {
      _links.pruneOutboundPreferences();
      _links.pruneSearchReferences();
    }
    if (effects.followsOpeners) {
      await _tabs.reconcileLinkTabs();
      if (!mounted) return;
    }
    if (effects.closesIneligibleTabs) {
      await _tabs.closeIneligibleHostedTabs();
      if (!mounted) return;
    }
    if (change case SiteArchived(:final site, :final into)) {
      await _archives.recordIn(site, into);
      if (!mounted) return;
    }
    if (shownBefore != null && !_sites.models.contains(shownBefore)) {
      await _setCurrentIndex(null);
      if (!mounted) return;
    }
    if (_sites.selectedWebspaceId != selectionBefore) {
      unawaited(_saveSelectedWebspaceId());
    }
    // Before the demo-mode bail in the writes: the refcount tracks runtime
    // intent, not persistence, and a demo session that pinned Tor up would
    // keep it up.
    await _network.syncTorHolders();
    unawaited(_network.refreshRoutes());
    if (effects.persists) await _persistSites();
    if (effects.savesWebspaces) await _saveWebspaces();
    if (effects.reschedulesBackground) {
      unawaited(_background.reschedule());
      unawaited(_background.updateAudioSession());
    }
    if (effects.sweepsOrphans) await _sweepOrphans();
  }

  Future<void> _persistSites() async {
    if (isDemoMode) return;
    await _siteStore.save(_sites.models);
    _shortcuts.syncSites();
    // Compile the per-site filter-list mask into the engine. Fire-and-forget:
    // it no-ops unless the mask actually moved, and a save must not wait on
    // an engine reparse.
    unawaited(ContentBlockerService.instance.setListMasks(_filterListMasks()));
  }

  /// Which sites switched each filter list off, by list id, keyed by the
  /// site's registrable host — the identity adblock-rust's `$domain=` scoping
  /// matches against. Archive-tier sites are excluded (ARCH-006): their mask
  /// would rewrite the shared engine cache blob, which must not vary with
  /// whether an archive is open.
  Map<String, Set<String>> _filterListMasks() {
    final masks = <String, Set<String>>{};
    for (final model in _sites.models) {
      final off = model.effectiveDisabledFilterLists;
      if (off.isEmpty) continue;
      final host = getNormalizedDomain(model.initUrl);
      if (host.isEmpty) continue;
      for (final id in off) {
        (masks[id] ??= <String>{}).add(host);
      }
    }
    return masks;
  }

  Future<void> _saveCurrentIndex() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('currentIndex', _sites.current == null ? 10000 : _sites.current!);
  }

  Future<void> _saveThemeSettings() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('themeSettings', _themeSettings.toStorageIndex());
  }

  /// Corner for the currently active site: its remembered per-site choice,
  /// falling back to the app-wide legacy bottom-corner default.
  TabBarCorner get _tabBarButtonCornerEffective {
    final index = _sites.current;
    TabBarCorner? corner;
    if (index != null && index < _sites.models.length) {
      corner = _sites.models[index].tabBarButtonCorner;
    }
    return corner ??
        (AppPref.tabBarButtonOnRight.value
            ? TabBarCorner.bottomRight
            : TabBarCorner.bottomLeft);
  }

  void _openLinkHandlingSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => LinkHandlingSettingsScreen(
          sites: List<WebViewModel>.from(_sites.models),
          onOpenSiteEditor: (site) {
            final idx = _sites.models.indexOf(site);
            if (idx >= 0) {
              Navigator.of(ctx).pop();
              unawaited(_editSite(idx));
            }
          },
          onManualDispatch: (uri) async {
            await _links.dispatchInbound(InboundUrl(uri));
          },
        ),
      ),
    );
  }

  Future<void> _saveGlobalUserScripts() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    final json = _globalUserScripts.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList('globalUserScripts', json);
  }

  Future<void> _loadGlobalUserScripts() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    final json = prefs.getStringList('globalUserScripts');
    if (json == null) return;
    final loaded = <UserScriptConfig>[];
    for (var i = 0; i < json.length; i++) {
      try {
        loaded.add(UserScriptConfig.fromJson(
          jsonDecode(json[i]) as Map<String, dynamic>,
        ));
      } catch (e) {
        LogService.instance.log(
          'Boot',
          'Skipped malformed global user script at index $i: $e',
          level: LogLevel.warning,
        );
      }
    }
    _globalUserScripts = loaded;
  }

  /// Migrate pre-opt-in data: older builds ran every enabled global script
  /// on every site. After switching to per-site opt-in, sites that haven't
  /// declared [WebViewModel.enabledGlobalScriptIds] would silently lose
  /// their global scripts. For each site with an empty opt-in set, opt it
  /// into all currently-defined globals once. A marker key prevents this
  /// running again after the user starts curating per-site opt-ins.
  Future<void> _migrateGlobalScriptOptIn() async {
    if (_globalUserScripts.isEmpty || _sites.models.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('globalUserScriptsOptInMigrated') == true) return;
    final allIds = _globalUserScripts.map((s) => s.id).toSet();
    for (final model in _sites.models) {
      if (model.enabledGlobalScriptIds.isEmpty) {
        model.enabledGlobalScriptIds = {...allIds};
      }
    }
    await prefs.setBool('globalUserScriptsOptInMigrated', true);
    await _commitSites(const SitesEdited());
  }

  /// Drop the cached HTML snapshot for a site so the next webview rebuild
  /// boots clean — but only when we're (likely) online. When offline the
  /// cached snapshot is the only content we can render, so preserve it
  /// until a live reload can overwrite it (via the `onHtmlLoaded` callback
  /// on the next successful `onLoadStop`).
  ///
  /// Synchronous in-memory eviction. Sync because callers like `_goHome`
  /// dispose the webview and trigger a rebuild in the same event-loop turn
  /// — `getHtmlSync(siteId)` runs during that rebuild's build phase, so an
  /// async eviction loses the race and the rebuilt webview boots with the
  /// stale snapshot anyway. The eviction also bumps the
  /// [HtmlCacheService] generation, so any `saveHtml` for the same siteId
  /// already in flight (e.g. the previous snapshot IPC
  /// resolving after dispose) is rejected at write time and cannot
  /// resurrect the stale bytes the call site just dropped.
  ///
  /// Online gate uses [ConnectivityService.lastKnownOnline] (primed at
  /// startup, refreshed by every probe). Treats unknown as online so
  /// post-startup callers get the eviction; the only cost of a wrong
  /// guess offline is losing the cached fallback for one rebuild —
  /// `controller.reload()` is itself online-gated in [WebViewFactory], so
  /// nothing tries to fetch a live page we can't reach.
  ///
  /// Disk file is left alone. The next live `saveHtml` overwrites it; if
  /// the app is killed before that fires, `preloadCache` reads it back at
  /// next launch and the cached-then-live rebuild path heals it on first
  /// webview load. Use [HtmlCacheService.deleteCache] when the disk file
  /// must also go (orphan cleanup, explicit site deletion).
  void _evictCacheIfOnline(String siteId) {
    if (ConnectivityService.instance.lastKnownOnline ?? true) {
      HtmlCacheService.instance.evictInMemory(siteId);
    }
  }

  /// Dispose the current site's webview so the next render recreates it
  /// with fresh [initialUserScripts] and [initialSettings]. Used after
  /// the user edits the script list or any per-site setting baked at
  /// webview creation time — UA, language, location/timezone, content
  /// blocker, etc. The native WKUserScript / Android UserScript objects
  /// are immutable post-creation, and so are the platform UA / desktop-
  /// mode flags; `controller.loadUrl` alone reloads the *page* but
  /// reuses those baked-in values, so e.g. a desktop UA set after the
  /// webview was created wouldn't activate the desktop_mode_shim.
  ///
  /// Also drops the cached HTML (online only): the snapshot was captured
  /// with the previous script set applied, so showing it on next load
  /// would render the pre-edit DOM before the new scripts re-run.
  void _resetCurrentSiteWebView() {
    if (_sites.current == null || _sites.current! >= _sites.models.length) return;
    _evictCacheIfOnline(_sites.models[_sites.current!].siteId);
    setState(() {
      _sites.models[_sites.current!].disposeWebView();
    });
  }

  /// Persist settings, then recreate the current site's webview so the
  /// updated UA / language / location / shim-relevant fields take effect
  /// through fresh `initialSettings` and `initialUserScripts`. Wired into
  /// [SettingsScreen]'s `onSettingsSaved`.
  Future<void> _handlePerSiteSettingsSaved() async {
    await _commitSites(const SiteSettingsSaved());
    if (!mounted) return;
    final model = _sites.shown;
    if (model != null && model.fullscreenMode) {
      _enterFullscreen();
    } else {
      _exitFullscreen();
    }
    if (model != null) {
      _resetCurrentSiteWebView();
    } else {
      setState(() {});
    }
  }

  /// Dispose every loaded webview. Used after global user script edits,
  /// which can affect any site that has opted in. Caches for sites that
  /// have any global opt-in are dropped (online only) for the same reason
  /// as [_resetCurrentSiteWebView].
  void _resetAllWebViews() {
    for (final model in _sites.models) {
      if (model.enabledGlobalScriptIds.isNotEmpty) {
        _evictCacheIfOnline(model.siteId);
      }
    }
    setState(() {
      for (final model in _sites.models) {
        model.disposeWebView();
      }
    });
  }

  Set<String> get _archivedSiteIds => {
        for (final m in _sites.models)
          if (m.isArchiveTier) m.siteId,
      };

  Future<void> _saveWebspaces() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();
    // Archive-tier collections and archived siteIds live in `_sites.webspaces`
    // for rendering while open but must not enter app-tier persistence
    // (the archive's own encrypted state carries them).
    List<String> webspacesJson = ArchiveMembershipEngine.persistable(
      _sites.webspaces,
      _archivedSiteIds,
    ).map((webspace) => jsonEncode(webspace.toJson())).toList();
    await prefs.setStringList('webspaces', webspacesJson);
  }

  Future<void> _saveSelectedWebspaceId() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (_sites.selectedWebspaceId != null) {
      await prefs.setString('selectedWebspaceId', _sites.selectedWebspaceId!);
    } else {
      await prefs.remove('selectedWebspaceId');
    }
  }

  /// Set the current index and mark it as loaded for lazy webview creation.
  /// This ensures only visited webviews are created, not all webviews at once.
  /// Also handles domain conflict detection for per-site cookie isolation.
  Future<void> _setCurrentIndex(int? index) async {
    final version = ++_sites.activationVersion;
    // Another site by any way leaves the Tabs sheet's way back behind
    // (TAB-019); a jump the sheet makes puts its own back once it lands.
    if (index != _sites.current) _tabs.forgetReturns();

    if (index == null || index < 0 || index >= _sites.models.length) {
      final leaving = _sites.current != null &&
              _sites.current! < _sites.models.length &&
              _sites.loaded.contains(_sites.current)
          ? _sites.models[_sites.current!]
          : null;
      // Going home is committed before the teardown below, never after it
      // (NAV-010): every step there is a native round-trip that can throw,
      // be superseded, or never answer at all, and each of those used to
      // abandon the whole call with `_sites.current` still on the site the
      // user asked to leave — a "back to webspaces" that silently did
      // nothing. Nothing in the teardown decides where we end up.
      _sites.current = index;
      _exitFullscreen();
      // Opportunistically capture state for the previously-active site so a
      // later cold start (or OS-killed-while-backgrounded scenario) can
      // re-hydrate its back/forward stack and form data on re-activation.
      // The webview stays loaded (pause-only, not disposed) so a
      // near-immediate return to the same site keeps its in-memory tab.
      // Bytes-only capture — `lifecycleState` stays `live` because the
      // webview is not actually disposed.
      if (leaving != null) await _quiesceOutgoingSite(leaving, version);
      return;
    }

    final target = _sites.models[index];

    LogService.instance.log(
      'CookieIsolation',
      'Switching to site $index: "${target.name}" (siteId: ${target.siteId})',
      sensitivity: LogSensitivity.sensitive,
    );
    LogService.instance.log(
      'CookieIsolation',
      'Target domain: ${getBaseDomain(target.initUrl)}',
      sensitivity: LogSensitivity.sensitive,
    );
    LogService.instance.log('CookieIsolation', 'Currently loaded indices: ${_sites.loaded}');

    // Mark this site as activation-in-flight so concurrent OS memory
    // pressure events can't pick it as a victim before _sites.current
    // is updated below — disposing the webview mid-activation would
    // silently wipe its state from under the user.
    _sites.activating = index;
    try {

    // Whenever the target is about to be built fresh (not already in
    // `_sites.loaded`), fetch any saved navigation state and hand it to
    // the model so the soon-to-be-built controller's onControllerCreated
    // handler can apply restoreState. This covers both in-session
    // re-activation of a `savedForRestore` site AND a cold start, where
    // every site loads from JSON at the default `resident` tier yet the
    // bytes persisted on the previous run (on navigation / backgrounding)
    // still sit on disk — that's the cross-restart back/forward restore.
    //
    // Skipped when the webview is already loaded (rebuild won't recreate
    // the controller, so a queued restore would be stale) and for sites
    // that never persist nav state — incognito (ephemeral) and
    // archive-tier (ARCH-006: state lives only in the slot ciphertext).
    if (!_sites.loaded.contains(index) && target.activeTabPersistsNavState) {
      final bytes = await _stateStorage.loadState(target.activeStateKey);
      if (version != _sites.activationVersion) return;
      if (bytes != null) {
        target.schedulePendingRestoreState(bytes);
        LogService.instance.log(
          'WebViewState',
          'Queued ${bytes.length} restore bytes for "${target.name}" '
              '(siteId: ${target.siteId})',
          sensitivity: LogSensitivity.sensitive,
        );
      }
    }
    // The about-to-be-resumed webview is back at the lowest tier; reset
    // regardless of how it got here (savedForRestore dispose, cacheCleared
    // promotion, or a fresh cold-start load).
    if (target.lifecycleState != SiteLifecycleState.resident) {
      target.lifecycleState = SiteLifecycleState.resident;
    }

    // The loaded sites the target pushes out and the residents that drop
    // their cache. Every rule and its order is SiteUnloadEngine.plan's.
    if (!await _applyResidency(_residencyPlan(Activating(index)),
        isStale: () => version != _sites.activationVersion)) {
      return;
    }

    // Repoint the shared-profile route before this site can issue a
    // request, not after: the identity is shared, so until this lands the
    // relay still holds the previous shared-profile site's upstream.
    if (_network.topology case RoutedProxy(:final sharesDefaultSession)
        when index >= 0 &&
            index < _sites.models.length &&
            sharesDefaultSession(_sites.models[index])) {
      await _network.refreshRoutes(activeIndex: index);
      if (version != _sites.activationVersion) return;
    }

    // Only once the disagreeing siblings are gone: SETCONF takes effect for
    // the whole runtime the moment it lands, so applying it first would
    // route their next request through the new country. Not awaited: the
    // target, if it uses Tor, is held behind the interstitial until the pin
    // lands, and a target that does not use Tor has no reason to wait on tor
    // at all.
    if (TorService.instance.isAvailable) {
      _network.syncTorExitPin(<int>{index, ..._sites.loaded});
    }

    // Pause the previously active webview to save resources. Nothing to do
    // when the user tapped the site they are already on — see the engine.
    final outgoing = SiteActivationEngine.outgoingSiteToQuiesce(
      currentIndex: _sites.current,
      targetIndex: index,
      siteCount: _sites.models.length,
      loadedIndices: _sites.loaded,
    );
    if (outgoing != null) {
      await _quiesceOutgoingSite(_sites.models[outgoing], version,
          captureState: false);
      if (version != _sites.activationVersion) return;
    }

    if (_sites.useContainers) {
      // Container path: ensure the named container is recorded.
      // Materialization happens lazily on the native side when the
      // WebView binds via `InAppWebViewSettings.containerId`.
      await _containerIsolation.ensureContainer(target.siteId);
      if (version != _sites.activationVersion) return;
    } else {
      // Legacy path: restore cookies for target site before loading
      await _restoreCookiesForSite(index);
      if (version != _sites.activationVersion) return;
    }

    // Validate index is still in bounds after async gaps
    if (index >= _sites.models.length) return;

    // Decrypt this site's cached/imported HTML into memory before it enters
    // _sites.loaded, so the build's synchronous getHtmlSync hits. Replaces the
    // cold-start bulk preload of every page (idempotent no-op for sites that
    // have no cached/imported HTML, e.g. a plain URL site).
    await _ensureSiteHtml(index);
    if (version != _sites.activationVersion) return;

    _sites.current = index;
    // Bump to end of insertion order so iteration over _sites.loaded is
    // least-recently-used first (consumed by the LRU eviction above).
    _sites.loaded.remove(index);
    _sites.loaded.add(index);

    // Resume the newly active webview
    await _sites.models[index].resumeWebView();

    // A site that sat offscreen while the OS reclaimed memory can come back
    // with a dead renderer (iOS content-process jettison whose termination
    // delegate never fired) or a blank surface (Android hybrid-composition).
    // Probe and recover so a shortcut tap or tab switch doesn't land on a
    // black/blank page. See PAUSE-013.
    unawaited(_lifecycle.probeRenderer(target, trigger: 'site-switch'));

    // Defensive sweep: pause every other loaded webview so background
    // sites don't run animations / GPS listeners / non-throttled
    // raf callbacks when the user isn't looking at them. Steady state
    // already has them paused (each becomes paused when it last lost
    // active status above), but a path that adds to _sites.loaded
    // without going through the previous-active pause would leave
    // it unpaused. pauseWebView() is idempotent.
    //
    // unawaited: subsequent activation logic (fullscreen, logging)
    // doesn't depend on these completing, and a page whose JS thread is
    // frozen may never answer at all. Race-wise the version guard inside
    // the teardown is what keeps a sweep still in flight from pausing the
    // site a newer activation has since resumed.
    //
    // (Per-instance pause() doesn't stop JavaScript — see
    // openspec/specs/webview-pause-lifecycle/spec.md. This is a
    // CPU/battery optimization, not RAM. The LRU cap and OS memory
    // pressure handler cover RAM.)
    final loadedSnapshot = _sites.loaded.toList();
    for (final i in loadedSnapshot) {
      if (i == index) continue;
      if (i < 0 || i >= _sites.models.length) continue;
      // Camera stop is dispatched before the pause (CAM-012) and covers the
      // sites pauseWebView() exempts — a notification or background-audio
      // site keeps its JS running, which is exactly where a forgotten capture
      // would survive. Bound to a local model: the steps run a microtask
      // later, by which point _sites.models may have been reindexed.
      final model = _sites.models[i];
      unawaited(_quiesceOutgoingSite(model, version, captureState: false));
    }

    // Auto-enter fullscreen if the site has fullscreenMode enabled
    if (target.fullscreenMode) {
      _enterFullscreen();
    } else {
      _exitFullscreen();
    }

    LogService.instance.log('CookieIsolation', 'After switch, loaded indices: ${_sites.loaded}', sensitivity: LogSensitivity.sensitive);
    // Force the just-activated Android platform-view surface to recomposite.
    // Bringing a webview onstage (tab tap, shortcut open, cold-start restore)
    // can re-attach the hybrid-composition SurfaceView blank: the page is alive
    // (JS runs, DOM serializes) but nothing paints and the native overscroll
    // gesture is dead, so pull-to-refresh can't recover it — only this relayout
    // can. _probeRendererAndRecover above only relayouts web content, not the
    // surface (see its doc), so it does not cover this. No-op off Android.
    //
    // Activating a site whose document is still in flight has the PAUSE-021
    // ordering on top of that: this nudge drains against a surface that has
    // nothing to show yet, and the commit lands afterwards. Latch it so
    // onLoadSettled repaints the committed document (PAUSE-025).
    if (target.isLoading) _surface.armCommitLatch();
    _surface.nudge('activate');
    // _sites.loaded may have changed (LRU eviction, conflict unload,
    // first-load of target), so re-evaluate the background refresh
    // schedule. No-op on non-iOS / non-Android.
    unawaited(_background.reschedule());
    // Same trigger for the iOS audio session: the first load of a
    // background-audio site must activate `.playback` before the user
    // starts playback in it.
    unawaited(_background.updateAudioSession());
    } finally {
      // Clear the in-flight marker only if we still own it; a newer
      // _setCurrentIndex caller will have already overwritten it with
      // its own target.
      if (_sites.activating == index) {
        _sites.activating = null;
      }
    }
  }

  /// Unloads the site at [index] (PAUSE-007, ISO-002); see
  /// [SiteUnloadEngine.unload].
  Future<void> _unloadSite(int index, UnloadReason reason) =>
      SiteUnloadEngine.unload(_ResidencyHost(this), index, reason);

  ResidencyPlan _residencyPlan(ResidencyEvent event) =>
      SiteUnloadEngine.plan(_ResidencyHost(this), event);

  /// False when [isStale] turned true partway; see [SiteUnloadEngine.apply].
  Future<bool> _applyResidency(
    ResidencyPlan plan, {
    required bool Function() isStale,
  }) =>
      SiteUnloadEngine.apply(_ResidencyHost(this), plan, isStale: isStale);

  /// Every navigation-state key that should survive a sweep, for the sites in
  /// [siteIds]. State is per tab, so a site contributes one key per tab it
  /// still has: closing a tab makes its file an orphan, and deleting a site
  /// makes all of them orphans. The engine that drives the sweep speaks in
  /// sites (it has no reason to know about tabs); expanding a site to its keys
  /// belongs here, where the models are.
  Set<String> _liveStateKeys(Set<String> siteIds) => <String>{
        for (final m in _sites.models)
          if (siteIds.contains(m.siteId))
            for (final t in m.tabs) m.stateKeyForTab(t.id),
      };

  /// Capture [model]'s navigation state to encrypted on-disk storage.
  /// Returns true if bytes were captured and persisted. No-op for
  /// incognito sites or when there's nothing to save.
  ///
  /// Does NOT mutate `model.lifecycleState` — callers that are
  /// disposing the webview should do that themselves (typically
  /// flipping to [SiteLifecycleState.savedForRestore]); callers that
  /// are *only* opportunistically persisting (go-home,
  /// app-background) should leave the state at [SiteLifecycleState.resident]
  /// since the webview is still in memory.
  Future<bool> _captureStateBytes(WebViewModel model) async {
    // Archive-tier (ARCH-006) and incognito sites never persist nav state,
    // and a hosted tab only when its host would keep it (LIR-022).
    if (!model.activeTabPersistsNavState) return false;
    // The key is the one the bytes belong to, read before the capture: a tab
    // switch or a container flip (LIR-034) landing while it runs would make
    // the key read afterwards name another tab or another identity, and these
    // bytes would be restored there.
    final tabId = model.activeTabId;
    final key = model.activeStateKey;
    final bytes = await model.captureNavigationState();
    if (bytes == null) return false;
    if (model.activeTabId != tabId || model.activeStateKey != key) {
      LogService.instance.log(
        'WebViewState',
        'Dropped a capture for "${model.name}": its tab changed meanwhile',
        sensitivity: LogSensitivity.sensitive,
      );
      return false;
    }
    await _stateStorage.saveState(key, bytes);
    LogService.instance.log(
      'WebViewState',
      'Captured ${bytes.length} bytes for "${model.name}" '
          '(state key: $key)',
      sensitivity: LogSensitivity.sensitive,
    );
    return true;
  }

  /// Quiesce the site the user is leaving — a site switch, or a return to the
  /// webspace list (which also captures nav state).
  ///
  /// Ordering is CAM-012 / BGAUDIO-009: on iOS the per-instance pause blocks
  /// the page's JS thread, so the camera stop and the media pause have to be
  /// dispatched before it or they sit queued behind it forever. That same
  /// freeze is why the engine bounds the sequence — a page an earlier pause
  /// left frozen never answers `evaluateJavascript` again, and the caller's
  /// own state change must not hang on it (NAV-010).
  Future<void> _quiesceOutgoingSite(
    WebViewModel model,
    int version, {
    bool captureState = true,
  }) async {
    final result = await SiteTeardownEngine.quiesceOutgoing(
      superseded: () => version != _sites.activationVersion,
      steps: [
        if (captureState)
          SiteTeardownStep('captureState', () => _captureStateBytes(model)),
        SiteTeardownStep('stopRealCapture', model.stopRealCapture),
        SiteTeardownStep('pauseMediaPlayback', model.pauseMediaPlayback),
        SiteTeardownStep('pauseWebView', model.pauseWebView),
      ],
    );
    if (result.isClean) return;
    LogService.instance.log(
      'WebView',
      'Teardown of "${model.name}" ran ${result.ran}'
          '${result.errors.isEmpty ? '' : ', failed ${result.errors}'}'
          '${result.stalledOn == null ? '' : ', stalled on ${result.stalledOn}'}'
          '${result.supersededBefore == null ? '' : ', superseded before ${result.supersededBefore}'}',
      level: result.stalledOn == null ? LogLevel.info : LogLevel.warning,
      sensitivity: LogSensitivity.sensitive,
    );
  }

  /// Capture state and flip the lifecycle to [SiteLifecycleState.savedForRestore].
  /// Used by dispose paths (LRU eviction, memory-pressure cascade,
  /// legacy webspace-switch unload) where the webview is about to be
  /// torn down.
  Future<void> _captureStateForRestore(WebViewModel model) async {
    final ok = await _captureStateBytes(model);
    if (ok) {
      model.lifecycleState = SiteLifecycleState.savedForRestore;
    }
  }

  /// Restores cookies for a site before activation. Delegates to the engine.
  Future<void> _restoreCookiesForSite(int index) async {
    final version = _sites.activationVersion;
    await _cookieIsolation.restoreCookiesForSite(
      index: index,
      models: _sites.models,
      loadedIndices: _sites.loaded,
      versionAtEntry: version,
      currentVersion: () => _sites.activationVersion,
    );
  }

  /// Shows a popup window for handling window.open() requests from webviews.
  /// Used for Cloudflare Turnstile challenges and other popup-based flows.
  Future<void> _showPopupWindow(int windowId, String url) async {
    if (!mounted) return;

    LogService.instance.log(
      'PopupWindow',
      'Opening popup window with id: $windowId, url: $url',
      sensitivity: LogSensitivity.sensitive,
    );

    final loc = AppLocalizations.of(context);
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return Dialog(
          insetPadding: EdgeInsets.all(16),
          child: Container(
            width: MediaQuery.of(dialogContext).size.width * 0.9,
            height: MediaQuery.of(dialogContext).size.height * 0.8,
            child: Column(
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(loc.homeVerificationTitle, style: TextStyle(fontWeight: FontWeight.bold)),
                      IconButton(
                        icon: Icon(Icons.close),
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: WebViewFactory.createPopupWebView(
                    windowId: windowId,
                    onCloseWindow: () {
                      if (Navigator.of(dialogContext).canPop()) {
                        Navigator.of(dialogContext).pop();
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    LogService.instance.log('PopupWindow', 'Popup window closed');
  }

  Future<void> _loadWebspaces() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? webspacesJson = prefs.getStringList('webspaces');

    if (webspacesJson != null) {
      final loadedWebspaces = <Webspace>[];
      for (var i = 0; i < webspacesJson.length; i++) {
        try {
          loadedWebspaces.add(Webspace.fromJson(jsonDecode(webspacesJson[i])));
        } catch (e) {
          LogService.instance.log(
            'Boot',
            'Skipped malformed webspace at index $i: $e',
            level: LogLevel.warning,
          );
        }
      }

      setState(() {
        _sites.webspaces.addAll(loadedWebspaces);
      });
    }

    // Ensure "All" webspace always exists
    _ensureAllWebspaceExists();

    _sites.selectedWebspaceId = prefs.getString('selectedWebspaceId');

    // If no webspace is selected, select "All" by default
    if (_sites.selectedWebspaceId == null) {
      _sites.selectedWebspaceId = kAllWebspaceId;
    }
  }

  void _ensureAllWebspaceExists() {
    // Check if "All" webspace already exists
    final hasAll = _sites.webspaces.any((ws) => ws.id == kAllWebspaceId);

    if (!hasAll) {
      setState(() {
        _sites.webspaces.insert(0, Webspace.all());
      });
    } else {
      // Ensure "All" is at the beginning
      final allIndex = _sites.webspaces.indexWhere((ws) => ws.id == kAllWebspaceId);
      if (allIndex > 0) {
        setState(() {
          final allWebspace = _sites.webspaces.removeAt(allIndex);
          _sites.webspaces.insert(0, allWebspace);
        });
      }
    }
  }

  Future<void> _restoreAppState() async {
    final activationVersionAtRestore = _sites.activationVersion;
    // Debug-only startup phase timing (compiled out of release via kDebugMode).
    final swRestore = kDebugMode ? (Stopwatch()..start()) : null;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    AppPref.loadAll(prefs);
    setState(() {
      // Load theme settings, with migration from old formats
      final savedThemeSettings = readPrefAs<int>(prefs, 'themeSettings');
      if (savedThemeSettings != null) {
        _themeSettings = AppThemeSettings.fromStorageIndex(savedThemeSettings);
      } else {
        // Try to migrate from old appTheme format
        final savedAppTheme = readPrefAs<int>(prefs, 'appTheme');
        if (savedAppTheme != null && savedAppTheme < AppTheme.values.length) {
          _themeSettings = _legacyAppThemeToSettings(AppTheme.values[savedAppTheme]);
        } else {
          // Migrate from old themeMode if exists
          final oldThemeMode = readPrefAs<int>(prefs, 'themeMode');
          if (oldThemeMode != null) {
            // Map old ThemeMode to new settings (assuming green was the old color)
            switch (oldThemeMode) {
              case 0: // ThemeMode.system
                _themeSettings = AppThemeSettings(themeMode: ThemeMode.system, accentColor: AccentColor.green);
                break;
              case 1: // ThemeMode.light
                _themeSettings = AppThemeSettings(themeMode: ThemeMode.light, accentColor: AccentColor.green);
                break;
              case 2: // ThemeMode.dark
                _themeSettings = AppThemeSettings(themeMode: ThemeMode.dark, accentColor: AccentColor.green);
                break;
              default:
                _themeSettings = const AppThemeSettings();
            }
          }
        }
      }
      _shortcuts.load(prefs);
      widget.onThemeSettingsChanged(_themeSettings);
    });
    await _loadWebspaces();
    await _loadGlobalUserScripts();
    // Before the sites are committed: whether hosted tabs can exist at all
    // depends on the engine (LIR-019), and the commit settles them. Every
    // path downstream branches on it synchronously. False on Android System
    // WebView without MULTI_PROFILE, iOS <17, macOS <14 and unsupported
    // platforms.
    _sites.useContainers = await ContainerNative.instance.isSupported();
    _containerCookieManager =
        _sites.useContainers ? ContainerCookieManager() : null;
    LogService.instance.log(
      'Container',
      _sites.useContainers
          ? 'Container API supported — using ContainerIsolationEngine + ContainerCookieManager'
          : 'Container API not supported — using CookieIsolationEngine + (legacy) CookieManager',
    );
    final (sites: restored, :needsResave) =
        await _siteStore.load(onChange: () => setState(() {}));
    if (swRestore != null) {
      LogService.instance.log('Startup',
          'load ${restored.length} site(s) + cookies: ${swRestore.elapsedMilliseconds}ms');
    }
    // Legacy positional membership resolves against the restored order,
    // before the commit rebuilds every webspace's positions from siteIds.
    if (promoteLegacySiteIndices(_sites.webspaces, restored)) {
      await _saveWebspaces();
    }
    // Sites restored with ProxyType.TOR need the runtime coming up before
    // their first navigation, or each opens on the bootstrap interstitial;
    // the commit's Tor sync does that.
    await _commitSites(SitesLoaded(restored));
    await _migrateGlobalScriptOptIn();
    _suggestedSites = await suggested_sites.getEffectiveSuggestedSites();

    await _network.activateRouter();

    // Startup GC. The container sweeps run here (before any WebView binds —
    // `deleteContainer` is only reliable in that unbound window). The
    // secure-storage / HTML / cookie-jar sweeps are pure housekeeping for
    // sites deleted in previous sessions, so they're deferred until after the
    // launched site has painted (see `_runDeferredStartupGc` below): the
    // activated site reads its cookies from its already-hydrated model (legacy
    // mode re-nukes + restores the jar inside `_restoreCookiesForSite`;
    // container mode reads from its own container), so none of those sweeps is
    // on the first-paint path.
    final activeSiteIdsAtStartup = _sites.models.map((m) => m.siteId).toSet();
    await _shortcuts.pruneAgainst(activeSiteIdsAtStartup);
    // Incognito sites are treated as orphans for any session-scoped GC
    // (cookies, html cache, navigation state, container) so on-disk
    // remnants don't outlive the process — see issue #298. Their config
    // (proxy passwords, imported HTML for file:// sites) stays put.
    final nonIncognitoSiteIds = {
      for (final m in _sites.models)
        if (!m.incognito) m.siteId,
    };
    // Sweep containers whose owning site no longer exists. Also
    // catches any leftover rev'd-name containers from the short-lived
    // `containerRev` workaround on this branch — the name won't match
    // any current siteId, so the set-membership check drops them.
    await _containerIsolation.garbageCollectOrphans(activeSiteIdsAtStartup);
    // Drop incognito containers before any WebView binds — `deleteContainer`
    // is reliable in this unbound window on every platform, and we want
    // the container directory gone (next bind materializes a fresh one)
    // so disk usage doesn't grow across sessions.
    final incognitoSiteIds =
        activeSiteIdsAtStartup.difference(nonIncognitoSiteIds);
    for (final siteId in incognitoSiteIds) {
      await _containerIsolation.onSiteDeleted(siteId);
    }
    // Left uninitialised in demo mode, which keeps the store memory-only
    // there.
    if (!isDemoMode) {
      unawaited(SiteIconStore.instance.initialize());
    }

    // Every launch starts on the webspace list unless a shortcut names a site.
    final indexToRestore = await _shortcuts.resolveColdLaunch();
    if (!mounted) return;

    // Notification sites auto-load so they poll and fire notifications without
    // the user opening them. In container mode this is deferred to AFTER the
    // launched site paints (below) so a large notif import doesn't block the
    // shortcut target. In legacy (non-container) mode they must load pre-paint
    // so `_setCurrentIndex`'s conflict-unload can arbitrate same-base-domain
    // collisions; preload each one's HTML so its first build's getHtmlSync hits.
    if (!_sites.useContainers && !launchedForBackgroundWake) {
      for (int i = 0; i < _sites.models.length; i++) {
        if (_sites.models[i].effectiveNotificationsEnabled) {
          await _ensureSiteHtml(i);
          // PAUSE-019: same pre-queue as the container-mode deferred
          // path — once in _sites.loaded the activation restore is
          // skipped, so the back/forward stack must be queued now.
          await queueNavStateRestore(_sites.models[i].siteId);
          _sites.loaded.add(i);
        }
      }
    }

    // Apply saved theme BEFORE _setCurrentIndex so the first build sees the
    // right currentTheme — initialHtml reads it to pick the dark prelude for
    // cached HTML (file:// imports especially, which never reload to live and
    // so paint with whatever prelude the first build chose). Models default to
    // WebViewTheme.light, so without this the first frame on a dark theme
    // flashes white before the controller is created and re-applies via
    // setController(). Only the models built this frame (launched site + any
    // auto-loaded notification sites) need it now; the rest are themed after
    // paint — their controllers aren't created until activated, and
    // setController re-applies the theme then.
    final webViewTheme = _themeModeToWebViewTheme(_themeSettings.themeMode);
    final preThemeIndices = <int>{
      ..._sites.loaded,
      ?indexToRestore,
    };
    for (final i in preThemeIndices) {
      if (i >= 0 && i < _sites.models.length) {
        await _sites.models[i].setTheme(webViewTheme);
      }
    }

    // Parity: a launched from-location site whose timezone hasn't been baked
    // into `spoofTimezone` yet (data saved before tz-baking existed) must still
    // spoof tz on this launch, matching the old resolve-at-build behavior. The
    // background `_refreshLocationTimezones` would only fix it next launch, so
    // resolve it synchronously here — but only for the launched site, only when
    // unbaked, so the polygon dataset stays off the path for everyone else.
    if (indexToRestore != null) {
      final m = _sites.models[indexToRestore];
      final unbaked = m.spoofTimezone == null || m.spoofTimezone!.isEmpty;
      if (unbaked &&
          derivesTimezoneFromLocation(
            spoofTimezoneFromLocation: m.spoofTimezoneFromLocation,
            trackingProtectionEnabled: m.trackingProtectionEnabled,
            spoofLatitude: m.spoofLatitude,
            spoofLongitude: m.spoofLongitude,
          )) {
        if (await TimezoneLocationService.instance.loadFromCacheIfPresent()) {
          final tz = TimezoneLocationService.instance
              .lookup(m.spoofLatitude!, m.spoofLongitude!);
          if (tz != null) m.spoofTimezone = tz;
        }
      }
    }

    // Set current index (async for cookie restoration)
    final swActivate = kDebugMode ? (Stopwatch()..start()) : null;
    if (StartupRestoreEngine.shouldActivateAfterRestore(
      indexToRestore: indexToRestore,
      activatedDuringRestore:
          _sites.activationVersion != activationVersionAtRestore,
    )) {
      await _setCurrentIndex(indexToRestore);
    }
    if (swActivate != null) {
      LogService.instance.log('Startup',
          'activate target site (_setCurrentIndex): ${swActivate.elapsedMilliseconds}ms');
    }
    if (!mounted) return;
    // indexToRestore is non-null only for a shortcut cold launch (see the
    // "only restore index if launched via shortcut" comment above), so apply
    // the FS-008 shortcut-launch fullscreen policy here.
    // KIOSK-003: a locked kiosk launch always goes fullscreen, overriding the
    // per-site / fullscreenOnShortcut policy.
    if (indexToRestore != null &&
        (_kioskLocked ||
            StartupRestoreEngine.shouldEnterFullscreen(
              viaShortcut: true,
              fullscreenOnShortcut: AppPref.fullscreenOnShortcut.value,
              perSiteFullscreenMode:
                  _sites.models[indexToRestore].fullscreenMode,
            ))) {
      _enterFullscreen();
    }
    setState(() {}); // Trigger UI update after async operation
    if (swRestore != null) {
      LogService.instance.log('Startup',
          'restore to first setState (total): ${swRestore.elapsedMilliseconds}ms');
    }

    // Container mode: auto-load notification sites now that the launched site
    // has painted — off the first-frame path. Each one's cached/imported HTML
    // is decrypted before it enters _sites.loaded so its build's getHtmlSync
    // hits; doing it here keeps a large notif import from blocking the shortcut
    // target's first paint. (Legacy mode already loaded them pre-paint above.)
    if (_sites.useContainers && !launchedForBackgroundWake) {
      unawaited(DeferredStartupEngine.autoLoadNotificationSites(this)
          .then((_) => _background.reschedule()));
    }

    // Off the first-paint path: theme the remaining (not-yet-built) models,
    // persist the load-time migration, and sweep orphan storage — all behind
    // the siteId-keyed DeferredStartupEngine so a post-paint add/delete can't
    // race it (see test/deferred_startup_engine_test.dart). The launched site
    // waits on none of it.
    final preThemeSiteIds = <String>{
      for (final i in preThemeIndices)
        if (i >= 0 && i < _sites.models.length) _sites.models[i].siteId,
    };
    unawaited(DeferredStartupEngine.runPostPaintMaintenance(
      this,
      alreadyThemedSiteIds: preThemeSiteIds,
      needsResave: needsResave,
    ));

    _shortcuts.promptParkedAfterFrame();

    // Refresh the iOS App Intents picker on every launch, not just on save.
    // iOS queries `suggestedEntities()` (and may re-materialize the per-site
    // App Shortcuts) whenever Shortcuts.app is touched; if the App Group was
    // never repopulated this session it can serve a stale single entry whose
    // bound target no longer matches its title. Re-syncing here also re-fires
    // `updateAppShortcutParameters()` so iOS re-reads the current site list.
    _shortcuts.syncSites();

    _background.startForegroundPoll();

    // Off the cold-start critical path. Neither gates the first frame or the
    // launched site: the image cache's upgrade-clear only matters on a version
    // bump, and the favicon URL cache is consulted progressively by the tab
    // strip / add-site UI (a miss just triggers a fresh fetch).
    unawaited(ImageCacheService.clearCacheOnUpgrade());
    unawaited(FaviconUrlCache.initialize());

    // Off the cold-start critical path: re-resolve the persisted timezone for
    // any from-location site (migrates sites saved before the tz was baked
    // into `spoofTimezone`, and refreshes after a dataset update). The dataset
    // load + parse happen on a background isolate after the first frame.
    unawaited(DeferredStartupEngine.refreshLocationTimezones(this));

    await _background.install();
    // Cold-start path for share intents; the resume handles the warm one.
    unawaited(_links.handleShareIntent());
  }

  /// Decrypt the cached/imported HTML for one site into memory before its
  /// webview builds, so the build's synchronous `getHtmlSync` hits. Uses the
  /// same [htmlSourceFor] classification as the build's `initialHtml` read, so
  /// the preload can never target a different store than the read (a blank
  /// site). Cheap no-op when the site has nothing on disk.
  Future<void> _ensureSiteHtml(int index) async {
    if (index < 0 || index >= _sites.models.length) return;
    await _ensureSiteHtmlForModel(_sites.models[index]);
  }

  /// Model-keyed variant — safe to call across `await`s in deferred loops where
  /// the index may shift (a site added/deleted while it runs), since it doesn't
  /// re-index `_sites.models`.
  Future<void> _ensureSiteHtmlForModel(WebViewModel m) async {
    switch (htmlSourceFor(
      incognito: m.incognito,
      isArchiveTier: m.isArchiveTier,
      initUrl: m.initUrl,
    )) {
      case HtmlSource.import:
        await HtmlImportStorage.instance.preloadOne(m.siteId);
      case HtmlSource.cache:
        await HtmlCacheService.instance.preloadOne(m.siteId);
      case HtmlSource.none:
        break;
    }
  }

  // ── DeferredStartupHost ──────────────────────────────────────────────────
  // Drives DeferredStartupEngine for the post-paint deferred init (notif
  // auto-load, timezone re-bake). Everything is addressed by siteId and the
  // siteId<->index translation happens fresh per call, so an add/delete while
  // the deferred work is awaiting can never make it act on a stale position.

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
  bool get isMounted => mounted;

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
    if (m != null) await _ensureSiteHtmlForModel(m);
  }

  @override
  Future<void> applyTheme(String siteId) async {
    final m = _sites.byId(siteId);
    if (m != null) {
      await m.setTheme(_themeModeToWebViewTheme(_themeSettings.themeMode));
    }
  }

  /// PAUSE-019: pre-queue the saved back/forward stack for a site that
  /// is about to enter `_sites.loaded` without going through
  /// `_setCurrentIndex` (auto-loaded notification sites). Once it's in
  /// the set, the activation path skips its restore fetch, so a queue
  /// here is the only chance the bytes get applied on this run.
  @override
  Future<void> queueNavStateRestore(String siteId) async {
    final model = _sites.byId(siteId);
    if (model == null) return;
    // A live controller can't consume queued bytes — restoreState only
    // applies to a freshly-created one.
    if (!model.activeTabPersistsNavState || model.controller != null) return;
    final bytes = await _stateStorage.loadState(model.activeStateKey);
    if (bytes == null) return;
    // Re-resolve after the disk read: the site may have been deleted.
    if (_sites.byId(siteId) == null) return;
    model.schedulePendingRestoreState(bytes);
    LogService.instance.log(
      'WebViewState',
      'Queued ${bytes.length} restore bytes for auto-loaded site '
          '"${model.name}" (siteId: $siteId)',
      sensitivity: LogSensitivity.sensitive,
    );
  }

  @override
  void requestRebuild() {
    if (mounted) setState(() {});
  }

  @override
  Future<bool> loadTimezoneDataset() =>
      TimezoneLocationService.instance.loadFromCacheIfPresent();

  @override
  String? resolveTimezone(double latitude, double longitude) =>
      TimezoneLocationService.instance.lookup(latitude, longitude);

  @override
  bool setSpoofTimezone(String siteId, String timezone) {
    final m = _sites.byId(siteId);
    if (m != null && m.spoofTimezone != timezone) {
      m.spoofTimezone = timezone;
      return true;
    }
    return false;
  }

  @override
  Future<void> persist() => _commitSites(const SitesEdited());

  @override
  Set<String> liveSiteIds() => {for (final m in _sites.models) m.siteId};

  @override
  Set<String> liveNonIncognitoSiteIds() =>
      {for (final m in _sites.models) if (!m.incognito) m.siteId};
  // ─────────────────────────────────────────────────────────────────────────

  /// Housekeeping sweep of storage left by sites deleted in previous sessions,
  /// deferred off the cold-launch first-paint path. The launched site never
  /// reads any of this — its cookies come from its hydrated model (legacy) or
  /// its own container — so running it after paint changes nothing the user
  /// sees, only when the disk reclaim happens. The live-set args are read fresh
  /// by the engine at sweep time so a site added post-paint isn't reclaimed.
  @override
  Future<void> sweepOrphanStorage(
    Set<String> activeSiteIds,
    Set<String> nonIncognitoSiteIds,
  ) async {
    try {
      await OrphanSweepEngine.sweep(
        targets: _OrphanSweepTargets(this),
        activeSiteIds: activeSiteIds,
        nonIncognitoSiteIds: nonIncognitoSiteIds,
        useContainers: _sites.useContainers,
        occasion: SweepOccasion.launch,
      );
      // Blocklist levels nothing asks for any more: a site that moved back
      // to the app-wide level leaves its tier behind, and each one is a
      // multi-megabyte file plus its share of the in-memory partition. Only
      // here, not on every model save — an unsaved per-site edit is not in
      // `_sites.models` yet, and pruning against it would delete the tier
      // the user just waited for.
      await DnsBlockService.instance.pruneLevels(requiredDnsLevels(
        globalLevel: DnsBlockService.instance.level,
        siteLevels: [for (final m in _sites.models) m.effectiveDnsBlockLevel],
      ));
    } catch (e) {
      LogService.instance.log(
        'Startup',
        'Deferred startup GC failed: $e',
        level: LogLevel.error,
      );
    }
  }

  /// Sweep after sites left the list while the app runs (delete, import).
  Future<void> _sweepOrphans() => OrphanSweepEngine.sweep(
        targets: _OrphanSweepTargets(this),
        activeSiteIds: liveSiteIds(),
        nonIncognitoSiteIds: liveNonIncognitoSiteIds(),
        useContainers: _sites.useContainers,
        occasion: SweepOccasion.sitesRemoved,
      );

  /// What this page answers for every site webview, root and nested.
  late final WebViewHostHooks _webViewHooks = WebViewHostHooks(
    cookieManager: _cookieManager,
    containerCookieManager: _containerCookieManager,
    globalUserScripts: () => _globalUserScripts,
    save: () => _commitSites(const SitesEdited()),
    rebuild: () {
      if (mounted) setState(() {});
    },
    onScreen: (slot) =>
        _sites.current != null &&
        _sites.current! < _sites.models.length &&
        identical(_sites.models[_sites.current!], slot),
    launchNested: launchUrl,
    routeOutbound: _links.routeOutbound,
    // Identity, not index: the list can have been reordered by the time the
    // native event lands.
    linkMenu: (source, url) {
      final at = _sites.models.indexOf(source);
      if (at >= 0) unawaited(_showLinkLongPressMenu(at, url));
    },
    openSiteSettings: _openSiteSettingsById,
    showPopup: _showPopupWindow,
    externalScheme: (info, loadIn) async {
      if (!mounted) return;
      await confirmAndLaunchExternalUrl(context, info, loadInWebView: loadIn);
    },
    confirmScriptFetch: _confirmScriptFetch,
    untrustedCertificate: _promptUntrustedCertificate,
    httpAuth: _promptHttpAuth,
    media: this,
  );

  Future<void> launchUrl(
    String url,
    SitePosture posture, {
    bool opensFromTab = true,
    String? homeTitle,
  }) async {
    // LIR-032: the screen opens over the tab on screen, and a link in it into
    // one of the user's sites goes back there as a tab. The tab opens once the
    // screen is gone, before whatever its opener runs on close.
    final owner = opensFromTab &&
            _sites.current != null &&
            _sites.current! < _sites.models.length
        ? _sites.models[_sites.current!]
        : null;
    final parentTabId = owner?.activeTabId;
    final openedFrom = owner?.runningIdentity.getDisplayName();
    final nestedSite = _sites.byId(posture.siteId);
    Future<void> Function()? handOff;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => InAppWebViewScreen(
          url: url,
          openedFrom: openedFrom,
          onOpenAsTab: owner == null || nestedSite == null
              ? null
              : (link, hadGesture) {
                  final tab = _links.tabRouteFor(owner, nestedSite, link, hadGesture);
                  if (tab == null) return false;
                  handOff = () => _links.executeTabRoute(
                      owner, nestedSite, parentTabId, tab, Uri.parse(link));
                  return true;
                },
          homeTitle: homeTitle,
          posture: posture,
          hooks: _webViewHooks,
          showUrlBar: AppPref.showUrlBar.value,
          onShowUrlBarChanged: AppPref.showUrlBar.set,
        ),
      ),
    );
    final run = handOff;
    if (run != null && mounted) await run();
  }

  /// Stable callback for the untrusted-TLS-certificate prompt. Used by
  /// both parent and nested webviews so a self-signed site looks the
  /// same regardless of where it was opened. Persistence (and pinning to
  /// the cert's SHA-256) happens inside [WebViewFactory] when this
  /// returns true — the dialog itself only collects user intent.
  Future<bool> _promptUntrustedCertificate(
    String host,
    int port,
    inapp.SslCertificate? certificate,
  ) {
    if (!mounted) return Future.value(false);
    return promptUntrustedCertificate(
      context,
      host: host,
      port: port,
      certificate: certificate,
    );
  }

  /// Stable callback for the HTTP authentication sign-in prompt, shared by
  /// parent and nested webviews (HTTPAUTH-003).
  Future<HttpAuthPromptResult?> _promptHttpAuth(HttpAuthPromptRequest request) {
    if (!mounted) return Future.value(null);
    return promptHttpAuth(context, request);
  }

  /// Stable callback for the user-script fetch-from-URL confirmation prompt.
  /// Used by both the parent webview (via `getWebView`) and the nested
  /// `InAppWebViewScreen` so external dependency loading prompts the user
  /// the same way regardless of where the webview was opened.
  Future<bool> _confirmScriptFetch(String url) async {
    if (!mounted) return false;
    final loc = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.homeLoadExternalScriptTitle),
        content: Text(loc.homeLoadExternalScriptBody(url)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.homeDenyAction),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.homeAllowAction),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Shown the first time a site requests `PROTECTED_MEDIA_ID` (e.g. the
  /// Spotify web player). The [GrantStore] remembers the answer, so this only
  /// collects user intent.
  @override
  Future<bool> protectedContent(String origin) async {
    if (!mounted) return false;
    final loc = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.homePlayProtectedContentTitle),
        content: Text(loc.homePlayProtectedContentBody(origin)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.homeBlockAction),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.homeAllowAction),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// The first request shows Block / Use a file / Allow (no Allow for a kind
  /// with no real mode); picking the file opens a picker and the chosen media
  /// becomes the site's virtual source. The [GrantStore] remembers the answer,
  /// so this only collects user intent. A site already set to `virtual` but
  /// missing a file skips the popup for the picker. A dismissed popup returns
  /// `ask`, so the request is denied once and the popup returns next time; a
  /// cancelled picker leaves the prior mode for the same reason. Android's
  /// app-level camera permission is handled at grant time by
  /// `CameraPermissionService`.
  @override
  Future<CaptureGrant<M, S>>
  capture<M extends CaptureMode, S extends VirtualSource>(
    CaptureKind<M, S> kind,
    String origin,
    M current,
  ) async {
    if (!mounted) return (mode: kind.block, source: null);
    if (current == kind.virtual) return _pickVirtualOrKeep(kind, current);
    final loc = AppLocalizations.of(context);
    final text = kind.text(loc);
    final real = kind.real;
    final choice = await showDialog<_MediaChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(text.promptTitle),
        content: Text(text.promptBody(origin)),
        actions: [
          for (final choice in _MediaChoice.values)
            if (choice != _MediaChoice.allow || real != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, choice),
                child: Text(switch (choice) {
                  _MediaChoice.block => loc.homeBlockAction,
                  _MediaChoice.useFile => text.useFile,
                  _MediaChoice.allow => loc.homeAllowAction,
                }),
              ),
        ],
      ),
    );
    return switch (choice) {
      _MediaChoice.allow => (mode: real ?? kind.block, source: null),
      _MediaChoice.useFile => await _pickVirtualOrKeep(kind, kind.ask),
      _MediaChoice.block => (mode: kind.block, source: null),
      null => (mode: kind.ask, source: null),
    };
  }

  /// Runs the picker. On success returns `virtual` with the source; on cancel
  /// or error returns [fallback] with no source, so the stored mode survives
  /// and the request is denied this once.
  Future<CaptureGrant<M, S>>
  _pickVirtualOrKeep<M extends CaptureMode, S extends VirtualSource>(
    CaptureKind<M, S> kind,
    M fallback,
  ) async {
    final result = await VirtualMediaPicker.pick(kind.medium);
    if (result.source case final source?) {
      return (mode: kind.virtual, source: source);
    }
    if (result.error case final error?) {
      _toast((loc) => kind.text(loc).pickError(error));
    }
    return (mode: fallback, source: null);
  }

  /// Shows a SnackBar. Built after the mounted check, so a caller past an
  /// await never reads a defunct context.
  void _toast(
    String Function(AppLocalizations loc) message, {
    Duration duration = const Duration(seconds: 4),
    bool floating = false,
    SnackBarAction Function(AppLocalizations loc)? action,
  }) {
    if (!mounted) return;
    final loc = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message(loc)),
      duration: duration,
      behavior: floating ? SnackBarBehavior.floating : null,
      action: action?.call(loc),
    ));
  }

  void _toastOpenedInNewTab(WebViewModel model, String tabId) => _toast(
        (loc) => loc.tabsOpenedInNewTab,
        action: (loc) => SnackBarAction(
          label: loc.tabsSwitchAction,
          // Sites may have moved or gone by the time this is tapped.
          onPressed: () {
            final at = _sites.models.indexOf(model);
            if (at >= 0) unawaited(_tabs.openTab(at, tabId));
          },
        ),
      );

  void _toggleFind() {
    setState(() {
      _isFindVisible = !_isFindVisible;
    });
  }

  void _enterFullscreen() {
    if (_isFullscreen) {
      // The mode depends on the kiosk lock and the tab strip prefs, which a
      // shortcut launch or an import can change while already full screen.
      _applyFullscreenSystemUi();
      return;
    }
    setState(() {
      _isFullscreen = true;
    });
    _applyFullscreenSystemUi();
    // Removing the app bar / changing the bottom bar resizes the webview; on
    // Android the hybrid-composition SurfaceView can come back with a 1px dark
    // seam at the bottom edge until it recomposites. github #421-followup
    _surface.nudge('fullscreen-toggle');
    // KIOSK-003: the hint promises an exit that a locked session won't honor.
    if (_kioskLocked) return;
    _toast((loc) => loc.homeExitFullscreenHint,
        duration: const Duration(seconds: 2), floating: true);
  }

  void _exitFullscreen() {
    // KIOSK-003: a locked kiosk session stays fullscreen; the only exit is to
    // relaunch the app normally (which clears the lock).
    if (_kioskLocked) return;
    if (!_isFullscreen) return;
    _revealedBarsHideTimer?.cancel();
    setState(() {
      _isFullscreen = false;
      _tabBarOverlayVisible = false;
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _surface.nudge('fullscreen-exit');
  }

  SystemUiMode get _fullscreenSystemUiMode => fullscreenSystemUiMode(
        tabStripInFullscreen: AppPref.tabStripInFullscreen.value,
        tabBarButton: AppPref.tabBarButton.value,
        kioskLocked: _kioskLocked,
      );

  void _applyFullscreenSystemUi() {
    SystemChrome.setEnabledSystemUIMode(_fullscreenSystemUiMode);
  }

  /// Under `immersive` (FS-011) a bar the user swipes in stays until the app
  /// hides it; the body and the tab strip inset around it meanwhile.
  Future<void> _onSystemUiChange(bool systemOverlaysAreVisible) async {
    _revealedBarsHideTimer?.cancel();
    if (!mounted || !_isFullscreen) return;
    if (_fullscreenSystemUiMode != SystemUiMode.immersive) return;
    _surface.nudge('system-bars');
    if (!systemOverlaysAreVisible) return;
    _revealedBarsHideTimer = Timer(kRevealedSystemBarsHideDelay, () {
      if (mounted && _isFullscreen) _applyFullscreenSystemUi();
    });
  }

  void _toggleFullscreen() {
    if (_isFullscreen) {
      _exitFullscreen();
    } else {
      _enterFullscreen();
    }
  }

  // Webspace management methods
  void _addWebspace() async {
    final webspace = Webspace(name: '');
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WebspaceDetailScreen(
          webspace: webspace,
          allSites: _sites.models,
          onSave: (updatedWebspace) {
            // The editor returns positional siteIndices; translate to
            // siteIds (the persisted source of truth) before storing.
            final selectedSiteIds = <String>[
              for (final i in updatedWebspace.siteIndices)
                if (i >= 0 && i < _sites.models.length)
                  _sites.models[i].siteId,
            ];
            setState(() {
              _sites.webspaces.add(updatedWebspace.copyWith(siteIds: selectedSiteIds));
              _sites.resolveWebspaceIndices();
            });
            _saveWebspaces();
          },
        ),
      ),
    );
  }

  void _editWebspace(Webspace webspace) async {
    // For "All" webspace, show all sites as selected but read-only.
    // The synthetic projection has to populate BOTH siteIds and
    // siteIndices so the editor's "selected" state matches.
    final webspaceToEdit = webspace.id == kAllWebspaceId
        ? Webspace(
            id: kAllWebspaceId,
            name: 'All',
            siteIds: [for (final m in _sites.models) m.siteId],
            siteIndices: List<int>.generate(_sites.models.length, (index) => index),
          )
        : webspace;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WebspaceDetailScreen(
          webspace: webspaceToEdit,
          allSites: _sites.models,
          isReadOnly: webspace.id == kAllWebspaceId,
          onSave: (updatedWebspace) {
            // Don't save changes for "All" webspace
            if (updatedWebspace.id == kAllWebspaceId) return;

            // Translate the editor's index-based selection back into
            // the siteId-keyed persisted membership.
            final selectedSiteIds = <String>[
              for (final i in updatedWebspace.siteIndices)
                if (i >= 0 && i < _sites.models.length)
                  _sites.models[i].siteId,
            ];
            setState(() {
              final index = _sites.webspaces.indexWhere((ws) => ws.id == updatedWebspace.id);
              if (index != -1) {
                _sites.webspaces[index] = updatedWebspace.copyWith(siteIds: selectedSiteIds);
                _sites.resolveWebspaceIndices();
              }
            });
            _saveWebspaces();
          },
        ),
      ),
    );
  }

  void _deleteWebspace(Webspace webspace) async {
    // Prevent deletion of "All" webspace
    final loc = AppLocalizations.of(context);
    if (webspace.id == kAllWebspaceId) {
      _toast((loc) => loc.homeCannotDeleteAllWebspace);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.homeDeleteWebspaceTitle),
        content: Text(loc.homeDeleteWebspaceConfirm(webspace.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.commonDelete),
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final wasSelected = _sites.selectedWebspaceId == webspace.id;
    setState(() {
      _sites.webspaces.removeWhere((ws) => ws.id == webspace.id);
      if (wasSelected) {
        _sites.selectedWebspaceId = kAllWebspaceId; // Select "All" instead of null
      }
    });
    if (wasSelected) {
      await _setCurrentIndex(null);
      if (!mounted) return;
    }
    await _saveWebspaces();
    await _saveSelectedWebspaceId();
    await _saveCurrentIndex();
  }

  void _selectWebspace(Webspace webspace) async {
    // If the same webspace is already selected, just open the drawer
    if (_sites.selectedWebspaceId == webspace.id) {
      _scaffoldKey.currentState?.openDrawer();
      return;
    }

    // Version counter guards against rapid taps: if another call arrives
    // while we are awaiting, the stale call will detect the version mismatch
    // and bail out instead of corrupting state.
    final version = ++_selectWebspaceVersion;

    // Signal that a webspace switch is in progress. Site selection (onTap)
    // awaits this so the unload finishes before any new site is loaded.
    final completer = Completer<void>();
    _webspaceSwitchCompleter = completer;

    try {
      // Get indices from the previous webspace before switching
      final previousIndices = _sites.filteredIndices().toSet();

      setState(() {
        _sites.selectedWebspaceId = webspace.id;
      });

      // Open drawer immediately so the user sees instant feedback on tap
      _scaffoldKey.currentState?.openDrawer();

      // Get indices in the new webspace
      final newIndices = _sites.filteredIndices().toSet();

      // Only unload sites when online - preserve live webviews when offline
      // so users can still view cached content
      final online = await ConnectivityService.instance.isOnline();
      if (!mounted || version != _selectWebspaceVersion) return;

      if (online) {
        final plan = _residencyPlan(WebspaceSwitched(
          previous: previousIndices,
          next: newIndices,
        ));
        if (!await _applyResidency(plan,
            isStale: () => !mounted || version != _selectWebspaceVersion)) {
          return;
        }
      } else {
        LogService.instance.log('WebspaceSwitch', 'Offline - preserving loaded webviews');
      }

      setState(() {}); // Update UI
      await _saveSelectedWebspaceId();
      await _saveCurrentIndex();
    } finally {
      completer.complete();
      if (_webspaceSwitchCompleter == completer) {
        _webspaceSwitchCompleter = null;
      }
    }
  }

  void _reorderWebspaces(int oldIndex, int newIndex) {
    // Don't allow reordering if "All" is involved (it stays at index 0)
    if (oldIndex == 0 || newIndex == 0) return;

    setState(() {
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      final webspace = _sites.webspaces.removeAt(oldIndex);
      _sites.webspaces.insert(newIndex, webspace);
    });
    _saveWebspaces();
  }

  // Export settings to a file
  Future<void> _exportSettings() async {
    final prefs = await SharedPreferences.getInstance();
    // The global proxy password is in secure storage, not in the prefs
    // value `readExportedAppPrefs` reads — and per PWD-005 we do NOT
    // re-inject it for export (same as secure cookies).
    // ARCH-010: exports never include archive-tier state, even when an
    // archive is open. Filter on `isArchiveTier` so the export bytes
    // match what a user with zero archives would produce.
    final appTierModels =
        _sites.models.where((m) => !m.isArchiveTier).toList();

    final extraSections = await _archives.sectionsForExport();
    if (!mounted) return;

    await SettingsBackupService.exportAndSave(
      context,
      webViewModels: appTierModels,
      webspaces: ArchiveMembershipEngine.persistable(
        _sites.webspaces,
        _archivedSiteIds,
      ),
      themeMode: _themeSettings.toStorageIndex(),
      globalPrefs: readExportedAppPrefs(prefs),
      selectedWebspaceId: _sites.selectedWebspaceId,
      currentIndex: _sites.current != null &&
              _sites.current! < appTierModels.length
          ? _sites.current
          : null,
      suggestedSites: _suggestedSites
          .map((s) => {'name': s.name, 'url': s.url, 'domain': s.domain})
          .toList(),
      globalUserScripts: _globalUserScripts.map((s) => s.toJson()).toList(),
      // User intent for the downloaded-data blockers: the chosen DNS
      // severity level and the content-blocker list selection. The blobs
      // themselves stay machine state; the user re-downloads after import.
      dnsBlockLevel: DnsBlockService.instance.level,
      contentBlockerLists: ContentBlockerService.instance.exportListSelection(),
      extraSections: extraSections,
    );
  }

  // Import settings from a file
  /// uBO trusts a site by switching all filtering off on it; the per-site
  /// content-blocker toggle is the equivalent here. Archive-tier sites are
  /// left alone (ARCH-006), and so are sites whose Tracking Protection
  /// would hold the blocker on regardless.
  Future<List<UboTrustedSite>> _trustUboHosts(Set<String> hosts,
      {required bool apply}) async {
    final matched = <WebViewModel>[];
    for (final m in _sites.models) {
      if (m.isArchiveTier || !m.contentBlockEnabled) continue;
      if (m.trackingProtectionEnabled) continue;
      final host = Uri.tryParse(m.initUrl)?.host ?? '';
      if (host.isNotEmpty && hostTrustedBy(host, hosts)) matched.add(m);
    }
    final result = [
      for (final m in matched)
        UboTrustedSite(m.getDisplayName(), Uri.parse(m.initUrl).host)
    ];
    if (apply && matched.isNotEmpty) {
      setState(() {
        for (final m in matched) {
          m.contentBlockEnabled = false;
          m.disposeWebView();
        }
      });
      await _commitSites(const SitesEdited());
    }
    return result;
  }

  Future<void> _importSettings() async {
    final backup = await SettingsBackupService.pickAndImport(context);
    if (backup == null) {
      return;
    }

    // Show confirmation dialog with backup info
    final sitesCount = backup.sites.length;
    final webspacesCount = backup.webspaces.length;
    final exportDate = backup.exportedAt.toLocal().toString().split('.')[0];

    final loc = AppLocalizations.of(context);
    final exportedLabel = loc.homeImportExportedLabel(exportDate);
    // State the backup installs that acts on its own once restored: the
    // app-wide proxy captures every DEFAULT site including webview traffic,
    // and a user script runs at document start with full page privileges.
    // Neither is visible in a site list, so the dialog has to name them.
    final incomingGlobalProxy = backupGlobalProxyAddress(backup);
    final incomingScriptCount = backupUserScriptCount(backup);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.homeImportSettingsTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(loc.homeImportSettingsConfirm(sitesCount, webspacesCount)),
              SizedBox(height: 12),
              Text(
                exportedLabel,
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (incomingGlobalProxy != null) ...[
                SizedBox(height: 12),
                Text(loc.homeImportGlobalProxyWarning(incomingGlobalProxy)),
              ],
              if (incomingScriptCount > 0) ...[
                SizedBox(height: 12),
                Text(loc.homeImportUserScriptsWarning(incomingScriptCount)),
              ],
              SizedBox(height: 16),
              Text(
                loc.homeImportSettingsSessionsNote,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.homeImportAction),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    // Decide the whole import BEFORE touching live state: a site entry that
    // does not parse throws here, and a malformed/hostile backup would
    // otherwise leave the user with their sites already cleared and the
    // restore half-done.
    final SettingsImportPlan plan;
    try {
      plan = planSettingsImport(backup, stateSetterF: () {
        setState(() {});
      });
    } catch (e) {
      LogService.instance.log(
        'Import',
        'Aborted import; live state left intact: $e',
        level: LogLevel.error,
      );
      _toast((loc) => loc.homeImportInvalidBackup);
      return;
    }

    // Applied and persisted in one step, before any site activates, so a pref
    // the backup does not name reads the same before and after a restart.
    // Per PWD-005 the backup carries no proxy password: the user re-enters
    // it on the proxy settings screen, as they re-log into sites whose secure
    // cookies were stripped.
    await writeExportedAppPrefs(
        await SharedPreferences.getInstance(), plan.appPrefs);
    if (!mounted) return;
    // Every service that reads those prefs reloads before the sites commit,
    // so the Tor refcount and a DEFAULT site's first load see the imported
    // app-wide proxy, not the one it replaces.
    await DeveloperModeService.instance.reload();
    await TorService.instance.externalAddressChanged();
    await TorService.instance.runtimeChoiceChanged();
    // The imported value is password-less; the in-memory proxy follows it
    // without an app restart.
    final reloadedPrefs = await SharedPreferences.getInstance();
    await GlobalOutboundProxy.update(readGlobalOutboundProxy(reloadedPrefs));
    await ProxyLibrary.reloadAfterImport();
    // The downloaded-data blockers' user intent: the selection only, never
    // the blob, which the user re-downloads from App Settings.
    if (plan.dnsBlockLevel != null) {
      await DnsBlockService.instance.applyImportedLevel(plan.dnsBlockLevel!);
    }
    if (plan.contentBlockerLists != null) {
      await ContentBlockerService.instance
          .importListSelection(plan.contentBlockerLists!);
    }
    if (!mounted) return;
    _themeSettings = AppThemeSettings.fromStorageIndex(plan.themeStorageIndex);
    await _commitSites(SitesReplaced(
      sites: plan.sites,
      webspaces: plan.webspaces,
      selectedWebspaceId: plan.selectedWebspaceId,
    ));
    if (!mounted) return;

    final indexToRestore = plan.currentIndex;
    // With no site activated, _setCurrentIndex never reaches
    // _restoreCookiesForSite, so the previously active site's cookies would
    // stay in the native jar. Legacy engine only: container-mode sites never
    // shared that jar, and an unscoped clear issued while live containers
    // exist is the shape BUG-007 turned into a wiped session.
    if (indexToRestore == null && !_sites.useContainers) {
      await _cookieManager.deleteAllCookies();
    }
    await _setCurrentIndex(indexToRestore);
    if (!mounted) return;
    setState(() {});
    widget.onThemeSettingsChanged(_themeSettings);

    final importedCounts = _background.counts();
    if (importedCounts.enabled > 0) {
      BackgroundLog.instance.record(
        'SiteUnload',
        'settings import: ${importedCounts.enabled} notification sites, '
            '${importedCounts.loaded} loaded until opened or the next launch',
        level: LogLevel.warning,
      );
    }
    await _saveThemeSettings();
    await _saveSelectedWebspaceId();
    await _saveCurrentIndex();

    if (plan.globalUserScripts != null) {
      _globalUserScripts = plan.globalUserScripts!;
    }
    await _saveGlobalUserScripts();

    if (plan.suggestedSites != null) {
      _suggestedSites = [
        for (final s in plan.suggestedSites!)
          SiteSuggestion(name: s.name, url: s.url, domain: s.domain),
      ];
      await suggested_sites.saveSuggestedSites(_suggestedSites);
    }

    // Apply theme to all webviews
    final webViewTheme = _themeModeToWebViewTheme(_themeSettings.themeMode);
    for (var webViewModel in _sites.models) {
      await webViewModel.setTheme(webViewTheme);
    }

    if (mounted) {
      final loc = AppLocalizations.of(context);
      final hints = <String>[
        if (plan.proxyPasswordsNeeded) loc.homeImportProxyPasswordsHint,
        if (plan.blocklistsNeedDownload) loc.homeImportBlocklistRedownloadHint,
      ];
      _toast(
        (loc) => hints.isEmpty
            ? loc.homeSettingsImportedSuccess
            : loc.homeSettingsImportedWithHints(hints.join(' ')),
        duration: Duration(seconds: hints.isEmpty ? 4 : 6),
      );
    }

    // If the backup carries encrypted sections, offer to restore them
    // by passphrase. Each prompt restores the section(s) matching the
    // entered passphrase; remaining ones can be restored by entering
    // another passphrase, or skipped by cancelling.
    if (plan.extraSections.isNotEmpty && mounted) {
      await _archives.restoreSections(plan.extraSections);
    }
  }

  WebViewController? getController() {
    if(_sites.current == null) {
      return null;
    }
    final model = _sites.models[_sites.current!];
    return model.getController(_webViewHooks);
  }

  void _openDrawerFromBackGesture(ScaffoldState? scaffoldState) {
    if (scaffoldState == null) return;
    _drawerOpenedByBackGesture = true;
    scaffoldState.openDrawer();
  }

  /// Resolve one back gesture: the Android system back button, or a pushable
  /// route's pop.
  Future<void> _handleBackGesture() async {
    await _backGuard.run(() async {
      final scaffoldState = _scaffoldKey.currentState;
      final drawerOpen = scaffoldState?.isDrawerOpen ?? false;
      final controller = getController();
      // Android's canGoBack() is reliable (including for pushState/SPA
      // entries on Chromium). Trust it directly: URL-comparison can
      // false-positive when goBack() succeeds but the navigation
      // hasn't propagated within the timeout. iOS/macOS decide from the
      // URL diff instead, so they don't sample it at all.
      final canGoBack = !drawerOpen && controller != null && hostIsAndroid
          ? await controller.canGoBack()
          : false;
      if (!mounted) return;
      final action = decideBackGesture(
        drawerOpen: drawerOpen,
        drawerOpenedByGesture: _drawerOpenedByBackGesture,
        drawerAvailable: !_kioskLocked,
        hasWebView: controller != null,
        trustsCanGoBack: hostIsAndroid,
        canGoBack: canGoBack,
        atHistoryStart: _backAtHistoryStart,
        canExitApp: hostIsAndroid,
      );
      // At the start of the page history the gesture is still spendable: a
      // tab the user opened from another tab closes and hands back to it
      // (TAB-007). Only then does NAV-001 / NAV-009 get the gesture.
      if ((action == BackGestureAction.ignore ||
              action == BackGestureAction.openDrawer) &&
          controller != null &&
          !drawerOpen) {
        if (await _tabs.backAtTabStart()) return;
        if (!mounted) return;
      }
      switch (action) {
        case BackGestureAction.ignore:
          LogService.instance.log('Navigation', 'Back gesture: nothing to do, ignoring');
          break;
        case BackGestureAction.closeDrawer:
          LogService.instance.log('Navigation', 'Back gesture: closing open drawer');
          _scaffoldKey.currentState?.closeDrawer();
          break;
        case BackGestureAction.closeDrawerAndExit:
          LogService.instance.log('Navigation', 'Back gesture: closing drawer and leaving app');
          _scaffoldKey.currentState?.closeDrawer();
          await SystemNavigator.pop();
          break;
        case BackGestureAction.openDrawer:
          LogService.instance.log('Navigation', 'Back gesture: no history, opening drawer');
          _openDrawerFromBackGesture(scaffoldState);
          break;
        case BackGestureAction.exitApp:
          LogService.instance.log('Navigation', 'Back gesture: no site shown, leaving app');
          await SystemNavigator.pop();
          break;
        case BackGestureAction.goBack:
          await _goBackAndRepaint(controller!);
          LogService.instance.log('Navigation', 'Back gesture: navigated back (canGoBack)');
          break;
        case BackGestureAction.attemptGoBack:
          // iOS/macOS: canGoBack() can return false for pushState
          // entries, so attempt goBack() unconditionally and use URL
          // comparison as the authoritative check.
          final urlBefore = (await controller!.getUrl())?.toString();
          await controller.goBack();
          // Give the native webview time to process the navigation
          await Future.delayed(const Duration(milliseconds: 150));
          if (!mounted) return;
          final urlAfter = (await controller.getUrl())?.toString();
          final urlChanged = urlBefore != urlAfter;
          LogService.instance.log(
            'Navigation',
            urlChanged
                ? 'Back gesture: navigated back from $urlBefore to $urlAfter'
                : 'Back gesture: URL unchanged ($urlAfter)',
            sensitivity: LogSensitivity.sensitive,
          );
          if (!urlChanged) {
            // Same rule as the Android branch above, reached the only way
            // Apple can reach it: the URL did not move, so the tab is at the
            // start of its own history.
            if (await _tabs.backAtTabStart()) return;
            if (!mounted) return;
          }
          final next = decideAfterAttemptedGoBack(
            urlChanged: urlChanged,
            drawerAvailable: !_kioskLocked,
            atHistoryStart: _backAtHistoryStart,
          );
          if (next == BackGestureAction.openDrawer) {
            LogService.instance.log('Navigation', 'Back gesture: no history, opening drawer');
            _openDrawerFromBackGesture(_scaffoldKey.currentState);
          }
          break;
      }
    });
  }

  /// Navigate the visible webview back one history entry, then recomposite the
  /// Android surface. A back/forward-cache restore re-attaches a fresh
  /// hybrid-composition SurfaceView that can come back blank-white, and back
  /// navigation passes through neither `_setCurrentIndex` nor `onControllerReady`
  /// (the existing nudge chokepoints), so it would otherwise stay uncovered.
  /// No-op off Android.
  Future<void> _goBackAndRepaint(WebViewController controller) async {
    await controller.goBack();
    _surface.nudge('back');
  }

  /// User-driven reload of the current site (Refresh button, Clear-cookies).
  /// Delegates to [WebViewModel.userDrivenReload] which drops the
  /// HtmlCacheService snapshot and the chromium HTTP cache before the
  /// reload, so the user actually gets fresh content instead of being
  /// served the same stale page from disk cache (issue #290).
  Future<void> _refreshCurrentSite() async {
    if (_sites.current == null || _sites.current! >= _sites.models.length) return;
    await _sites.models[_sites.current!].userDrivenReload();
  }

  /// User-driven full session wipe for a single site.
  ///
  /// Plan is computed by [SiteDataClearEngine.planClear]; this method
  /// is the executor. Container mode calls
  /// `ContainerIsolationEngine.clearForSite` (fork's
  /// `clearContainerData`, designed for live-bound containers) and
  /// disposes the cached widget so the next IndexedStack rebuild
  /// constructs a fresh InAppWebView against the now-empty container.
  /// Legacy mode falls back to in-model cookie deletion + reload (the
  /// most that can be scoped to a single site when localStorage / IDB
  /// / SW are app-global).
  Future<void> _clearSiteData(int index) async {
    if (index < 0 || index >= _sites.models.length) return;
    final model = _sites.models[index];
    final plan = SiteDataClearEngine.planClear(useContainers: _sites.useContainers);

    // Reroll the anti-fingerprinting seed so the post-wipe page can't be
    // re-identified via a stable fingerprint (window size, canvas, …) after
    // a data clear (ETP-022). The fresh nonce is baked into the shim when the
    // webview is rebuilt against the cleared container.
    model.rerollFingerprint();

    if (plan.disposeWebView) {
      _evictCacheIfOnline(model.siteId);
    }

    if (plan.clearContainer) {
      await _containerIsolation.clearForSite(model.siteId);
    }

    if (plan.disposeWebView || plan.clearInModelCookies) {
      setState(() {
        if (plan.disposeWebView) {
          model.disposeWebView();
          // LIR-023: a slot running as this site binds the cleared container.
          for (final other in _sites.models) {
            if (other.activeTab.hostSiteId == model.siteId) {
              other.disposeWebView();
            }
          }
        }
        if (plan.clearInModelCookies) {
          model.cookies = const [];
        }
      });
    }

    if (plan.deleteKnownCookies) {
      await model.deleteCookies(_cookieManager, _containerCookieManager);
    }
    // Restorable residue the container/cookie wipes don't reach, both engines:
    // the saved `controller.saveState()` bytes are replayed on the next
    // activation, so a page that stashed an identifier in its URL via
    // history.pushState would be reloaded at that URL and read itself back —
    // defeating the fingerprint reroll above (ETP-022). The encrypted HTML
    // snapshot is the same story for the page body.
    _navStateDebouncer.cancel(model.siteId);
    await _stateStorage.removeStatesForSite(model.siteId);
    await HtmlCacheService.instance.deleteCache(model.siteId);
    await _commitSites(const SitesEdited());
    if (!mounted) return;
    if (plan.userDrivenReload) {
      await _refreshCurrentSite();
    }
  }

  Future<void> _stopCurrentSiteLoading() async {
    if (_sites.current == null || _sites.current! >= _sites.models.length) return;
    await _sites.models[_sites.current!].userStopLoading();
  }

  /// Navigate to the site's initial URL and clear navigation history.
  /// Disposes the webview so it's recreated fresh with no back history.
  /// Evicts the in-memory HTML cache snapshot (online only) so the
  /// rebuilt webview boots clean and goes straight to the live home URL
  /// rather than flashing a stale cached frame. Offline: the cache is
  /// preserved — it's the only content we can render without network.
  /// Reset every "Always open Home" / incognito site that shares a named
  /// webspace with [launchedIndex] back to its `initUrl` and tear down its
  /// live webview so the next paint reloads at home. Called from both the
  /// cold and warm shortcut entrypoints — on cold launch most flagged
  /// sites already had `currentUrl` dropped during `fromJson`, so the
  /// pass is mostly a no-op there; on warm launch it is the only thing
  /// that resets siblings.
  ///
  /// A site with tabs is not sent home in place: it lands on a tab at home,
  /// and the tab it was on stays in its list (TAB-014).
  Future<void> _resetAlwaysOpenHomeOnShortcut(int launchedIndex) async {
    final indices = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
      launchedIndex: launchedIndex,
      webspaces: _sites.webspaces,
      flag: (i) {
        if (i < 0 || i >= _sites.models.length) return false;
        final m = _sites.models[i];
        return m.alwaysOpenHome || m.incognito;
      },
    );
    final withTabs = [
      for (final i in indices)
        if (_tabs.enabledAt(i)) _sites.models[i],
    ];
    for (final i in indices) {
      final m = _sites.models[i];
      if (withTabs.contains(m)) continue;
      if (m.currentUrl == m.initUrl && m.webview == null) continue;
      _evictCacheIfOnline(m.siteId);
      await _tabs.bindOwnerRunTab(m);
      if (!mounted) return;
      m.currentUrl = m.initUrl;
      // Keep the active site in _sites.loaded (mirrors
      // _resetAlwaysOpenHomeForAppClose / _goHome) so the IndexedStack still
      // has a child to rebuild at initUrl. Dropping it black-screens a warm
      // shortcut re-tap of the already-current site: _openShortcutIndex skips
      // _setCurrentIndex when index == _sites.current, so nothing would re-add
      // it or recreate the disposed webview.
      if (i == _sites.current) {
        m.disposeWebView();
      } else {
        await _unloadSite(i, UnloadReason.homeReset);
        if (!mounted) return;
      }
    }
    for (final m in withTabs) {
      if (!mounted) return;
      await _tabs.landOnHomeTab(m);
    }
  }

  /// Every site with tabs: the current webspace's in the order the drawer
  /// shows them, then the rest, whose trees can hold tabs that run as a site
  /// the webspace shows (TAB-017). A site without tabs is left out, so its
  /// stored ones cannot be opened from another site's list.
  List<TabsSheetSite> _tabsSheetSites() {
    final view = _sites.filteredIndices();
    final shown = view.toSet();
    TabsSheetSite site(int i) => TabsSheetSite(
          index: i,
          model: _sites.models[i],
          isCurrent: i == _sites.current,
          isLoaded: _sites.loaded.contains(i),
          inView: shown.contains(i),
        );
    return [
      for (final i in view)
        if (_tabs.enabledAt(i)) site(i),
      for (var i = 0; i < _sites.models.length; i++)
        if (!shown.contains(i) && _tabs.enabledAt(i)) site(i),
    ];
  }

  /// A sheet opened while the keyboard is up sits behind it, and the
  /// keyboard stays up while the URL bar or an input in the page has focus.
  Future<void> _dismissKeyboard() async {
    FocusManager.instance.primaryFocus?.unfocus();
    // A page that is stuck must not keep the list from opening.
    await getController()
        ?.evaluateJavascript(
            'document.activeElement && document.activeElement.blur && '
            'document.activeElement.blur();')
        .timeout(const Duration(milliseconds: 300), onTimeout: () {});
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  Future<void> _showTabsSheet() async {
    if (_kioskLocked || !_tabs.enabledAt(_sites.current) || _isShowingTabsSheet) {
      return;
    }
    _isShowingTabsSheet = true;
    try {
      await _dismissKeyboard();
      if (!mounted || !_tabs.enabledAt(_sites.current)) return;
      await _presentTabsSheet();
    } finally {
      _isShowingTabsSheet = false;
    }
  }

  bool _isShowingTabsSheet = false;

  Future<void> _presentTabsSheet() async {
    final sites = _tabsSheetSites();
    final at = sites.indexWhere((s) => s.index == _sites.current);
    if (at < 0) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => TabsSheet(
        sites: sites,
        currentIndex: at,
        onOpenTab: (i, id) => unawaited(_tabs.openTab(i, id)),
        onNewTab: (i) => unawaited(_tabs.newTab(i)),
        onWebSearch: () => unawaited(_links.webSearch()),
        onCloseTab: (i, id) => unawaited(_tabs.closeTab(i, id)),
        onCloseSubtree: (i, id) => unawaited(_tabs.closeTab(i, id, subtree: true)),
        onMoveTab: _tabs.moveTab,
        onMoveSite: _canReorderCurrentView ? _moveSiteInTabsSheet : null,
        wayBack: _tabs.wayBackFrom(_sites.models[_sites.current!]),
      ),
    );
  }

  /// A site heading dropped on another in the Tabs sheet (TAB-016): the same
  /// reorder the drawer grid and the tab strip make. Returns the sheet's sites
  /// afresh, since reordering "All" renumbers them.
  List<TabsSheetSite>? _moveSiteInTabsSheet(String siteId, String ontoSiteId) {
    if (_tabs.busy || !_canReorderCurrentView) return null;
    final order = _sites.filteredIndices();
    int at(String id) => order.indexWhere((i) =>
        i >= 0 && i < _sites.models.length && _sites.models[i].siteId == id);
    final from = at(siteId);
    final to = at(ontoSiteId);
    if (from < 0 || to < 0 || from == to) return null;
    _reorderSite(from, to);
    return _tabsSheetSites();
  }

  /// A long press that landed on a link. In-domain links can become a tab of
  /// this site; anything else keeps today's behaviour, and the sheet says why
  /// rather than silently offering nothing.
  Future<void> _showLinkLongPressMenu(int index, String url) async {
    if (_kioskLocked || !_tabs.enabledAt(index)) return;
    if (index < 0 || index >= _sites.models.length) return;
    if (index != _sites.current) return;
    final model = _sites.models[index];
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final identity = model.runningIdentity;
    final inDomain =
        getNormalizedDomain(url) == getNormalizedDomain(model.navigationHomeUrl);
    // A link into another of the user's sites becomes that site's tab, as a
    // tap would open it (LIR-032).
    final tabRoute = inDomain ? null : _links.tabRouteFor(model, identity, url, true);
    final tabHost = switch (tabRoute) {
      DispatchOpenInTab(:final siteId) => _sites.byId(siteId),
      _ => null,
    };
    final loc = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                url,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
            ListTile(
              enabled: inDomain || tabRoute != null,
              leading: const Icon(Icons.tab),
              title: Text(loc.tabsOpenInNewTab),
              subtitle: inDomain
                  ? null
                  : tabHost != null
                      ? Text(loc.tabsRunsAs(tabHost.getDisplayName()))
                      : tabRoute == null
                          ? Text(loc.tabsLinkOutsideSite(uri.host))
                          : null,
              onTap: () {
                Navigator.of(ctx).pop();
                if (tabRoute is DispatchShowPicker) {
                  unawaited(_links.showOutboundPicker(
                      model, identity, tabRoute, uri, parked: true));
                } else if (inDomain) {
                  // A sibling of the tab on screen: same container, and when
                  // that tab follows an opener's switch (LIR-034), so does it.
                  final active = model.activeTab;
                  unawaited(_tabs.openLinkInNewTab(index, url,
                      hostSiteId: active.hostSiteId,
                      openerSiteId: active.openerSiteId,
                      homeUrl: active.homeUrl));
                } else {
                  unawaited(_tabs.openLinkInNewTab(index, url,
                      hostSiteId: tabHost?.siteId,
                      openerSiteId: identity.siteId,
                      homeUrl: url));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: Text(loc.commonOpen),
              onTap: () {
                Navigator.of(ctx).pop();
                unawaited(_links.openLinkAsTapped(index, url));
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(loc.commonCopy),
              onTap: () {
                Navigator.of(ctx).pop();
                Clipboard.setData(ClipboardData(text: url));
              },
            ),
          ],
        ),
      ),
    );
  }

  void _goHome() {
    if (_sites.current == null || _sites.current! >= _sites.models.length) return;
    final model = _sites.models[_sites.current!];
    _evictCacheIfOnline(model.siteId);
    model.currentUrl = model.navigationHomeUrl;
    model.disposeWebView();
    setState(() {});
    // Re-apply fullscreen for sites with auto-fullscreen after webview recreation
    if (model.fullscreenMode) {
      _enterFullscreen();
    }
    _commitSites(const SitesEdited());
  }

  String _getThemeTooltip(AppLocalizations loc) {
    final modeName = _themeSettings.themeMode == ThemeMode.system
        ? loc.homeThemeModeSystem
        : _themeSettings.themeMode == ThemeMode.light
            ? loc.homeThemeModeLight
            : loc.homeThemeModeDark;
    final colorName = _themeSettings.accentColor == AccentColor.blue
        ? loc.homeThemeColorBlue
        : loc.homeThemeColorGreen;
    return loc.homeThemeTooltip(modeName, colorName);
  }

  /// The one way the theme changes: the app, its saved settings and every
  /// site's webview follow.
  Future<void> _applyThemeSettings(AppThemeSettings next) async {
    setState(() => _themeSettings = next);
    widget.onThemeSettingsChanged(next);
    await _saveThemeSettings();
    if (!mounted) return;
    final webViewTheme = _themeModeToWebViewTheme(next.themeMode);
    for (final model in List.of(_sites.models)) {
      await model.setTheme(webViewTheme);
    }
  }

  Future<void> _openAppSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AppSettingsScreen(
          currentSettings: _themeSettings,
          proxyRouterRunsHere: ProxyRouterService.canRunHere(
              useContainers: _sites.useContainers),
          externalTorRunsHere: externalTorRunsHere,
          siteNames: _siteNames(),
          onSettingsChanged: _applyThemeSettings,
          onExportSettings: _exportSettings,
          onImportSettings: _importSettings,
          onTrustUboHosts: _trustUboHosts,
          onRestoreArchive: _archives.promptRestore,
          hasOpenArchives: _archives.anyOpen,
          onCloseAllArchives: () async {
            await _archives.closeAll();
            _toast((loc) => loc.homeArchivesClosed);
          },
          onOpenLinkHandlingSettings: _openLinkHandlingSettings,
          webSearchSites: [
            for (final m in _sites.models)
              if (!m.isArchiveTier &&
                  m.searchCapability?.kind == SearchKind.web)
                (
                  siteId: m.siteId,
                  name: m.getDisplayName(),
                  containerColor: _sites.useContainers
                      ? m.containerColor ??
                          ContainerColorEngine.fallback(
                              m.siteId, kContainerPaletteSize)
                      : null,
                ),
          ],
          globalUserScripts: _globalUserScripts,
          onGlobalUserScriptsChanged: (scripts) {
            _globalUserScripts = scripts;
            _saveGlobalUserScripts();
            _resetAllWebViews();
          },
          onOutboundProxyChanged: _resetAllWebViews,
          siteProxies: () => [
            for (final m in _sites.models) m.proxySettings,
          ],
          onSavedProxiesChanged: () {
            _resetAllWebViews();
            unawaited(_network.refreshRoutes());
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openProtectionReport() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => BlockStatsScreen(siteNames: _siteNames()),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  AppBar _buildAppBar() {
    final loc = AppLocalizations.of(context);
    final currentModel =
        _sites.current != null && _sites.current! < _sites.models.length
            ? _sites.models[_sites.current!]
            : null;
    return AppBar(
      bottom: currentModel == null
          ? null
          : PageLoadBar(
              loading: currentModel.isLoading,
              progress: currentModel.loadingProgress,
            ),
      // KIOSK-002: no leading menu button when locked.
      automaticallyImplyLeading: !_kioskLocked,
      title: _sites.current != null && _sites.current! < _sites.models.length
          ? GestureDetector(
              onDoubleTap: _toggleFullscreen,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      _sites.models[_sites.current!].getDisplayName(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ],
              ),
            )
          : Text(_sites.selectedWebspaceId != null
              ? _sites.webspaces.firstWhere(
                  (ws) => ws.id == _sites.selectedWebspaceId,
                  orElse: () => Webspace(name: 'Unknown'),
                ).name
              : loc.homeNoWebspaceSelected),
      // KIOSK-002: no app-bar actions (download, theme, settings) when locked.
      actions: _kioskLocked ? const <Widget>[] : [
        // Tab count for the site on screen. Present whenever a site is shown,
        // even at one tab, because it is also how a new tab is opened.
        if (currentModel != null && _tabs.enabledAt(_sites.current))
          TabCountButton(
            count: currentModel.tabs.length,
            onPressed: () => unawaited(_showTabsSheet()),
          ),
        const DownloadButton(),
        ThemeModeButton(
          mode: _themeSettings.themeMode,
          tooltip: _getThemeTooltip(loc),
          onChanged: (mode) => _applyThemeSettings(
              _themeSettings.copyWith(themeMode: mode)),
        ),
        // Protection report shield, badged with the week's block count.
        // Same visibility rule as the settings gear: the webspaces list is
        // the app's "home", which is where a protection summary belongs.
        if (_sites.current == null || _sites.current! >= _sites.models.length)
          ProtectionShieldButton(onPressed: _openProtectionReport),
        // Settings icon button (only visible on webspaces list screen)
        if (_sites.current == null || _sites.current! >= _sites.models.length)
          IconButton(
            icon: Icon(Icons.settings),
            tooltip: loc.homeAppSettingsTooltip,
            onPressed: _openAppSettings,
          ),
        if (_sites.current != null && _sites.current! < _sites.models.length && !AppPref.showTabStrip.value)
          PopupMenuButton<SiteMenuAction>(
            itemBuilder: (context) =>
                _siteMenuItems(context, _SiteMenuPlacement.appBar),
            onSelected: _onSiteMenuAction,
          ),
      ],
    );
  }

  /// Whether the bottom tab strip should currently occupy the
  /// bottomNavigationBar slot. Out of fullscreen it follows the "Site Tab
  /// Strip" pref. In fullscreen the behavior is an independent choice: always
  /// visible, revealed on demand by the tab-bar button, or hidden.
  bool get _tabStripShown {
    // KIOSK-002: never show the tab strip in a locked session, in or out of
    // fullscreen — no switching away from the kiosk site.
    if (_kioskLocked) return false;
    if (_sites.current == null || _sites.current! >= _sites.models.length) {
      return false;
    }
    if (_sites.filteredIndices().isEmpty) return false;
    if (_isFullscreen) {
      if (AppPref.tabStripInFullscreen.value) return true;
      return AppPref.tabBarButton.value && _tabBarOverlayVisible;
    }
    return AppPref.showTabStrip.value || (AppPref.tabBarButton.value && _tabBarOverlayVisible);
  }

  /// Whether the floating tab-bar button is currently shown. It reveals the
  /// tab strip (and its overflow menu) on demand, in and out of fullscreen.
  /// Suppressed while the strip is already pinned or revealed — the strip then
  /// carries its own dismiss control.
  bool get _tabBarButtonShown {
    if (!AppPref.tabBarButton.value) return false;
    // KIOSK-002: a locked session must not expose tab switching.
    if (_kioskLocked) return false;
    if (_sites.current == null || _sites.current! >= _sites.models.length) {
      return false;
    }
    if (_sites.filteredIndices().isEmpty) return false;
    if (_tabBarOverlayVisible) return false;
    if (_isFullscreen) return !AppPref.tabStripInFullscreen.value;
    return !AppPref.showTabStrip.value;
  }

  /// Build the tab strip shown in bottomNavigationBar.
  /// This stays at the screen bottom and doesn't need to be above the keyboard.
  Widget? _buildTabStrip() {
    if (!_tabStripShown) return null;

    // Hide when keyboard is open - it's not needed during text input
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      return null;
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final filteredIndices = _sites.filteredIndices();

    return SafeArea(
      top: false,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: isDark ? Color(0xFF1E1E1E) : Color(0xFFF5F5F5),
          border: Border(
            top: BorderSide(
              color: isDark ? Color(0xFF3E3E3E) : Color(0xFFE0E0E0),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            // When the strip was revealed by the fullscreen tab-bar button,
            // its dismiss control lives inside the bar (not as a separate
            // floating cross above it).
            if (_tabBarOverlayVisible)
              IconButton(
                icon: const Icon(Icons.close),
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  setState(() {
                    _tabBarOverlayVisible = false;
                  });
                  _surface.nudge('tab-overlay-hide');
                },
              ),
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: filteredIndices.length,
                padding: EdgeInsets.symmetric(horizontal: 4),
                itemBuilder: (context, listIndex) {
                  return _buildTabStripItem(
                    context, listIndex, filteredIndices, theme, isDark);
                },
              ),
            ),
            _buildBottomPopupMenu(),
          ],
        ),
      ),
    );
  }

  /// One tab in the bottom strip. Draggable-to-reorder when the current view
  /// supports reordering (a named webspace or "All") and there is more than
  /// one tab; a plain tappable chip otherwise. Uses a raw [Listener] for tap
  /// detection rather than [GestureDetector] so the tap doesn't lose the
  /// gesture-arena fight with [LongPressDraggable] (same pattern as the
  /// drawer grid tiles).
  Widget _buildTabStripItem(
    BuildContext context,
    int listIndex,
    List<int> filteredIndices,
    ThemeData theme,
    bool isDark,
  ) {
    final siteIndex = filteredIndices[listIndex];
    final siteModel = _sites.models[siteIndex];
    final isActive = siteIndex == _sites.current;
    final content = _buildTabStripItemContent(siteModel, isActive, theme, isDark);

    void handleTap() {
      // Tapping the chip of the site already on screen opens its tab list —
      // the strip switches sites, and within a site the tabs are what is left
      // to switch between (TAB-008). It was a no-op before.
      if (isActive) {
        unawaited(_showTabsSheet());
        return;
      }
      () async {
        await _setCurrentIndex(siteIndex);
        if (!mounted) return;
        setState(() {
          _tabBarOverlayVisible = false;
        });
        _saveCurrentIndex();
      }();
    }

    if (!_canReorderCurrentView || filteredIndices.length < 2) {
      return GestureDetector(onTap: handleTap, child: content);
    }

    Offset? pointerDownPos;
    Duration? pointerDownTime;
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != listIndex,
      onAcceptWithDetails: (details) => _reorderSite(details.data, listIndex),
      builder: (context, candidateData, rejectedData) {
        final isHovered = candidateData.isNotEmpty;
        return LongPressDraggable<int>(
          data: listIndex,
          feedback: Material(
            color: Colors.transparent,
            child: Opacity(opacity: 0.85, child: content),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: content),
          child: Container(
            decoration: isHovered
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.primary, width: 2),
                  )
                : null,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                pointerDownPos = event.position;
                pointerDownTime = event.timeStamp;
              },
              onPointerUp: (event) {
                if (pointerDownPos != null) {
                  final distance = (event.position - pointerDownPos!).distance;
                  final duration = event.timeStamp - pointerDownTime!;
                  if (distance < 20 &&
                      duration < const Duration(milliseconds: 300)) {
                    handleTap();
                  }
                }
                pointerDownPos = null;
                pointerDownTime = null;
              },
              onPointerCancel: (_) {
                pointerDownPos = null;
                pointerDownTime = null;
              },
              child: content,
            ),
          ),
        );
      },
    );
  }

  Widget _buildTabStripItemContent(
    WebViewModel siteModel,
    bool isActive,
    ThemeData theme,
    bool isDark,
  ) {
    return Container(
      constraints: BoxConstraints(maxWidth: AppPref.tabMaxWidth.value.toDouble()),
      margin: EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      padding: EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: isActive
            ? theme.colorScheme.primaryContainer
            : (isDark ? Color(0xFF2A2A2A) : Colors.white),
        borderRadius: BorderRadius.circular(8),
        border: isActive
            ? Border.all(color: theme.colorScheme.primary, width: 1.5)
            : Border.all(
                color: isDark ? Color(0xFF3E3E3E) : Color(0xFFE0E0E0),
                width: 0.5,
              ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          UnifiedFaviconImage(
            url: siteModel.initUrl,
            size: 16,
            proxy: siteModel.outboundProxySettings,
            customIcon: siteModel.customIconPng,
            persist: !siteModel.isArchiveTier,
          ),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              siteModel.getDisplayName(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                color: isActive
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurface.withOpacity(0.8),
              ),
            ),
          ),
          // Tab count, only once there is more than one: a site with a single
          // tab looks exactly as it did before tabs existed (TAB-008).
          if (_tabs.enabledFor(siteModel) && siteModel.tabs.length > 1)
            TabCountPill(count: siteModel.tabs.length, active: isActive),
        ],
      ),
    );
  }

  /// Build the URL bar and find toolbar, placed in the body so that
  /// resizeToAvoidBottomInset keeps them above the keyboard.
  Widget? _buildInputBar() {
    if (_isFullscreen) return null;
    if (_sites.current == null || _sites.current! >= _sites.models.length) {
      return null;
    }

    final model = _sites.models[_sites.current!];
    final hasUrlBar = AppPref.showUrlBar.value;
    final hasFindToolbar = _isFindVisible && getController() != null;
    if (!hasUrlBar && !hasFindToolbar) {
      return null;
    }
    final urlBarSearch = hasUrlBar && !_kioskLocked && _tabs.featureEnabled
        ? _links.urlBarSearchFor(model)
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Find toolbar (when visible)
        if (hasFindToolbar)
          FindToolbar(
            webViewController: getController(),
            matches: model.findMatches,
            onClose: () {
              _toggleFind();
            },
          ),
        // URL bar (when visible)
        if (hasUrlBar)
          UrlBar(
            currentUrl: model.currentUrl,
            searchSites: urlBarSearch?.sites ?? const [],
            defaultSearchSiteId: urlBarSearch?.defaultId,
            onSearch: urlBarSearch == null
                ? null
                : (query, siteId) =>
                    _links.searchFromUrlBar(model, query, siteId),
            onSiteInfo: () {
              final id = model.runningIdentity;
              showSiteInfoSheet(
                context,
                SiteInfo(
                  siteName: id.getDisplayName(),
                  tabOf: identical(id, model) ? null : model.getDisplayName(),
                  pageUrl: model.currentUrl,
                  proxy: PlatformInfo.isProxySupported
                      ? id.proxySettings
                      : null,
                  siteId: id.siteId,
                  containerId: containerIdFor(
                    siteId: id.siteId,
                    archiveContainerId: id.archiveContainerId,
                    incognito: id.effectiveIncognito,
                  ),
                  incognito: id.effectiveIncognito,
                  containerColor: _sites.useContainers
                      ? id.containerColor ??
                          ContainerColorEngine.fallback(
                              id.siteId, kContainerPaletteSize)
                      : null,
                ),
              );
            },
            onUrlSubmitted: (url) => _links.openTypedAddress(model, url),
          ),
      ],
    );
  }

  /// Popup menu button for use in the bottom bar when tab strip is enabled.
  Widget _buildBottomPopupMenu() {
    return PopupMenuButton<SiteMenuAction>(
      icon: Icon(Icons.more_vert, size: 20),
      padding: EdgeInsets.zero,
      tooltip: AppLocalizations.of(context).homeMenuTooltip,
      itemBuilder: (context) =>
          _siteMenuItems(context, _SiteMenuPlacement.bottomBar),
      onSelected: _onSiteMenuAction,
    );
  }

  List<PopupMenuEntry<SiteMenuAction>> _siteMenuItems(
    BuildContext menuContext,
    _SiteMenuPlacement placement,
  ) {
    final loc = AppLocalizations.of(menuContext);
    return [
      _siteMenuNavRow(menuContext, loc),
      PopupMenuDivider(),
      for (final action in SiteMenuAction.values)
        if (_siteMenuEntry(action, placement, loc) case (final icon, final label))
          PopupMenuItem(
            value: action,
            child: Row(
              children: [
                Icon(icon),
                SizedBox(width: 8),
                Flexible(child: Text(label)),
              ],
            ),
          ),
    ];
  }

  /// Icon and label of [action] in the menu at [placement], or null where
  /// that menu does not offer it.
  (IconData, String)? _siteMenuEntry(
    SiteMenuAction action,
    _SiteMenuPlacement placement,
    AppLocalizations loc,
  ) =>
      switch (action) {
        SiteMenuAction.newTab =>
          _tabs.enabledAt(_sites.current) ? (Icons.add, loc.tabsNewTab) : null,
        SiteMenuAction.backToWebspaces =>
          placement == _SiteMenuPlacement.bottomBar
              ? (Icons.arrow_back, loc.homeBackToWebspaces)
              : null,
        SiteMenuAction.search => (Icons.search, loc.homeFindMenu),
        // Where the site has tabs, web search lives in the Tabs sheet.
        SiteMenuAction.webSearch =>
          _tabs.featureEnabled && !_tabs.enabledAt(_sites.current)
              ? (Icons.travel_explore, loc.webSearchMenu)
              : null,
        SiteMenuAction.toggleUrlBar => AppPref.showUrlBar.value
            ? (Icons.visibility_off, loc.homeHideUrlBarMenu)
            : (Icons.visibility, loc.homeShowUrlBarMenu),
        SiteMenuAction.fullscreen => _isFullscreen
            ? (Icons.fullscreen_exit, loc.homeExitFullScreenMenu)
            : (Icons.fullscreen, loc.homeFullScreenMenu),
        // Manual escape hatch for the recurring Android blank surface
        // (BUG-001 / PAUSE-028): every automatic trigger is an enumerated
        // code path, and the user is the only one who can see a path nobody
        // enumerated. Android-only, where the nudge is not a no-op, and
        // behind developer mode: it is a diagnostic, not something to meet
        // by accident.
        SiteMenuAction.repaint =>
          hostIsAndroid && DeveloperModeService.instance.enabled
              ? (Icons.format_paint, loc.commonRepaintScreen)
              : null,
        SiteMenuAction.settings => (Icons.settings, loc.homeSettingsMenu),
        SiteMenuAction.devTools => (Icons.code, loc.homeDeveloperToolsMenu),
        SiteMenuAction.addToHome => switch (_sites.shown) {
            final shown? when _shortcuts.offersShortcutFor(shown) =>
              (Icons.add_to_home_screen, loc.homeHomeShortcutMenu),
            _ => null,
          },
      };

  PopupMenuItem<SiteMenuAction> _siteMenuNavRow(
    BuildContext menuContext,
    AppLocalizations loc,
  ) {
    final model = _sites.current != null ? _sites.models[_sites.current!] : null;
    final loading = model?.isLoading ?? false;
    return PopupMenuItem(
      padding: EdgeInsets.zero,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back),
            tooltip: loc.homeGoBackTooltip,
            onPressed: () {
              Navigator.pop(menuContext);
              () async {
                final controller = getController();
                if (controller != null) {
                  final canGoBack = await controller.canGoBack();
                  if (canGoBack) {
                    await _goBackAndRepaint(controller);
                  }
                }
              }();
            },
          ),
          IconButton(
            icon: Icon(Icons.home),
            tooltip: loc.homeGoToHomeTooltip,
            onPressed: () {
              Navigator.pop(menuContext);
              _goHome();
            },
          ),
          IconButton(
            icon: Icon(Icons.share),
            tooltip: loc.commonShare,
            onPressed: () {
              Navigator.pop(menuContext);
              if (_sites.current != null && _sites.current! < _sites.models.length) {
                final model = _sites.models[_sites.current!];
                final url = model.currentUrl ?? model.initUrl;
                SharePlus.instance.share(ShareParams(uri: Uri.parse(url)));
              }
            },
          ),
          IconButton(
            icon: Icon(loading ? Icons.close : Icons.refresh),
            tooltip: loading ? loc.homeStopTooltip : loc.homeRefreshTooltip,
            onLongPress: _tabs.enabledAt(_sites.current)
                ? () {
                    Navigator.pop(menuContext);
                    final index = _sites.current;
                    if (index != null) unawaited(_tabs.duplicateTab(index));
                  }
                : null,
            onPressed: () {
              Navigator.pop(menuContext);
              if (loading) {
                _stopCurrentSiteLoading();
              } else {
                _refreshCurrentSite();
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _onSiteMenuAction(SiteMenuAction action) async {
    final index = _sites.current;
    final model = index != null && index < _sites.models.length
        ? _sites.models[index]
        : null;
    switch (action) {
      case SiteMenuAction.newTab:
        if (model != null) await _tabs.newTab(index!);
      case SiteMenuAction.backToWebspaces:
        await _setCurrentIndex(null);
        if (!mounted) return;
        setState(() {});
        await _saveSelectedWebspaceId();
        await _saveCurrentIndex();
      case SiteMenuAction.search:
        _toggleFind();
      case SiteMenuAction.webSearch:
        await _links.webSearch();
      case SiteMenuAction.toggleUrlBar:
        await AppPref.showUrlBar.set(!AppPref.showUrlBar.value);
      case SiteMenuAction.fullscreen:
        _toggleFullscreen();
      case SiteMenuAction.repaint:
        _repaintCurrentSurface();
      case SiteMenuAction.settings:
        if (model != null) await _openSiteSettings(index!);
      case SiteMenuAction.devTools:
        if (model == null) return;
        unawaited(Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => DevToolsScreen(
              host: WebViewModelDevToolsHost(model),
              cookieManager: _cookieManager,
              containerCookieManager: _containerCookieManager,
              onSave: () => _commitSites(const SitesEdited()),
              globalUserScripts: _globalUserScripts,
              onSimulateBackgroundRefresh: _background.wake,
            ),
          ),
        ));
      case SiteMenuAction.addToHome:
        if (model != null) await _shortcuts.addToHome(model);
    }
  }

  /// [deepLinkQrSettings] is a decoded `webspace://qr/` payload that arrived
  /// from outside the app. Both QR entry points (this one and the in-app
  /// scanner, which returns `{'qrSettings': ...}` from `AddSiteScreen`) pass
  /// through the same review gate below, and a payload the app did not ask
  /// for never becomes the visible site.
  Future<void> _addSite({
    String? initialUrl,
    Map<String, dynamic>? deepLinkQrSettings,
  }) async {
    Object? result;
    if (deepLinkQrSettings != null) {
      result = {'qrSettings': deepLinkQrSettings};
    } else {
      result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AddSiteScreen(
            themeMode: _themeSettings.themeMode,
            onThemeModeChanged: (mode) => _applyThemeSettings(
                _themeSettings.copyWith(themeMode: mode)),
            suggestions: _suggestedSites,
            onSuggestionsChanged: (sites) {
              _suggestedSites = sites;
              suggested_sites.saveSuggestedSites(sites);
            },
            initialUrl: initialUrl,
          ),
        ),
      );
    }
    if (result == null || result is! Map<String, dynamic>) return;
    if (!mounted) return;

    final stateSetter = () { setState((){}); };
    late WebViewModel model;
    final resultQrSettings = result['qrSettings'] as Map<String, dynamic>?;

    if (resultQrSettings != null) {
      final accepted = await _confirmQrSiteSettings(resultQrSettings);
      if (!accepted || !mounted) return;
      model = WebViewModel.fromJson(
        SiteSettingsQrCodec.hydrateForFromJson(resultQrSettings),
        stateSetter,
      );
      if ((model.name ?? '').isEmpty) {
        final pageTitle = await getPageTitle(
          model.initUrl,
          proxy: model.proxySettings,
        );
        if (!mounted) return;
        if (pageTitle != null && pageTitle.isNotEmpty) {
          model.name = pageTitle;
          model.pageTitle = pageTitle;
        }
      } else {
        model.pageTitle = model.name;
      }
    } else {
      final url = result['url'] as String;
      final customName = result['name'] as String;
      final incognito = result['incognito'] as bool? ?? false;
      final htmlContent = result['htmlContent'] as String?;

      // Try to fetch page title if custom name not provided (skip for local files)
      String? pageTitle;
      if (customName.isEmpty && htmlContent == null) {
        pageTitle = await getPageTitle(url);
        if (!mounted) return;
      }

      model = WebViewModel(
        initUrl: url,
        incognito: incognito,
        stateSetterF: stateSetter,
      );
      if (customName.isNotEmpty) {
        model.name = customName;
        model.pageTitle = customName;
      } else if (pageTitle != null && pageTitle.isNotEmpty) {
        model.name = pageTitle;
        model.pageTitle = pageTitle;
      }

      // Imported HTML files are the only copy of the user's data, so they
      // go into HtmlImportStorage (persistent) rather than HtmlCacheService
      // (cleared on app upgrade). The webview reads from the import store
      // for `initialHtml` on creation.
      if (htmlContent != null && !incognito) {
        await HtmlImportStorage.instance.saveHtml(model.siteId, htmlContent, url);
      }
    }

    await _registerNewSite(model, activate: deepLinkQrSettings == null);
  }

  /// Mandatory review of a QR-borne site configuration before it is created.
  /// The payload is authored by whoever printed the code, reaches us from any
  /// app or web page via the exported `webspace://` scheme, and can turn every
  /// protection off, point the site at a proxy, and name it anything.
  Future<bool> _confirmQrSiteSettings(Map<String, dynamic> qr) async {
    final loc = AppLocalizations.of(context);
    final url = qr['initUrl'] as String? ?? '';
    final name = (qr['name'] as String?) ?? extractDomain(url);
    final proxy = SiteSettingsQrCodec.reviewProxy(qr);
    final proxyAddress = proxy?.address ?? '';
    final proxyLabel = proxy == null
        ? null
        : proxy.type == ProxyType.TOR
            ? loc.torStatusTitle
            : proxyAddress.isNotEmpty
                ? proxyAddress
                : proxy.type.name;
    bool turnsOff(String key) => qr[key] == false;
    bool turnsOn(String key) => qr[key] == true;
    final weakened = <String>[
      if (turnsOff('trackingProtectionEnabled')) loc.siteSettingsTrackingProtection,
      if (turnsOff('clearUrlEnabled')) loc.siteSettingsClearUrls,
      if (turnsOff('dnsBlockEnabled')) loc.siteSettingsDnsBlocklist,
      if (turnsOff('contentBlockEnabled')) loc.siteSettingsContentBlocker,
      if (turnsOff('localCdnEnabled')) loc.siteSettingsLocalCdn,
      // A level below the app-wide one, or a filter list switched off, weakens
      // the blockers without turning either toggle off. Unnamed, a QR could
      // relax protection while the review reported nothing.
      if (qr['dnsBlockLevel'] is int &&
          (qr['dnsBlockLevel'] as int) < DnsBlockService.instance.level)
        loc.siteSettingsDnsBlocklistLevel,
      if (qr['disabledFilterLists'] is List &&
          (qr['disabledFilterLists'] as List).isNotEmpty)
        loc.siteSettingsContentBlockerLists,
    ];
    final granted = <String>[
      if (turnsOn('thirdPartyCookiesEnabled')) loc.siteSettingsThirdPartyCookies,
      if (turnsOn('notificationsEnabled')) loc.siteSettingsNotifications,
      if (turnsOn('backgroundAudioEnabled')) loc.siteSettingsBackgroundAudio,
      if (turnsOn('kioskMode')) loc.siteSettingsKioskMode,
      if (qr['locationMode'] is String && qr['locationMode'] != LocationMode.off.name)
        loc.siteSettingsGeolocation,
    ];
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.homeQrReviewTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(loc.homeQrReviewBody),
              SizedBox(height: 12),
              Text(loc.homeQrReviewUrl(url)),
              Text(loc.homeQrReviewName(name)),
              if (proxyLabel != null) Text(loc.homeQrReviewProxy(proxyLabel)),
              if (weakened.isNotEmpty) ...[
                SizedBox(height: 12),
                Text(loc.homeQrReviewTurnsOff(weakened.join(', '))),
              ],
              if (granted.isNotEmpty) ...[
                SizedBox(height: 12),
                Text(loc.homeQrReviewTurnsOn(granted.join(', '))),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.qrApplyConfirm),
          ),
        ],
      ),
    );
    return accepted == true;
  }

  Future<void> _editSite(int index) async {
    final model = _sites.models[index];
    final result = await showEditSiteDialog(context, model);
    if (result == null || !mounted) return;
    // Apply by the captured model identity, not the index: a concurrent
    // delete of a lower-indexed site while the dialog was open shifts
    // positions, so `index` could now target a different site. Bail if this
    // model was deleted meanwhile.
    if (!_sites.models.contains(model)) return;

    final (:name, :url, :icon) = result;
    if (icon != null) {
      setState(() => model.customIconPng = icon.png);
    }
    if (name.isNotEmpty) {
      setState(() => model.name = name);
    }

    if (url != model.initUrl) {
      // Snapshot belongs to the old URL; deleteCache must run before the
      // rebuild's getHtmlSync, which is why the sync in-memory eviction
      // (inside deleteCache) is fired before setState rather than awaited.
      final siteId = model.siteId;
      final deleteCache = HtmlCacheService.instance.deleteCache(siteId);
      setState(() {
        model.initUrl = url;
        model.currentUrl = url;
        model.webview = null; // Force recreation with new URL
        model.controller = null;
      });
      await deleteCache;
    }

    await _commitSites(const SitesEdited());
  }

  void _showSiteContextMenu(BuildContext context, int index, Offset position) {
    final filteredIndices = _sites.filteredIndices();
    final listIndex = filteredIndices.indexOf(index);
    final isArchiveSite =
        index >= 0 && index < _sites.models.length && _sites.models[index].isArchiveTier;
    // Show "Move to archive" for every app-tier site, regardless of
    // whether any archive is currently open. The handler always prompts
    // for a passphrase and opens-or-creates the matching archive — its
    // presence in the menu therefore reveals nothing about whether an
    // archive is currently open or whether any exist on disk.
    final canMoveToArchive = !isArchiveSite;

    final loc = AppLocalizations.of(context);
    PopupMenuItem<_SiteListAction> item(
      _SiteListAction action,
      IconData icon,
      String label, {
      Color? color,
    }) =>
        PopupMenuItem(
          value: action,
          child: ListTile(
            leading: Icon(icon, color: color),
            title: Text(label, style: TextStyle(color: color)),
            dense: true,
            visualDensity: VisualDensity.compact,
          ),
        );
    showMenu<_SiteListAction>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx + 1, position.dy + 1),
      items: [
        item(_SiteListAction.edit, Icons.edit, loc.commonEdit),
        item(_SiteListAction.delete, Icons.delete, loc.commonDelete,
            color: Colors.red),
        if (_canReorderCurrentView && listIndex > 0)
          item(_SiteListAction.moveUp, Icons.arrow_upward, loc.homeMoveUp),
        if (_canReorderCurrentView && listIndex >= 0 && listIndex < filteredIndices.length - 1)
          item(_SiteListAction.moveDown, Icons.arrow_downward, loc.homeMoveDown),
        if (canMoveToArchive)
          item(_SiteListAction.moveToArchive, Icons.archive_outlined,
              loc.homeMoveToArchive),
        if (isArchiveSite)
          item(_SiteListAction.moveOutOfArchive, Icons.unarchive_outlined,
              loc.homeMoveOutOfArchive),
        if (isArchiveSite)
          item(_SiteListAction.closeArchive, Icons.lock_outline,
              loc.homeCloseArchive),
      ],
    ).then((value) async {
      final site = index >= 0 && index < _sites.models.length
          ? _sites.models[index]
          : null;
      switch (value) {
        case null:
          return;
        case _SiteListAction.moveToArchive:
          if (site != null) await _archives.moveIn(site);
        case _SiteListAction.moveOutOfArchive:
          if (site != null) await _archives.moveOut(site);
        case _SiteListAction.closeArchive:
          if (site != null) await _archives.closeArchiveOf(site);
        case _SiteListAction.edit:
          await _editSite(index);
        case _SiteListAction.delete:
          await _deleteSite(context, index);
        case _SiteListAction.moveUp:
          _reorderSite(listIndex, listIndex - 1);
        case _SiteListAction.moveDown:
          _reorderSite(listIndex, listIndex + 1);
      }
    });
  }

  /// Whether the currently-selected view supports drag/menu reordering.
  /// Both a named webspace (reorders its `siteIds`) and the synthetic "All"
  /// view (reorders `_sites.models` globally) qualify; the null/home state
  /// does not.
  bool get _canReorderCurrentView => _sites.selectedWebspaceId != null;

  /// Reorder the site shown at [oldListIndex] to [newListIndex] within the
  /// current view. Dispatches to the per-webspace `siteIds` reorder for a
  /// named webspace, or the global `_sites.models` reorder for "All".
  /// [oldListIndex]/[newListIndex] are positions in `_sites.filteredIndices()`.
  void _reorderSite(int oldListIndex, int newListIndex) {
    final filtered = _sites.filteredIndices();
    if (oldListIndex < 0 || oldListIndex >= filtered.length) return;
    if (newListIndex < 0 || newListIndex >= filtered.length) return;
    if (oldListIndex == newListIndex) return;
    if (_sites.selectedWebspaceId == kAllWebspaceId) {
      unawaited(_reorderAllSites(filtered[oldListIndex], filtered[newListIndex]));
    } else {
      _reorderSiteInWebspace(oldListIndex, newListIndex);
    }
  }

  void _reorderSiteInWebspace(int oldListIndex, int newListIndex) {
    final webspace = _sites.webspaces.cast<Webspace?>().firstWhere(
      (ws) => ws!.id == _sites.selectedWebspaceId,
      orElse: () => null,
    );
    if (webspace == null) return;
    if (oldListIndex < 0 || oldListIndex >= webspace.siteIds.length) return;
    if (newListIndex < 0 || newListIndex >= webspace.siteIds.length) return;
    setState(() {
      final movedSiteId = webspace.siteIds.removeAt(oldListIndex);
      webspace.siteIds.insert(newListIndex, movedSiteId);
      _sites.resolveWebspaceIndices();
    });
    _saveWebspaces();
  }

  /// Moves the site at [oldModelIndex] to [newModelIndex] in the "All"
  /// order. The IndexedStack children are keyed by siteId, so each webview
  /// keeps its State.
  Future<void> _reorderAllSites(int oldModelIndex, int newModelIndex) async {
    if (oldModelIndex < 0 || oldModelIndex >= _sites.models.length) return;
    if (newModelIndex < 0 || newModelIndex >= _sites.models.length) return;
    if (oldModelIndex == newModelIndex) return;
    await _commitSites(SitesMoved(oldModelIndex, newModelIndex));
    await _saveCurrentIndex();
  }

  /// What a deleted site leaves outside the list: its webview, the tabs it
  /// hosts, its shortcut, its container or shared-jar cookies, its pages.
  Future<void> _retireSite(WebViewModel site) async {
    final index = _sites.models.indexOf(site);
    if (index < 0) return;
    site.disposeWebView();
    _sites.loaded.remove(index);
    // LIR-023: every tab the site hosts closes before its container is
    // deleted, which iOS and macOS skip while a webview still binds it.
    await _tabs.closeIneligibleHostedTabs(goneSiteId: site.siteId);
    if (!mounted) return;
    // LIR-022: its hosted tabs keep their bytes under their hosts' keys,
    // which the site's own sweep does not reach.
    for (final t in site.tabs) {
      if (t.hostSiteId != null) {
        await _stateStorage.removeState(site.stateKeyForTab(t.id));
      }
    }
    await ShortcutService.removeShortcut(site.siteId);
    if (!mounted) return;
    if (_sites.useContainers) {
      await _containerIsolation.onSiteDeleted(site.siteId);
    } else {
      // The legacy jar is shared: a loaded same-base-domain site's session
      // is captured and restored around clearing the deleted site's cookies,
      // so the site on screen is not logged out.
      await _cookieIsolation.preDeleteCookieCleanup(
        deletedModel: site,
        deletedIndex: _sites.models.indexOf(site),
        models: _sites.models,
        loadedIndices: _sites.loaded,
      );
    }
    await HtmlCacheService.instance.deleteCache(site.siteId);
    await HtmlImportStorage.instance.deleteImport(site.siteId);
  }

  Future<void> _deleteSite(BuildContext context, int index) async {
    final loc = AppLocalizations.of(context);
    final siteName = _sites.models[index].getDisplayName();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.homeDeleteSiteTitle),
        content: Text(loc.homeDeleteSiteConfirm(siteName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.commonDelete),
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    if (index >= _sites.models.length) return;

    final deletedModel = _sites.models[index];
    // HS-013: the tiles reaching the site, read before it goes.
    final reachingTiles = await _shortcuts.tilesReaching(deletedModel);
    if (!mounted) return;
    await _commitSites(SiteRemoved(deletedModel));
    await _shortcuts.siteDeleted(deletedModel, reachingTiles);

    if (!mounted) return;
    // closeDrawer() (not Navigator.pop): `context` belongs to the drawer tile
    // of the site just removed, so by now its element can be defunct and
    // Navigator.of would fail its null check — deterministically so when the
    // deleted site was the last tile. Idempotent, like the other drawer taps.
    _scaffoldKey.currentState?.closeDrawer();
  }

  /// A site tapped in the drawer, once a webspace switch in flight lands.
  Future<void> _openSiteFromDrawer(int index) async {
    // closeDrawer() (not Navigator.pop) is idempotent: a rapid second tap
    // won't pop the underlying page route once the drawer is already closing.
    _scaffoldKey.currentState?.closeDrawer();
    await _webspaceSwitchCompleter?.future;
    await _setCurrentIndex(index);
    if (!mounted) return;
    setState(() {});
    await _saveCurrentIndex();
  }

  /// `siteId` -> display name for the sites the protection report may name.
  /// Archive-tier sites are excluded: they never contribute a count
  /// (STATS-005), so naming them there could only ever be noise.
  Map<String, String> _siteNames() => {
        for (final model in _sites.models)
          if (!model.isArchiveTier) model.siteId: model.getDisplayName(),
      };

  /// The page's hooks on a loaded site, set on every build; each reads the
  /// page's state when it fires.
  void _wireSite(WebViewModel site, int index) {
    _surface.watch(site, onScreen: () => index == _sites.current);
    // Keep the on-disk back/forward stack tracking browsing (PAUSE-009):
    // pause and dispose captures go stale for background sites, and a kill
    // from the switcher only delivers `inactive`, which is ignored (#308).
    // By identity: the list may have changed when the debounce fires.
    site.onNavigationCommitted = () {
      _navStateDebouncer.schedule(site.siteId, () {
        if (!mounted || !_sites.models.contains(site)) return;
        unawaited(_captureStateBytes(site));
      });
    };
    site.onReturnToOwner = _tabs.enabledFor(site)
        ? (url) => unawaited(_tabs.returnToOwner(site, url))
        : null;
  }

  /// Build the body with the input bar (URL bar / find toolbar) integrated,
  /// so resizeToAvoidBottomInset naturally keeps them above the keyboard.
  /// The tab strip stays in bottomNavigationBar separately.
  Widget _buildBodyWithBottomBar() {
    for (final i in _sites.loaded) {
      if (i < _sites.models.length) _wireSite(_sites.models[i], i);
    }
    final inputBar = _buildInputBar();
    final nudgeInset = _surface.bottomInset;
    // Tab strip in bottomNavigationBar handles bottom safe area when visible.
    // Input bar has its own SafeArea. Only apply body safe area when neither
    // is present (e.g. webspace list screen). The tab strip is also rendered
    // (in bottomNavigationBar) when kept in fullscreen or temporarily revealed
    // by the tab-bar button, in which case it owns the bottom safe-area inset.
    final hasTabStrip = _tabStripShown;
    return SafeArea(
      // Out of fullscreen the AppBar absorbs the top inset, so top stays false.
      // In fullscreen there is no AppBar, and the immersive modes do not
      // reliably hide the status/navigation bars on Android 15 (edge-to-edge
      // enforced) — when they remain, edge-to-edge content lands behind them
      // and the site's top/bottom controls become untappable. Inset the body on
      // both edges so it stays clear of any bars that persist, or that the user
      // revealed under `immersive` (FS-011); when they are truly hidden the
      // padding is ~0 and the webview still fills the screen. github #385
      top: _isFullscreen,
      bottom: !hasTabStrip && inputBar == null,
      // Out of fullscreen, inset around a landscape display cutout so chrome
      // and content avoid the notch. In fullscreen let the webview fill the
      // cutout strip (with shortEdges cutout mode the window already extends
      // there); otherwise SafeArea would re-letterbox the space beside the
      // notch with the app background. github #457
      left: !_isFullscreen,
      right: !_isFullscreen,
      // Use Stack + Offstage so the IndexedStack (and its webview States)
      // stay mounted when showing the webspace list. Removing the
      // IndexedStack from the tree destroys webview States, losing
      // navigation history and scroll position.
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Offstage(
                  offstage: _sites.current != null && _sites.current! < _sites.models.length,
                  child: WebspacesListScreen(
                    webspaces: _sites.webspaces,
                    selectedWebspaceId: _sites.selectedWebspaceId,
                    totalSitesCount: _sites.models.length,
                    accentColor: _themeSettings.accentColor,
                    onSelectWebspace: _selectWebspace,
                    onAddWebspace: _addWebspace,
                    onEditWebspace: _editWebspace,
                    onDeleteWebspace: _deleteWebspace,
                    onReorder: _reorderWebspaces,
                  ),
                ),
                if (_sites.loaded.isNotEmpty)
                  Offstage(
                    offstage: _sites.current == null || _sites.current! >= _sites.models.length,
                    // The inset SurfaceRepaintController toggles to make the
                    // hybrid-composition SurfaceView recomposite (BUG-001);
                    // zero in steady state.
                    child: Visibility(
                      visible: !_surface.hidden,
                      maintainState: true,
                      maintainSize: true,
                      maintainAnimation: true,
                      child: SurfaceNudgeScope(
                      bottomInset: nudgeInset,
                      child: Padding(
                      padding: EdgeInsets.only(bottom: nudgeInset),
                      child: SiteWebViewStack(
                        models: _sites.models,
                        loaded: _sites.loaded,
                        current: _sites.current,
                        hooks: _webViewHooks,
                        showStatsBanner: AppPref.showStatsBanner.value,
                      ),
                    ),
                    ),
                    ),
                  ),
                // Full screen has no app bar to host the progress, kiosk-locked
                // too (fullscreen is forced and held there, KIOSK-003).
                if (_sites.shown case final shown?
                    when _isFullscreen && shown.isLoading)
                  FullscreenLoadBar(progress: shown.loadingProgress),
                // Back keeps its normal behaviour in full screen. KIOSK-003:
                // no exit handle in a locked session.
                if (_isFullscreen && !_kioskLocked)
                  FullscreenExitHandle(onExit: _exitFullscreen),
                // Tab-bar button: a small floating control that reveals the
                // tab strip (with its overflow menu) on demand, in and out of
                // fullscreen. Works on its own (no always-on strip needed).
                // Hidden once the strip is showing — its dismiss control then
                // lives inside the bar instead.
                if (_tabBarButtonShown)
                  Positioned.fill(
                    child: TabBarCornerOverlay(
                      corner: _tabBarButtonCornerEffective,
                      onTap: () {
                        setState(() => _tabBarOverlayVisible = true);
                        _surface.nudge('tab-overlay-show');
                      },
                      // Remembered on the site on screen.
                      onCornerChosen: (corner) {
                        final site = _sites.shown;
                        if (site == null) return;
                        setState(() => site.tabBarButtonCorner = corner);
                        unawaited(_commitSites(const SitesEdited()));
                      },
                    ),
                  ),
              ],
            ),
          ),
          // Always wrap in SafeArea to keep the widget tree stable when
          // the keyboard opens/closes (changing tree structure would unmount
          // the UrlBar, losing TextField focus and closing the keyboard).
          // SafeArea naturally adds 0 padding when keyboard is open.
          if (inputBar != null) SafeArea(top: false, child: inputBar),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool webviewIsVisible = _sites.current != null && _sites.current! < _sites.models.length;
    // From build, not from the paths that change the site on screen: the site
    // shown and the window flag then change in the same frame, and a new path
    // that moves _sites.current cannot skip it (SCREENBLOCK-002).
    final shown = _sites.current;
    unawaited(_screenCaptureGuard.apply(screenCaptureBlocked(
      appWide: AppPref.blockScreenshots.value,
      siteOnScreen: shown != null && shown >= 0 && shown < _sites.models.length
          ? _sites.models[shown].blockScreenshots
          : null,
    )));
    final mainTree = _buildMainTree(context, webviewIsVisible);
    if (!_maskBackground) {
      return mainTree;
    }
    // Snapshot-time mask: an opaque surface overlays everything so the
    // task-switcher / recents preview never captures archive content
    // (ARCH-009). Wrapping the existing tree keeps the running webview
    // state intact — only the painted output is replaced.
    return Stack(
      fit: StackFit.expand,
      children: [
        mainTree,
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: Center(
              child: Icon(
                Icons.lock_outline,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMainTree(BuildContext context, bool webviewIsVisible) {
    final loc = AppLocalizations.of(context);
    return PopScope(
      // On Android, always intercept back so the gesture only ever navigates
      // webview history (never exits the app). On other platforms, allow pop
      // only when no webview is visible.
      canPop: hostIsAndroid ? false : !webviewIsVisible,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBackGesture();
      },
      child: Scaffold(
      key: _scaffoldKey,
      // Clearing on close covers every way the drawer goes away; a drawer
      // opened by any other affordance therefore starts with the flag down.
      onDrawerChanged: (isOpen) {
        if (!isOpen) _drawerOpenedByBackGesture = false;
      },
      // Disable the drawer edge-swipe whenever a webview is active so the back
      // gesture never opens the drawer. The drawer is reached via the AppBar
      // menu button instead.
      drawerEdgeDragWidth: webviewIsVisible ? 0 : null,
      appBar: _isFullscreen ? null : _buildAppBar(),
      // KIOSK-002: no drawer when locked — removes the site grid, "back to
      // webspaces", add-site, and the auto app-bar hamburger / edge swipe.
      drawer: _kioskLocked ? null : Drawer(
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: () async {
                        await _setCurrentIndex(null);
                        if (!mounted) return;
                        setState(() {});
                        await _saveSelectedWebspaceId();
                        await _saveCurrentIndex();
                        if (!mounted) return;
                        _scaffoldKey.currentState?.closeDrawer();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                        child: Column(
                          children: [
                            AccentLogo(
                              accentColor: _themeSettings.accentColor,
                              size: 72,
                              brightness: Theme.of(context).brightness,
                            ),
                            SizedBox(height: 4),
                            Text(
                              _sites.selectedWebspaceId != null
                                  ? _sites.webspaces.firstWhere((ws) => ws.id == _sites.selectedWebspaceId, orElse: () => Webspace(name: 'Unknown')).name
                                  : loc.homeNoWebspace,
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Semantics(
                      label: loc.homeBackToWebspaces,
                      button: true,
                      enabled: true,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 0),
                          minimumSize: Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () async {
                          await _setCurrentIndex(null);
                          if (!mounted) return;
                          setState(() {});
                          await _saveSelectedWebspaceId();
                          await _saveCurrentIndex();
                          if (!mounted) return;
                          _scaffoldKey.currentState?.closeDrawer();
                        },
                        icon: Icon(Icons.arrow_back, size: 16),
                        label: Text(loc.homeBackToWebspaces, style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _sites.selectedWebspaceId == null
                  ? Center(
                      child: Text(loc.homeSelectWebspaceToViewSites),
                    )
                  : () {
                      final filteredIndices = _sites.filteredIndices();
                      if (filteredIndices.isEmpty) {
                        return Center(
                          child: Text(loc.homeNoSitesInWebspace),
                        );
                      }

                      return LayoutBuilder(
                        builder: (context, constraints) {
                          final itemCount = filteredIndices.length;
                          const itemHeight = 88.0;
                          final availableHeight = constraints.maxHeight - 12; // padding (top: 4 + bottom: 8)
                          final maxRows = (availableHeight / itemHeight).floor().clamp(1, itemCount);

                          int crossAxisCount = 1;
                          if (itemCount > maxRows) {
                            crossAxisCount = (itemCount / maxRows).ceil().clamp(1, 4);
                          }

                          return GridView.builder(
                            padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8, top: 4),
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: crossAxisCount,
                              mainAxisSpacing: 4,
                              crossAxisSpacing: 4,
                              mainAxisExtent: itemHeight,
                            ),
                            itemCount: itemCount,
                            itemBuilder: (BuildContext context, int listIndex) {
                              final index = filteredIndices[listIndex];
                              final site = _sites.models[index];
                              return SiteGridTile(
                                key: Key('site_$index'),
                                site: site,
                                listIndex: listIndex,
                                selected: _sites.current == index,
                                showTabCount: _tabs.enabledAt(index) &&
                                    site.tabs.length > 1,
                                onOpen: () => unawaited(_openSiteFromDrawer(index)),
                                onMenu: (context, at) =>
                                    _showSiteContextMenu(context, index, at),
                                onReorder:
                                    _canReorderCurrentView ? _reorderSite : null,
                              );
                            },
                          );
                        },
                      );
                    }(),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    _addSite();
                  },
                  icon: Icon(Icons.add),
                  label: Text(loc.homeAddSite),
                ),
              ),
            ),
            SizedBox(height: 8.0 + MediaQuery.of(context).padding.bottom),
          ],
        ),
      ),
      body: _buildBodyWithBottomBar(),
      bottomNavigationBar: _buildTabStrip(),
      floatingActionButton:
          !(_sites.current == null || _sites.current! >= _sites.models.length) ? null
          : FloatingActionButton(
              onPressed: () async {
                _addSite();
              },
              child: Icon(Icons.add),
            ),
    ),
    );
  }
}

/// What a site's overflow menu offers, in menu order.
enum SiteMenuAction {
  newTab,
  backToWebspaces,
  search,
  webSearch,
  toggleUrlBar,
  fullscreen,
  repaint,
  settings,
  devTools,
  addToHome,
}

/// What the edit-site dialog saved. [icon] is null when the icon was left
/// alone; a null `png` inside it resets to the fetched favicon.

enum _MediaChoice { block, useFile, allow }

/// What a site's long-press menu in the list offers.
enum _SiteListAction {
  edit,
  delete,
  moveUp,
  moveDown,
  moveToArchive,
  moveOutOfArchive,
  closeArchive,
}

/// Where a site's overflow menu sits: the app bar, or the bottom bar while
/// the tab strip is on.
enum _SiteMenuPlacement { appBar, bottomBar }

/// Binds [NestedOpenEngine] to the page state.
class _NestedOpenHost implements NestedOpenHost<WebViewModel> {
  final _WebSpacePageState state;
  const _NestedOpenHost(this.state, {required this.fromTab});

  /// The screen opens over the tab on screen (outbound routing), not for a
  /// share, so a link in it can come back as a tab (LIR-032).
  final bool fromTab;

  @override
  bool get mounted => state.mounted;

  // Android/Linux: the proxy is a process-global override that only the
  // activation path flips. The nested screen is for a site that is not
  // being activated, so the PROXY-008 sequence runs for it here or it would
  // load through whatever the active site left behind, bound to this site's
  // container (LEAK-003).
  //
  // Under router mode the eviction set is computed router-aware below: the
  // rule points at the relay for every site and the nested screen presents
  // this site's own credential, so `setProxySettings` no-ops and evicting
  // siblings would only cold-start what PROXY-013 keeps loaded.
  @override
  bool get proxyIsProcessGlobal => hostIsAndroid || hostIsLinux;

  @override
  int indexOf(WebViewModel site) => state._sites.models.indexOf(site);

  @override
  int? get currentIndex => state._sites.current;

  @override
  Future<void> switchWebspaceFor(WebViewModel target) async {
    final index = state._sites.models.indexOf(target);
    if (index < 0) return;
    await state._maybeSwitchToAllForSite(target, index);
  }

  @override
  Set<int> mismatchedWith(WebViewModel target) => {
        for (final unload in state
            ._residencyPlan(NestedOpening(state._sites.models.indexOf(target)))
            .unloads)
          state._sites.models.indexOf(unload.site),
      };

  @override
  Future<void> unload(int index) =>
      state._unloadSite(index, UnloadReason.proxyMismatch);

  @override
  Future<void> applyProxyOf(WebViewModel target) => ProxyManager()
      .setProxySettings(target.proxySettings, siteId: target.siteId);

  @override
  void reportProxyFailure(Object error) {
    LogService.instance.log(
      'Proxy',
      'Nested open refused: proxy apply failed: $error',
      level: LogLevel.error,
      sensitivity: LogSensitivity.sensitive,
    );
    if (!state.mounted) return;
    state._toast((loc) => loc.siteSettingsProxyError('$error'));
  }

  @override
  Future<void> launchNested(WebViewModel target, String url) =>
      state._launchNestedForModel(target, url, opensFromTab: fromTab);

  @override
  Future<void> activate(int index) => state._setCurrentIndex(index);
}

class _ResidencyHost implements ResidencyHost {
  const _ResidencyHost(this.state);

  final _WebSpacePageState state;

  @override
  List<WebViewModel> get models => state._sites.models;

  @override
  Set<int> get loadedIndices => state._sites.loaded;

  @override
  CookieIsolationEngine? get sharedJar =>
      state._sites.useContainers ? null : state._cookieIsolation;

  @override
  Future<void> captureNavState(WebViewModel model) =>
      state._captureStateForRestore(model);

  @override
  void noteUnloaded(WebViewModel model, UnloadReason reason) =>
      state._background.noteUnloaded(model, reason.label);

  @override
  List<WebViewModel> identities({int? except}) =>
      state._sites.slotIdentities(except: except);

  @override
  SiteRetentionPriority priorityOf(int index) =>
      state._sites.retentionPriority(index);

  @override
  ProxyTopology get proxyTopology => state._network.topology;

  @override
  bool get torAvailable => TorService.instance.isAvailable;
}

class _OrphanSweepTargets implements OrphanSweepTargets {
  final _WebSpacePageState state;
  const _OrphanSweepTargets(this.state);

  @override
  Future<void> removeOrphans(OrphanStore store, Set<String> live) =>
      switch (store) {
        OrphanStore.cookies =>
          state._cookieSecureStorage.removeOrphanedCookies(live),
        OrphanStore.proxyPasswords =>
          state._proxyPasswordStorage.removeOrphaned(live),
        OrphanStore.httpAuthCredentials =>
          HttpAuthSecureStorage.instance.removeOrphaned(live),
        OrphanStore.htmlCaches =>
          HtmlCacheService.instance.removeOrphanedCaches(live),
        OrphanStore.htmlImports =>
          HtmlImportStorage.instance.removeOrphanedImports(live),
        OrphanStore.webViewState =>
          state._stateStorage.removeOrphans(state._liveStateKeys(live)),
        OrphanStore.blockStatsSites =>
          BlockStatsService.instance.removeOrphanedSites(live),
        OrphanStore.siteIcons => SiteIconStore.instance.removeOrphans({
            for (final m in state._sites.models)
              if (live.contains(m.siteId) && !m.effectiveIncognito) m.initUrl,
          }),
      };

  @override
  Future<void> clearLegacyGlobalCookieJar() =>
      state._cookieManager.deleteAllCookies();
}

/// What the page answers for its controllers.
class _PageHost
    implements
        ShortcutHost,
        ArchiveHost,
        SurfaceHost,
        BackgroundSitesHost,
        LifecycleHost,
        TabsHost,
        LinkHost {
  const _PageHost(this._s);

  final _WebSpacePageState _s;

  @override
  bool get mounted => _s.mounted;

  @override
  void rebuild() => _s._rebuild();

  @override
  void toast(
    String Function(AppLocalizations loc) message, {
    Duration duration = const Duration(seconds: 4),
  }) =>
      _s._toast(message, duration: duration);

  @override
  Future<void> commitSites(SiteSetChange change) => _s._commitSites(change);

  @override
  Future<List<Cookie>> captureCookies(WebViewModel model) async {
    final jar = _s._containerCookieManager;
    final controller = model.controller;
    if (controller != null && jar != null) {
      final url = Uri.parse(
        model.currentUrl.isNotEmpty ? model.currentUrl : model.initUrl,
      );
      final fresh = await jar.getCookies(
        controller: controller,
        siteId: model.siteId,
        url: url,
      );
      if (fresh.isNotEmpty) return fresh;
    }
    return List<Cookie>.from(model.cookies);
  }

  @override
  bool get kioskLocked => _s._kioskLocked;

  @override
  set kioskLocked(bool locked) => _s._kioskLocked = locked;

  @override
  void popToRoot() =>
      Navigator.of(_s.context).popUntil((route) => route.isFirst);

  @override
  Future<void> activate(int index) => _s._setCurrentIndex(index);

  @override
  void syncTorExitPin(Set<int> indices) => _s._network.syncTorExitPin(indices);

  @override
  List<UserScriptConfig> get globalUserScripts => _s._globalUserScripts;

  @override
  void enterFullscreen() => _s._enterFullscreen();

  @override
  void reapplyFullscreen() {
    if (_s._isFullscreen) _s._applyFullscreenSystemUi();
  }

  @override
  Future<bool> captureNavState(WebViewModel model) =>
      _s._captureStateBytes(model);

  @override
  Future<void> handleShareIntent() => _s._links.handleShareIntent();

  @override
  Future<void> resetHomeOnLaunch(int index) =>
      _s._resetAlwaysOpenHomeOnShortcut(index);

  @override
  bool tabsEnabledAt(int index) => _s._tabs.enabledAt(index);

  @override
  Future<void> bindOwnerRunTab(WebViewModel model) =>
      _s._tabs.bindOwnerRunTab(model);

  @override
  Future<void> registerSite(WebViewModel model, {bool activate = true}) =>
      _s._registerNewSite(model, activate: activate);

  @override
  Future<void> addSiteFromQr(Map<String, dynamic> settings) =>
      _s._addSite(deepLinkQrSettings: settings);

  @override
  WebViewController? controllerOf(WebViewModel model) =>
      model.getController(_s._webViewHooks);

  @override
  Future<void> launchNestedFor(WebViewModel model, String url,
          {bool opensFromTab = true}) =>
      _s._launchNestedForModel(model, url, opensFromTab: opensFromTab);

  @override
  Future<void> openNested(DispatchOpenNested action, {WebViewModel? source}) =>
      _s._executeOpenNested(action, source: source);

  @override
  Future<void> unloadSite(int index, UnloadReason reason) =>
      _s._unloadSite(index, reason);

  @override
  Future<void> wipeContainer(String siteId) async {
    await _s._containerIsolation.clearForSite(siteId);
  }

  @override
  ArchiveHandle? archiveOf(WebViewModel model) =>
      _s._archives.archiveOf(model);

  @override
  void cancelPendingCapture(String siteId) =>
      _s._navStateDebouncer.cancel(siteId);

  @override
  void evictCache(String siteId) => _s._evictCacheIfOnline(siteId);

  @override
  Future<void> saveCurrentIndex() => _s._saveCurrentIndex();

  @override
  Future<void> saveSelectedWebspace() => _s._saveSelectedWebspaceId();

  @override
  Future<void> revealSite(WebViewModel model, int index) =>
      _s._maybeSwitchToAllForSite(model, index);

  @override
  void offerOpenTab(WebViewModel model, String tabId) =>
      _s._toastOpenedInNewTab(model, tabId);

  @override
  List<DispatchableSite> tabHostsIn(WebViewModel owner, WebViewModel opener) =>
      _s._links.tabHostsIn(owner, opener);

  @override
  void noteUnloaded(WebViewModel model, String why) =>
      _s._background.noteUnloaded(model, why);
}
