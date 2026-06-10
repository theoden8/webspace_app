import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' show min, max;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp
    show InAppWebViewController, ServiceWorkerController, SslCertificate;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;

import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/screens/add_site.dart' show AddSiteScreen, UnifiedFaviconImage, FaviconUrlCache, SiteSuggestion;
import 'package:webspace/screens/settings.dart';
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/icon_png_export.dart';
import 'package:webspace/screens/inappbrowser.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/screens/webspace_detail.dart';
import 'package:webspace/widgets/stats_banner.dart';
import 'package:webspace/widgets/find_toolbar.dart';
import 'package:webspace/widgets/url_bar.dart';
import 'package:webspace/demo_data.dart' show seedDemoData, isDemoMode;
import 'package:webspace/services/image_cache_service.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_crypto.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/container_cookie_manager.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/services/site_activation_engine.dart';
import 'package:webspace/services/site_data_clear_engine.dart';
import 'package:webspace/services/site_lifecycle_engine.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/webview_state_secure_storage.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/services/startup_restore_engine.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/shortcut_service.dart';
import 'package:webspace/services/background_task_service.dart';
import 'package:webspace/services/share_intent_service.dart';
import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/services/link_intent_dispatch_engine.dart';
import 'package:webspace/screens/link_handling_settings.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/trusted_hosts_service.dart';
import 'package:webspace/services/notification_service.dart';
import 'package:webspace/services/proxy_conflict_engine.dart';
import 'package:webspace/services/suggested_sites_service.dart' as suggested_sites;
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/utils/url_utils.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webspace/widgets/download_button.dart';
import 'package:webspace/widgets/external_url_prompt.dart';
import 'package:webspace/widgets/root_messenger.dart';
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

// Accent colors
const Color _accentBlue = Color(0xFF6B8DD6);
const Color _accentGreen = Color(0xFF7be592);
const Color _accentPurple = Color(0xFF9B7BD6);
const Color _accentOrange = Color(0xFFE59B5B);
const Color _accentRed = Color(0xFFD66B6B);
const Color _accentPink = Color(0xFFD66BA8);
const Color _accentTeal = Color(0xFF5BC4C4);
const Color _accentYellow = Color(0xFFD6C86B);

// Get accent color from AccentColor enum
/// Build a ColorScheme that preserves the full saturation of [accent].
/// Uses fromSeed only for neutral surface/background colors, then overrides
/// all accent-derived roles so nothing gets desaturated by Material 3's HCT.
ColorScheme _buildAccentColorScheme(Color accent, Brightness brightness) {
  final bool isLight = brightness == Brightness.light;
  final hsl = HSLColor.fromColor(accent);

  // Container: a tinted but lighter/darker version of the accent
  final primaryContainer = isLight
      ? hsl.withLightness((hsl.lightness * 0.3 + 0.7).clamp(0.80, 0.92)).withSaturation((hsl.saturation * 0.8).clamp(0.0, 1.0)).toColor()
      : hsl.withLightness((hsl.lightness * 0.35).clamp(0.12, 0.25)).withSaturation((hsl.saturation * 0.8).clamp(0.0, 1.0)).toColor();

  final onPrimaryContainer = isLight
      ? hsl.withLightness(0.15).toColor()
      : hsl.withLightness(0.90).toColor();

  // Use fromSeed as base for surface/neutral colors only
  final base = ColorScheme.fromSeed(seedColor: accent, brightness: brightness);

  return base.copyWith(
    primary: accent,
    onPrimary: isLight ? Colors.white : Colors.black,
    primaryContainer: primaryContainer,
    onPrimaryContainer: onPrimaryContainer,
    secondary: accent,
    onSecondary: isLight ? Colors.white : Colors.black,
    secondaryContainer: primaryContainer,
    onSecondaryContainer: onPrimaryContainer,
  );
}

Color _accentColorToColor(AccentColor accentColor) {
  switch (accentColor) {
    case AccentColor.blue:
      return _accentBlue;
    case AccentColor.green:
      return _accentGreen;
    case AccentColor.purple:
      return _accentPurple;
    case AccentColor.orange:
      return _accentOrange;
    case AccentColor.red:
      return _accentRed;
    case AccentColor.pink:
      return _accentPink;
    case AccentColor.teal:
      return _accentTeal;
    case AccentColor.yellow:
      return _accentYellow;
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

// extractDomain and getNormalizedDomain are imported from web_view_model.dart

// Cache for page titles
final Map<String, String?> _pageTitleCache = {};

// Get page title by parsing HTML (fallback for platforms without native title support)
Future<String?> getPageTitle(String url) async {
  // Check cache first
  if (_pageTitleCache.containsKey(url)) {
    return _pageTitleCache[url];
  }

  try {
    final response = await http.get(Uri.parse(url)).timeout(
      Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Page fetch timeout'),
    );

    if (response.statusCode == 200) {
      html_dom.Document document = html_parser.parse(response.body);
      final titleElement = document.querySelector('title');
      if (titleElement != null) {
        final title = titleElement.text.trim();
        if (title.isNotEmpty) {
          _pageTitleCache[url] = title;
          return title;
        }
      }
    }
  } catch (e) {
    // Silently handle errors
  }

  _pageTitleCache[url] = null;
  return null;
}

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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Clear image cache on app upgrade
  await ImageCacheService.clearCacheOnUpgrade();

  // Imported HTML files are the only copy of user-supplied content,
  // so they live in their own persistent store and survive upgrades.
  // Cached fetched-page snapshots stay in HtmlCacheService (re-fetchable,
  // safe to drop on upgrade).
  await HtmlImportStorage.instance.initialize();

  // Initialize HTML cache (clears on app upgrade). The pre-wipe hook
  // copies imports left in the legacy cache (from versions before the
  // import store existed) into HtmlImportStorage before they're nuked.
  await HtmlCacheService.instance.initialize(
    beforeUpgradeWipe: _migrateFileImportsToStorage,
  );

  // Initialize favicon URL cache
  await FaviconUrlCache.initialize();

  // Initialize ClearURLs service (loads cached rules from disk)
  await ClearUrlService.instance.initialize();

  // Initialize DNS block service (loads cached blocklist from disk)
  await DnsBlockService.instance.initialize();

  // Load timezone-polygon dataset if previously downloaded. Lookups are
  // synchronous so the per-site shim builder needs the data ready before
  // it runs. Missing/empty cache is fine — the "From picked location"
  // dropdown option just stays disabled.
  await TimezoneLocationService.instance.loadFromCacheIfPresent();

  // Initialize native interceptor bridge for sub-resource DNS + ABP
  // blocking and LocalCDN serving (Android). The Dart shouldInterceptRequest
  // callback only fires for main-document navigations on modern Chromium
  // WebView, so everything per-subresource has to go through the native
  // path.
  WebInterceptNative.initialize();
  // Disable network loads from any service worker registered by a
  // visited site. Service workers stay alive across page navigations
  // (they're tied to the origin, not the document), and on Android
  // System WebView there are open chromium regressions where a SW's
  // fetch-handler tasks race against parent-page navigation and trip
  // MiraclePtr's dangling-raw_ptr detector on the IO thread. We
  // never use service-worker functionality ourselves (no offline
  // pages, no push), so blocking SW network is no functional loss.
  if (Platform.isAndroid) {
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
  if (DnsBlockService.instance.hasBlocklist) {
    await WebInterceptNative.sendDnsDomains(
        DnsBlockService.instance.blockedDomains);
  }

  // Initialize content blocker service (loads cached filter lists from disk
  // and spins up the adblock-rust engine; native Android sub-resource
  // interceptor is fed the rules text from inside the service).
  await ContentBlockerService.instance.initialize();

  // Keep the DNS-side bloom in sync when the DNS list changes; ABP rules
  // are owned end-to-end by the engine, so no Dart-side push is needed
  // for them anymore.
  DnsBlockService.instance.addBlocklistChangedListener(() {
    WebInterceptNative.sendDnsDomains(DnsBlockService.instance.blockedDomains);
  });
  ContentBlockerService.instance.addRulesChangedListener(() {
    DnsBlockService.instance.invalidateMergedBloom();
  });

  // Initialize LocalCDN service (loads cache index from disk)
  await LocalCdnService.instance.initialize();

  // Seed the native interceptor with CDN patterns + the current cache
  // index, and keep its copy in sync whenever the cache changes.
  await WebInterceptNative.sendCdnPatterns(
      LocalCdnService.instance.cdnPatternStrings);
  await WebInterceptNative.sendCdnCacheIndex(
      LocalCdnService.instance.cacheIndexSnapshot);
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
  await PlatformInfo.initialize();

  // Prime ConnectivityService.lastKnownOnline before the first webview
  // is constructed. The offline cached-HTML render path needs a sync
  // answer to decide between live URL and `initialData` at construction
  // time — without this the first webview always sees `null` and
  // defaults to live load even when the device is offline.
  await ConnectivityService.instance.primeLastKnownOnline();

  // Populate HtmlCacheService._memoryCache before the first webview
  // is built. `WebSpacePage.build` reads cached HTML synchronously
  // via `getHtmlSync(siteId)` to feed the cached-HTML render path,
  // and the only sites that ever land in `_memoryCache` are the ones
  // that have been previously cached on disk for this user. Eating
  // the decryption cost up front (rather than lazy-loading on first
  // miss) lets the build path stay synchronous, which is what
  // `InAppWebViewInitialData` requires — chromium needs the bytes
  // before navigation starts, not after an awaited disk read.
  await HtmlCacheService.instance.preloadCache();
  // Same reasoning as the line above, for imported HTML.
  await HtmlImportStorage.instance.preloadAll();

  // Load the global outbound proxy from SharedPreferences. Synchronous
  // callers (flutter_map TileProvider, per-site DEFAULT fallthrough) read
  // GlobalOutboundProxy.current after this.
  await GlobalOutboundProxy.initialize();
  // Hydrate user-approved TLS exceptions so a self-signed site the user
  // already trusted in a previous session loads without a prompt — and
  // so the Dart-side `HttpClient.badCertificateCallback` (favicon
  // probes, downloads, …) sees the same pinned set.
  await TrustedHostsService.instance.initialize();
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
  Widget build(BuildContext context) {
    final Color accentColor = _accentColorToColor(_themeSettings.accentColor);
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      theme: ThemeData(
        colorScheme: _buildAccentColorScheme(accentColor, Brightness.light),
        scaffoldBackgroundColor: Color(0xFFFFFFFF),
      ),
      darkTheme: ThemeData(
        colorScheme: _buildAccentColorScheme(accentColor, Brightness.dark),
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

/// Records which site IDs and webspace IDs belong to one open archive
/// handle, so closing one archive can remove exactly its rows from the
/// parallel runtime collections without touching others.
class _ArchiveSlice {
  _ArchiveSlice({
    required this.siteIds,
    required this.webspaceIds,
    required this.containerIds,
  });
  final Set<String> siteIds;
  final Set<String> webspaceIds;
  /// Opaque container identifiers owned by this archive — passed to
  /// `ContainerNative.deleteContainer` on close so archive-tier
  /// container directories don't survive past the close call (ARCH-007).
  final Set<String> containerIds;
}

class _WebSpacePageState extends State<WebSpacePage> with WidgetsBindingObserver {
  int? _currentIndex;
  final List<WebViewModel> _webViewModels = [];
  AppThemeSettings _themeSettings = const AppThemeSettings();
  final CookieManager _cookieManager = CookieManager();
  final CookieSecureStorage _cookieSecureStorage = CookieSecureStorage();
  final ProxyPasswordSecureStorage _proxyPasswordStorage =
      ProxyPasswordSecureStorage();
  late final CookieIsolationEngine _cookieIsolation = CookieIsolationEngine(
    cookieManager: _cookieManager,
    storage: _cookieSecureStorage,
  );
  late final ContainerIsolationEngine _containerIsolation =
      ContainerIsolationEngine(containerNative: ContainerNative.instance);

  /// Orchestrates the passphrase-gated archive layer (spec
  /// `openspec/specs/archive/spec.md`). Constructed eagerly but the slot
  /// pool is lazily initialised inside the orchestrator on first
  /// open/create so users who never touch the feature pay no
  /// `flutter_secure_storage` write at startup (ARCH-001).
  final Archive _archive = Archive();

  /// Tracks which `WebViewModel`s in [_webViewModels] belong to each
  /// open archive handle. Archive sites live in the same list as
  /// app-tier sites with `isArchiveTier=true`; the persistence path in
  /// [_saveWebViewModels] filters by that flag so archive state never
  /// enters SharedPreferences. Closing one archive removes exactly its
  /// rows by `siteId` lookup against this slice.
  final Map<ArchiveHandle, _ArchiveSlice> _archiveSlices = {};

  /// Container-mode cookie manager. Non-null when `_useContainers ==
  /// true`; null in legacy mode (the existing `_cookieManager` covers
  /// that path). Resolved alongside `_useContainers` in
  /// `_restoreAppState` so the branches stay tied to the same
  /// runtime decision. The WebViewModel cookie-blocking path branches
  /// on `containerCookieManager != null`.
  late final ContainerCookieManager? _containerCookieManager;

  /// Cached result of [ContainerNative.isSupported] resolved during
  /// `_restoreAppState`. When true, the app uses native per-site
  /// containers (Android System WebView 110+, iOS 17+, macOS 14+);
  /// same-base-domain sites can be loaded concurrently and the
  /// capture-nuke-restore cycle in [_restoreCookiesForSite] /
  /// [_unloadSiteForDomainSwitch] / preDelete cleanup is skipped. When
  /// false (legacy Android, older Apple, Linux/desktop) the app falls
  /// through to the existing [CookieIsolationEngine].
  bool _useContainers = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _isBackHandling = false;
  bool _isFindVisible = false;
  bool _isFullscreen = false; // Runtime fullscreen state (hides appBar, tabStrip, system UI)
  // Toggled by _nudgeSurfaceRepaint to apply a transient 1px inset that
  // forces Android hybrid-composition platform views to recomposite after
  // the activity is recreated (shortcut/resume). Always false in steady state.
  bool _repaintNudge = false;
  /// When true, a full-screen opaque mask covers every webview so the
  /// OS task-switcher / recents snapshot doesn't capture archive-tier
  /// content (ARCH-009). Set on `inactive`/`paused` when at least one
  /// archive is open; cleared on `resumed`. Apps without an open
  /// archive get the normal screenshot as before — this is a purely
  /// additive guard.
  bool _maskBackground = false;
  bool _showUrlBar = false;
  bool _showTabStrip = false;
  bool _tabStripInFullscreen = false;
  bool _linkHandlingEnabled = true;
  bool _showStatsBanner = true;

  // Webspace-related state
  final List<Webspace> _webspaces = [];
  String? _selectedWebspaceId;
  int _selectWebspaceVersion = 0;
  int _setCurrentIndexVersion = 0;
  Completer<void>? _webspaceSwitchCompleter;

  // Index currently being activated by an in-flight `_setCurrentIndex`
  // call, or null when no activation is in progress. Read by
  // `_handleMemoryPressure` so an OS pressure event during a
  // re-activation can't dispose the soon-to-be-active site (which
  // would silently wipe its state — the IndexedStack would re-create
  // a fresh webview on next paint, losing scroll/URL/session).
  int? _activationInFlightIndex;

  // Drops concurrent `_handleMemoryPressure` invocations. The OS may
  // fire `didHaveMemoryPressure` repeatedly under sustained pressure;
  // the first handler runs to completion, then the next event picks up
  // the new state. Without this, in legacy (non-container) mode the
  // capture-then-dispose await window lets two handlers pick the same
  // victim and double-write its captured cookies to storage.
  bool _isHandlingMemoryPressure = false;

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
  final WebViewStateStorage _stateStorage = SecureWebViewStateStorage();

  // Track which webview indices have been loaded (for lazy loading)
  // Only webviews in this set will be created - others remain as placeholders
  final Set<int> _loadedIndices = {};

  // Configurable suggested sites
  List<SiteSuggestion> _suggestedSites = [];

  // Global user scripts (shared across all sites)
  List<UserScriptConfig> _globalUserScripts = [];

  Timer? _foregroundPollTimer;

  // Guards lifecycle pause/resume against rapid state transitions.
  // Without this, a quick inactive→resumed sequence could let the resume
  // platform call complete before the pause call, leaving the webview stuck.
  Future<void>? _lifecyclePauseFuture;

  // Tracks which sites already have a pinned home shortcut, so the
  // "Home Shortcut" menu item can hide for sites that are already pinned.
  Set<String> _pinnedSiteIds = const <String>{};

  // HS-006/007: iOS 16+ / macOS 13+ expose home shortcuts via App Intents.
  // Probed once at startup so the menu can render synchronously without a
  // future on every overflow-menu open.
  bool _appIntentsSupported = false;

  // HS-011 (Android): a pinned shortcut's intent carries only the random
  // siteId. Once the owning site is deleted (delete+recreate) that id is opaque,
  // so we keep a `siteId -> url` ledger — recorded for pinned sites, pruned to
  // the pinned/current set — to drive the domain fallback.
  static const _kShortcutUrlLedgerKey = 'shortcutUrlLedger';
  Map<String, String> _shortcutUrlLedger = {};

  // HS-011 (iOS): iOS can't enumerate home-screen tiles, so the Android ledger
  // approach can't GC. Instead we keep a bounded tombstone list of deleted
  // `{siteId, label, url}` and sync it to the App Group: `entities(for:)`
  // resolves a deleted-site Shortcut from live ∪ tombstones (so it still
  // launches and routes by domain), while the picker stays live-only (HS-009).
  static const _kShortcutTombstonesKey = 'shortcutTombstones';
  List<Map<String, String>> _shortcutTombstones = [];

  // When the user confirms a rebind, the choice is remembered here (stale
  // siteId -> live siteId) and persisted so later taps of the same shortcut
  // resolve silently. Machine state derived from shortcut activity, not a user
  // setting: excluded from settings backups.
  static const _kShortcutRemapKey = 'shortcutSiteRemap';
  Map<String, String> _shortcutSiteRemap = {};

  // A cold-launch shortcut that needs a confirm/create prompt can't show a
  // dialog mid-restore (no UI yet); it's parked here and handled on the first
  // post-frame. Guards re-entry while a prompt is on screen.
  LaunchResolution? _pendingShortcutResolution;
  bool _handlingShortcutPrompt = false;

  StreamSubscription<TrustedHostEntry>? _untrustSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreAppState();
    _refreshPinnedSiteIds();
    _probeAppIntents();
    // When a pin is revoked while the site is still rendered, the
    // existing webview keeps showing the cached DOM and the live
    // reload may serve from WebView HTTP cache without doing a fresh
    // TLS handshake. The user expects revocation to "take effect"
    // immediately, so wipe the per-site HTML cache and force-reload
    // any loaded matching webview. The reload re-establishes TLS,
    // the trust callback finds no pin, and the prompt fires again.
    _untrustSub =
        TrustedHostsService.instance.untrustChanges.listen(_onPinRevoked);
  }

  Future<void> _onPinRevoked(TrustedHostEntry entry) async {
    LogService.instance.log(
      'TLS',
      '_onPinRevoked fired for ${entry.host}:${entry.port} '
          '(loaded=${_loadedIndices.toList()..sort()}, '
          'webViewModels=${_webViewModels.length})',
      sensitivity: LogSensitivity.sensitive,
    );
    final host = entry.host.toLowerCase();
    // Android's cert-acceptance state lives in multiple layers:
    //   1. App-level SSL preferences table (WebView.clearSslPreferences) —
    //      where `handler.proceed()` decisions are kept. Doc-claimed
    //      shared across WebViews; we call on the matching host's
    //      controller first if available since some Android versions
    //      key this per-instance despite docs.
    //   2. Chromium network-service HTTP cache + connection pool —
    //      nuked by `InAppWebViewController.clearAllCache(includeDiskFiles: true)`,
    //      a static call that flushes the process-shared cache.
    //   3. Per-site container storage (cookies, localStorage, IDB, SW,
    //      service-worker registrations) — wiped in the loop below.
    // We hit all three because empirically just (1)+(3) doesn't stop
    // the network service from reusing a remembered "trusted" verdict.
    WebViewController? matching;
    WebViewController? anyLive;
    for (final i in _loadedIndices) {
      if (i >= _webViewModels.length) continue;
      final m = _webViewModels[i];
      final c = m.controller;
      if (c == null) continue;
      anyLive ??= c;
      final uri = Uri.tryParse(m.initUrl);
      if (uri == null) continue;
      if (uri.host.toLowerCase() != host) continue;
      final port = uri.hasPort
          ? uri.port
          : (uri.scheme == 'https' ? 443 : (uri.scheme == 'http' ? 80 : 0));
      if (port == entry.port) {
        matching ??= c;
      }
    }
    final preferred = matching ?? anyLive;
    if (preferred != null) {
      try {
        await preferred.nativeController.clearSslPreferences();
        LogService.instance.log(
          'TLS',
          'clearSslPreferences() completed for ${entry.host}:${entry.port} '
              '(via ${matching != null ? "matching-host" : "any-loaded"} controller)',
          sensitivity: LogSensitivity.sensitive,
        );
      } catch (e) {
        LogService.instance.log('TLS',
            'clearSslPreferences() failed: $e',
            level: LogLevel.error);
      }
    } else {
      LogService.instance.log(
        'TLS',
        'no loaded controller to call clearSslPreferences() for '
            '${entry.host}:${entry.port} — SSL prefs table may retain stale '
            'host decisions until next app restart',
        sensitivity: LogSensitivity.sensitive,
      );
    }
    // Process-wide cache flush. Static — no instance needed; affects
    // the Chromium network service shared by all WebViews + Profiles.
    try {
      await inapp.InAppWebViewController.clearAllCache(includeDiskFiles: true);
      LogService.instance.log(
        'TLS',
        'clearAllCache(disk=true) completed for revoke of '
            '${entry.host}:${entry.port}',
        sensitivity: LogSensitivity.sensitive,
      );
    } catch (e) {
      LogService.instance.log('TLS',
          'clearAllCache failed: $e',
          level: LogLevel.error);
    }
    if (!mounted) return;
    bool changed = false;
    final wipedSiteIds = <String>[];
    for (var i = 0; i < _webViewModels.length; i++) {
      final model = _webViewModels[i];
      final uri = Uri.tryParse(model.initUrl);
      if (uri == null) continue;
      if (uri.host.toLowerCase() != host) continue;
      final port = uri.hasPort
          ? uri.port
          : (uri.scheme == 'https' ? 443 : (uri.scheme == 'http' ? 80 : 0));
      if (port != entry.port) continue;
      HtmlCacheService.instance.deleteCache(model.siteId);
      if (_loadedIndices.contains(i)) {
        model.disposeWebView();
        _loadedIndices.remove(i);
        changed = true;
      }
      wipedSiteIds.add(model.siteId);
    }
    // `WebView.clearSslPreferences()` clears the app-level table of
    // user "proceed" decisions but does NOT clear the network
    // service's per-host TLS state — once the network process has
    // accepted a cert during the original handshake, subsequent
    // connections to the same host reuse that decision via the
    // connection pool / TLS session cache, never re-firing
    // `onReceivedSslError`. Clearing the per-site container drops the
    // network service's session state for those hosts along with
    // cookies/localStorage/IndexedDB — acceptable for self-signed
    // hosts where the user has no meaningful session, and the in-app
    // pin had to be approved again for the site to load anyway.
    if (wipedSiteIds.isNotEmpty) {
      int cleared = 0;
      for (final siteId in wipedSiteIds) {
        if (await _containerIsolation.clearForSite(siteId)) cleared++;
      }
      LogService.instance.log(
        'TLS',
        'cleared $cleared of ${wipedSiteIds.length} container(s) after '
            'revoke of ${entry.host}:${entry.port}',
        sensitivity: LogSensitivity.sensitive,
      );
    }
    if (changed && mounted) setState(() {});
  }

  Future<void> _probeAppIntents() async {
    final supported = await ShortcutService.isAppIntentsSupported();
    if (!mounted || supported == _appIntentsSupported) return;
    setState(() {
      _appIntentsSupported = supported;
    });
  }

  /// HS-004 / HS-005: gate the "Home Shortcut" menu item. On Android, hide
  /// once the site already has a pinned shortcut (HS-005). On iOS 16+ /
  /// macOS 13+ the item is always visible (no API to detect home-screen /
  /// Shortcuts.app pinning). Other platforms hide it.
  bool _isHomeShortcutMenuVisible(int index) {
    if (index >= _webViewModels.length) return false;
    // ARCH-006: archive-tier sites must not get OS-level pinned
    // shortcuts (visible in the launcher / Shortcuts.app indefinitely).
    if (_webViewModels[index].isArchiveTier) return false;
    if (Platform.isAndroid) {
      // Treat a site an orphaned tile was rebound to (HS-011) as already
      // pinned — it's reachable via that tile, so don't offer a second one.
      final effective = ShortcutPinState.effectivePinnedSiteIds(
        pinnedSiteIds: _pinnedSiteIds,
        rememberedRemap: _shortcutSiteRemap,
      );
      return !effective.contains(_webViewModels[index].siteId);
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return _appIntentsSupported;
    }
    return false;
  }

  /// Routes the "Home Shortcut" menu tap. Android pins directly; iOS shows
  /// the HS-008 instructional dialog then deep-links to Shortcuts.app.
  Future<void> _handleAddToHome(WebViewModel model) async {
    if (Platform.isAndroid) {
      final faviconUrl = FaviconUrlCache.get(model.initUrl);
      // Rasterize the favicon to PNG here (HS-003): Android's BitmapFactory
      // can't decode SVG, so an SVG favicon would otherwise fall back to the
      // WebSpace app icon. exportIconAsPng also normalizes ICO/PNG and applies
      // the site's proxy. iconUrl stays as a native-side fallback if it fails.
      final iconBytes = await exportIconAsPng(
        model.initUrl,
        resolvedIconUrl: faviconUrl,
        proxy: model.proxySettings,
      );
      if (!mounted) return;
      await ShortcutService.pinShortcut(
        siteId: model.siteId,
        label: model.name,
        iconBytes: iconBytes,
        iconUrl: iconBytes == null ? faviconUrl : null,
      );
      // HS-011: remember this id's url now so a later delete+recreate can be
      // routed by domain. _refreshPinnedSiteIds also reconciles on resume.
      await _recordShortcutLedger(model.siteId, model.initUrl);
      return;
    }
    if ((Platform.isIOS || Platform.isMacOS) && _appIntentsSupported) {
      final addStep = Platform.isMacOS
          ? 'then add it to the Dock or run it from the menu bar.'
          : 'then tap "Add to Home Screen" from the share menu.';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
              Platform.isMacOS ? 'Add a Shortcut' : 'Add to Home Screen'),
          content: Text(
            '${Platform.isMacOS ? "macOS" : "iOS"} adds WebSpace sites through '
            'the Shortcuts app.\n\n'
            'In Shortcuts, find the "Open Site" action under WebSpace, pick '
            '"${model.name}", $addStep',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Open Shortcuts'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await ShortcutService.pinShortcut(
          siteId: model.siteId,
          label: model.name,
        );
      }
    }
  }

  Future<void> _refreshPinnedSiteIds() async {
    final ids = await ShortcutService.getPinnedSiteIds();
    if (!mounted) return;
    // HS-011: keep the url ledger in step with the launcher — record urls for
    // pinned sites that still exist, drop entries no longer reachable. Runs on
    // initState and every resume, so it catches in-app pins and out-of-app
    // removals. Android-only (iOS getPinnedSiteIds is always empty).
    await _reconcileShortcutLedger(ids);
    if (!mounted) return;
    if (ids.length == _pinnedSiteIds.length &&
        ids.containsAll(_pinnedSiteIds)) {
      return;
    }
    setState(() {
      _pinnedSiteIds = ids;
    });
  }

  @override
  void dispose() {
    _foregroundPollTimer?.cancel();
    _untrustSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeTextScaleFactor() {
    final zoom = WebViewFactory.systemTextZoomPercent();
    for (final i in _loadedIndices) {
      if (i < _webViewModels.length) {
        _webViewModels[i].controller?.setTextZoom(zoom);
      }
    }
  }

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
    if (_isHandlingMemoryPressure) return;
    _isHandlingMemoryPressure = true;
    try {
      // Protect both the currently-active site and any site in the
      // middle of being activated by an in-flight `_setCurrentIndex`.
      // Without the in-flight guard, a re-activation of an already-
      // loaded site could be racing with this handler — disposing the
      // soon-to-be-active webview silently wipes its state.
      final states = <int, SiteLifecycleState>{};
      for (final i in _loadedIndices) {
        if (i < 0 || i >= _webViewModels.length) continue;
        states[i] = _webViewModels[i].lifecycleState;
      }
      final victim = SiteLifecyclePromotionEngine.pickPromotionTarget(
        loadedIndices: _loadedIndices,
        states: states,
        priorityOf: _siteRetentionPriority,
      );
      if (victim == null) return;
      if (victim < 0 || victim >= _webViewModels.length) return;
      final model = _webViewModels[victim];
      final from = model.lifecycleState;
      final to = SiteLifecyclePromotionEngine.nextState(from);
      if (to == null) return;

      LogService.instance.log(
        'SiteUnload',
        'Memory pressure — promoting site $victim "${model.name}": '
            '${from.name} → ${to.name}',
        level: LogLevel.warning,
        sensitivity: LogSensitivity.sensitive,
      );

      switch (to) {
        case SiteLifecycleState.cacheCleared:
          // live → cacheCleared: drop the in-memory cache. Webview
          // stays loaded; tab state intact. Frees decoded image
          // cache + HTTP response cache.
          await model.clearWebViewCache();
          if (!mounted) return;
          model.lifecycleState = SiteLifecycleState.cacheCleared;
        case SiteLifecycleState.savedForRestore:
          // cacheCleared → savedForRestore: capture state, dispose
          // webview, drop from _loadedIndices. Frees the renderer
          // process. Re-activation hydrates from storage via the
          // model's _pendingRestoreState hook.
          //
          // Routes through _unloadSiteForOtherReason so the legacy
          // cookie capture (when not in container mode) runs too;
          // _captureStateForRestore inside that helper is what
          // updates the lifecycleState to savedForRestore.
          await _unloadSiteForOtherReason(victim);
        case SiteLifecycleState.resident:
          // Promotion can never go back to live — defensive.
          break;
      }
      if (!mounted) return;
      setState(() {});
    } finally {
      _isHandlingMemoryPressure = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Mask any visible archive content the moment focus leaves the app
    // (well before `paused`) so the OS snapshot for the task switcher
    // / recents preview never captures an archive-tier site. False
    // positives (popup dialog, app-switcher peek) cost a brief visual
    // overlay flash, not data — acceptable trade for the snapshot
    // guarantee. The mask is only armed while at least one archive is
    // open; the no-archive code path is unchanged.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_archiveSlices.isNotEmpty && !_maskBackground) {
        setState(() => _maskBackground = true);
      }
    }
    // Only treat `paused` as a real backgrounding event. `inactive` fires for
    // any transient focus loss — native <select> popup dialog, app-switcher
    // peek, system permission prompt, incoming call on iOS — where pausing
    // the WebView would dismiss the popup or the JS thread that the user is
    // actively interacting with. See issue #308.
    if (state == AppLifecycleState.paused) {
      _foregroundPollTimer?.cancel();
      _foregroundPollTimer = null;
      // AOH-006: URL-ephemeral sites (alwaysOpenHome / incognito) revert to
      // their initUrl when the app leaves the foreground, so reopening lands
      // on home. This is the only warm-resume reset — fromJson handles cold
      // start. In-app site switches never trigger it; only app close does.
      final activeWentHome = _resetAlwaysOpenHomeForAppClose();
      if (activeWentHome && mounted) {
        // The active webview was disposed above. Mark dirty so the rebuild
        // recreates it at initUrl once frames resume.
        setState(() {});
      }
      if (!activeWentHome &&
          _currentIndex != null && _currentIndex! < _webViewModels.length && _loadedIndices.contains(_currentIndex)) {
        if (!_webViewModels[_currentIndex!].effectiveNotificationsEnabled) {
          _lifecyclePauseFuture = _webViewModels[_currentIndex!].pauseForAppLifecycle();
        }
        final activeIdx = _currentIndex!;
        unawaited(_captureStateBytes(_webViewModels[activeIdx]));
      }
      // iOS: open a ~30s background-task window so notification webviews
      // can flush in-flight setTimeouts before iOS suspends the process.
      // Android has no equivalent without a foreground service; it relies
      // on the OS's implicit grace and the notif early-return in
      // WebViewModel.pauseWebView so the renderer keeps ticking briefly.
      if (_anyNotificationSites()) {
        unawaited(BackgroundTaskService.instance.beginGracePeriod());
      }
      // Both iOS and Android: ensure the periodic refresh is scheduled
      // before the process gets backgrounded.
      unawaited(_updateBackgroundRefreshSchedule());
    } else if (state == AppLifecycleState.resumed) {
      if (_maskBackground) {
        setState(() => _maskBackground = false);
      }
      _startForegroundPollTimer();
      // Resume + shortcut + share are sequenced in _onResumed: the
      // app-lifecycle resume must finish before a shortcut intent switches
      // sites, or the two race over _currentIndex and webview pause/resume.
      unawaited(_onResumed());
      // Release the iOS grace-period background task. Foregrounded again,
      // so we don't need the extension; iOS auto-ends after the expiration
      // handler fires, but explicit end is cleaner.
      unawaited(BackgroundTaskService.instance.endGracePeriod());
      // Re-evaluate (idempotent): if a memory-pressure handler unloaded
      // every notif site while we were backgrounded the schedule should
      // be torn down; if any are still loaded the schedule submission
      // is a no-op.
      unawaited(_updateBackgroundRefreshSchedule());
    }
  }

  bool _isResuming = false;

  /// Run the resume sequence in a fixed order. The app-lifecycle resume
  /// (drains the in-flight `pauseForAppLifecycle`, resumes process-global JS
  /// timers and the active site) MUST complete before a pinned-shortcut
  /// intent is handled: both mutate `_currentIndex` and pause/resume
  /// webviews, and the previous fire-and-forget pair let the shortcut's site
  /// switch race the resume. Sequencing also lets a single surface repaint
  /// run once, against the final visible site, instead of two `_repaintNudge`
  /// loops interleaving. Re-entry guarded in case `resumed` fires twice.
  Future<void> _onResumed() async {
    if (_isResuming) return;
    _isResuming = true;
    try {
      await _resumeAfterLifecyclePause();
      if (!mounted) return;
      await _handleShortcutIntent();
      if (!mounted) return;
      await _handleShareIntent();
      if (!mounted) return;
      // Pinned shortcuts may have been added (via the launcher's pin dialog)
      // or removed (by the user from the launcher) while we were backgrounded.
      _refreshPinnedSiteIds();
      // One relayout against the now-final visible site, in case the activity
      // was recreated and the platform-view surface came back blank. See
      // PAUSE-015.
      _nudgeSurfaceRepaint();
    } finally {
      _isResuming = false;
    }
  }

  Future<void> _resumeAfterLifecyclePause() async {
    if (_lifecyclePauseFuture != null) {
      await _lifecyclePauseFuture;
      _lifecyclePauseFuture = null;
    }
    if (_currentIndex != null && _currentIndex! < _webViewModels.length && _loadedIndices.contains(_currentIndex)) {
      if (!_webViewModels[_currentIndex!].effectiveNotificationsEnabled) {
        await _webViewModels[_currentIndex!].resumeFromAppLifecycle();
      }
      unawaited(_probeRendererAndRecover(_webViewModels[_currentIndex!]));
    }
    // Re-apply fullscreen system UI mode after resume
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  /// Probe a just-resumed / just-activated webview's renderer and recreate it
  /// if the renderer process is gone. Covers the two memory-reclaim outcomes
  /// the user hits most when returning to a backgrounded site (typically via
  /// a pinned shortcut, which can recreate the activity and re-attach every
  /// platform-view surface):
  ///
  ///   - iOS: WKWebView's content process was jettisoned while this webview
  ///     was offscreen. `onWebContentProcessDidTerminate` does not reliably
  ///     fire for a webview that was not on screen at termination, so the
  ///     event-driven recovery (PAUSE-013) never runs — the page comes back
  ///     blank with no signal. `evaluateJavascript` against a dead content
  ///     process throws, surfaced here as a null probe result.
  ///   - Android: the renderer is alive but the hybrid-composition surface
  ///     re-attached blank after an activity restart. Reading
  ///     `document.body.offsetHeight` forces a synchronous layout that
  ///     schedules the missing paint; the probe returns a number, so no
  ///     recreate happens — the read alone fixes the blank surface.
  ///
  /// A live renderer returns a number (0 / -1 / positive); only null means
  /// gone. Fire-and-forget; no-op when the model has no controller (a fresh
  /// first-load whose controller hasn't been created yet).
  Future<void> _probeRendererAndRecover(WebViewModel model) async {
    final controller = model.controller;
    if (controller == null) return;
    final result = await controller
        .evaluateJavascriptReturning('document.body ? document.body.offsetHeight : -1');
    if (!mounted) return;
    // identical() guard: a concurrent recreate may have already swapped the
    // controller out from under us — don't null a fresh one.
    if (rendererProbeIndicatesGone(result) && identical(model.controller, controller)) {
      LogService.instance.log(
        'WebView',
        'Renderer probe failed for "${model.name}" (siteId: ${model.siteId}) — recreating',
        level: LogLevel.warning,
      );
      model.handleRendererGone(didCrash: false);
    }
  }

  /// Android only: after the activity is recreated (a pinned-shortcut tap, or
  /// a resume that recreated the activity) the Flutter base surface and the
  /// hybrid-composition webview SurfaceView can come back without a paint —
  /// the page area and the strip behind the edge-to-edge status bar render
  /// black even though the page is alive. A relayout fixes it: that is what a
  /// device rotation / lock-unlock / tab switch does, all of which the user
  /// confirmed recover the screen. A JS `offsetHeight` read does not, because
  /// it relayouts web content, not the Android surface.
  ///
  /// Toggle a 1px body inset a few times over ~0.5s: each setState repaints
  /// the Flutter surface (status-bar strip, chrome) and each size flip forces
  /// the webview platform view to recomposite. Spread across several frames
  /// because the new surface may not be attached on the first frame after
  /// resume, which is why a single rebuild (e.g. the one in _setCurrentIndex)
  /// is not enough on its own.
  void _nudgeSurfaceRepaint() {
    if (!Platform.isAndroid) return;
    var ticks = 0;
    void tick() {
      if (!mounted || ticks >= 6) return;
      ticks++;
      setState(() => _repaintNudge = !_repaintNudge);
      Future.delayed(const Duration(milliseconds: 100), tick);
    }
    tick();
  }

  Future<void> _handleShortcutIntent() async {
    final launch = await ShortcutService.getLaunch();
    if (!mounted || launch == null) return;
    final url = launch.url ??
        _shortcutUrlLedger[launch.siteId] ??
        _tombstoneUrlFor(launch.siteId);
    LogService.instance.log(
      'Shortcut',
      'warm launch siteId=${launch.siteId} payloadUrl=${launch.url} '
          'resolvedUrl=$url',
      sensitivity: LogSensitivity.sensitive,
    );
    final resolution = StartupRestoreEngine.resolveLaunch(
      shortcutSiteId: launch.siteId,
      // iOS carries the url in the launch payload; Android pairs the id with
      // its url ledger. Fall back to the iOS tombstone url in case iOS handed
      // back a stale cached entity without a url.
      shortcutUrl: url,
      models: _webViewModels,
      rememberedRemap: _shortcutSiteRemap,
    );
    if (resolution is LaunchOpenSite) {
      await _openShortcutIndex(resolution.index);
    } else if (resolution is! LaunchNone) {
      await _applyInteractiveShortcut(resolution, coldLaunch: false);
    }
  }

  /// Look up a deleted site's url from the iOS tombstone list (HS-014), so a
  /// stale launch payload without a url can still route by domain.
  String? _tombstoneUrlFor(String siteId) {
    for (final t in _shortcutTombstones) {
      if (t['siteId'] == siteId) return t['url'];
    }
    return null;
  }

  /// Warm-tap switch to a resolved site: reset flagged siblings to home
  /// (HS-007), switch if not already active, persist. Does NOT reset the
  /// launched site's own currentUrl — a warm tap preserves the live session
  /// (HS-006); cold launch handles the initUrl reset separately.
  Future<void> _openShortcutIndex(int index) async {
    if (index < 0 || index >= _webViewModels.length) return;
    _resetAlwaysOpenHomeOnShortcut(index);
    if (index != _currentIndex) {
      await _setCurrentIndex(index);
      if (!mounted) return;
    }
    setState(() {});
    await _saveWebViewModels();
  }

  /// HS-011: drive the confirm/create prompt for a shortcut whose siteId no
  /// longer maps to a site. On confirm, remembers the rebind so future taps
  /// resolve directly via [_shortcutSiteRemap].
  Future<void> _applyInteractiveShortcut(
    LaunchResolution resolution, {
    required bool coldLaunch,
  }) async {
    if (_handlingShortcutPrompt) return;
    _handlingShortcutPrompt = true;
    try {
      if (resolution is LaunchConfirmExisting) {
        if (resolution.index < 0 ||
            resolution.index >= _webViewModels.length) {
          return;
        }
        final model = _webViewModels[resolution.index];
        final ok = await _showShortcutConfirm(
          title: 'Open site?',
          message:
              'This shortcut points to a site that no longer exists. Open '
              '"${model.getDisplayName()}" instead? It matches the same address.',
          confirmLabel: 'Open',
        );
        if (ok != true || !mounted) return;
        await _rememberShortcutRemap(resolution.shortcutSiteId, model.siteId);
        if (coldLaunch && model.currentUrl != model.initUrl) {
          model.currentUrl = model.initUrl;
        }
        await _openShortcutIndex(resolution.index);
      } else if (resolution is LaunchOfferCreate) {
        // No live site and no domain match: let the user reroute this handle to
        // any existing site or create a fresh one. Either choice is remembered
        // as a remap so the next tap resolves directly (HS-011/HS-014).
        final choice = await _showShortcutMissingChoice(resolution.url);
        if (choice == null || !mounted) return;
        if (choice == 'reroute') {
          final targetSiteId = await _pickSiteForShortcut();
          if (targetSiteId == null || !mounted) return;
          await _rememberShortcutRemap(resolution.shortcutSiteId, targetSiteId);
          final i =
              _webViewModels.indexWhere((m) => m.siteId == targetSiteId);
          if (i >= 0) await _openShortcutIndex(i);
          return;
        }
        final model = WebViewModel(
          initUrl: resolution.url,
          stateSetterF: () {
            if (mounted) setState(() {});
          },
        );
        final title = await getPageTitle(resolution.url);
        if (!mounted) return;
        if (title != null && title.isNotEmpty) {
          model.name = title;
          model.pageTitle = title;
        }
        // _registerNewSite adds, activates, applies theme, and persists.
        await _registerNewSite(model);
        if (!mounted) return;
        await _rememberShortcutRemap(resolution.shortcutSiteId, model.siteId);
      } else if (resolution is LaunchOfferReroute) {
        // Handle resolved to a placeholder (site removed, no url known). Let the
        // user point it at an existing site; remembered so the next tap is direct.
        final targetSiteId = await _pickSiteForShortcut();
        if (targetSiteId == null || !mounted) return;
        await _rememberShortcutRemap(resolution.shortcutSiteId, targetSiteId);
        final i = _webViewModels.indexWhere((m) => m.siteId == targetSiteId);
        if (i >= 0) await _openShortcutIndex(i);
      }
    } finally {
      _handlingShortcutPrompt = false;
    }
  }

  Future<bool?> _showShortcutConfirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  /// Tap-time chooser for a handle whose site is gone and that has no domain
  /// match (HS-011 step 3). Returns 'reroute' | 'create' | null (dismissed).
  Future<String?> _showShortcutMissingChoice(String url) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Shortcut site missing'),
        content: Text(
          'This shortcut points to a site that no longer exists. Open another '
          'site instead, or create a new one for $url?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('reroute'),
            child: const Text('Open another'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('create'),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _rememberShortcutRemap(
    String shortcutSiteId,
    String resolvedSiteId,
  ) async {
    if (_shortcutSiteRemap[shortcutSiteId] == resolvedSiteId) return;
    _shortcutSiteRemap[shortcutSiteId] = resolvedSiteId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kShortcutRemapKey, jsonEncode(_shortcutSiteRemap));
  }

  void _loadShortcutRemap(SharedPreferences prefs) {
    _shortcutSiteRemap = _decodeStringMap(prefs.getString(_kShortcutRemapKey));
    _shortcutUrlLedger = _decodeStringMap(prefs.getString(_kShortcutUrlLedgerKey));
    _shortcutTombstones = _decodeTombstones(prefs.getString(_kShortcutTombstonesKey));
  }

  List<Map<String, String>> _decodeTombstones(String? raw) {
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return [
          for (final e in decoded)
            if (e is Map)
              {
                for (final kv in e.entries) kv.key.toString(): kv.value.toString(),
              },
        ];
      }
    } catch (_) {
      // Corrupt entry — start fresh.
    }
    return [];
  }

  /// HS-011 (iOS): tombstone a deleted site so a Shortcut tile bound to it
  /// still resolves and routes by domain. Persists and re-syncs the App Group.
  Future<void> _recordShortcutTombstone(
    String siteId,
    String label,
    String url,
  ) async {
    _shortcutTombstones = ShortcutTombstones.add(
      tombstones: _shortcutTombstones,
      entry: {'siteId': siteId, 'label': label, 'url': url},
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kShortcutTombstonesKey, jsonEncode(_shortcutTombstones));
    _syncShortcutSites();
  }

  Map<String, String> _decodeStringMap(String? raw) {
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return {
          for (final e in decoded.entries) e.key.toString(): e.value.toString(),
        };
      }
    } catch (_) {
      // Corrupt entry — start fresh; it'll be rewritten on the next update.
    }
    return {};
  }

  /// Record one `siteId -> url` ledger entry (HS-011) and persist if it changed.
  Future<void> _recordShortcutLedger(String siteId, String url) async {
    if (url.isEmpty || _shortcutUrlLedger[siteId] == url) return;
    _shortcutUrlLedger[siteId] = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kShortcutUrlLedgerKey, jsonEncode(_shortcutUrlLedger));
  }

  /// Reconcile the ledger against the launcher's [pinnedSiteIds] (HS-011):
  /// record urls for pinned sites that still exist, prune unreachable entries.
  Future<void> _reconcileShortcutLedger(Set<String> pinnedSiteIds) async {
    final currentSiteUrls = {
      for (final m in _webViewModels)
        if (!m.isArchiveTier) m.siteId: m.initUrl,
    };
    final next = ShortcutUrlLedger.reconcile(
      ledger: _shortcutUrlLedger,
      currentSiteUrls: currentSiteUrls,
      pinnedSiteIds: pinnedSiteIds,
    );
    if (mapEquals(next, _shortcutUrlLedger)) return;
    _shortcutUrlLedger = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kShortcutUrlLedgerKey, jsonEncode(_shortcutUrlLedger));
  }

  bool _handlingShareIntent = false;

  Future<void> _handleShareIntent() async {
    if (_handlingShareIntent) {
      LogService.instance.log('LinkIntent', 'poll skipped: re-entry guarded');
      return;
    }
    _handlingShareIntent = true;
    try {
      LogService.instance.log('LinkIntent', 'poll: consumeLaunchHtml');
      // HTML file payload first — the native side clears it after read,
      // so a tag mismatch (e.g. an HTML file that *also* has EXTRA_TEXT)
      // won't double-fire.
      final html = await ShareIntentService.consumeLaunchHtml();
      if (!mounted) return;
      if (html != null) {
        if (!_linkHandlingEnabled) {
          LogService.instance.log('LinkIntent',
              'HTML share dropped (link handling disabled)');
          return;
        }
        LogService.instance.log(
          'LinkIntent',
          'HTML share received (${html.content.length} bytes, title=${html.title})',
          sensitivity: LogSensitivity.sensitive,
        );
        await _dispatchInbound(InboundHtml(
          content: html.content,
          suggestedTitle: html.title,
          sourceUri: html.sourceUri,
        ));
        return;
      }
      LogService.instance.log('LinkIntent', 'poll: consumeLaunchUrl');
      final raw = await ShareIntentService.consumeLaunchUrl();
      if (!mounted) return;
      if (raw == null || raw.isEmpty) {
        LogService.instance.log('LinkIntent', 'poll: no pending URL');
        return;
      }
      LogService.instance.log(
        'LinkIntent',
        'received: $raw',
        sensitivity: LogSensitivity.sensitive,
      );
      if (raw.startsWith('webspace://qr/')) {
        final decoded = SiteSettingsQrCodec.decode(raw);
        if (decoded != null) {
          _addSite(qrSettings: decoded);
        } else {
          LogService.instance.log(
            'LinkIntent',
            'QR payload failed to decode: $raw',
            level: LogLevel.warning,
            sensitivity: LogSensitivity.sensitive,
          );
        }
        return;
      }
      if (!_linkHandlingEnabled) {
        LogService.instance.log(
          'LinkIntent',
          'Share dropped (link handling disabled): $raw',
          sensitivity: LogSensitivity.sensitive,
        );
        return;
      }
      final parsed = Uri.tryParse(raw);
      if (parsed == null) {
        LogService.instance.log(
          'LinkIntent',
          'unparseable URL: $raw',
          level: LogLevel.warning,
          sensitivity: LogSensitivity.sensitive,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unsupported URL')),
        );
        return;
      }
      await _dispatchInbound(InboundUrl(parsed));
    } catch (e, st) {
      LogService.instance.log(
          'LinkIntent', 'share intent handler threw: $e\n$st',
          level: LogLevel.error,
          sensitivity: LogSensitivity.sensitive);
    } finally {
      _handlingShareIntent = false;
    }
  }

  /// Engine-driven dispatch entry point: hands [payload] to
  /// [LinkIntentDispatchEngine] and executes the returned action. The
  /// engine owns the routing decisions; this method only performs IO and
  /// UI. See `lib/services/link_intent_dispatch_engine.dart`.
  Future<void> _dispatchInbound(InboundPayload payload) async {
    final adapters = _webViewModels
        .map((m) => _SiteRouteAdapter(m))
        .toList(growable: false);
    final action = LinkIntentDispatchEngine.dispatch(
      payload: payload,
      sites: adapters,
    );
    final inboundUri = payload is InboundUrl ? payload.url : null;
    LogService.instance.log(
      'LinkIntent',
      'dispatch ${inboundUri ?? '(html payload)'} -> ${_describeDispatchAction(action)}',
      sensitivity: LogSensitivity.sensitive,
    );
    await _executeDispatchAction(action, inboundUri);
  }

  String _describeDispatchAction(DispatchAction action) {
    switch (action) {
      case DispatchUnsupported(:final reason):
        return 'Unsupported($reason)';
      case DispatchOpenInMain(:final siteId, :final url, :final disposeBeforeLoad, :final wipeContainer, :final clearInMemoryCookies):
        final flags = [
          if (disposeBeforeLoad) 'dispose',
          if (wipeContainer) 'wipeContainer',
          if (clearInMemoryCookies) 'clearCookies',
        ].join(',');
        return 'OpenInMain(siteId=$siteId, url=$url${flags.isEmpty ? '' : ', $flags'})';
      case DispatchOpenNested(:final siteId, :final url):
        return 'OpenNested(siteId=$siteId, url=$url)';
      case DispatchCreateSite(:final home, :final fullUrl):
        return 'CreateSite(home=$home, fullUrl=$fullUrl)';
      case DispatchCreateSiteFromHtml(:final suggestedTitle):
        return 'CreateSiteFromHtml(title=$suggestedTitle)';
      case DispatchBindAndOpen(:final chosenSiteId, :final claimAdditions):
        return 'BindAndOpen(siteId=$chosenSiteId, +${claimAdditions.length} claims)';
      case DispatchShowPicker(:final winnerSiteIds, :final offerBind, :final offerCreate):
        return 'ShowPicker(winners=${winnerSiteIds.length}, '
            'bind=$offerBind, create=$offerCreate)';
    }
  }

  Future<void> _executeDispatchAction(
    DispatchAction action,
    Uri? inboundUri,
  ) async {
    switch (action) {
      case DispatchUnsupported(:final reason):
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Unsupported share: $reason')),
          );
        }
      case DispatchOpenInMain():
        await _executeOpenInMain(action);
      case DispatchOpenNested():
        await _executeOpenNested(action);
      case DispatchCreateSite():
        await _executeCreateSite(action);
      case DispatchCreateSiteFromHtml():
        await _executeCreateSiteFromHtml(action);
      case DispatchBindAndOpen():
        await _executeBindAndOpen(action);
      case DispatchShowPicker():
        if (inboundUri == null) return;
        await _showDispatchPicker(action, inboundUri);
    }
  }

  /// Hosts the LIR-010 picker. Translates the user's choice into a
  /// follow-up engine call and executes the result.
  Future<void> _showDispatchPicker(
    DispatchShowPicker action,
    Uri inbound,
  ) async {
    final winners = _webViewModels
        .where((m) => action.winnerSiteIds.contains(m.siteId))
        .toList(growable: false);
    final others = _webViewModels
        .where((m) => !action.winnerSiteIds.contains(m.siteId))
        .toList(growable: false);
    if (!mounted) return;
    final choice = await showModalBottomSheet<_DispatchChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _DispatchPickerSheet(
        url: inbound,
        winners: winners,
        otherSites: others,
        canCreate: action.offerCreate,
      ),
    );
    if (!mounted || choice == null) return;
    final DispatchAction followUp;
    switch (choice) {
      case _DispatchChoiceOpen(:final site):
        followUp = LinkIntentDispatchEngine.openInChosen(
          inbound: inbound,
          site: _SiteRouteAdapter(site),
        );
      case _DispatchChoiceBind(:final site):
        followUp = LinkIntentDispatchEngine.bindToSite(
          inbound: inbound,
          site: _SiteRouteAdapter(site),
        );
      case _DispatchChoiceCreate():
        followUp =
            LinkIntentDispatchEngine.createNew(inbound: inbound);
    }
    await _executeDispatchAction(followUp, inbound);
  }

  /// LIR-011: dispose first when alwaysOpenHome / incognito; wipe
  /// container + clear cookies when incognito. Then activate and load.
  Future<void> _executeOpenInMain(DispatchOpenInMain a) async {
    final index =
        _webViewModels.indexWhere((m) => m.siteId == a.siteId);
    if (index < 0) {
      LogService.instance.log(
        'LinkIntent',
        'OpenInMain bailed: site ${a.siteId} not found',
        level: LogLevel.warning,
        sensitivity: LogSensitivity.sensitive,
      );
      return;
    }
    final model = _webViewModels[index];
    await _maybeSwitchToAllForSite(model, index);
    if (a.disposeBeforeLoad) {
      _evictCacheIfOnline(model.siteId);
      model.disposeWebView();
      _loadedIndices.remove(index);
      model.currentUrl = model.initUrl;
    }
    if (a.wipeContainer) {
      await _containerIsolation.clearForSite(model.siteId);
    }
    if (a.clearInMemoryCookies) {
      model.cookies = const [];
    }
    if (index != _currentIndex) {
      await _setCurrentIndex(index);
    }
    if (!mounted) return;
    final controller = model.getController(
      launchUrl,
      _cookieManager,
      _containerCookieManager,
      _saveWebViewModels,
      globalUserScripts: _globalUserScripts,
    );
    if (controller == null) {
      LogService.instance.log(
        'LinkIntent',
        'OpenInMain: controller not yet ready for "${model.name}" '
            '(siteId: ${model.siteId}); ${a.url} may queue until first frame',
        level: LogLevel.warning,
        sensitivity: LogSensitivity.sensitive,
      );
      return;
    }
    await controller.loadUrl(a.url, language: model.language);
    if (!mounted) return;
    setState(() {
      model.currentUrl = a.url;
    });
    await _saveWebViewModels();
  }

  /// LIR-011: open as a nested webview using the chosen site's settings.
  Future<void> _executeOpenNested(DispatchOpenNested a) async {
    final index =
        _webViewModels.indexWhere((m) => m.siteId == a.siteId);
    if (index < 0) return;
    final model = _webViewModels[index];
    await _maybeSwitchToAllForSite(model, index);
    if (!mounted) return;
    await launchUrl(
      a.url,
      homeTitle: model.name,
      siteId: model.siteId,
      incognito: model.incognito,
      thirdPartyCookiesEnabled: model.thirdPartyCookiesEnabled,
      clearUrlEnabled: model.clearUrlEnabled,
      dnsBlockEnabled: model.dnsBlockEnabled,
      contentBlockEnabled: model.contentBlockEnabled,
      localCdnEnabled: model.effectiveLocalCdnEnabled,
      trackingProtectionEnabled: model.trackingProtectionEnabled,
      language: model.language,
      zoomPercent: model.zoomPercent,
      locationMode: model.locationMode,
      spoofLatitude: model.spoofLatitude,
      spoofLongitude: model.spoofLongitude,
      spoofAccuracy: model.spoofAccuracy,
      spoofTimezone: model.spoofTimezone,
      spoofTimezoneFromLocation: model.spoofTimezoneFromLocation,
      liveLocationGranularity: model.liveLocationGranularity,
      webRtcPolicy: model.webRtcPolicy,
      userScripts: model.userScripts,
      proxySettings: model.proxySettings,
      notificationsEnabled: model.effectiveNotificationsEnabled,
    );
  }

  /// LIR-009 + LIR-010 option 3: create a brand-new site rooted at the
  /// stripped home URL with a synthesized `baseDomain` claim, then
  /// navigate the new webview to the full inbound URL on first activation.
  Future<void> _executeCreateSite(DispatchCreateSite a) async {
    final stateSetter = () { setState((){}); };
    final model = WebViewModel(
      initUrl: a.home,
      domainClaims: a.initialClaims.isEmpty ? null : a.initialClaims,
      stateSetterF: stateSetter,
    );
    final pageTitle = await getPageTitle(a.fullUrl);
    if (!mounted) return;
    if (pageTitle != null && pageTitle.isNotEmpty) {
      model.name = pageTitle;
      model.pageTitle = pageTitle;
    }
    await _registerNewSite(model);
    if (!mounted) return;
    final controller = model.getController(
      launchUrl,
      _cookieManager,
      _containerCookieManager,
      _saveWebViewModels,
      globalUserScripts: _globalUserScripts,
    );
    if (controller != null && a.fullUrl != a.home) {
      await controller.loadUrl(a.fullUrl, language: model.language);
      if (!mounted) return;
      setState(() {
        model.currentUrl = a.fullUrl;
      });
      await _saveWebViewModels();
    }
  }

  /// LIR-012: an HTML file share short-circuits to "create new site"
  /// (only sensible action — opaque file content can't be claimed by an
  /// existing site). HTML lives in `HtmlImportStorage`, identical to the
  /// in-app file-import flow.
  Future<void> _executeCreateSiteFromHtml(
    DispatchCreateSiteFromHtml a,
  ) async {
    final stateSetter = () { setState((){}); };
    final fileSiteUrl =
        'file:///webspace_import_${DateTime.now().microsecondsSinceEpoch}.html';
    final model = WebViewModel(
      initUrl: fileSiteUrl,
      stateSetterF: stateSetter,
    );
    final title = a.suggestedTitle?.trim();
    if (title != null && title.isNotEmpty) {
      model.name = title;
      model.pageTitle = title;
    }
    await HtmlImportStorage.instance.saveHtml(model.siteId, a.html, fileSiteUrl);
    await _registerNewSite(model);
  }

  /// Persist [a.claimAdditions] onto the chosen site (deduped against
  /// existing claims) and then execute the engine-computed [a.followUp].
  Future<void> _executeBindAndOpen(DispatchBindAndOpen a) async {
    final idx =
        _webViewModels.indexWhere((m) => m.siteId == a.chosenSiteId);
    if (idx < 0) return;
    final site = _webViewModels[idx];
    if (a.claimAdditions.isNotEmpty) {
      final existing = site.domainClaims ?? site.effectiveDomainClaims;
      site.domainClaims =
          LinkRoutingService.mergeClaims(existing, a.claimAdditions);
      await _saveWebViewModels();
    }
    await _executeDispatchAction(a.followUp, null);
  }

  /// WEBSPACE-011 helper: switch the active webspace to "All" if [model]
  /// isn't a member of the current named webspace, with a snackbar.
  Future<void> _maybeSwitchToAllForSite(WebViewModel model, int index) async {
    if (_selectedWebspaceId == null ||
        _selectedWebspaceId == kAllWebspaceId) {
      return;
    }
    final ws = _webspaces.firstWhere(
      (w) => w.id == _selectedWebspaceId,
      orElse: () => _webspaces.first,
    );
    if (ws.siteIndices.contains(index)) return;
    setState(() {
      _selectedWebspaceId = kAllWebspaceId;
    });
    await _saveSelectedWebspaceId();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Switched to All to open in ${model.getDisplayName()}',
          ),
        ),
      );
    }
  }

  /// Add [model] to `_webViewModels`, attach to current named webspace,
  /// activate, persist, and apply the current theme. Shared by the
  /// "create new site for URL" and "create new site for HTML" flows.
  Future<void> _registerNewSite(WebViewModel model) async {
    // Apply theme before _setCurrentIndex triggers the first build —
    // initialHtml reads currentTheme to pick the dark prelude for cached
    // HTML (file:// imports especially, which never reload to live), and
    // the model defaults to WebViewTheme.light otherwise.
    await model.setTheme(_themeModeToWebViewTheme(_themeSettings.themeMode));
    setState(() {
      _webViewModels.add(model);
    });
    final newSiteIndex = _webViewModels.length - 1;
    if (_selectedWebspaceId != null && _selectedWebspaceId != kAllWebspaceId) {
      final wsIdx = _webspaces.indexWhere((w) => w.id == _selectedWebspaceId);
      if (wsIdx != -1) {
        _webspaces[wsIdx].siteIds.add(model.siteId);
        _resolveWebspaceIndices();
        await _saveWebspaces();
      }
    }
    await _setCurrentIndex(newSiteIndex);
    if (!mounted) return;
    setState(() {});
    await _saveCurrentIndex();
    await _saveWebViewModels();
  }

  Future<void> _saveWebViewModels() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();

    // Archive-tier sites live in `_webViewModels` for runtime rendering
    // but must not enter app-tier persistence (ARCH-001 byte-identity
    // invariant). Cookies, proxy passwords, and the SharedPreferences
    // model list all filter on `!m.isArchiveTier`.
    final appTierModels = _webViewModels.where((m) => !m.isArchiveTier);

    // Save cookies to secure storage, keyed by siteId for per-site isolation
    final Map<String, List<Cookie>> cookiesBySiteId = {};
    for (final webViewModel in appTierModels) {
      if (webViewModel.cookies.isNotEmpty && !webViewModel.incognito) {
        cookiesBySiteId[webViewModel.siteId] = List.from(webViewModel.cookies);
      }
    }
    await _cookieSecureStorage.saveCookies(cookiesBySiteId);

    // Mirror per-site proxy passwords into secure storage. The non-secret
    // proxy fields ride along in the SharedPreferences JSON via
    // `model.toJson()` (which omits password by default).
    final existingPasswords = await _proxyPasswordStorage.loadAll();
    final updatedPasswords = <String, String?>{...existingPasswords};
    for (final m in appTierModels) {
      updatedPasswords[m.siteId] = m.proxySettings.password;
    }
    await _proxyPasswordStorage.saveAll(updatedPasswords);

    // Save models to SharedPreferences (cookies will be empty in
    // SharedPreferences; proxy password is omitted by `toJson()` default —
    // it lives in secure storage).
    List<String> webViewModelsJson = appTierModels.map((webViewModel) {
      final json = webViewModel.toJson();
      json['cookies'] = []; // Don't store cookies in SharedPreferences
      return jsonEncode(json);
    }).toList();
    await prefs.setStringList('webViewModels', webViewModelsJson);
    _syncShortcutSites();
  }

  /// Materialises an open [ArchiveHandle]'s sites into [_webViewModels]
  /// (appended at the end with `isArchiveTier=true`) and its named
  /// collections into [_webspaces] (marked `isArchiveTier`). Both
  /// persistence paths ([_saveWebViewModels], [_saveWebspaces]) filter
  /// by `isArchiveTier` so neither archive sites nor archive collections
  /// enter SharedPreferences. Caller triggers setState.
  Future<void> _materialiseArchive(ArchiveHandle handle) async {
    final siteIds = <String>{};
    final containerIds = <String>{};
    final stateSetter = () {
      if (mounted) setState(() {});
    };
    for (final siteJson in handle.state.sites) {
      final model = WebViewModel.fromJson(
        Map<String, dynamic>.from(siteJson),
        stateSetter,
        isArchiveTier: true,
      );
      // ARCH-007 opaque container id: HMAC of the archive key + site id,
      // truncated and reformatted to match the radix-36-dash-radix-36
      // shape of an app-tier siteId so directory listings look uniform.
      model.archiveContainerId =
          await _deriveArchiveContainerId(handle.key, model.siteId);
      containerIds.add(model.archiveContainerId!);
      final cookieList = handle.state.cookies[model.siteId];
      if (cookieList != null && cookieList.isNotEmpty) {
        final cookies = cookieList
            .map((c) => cookieFromJson(Map<String, dynamic>.from(c)))
            .toList();
        model.setPendingArchiveCookies(cookies);
      }
      _webViewModels.add(model);
      siteIds.add(model.siteId);
    }
    // Restore the archive's own named collections (grouping). They carry
    // siteId-keyed membership just like app-tier collections, marked
    // isArchiveTier so `_saveWebspaces` keeps them out of app-tier
    // persistence. Their runtime siteIndices view is rebuilt below.
    final webspaceIds = <String>{};
    for (final wsJson in handle.state.webspaces) {
      final ws = Webspace.fromJson(Map<String, dynamic>.from(wsJson))
        ..isArchiveTier = true;
      _webspaces.add(ws);
      webspaceIds.add(ws.id);
    }
    _archiveSlices[handle] = _ArchiveSlice(
      siteIds: siteIds,
      webspaceIds: webspaceIds,
      containerIds: containerIds,
    );
    _resolveWebspaceIndices();
  }

  Future<String> _deriveArchiveContainerId(
    Uint8List archiveKey,
    String siteId,
  ) async {
    final mac = await ArchiveCrypto.hmac(archiveKey, 'container:$siteId');
    final bd = ByteData.view(mac.buffer, mac.offsetInBytes);
    final v1 =
        (bd.getUint16(0) * 0x100000000) + bd.getUint32(2); // 48-bit group
    final v2 = bd.getUint32(6);
    return '${v1.toRadixString(36)}-${v2.toRadixString(36)}';
  }

  /// Opens an archive by passphrase. Returns the handle on success or
  /// null when no archive matches this passphrase (caller may then offer
  /// to create a new one). Cookies and webspace metadata for the archive
  /// are materialised into the parallel runtime collections.
  Future<ArchiveHandle?> _openArchive(String passphrase) async {
    final handle = await _archive.tryOpen(passphrase);
    if (handle == null) return null;
    if (_archiveSlices.containsKey(handle)) {
      // Already open. tryOpen on an already-open archive returns the same
      // handle, no extra materialisation needed.
      return handle;
    }
    _materialiseArchive(handle);
    if (mounted) setState(() {});
    return handle;
  }

  /// Creates a new archive with this passphrase and materialises an
  /// empty slice.
  Future<ArchiveHandle> _createArchive(String passphrase) async {
    final handle = await _archive.create(passphrase);
    _materialiseArchive(handle);
    if (mounted) setState(() {});
    return handle;
  }

  /// Closes an open archive: captures current cookies + sites back into
  /// the handle, persists, zeroes the key, and removes the archive's
  /// rows from [_webViewModels]. If the current selection points into
  /// the removed range, it falls back to the home view.
  Future<void> _closeArchive(ArchiveHandle handle) async {
    final slice = _archiveSlices.remove(handle);
    if (slice == null) return;
    final ownedSites = [
      for (final m in _webViewModels)
        if (slice.siteIds.contains(m.siteId)) m,
    ];
    handle.state.cookies
      ..clear()
      ..addEntries(
        ownedSites.map(
          (m) => MapEntry(
            m.siteId,
            m.cookies.map((c) => c.toJson()).toList(),
          ),
        ),
      );
    handle.state.sites
      ..clear()
      ..addAll(ownedSites.map((m) => m.toJson()));
    // Capture this archive's collections back into its state so any
    // rename / reorder / membership change made while open persists.
    final ownedSpaces = [
      for (final w in _webspaces)
        if (slice.webspaceIds.contains(w.id)) w,
    ];
    handle.state.webspaces
      ..clear()
      ..addAll(ownedSpaces.map((w) => w.toJson()));
    await _archive.save(handle);
    await _archive.close(handle);
    // Dispose webviews owned by this archive before removing them from
    // the list, so the IndexedStack rebuild doesn't try to render
    // orphan controllers.
    for (final m in ownedSites) {
      m.disposeWebView();
    }
    // ARCH-007: tear down per-site containers owned by this archive so
    // their on-disk directories don't outlive the close. Best-effort —
    // underlying filesystems may retain freed blocks.
    for (final cid in slice.containerIds) {
      await _containerIsolation.containerNative.deleteContainer(cid);
    }
    // Defensive back-erasure: wipe any per-`siteId` app-tier state
    // that could have leaked archive identity across the close (the
    // ARCH-006 overrides keep new writes out, but this also handles
    // entries written by builds that predate the override — and
    // entries that any future code path forgets to gate).
    for (final sid in slice.siteIds) {
      await _stateStorage.removeState(sid);
      await _cookieSecureStorage.saveCookiesForSite(sid, const []);
      await HtmlCacheService.instance.deleteCache(sid);
    }
    final pwAll = await _proxyPasswordStorage.loadAll();
    final pwPatch = <String, String?>{
      ...pwAll,
      for (final sid in slice.siteIds)
        if (pwAll.containsKey(sid)) sid: null,
    };
    if (pwPatch.length != pwAll.length ||
        slice.siteIds.any((sid) => pwAll.containsKey(sid))) {
      await _proxyPasswordStorage.saveAll(pwPatch);
    }
    final removedSet = slice.siteIds;
    if (_currentIndex != null) {
      final cur = _currentIndex!;
      if (cur < _webViewModels.length &&
          removedSet.contains(_webViewModels[cur].siteId)) {
        _currentIndex = null;
      }
    }
    _loadedIndices
        .removeWhere((i) => i < _webViewModels.length && removedSet.contains(_webViewModels[i].siteId));
    _webViewModels.removeWhere((m) => removedSet.contains(m.siteId));
    // Remove this archive's collections from the runtime list. If the
    // user was viewing one, fall back to the synthetic "All" view.
    if (slice.webspaceIds.contains(_selectedWebspaceId)) {
      _selectedWebspaceId = kAllWebspaceId;
      unawaited(_saveSelectedWebspaceId());
    }
    _webspaces.removeWhere((w) => slice.webspaceIds.contains(w.id));
    // Webspace.siteIndices is a derived view over _webViewModels;
    // archive sites just left the list, so positions of remaining
    // sites may have shifted and any webspace siteIds that previously
    // resolved into archive positions must drop from the runtime
    // projection. siteIds stays untouched (ARCH-001), so reopening
    // the archive restores membership.
    _resolveWebspaceIndices();
    if (mounted) setState(() {});
  }

  /// Closes every currently-open archive in sequence.
  Future<void> _closeAllArchives() async {
    final handles = List<ArchiveHandle>.from(_archiveSlices.keys);
    for (final h in handles) {
      await _closeArchive(h);
    }
  }

  /// Moves the site at [index] from the app-tier into an archive
  /// identified by a passphrase. Always prompts; if the passphrase
  /// matches an existing archive (open or not), the site is added
  /// there. If no archive matches, the user is asked whether to create
  /// one. The site's position in `_webViewModels` is preserved — only
  /// its tier flips (and the running webview is rebuilt to bind to the
  /// new opaque container). Webspace membership is preserved via the
  /// siteId-keyed `webspace.siteIds` list.
  Future<void> _moveSiteToArchive(int index) async {
    if (index < 0 || index >= _webViewModels.length) return;
    final model = _webViewModels[index];
    if (model.isArchiveTier) return;

    final passphrase = await _showPassphraseDialog(
      title: 'Move site to archive',
      hint: 'Archive passphrase',
      submitLabel: 'Move',
    );
    if (passphrase == null || passphrase.isEmpty) return;
    if (!mounted) return;

    ArchiveHandle? target;
    try {
      target = await _openArchive(passphrase);
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open archive: ${e.message}')),
      );
      return;
    }
    if (target == null) {
      if (!mounted) return;
      final shouldCreate = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('No matching archive'),
          content: const Text(
            'No archive exists for this passphrase. '
            'Create a new archive with it and move this site into it?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create'),
            ),
          ],
        ),
      );
      if (shouldCreate != true) return;
      try {
        target = await _createArchive(passphrase);
      } on StateError catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create archive: ${e.message}')),
        );
        return;
      }
    }
    if (!mounted) return;

    // Capture cookies from the running container so they ride along
    // with the move. Falls back to model.cookies (synced via
    // onCookiesChanged) when the webview hasn't been loaded.
    final capturedCookies = await _captureCookiesForTransfer(model);

    // Drop app-tier persistence for this site so the next
    // _saveWebViewModels doesn't see it. The site's runtime row stays
    // in _webViewModels; only its tier and routing change.
    await _cookieSecureStorage.saveCookiesForSite(model.siteId, const []);
    final passwords = await _proxyPasswordStorage.loadAll();
    if (passwords.containsKey(model.siteId)) {
      final next = <String, String?>{...passwords, model.siteId: null};
      await _proxyPasswordStorage.saveAll(next);
    }

    // Drop the app-tier container (cleartext `ws-<siteId>`).
    if (_useContainers) {
      await _containerIsolation.onSiteDeleted(model.siteId);
    }

    // Force a fresh webview that binds to the new opaque container.
    model.disposeWebView();
    model.isArchiveTier = true;
    model.archiveContainerId =
        await _deriveArchiveContainerId(target.key, model.siteId);
    model.setPendingArchiveCookies(capturedCookies);

    // Track ownership for the close-archive flow.
    target.state.sites.add(model.toJson());
    target.state.cookies[model.siteId] =
        capturedCookies.map((c) => c.toJson()).toList();
    _archiveSlices[target]!.siteIds.add(model.siteId);
    _archiveSlices[target]!.containerIds.add(model.archiveContainerId!);
    await _archive.save(target);

    // Webspace membership is keyed by siteId (not positional index), so
    // no change is needed here — the runtime `siteIndices` projection
    // will continue to surface this site under any webspace it
    // belonged to whenever the archive is open. When the archive
    // closes, the siteId stays in webspace.siteIds (persisted) but
    // drops out of siteIndices (runtime view) automatically.
    _resolveWebspaceIndices();
    await _saveWebViewModels();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Site moved to archive. You may need to re-set per-site '
            'preferences (theme, language) the first time it loads.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
    }
  }

  /// Reverse of [_moveSiteToArchive]: pulls an archive-tier site back
  /// into the app-tier. Only works while the owning archive is open.
  Future<void> _moveSiteOutOfArchive(int index) async {
    if (index < 0 || index >= _webViewModels.length) return;
    final model = _webViewModels[index];
    if (!model.isArchiveTier) return;
    final entry = _archiveSlices.entries
        .where((e) => e.value.siteIds.contains(model.siteId))
        .firstOrNull;
    if (entry == null) return;
    final handle = entry.key;
    final slice = entry.value;

    final capturedCookies = await _captureCookiesForTransfer(model);

    // Tear down the opaque archive container.
    final containerId = model.archiveContainerId;
    if (containerId != null) {
      await _containerIsolation.containerNative.deleteContainer(containerId);
    }

    // Pop the site out of the archive's state and slice.
    handle.state.sites.removeWhere((s) => s['siteId'] == model.siteId);
    handle.state.cookies.remove(model.siteId);
    slice.siteIds.remove(model.siteId);
    if (containerId != null) {
      slice.containerIds.remove(containerId);
    }
    await _archive.save(handle);

    // Flip the model back to app-tier and rebuild the webview against
    // the standard `ws-<siteId>` container.
    model.disposeWebView();
    model.isArchiveTier = false;
    model.archiveContainerId = null;
    model.cookies = capturedCookies;

    await _saveWebViewModels();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Site moved out of archive')),
      );
    }
  }

  /// Pulls cookies from the running container (if any) and falls back
  /// to the in-Dart `cookies` list when no controller is alive. Used by
  /// both directions of the move flow.
  Future<List<Cookie>> _captureCookiesForTransfer(WebViewModel model) async {
    final controller = model.controller;
    if (controller != null && _containerCookieManager != null) {
      final url = Uri.parse(
        model.currentUrl.isNotEmpty ? model.currentUrl : model.initUrl,
      );
      final fresh = await _containerCookieManager!.getCookies(
        controller: controller,
        siteId: model.siteId,
        url: url,
      );
      if (fresh.isNotEmpty) return fresh;
    }
    return List<Cookie>.from(model.cookies);
  }


  /// Settings-screen entry point: prompts for a passphrase, then attempts
  /// to open a matching archive. If none matches, asks the user whether
  /// to create a new archive with that passphrase. Snackbars report the
  /// result without revealing existence of other archives.
  Future<void> _promptRestoreArchive() async {
    final passphrase = await _showPassphraseDialog(
      title: 'Restore archive',
      hint: 'Passphrase',
      submitLabel: 'Open',
    );
    if (passphrase == null || passphrase.isEmpty) return;
    if (!mounted) return;
    try {
      final handle = await _openArchive(passphrase);
      if (handle != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Archive opened (${handle.state.sites.length} sites, '
              '${handle.state.webspaces.length} webspaces)',
            ),
          ),
        );
        return;
      }
      if (!mounted) return;
      final shouldCreate = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('No matching archive'),
          content: const Text(
            'No archive exists for this passphrase. '
            'Create a new archive with it?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create'),
            ),
          ],
        ),
      );
      if (shouldCreate != true) return;
      await _createArchive(passphrase);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('New archive created')),
      );
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open: ${e.message}')),
      );
    }
  }

  Future<String?> _showPassphraseDialog({
    required String title,
    required String hint,
    required String submitLabel,
  }) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (value) => Navigator.pop(ctx, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text(submitLabel),
            ),
          ],
        );
      },
    );
  }

  /// HS-007: push the current site list to the iOS App Intents picker so
  /// renames / additions / deletions show up in Shortcuts.app the next time
  /// the user touches it. No-op on non-iOS platforms.
  void _syncShortcutSites() {
    if (!Platform.isIOS && !Platform.isMacOS) return;
    final sites = [
      for (final m in _webViewModels)
        if (!m.isArchiveTier)
          ShortcutSite(
            siteId: m.siteId,
            label: m.name,
            url: m.initUrl,
            iconUrl: FaviconUrlCache.get(m.initUrl),
          ),
    ];
    // HS-011: a deleted-site Shortcut still resolves via these tombstones, so
    // it launches and routes by domain instead of failing "no longer available".
    final tombstones = [
      for (final t in _shortcutTombstones)
        ShortcutSite(
          siteId: t['siteId'] ?? '',
          label: t['label'] ?? '',
          url: t['url'],
        ),
    ];
    unawaited(ShortcutService.syncSites(sites, tombstones: tombstones));
  }

  Future<void> _saveCurrentIndex() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('currentIndex', _currentIndex == null ? 10000 : _currentIndex!);
  }

  Future<void> _saveThemeSettings() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('themeSettings', _themeSettings.toStorageIndex());
  }

  Future<void> _saveShowUrlBar() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showUrlBar', _showUrlBar);
  }

  Future<void> _saveShowTabStrip() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showTabStrip', _showTabStrip);
  }

  Future<void> _saveTabStripInFullscreen() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tabStripInFullscreen', _tabStripInFullscreen);
  }

  Future<void> _saveShowStatsBanner() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showStatsBanner', _showStatsBanner);
  }

  Future<void> _saveLinkHandlingEnabled() async {
    if (isDemoMode) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kLinkHandlingEnabledKey, _linkHandlingEnabled);
  }

  void _openLinkHandlingSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => LinkHandlingSettingsScreen(
          enabled: _linkHandlingEnabled,
          onEnabledChanged: (v) {
            setState(() => _linkHandlingEnabled = v);
            _saveLinkHandlingEnabled();
          },
          sites: List<WebViewModel>.from(_webViewModels),
          onOpenSiteEditor: (site) {
            final idx = _webViewModels.indexOf(site);
            if (idx >= 0) {
              Navigator.of(ctx).pop();
              _editSite(idx);
            }
          },
          onManualDispatch: (uri) async {
            await _dispatchInbound(InboundUrl(uri));
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
    if (_globalUserScripts.isEmpty || _webViewModels.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('globalUserScriptsOptInMigrated') == true) return;
    final allIds = _globalUserScripts.map((s) => s.id).toSet();
    for (final model in _webViewModels) {
      if (model.enabledGlobalScriptIds.isEmpty) {
        model.enabledGlobalScriptIds = {...allIds};
      }
    }
    await prefs.setBool('globalUserScriptsOptInMigrated', true);
    await _saveWebViewModels();
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
  /// already in flight (e.g. the previous `controller.getHtml()` IPC
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
    if (_currentIndex == null || _currentIndex! >= _webViewModels.length) return;
    _evictCacheIfOnline(_webViewModels[_currentIndex!].siteId);
    setState(() {
      _webViewModels[_currentIndex!].disposeWebView();
    });
  }

  /// Persist settings, then recreate the current site's webview so the
  /// updated UA / language / location / shim-relevant fields take effect
  /// through fresh `initialSettings` and `initialUserScripts`. Wired into
  /// [SettingsScreen]'s `onSettingsSaved`.
  Future<void> _handlePerSiteSettingsSaved() async {
    await _saveWebViewModels();
    if (!mounted) return;

    final index = _currentIndex;
    final model = (index != null && index < _webViewModels.length)
        ? _webViewModels[index]
        : null;

    if (model != null && model.fullscreenMode) {
      _enterFullscreen();
    } else {
      _exitFullscreen();
    }

    if (index != null && model != null) {
      _resetCurrentSiteWebView();
    } else {
      setState(() {});
    }

    // The user may have just toggled `notificationsEnabled` on/off, so
    // re-evaluate the background refresh schedule (iOS BGAppRefreshTask
    // / Android WorkManager). No-op on other platforms.
    unawaited(_updateBackgroundRefreshSchedule());
  }

  /// Dispose every loaded webview. Used after global user script edits,
  /// which can affect any site that has opted in. Caches for sites that
  /// have any global opt-in are dropped (online only) for the same reason
  /// as [_resetCurrentSiteWebView].
  void _resetAllWebViews() {
    for (final model in _webViewModels) {
      if (model.enabledGlobalScriptIds.isNotEmpty) {
        _evictCacheIfOnline(model.siteId);
      }
    }
    setState(() {
      for (final model in _webViewModels) {
        model.disposeWebView();
      }
    });
  }

  Future<void> _saveWebspaces() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();
    // Archive-tier collections live in `_webspaces` for rendering while
    // open but must not enter app-tier persistence (their membership is
    // carried in the archive's own encrypted state).
    List<String> webspacesJson = _webspaces
        .where((webspace) => !webspace.isArchiveTier)
        .map((webspace) => jsonEncode(webspace.toJson()))
        .toList();
    await prefs.setStringList('webspaces', webspacesJson);
  }

  Future<void> _saveSelectedWebspaceId() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (_selectedWebspaceId != null) {
      await prefs.setString('selectedWebspaceId', _selectedWebspaceId!);
    } else {
      await prefs.remove('selectedWebspaceId');
    }
  }

  /// Set the current index and mark it as loaded for lazy webview creation.
  /// This ensures only visited webviews are created, not all webviews at once.
  /// Also handles domain conflict detection for per-site cookie isolation.
  Future<void> _setCurrentIndex(int? index) async {
    final version = ++_setCurrentIndexVersion;

    if (index == null || index < 0 || index >= _webViewModels.length) {
      // Going home: opportunistically capture state for the
      // previously-active site so a later cold start (or
      // OS-killed-while-backgrounded scenario) can re-hydrate its
      // back/forward stack and form data on re-activation. The
      // webview stays loaded (pause-only, not disposed) so a
      // near-immediate return to the same site keeps its in-memory
      // tab. Bytes-only capture — `lifecycleState` stays `live`
      // because the webview is not actually disposed.
      if (_currentIndex != null && _currentIndex! < _webViewModels.length && _loadedIndices.contains(_currentIndex)) {
        await _captureStateBytes(_webViewModels[_currentIndex!]);
        if (version != _setCurrentIndexVersion) return;
        await _webViewModels[_currentIndex!].pauseWebView();
        if (version != _setCurrentIndexVersion) return;
      }
      _currentIndex = index;
      _exitFullscreen();
      return;
    }

    final target = _webViewModels[index];

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
    LogService.instance.log('CookieIsolation', 'Currently loaded indices: $_loadedIndices');

    // Mark this site as activation-in-flight so concurrent OS memory
    // pressure events can't pick it as a victim before _currentIndex
    // is updated below — disposing the webview mid-activation would
    // silently wipe its state from under the user.
    _activationInFlightIndex = index;
    try {

    // If the target was disposed under memory pressure (lifecycleState
    // == savedForRestore), fetch its captured navigation state and
    // hand it to the model so the soon-to-be-built controller's
    // onControllerCreated handler can apply restoreState. Resets the
    // tier to live regardless — the about-to-be-resumed webview
    // is back at the lowest tier.
    // ARCH-006: archive-tier sites never persist webview state to
    // disk (`_captureStateBytes` early-returns for them), so there's
    // nothing on disk to restore. Skip the load to avoid a per-site
    // disk hit that would correlate to the archive siteId.
    if (target.lifecycleState == SiteLifecycleState.savedForRestore &&
        !target.isArchiveTier) {
      final bytes = await _stateStorage.loadState(target.siteId);
      if (version != _setCurrentIndexVersion) return;
      if (bytes != null) {
        target.schedulePendingRestoreState(bytes);
        LogService.instance.log(
          'WebViewState',
          'Queued ${bytes.length} restore bytes for "${target.name}" '
              '(siteId: ${target.siteId})',
          sensitivity: LogSensitivity.sensitive,
        );
      }
      target.lifecycleState = SiteLifecycleState.resident;
    } else if (target.lifecycleState != SiteLifecycleState.resident) {
      // cacheCleared promoted back to live on activation — the user
      // is interacting with it again, so any subsequent memory
      // pressure starts the cascade fresh from the live tier.
      target.lifecycleState = SiteLifecycleState.resident;
    }

    // Domain-conflict unload + capture-nuke-restore is only needed when
    // the native cookie jar is shared between sites. With the Container
    // API, each site has its own jar; concurrent same-base-domain sites
    // are isolated by the engine and do not need to be unloaded.
    if (!_useContainers) {
      final conflictIndex = SiteActivationEngine.findDomainConflict(
        targetIndex: index,
        models: _webViewModels,
        loadedIndices: _loadedIndices,
      );
      if (conflictIndex != null) {
        LogService.instance.log(
          'CookieIsolation',
          'CONFLICT! Unloading site $conflictIndex: "${_webViewModels[conflictIndex].name}"',
          level: LogLevel.warning,
          sensitivity: LogSensitivity.sensitive,
        );
        await _unloadSiteForDomainSwitch(conflictIndex);
        if (version != _setCurrentIndexVersion) return;
      }
    }

    // Proxy-mismatch unload (Android only). The WebView proxy is
    // process-global on Android (`inapp.ProxyController` last-write-wins);
    // activating a site whose effective proxy differs from a currently-
    // loaded site would silently re-route that site's next request through
    // the new proxy. Unload conflicting sites so they can't leak.
    final proxyMismatch = SiteUnloadEngine.indicesToUnloadForProxyMismatch(
      targetIndex: index,
      models: _webViewModels,
      loadedIndices: _loadedIndices,
      proxyIsGlobal: Platform.isAndroid,
    );
    for (final i in proxyMismatch) {
      LogService.instance.log(
        'SiteUnload',
        'Proxy mismatch — unloading site $i: "${_webViewModels[i].name}"',
        level: LogLevel.warning,
        sensitivity: LogSensitivity.sensitive,
      );
      await _unloadSiteForOtherReason(i);
      if (version != _setCurrentIndexVersion) return;
    }

    // LRU cap. Bound the number of concurrently loaded webviews; under
    // container mode the unload-on-webspace-switch step is skipped, so
    // without a cap a heavy user could pile up dozens of live webviews.
    // _loadedIndices is treated as access-ordered (re-added on each
    // activation below), so iteration order is least-recently-used first.
    //
    // Sites in the currently-selected webspace are passed as soft-keep:
    // membership in the user's active workspace is treated as "context
    // relevance" and beats raw access recency, so a stale site in the
    // active webspace stays loaded over a fresher site from a different
    // webspace if both are eligible for eviction.
    final lruEvict = SiteUnloadEngine.indicesToEvictForLruCap(
      targetIndex: index,
      loadedIndices: _loadedIndices,
      maxLoadedSites: kMaxLoadedSites,
      priorityOf: _siteRetentionPriority,
    );
    for (final i in lruEvict) {
      LogService.instance.log(
        'SiteUnload',
        'LRU cap (>$kMaxLoadedSites) — unloading site $i: "${_webViewModels[i].name}"',
        sensitivity: LogSensitivity.sensitive,
      );
      await _unloadSiteForOtherReason(i);
      if (version != _setCurrentIndexVersion) return;
    }

    // Proactive `resident → cacheCleared` promotion. Backstop for
    // platforms where the OS doesn't reliably fire memory pressure
    // (Linux/desktop), and for iOS where Jetsam is reactive (after
    // memory is already tight). Once more than [kMaxResidentSites]
    // sites are at the resident tier, the oldest excess get
    // clearCache called eagerly. This is the proactive complement
    // to the reactive _handleMemoryPressure cascade and uses the
    // same priority hierarchy. The active site is hard-protected;
    // sites in the active webspace are soft-keep.
    final cacheClearStates = <int, SiteLifecycleState>{
      for (final i in _loadedIndices)
        if (i >= 0 && i < _webViewModels.length) i: _webViewModels[i].lifecycleState,
    };
    final cacheClearTargets =
        SiteLifecyclePromotionEngine.pickProactiveCacheClearTargets(
      loadedIndices: _loadedIndices,
      states: cacheClearStates,
      maxResidentSites: kMaxResidentSites,
      priorityOf: _siteRetentionPriority,
    );
    for (final i in cacheClearTargets) {
      // Defensive bounds check after the await below in case site
      // deletion shifted indices.
      if (i < 0 || i >= _webViewModels.length) continue;
      LogService.instance.log(
        'SiteUnload',
        'Proactive cacheClear (>$kMaxResidentSites resident) — '
            'clearing cache for site $i: "${_webViewModels[i].name}"',
        sensitivity: LogSensitivity.sensitive,
      );
      await _webViewModels[i].clearWebViewCache();
      if (version != _setCurrentIndexVersion) return;
      // Re-check membership in case a concurrent path (memory
      // pressure handler, deletion) already promoted or evicted this
      // index between the engine pick and the await resume.
      if (i < _webViewModels.length &&
          _loadedIndices.contains(i) &&
          _webViewModels[i].lifecycleState == SiteLifecycleState.resident) {
        _webViewModels[i].lifecycleState = SiteLifecycleState.cacheCleared;
      }
    }

    // Pause the previously active webview to save resources
    if (_currentIndex != null && _currentIndex! < _webViewModels.length && _loadedIndices.contains(_currentIndex)) {
      await _webViewModels[_currentIndex!].pauseWebView();
      if (version != _setCurrentIndexVersion) return;
    }

    if (_useContainers) {
      // Container path: ensure the named container is recorded.
      // Materialization happens lazily on the native side when the
      // WebView binds via `InAppWebViewSettings.containerId`.
      await _containerIsolation.ensureContainer(target.siteId);
      if (version != _setCurrentIndexVersion) return;
    } else {
      // Legacy path: restore cookies for target site before loading
      await _restoreCookiesForSite(index);
      if (version != _setCurrentIndexVersion) return;
    }

    // Validate index is still in bounds after async gaps
    if (index >= _webViewModels.length) return;

    _currentIndex = index;
    // Bump to end of insertion order so iteration over _loadedIndices is
    // least-recently-used first (consumed by the LRU eviction above).
    _loadedIndices.remove(index);
    _loadedIndices.add(index);

    // Resume the newly active webview
    await _webViewModels[index].resumeWebView();

    // A site that sat offscreen while the OS reclaimed memory can come back
    // with a dead renderer (iOS content-process jettison whose termination
    // delegate never fired) or a blank surface (Android hybrid-composition).
    // Probe and recover so a shortcut tap or tab switch doesn't land on a
    // black/blank page. See PAUSE-013.
    unawaited(_probeRendererAndRecover(target));

    // Defensive sweep: pause every other loaded webview so background
    // sites don't run animations / GPS listeners / non-throttled
    // raf callbacks when the user isn't looking at them. Steady state
    // already has them paused (each becomes paused when it last lost
    // active status above), but a path that adds to _loadedIndices
    // without going through the previous-active pause would leave
    // it unpaused. pauseWebView() is idempotent.
    //
    // unawaited: subsequent activation logic (fullscreen, logging)
    // doesn't depend on these completing. Race-wise this is safe in
    // Dart's single-threaded model: each pauseWebView dispatches on
    // the platform channel synchronously up to its first await, and
    // the channel preserves FIFO order — so the resumeWebView above
    // is dispatched before any of these pauses. A subsequent
    // _setCurrentIndex would also do its own resume after these
    // pauses, so the latest target always ends up resumed.
    //
    // (Per-instance pause() doesn't stop JavaScript — see
    // openspec/specs/webview-pause-lifecycle/spec.md. This is a
    // CPU/battery optimization, not RAM. The LRU cap and OS memory
    // pressure handler cover RAM.)
    final loadedSnapshot = _loadedIndices.toList();
    for (final i in loadedSnapshot) {
      if (i == index) continue;
      if (i < 0 || i >= _webViewModels.length) continue;
      unawaited(_webViewModels[i].pauseWebView());
    }

    // Auto-enter fullscreen if the site has fullscreenMode enabled
    if (target.fullscreenMode) {
      _enterFullscreen();
    } else {
      _exitFullscreen();
    }

    LogService.instance.log('CookieIsolation', 'After switch, loaded indices: $_loadedIndices', sensitivity: LogSensitivity.sensitive);
    // _loadedIndices may have changed (LRU eviction, conflict unload,
    // first-load of target), so re-evaluate the background refresh
    // schedule. No-op on non-iOS / non-Android.
    unawaited(_updateBackgroundRefreshSchedule());
    } finally {
      // Clear the in-flight marker only if we still own it; a newer
      // _setCurrentIndex caller will have already overwritten it with
      // its own target.
      if (_activationInFlightIndex == index) {
        _activationInFlightIndex = null;
      }
    }
  }

  /// Unloads a site due to domain conflict with another site. Delegates to
  /// the isolation engine so the orchestration is shared with tests.
  Future<void> _unloadSiteForDomainSwitch(int index) async {
    await _cookieIsolation.unloadSiteForDomainSwitch(
      index: index,
      models: _webViewModels,
      loadedIndices: _loadedIndices,
    );
  }

  /// Unloads a site for non-domain-conflict reasons (proxy mismatch,
  /// LRU cap, memory pressure). Under container mode the per-site
  /// container partitions cookies/localStorage/IDB/etc., so disposing
  /// the webview is enough. Under legacy mode, the cookie jar is
  /// shared, so we run the same capture-then-dispose cycle the engine
  /// uses for domain conflicts — otherwise the soon-to-run capture-
  /// nuke-restore on activation of the target would wipe the unloaded
  /// site's session out of the jar.
  ///
  /// Before disposing, captures `controller.saveState()` to the in-
  /// memory state storage so re-activation can restore the back/
  /// forward stack and (Apple) form data via `restoreState`. Skipped
  /// for incognito sites (state is meant to be ephemeral).
  Future<void> _unloadSiteForOtherReason(int index) async {
    if (index < 0 || index >= _webViewModels.length) return;
    final model = _webViewModels[index];
    await _captureStateForRestore(model);
    if (_useContainers) {
      model.disposeWebView();
      _loadedIndices.remove(index);
      return;
    }
    await _cookieIsolation.unloadSiteForDomainSwitch(
      index: index,
      models: _webViewModels,
      loadedIndices: _loadedIndices,
    );
  }

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
    if (model.incognito) return false;
    // ARCH-006: per-site webview state is keyed by siteId on disk
    // (encrypted, but the file's existence + path leaks archive site
    // identity to forensic inspection, and the bytes encode the
    // back/forward URL stack). Archive-tier sites never capture.
    if (model.isArchiveTier) return false;
    final bytes = await model.captureNavigationState();
    if (bytes == null) return false;
    await _stateStorage.saveState(model.siteId, bytes);
    LogService.instance.log(
      'WebViewState',
      'Captured ${bytes.length} bytes for "${model.name}" (siteId: ${model.siteId})',
      sensitivity: LogSensitivity.sensitive,
    );
    return true;
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
    final version = _setCurrentIndexVersion;
    await _cookieIsolation.restoreCookiesForSite(
      index: index,
      models: _webViewModels,
      loadedIndices: _loadedIndices,
      versionAtEntry: version,
      currentVersion: () => _setCurrentIndexVersion,
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
                      Text('Verification', style: TextStyle(fontWeight: FontWeight.bold)),
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
        _webspaces.addAll(loadedWebspaces);
      });
    }

    // Ensure "All" webspace always exists
    _ensureAllWebspaceExists();

    _selectedWebspaceId = prefs.getString('selectedWebspaceId');

    // If no webspace is selected, select "All" by default
    if (_selectedWebspaceId == null) {
      _selectedWebspaceId = kAllWebspaceId;
    }
  }

  void _ensureAllWebspaceExists() {
    // Check if "All" webspace already exists
    final hasAll = _webspaces.any((ws) => ws.id == kAllWebspaceId);

    if (!hasAll) {
      setState(() {
        _webspaces.insert(0, Webspace.all());
      });
    } else {
      // Ensure "All" is at the beginning
      final allIndex = _webspaces.indexWhere((ws) => ws.id == kAllWebspaceId);
      if (allIndex > 0) {
        setState(() {
          final allWebspace = _webspaces.removeAt(allIndex);
          _webspaces.insert(0, allWebspace);
        });
      }
    }
  }

  /// Recomputes each webspace's runtime `siteIndices` list from its
  /// persisted `siteIds` membership against the current `_webViewModels`.
  /// Order is preserved: `siteIndices` ends up in the same order as
  /// `siteIds`, with missing siteIds simply absent from the projection.
  /// The synthetic "All" webspace is treated specially by the renderer
  /// and not rewritten here.
  void _resolveWebspaceIndices() {
    final positionBySiteId = <String, int>{
      for (var i = 0; i < _webViewModels.length; i++)
        _webViewModels[i].siteId: i,
    };
    for (final ws in _webspaces) {
      if (ws.isAll) continue;
      ws.siteIndices = [
        for (final sid in ws.siteIds)
          if (positionBySiteId.containsKey(sid)) positionBySiteId[sid]!,
      ];
    }
  }

  /// Legacy migration: webspaces persisted before the siteId-based
  /// membership refactor stored positional `siteIndices` in JSON. On
  /// first load after the upgrade, `Webspace.fromJson` populates
  /// `siteIndices` but leaves `siteIds` empty. We resolve each legacy
  /// index to the matching `_webViewModels[index].siteId` and persist
  /// back as siteIds. Idempotent: webspaces that already have siteIds
  /// skip the conversion.
  Future<void> _migrateLegacyWebspaceIndices() async {
    var migrated = false;
    for (final ws in _webspaces) {
      if (ws.isAll) continue;
      if (ws.siteIds.isNotEmpty || ws.siteIndices.isEmpty) continue;
      final ids = <String>[];
      for (final idx in ws.siteIndices) {
        if (idx >= 0 && idx < _webViewModels.length) {
          ids.add(_webViewModels[idx].siteId);
        }
      }
      ws.siteIds = ids;
      migrated = true;
    }
    if (migrated) {
      await _saveWebspaces();
    }
  }

  Future<void> _loadWebViewModels() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? webViewModelsJson = prefs.getStringList('webViewModels');

    if (webViewModelsJson != null) {
      // Pre-pass: legacy data may carry a plaintext `password` field inside
      // each site's `proxySettings` blob. Move them into secure storage and
      // strip from the in-memory JSON before constructing models, so the
      // post-migration `_saveWebViewModels` writes the cleaned form back.
      final secureProxyPasswords = await _proxyPasswordStorage.loadAll();
      final legacyMigrations = <String, String>{};
      final cleanedJsonStrings = <String>[];
      for (var i = 0; i < webViewModelsJson.length; i++) {
        final raw = webViewModelsJson[i];
        try {
          final decoded = jsonDecode(raw) as Map<String, dynamic>;
          final proxy = decoded['proxySettings'];
          if (proxy is Map<String, dynamic>) {
            final pwd = proxy['password'];
            if (pwd is String && pwd.isNotEmpty) {
              final siteId = decoded['siteId'];
              if (siteId is String && siteId.isNotEmpty) {
                // Don't overwrite an existing secure-storage entry — the
                // secure value wins on conflict (it's newer by definition).
                if (!(secureProxyPasswords[siteId]?.isNotEmpty ?? false)) {
                  legacyMigrations[siteId] = pwd;
                }
                proxy.remove('password');
              }
            }
          }
          cleanedJsonStrings.add(jsonEncode(decoded));
        } catch (e) {
          LogService.instance.log(
            'Boot',
            'Dropped unparseable site JSON at index $i: $e',
            level: LogLevel.warning,
            // The exception text can echo the malformed site JSON, which
            // includes initUrl / name — per-site identifiers. Memory ring.
            sensitivity: LogSensitivity.sensitive,
          );
        }
      }
      if (legacyMigrations.isNotEmpty) {
        final merged = <String, String?>{
          ...secureProxyPasswords,
          ...legacyMigrations,
        };
        await _proxyPasswordStorage.saveAll(merged);
        await prefs.setStringList('webViewModels', cleanedJsonStrings);
        secureProxyPasswords.addAll(legacyMigrations);
        LogService.instance.log(
          'ProxyPwdStore',
          'Migrated ${legacyMigrations.length} legacy plaintext per-site proxy password(s) to secure storage',
          level: LogLevel.info,
        );
      }

      final loadedWebViewModels = <WebViewModel>[];
      for (var i = 0; i < cleanedJsonStrings.length; i++) {
        try {
          loadedWebViewModels.add(WebViewModel.fromJson(
            jsonDecode(cleanedJsonStrings[i]),
            () { setState((){}); },
          ));
        } catch (e) {
          LogService.instance.log(
            'Boot',
            'Skipped malformed site at index $i: $e',
            level: LogLevel.warning,
            // Exception text can echo site JSON (initUrl / name). Memory ring.
            sensitivity: LogSensitivity.sensitive,
          );
        }
      }

      // Hydrate per-site proxy passwords from secure storage.
      var hydratedCount = 0;
      var sitesWithCustomProxy = 0;
      for (final m in loadedWebViewModels) {
        if (m.proxySettings.type != ProxyType.DEFAULT) {
          sitesWithCustomProxy++;
        }
        final pwd = secureProxyPasswords[m.siteId];
        if (pwd != null && pwd.isNotEmpty) {
          m.proxySettings.password = pwd;
          hydratedCount++;
        }
      }
      LogService.instance.log(
        'Proxy',
        'Hydrated proxy passwords for $hydratedCount of '
            '${loadedWebViewModels.length} site(s); '
            '$sitesWithCustomProxy site(s) have a non-DEFAULT per-site proxy',
        level: LogLevel.info,
        sensitivity: LogSensitivity.sensitive,
      );

      // Load cookies from secure storage (keyed by siteId or legacy domain)
      final secureCookies = await _cookieSecureStorage.loadCookies();

      // Load cookies into models by siteId (or migrate from domain-keyed).
      // Incognito sites must start each launch with no cookies — even if
      // legacy entries exist in secure storage from before the toggle was
      // flipped on (issue #298).
      for (final webViewModel in loadedWebViewModels) {
        if (webViewModel.incognito) continue;
        // Try siteId first (new format)
        var siteCookies = secureCookies[webViewModel.siteId];
        if (siteCookies == null || siteCookies.isEmpty) {
          // Fallback: try domain-keyed (legacy migration)
          final domain = extractDomain(webViewModel.initUrl);
          siteCookies = secureCookies[domain];
        }
        if (siteCookies != null && siteCookies.isNotEmpty) {
          webViewModel.cookies = siteCookies;
        }
      }

      setState(() {
        _webViewModels.addAll(loadedWebViewModels);
      });

      // NOTE: We don't restore cookies to CookieManager here anymore.
      // Cookies are restored per-site via _restoreCookiesForSite() when
      // a site is selected via _setCurrentIndex(). This enables per-site
      // cookie isolation for same-domain sites.

      // Re-save to migrate cookies to siteId-keyed format
      await _saveWebViewModels();
    }
  }

  Future<void> _restoreAppState() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      // Load theme settings, with migration from old formats
      final savedThemeSettings = prefs.getInt('themeSettings');
      if (savedThemeSettings != null) {
        _themeSettings = AppThemeSettings.fromStorageIndex(savedThemeSettings);
      } else {
        // Try to migrate from old appTheme format
        final savedAppTheme = prefs.getInt('appTheme');
        if (savedAppTheme != null && savedAppTheme < AppTheme.values.length) {
          _themeSettings = _legacyAppThemeToSettings(AppTheme.values[savedAppTheme]);
        } else {
          // Migrate from old themeMode if exists
          final oldThemeMode = prefs.getInt('themeMode');
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
      _showUrlBar = prefs.getBool('showUrlBar') ?? false;
      _showTabStrip = prefs.getBool('showTabStrip') ?? false;
      _tabStripInFullscreen = prefs.getBool('tabStripInFullscreen') ?? false;
      _showStatsBanner = prefs.getBool('showStatsBanner') ?? true;
      _linkHandlingEnabled = prefs.getBool(kLinkHandlingEnabledKey) ?? true;
      _loadShortcutRemap(prefs);
      widget.onThemeSettingsChanged(_themeSettings);
    });
    await _loadWebspaces();
    await _loadGlobalUserScripts();
    await _loadWebViewModels();
    // Webspace membership is keyed by siteId; `_loadWebViewModels` had
    // to finish before we can promote any legacy `siteIndices`-shaped
    // JSON to siteIds and seed the runtime projection.
    await _migrateLegacyWebspaceIndices();
    _resolveWebspaceIndices();
    await _migrateGlobalScriptOptIn();
    _suggestedSites = await suggested_sites.getEffectiveSuggestedSites();

    // Container API selection: query the native side once at startup so
    // every code path downstream can branch synchronously on
    // _useContainers (engine selection in _setCurrentIndex, deletion
    // path, save/restore). Returns false on Android System WebView
    // <110, iOS <17, macOS <14, and unsupported platforms.
    _useContainers = await ContainerNative.instance.isSupported();
    _containerCookieManager =
        _useContainers ? ContainerCookieManager() : null;
    LogService.instance.log(
      'Container',
      _useContainers
          ? 'Container API supported — using ContainerIsolationEngine + ContainerCookieManager'
          : 'Container API not supported — using CookieIsolationEngine + (legacy) CookieManager',
    );

    // Startup GC: sweep orphaned per-siteId encrypted storage and HTML cache
    // (sites deleted in previous sessions), then nuke the native cookie jar
    // so residual cookies from deleted/legacy sites don't leak into the next
    // activated site. `_restoreCookiesForSite` re-nukes on every switch; this
    // extra pass covers launch before any site is activated.
    final activeSiteIdsAtStartup = _webViewModels.map((m) => m.siteId).toSet();
    // HS-011: drop remap entries whose resolved target was since deleted —
    // they'd never resolve, and a fresh tap re-prompts (and re-remembers).
    if (_shortcutSiteRemap.isNotEmpty) {
      final before = _shortcutSiteRemap.length;
      _shortcutSiteRemap.removeWhere(
        (_, resolved) => !activeSiteIdsAtStartup.contains(resolved),
      );
      if (_shortcutSiteRemap.length != before) {
        await prefs.setString(
            _kShortcutRemapKey, jsonEncode(_shortcutSiteRemap));
      }
    }
    // HS-014: drop tombstones whose siteId is live again (defensive — ids are
    // unique per create, so this only fires if a backup reintroduced one).
    if (_shortcutTombstones.isNotEmpty) {
      final before = _shortcutTombstones.length;
      _shortcutTombstones =
          ShortcutTombstones.pruneLive(_shortcutTombstones, activeSiteIdsAtStartup);
      if (_shortcutTombstones.length != before) {
        await prefs.setString(
            _kShortcutTombstonesKey, jsonEncode(_shortcutTombstones));
      }
    }
    // Incognito sites are treated as orphans for any session-scoped GC
    // (cookies, html cache, navigation state, container) so on-disk
    // remnants don't outlive the process — see issue #298. Their config
    // (proxy passwords, imported HTML for file:// sites) stays put.
    final nonIncognitoSiteIds = {
      for (final m in _webViewModels)
        if (!m.incognito) m.siteId,
    };
    await _cookieSecureStorage.removeOrphanedCookies(nonIncognitoSiteIds);
    await _proxyPasswordStorage.removeOrphaned(activeSiteIdsAtStartup);
    await HtmlCacheService.instance.removeOrphanedCaches(nonIncognitoSiteIds);
    await HtmlImportStorage.instance.removeOrphanedImports(activeSiteIdsAtStartup);
    await _stateStorage.removeOrphans(nonIncognitoSiteIds);
    await _cookieManager.deleteAllCookies();
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

    // Always start at home screen on launch - only restore index if launched via shortcut
    final launch = await ShortcutService.getLaunch();
    final launchUrl = launch == null
        ? null
        : (launch.url ??
            _shortcutUrlLedger[launch.siteId] ??
            _tombstoneUrlFor(launch.siteId));
    if (launch != null) {
      LogService.instance.log(
        'Shortcut',
        'cold launch siteId=${launch.siteId} payloadUrl=${launch.url} '
            'resolvedUrl=$launchUrl',
        sensitivity: LogSensitivity.sensitive,
      );
    }
    final resolution = StartupRestoreEngine.resolveLaunch(
      shortcutSiteId: launch?.siteId,
      // iOS carries the url in the launch payload; Android pairs the id with
      // its url ledger; the iOS tombstone url is the last fallback if iOS
      // handed back a stale cached entity without a url.
      shortcutUrl: launchUrl,
      models: _webViewModels,
      rememberedRemap: _shortcutSiteRemap,
    );
    // A direct hit activates inline below; a confirm/create outcome can't show
    // a dialog mid-restore (no UI yet), so park it and prompt post-frame.
    int? indexToRestore;
    if (resolution is LaunchOpenSite) {
      indexToRestore = resolution.index;
    } else if (resolution is! LaunchNone) {
      _pendingShortcutResolution = resolution;
    }
    // A Home Shortcut represents the user's stated entry point for that
    // site — they pinned it expecting "open google maps", not "resume
    // wherever I last drifted to". Reset the launched site's currentUrl
    // to its initUrl so a tapped shortcut always lands on the home URL,
    // regardless of where the previous session ended up (issue #298).
    if (indexToRestore != null) {
      final m = _webViewModels[indexToRestore];
      if (m.currentUrl != m.initUrl) {
        m.currentUrl = m.initUrl;
      }
      // Webspace-scoped reset: every flagged sibling in a webspace that
      // contains the launched site also drops to its initUrl. Mostly a
      // no-op on cold launch (fromJson already stripped currentUrl for
      // flagged sites) but kept here for defense in depth and parity
      // with the warm-launch path in `_handleShortcutIntent`.
      _resetAlwaysOpenHomeOnShortcut(indexToRestore);
    }

    // Auto-load notification sites so they start polling immediately and
    // can fire notifications without waiting for the user to open them.
    for (int i = 0; i < _webViewModels.length; i++) {
      if (_webViewModels[i].effectiveNotificationsEnabled) {
        _loadedIndices.add(i);
      }
    }

    // Apply saved theme BEFORE _setCurrentIndex so the first build sees
    // the right currentTheme — initialHtml reads it to pick the dark
    // prelude for cached HTML (file:// imports especially, which never
    // reload to live and so paint with whatever prelude the first build
    // chose). Models default to WebViewTheme.light, so without this the
    // first frame on a dark theme flashes white before the controller
    // is created and re-applies via setController().
    final webViewTheme = _themeModeToWebViewTheme(_themeSettings.themeMode);
    for (var webViewModel in List.from(_webViewModels)) {
      await webViewModel.setTheme(webViewTheme);
    }

    // Set current index (async for cookie restoration)
    await _setCurrentIndex(indexToRestore);
    if (!mounted) return;
    setState(() {}); // Trigger UI update after async operation

    // HS-011: a shortcut whose siteId is gone but that carried a url needs a
    // confirm/create prompt. The UI is up now, so fire it on the next frame.
    if (_pendingShortcutResolution != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final pending = _pendingShortcutResolution;
        _pendingShortcutResolution = null;
        if (pending != null) {
          unawaited(_applyInteractiveShortcut(pending, coldLaunch: true));
        }
      });
    }

    // Refresh the iOS App Intents picker on every launch, not just on save.
    // iOS queries `suggestedEntities()` (and may re-materialize the per-site
    // App Shortcuts) whenever Shortcuts.app is touched; if the App Group was
    // never repopulated this session it can serve a stale single entry whose
    // bound target no longer matches its title. Re-syncing here also re-fires
    // `updateAppShortcutParameters()` so iOS re-reads the current site list.
    _syncShortcutSites();

    _startForegroundPollTimer();

    await NotificationService.instance.init();
    NotificationService.instance.onNotificationTapped = _onNotificationTapped;

    // Cold-start path for ACTION_SEND share intents: open AddSiteScreen
    // prefilled with the shared URL once startup is settled. The resumed
    // lifecycle hook handles the warm path.
    unawaited(_handleShareIntent());

    // iOS: register the BGAppRefreshTask handler so opportunistic wakeups
    // reload notification webviews. No-op on other platforms.
    BackgroundTaskService.instance.onBackgroundRefresh =
        _refreshNotificationSites;
    BackgroundTaskService.instance.initialize();
    if (_anyNotificationSites()) {
      unawaited(BackgroundTaskService.instance.scheduleNextRefresh());
    }
  }

  bool _anyNotificationSites() {
    for (final m in _webViewModels) {
      if (m.effectiveNotificationsEnabled) return true;
    }
    return false;
  }

  /// NOTIF-005-A: Android `ProxyController` is process-wide, so a site
  /// can become a notification (background-poll) site only if every
  /// other already-enabled notification site shares its proxy
  /// fingerprint. Returns the first conflicting site's name (for
  /// explanatory subtitle) or `null` if [target] is free to enable.
  ///
  /// No-op (returns null) on non-Android — iOS uses `BGAppRefreshTask`
  /// which doesn't share a process-wide proxy controller.
  String? _notificationsBlockedBySite(WebViewModel target) {
    if (!Platform.isAndroid) return null;
    final others = <WebViewModel>[];
    for (final m in _webViewModels) {
      if (identical(m, target)) continue;
      if (!m.effectiveNotificationsEnabled) continue;
      others.add(m);
    }
    final conflict = ProxyConflictEngine.firstConflict(
      targetProxy: target.proxySettings,
      otherEnabledProxies: others.map((m) => m.proxySettings),
    );
    if (conflict == null) return null;
    final blocker = _webViewModels.firstWhere(
      (m) => identical(m.proxySettings, conflict),
      orElse: () => target,
    );
    return blocker.name.isNotEmpty
        ? blocker.name
        : (blocker.initUrl.isNotEmpty ? blocker.initUrl : 'Another site');
  }

  /// NOTIF-005-{I,A}: ensure a background refresh is scheduled iff at
  /// least one notification site is loaded. iOS uses `BGAppRefreshTask`,
  /// Android uses a `WorkManager` `PeriodicWorkRequest` (15-min minimum).
  /// Both submissions are idempotent — the platform replaces any existing
  /// pending request for the same identifier / unique-work name.
  Future<void> _updateBackgroundRefreshSchedule() async {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    bool any = false;
    for (int i = 0; i < _webViewModels.length; i++) {
      final m = _webViewModels[i];
      if (!m.effectiveNotificationsEnabled) continue;
      if (!_loadedIndices.contains(i)) continue;
      any = true;
      break;
    }
    if (any) {
      await BackgroundTaskService.instance.scheduleNextRefresh();
    } else {
      await BackgroundTaskService.instance.cancelScheduledRefreshes();
    }
  }

  /// Reload every notification site so its page JS gets a chance to fire
  /// pending notifications. Called by:
  ///   1. The 5-minute foreground poll tick (skips the active site so the
  ///      user's interaction isn't disrupted).
  ///   2. The iOS BGAppRefreshTask handler (no active-site exclusion since
  ///      the app is suspended at that point).
  Future<void> _refreshNotificationSites({bool excludeActive = false}) async {
    for (int i = 0; i < _webViewModels.length; i++) {
      final m = _webViewModels[i];
      if (!m.effectiveNotificationsEnabled) continue;
      if (excludeActive && i == _currentIndex) continue;
      if (!_loadedIndices.contains(i)) continue;
      try {
        await m.controller?.reload();
      } catch (_) {
        // Controller may have been disposed mid-iteration.
      }
    }
  }

  void _onNotificationTapped(String siteId) {
    final index = _webViewModels.indexWhere((m) => m.siteId == siteId);
    if (index < 0) {
      LogService.instance.log(
        'Notification',
        'Tap for unknown siteId: $siteId',
        level: LogLevel.warning,
        sensitivity: LogSensitivity.sensitive,
      );
      return;
    }
    LogService.instance.log(
      'Notification',
      'Tap routing to site $index: "${_webViewModels[index].name}"',
      sensitivity: LogSensitivity.sensitive,
    );
    _setCurrentIndex(index);
    if (mounted) setState(() {});
  }

  void _startForegroundPollTimer() {
    _foregroundPollTimer?.cancel();
    _foregroundPollTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _onForegroundPollTick(),
    );
  }

  SiteRetentionPriority _siteRetentionPriority(int index) {
    if (index == _currentIndex) return SiteRetentionPriority.active;
    if (index == _activationInFlightIndex) return SiteRetentionPriority.activating;
    if (index >= 0 && index < _webViewModels.length) {
      final m = _webViewModels[index];
      if (m.effectiveNotificationsEnabled) {
        return SiteRetentionPriority.notification;
      }
    }
    final webspaceIndices = _getFilteredSiteIndices().toSet();
    if (webspaceIndices.contains(index)) return SiteRetentionPriority.webspace;
    return SiteRetentionPriority.loaded;
  }

  void _onForegroundPollTick() {
    unawaited(_refreshNotificationSites(excludeActive: true));
  }

  Future<void> launchUrl(String url, {
    String? homeTitle,
    required String? siteId,
    required bool incognito,
    required bool thirdPartyCookiesEnabled,
    required bool clearUrlEnabled,
    required bool dnsBlockEnabled,
    required bool contentBlockEnabled,
    required bool localCdnEnabled,
    required bool trackingProtectionEnabled,
    required String? language,
    required int zoomPercent,
    LocationMode locationMode = LocationMode.off,
    double? spoofLatitude,
    double? spoofLongitude,
    double spoofAccuracy = 50.0,
    String? spoofTimezone,
    bool spoofTimezoneFromLocation = false,
    LocationGranularity liveLocationGranularity = LocationGranularity.gps,
    WebRtcPolicy webRtcPolicy = WebRtcPolicy.defaultPolicy,
    required List<UserScriptConfig> userScripts,
    UserProxySettings? proxySettings,
    bool notificationsEnabled = false,
  }) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => InAppWebViewScreen(
          url: url,
          homeTitle: homeTitle,
          siteId: siteId,
          incognito: incognito,
          thirdPartyCookiesEnabled: thirdPartyCookiesEnabled,
          clearUrlEnabled: clearUrlEnabled,
          dnsBlockEnabled: dnsBlockEnabled,
          contentBlockEnabled: contentBlockEnabled,
          localCdnEnabled: localCdnEnabled,
          trackingProtectionEnabled: trackingProtectionEnabled,
          language: language,
          zoomPercent: zoomPercent,
          showUrlBar: _showUrlBar,
          locationMode: locationMode,
          spoofLatitude: spoofLatitude,
          spoofLongitude: spoofLongitude,
          spoofAccuracy: spoofAccuracy,
          spoofTimezone: spoofTimezone,
          spoofTimezoneFromLocation: spoofTimezoneFromLocation,
          liveLocationGranularity: liveLocationGranularity,
          webRtcPolicy: webRtcPolicy,
          userScripts: userScripts,
          onConfirmScriptFetch: _confirmScriptFetch,
          onProtectedMediaRequest: _promptProtectedMedia,
          onShowUrlBarChanged: (show) async {
            if (!mounted) return;
            setState(() {
              _showUrlBar = show;
            });
            await _saveShowUrlBar();
          },
          proxySettings: proxySettings,
          notificationsEnabled: notificationsEnabled,
        ),
      ),
    );
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

  /// Stable callback for the user-script fetch-from-URL confirmation prompt.
  /// Used by both the parent webview (via `getWebView`) and the nested
  /// `InAppWebViewScreen` so external dependency loading prompts the user
  /// the same way regardless of where the webview was opened.
  Future<bool> _confirmScriptFetch(String url) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Load external script?'),
        content: Text(
          'A user script wants to load:\n\n$url\n\n'
          'This URL is not on the trusted CDN list. Allow?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Deny'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Stable callback for the protected-content (Widevine/EME) permission
  /// popup. Shown the first time a site requests `PROTECTED_MEDIA_ID` (e.g.
  /// the Spotify web player). The per-site decision is remembered by the
  /// caller (the parent webview persists it on the `WebViewModel`; nested
  /// webviews remember it in-memory), so this only collects user intent.
  Future<bool> _promptProtectedMedia(String origin) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Play protected content?'),
        content: Text(
          '$origin wants to play protected (DRM) content.\n\n'
          'Allowing this lets the site provision a device identifier to '
          'decrypt the media. Your choice is remembered for this site.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Block'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _toggleFind() {
    setState(() {
      _isFindVisible = !_isFindVisible;
    });
  }

  void _enterFullscreen() {
    if (_isFullscreen) return;
    setState(() {
      _isFullscreen = true;
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Tap the top of the screen to exit full screen'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _exitFullscreen() {
    if (!_isFullscreen) return;
    setState(() {
      _isFullscreen = false;
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
          allSites: _webViewModels,
          onSave: (updatedWebspace) {
            // The editor returns positional siteIndices; translate to
            // siteIds (the persisted source of truth) before storing.
            final selectedSiteIds = <String>[
              for (final i in updatedWebspace.siteIndices)
                if (i >= 0 && i < _webViewModels.length)
                  _webViewModels[i].siteId,
            ];
            setState(() {
              _webspaces.add(updatedWebspace.copyWith(siteIds: selectedSiteIds));
              _resolveWebspaceIndices();
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
            siteIds: [for (final m in _webViewModels) m.siteId],
            siteIndices: List<int>.generate(_webViewModels.length, (index) => index),
          )
        : webspace;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WebspaceDetailScreen(
          webspace: webspaceToEdit,
          allSites: _webViewModels,
          isReadOnly: webspace.id == kAllWebspaceId,
          onSave: (updatedWebspace) {
            // Don't save changes for "All" webspace
            if (updatedWebspace.id == kAllWebspaceId) return;

            // Translate the editor's index-based selection back into
            // the siteId-keyed persisted membership.
            final selectedSiteIds = <String>[
              for (final i in updatedWebspace.siteIndices)
                if (i >= 0 && i < _webViewModels.length)
                  _webViewModels[i].siteId,
            ];
            setState(() {
              final index = _webspaces.indexWhere((ws) => ws.id == updatedWebspace.id);
              if (index != -1) {
                _webspaces[index] = updatedWebspace.copyWith(siteIds: selectedSiteIds);
                _resolveWebspaceIndices();
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
    if (webspace.id == kAllWebspaceId) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot delete the "All" webspace')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete Webspace'),
        content: Text('Are you sure you want to delete "${webspace.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final wasSelected = _selectedWebspaceId == webspace.id;
    setState(() {
      _webspaces.removeWhere((ws) => ws.id == webspace.id);
      if (wasSelected) {
        _selectedWebspaceId = kAllWebspaceId; // Select "All" instead of null
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
    if (_selectedWebspaceId == webspace.id) {
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
      final previousIndices = _getFilteredSiteIndices().toSet();

      setState(() {
        _selectedWebspaceId = webspace.id;
      });

      // Open drawer immediately so the user sees instant feedback on tap
      _scaffoldKey.currentState?.openDrawer();

      // Get indices in the new webspace
      final newIndices = _getFilteredSiteIndices().toSet();

      // Only unload sites when online - preserve live webviews when offline
      // so users can still view cached content
      final online = await ConnectivityService.instance.isOnline();
      if (!mounted || version != _selectWebspaceVersion) return;

      if (online) {
        // Under container mode, sites are isolated by their per-site
        // container (cookies, localStorage, IDB, ServiceWorkers, HTTP
        // cache) and stay resident across webspace switches — keeping
        // them loaded is harmless and avoids the cost of re-creating the
        // webview when the user switches back. The unload-on-switch only
        // runs in legacy mode where the cookie jar is shared.
        final indicesToUnload = SiteUnloadEngine.indicesToUnloadOnWebspaceSwitch(
          useContainers: _useContainers,
          loadedIndices: _loadedIndices,
          previousWebspaceIndices: previousIndices,
          newWebspaceIndices: newIndices,
        );

        for (final index in indicesToUnload) {
          if (index >= 0 && index < _webViewModels.length) {
            // Capture state before dispose so re-activation can
            // restore the back/forward stack and (Apple) form data.
            // Skipped for incognito sites inside the helper.
            await _captureStateForRestore(_webViewModels[index]);
            if (!mounted || version != _selectWebspaceVersion) return;
            _webViewModels[index].disposeWebView();
            _loadedIndices.remove(index);
            LogService.instance.log(
              'WebspaceSwitch',
              'Unloaded site $index: "${_webViewModels[index].name}"',
              sensitivity: LogSensitivity.sensitive,
            );
          }
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
      final webspace = _webspaces.removeAt(oldIndex);
      _webspaces.insert(newIndex, webspace);
    });
    _saveWebspaces();
  }

  List<int> _getFilteredSiteIndices() {
    return WebspaceSelectionEngine.filteredSiteIndices(
      selectedWebspaceId: _selectedWebspaceId,
      webspaces: _webspaces,
      siteCount: _webViewModels.length,
    );
  }

  void _cleanupWebspaceIndices() {
    WebspaceSelectionEngine.cleanupWebspaceIndices(
      webspaces: _webspaces,
      siteCount: _webViewModels.length,
    );
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
        _webViewModels.where((m) => !m.isArchiveTier).toList();

    // When archives are open, offer to bundle them into the backup as
    // opaque encrypted sections. The prompt only appears while archives
    // are open (their content is already visible in the switcher at
    // that point); a backup with none open is byte-identical to one
    // produced without the feature.
    List<String>? extraSections;
    final open = _archive.openArchives;
    if (open.isNotEmpty) {
      final include = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Include open archives?'),
          content: Text(
            'You have ${open.length} archive(s) open. Include them in this '
            'backup? They stay encrypted, but the file will reveal that '
            'archived data exists.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Exclude'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Include'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (include == true) {
        extraSections = [
          for (final h in open) await _archive.exportSection(h),
        ];
      }
    }

    await SettingsBackupService.exportAndSave(
      context,
      webViewModels: appTierModels,
      webspaces: _webspaces,
      themeMode: _themeSettings.toStorageIndex(),
      globalPrefs: readExportedAppPrefs(prefs),
      selectedWebspaceId: _selectedWebspaceId,
      currentIndex: _currentIndex != null &&
              _currentIndex! < appTierModels.length
          ? _currentIndex
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
  Future<void> _importSettings() async {
    final backup = await SettingsBackupService.pickAndImport(context);
    if (backup == null) {
      return;
    }

    // Show confirmation dialog with backup info
    final sitesCount = backup.sites.length;
    final webspacesCount = backup.webspaces.length;
    final exportDate = backup.exportedAt.toLocal().toString().split('.')[0];

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Import Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Import $sitesCount site(s) and $webspacesCount webspace(s)?'),
            SizedBox(height: 12),
            Text(
              'Exported: $exportDate',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            SizedBox(height: 16),
            Text(
              'Your login sessions will be preserved for matching domains. '
              'Logins for removed sites will be cleared.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Import'),
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

    // Apply the imported settings
    setState(() {
      // Clear existing data
      _webViewModels.clear();
      _webspaces.clear();
      _loadedIndices.clear(); // Clear lazy loading state

      // Restore sites
      _webViewModels.addAll(
        SettingsBackupService.restoreSites(backup, () {
          setState(() {});
        }),
      );

      // Restore webspaces. Legacy backups carry `siteIndices`-shaped
      // webspaces; promote those to siteIds against the just-restored
      // models and seed the runtime projection.
      _webspaces.addAll(SettingsBackupService.restoreWebspaces(backup));

      // Restore other settings - handle both new and legacy formats.
      // Every boolean/int/string global toggle is routed through the
      // kExportedAppPrefs registry, so adding a new one requires zero
      // additional code here.
      _themeSettings = AppThemeSettings.fromStorageIndex(backup.themeMode);
      _showUrlBar =
          backup.globalPrefs['showUrlBar'] as bool? ?? _showUrlBar;
      _showTabStrip =
          backup.globalPrefs['showTabStrip'] as bool? ?? _showTabStrip;
      _tabStripInFullscreen =
          backup.globalPrefs['tabStripInFullscreen'] as bool? ?? _tabStripInFullscreen;
      _showStatsBanner =
          backup.globalPrefs['showStatsBanner'] as bool? ?? _showStatsBanner;

      // Restore selection state
      if (backup.selectedWebspaceId != null &&
          _webspaces.any((ws) => ws.id == backup.selectedWebspaceId)) {
        _selectedWebspaceId = backup.selectedWebspaceId;
      } else {
        _selectedWebspaceId = kAllWebspaceId;
      }
    });

    // Same boot dance: legacy `siteIndices`-shaped webspaces in the
    // backup need to be promoted to siteIds, then the runtime
    // projection has to be seeded from the (now-restored) models.
    await _migrateLegacyWebspaceIndices();
    _resolveWebspaceIndices();

    // Restore current index if valid (async for cookie handling)
    int? indexToRestore;
    if (backup.currentIndex != null &&
        backup.currentIndex! >= 0 &&
        backup.currentIndex! < _webViewModels.length) {
      indexToRestore = backup.currentIndex;
    }
    // If no site is activated, _setCurrentIndex returns without routing
    // through _restoreCookiesForSite — which means pre-import cookies from
    // the previously-active site remain in the native jar. Nuke explicitly.
    if (indexToRestore == null) {
      await _cookieManager.deleteAllCookies();
    }
    await _setCurrentIndex(indexToRestore);
    setState(() {}); // Update UI after async operation

    // Apply theme to app
    widget.onThemeSettingsChanged(_themeSettings);

    // Save all settings. Global UI toggles go through the registry so
    // new entries in kExportedAppPrefs are automatically persisted.
    // Per PWD-005 the backup file does not carry proxy passwords, so
    // there's nothing to route into secure storage here — the user will
    // re-enter passwords on the proxy settings screen, just like they
    // re-log into sites whose secure cookies were stripped.
    final prefsToWrite = await SharedPreferences.getInstance();
    await writeExportedAppPrefs(prefsToWrite, backup.globalPrefs);
    // Hydrate the in-memory GlobalOutboundProxy from the (password-less)
    // imported value so subsequent outbound calls pick up the new
    // address/username without an app restart.
    final reloadedPrefs = await SharedPreferences.getInstance();
    await GlobalOutboundProxy.update(readGlobalOutboundProxy(reloadedPrefs));
    // Restore the downloaded-data blockers' user intent. Both carry only
    // the selection (DNS level / list URLs + enabled), never the blob —
    // the user re-downloads from App Settings to activate blocking.
    if (backup.dnsBlockLevel != null) {
      await DnsBlockService.instance.applyImportedLevel(backup.dnsBlockLevel!);
    }
    if (backup.contentBlockerLists != null) {
      await ContentBlockerService.instance
          .importListSelection(backup.contentBlockerLists!);
    }
    await _saveWebViewModels();
    await _saveWebspaces();
    await _saveThemeSettings();
    await _saveSelectedWebspaceId();
    await _saveCurrentIndex();

    // Restore global user scripts if present in backup
    if (backup.globalUserScripts != null) {
      _globalUserScripts = backup.globalUserScripts!
          .map((e) => UserScriptConfig.fromJson(e))
          .toList();
    }
    await _saveGlobalUserScripts();

    // Restore suggested sites if present in backup
    if (backup.suggestedSites != null) {
      _suggestedSites = backup.suggestedSites!
          .map((e) => SiteSuggestion(
                name: e['name'] as String,
                url: e['url'] as String,
                domain: e['domain'] as String,
              ))
          .toList();
      await suggested_sites.saveSuggestedSites(_suggestedSites);
    }

    // Clean up orphaned cookies and HTML cache (for siteIds no longer in any site).
    // Note: we do NOT nuke the native cookie jar here — `_setCurrentIndex` above
    // already routed through `_restoreCookiesForSite`, which nuked and restored
    // the imported active site's cookies. Another nuke here would wipe the
    // session we just restored and log the user out of the imported active site.
    final activeSiteIds = _webViewModels
        .map((model) => model.siteId)
        .toSet();
    await _cookieSecureStorage.removeOrphanedCookies(activeSiteIds);
    await _proxyPasswordStorage.removeOrphaned(activeSiteIds);
    await HtmlCacheService.instance.removeOrphanedCaches(activeSiteIds);
    await HtmlImportStorage.instance.removeOrphanedImports(activeSiteIds);

    // Apply theme to all webviews
    final webViewTheme = _themeModeToWebViewTheme(_themeSettings.themeMode);
    for (var webViewModel in _webViewModels) {
      await webViewModel.setTheme(webViewTheme);
    }

    if (mounted) {
      // Surface the strip-from-export contract (PWD-005) when the source
      // device had a proxy username configured — a strong proxy for "had
      // a proxy password too" (since the username is meaningless without
      // one). Detected from the imported backup, not the live state, so
      // the hint fires even if hydration from secure storage hasn't
      // finished yet.
      bool hasProxyUsername(Map<String, dynamic>? proxy) =>
          proxy != null &&
          proxy['username'] is String &&
          (proxy['username'] as String).isNotEmpty;
      final perSiteProxyAuth = backup.sites
          .any((s) => hasProxyUsername(s['proxySettings'] as Map<String, dynamic>?));
      Map<String, dynamic>? globalProxyJson;
      try {
        final raw = backup.globalPrefs[kGlobalOutboundProxyKey];
        if (raw is String && raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) globalProxyJson = decoded;
        }
      } catch (_) {/* malformed global proxy entry → no hint */}
      final globalProxyAuth = hasProxyUsername(globalProxyJson);
      final stripped = perSiteProxyAuth || globalProxyAuth;
      // Blocklist/filter-list blobs aren't in the backup — only the
      // selection. Hint the user to re-download if they had either set.
      final needsBlocklistRedownload =
          (backup.dnsBlockLevel ?? 0) > 0 ||
              (backup.contentBlockerLists
                      ?.any((e) => e['enabled'] == true) ??
                  false);
      final hints = <String>[
        if (stripped)
          'Proxy passwords aren\'t included in backups — re-enter them in '
              'site / app settings.',
        if (needsBlocklistRedownload)
          'Re-download DNS / content blocker lists in App Settings to '
              'activate blocking.',
      ];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(hints.isEmpty
              ? 'Settings imported successfully'
              : 'Settings imported. ${hints.join(' ')}'),
          duration: Duration(seconds: hints.isEmpty ? 4 : 6),
        ),
      );
    }

    // If the backup carries encrypted sections, offer to restore them
    // by passphrase. Each prompt restores the section(s) matching the
    // entered passphrase; remaining ones can be restored by entering
    // another passphrase, or skipped by cancelling.
    final sections = backup.extraSections;
    if (sections != null && sections.isNotEmpty && mounted) {
      await _restoreBackupSections(sections);
    }
  }

  Future<void> _restoreBackupSections(List<String> sections) async {
    var remaining = List<String>.from(sections);
    while (remaining.isNotEmpty && mounted) {
      final passphrase = await _showPassphraseDialog(
        title: 'Restore archived data',
        hint: 'Passphrase (cancel to skip)',
        submitLabel: 'Restore',
      );
      if (passphrase == null || passphrase.isEmpty) break;
      final before = remaining.length;
      final unmatched = await _archive.importSections(passphrase, remaining);
      if (!mounted) return;
      final restored = before - unmatched.length;
      remaining = unmatched;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(restored > 0
              ? 'Restored $restored archived section(s)'
              : 'No section matched that passphrase'),
        ),
      );
    }
  }

  WebViewController? getController() {
    if(_currentIndex == null) {
      return null;
    }
    return _webViewModels[_currentIndex!].getController(launchUrl, _cookieManager, _containerCookieManager, _saveWebViewModels, globalUserScripts: _globalUserScripts);
  }

  /// User-driven reload of the current site (Refresh button, Clear-cookies).
  /// Delegates to [WebViewModel.userDrivenReload] which drops the
  /// HtmlCacheService snapshot and the chromium HTTP cache before the
  /// reload, so the user actually gets fresh content instead of being
  /// served the same stale page from disk cache (issue #290).
  Future<void> _refreshCurrentSite() async {
    if (_currentIndex == null || _currentIndex! >= _webViewModels.length) return;
    await _webViewModels[_currentIndex!].userDrivenReload();
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
    if (index < 0 || index >= _webViewModels.length) return;
    final model = _webViewModels[index];
    final plan = SiteDataClearEngine.planClear(useContainers: _useContainers);

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
        }
        if (plan.clearInModelCookies) {
          model.cookies = const [];
        }
      });
    }

    if (plan.deleteKnownCookies) {
      await model.deleteCookies(_cookieManager, _containerCookieManager);
    }
    await _saveWebViewModels();
    if (!mounted) return;
    if (plan.userDrivenReload) {
      await _refreshCurrentSite();
    }
  }

  Future<void> _stopCurrentSiteLoading() async {
    if (_currentIndex == null || _currentIndex! >= _webViewModels.length) return;
    await _webViewModels[_currentIndex!].userStopLoading();
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
  void _resetAlwaysOpenHomeOnShortcut(int launchedIndex) {
    final indices = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
      launchedIndex: launchedIndex,
      webspaces: _webspaces,
      flag: (i) {
        if (i < 0 || i >= _webViewModels.length) return false;
        final m = _webViewModels[i];
        return m.alwaysOpenHome || m.incognito;
      },
    );
    for (final i in indices) {
      final m = _webViewModels[i];
      if (m.currentUrl == m.initUrl && m.webview == null) continue;
      _evictCacheIfOnline(m.siteId);
      m.currentUrl = m.initUrl;
      m.disposeWebView();
      _loadedIndices.remove(i);
    }
  }

  /// Reset every URL-ephemeral site (`alwaysOpenHome`, or incognito which
  /// implies it per AOH-005) back to its initUrl when the app leaves the
  /// foreground, disposing the live webview so the next foreground rebuild
  /// loads home. Cookies, localStorage, and other persistent state are left
  /// intact — that is the boundary between this toggle and incognito.
  ///
  /// Notification sites are skipped: their page must keep running in the
  /// background to fire notifications, and resetting the URL would tear it
  /// down. The active site stays in `_loadedIndices` (only its webview is
  /// dropped) so the IndexedStack still has a child to rebuild at initUrl.
  /// Returns true if the currently-active site was reset, so the caller can
  /// skip the now-redundant pause/capture and schedule a rebuild instead.
  bool _resetAlwaysOpenHomeForAppClose() {
    bool activeReset = false;
    for (int i = 0; i < _webViewModels.length; i++) {
      final m = _webViewModels[i];
      if (!(m.alwaysOpenHome || m.incognito)) continue;
      if (m.effectiveNotificationsEnabled) continue;
      if (m.currentUrl == m.initUrl && m.webview == null) continue;
      _evictCacheIfOnline(m.siteId);
      m.currentUrl = m.initUrl;
      m.disposeWebView();
      if (i == _currentIndex) {
        activeReset = true;
      } else {
        _loadedIndices.remove(i);
      }
    }
    return activeReset;
  }

  void _goHome() {
    if (_currentIndex == null || _currentIndex! >= _webViewModels.length) return;
    final model = _webViewModels[_currentIndex!];
    _evictCacheIfOnline(model.siteId);
    model.currentUrl = model.initUrl;
    model.disposeWebView();
    setState(() {});
    // Re-apply fullscreen for sites with auto-fullscreen after webview recreation
    if (model.fullscreenMode) {
      _enterFullscreen();
    }
    _saveWebViewModels();
  }

  IconData _getThemeIcon() {
    switch (_themeSettings.themeMode) {
      case ThemeMode.light:
        return Icons.wb_sunny;
      case ThemeMode.dark:
        return Icons.nights_stay;
      case ThemeMode.system:
        return Icons.brightness_auto;
    }
  }

  String _getThemeTooltip() {
    final modeName = _themeSettings.themeMode == ThemeMode.system
        ? 'System'
        : _themeSettings.themeMode == ThemeMode.light
            ? 'Light'
            : 'Dark';
    final colorName = _themeSettings.accentColor == AccentColor.blue ? 'Blue' : 'Green';
    return '$modeName $colorName theme';
  }

  String _getThemeName() {
    final modeName = _themeSettings.themeMode == ThemeMode.system
        ? 'System'
        : _themeSettings.themeMode == ThemeMode.light
            ? 'Light'
            : 'Dark';
    final colorName = _themeSettings.accentColor == AccentColor.blue ? 'Blue' : 'Green';
    return '$modeName $colorName';
  }

  AppBar _buildAppBar() {
    return AppBar(
      title: _currentIndex != null && _currentIndex! < _webViewModels.length
          ? GestureDetector(
              onDoubleTap: _toggleFullscreen,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      _webViewModels[_currentIndex!].getDisplayName(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ],
              ),
            )
          : Text(_selectedWebspaceId != null
              ? _webspaces.firstWhere(
                  (ws) => ws.id == _selectedWebspaceId,
                  orElse: () => Webspace(name: 'Unknown'),
                ).name
              : 'No Webspace Selected'),
      actions: [
        const DownloadButton(),
        IconButton(
          icon: Icon(_getThemeIcon()),
          tooltip: _getThemeTooltip(),
          onPressed: () async {
            setState(() {
              final newMode = _themeSettings.themeMode == ThemeMode.light
                  ? ThemeMode.dark
                  : _themeSettings.themeMode == ThemeMode.dark
                      ? ThemeMode.system
                      : ThemeMode.light;
              _themeSettings = _themeSettings.copyWith(themeMode: newMode);
            });
            widget.onThemeSettingsChanged(_themeSettings);
            await _saveThemeSettings();
            if (!mounted) return;

            final webViewTheme = _themeModeToWebViewTheme(_themeSettings.themeMode);
            for (var webViewModel in List.from(_webViewModels)) {
              await webViewModel.setTheme(webViewTheme);
            }
          },
        ),
        // Settings icon button (only visible on webspaces list screen)
        if (_currentIndex == null || _currentIndex! >= _webViewModels.length)
          IconButton(
            icon: Icon(Icons.settings),
            tooltip: 'App Settings',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AppSettingsScreen(
                    currentSettings: _themeSettings,
                    onSettingsChanged: (AppThemeSettings newSettings) async {
                      setState(() {
                        _themeSettings = newSettings;
                      });
                      widget.onThemeSettingsChanged(_themeSettings);
                      await _saveThemeSettings();
                      if (!mounted) return;

                      final webViewTheme = _themeModeToWebViewTheme(_themeSettings.themeMode);
                      for (var webViewModel in List.from(_webViewModels)) {
                        await webViewModel.setTheme(webViewTheme);
                      }
                    },
                    onExportSettings: _exportSettings,
                    onImportSettings: _importSettings,
                    onRestoreArchive: _promptRestoreArchive,
                    hasOpenArchives: _archiveSlices.isNotEmpty,
                    onCloseAllArchives: () async {
                      await _closeAllArchives();
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Archives closed'),
                        ),
                      );
                    },
                    showTabStrip: _showTabStrip,
                    onShowTabStripChanged: (value) {
                      setState(() {
                        _showTabStrip = value;
                      });
                      _saveShowTabStrip();
                    },
                    tabStripInFullscreen: _tabStripInFullscreen,
                    onTabStripInFullscreenChanged: (value) {
                      setState(() {
                        _tabStripInFullscreen = value;
                      });
                      _saveTabStripInFullscreen();
                    },
                    showStatsBanner: _showStatsBanner,
                    onShowStatsBannerChanged: (value) {
                      setState(() {
                        _showStatsBanner = value;
                      });
                      _saveShowStatsBanner();
                    },
                    linkHandlingEnabled: _linkHandlingEnabled,
                    onLinkHandlingEnabledChanged: (value) {
                      setState(() => _linkHandlingEnabled = value);
                      _saveLinkHandlingEnabled();
                    },
                    onOpenLinkHandlingSettings: _openLinkHandlingSettings,
                    globalUserScripts: _globalUserScripts,
                    onGlobalUserScriptsChanged: (scripts) {
                      _globalUserScripts = scripts;
                      _saveGlobalUserScripts();
                      _resetAllWebViews();
                    },
                    onOutboundProxyChanged: _resetAllWebViews,
                  ),
                ),
              );
            },
          ),
        if (_currentIndex != null && _currentIndex! < _webViewModels.length && !_showTabStrip)
          PopupMenuButton<String>(
            itemBuilder: (BuildContext context) {
              return [
                PopupMenuItem<String>(
                  padding: EdgeInsets.zero,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        icon: Icon(Icons.arrow_back),
                        tooltip: 'Go Back',
                        onPressed: () {
                          Navigator.pop(context);
                          () async {
                            final controller = getController();
                            if (controller != null) {
                              final canGoBack = await controller.canGoBack();
                              if (canGoBack) {
                                await controller.goBack();
                              }
                            }
                          }();
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.home),
                        tooltip: 'Go to Home',
                        onPressed: () {
                          Navigator.pop(context);
                          _goHome();
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.share),
                        tooltip: 'Share',
                        onPressed: () {
                          Navigator.pop(context);
                          if (_currentIndex != null && _currentIndex! < _webViewModels.length) {
                            final model = _webViewModels[_currentIndex!];
                            final url = model.currentUrl ?? model.initUrl;
                            SharePlus.instance.share(ShareParams(uri: Uri.parse(url)));
                          }
                        },
                      ),
                      Builder(builder: (context) {
                        final model = _currentIndex != null
                            ? _webViewModels[_currentIndex!]
                            : null;
                        final loading = model?.isLoading ?? false;
                        return IconButton(
                          icon: Icon(loading ? Icons.close : Icons.refresh),
                          tooltip: loading ? 'Stop' : 'Refresh',
                          onPressed: () {
                            Navigator.pop(context);
                            if (loading) {
                              _stopCurrentSiteLoading();
                            } else {
                              _refreshCurrentSite();
                            }
                          },
                        );
                      }),
                    ],
                  ),
                ),
                PopupMenuDivider(),
                PopupMenuItem<String>(
                  value: "search",
                  child: Row(
                    children: [
                      Icon(Icons.search),
                      SizedBox(width: 8),
                      Text("Find"),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: "toggleUrlBar",
                  child: Row(
                    children: [
                      Icon(_showUrlBar ? Icons.visibility_off : Icons.visibility),
                      SizedBox(width: 8),
                      Text(_showUrlBar ? "Hide URL Bar" : "Show URL Bar"),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: "fullscreen",
                  child: Row(
                    children: [
                      Icon(_isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                      SizedBox(width: 8),
                      Text(_isFullscreen ? "Exit Full Screen" : "Full Screen"),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: "settings",
                  child: Row(
                    children: [
                      Icon(Icons.settings),
                      SizedBox(width: 8),
                      Text("Settings"),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: "devTools",
                  child: Row(
                    children: [
                      Icon(Icons.code),
                      SizedBox(width: 8),
                      Text("Developer Tools"),
                    ],
                  ),
                ),
                if (_currentIndex != null && _isHomeShortcutMenuVisible(_currentIndex!))
                  PopupMenuItem<String>(
                    value: "addToHome",
                    child: Row(
                      children: [
                        Icon(Icons.add_to_home_screen),
                        SizedBox(width: 8),
                        Text("Home Shortcut"),
                      ],
                    ),
                  ),
              ];
            },
            onSelected: (String value) async {
              switch(value) {
                case 'search':
                  _toggleFind();
                break;
                case 'fullscreen':
                  _toggleFullscreen();
                break;
                case 'settings':
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => SettingsScreen(
                        webViewModel: _webViewModels[_currentIndex!],
                        otherSites: _webViewModels
                            .where((m) => m.siteId != _webViewModels[_currentIndex!].siteId)
                            .toList(growable: false),
                        useContainers: _useContainers,
                        notificationsBlockedBySite: _notificationsBlockedBySite(_webViewModels[_currentIndex!]),
                        globalUserScripts: _globalUserScripts,
                        onGlobalUserScriptsChanged: (scripts) {
                          _globalUserScripts = scripts;
                          _saveGlobalUserScripts();
                          _resetAllWebViews();
                        },
                        onScriptsChanged: _resetCurrentSiteWebView,
                        onClearCookies: () => _clearSiteData(_currentIndex!),
                        onSettingsSaved: _handlePerSiteSettingsSaved,
                      ),
                    ),
                  );
                  await _saveWebViewModels();
                break;
                case 'toggleUrlBar':
                  setState(() {
                    _showUrlBar = !_showUrlBar;
                  });
                  await _saveShowUrlBar();
                break;
                case 'addToHome':
                  if (_currentIndex != null) {
                    await _handleAddToHome(_webViewModels[_currentIndex!]);
                  }
                break;
                case 'devTools':
                  if (_currentIndex != null && _currentIndex! < _webViewModels.length) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => DevToolsScreen(
                          host: WebViewModelDevToolsHost(_webViewModels[_currentIndex!]),
                          cookieManager: _cookieManager,
                          containerCookieManager: _containerCookieManager,
                          onSave: _saveWebViewModels,
                          globalUserScripts: _globalUserScripts,
                        ),
                      ),
                    );
                  }
                break;
              }
            },
          ),
      ],
    );
  }

  /// Build the tab strip shown in bottomNavigationBar.
  /// This stays at the screen bottom and doesn't need to be above the keyboard.
  Widget? _buildTabStrip() {
    if (_isFullscreen && !_tabStripInFullscreen) return null;
    if (_currentIndex == null || _currentIndex! >= _webViewModels.length) {
      return null;
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final filteredIndices = _getFilteredSiteIndices();

    final hasTabStrip = _showTabStrip && filteredIndices.isNotEmpty;
    if (!hasTabStrip) {
      return null;
    }

    // Hide when keyboard is open - it's not needed during text input
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      return null;
    }

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
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: filteredIndices.length,
                padding: EdgeInsets.symmetric(horizontal: 4),
                itemBuilder: (context, listIndex) {
                  final siteIndex = filteredIndices[listIndex];
                  final siteModel = _webViewModels[siteIndex];
                  final isActive = siteIndex == _currentIndex;

                  return GestureDetector(
                    onTap: () async {
                      await _setCurrentIndex(siteIndex);
                      if (!mounted) return;
                      setState(() {});
                      _saveCurrentIndex();
                    },
                    child: Container(
                      constraints: BoxConstraints(maxWidth: 140),
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
                            proxy: siteModel.proxySettings,
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
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            _buildBottomPopupMenu(),
          ],
        ),
      ),
    );
  }

  /// Build the URL bar and find toolbar, placed in the body so that
  /// resizeToAvoidBottomInset keeps them above the keyboard.
  Widget? _buildInputBar() {
    if (_isFullscreen) return null;
    if (_currentIndex == null || _currentIndex! >= _webViewModels.length) {
      return null;
    }

    final model = _webViewModels[_currentIndex!];
    final hasUrlBar = _showUrlBar;
    final hasFindToolbar = _isFindVisible && getController() != null;
    if (!hasUrlBar && !hasFindToolbar) {
      return null;
    }

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
            onUrlSubmitted: (url) async {
              // Cross-domain URL bar submissions route to a nested
              // InAppWebViewScreen rather than navigating in-place — the
              // site card stays bound to its configured identity (cookies,
              // container, per-site privacy posture). Mirrors the
              // shouldOverrideUrlLoading cross-domain → nested decision so
              // typing a URL behaves identically to tapping an outbound
              // link.
              if (getNormalizedDomain(url) != getNormalizedDomain(model.initUrl)) {
                await launchUrl(
                  url,
                  homeTitle: model.name,
                  siteId: model.siteId,
                  incognito: model.incognito,
                  thirdPartyCookiesEnabled: model.thirdPartyCookiesEnabled,
                  clearUrlEnabled: model.clearUrlEnabled,
                  dnsBlockEnabled: model.dnsBlockEnabled,
                  contentBlockEnabled: model.contentBlockEnabled,
                  localCdnEnabled: model.localCdnEnabled,
                  trackingProtectionEnabled: model.trackingProtectionEnabled,
                  language: model.language,
                  zoomPercent: model.zoomPercent,
                  locationMode: model.locationMode,
                  spoofLatitude: model.spoofLatitude,
                  spoofLongitude: model.spoofLongitude,
                  spoofAccuracy: model.spoofAccuracy,
                  spoofTimezone: model.spoofTimezone,
                  spoofTimezoneFromLocation: model.spoofTimezoneFromLocation,
                  liveLocationGranularity: model.liveLocationGranularity,
                  webRtcPolicy: model.webRtcPolicy,
                  userScripts: model.combineUserScripts(_globalUserScripts),
                  proxySettings: model.proxySettings,
                  notificationsEnabled: model.notificationsEnabled,
                );
                return;
              }
              final controller = model.getController(launchUrl, _cookieManager, _containerCookieManager, _saveWebViewModels, globalUserScripts: _globalUserScripts);
              if (controller != null) {
                await controller.loadUrl(url, language: model.language);
                if (!mounted) return;
                setState(() {
                  model.currentUrl = url;
                });
                await _saveWebViewModels();
              }
            },
          ),
      ],
    );
  }

  /// Popup menu button for use in the bottom bar when tab strip is enabled.
  Widget _buildBottomPopupMenu() {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, size: 20),
      padding: EdgeInsets.zero,
      tooltip: 'Menu',
      itemBuilder: (BuildContext context) {
        return [
          PopupMenuItem<String>(
            padding: EdgeInsets.zero,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_back),
                  tooltip: 'Go Back',
                  onPressed: () {
                    Navigator.pop(context);
                    () async {
                      final controller = getController();
                      if (controller != null) {
                        final canGoBack = await controller.canGoBack();
                        if (canGoBack) {
                          await controller.goBack();
                        }
                      }
                    }();
                  },
                ),
                IconButton(
                  icon: Icon(Icons.home),
                  tooltip: 'Go to Home',
                  onPressed: () {
                    Navigator.pop(context);
                    _goHome();
                  },
                ),
                IconButton(
                  icon: Icon(Icons.share),
                  tooltip: 'Share',
                  onPressed: () {
                    Navigator.pop(context);
                    if (_currentIndex != null && _currentIndex! < _webViewModels.length) {
                      final model = _webViewModels[_currentIndex!];
                      final url = model.currentUrl ?? model.initUrl;
                      SharePlus.instance.share(ShareParams(uri: Uri.parse(url)));
                    }
                  },
                ),
                Builder(builder: (context) {
                  final model = _currentIndex != null
                      ? _webViewModels[_currentIndex!]
                      : null;
                  final loading = model?.isLoading ?? false;
                  return IconButton(
                    icon: Icon(loading ? Icons.close : Icons.refresh),
                    tooltip: loading ? 'Stop' : 'Refresh',
                    onPressed: () {
                      Navigator.pop(context);
                      if (loading) {
                        _stopCurrentSiteLoading();
                      } else {
                        _refreshCurrentSite();
                      }
                    },
                  );
                }),
              ],
            ),
          ),
          PopupMenuDivider(),
          PopupMenuItem<String>(
            value: "search",
            child: Row(
              children: [
                Icon(Icons.search),
                SizedBox(width: 8),
                Text("Find"),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: "toggleUrlBar",
            child: Row(
              children: [
                Icon(_showUrlBar ? Icons.visibility_off : Icons.visibility),
                SizedBox(width: 8),
                Text(_showUrlBar ? "Hide URL Bar" : "Show URL Bar"),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: "fullscreen",
            child: Row(
              children: [
                Icon(_isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                SizedBox(width: 8),
                Text(_isFullscreen ? "Exit Full Screen" : "Full Screen"),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: "settings",
            child: Row(
              children: [
                Icon(Icons.settings),
                SizedBox(width: 8),
                Text("Settings"),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: "devTools",
            child: Row(
              children: [
                Icon(Icons.code),
                SizedBox(width: 8),
                Text("Developer Tools"),
              ],
            ),
          ),
          if (_currentIndex != null && _isHomeShortcutMenuVisible(_currentIndex!))
            PopupMenuItem<String>(
              value: "addToHome",
              child: Row(
                children: [
                  Icon(Icons.add_to_home_screen),
                  SizedBox(width: 8),
                  Text("Home Shortcut"),
                ],
              ),
            ),
        ];
      },
      onSelected: (String value) async {
        switch(value) {
          case 'search':
            _toggleFind();
          break;
          case 'fullscreen':
            _toggleFullscreen();
          break;
          case 'settings':
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => SettingsScreen(
                  webViewModel: _webViewModels[_currentIndex!],
                  otherSites: _webViewModels
                      .where((m) => m.siteId != _webViewModels[_currentIndex!].siteId)
                      .toList(growable: false),
                  useContainers: _useContainers,
                  notificationsBlockedBySite: _notificationsBlockedBySite(_webViewModels[_currentIndex!]),
                  globalUserScripts: _globalUserScripts,
                  onGlobalUserScriptsChanged: (scripts) {
                    _globalUserScripts = scripts;
                    _saveGlobalUserScripts();
                    _resetAllWebViews();
                  },
                  onScriptsChanged: _resetCurrentSiteWebView,
                  onClearCookies: () => _clearSiteData(_currentIndex!),
                  onSettingsSaved: _handlePerSiteSettingsSaved,
                ),
              ),
            );
            await _saveWebViewModels();
          break;
          case 'toggleUrlBar':
            setState(() {
              _showUrlBar = !_showUrlBar;
            });
            await _saveShowUrlBar();
          break;
          case 'addToHome':
            if (_currentIndex != null) {
              await _handleAddToHome(_webViewModels[_currentIndex!]);
            }
          break;
          case 'devTools':
            if (_currentIndex != null && _currentIndex! < _webViewModels.length) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => DevToolsScreen(
                    host: WebViewModelDevToolsHost(_webViewModels[_currentIndex!]),
                    cookieManager: _cookieManager,
                    containerCookieManager: _containerCookieManager,
                    onSave: _saveWebViewModels,
                    globalUserScripts: _globalUserScripts,
                  ),
                ),
              );
            }
          break;
        }
      },
    );
  }

  void _addSite({String? initialUrl, Map<String, dynamic>? qrSettings}) async {
    Object? result;
    if (qrSettings != null) {
      result = {'qrSettings': qrSettings};
    } else {
      result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AddSiteScreen(
            themeMode: _themeSettings.themeMode,
            onThemeModeChanged: (ThemeMode mode) async {
              setState(() {
                _themeSettings = _themeSettings.copyWith(themeMode: mode);
              });
              widget.onThemeSettingsChanged(_themeSettings);
              await _saveThemeSettings();

              // Apply theme to all webviews
              final webViewTheme = _themeModeToWebViewTheme(_themeSettings.themeMode);
              for (var webViewModel in _webViewModels) {
                await webViewModel.setTheme(webViewTheme);
              }
            },
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
      model = WebViewModel.fromJson(
        SiteSettingsQrCodec.hydrateForFromJson(resultQrSettings),
        stateSetter,
      );
      if ((model.name ?? '').isEmpty) {
        final pageTitle = await getPageTitle(model.initUrl);
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

    await _registerNewSite(model);
  }

  void _editSite(int index) async {
    final nameController = TextEditingController(text: _webViewModels[index].name);
    final urlController = TextEditingController(text: _webViewModels[index].initUrl);

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit Site'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Site Name',
                hintText: 'Enter a custom name',
              ),
            ),
            SizedBox(height: 16),
            TextField(
              controller: urlController,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'URL',
                hintText: 'http://example.com:8080',
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Tip: Include http:// for HTTP sites, or leave it out for HTTPS',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final name = nameController.text.trim();
              var url = urlController.text.trim();

              // Infer protocol if not specified
              url = ensureUrlScheme(url);

              Navigator.pop(context, {'name': name, 'url': url});
            },
            child: Text('Save'),
          ),
        ],
      ),
    );

    if (result == null || !mounted) return;
    if (index >= _webViewModels.length) return;

    final newName = result['name'];
    final newUrl = result['url'];

    if (newName != null && newName.isNotEmpty) {
      setState(() {
        _webViewModels[index].name = newName;
      });
    }

    if (newUrl != null && newUrl != _webViewModels[index].initUrl) {
      // Snapshot belongs to the old URL; deleteCache must run before the
      // rebuild's getHtmlSync, which is why the sync in-memory eviction
      // (inside deleteCache) is fired before setState rather than awaited.
      final siteId = _webViewModels[index].siteId;
      final deleteCache = HtmlCacheService.instance.deleteCache(siteId);
      setState(() {
        _webViewModels[index].initUrl = newUrl;
        _webViewModels[index].currentUrl = newUrl;
        _webViewModels[index].webview = null; // Force recreation with new URL
        _webViewModels[index].controller = null;
      });
      await deleteCache;
    }

    await _saveWebViewModels();
  }

  void _showSiteContextMenu(BuildContext context, int index, Offset position) {
    final isCustomWebspace = _selectedWebspaceId != null && _selectedWebspaceId != kAllWebspaceId;
    final filteredIndices = _getFilteredSiteIndices();
    final listIndex = filteredIndices.indexOf(index);
    final isArchiveSite =
        index >= 0 && index < _webViewModels.length && _webViewModels[index].isArchiveTier;
    // Show "Move to archive" for every app-tier site, regardless of
    // whether any archive is currently open. The handler always prompts
    // for a passphrase and opens-or-creates the matching archive — its
    // presence in the menu therefore reveals nothing about whether an
    // archive is currently open or whether any exist on disk.
    final canMoveToArchive = !isArchiveSite;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx + 1, position.dy + 1),
      items: [
        PopupMenuItem(value: 'refresh', child: ListTile(leading: Icon(Icons.refresh), title: Text('Refresh Title & Icon'), dense: true, visualDensity: VisualDensity.compact)),
        PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit), title: Text('Edit'), dense: true, visualDensity: VisualDensity.compact)),
        PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete, color: Colors.red), title: Text('Delete', style: TextStyle(color: Colors.red)), dense: true, visualDensity: VisualDensity.compact)),
        if (isCustomWebspace && listIndex > 0)
          PopupMenuItem(value: 'move_up', child: ListTile(leading: Icon(Icons.arrow_upward), title: Text('Move Up'), dense: true, visualDensity: VisualDensity.compact)),
        if (isCustomWebspace && listIndex >= 0 && listIndex < filteredIndices.length - 1)
          PopupMenuItem(value: 'move_down', child: ListTile(leading: Icon(Icons.arrow_downward), title: Text('Move Down'), dense: true, visualDensity: VisualDensity.compact)),
        if (canMoveToArchive)
          PopupMenuItem(value: 'move_to_archive', child: ListTile(leading: Icon(Icons.archive_outlined), title: Text('Move to archive'), dense: true, visualDensity: VisualDensity.compact)),
        if (isArchiveSite)
          PopupMenuItem(value: 'move_out_of_archive', child: ListTile(leading: Icon(Icons.unarchive_outlined), title: Text('Move out of archive'), dense: true, visualDensity: VisualDensity.compact)),
        if (isArchiveSite)
          PopupMenuItem(value: 'close_archive', child: ListTile(leading: Icon(Icons.lock_outline), title: Text('Close archive'), dense: true, visualDensity: VisualDensity.compact)),
      ],
    ).then((value) async {
      if (value == null) return;
      switch (value) {
        case 'move_to_archive':
          await _moveSiteToArchive(index);
          break;
        case 'move_out_of_archive':
          await _moveSiteOutOfArchive(index);
          break;
        case 'close_archive':
          final siteId = index < _webViewModels.length
              ? _webViewModels[index].siteId
              : null;
          if (siteId == null) return;
          final handle = _archiveSlices.entries
              .where((e) => e.value.siteIds.contains(siteId))
              .map((e) => e.key)
              .firstOrNull;
          if (handle == null) return;
          await _closeArchive(handle);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Archive closed')),
          );
          break;
        case 'refresh':
          final url = _webViewModels[index].initUrl;
          await FaviconUrlCache.invalidate(url);
          if (!mounted) return;
          final title = await getPageTitle(url);
          if (!mounted) return;
          if (index >= _webViewModels.length) return;
          if (title != null && title.isNotEmpty) {
            setState(() {
              _webViewModels[index].name = title;
              _webViewModels[index].pageTitle = title;
            });
            await _saveWebViewModels();
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Title updated to: $title')),
            );
          } else {
            setState(() {});
          }
          break;
        case 'edit':
          _editSite(index);
          break;
        case 'delete':
          await _deleteSite(context, index);
          break;
        case 'move_up':
          _reorderSiteInWebspace(listIndex, listIndex - 1);
          break;
        case 'move_down':
          _reorderSiteInWebspace(listIndex, listIndex + 1);
          break;
      }
    });
  }

  void _reorderSiteInWebspace(int oldListIndex, int newListIndex) {
    final webspace = _webspaces.cast<Webspace?>().firstWhere(
      (ws) => ws!.id == _selectedWebspaceId,
      orElse: () => null,
    );
    if (webspace == null) return;
    if (oldListIndex < 0 || oldListIndex >= webspace.siteIds.length) return;
    if (newListIndex < 0 || newListIndex >= webspace.siteIds.length) return;
    setState(() {
      final movedSiteId = webspace.siteIds.removeAt(oldListIndex);
      webspace.siteIds.insert(newListIndex, movedSiteId);
      _resolveWebspaceIndices();
    });
    _saveWebspaces();
  }

  Future<void> _deleteSite(BuildContext context, int index) async {
    final siteName = _webViewModels[index].getDisplayName();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete Site'),
        content: Text('Are you sure you want to delete "$siteName"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    if (index >= _webViewModels.length) return;

    final wasCurrentIndex = _currentIndex == index;
    final deletedModel = _webViewModels[index];
    // Capture before mutation: HS-013 delete-time shortcut prompt (Android).
    // Query the launcher fresh rather than trusting the cached _pinnedSiteIds,
    // which only refreshes on init/resume. Find every pinned tile that REACHES
    // this site — directly (tile id == siteId) or via an HS-011 rebind
    // (remap[tile] == siteId) — so deleting a site an orphaned tile was
    // rebound to still prompts about that tile.
    Set<String> reachingTiles = const {};
    if (Platform.isAndroid) {
      final pinnedNow = await ShortcutService.getPinnedSiteIds();
      if (!mounted) return;
      reachingTiles = ShortcutPinState.tilesReaching(
        siteId: deletedModel.siteId,
        pinnedSiteIds: pinnedNow,
        rememberedRemap: _shortcutSiteRemap,
      );
      LogService.instance.log(
        'Shortcut',
        'delete siteId=${deletedModel.siteId} pinned=$pinnedNow '
            'reachingTiles=$reachingTiles',
        sensitivity: LogSensitivity.sensitive,
      );
    }
    final hadPinnedShortcut = reachingTiles.isNotEmpty;
    deletedModel.disposeWebView();
    _loadedIndices.remove(index);

    await ShortcutService.removeShortcut(deletedModel.siteId);
    if (!mounted) return;

    if (_useContainers) {
      // Container path: each site has its own container, so deleting one
      // site cannot wipe a sibling site's cookies. Just drop the named
      // container and its on-disk data (cookies, localStorage, IDB, SW,
      // cache) in one call.
      await _containerIsolation.onSiteDeleted(deletedModel.siteId);
    } else {
      // Legacy path: snapshot any loaded same-base-domain site's session,
      // clear the deleted site's native cookies, and restore the
      // surviving session so the active webview isn't silently logged out.
      await _cookieIsolation.preDeleteCookieCleanup(
        deletedModel: deletedModel,
        deletedIndex: index,
        models: _webViewModels,
        loadedIndices: _loadedIndices,
      );
    }
    await HtmlCacheService.instance.deleteCache(deletedModel.siteId);
    await HtmlImportStorage.instance.deleteImport(deletedModel.siteId);
    if (!mounted) return;
    final currentModelIndex = _webViewModels.indexOf(deletedModel);
    if (currentModelIndex == -1) return;
    final deletedSiteId = deletedModel.siteId;
    // `_loadedIndices` is still positional, so the engine's index-shift
    // patch is the right tool for it. Webspace membership is keyed by
    // siteId now: we drop the deleted siteId from each webspace and let
    // `_resolveWebspaceIndices` rebuild the positional projection, so
    // the engine's `newSiteIndicesByWebspaceId` output is intentionally
    // ignored here.
    final patch = SiteLifecycleEngine.computeDeletionPatch(
      deletedIndex: currentModelIndex,
      siteCountBeforeRemoval: _webViewModels.length,
      loadedIndices: _loadedIndices,
      webspaces: _webspaces,
      currentIndex: _currentIndex,
    );
    setState(() {
      _webViewModels.removeAt(currentModelIndex);
      _loadedIndices
        ..clear()
        ..addAll(patch.newLoadedIndices);
      // Webspace membership is siteId-keyed: drop the deleted siteId
      // from each webspace and let `_resolveWebspaceIndices` rebuild
      // the positional view. The legacy index-shift patch from
      // SiteLifecycleEngine is now only used for `_loadedIndices`.
      for (final webspace in _webspaces) {
        webspace.siteIds.remove(deletedSiteId);
      }
      _resolveWebspaceIndices();
    });
    if (wasCurrentIndex) {
      await _setCurrentIndex(null);
      if (!mounted) return;
    }
    await _saveWebViewModels();
    await _saveWebspaces();

    // Defense in depth: sweep orphaned per-siteId storage entries.
    final activeSiteIds = _webViewModels.map((m) => m.siteId).toSet();
    await _cookieSecureStorage.removeOrphanedCookies(activeSiteIds);
    await _proxyPasswordStorage.removeOrphaned(activeSiteIds);
    await HtmlCacheService.instance.removeOrphanedCaches(activeSiteIds);
    await HtmlImportStorage.instance.removeOrphanedImports(activeSiteIds);
    await _stateStorage.removeOrphans(activeSiteIds);

    // Deletion may have just removed the last notification site; tear
    // down the background refresh schedule if so. No-op on other
    // platforms.
    unawaited(_updateBackgroundRefreshSchedule());

    if (hadPinnedShortcut) {
      await _handleDeletedSiteShortcut(reachingTiles);
    }
    // iOS/macOS can't detect whether a Shortcut tile exists, so prompting on
    // delete would fire blindly on every deletion. Instead, tombstone silently:
    // if a tile was bound here it stays resolvable and routes (or offers to
    // reroute) when actually tapped (HS-011/HS-014). The list is capped.
    if ((Platform.isIOS || Platform.isMacOS) && !deletedModel.isArchiveTier) {
      await _recordShortcutTombstone(
          deletedSiteId, deletedModel.name, deletedModel.initUrl);
    }

    if (!mounted) return;
    Navigator.pop(context);
  }

  /// Shared Keep/Reassign/Disable chooser for the delete-time shortcut prompt
  /// (HS-013). Returns 'keep' | 'reassign' | 'disable' | null (dismissed).
  Future<String?> _showShortcutFateChoice(String message) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Home screen shortcut'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'keep'),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'reassign'),
            child: const Text('Reassign'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'disable'),
            child: const Text('Disable'),
          ),
        ],
      ),
    );
  }

  /// HS-013: the deleted site was reachable by one or more pinned tiles
  /// ([tileIds] — directly or via an HS-011 rebind). Ask what to do with those
  /// now-orphaned launcher tiles (Android can't remove them for the user):
  /// keep them (a tap re-routes — open a domain match or offer to create),
  /// point them at another site, or disable them.
  Future<void> _handleDeletedSiteShortcut(Set<String> tileIds) async {
    if (!mounted || tileIds.isEmpty) return;
    final choice = await _showShortcutFateChoice(
      'This site had a home screen shortcut. By default, tapping it lets '
      'you reopen a matching site or create a new one.\n\n'
      'You can instead point it at another site, or disable it. (Android '
      "can't delete a pinned shortcut for you — disabling greys it out "
      'until you remove it from the home screen.)',
    );
    if (!mounted || choice == null || choice == 'keep') return;

    if (choice == 'disable') {
      for (final tile in tileIds) {
        await ShortcutService.disableShortcut(tile);
        _shortcutSiteRemap.remove(tile);
        _shortcutUrlLedger.remove(tile);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kShortcutRemapKey, jsonEncode(_shortcutSiteRemap));
      await prefs.setString(
          _kShortcutUrlLedgerKey, jsonEncode(_shortcutUrlLedger));
      if (!mounted) return;
      setState(() {
        _pinnedSiteIds = {..._pinnedSiteIds}..removeAll(tileIds);
      });
      return;
    }

    // 'reassign': point every reaching tile at an existing site via the remap.
    final targetSiteId = await _pickSiteForShortcut();
    if (targetSiteId == null || !mounted) return;
    for (final tile in tileIds) {
      await _rememberShortcutRemap(tile, targetSiteId);
    }
  }

  /// Pick an existing (non-archive) site to reassign an orphaned shortcut to.
  /// Returns the chosen siteId, or null if dismissed / nothing to pick.
  Future<String?> _pickSiteForShortcut() async {
    final candidates = [
      for (final m in _webViewModels)
        if (!m.isArchiveTier) m,
    ];
    if (candidates.isEmpty || !mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Point shortcut at'),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: candidates.length,
            itemBuilder: (context, i) {
              final m = candidates[i];
              return ListTile(
                leading: SizedBox(
                  width: 32,
                  height: 32,
                  child: UnifiedFaviconImage(
                    url: m.initUrl,
                    size: 32,
                    proxy: m.proxySettings,
                  ),
                ),
                title: Text(
                  m.getDisplayName(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  m.initUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(ctx).pop(m.siteId),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildSiteGridTile(BuildContext context, int index, int listIndex) {
    final isSelected = _currentIndex == index;
    final theme = Theme.of(context);
    final isCustomWebspace = _selectedWebspaceId != null && _selectedWebspaceId != kAllWebspaceId;
    return Semantics(
      key: Key('site_$index'),
      label: _webViewModels[index].getDisplayName(),
      button: true,
      enabled: true,
      child: isCustomWebspace
        ? _buildDraggableSiteGridTile(context, index, listIndex, isSelected, theme)
        : _buildStaticSiteGridTile(context, index, isSelected, theme),
    );
  }

  Widget _buildDraggableSiteGridTile(BuildContext context, int index, int listIndex, bool isSelected, ThemeData theme) {
    // Track pointer state for tap detection via raw Listener.
    // Using Listener instead of GestureDetector avoids the gesture arena
    // conflict with LongPressDraggable that causes delayed/missed taps.
    Offset? pointerDownPos;
    Duration? pointerDownTime;
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != listIndex,
      onAcceptWithDetails: (details) {
        _reorderSiteInWebspace(details.data, listIndex);
      },
      builder: (context, candidateData, rejectedData) {
        final isHovered = candidateData.isNotEmpty;
        return LongPressDraggable<int>(
          data: listIndex,
          feedback: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 80,
              height: 88,
              child: Opacity(
                opacity: 0.85,
                child: _buildSiteGridTileContent(context, index, isSelected, theme),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.3,
            child: _buildSiteGridTileContent(context, index, isSelected, theme),
          ),
          child: Container(
            decoration: isHovered
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.colorScheme.primary, width: 2),
                  )
                : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) {
                    pointerDownPos = event.position;
                    pointerDownTime = event.timeStamp;
                  },
                  onPointerUp: (event) {
                    if (pointerDownPos != null) {
                      final distance = (event.position - pointerDownPos!).distance;
                      final duration = event.timeStamp - pointerDownTime!;
                      if (distance < 20 && duration < const Duration(milliseconds: 300)) {
                        Navigator.pop(context);
                        () async {
                          await _webspaceSwitchCompleter?.future;
                          await _setCurrentIndex(index);
                          if (!mounted) return;
                          setState(() {});
                          await _saveCurrentIndex();
                        }();
                      }
                    }
                    pointerDownPos = null;
                    pointerDownTime = null;
                  },
                  onPointerCancel: (_) {
                    pointerDownPos = null;
                    pointerDownTime = null;
                  },
                  child: GestureDetector(
                    onSecondaryTapDown: (details) {
                      _showSiteContextMenu(context, index, details.globalPosition);
                    },
                    child: _buildSiteGridTileContent(context, index, isSelected, theme),
                  ),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      final renderBox = context.findRenderObject() as RenderBox;
                      final center = renderBox.localToGlobal(
                        Offset(renderBox.size.width - 8, 8),
                      );
                      _showSiteContextMenu(context, index, center);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Icon(Icons.more_vert, size: 16, color: theme.colorScheme.onSurfaceVariant.withAlpha(150)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStaticSiteGridTile(BuildContext context, int index, bool isSelected, ThemeData theme) {
    return GestureDetector(
      onLongPressStart: (details) {
        _showSiteContextMenu(context, index, details.globalPosition);
      },
      child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            Navigator.pop(context);
            await _webspaceSwitchCompleter?.future;
            await _setCurrentIndex(index);
            if (!mounted) return;
            setState(() {});
            await _saveCurrentIndex();
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > constraints.maxHeight * 1.5;
              return Container(
                decoration: isSelected
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: theme.colorScheme.primaryContainer.withAlpha(80),
                      )
                    : null,
                padding: isWide
                    ? const EdgeInsets.symmetric(vertical: 4, horizontal: 12)
                    : const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                child: isWide
                    ? Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: theme.colorScheme.surfaceContainerHighest,
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Center(
                              child: UnifiedFaviconImage(
                                url: _webViewModels[index].initUrl,
                                size: 28,
                                proxy: _webViewModels[index].proxySettings,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _webViewModels[index].getDisplayName(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13),
                                ),
                                Text(
                                  extractDomain(_webViewModels[index].initUrl),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: theme.colorScheme.surfaceContainerHighest,
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Center(
                              child: UnifiedFaviconImage(
                                url: _webViewModels[index].initUrl,
                                size: 36,
                                proxy: _webViewModels[index].proxySettings,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Flexible(
                            child: Text(
                              _webViewModels[index].getDisplayName(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                        ],
                      ),
              );
            },
          ),
        ),
    );
  }

  Widget _buildSiteGridTileContent(BuildContext context, int index, bool isSelected, ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > constraints.maxHeight * 1.5;
        return Container(
          decoration: isSelected
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: theme.colorScheme.primaryContainer.withAlpha(80),
                )
              : null,
          padding: isWide
              ? const EdgeInsets.symmetric(vertical: 4, horizontal: 12)
              : const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: isWide
              ? Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Center(
                        child: UnifiedFaviconImage(
                          url: _webViewModels[index].initUrl,
                          size: 28,
                          proxy: _webViewModels[index].proxySettings,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _webViewModels[index].getDisplayName(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13),
                          ),
                          Text(
                            extractDomain(_webViewModels[index].initUrl),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Center(
                        child: UnifiedFaviconImage(
                          url: _webViewModels[index].initUrl,
                          size: 36,
                          proxy: _webViewModels[index].proxySettings,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Flexible(
                      child: Text(
                        _webViewModels[index].getDisplayName(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  /// Build the body with the input bar (URL bar / find toolbar) integrated,
  /// so resizeToAvoidBottomInset naturally keeps them above the keyboard.
  /// The tab strip stays in bottomNavigationBar separately.
  Widget _buildBodyWithBottomBar() {
    final inputBar = _buildInputBar();
    // Tab strip in bottomNavigationBar handles bottom safe area when visible.
    // Input bar has its own SafeArea. Only apply body safe area when neither
    // is present (e.g. webspace list screen).
    final filteredIndices = _getFilteredSiteIndices();
    // The tab strip is also rendered (in bottomNavigationBar) when kept in
    // fullscreen, in which case it owns the bottom safe-area inset.
    final hasTabStrip = (!_isFullscreen || _tabStripInFullscreen)
        && _currentIndex != null
        && _currentIndex! < _webViewModels.length
        && _showTabStrip
        && filteredIndices.isNotEmpty;
    return SafeArea(
      // Out of fullscreen the AppBar absorbs the top inset, so top stays false.
      // In fullscreen there is no AppBar, and immersiveSticky does not reliably
      // hide the status/navigation bars on Android 15 (edge-to-edge enforced) —
      // when they remain, edge-to-edge content lands behind them and the site's
      // top/bottom controls become untappable. Inset the body on both edges so
      // it stays clear of any bars that persist; when they are truly hidden the
      // padding is ~0 and the webview still fills the screen. github #385
      top: _isFullscreen,
      bottom: !hasTabStrip && inputBar == null,
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
                  offstage: _currentIndex != null && _currentIndex! < _webViewModels.length,
                  child: WebspacesListScreen(
                    webspaces: _webspaces,
                    selectedWebspaceId: _selectedWebspaceId,
                    totalSitesCount: _webViewModels.length,
                    accentColor: _themeSettings.accentColor,
                    onSelectWebspace: _selectWebspace,
                    onAddWebspace: _addWebspace,
                    onEditWebspace: _editWebspace,
                    onDeleteWebspace: _deleteWebspace,
                    onReorder: _reorderWebspaces,
                  ),
                ),
                if (_loadedIndices.isNotEmpty)
                  Offstage(
                    offstage: _currentIndex == null || _currentIndex! >= _webViewModels.length,
                    // The 1px inset is toggled by _nudgeSurfaceRepaint after
                    // the activity is recreated (shortcut/resume) to force the
                    // hybrid-composition webview SurfaceView to recomposite —
                    // otherwise it can come back black on Android. No-op
                    // (zero inset) in steady state.
                    child: Padding(
                      padding: EdgeInsets.only(bottom: _repaintNudge ? 1.0 : 0.0),
                      child: IndexedStack(
                      index: _currentIndex ?? 0,
                      children: _webViewModels.asMap().entries.map<Widget>((entry) {
                        final index = entry.key;
                        final webViewModel = entry.value;

                        if (!_loadedIndices.contains(index)) {
                          return const SizedBox.shrink();
                        }

                        return SizedBox.expand(
                          key: ValueKey(webViewModel.siteId),
                          child: Column(
                            children: [
                              if (_showStatsBanner)
                                StatsBanner(
                                  siteId: webViewModel.siteId,
                                  dnsBlockEnabled: webViewModel.dnsBlockEnabled,
                                ),
                              Expanded(
                                child: webViewModel.getWebView(
                                  launchUrl,
                                  _cookieManager,
                                  _containerCookieManager,
                                  _saveWebViewModels,
                                  onWindowRequested: _showPopupWindow,
                                  language: webViewModel.language,
                                  globalUserScripts: _globalUserScripts,
                                  // file:// imports are user data (only copy on device), not
                                  // a re-fetchable snapshot — the canonical bytes live in
                                  // HtmlImportStorage and never change after import, so
                                  // skip the live-snapshot save path entirely.
                                  onHtmlLoaded: (webViewModel.incognito || webViewModel.isArchiveTier || webViewModel.initUrl.startsWith('file://'))
                                      ? null
                                      : (url, html) {
                                          HtmlCacheService.instance.saveHtml(webViewModel.siteId, html, url);
                                        },
                                  // Skip the per-onLoadStop getHtml() IPC into chromium when
                                  // a save would be debounced anyway. Drops the storm of
                                  // renderer-DOM-serializations that fired on every SPA pseudo-
                                  // navigation (8+ Saved events per page on LinkedIn) — each one
                                  // a candidate for racing chromium's frame-lifecycle teardown.
                                  // Archive-tier sites skip the cache write entirely (ARCH-006).
                                  shouldFetchHtml: (webViewModel.incognito || webViewModel.isArchiveTier || webViewModel.initUrl.startsWith('file://'))
                                      ? null
                                      : () => HtmlCacheService.instance.shouldSave(webViewModel.siteId),
                                  initialHtml: (webViewModel.incognito || webViewModel.isArchiveTier)
                                      ? null
                                      : () {
                                          // file:// imports come from HtmlImportStorage (the only
                                          // copy of user-supplied content); URL sites come from
                                          // HtmlCacheService (re-fetchable snapshot). The webview
                                          // factory uses initialHtml for instant first paint via
                                          // `InAppWebViewInitialData` and then — for URL sites —
                                          // swaps to a fresh live load via `controller.reload()`
                                          // once the cached parse settles. file:// imports skip
                                          // the swap (no live to fetch); offline cold starts skip
                                          // the swap inside the factory's `pendingLiveReload`
                                          // gate.
                                          //
                                          // Per-site `htmlCachingEnabled` gates the cached-read
                                          // for URL sites: off (default) means the cache is only
                                          // consulted when the device is offline at construction
                                          // time, so online cold starts go straight to live and
                                          // never show stale content. On = cache-then-live for
                                          // instant first paint. file:// imports ignore the
                                          // toggle — they have no live to fetch, so the cached
                                          // bytes are the only thing to render.
                                          final isFileImport =
                                              webViewModel.initUrl.startsWith('file://');
                                          if (!isFileImport &&
                                              !webViewModel.htmlCachingEnabled &&
                                              (ConnectivityService.instance.lastKnownOnline ?? true)) {
                                            return null;
                                          }
                                          final cached = isFileImport
                                              ? HtmlImportStorage.instance.getHtmlSync(webViewModel.siteId)
                                              : HtmlCacheService.instance.getHtmlSync(webViewModel.siteId);
                                          if (cached == null) return null;
                                          final isDark = webViewModel.currentTheme == WebViewTheme.dark ||
                                              (webViewModel.currentTheme == WebViewTheme.system &&
                                                  MediaQuery.platformBrightnessOf(context) == Brightness.dark);
                                          return HtmlCacheService.applyThemePrelude(cached, dark: isDark);
                                        }(),
                                  isActive: () => _currentIndex == index,
                                  onConfirmScriptFetch: _confirmScriptFetch,
                                  onProtectedMediaRequest: _promptProtectedMedia,
                                  onUntrustedCertificate: _promptUntrustedCertificate,
                                  onExternalSchemeUrl: (url, info) async {
                                    if (!mounted) return;
                                    await confirmAndLaunchExternalUrl(
                                      context,
                                      info,
                                      loadInWebView: webViewModel.controller,
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                      ),
                    ),
                  ),
                // Fullscreen exit zone: touch target at the top edge with a
                // visible handle just below the status bar / notch area.
                // The back button/gesture keeps its normal behavior (web
                // history back, open drawer, etc.) even while in fullscreen.
                if (_isFullscreen)
                  Builder(builder: (context) {
                    final topPadding = MediaQuery.of(context).padding.top;
                    return Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: topPadding + 20,
                      // Only the centered handle catches the exit tap. The rest
                      // of the strip stays transparent to pointers so web-app
                      // controls in the top corners (e.g. a sidebar toggle) get
                      // the tap instead of exiting fullscreen. github #401
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _exitFullscreen,
                          child: Container(
                            width: 96,
                            height: topPadding + 20,
                            alignment: Alignment.bottomCenter,
                            color: Colors.transparent,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 5),
                              width: 36,
                              height: 5,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.5),
                                borderRadius: BorderRadius.circular(2.5),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
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
    final bool webviewIsVisible = _currentIndex != null && _currentIndex! < _webViewModels.length;
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
    return PopScope(
      // On Android, always intercept back so the gesture only ever navigates
      // webview history (never exits the app). On other platforms, allow pop
      // only when no webview is visible.
      canPop: Platform.isAndroid ? false : !webviewIsVisible,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _isBackHandling) return;
        _isBackHandling = true;
        try {
          final scaffoldState = _scaffoldKey.currentState;
          // If the drawer is open, just close it.
          if (scaffoldState != null && scaffoldState.isDrawerOpen) {
            LogService.instance.log('Navigation', 'Back gesture: closing open drawer');
            Navigator.pop(context);
            return;
          }
          // The back gesture only navigates webview history. It never opens
          // the drawer and never exits the app; if there is nothing to go
          // back to, it is a no-op.
          final controller = getController();
          if (controller == null) {
            LogService.instance.log('Navigation', 'Back gesture: no controller, ignoring');
            return;
          }
          // Android's canGoBack() is reliable (including for pushState/SPA
          // entries on Chromium). Trust it directly: URL-comparison can
          // false-positive when goBack() succeeds but the navigation
          // hasn't propagated within the timeout.
          if (Platform.isAndroid) {
            if (await controller.canGoBack()) {
              await controller.goBack();
              LogService.instance.log('Navigation', 'Back gesture: navigated back (canGoBack)');
            } else {
              LogService.instance.log('Navigation', 'Back gesture: no history, ignoring');
            }
            return;
          }
          // iOS/macOS: canGoBack() can return false for pushState entries,
          // so attempt goBack() unconditionally and use URL comparison as
          // the authoritative check.
          final urlBefore = (await controller.getUrl())?.toString();
          await controller.goBack();
          // Give the native webview time to process the navigation
          await Future.delayed(const Duration(milliseconds: 150));
          if (!mounted) return;
          final urlAfter = (await controller.getUrl())?.toString();
          if (urlBefore == urlAfter) {
            LogService.instance.log(
              'Navigation',
              'Back gesture: URL unchanged ($urlAfter), ignoring',
              sensitivity: LogSensitivity.sensitive,
            );
          } else {
            LogService.instance.log(
              'Navigation',
              'Back gesture: navigated back from $urlBefore to $urlAfter',
              sensitivity: LogSensitivity.sensitive,
            );
          }
        } finally {
          _isBackHandling = false;
        }
      },
      child: Scaffold(
      key: _scaffoldKey,
      // Disable the drawer edge-swipe whenever a webview is active so the back
      // gesture never opens the drawer. The drawer is reached via the AppBar
      // menu button instead.
      drawerEdgeDragWidth: webviewIsVisible ? 0 : null,
      appBar: _isFullscreen ? null : _buildAppBar(),
      drawer: Drawer(
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
                        Navigator.pop(context);
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
                              _selectedWebspaceId != null
                                  ? _webspaces.firstWhere((ws) => ws.id == _selectedWebspaceId, orElse: () => Webspace(name: 'Unknown')).name
                                  : 'No webspace',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Semantics(
                      label: 'Back to Webspaces',
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
                          Navigator.pop(context);
                        },
                        icon: Icon(Icons.arrow_back, size: 16),
                        label: Text('Back to Webspaces', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _selectedWebspaceId == null
                  ? Center(
                      child: Text('Select a webspace to view sites'),
                    )
                  : () {
                      final filteredIndices = _getFilteredSiteIndices();
                      if (filteredIndices.isEmpty) {
                        return Center(
                          child: Text('No sites in this webspace'),
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
                              return _buildSiteGridTile(context, index, listIndex);
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
                  label: Text('Add Site'),
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
          !(_currentIndex == null || _currentIndex! >= _webViewModels.length) ? null
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

class _SiteRouteAdapter implements DispatchableSite {
  final WebViewModel model;
  const _SiteRouteAdapter(this.model);

  @override
  String get siteId => model.siteId;

  @override
  String get initUrl => model.initUrl;

  @override
  List<DomainClaim> get domainClaims => model.effectiveDomainClaims;

  @override
  bool get incognito => model.incognito;

  @override
  bool get alwaysOpenHome => model.alwaysOpenHome;

  @override
  String get navigationDomain => getNormalizedDomain(model.initUrl);
}

sealed class _DispatchChoice {
  const _DispatchChoice();
}

class _DispatchChoiceOpen extends _DispatchChoice {
  final WebViewModel site;
  const _DispatchChoiceOpen(this.site);
}

class _DispatchChoiceBind extends _DispatchChoice {
  final WebViewModel site;
  const _DispatchChoiceBind(this.site);
}

class _DispatchChoiceCreate extends _DispatchChoice {
  const _DispatchChoiceCreate();
}

/// LIR-010 dispatch picker: shown when the resolver does not deliver a
/// unique winner. Lists each resolver winner ("router default" rows), an
/// option to bind the URL's host to an existing site (mutates that site's
/// `domainClaims` via `claimsToAdoptHost`), and an option to create a new
/// site with the path stripped to `<scheme>://<host>[:port]/`.
class _DispatchPickerSheet extends StatefulWidget {
  final Uri url;
  final List<WebViewModel> winners;
  final List<WebViewModel> otherSites;
  final bool canCreate;

  const _DispatchPickerSheet({
    required this.url,
    required this.winners,
    required this.otherSites,
    required this.canCreate,
  });

  @override
  State<_DispatchPickerSheet> createState() => _DispatchPickerSheetState();
}

class _DispatchPickerSheetState extends State<_DispatchPickerSheet> {
  bool _bindMode = false;

  @override
  Widget build(BuildContext context) {
    final host = widget.url.host;
    final allSites = [...widget.winners, ...widget.otherSites];
    final rows = _bindMode ? _buildBindRows(allSites) : _buildPrimaryRows();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _bindMode ? 'Send $host to which site?' : 'Open $host',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                widget.url.toString(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: rows,
                ),
              ),
              const SizedBox(height: 8),
              if (_bindMode)
                TextButton(
                  onPressed: () => setState(() => _bindMode = false),
                  child: const Text('Back'),
                )
              else
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _siteFavicon(WebViewModel site) => SizedBox(
        width: 32,
        height: 32,
        child: UnifiedFaviconImage(
          url: site.initUrl,
          size: 32,
          proxy: site.proxySettings,
        ),
      );

  List<Widget> _buildPrimaryRows() {
    final rows = <Widget>[];
    for (final site in widget.winners) {
      rows.add(ListTile(
        leading: _siteFavicon(site),
        title: Text('Open in ${site.getDisplayName()}'),
        subtitle: Text(site.initUrl,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () =>
            Navigator.of(context).pop(_DispatchChoiceOpen(site)),
      ));
    }
    if (widget.winners.isNotEmpty || widget.otherSites.isNotEmpty) {
      rows.add(ListTile(
        leading: const SizedBox(
            width: 32, height: 32, child: Icon(Icons.link)),
        title: Text(
            'Send ${widget.url.host} (and subdomains) to a site'),
        subtitle: const Text('Pick an existing site to handle this domain'),
        onTap: () => setState(() => _bindMode = true),
      ));
    }
    if (widget.canCreate) {
      rows.add(ListTile(
        leading: SizedBox(
          width: 32,
          height: 32,
          child: UnifiedFaviconImage(
            url: LinkRoutingService.strippedHomeUrl(widget.url) ??
                widget.url.toString(),
            size: 32,
          ),
        ),
        title: Text('Create new site for ${widget.url.host}'),
        subtitle: Text(
          LinkRoutingService.strippedHomeUrl(widget.url) ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () =>
            Navigator.of(context).pop(const _DispatchChoiceCreate()),
      ));
    }
    return rows;
  }

  List<Widget> _buildBindRows(List<WebViewModel> sites) {
    if (sites.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Text('No existing sites.'),
        ),
      ];
    }
    return sites
        .map((s) => ListTile(
              leading: _siteFavicon(s),
              title: Text(s.getDisplayName()),
              subtitle: Text(s.initUrl,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () =>
                  Navigator.of(context).pop(_DispatchChoiceBind(s)),
            ))
        .toList(growable: false);
  }
}
