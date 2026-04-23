import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' show min, max;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:webspace/screens/inappbrowser.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/screens/webspace_detail.dart';
import 'package:webspace/widgets/stats_banner.dart';
import 'package:webspace/widgets/find_toolbar.dart';
import 'package:webspace/widgets/url_bar.dart';
import 'package:webspace/demo_data.dart' show seedDemoData, isDemoMode;
import 'package:webspace/services/image_cache_service.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/navigation_engine.dart';
import 'package:webspace/services/site_activation_engine.dart';
import 'package:webspace/services/site_lifecycle_engine.dart';
import 'package:webspace/services/startup_restore_engine.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/shortcut_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/suggested_sites_service.dart' as suggested_sites;
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/utils/url_utils.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webspace/widgets/download_button.dart';
import 'package:webspace/widgets/external_url_prompt.dart';
import 'package:webspace/widgets/root_messenger.dart';

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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Clear image cache on app upgrade
  await ImageCacheService.clearCacheOnUpgrade();

  // Initialize HTML cache (clears on app upgrade)
  await HtmlCacheService.instance.initialize();

  // Initialize favicon URL cache
  await FaviconUrlCache.initialize();

  // Initialize ClearURLs service (loads cached rules from disk)
  await ClearUrlService.instance.initialize();

  // Initialize DNS block service (loads cached blocklist from disk)
  await DnsBlockService.instance.initialize();

  // Initialize native interceptor bridge for sub-resource DNS + ABP
  // blocking and LocalCDN serving (Android). The Dart shouldInterceptRequest
  // callback only fires for main-document navigations on modern Chromium
  // WebView, so everything per-subresource has to go through the native
  // path.
  WebInterceptNative.initialize();
  if (DnsBlockService.instance.hasBlocklist) {
    await WebInterceptNative.sendDnsDomains(
        DnsBlockService.instance.blockedDomains);
  }

  // Initialize content blocker service (loads cached filter lists from disk)
  await ContentBlockerService.instance.initialize();

  // Seed the native interceptor with ABP domains once ContentBlocker has
  // parsed its cached lists.
  if (ContentBlockerService.instance.blockedDomains.isNotEmpty) {
    await WebInterceptNative.sendAbpDomains(
        ContentBlockerService.instance.blockedDomains);
  }

  // Keep native + JS Bloom in sync whenever either blocklist changes.
  // Individual download / toggle call sites don't need to know about the
  // interceptor — they just mutate the service, the listener re-pushes.
  DnsBlockService.instance.addBlocklistChangedListener(() {
    WebInterceptNative.sendDnsDomains(DnsBlockService.instance.blockedDomains);
  });
  ContentBlockerService.instance.addRulesChangedListener(() {
    DnsBlockService.instance.invalidateMergedBloom();
    WebInterceptNative.sendAbpDomains(
        ContentBlockerService.instance.blockedDomains);
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
    (['cdnjs (LocalCDN resource data)'], 'assets/licenses/cdnjs.txt'),
  ];
  for (final (packages, assetPath) in customLicenses) {
    LicenseRegistry.addLicense(() async* {
      final text = await rootBundle.loadString(assetPath);
      yield LicenseEntryWithLineBreaks(packages, text);
    });
  }

  // Initialize platform info to detect proxy support before UI loads
  await PlatformInfo.initialize();
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
      title: 'WebSpace',
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

class _WebSpacePageState extends State<WebSpacePage> with WidgetsBindingObserver {
  int? _currentIndex;
  final List<WebViewModel> _webViewModels = [];
  AppThemeSettings _themeSettings = const AppThemeSettings();
  final CookieManager _cookieManager = CookieManager();
  final CookieSecureStorage _cookieSecureStorage = CookieSecureStorage();
  late final CookieIsolationEngine _cookieIsolation = CookieIsolationEngine(
    cookieManager: _cookieManager,
    storage: _cookieSecureStorage,
  );
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _isBackHandling = false;
  bool _isFindVisible = false;
  bool _isFullscreen = false; // Runtime fullscreen state (hides appBar, tabStrip, system UI)
  bool _showUrlBar = false;
  bool _showTabStrip = false;
  bool _showStatsBanner = true;
  bool _canGoBack = false; // Tracks webview back history for iOS drawer gesture
  int _canGoBackVersion = 0; // Guards _updateCanGoBack against stale async results

  // Webspace-related state
  final List<Webspace> _webspaces = [];
  String? _selectedWebspaceId;
  int _selectWebspaceVersion = 0;
  int _setCurrentIndexVersion = 0;
  Completer<void>? _webspaceSwitchCompleter;

  // Track which webview indices have been loaded (for lazy loading)
  // Only webviews in this set will be created - others remain as placeholders
  final Set<int> _loadedIndices = {};

  // Configurable suggested sites
  List<SiteSuggestion> _suggestedSites = [];

  // Global user scripts (shared across all sites)
  List<UserScriptConfig> _globalUserScripts = [];

  // Guards lifecycle pause/resume against rapid state transitions.
  // Without this, a quick inactive→resumed sequence could let the resume
  // platform call complete before the pause call, leaving the webview stuck.
  Future<void>? _lifecyclePauseFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreAppState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // Pause the active webview when the app goes to background
      if (_currentIndex != null && _currentIndex! < _webViewModels.length && _loadedIndices.contains(_currentIndex)) {
        _lifecyclePauseFuture = _webViewModels[_currentIndex!].pauseWebView();
      }
    } else if (state == AppLifecycleState.resumed) {
      // Await any in-flight pause before resuming to prevent ordering inversion
      _resumeAfterLifecyclePause();
      _handleShortcutIntent();
    }
  }

  Future<void> _resumeAfterLifecyclePause() async {
    if (_lifecyclePauseFuture != null) {
      await _lifecyclePauseFuture;
      _lifecyclePauseFuture = null;
    }
    if (_currentIndex != null && _currentIndex! < _webViewModels.length && _loadedIndices.contains(_currentIndex)) {
      await _webViewModels[_currentIndex!].resumeWebView();
    }
    // Re-apply fullscreen system UI mode after resume
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  Future<void> _handleShortcutIntent() async {
    final siteId = await ShortcutService.getLaunchSiteId();
    if (!mounted) return;
    if (siteId != null) {
      final index = _webViewModels.indexWhere((m) => m.siteId == siteId);
      if (index >= 0 && index != _currentIndex) {
        await _setCurrentIndex(index);
        if (!mounted) return;
        setState(() {});
      }
    }
  }

  Future<void> _saveWebViewModels() async {
    if (isDemoMode) return; // Don't persist in demo mode
    SharedPreferences prefs = await SharedPreferences.getInstance();

    // Save cookies to secure storage, keyed by siteId for per-site isolation
    final Map<String, List<Cookie>> cookiesBySiteId = {};
    for (final webViewModel in _webViewModels) {
      if (webViewModel.cookies.isNotEmpty && !webViewModel.incognito) {
        cookiesBySiteId[webViewModel.siteId] = List.from(webViewModel.cookies);
      }
    }
    await _cookieSecureStorage.saveCookies(cookiesBySiteId);

    // Save models to SharedPreferences (cookies will be empty in SharedPreferences)
    List<String> webViewModelsJson = _webViewModels.map((webViewModel) {
      final json = webViewModel.toJson();
      json['cookies'] = []; // Don't store cookies in SharedPreferences
      return jsonEncode(json);
    }).toList();
    await prefs.setStringList('webViewModels', webViewModelsJson);
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

  Future<void> _saveShowStatsBanner() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showStatsBanner', _showStatsBanner);
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
    if (json != null) {
      _globalUserScripts = json
          .map((s) => UserScriptConfig.fromJson(jsonDecode(s) as Map<String, dynamic>))
          .toList();
    }
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

  /// Drop the cached HTML for a site — but only when we're online. When
  /// offline the cached snapshot is the only content we can render, so
  /// preserve it until a live reload can overwrite it (via the
  /// `onHtmlLoaded` callback on the next successful `onLoadStop`).
  ///
  /// Fire-and-forget so synchronous call sites (notably `_goHome`, which is
  /// synchronous by design per navigation spec RACE-004) stay synchronous.
  /// The connectivity probe resolves in a few ms; the worst case is a brief
  /// window where a freshly-rebuilt webview renders the stale snapshot, and
  /// then the next live navigation replaces it.
  void _deleteCacheIfOnline(String siteId) {
    ConnectivityService.instance.isOnline().then((online) {
      if (online) HtmlCacheService.instance.deleteCache(siteId);
    });
  }

  /// Dispose the current site's webview so the next render recreates it
  /// with fresh [initialUserScripts]. Used after the user edits the
  /// script list — toggling `enabled` on a script does nothing at runtime
  /// because the native WKUserScript / Android UserScript objects are
  /// baked at webview creation time.
  ///
  /// Also drops the cached HTML (online only): the snapshot was captured
  /// with the previous script set applied, so showing it on next load
  /// would render the pre-edit DOM before the new scripts re-run.
  void _resetCurrentSiteWebView() {
    if (_currentIndex == null || _currentIndex! >= _webViewModels.length) return;
    _deleteCacheIfOnline(_webViewModels[_currentIndex!].siteId);
    setState(() {
      _webViewModels[_currentIndex!].disposeWebView();
    });
  }

  /// Dispose every loaded webview. Used after global user script edits,
  /// which can affect any site that has opted in. Caches for sites that
  /// have any global opt-in are dropped (online only) for the same reason
  /// as [_resetCurrentSiteWebView].
  void _resetAllWebViews() {
    for (final model in _webViewModels) {
      if (model.enabledGlobalScriptIds.isNotEmpty) {
        _deleteCacheIfOnline(model.siteId);
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
    List<String> webspacesJson = _webspaces.map((webspace) => jsonEncode(webspace.toJson())).toList();
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
      // Pause the previously active webview when navigating away
      if (_currentIndex != null && _currentIndex! < _webViewModels.length && _loadedIndices.contains(_currentIndex)) {
        await _webViewModels[_currentIndex!].pauseWebView();
        if (version != _setCurrentIndexVersion) return;
      }
      _currentIndex = index;
      _canGoBack = false;
      _exitFullscreen();
      return;
    }

    final target = _webViewModels[index];

    LogService.instance.log('CookieIsolation', 'Switching to site $index: "${target.name}" (siteId: ${target.siteId})');
    LogService.instance.log('CookieIsolation', 'Target domain: ${getBaseDomain(target.initUrl)}');
    LogService.instance.log('CookieIsolation', 'Currently loaded indices: $_loadedIndices');

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
      );
      await _unloadSiteForDomainSwitch(conflictIndex);
      if (version != _setCurrentIndexVersion) return;
    }

    // Pause the previously active webview to save resources
    if (_currentIndex != null && _currentIndex! < _webViewModels.length && _loadedIndices.contains(_currentIndex)) {
      await _webViewModels[_currentIndex!].pauseWebView();
      if (version != _setCurrentIndexVersion) return;
    }

    // Restore cookies for target site before loading
    await _restoreCookiesForSite(index);
    if (version != _setCurrentIndexVersion) return;

    // Validate index is still in bounds after async gaps
    if (index >= _webViewModels.length) return;

    _currentIndex = index;
    _loadedIndices.add(index);
    _canGoBackVersion++; // Invalidate any in-flight _updateCanGoBack
    _canGoBack = false; // Reset until async check completes

    // Resume the newly active webview
    await _webViewModels[index].resumeWebView();
    _updateCanGoBack();

    // Auto-enter fullscreen if the site has fullscreenMode enabled
    if (target.fullscreenMode) {
      _enterFullscreen();
    } else {
      _exitFullscreen();
    }

    LogService.instance.log('CookieIsolation', 'After switch, loaded indices: $_loadedIndices');
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

    LogService.instance.log('PopupWindow', 'Opening popup window with id: $windowId, url: $url');

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
      List<Webspace> loadedWebspaces = webspacesJson
          .map((webspaceJson) => Webspace.fromJson(jsonDecode(webspaceJson)))
          .toList();

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

  Future<void> _loadWebViewModels() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? webViewModelsJson = prefs.getStringList('webViewModels');

    if (webViewModelsJson != null) {
      List<WebViewModel> loadedWebViewModels = webViewModelsJson
          .map((webViewModelJson) => WebViewModel.fromJson(jsonDecode(webViewModelJson), (){ setState((){}); _updateCanGoBack(); }))
          .toList();

      // Load cookies from secure storage (keyed by siteId or legacy domain)
      final secureCookies = await _cookieSecureStorage.loadCookies();

      // Load cookies into models by siteId (or migrate from domain-keyed)
      for (final webViewModel in loadedWebViewModels) {
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
      _showStatsBanner = prefs.getBool('showStatsBanner') ?? true;
      widget.onThemeSettingsChanged(_themeSettings);
    });
    await _loadWebspaces();
    await _loadGlobalUserScripts();
    await _loadWebViewModels();
    await _migrateGlobalScriptOptIn();
    _suggestedSites = await suggested_sites.getEffectiveSuggestedSites();

    // Startup GC: sweep orphaned per-siteId encrypted storage and HTML cache
    // (sites deleted in previous sessions), then nuke the native cookie jar
    // so residual cookies from deleted/legacy sites don't leak into the next
    // activated site. `_restoreCookiesForSite` re-nukes on every switch; this
    // extra pass covers launch before any site is activated.
    final activeSiteIdsAtStartup = _webViewModels.map((m) => m.siteId).toSet();
    await _cookieSecureStorage.removeOrphanedCookies(activeSiteIdsAtStartup);
    await HtmlCacheService.instance.removeOrphanedCaches(activeSiteIdsAtStartup);
    await _cookieManager.deleteAllCookies();

    // Always start at home screen on launch - only restore index if launched via shortcut
    final shortcutSiteId = await ShortcutService.getLaunchSiteId();
    final indexToRestore = StartupRestoreEngine.resolveLaunchTarget(
      shortcutSiteId: shortcutSiteId,
      models: _webViewModels,
    );

    // Set current index (async for cookie restoration)
    await _setCurrentIndex(indexToRestore);
    if (!mounted) return;
    setState(() {}); // Trigger UI update after async operation

    // Apply saved theme to all restored webviews
    final webViewTheme = _themeModeToWebViewTheme(_themeSettings.themeMode);
    for (var webViewModel in List.from(_webViewModels)) {
      await webViewModel.setTheme(webViewTheme);
    }
  }

  Future<void> launchUrl(String url, {
    String? homeTitle,
    required String? siteId,
    required bool incognito,
    required bool thirdPartyCookiesEnabled,
    required bool clearUrlEnabled,
    required bool dnsBlockEnabled,
    required bool contentBlockEnabled,
    required String? language,
    LocationMode locationMode = LocationMode.off,
    double? spoofLatitude,
    double? spoofLongitude,
    double spoofAccuracy = 50.0,
    String? spoofTimezone,
    WebRtcPolicy webRtcPolicy = WebRtcPolicy.defaultPolicy,
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
          language: language,
          showUrlBar: _showUrlBar,
          locationMode: locationMode,
          spoofLatitude: spoofLatitude,
          spoofLongitude: spoofLongitude,
          spoofAccuracy: spoofAccuracy,
          spoofTimezone: spoofTimezone,
          webRtcPolicy: webRtcPolicy,
        ),
      ),
    );
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
            setState(() {
              _webspaces.add(updatedWebspace);
            });
            _saveWebspaces();
          },
        ),
      ),
    );
  }

  void _editWebspace(Webspace webspace) async {
    // For "All" webspace, show all sites as selected but read-only
    final webspaceToEdit = webspace.id == kAllWebspaceId
        ? Webspace(
            id: kAllWebspaceId,
            name: 'All',
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

            setState(() {
              final index = _webspaces.indexWhere((ws) => ws.id == updatedWebspace.id);
              if (index != -1) {
                _webspaces[index] = updatedWebspace;
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
        final indicesToUnload = WebspaceSelectionEngine.indicesToUnloadOnWebspaceSwitch(
          loadedIndices: _loadedIndices,
          previousWebspaceIndices: previousIndices,
          newWebspaceIndices: newIndices,
        );

        for (final index in indicesToUnload) {
          if (index >= 0 && index < _webViewModels.length) {
            _webViewModels[index].disposeWebView();
            _loadedIndices.remove(index);
            LogService.instance.log('WebspaceSwitch', 'Unloaded site $index: "${_webViewModels[index].name}"');
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
    await SettingsBackupService.exportAndSave(
      context,
      webViewModels: _webViewModels,
      webspaces: _webspaces,
      themeMode: _themeSettings.toStorageIndex(),
      globalPrefs: readExportedAppPrefs(prefs),
      selectedWebspaceId: _selectedWebspaceId,
      currentIndex: _currentIndex,
      suggestedSites: _suggestedSites
          .map((s) => {'name': s.name, 'url': s.url, 'domain': s.domain})
          .toList(),
      globalUserScripts: _globalUserScripts.map((s) => s.toJson()).toList(),
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

      // Restore webspaces
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
    final prefsToWrite = await SharedPreferences.getInstance();
    await writeExportedAppPrefs(prefsToWrite, backup.globalPrefs);
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
    await HtmlCacheService.instance.removeOrphanedCaches(activeSiteIds);

    // Apply theme to all webviews
    final webViewTheme = _themeModeToWebViewTheme(_themeSettings.themeMode);
    for (var webViewModel in _webViewModels) {
      await webViewModel.setTheme(webViewTheme);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Settings imported successfully')),
      );
    }
  }

  WebViewController? getController() {
    if(_currentIndex == null) {
      return null;
    }
    return _webViewModels[_currentIndex!].getController(launchUrl, _cookieManager, _saveWebViewModels, globalUserScripts: _globalUserScripts);
  }

  /// Update _canGoBack from the current webview's controller.
  /// Used on iOS to enable drawer edge-swipe when there's no back history.
  /// Note: canGoBack() can return false for pushState/SPA navigations even
  /// when history exists, but that only means the drawer becomes swipeable
  /// when it shouldn't — the hamburger menu still provides back navigation
  /// via the PopScope URL-comparison fallback.
  void _updateCanGoBack() async {
    if (!Platform.isIOS) return;
    final version = ++_canGoBackVersion;

    final model = (_currentIndex != null && _currentIndex! < _webViewModels.length)
        ? _webViewModels[_currentIndex!]
        : null;
    final sync = NavigationEngine.trySyncCanGoBack(
      currentIndex: _currentIndex,
      siteCount: _webViewModels.length,
      currentUrl: model?.currentUrl,
      initUrl: model?.initUrl,
      hasController: model?.controller != null,
    );
    if (sync != null) {
      if (_canGoBack != sync) {
        if (model != null && sync == false && NavigationEngine.isHomeUrl(model.currentUrl, model.initUrl)) {
          LogService.instance.log('Navigation', '_updateCanGoBack: at home URL, forcing false');
        }
        setState(() => _canGoBack = sync);
      }
      return;
    }

    final canGoBack = await model!.controller!.canGoBack();
    if (!mounted || version != _canGoBackVersion) {
      LogService.instance.log('Navigation', '_updateCanGoBack: stale (v$version != v$_canGoBackVersion), discarding canGoBack=$canGoBack');
      return;
    }
    if (canGoBack != _canGoBack) {
      LogService.instance.log('Navigation', '_updateCanGoBack: $_canGoBack -> $canGoBack');
      setState(() => _canGoBack = canGoBack);
    }
  }

  /// Navigate to the site's initial URL and clear navigation history.
  /// Disposes the webview so it's recreated fresh with no back history.
  /// Drops the HTML cache (online only) so the next load starts from the
  /// live site rather than a stale cached frame. Offline: the cache is
  /// preserved — it's the only content we can render without network.
  void _goHome() {
    if (_currentIndex == null || _currentIndex! >= _webViewModels.length) return;
    final model = _webViewModels[_currentIndex!];
    _deleteCacheIfOnline(model.siteId);
    model.currentUrl = model.initUrl;
    model.disposeWebView();
    _canGoBackVersion++; // Invalidate any in-flight _updateCanGoBack
    setState(() {
      _canGoBack = false;
    });
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
                    showTabStrip: _showTabStrip,
                    onShowTabStripChanged: (value) {
                      setState(() {
                        _showTabStrip = value;
                      });
                      _saveShowTabStrip();
                    },
                    showStatsBanner: _showStatsBanner,
                    onShowStatsBannerChanged: (value) {
                      setState(() {
                        _showStatsBanner = value;
                      });
                      _saveShowStatsBanner();
                    },
                    globalUserScripts: _globalUserScripts,
                    onGlobalUserScriptsChanged: (scripts) {
                      _globalUserScripts = scripts;
                      _saveGlobalUserScripts();
                      _resetAllWebViews();
                    },
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
                      IconButton(
                        icon: Icon(Icons.refresh),
                        tooltip: 'Refresh',
                        onPressed: () {
                          Navigator.pop(context);
                          getController()?.reload();
                        },
                      ),
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
                      Icon(Icons.fullscreen),
                      SizedBox(width: 8),
                      Text("Full Screen"),
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
                if (Platform.isAndroid)
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
                  _enterFullscreen();
                break;
                case 'settings':
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => SettingsScreen(
                        webViewModel: _webViewModels[_currentIndex!],
                        globalUserScripts: _globalUserScripts,
                        onGlobalUserScriptsChanged: (scripts) {
                          _globalUserScripts = scripts;
                          _saveGlobalUserScripts();
                          _resetAllWebViews();
                        },
                        onScriptsChanged: _resetCurrentSiteWebView,
                        onClearCookies: () {
                          _webViewModels[_currentIndex!].deleteCookies(_cookieManager);
                          _saveWebViewModels();
                          getController()?.reload();
                        },
                        onProxySettingsChanged: (newProxySettings) {
                          setState(() {
                            for (var model in _webViewModels) {
                              model.proxySettings = UserProxySettings(
                                type: newProxySettings.type,
                                address: newProxySettings.address,
                              );
                            }
                          });
                          _saveWebViewModels();
                        },
                        onSettingsSaved: () async {
                          await _saveWebViewModels();
                          if (!mounted) return;

                          final index = _currentIndex;
                          final model = index != null && index < _webViewModels.length
                              ? _webViewModels[index]
                              : null;
                          final urlToLoad = model?.currentUrl;
                          final languageToUse = model?.language;

                          // Apply fullscreen setting immediately
                          if (model != null && model.fullscreenMode) {
                            _enterFullscreen();
                          } else {
                            _exitFullscreen();
                          }

                          setState(() {});

                          if (index != null && model != null && urlToLoad != null) {
                            WidgetsBinding.instance.addPostFrameCallback((_) async {
                              for (int i = 0; i < 20; i++) {
                                await Future.delayed(const Duration(milliseconds: 100));
                                if (!mounted) return;
                                if (model.controller != null) {
                                  LogService.instance.log('Settings', 'Reloading URL with language: $languageToUse');
                                  await model.controller!.loadUrl(urlToLoad, language: languageToUse);
                                  break;
                                }
                              }
                            });
                          }
                        },
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
                    final model = _webViewModels[_currentIndex!];
                    final faviconUrl = FaviconUrlCache.get(model.initUrl);
                    final isSvg = faviconUrl != null && faviconUrl.toLowerCase().endsWith('.svg');
                    await ShortcutService.pinShortcut(
                      siteId: model.siteId,
                      label: model.name,
                      iconUrl: isSvg ? null : faviconUrl,
                    );
                  }
                break;
                case 'devTools':
                  if (_currentIndex != null && _currentIndex! < _webViewModels.length) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => DevToolsScreen(
                          webViewModel: _webViewModels[_currentIndex!],
                          cookieManager: _cookieManager,
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
    if (_isFullscreen) return null;
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
              final controller = model.getController(launchUrl, _cookieManager, _saveWebViewModels, globalUserScripts: _globalUserScripts);
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
                IconButton(
                  icon: Icon(Icons.refresh),
                  tooltip: 'Refresh',
                  onPressed: () {
                    Navigator.pop(context);
                    getController()?.reload();
                  },
                ),
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
                Icon(Icons.fullscreen),
                SizedBox(width: 8),
                Text("Full Screen"),
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
          if (Platform.isAndroid)
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
            _enterFullscreen();
          break;
          case 'settings':
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => SettingsScreen(
                  webViewModel: _webViewModels[_currentIndex!],
                  globalUserScripts: _globalUserScripts,
                  onGlobalUserScriptsChanged: (scripts) {
                    _globalUserScripts = scripts;
                    _saveGlobalUserScripts();
                    _resetAllWebViews();
                  },
                  onScriptsChanged: _resetCurrentSiteWebView,
                  onClearCookies: () {
                    _webViewModels[_currentIndex!].deleteCookies(_cookieManager);
                    _saveWebViewModels();
                    getController()?.reload();
                  },
                  onProxySettingsChanged: (newProxySettings) {
                    setState(() {
                      for (var model in _webViewModels) {
                        model.proxySettings = UserProxySettings(
                          type: newProxySettings.type,
                          address: newProxySettings.address,
                        );
                      }
                    });
                    _saveWebViewModels();
                  },
                  onSettingsSaved: () async {
                    await _saveWebViewModels();
                    if (!mounted) return;

                    final index = _currentIndex;
                    final model = index != null && index < _webViewModels.length
                        ? _webViewModels[index]
                        : null;
                    final urlToLoad = model?.currentUrl;
                    final languageToUse = model?.language;

                    // Apply fullscreen setting immediately
                    if (model != null && model.fullscreenMode) {
                      _enterFullscreen();
                    } else {
                      _exitFullscreen();
                    }

                    setState(() {});

                    if (index != null && model != null && urlToLoad != null) {
                      WidgetsBinding.instance.addPostFrameCallback((_) async {
                        for (int i = 0; i < 20; i++) {
                          await Future.delayed(const Duration(milliseconds: 100));
                          if (!mounted) return;
                          if (model.controller != null) {
                            LogService.instance.log('Settings', 'Reloading URL with language: $languageToUse');
                            await model.controller!.loadUrl(urlToLoad, language: languageToUse);
                            break;
                          }
                        }
                      });
                    }
                  },
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
              final model = _webViewModels[_currentIndex!];
              final faviconUrl = FaviconUrlCache.get(model.initUrl);
              final isSvg = faviconUrl != null && faviconUrl.toLowerCase().endsWith('.svg');
              await ShortcutService.pinShortcut(
                siteId: model.siteId,
                label: model.name,
                iconUrl: isSvg ? null : faviconUrl,
              );
            }
          break;
          case 'devTools':
            if (_currentIndex != null && _currentIndex! < _webViewModels.length) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => DevToolsScreen(
                    webViewModel: _webViewModels[_currentIndex!],
                    cookieManager: _cookieManager,
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

  void _addSite() async {
    final result = await Navigator.push(
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
        ),
      ),
    );
    if (result == null || result is! Map<String, dynamic>) return;
    if (!mounted) return;

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

    final model = WebViewModel(
      initUrl: url,
      incognito: incognito,
      stateSetterF: () { setState((){}); _updateCanGoBack(); },
    );
    if (customName.isNotEmpty) {
      model.name = customName;
      model.pageTitle = customName;
    } else if (pageTitle != null && pageTitle.isNotEmpty) {
      model.name = pageTitle;
      model.pageTitle = pageTitle;
    }

    // For imported HTML files, store the content in HtmlCacheService
    // so the webview loads it via initialHtml on creation
    if (htmlContent != null && !incognito) {
      await HtmlCacheService.instance.saveHtml(model.siteId, htmlContent, url);
    }

    setState(() {
      _webViewModels.add(model);
    });

    final newSiteIndex = _webViewModels.length - 1;

    // If a non-"All" webspace is currently selected, add the new site to it
    if (_selectedWebspaceId != null && _selectedWebspaceId != kAllWebspaceId) {
      final webspaceIndex = _webspaces.indexWhere((ws) => ws.id == _selectedWebspaceId);
      if (webspaceIndex != -1) {
        _webspaces[webspaceIndex].siteIndices.add(newSiteIndex);
        await _saveWebspaces();
      }
    }

    // Set current index (async for cookie handling)
    await _setCurrentIndex(newSiteIndex);
    if (!mounted) return;
    setState(() {}); // Update UI after async operation

    await _saveCurrentIndex();
    await _saveWebViewModels();

    // Apply current theme to new webview
    final webViewTheme = _themeModeToWebViewTheme(_themeSettings.themeMode);
    await model.setTheme(webViewTheme);
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
      setState(() {
        _webViewModels[index].initUrl = newUrl;
        _webViewModels[index].currentUrl = newUrl;
        _webViewModels[index].webview = null; // Force recreation with new URL
        _webViewModels[index].controller = null;
      });
    }

    await _saveWebViewModels();
  }

  void _showSiteContextMenu(BuildContext context, int index, Offset position) {
    final isCustomWebspace = _selectedWebspaceId != null && _selectedWebspaceId != kAllWebspaceId;
    final filteredIndices = _getFilteredSiteIndices();
    final listIndex = filteredIndices.indexOf(index);

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
      ],
    ).then((value) async {
      if (value == null) return;
      switch (value) {
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
    if (oldListIndex < 0 || oldListIndex >= webspace.siteIndices.length) return;
    if (newListIndex < 0 || newListIndex >= webspace.siteIndices.length) return;
    setState(() {
      final movedIndex = webspace.siteIndices.removeAt(oldListIndex);
      webspace.siteIndices.insert(newListIndex, movedIndex);
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
    deletedModel.disposeWebView();
    _loadedIndices.remove(index);

    await ShortcutService.removeShortcut(deletedModel.siteId);
    if (!mounted) return;

    // Delegate cookie cleanup to the isolation engine: it snapshots any
    // loaded same-base-domain site's session, clears the deleted site's
    // native cookies, and restores the surviving session so the active
    // webview isn't silently logged out.
    await _cookieIsolation.preDeleteCookieCleanup(
      deletedModel: deletedModel,
      deletedIndex: index,
      models: _webViewModels,
      loadedIndices: _loadedIndices,
    );
    await HtmlCacheService.instance.deleteCache(deletedModel.siteId);
    if (!mounted) return;
    final currentModelIndex = _webViewModels.indexOf(deletedModel);
    if (currentModelIndex == -1) return;
    // Patch the index-dependent state: `_loadedIndices` and each webspace's
    // `siteIndices` are rewritten so indices > currentModelIndex shift down
    // by one, and the deleted index drops out. `_currentIndex` is handled
    // separately by the `wasCurrentIndex` branch below (preserving existing
    // semantics — we don't shift it here).
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
      for (final webspace in _webspaces) {
        final rewritten = patch.newSiteIndicesByWebspaceId[webspace.id];
        if (rewritten != null) webspace.siteIndices = rewritten;
      }
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
    await HtmlCacheService.instance.removeOrphanedCaches(activeSiteIds);

    if (!mounted) return;
    Navigator.pop(context);
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
    final hasTabStrip = _currentIndex != null
        && _currentIndex! < _webViewModels.length
        && _showTabStrip
        && filteredIndices.isNotEmpty;
    return SafeArea(
      top: false, // AppBar handles top inset; in fullscreen there's no AppBar either
      bottom: _isFullscreen ? false : (!hasTabStrip && inputBar == null),
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
                                  _saveWebViewModels,
                                  onWindowRequested: _showPopupWindow,
                                  language: webViewModel.language,
                                  globalUserScripts: _globalUserScripts,
                                  onHtmlLoaded: webViewModel.incognito ? null : (url, html) {
                                    HtmlCacheService.instance.saveHtml(webViewModel.siteId, html, url);
                                  },
                                  initialHtml: webViewModel.incognito
                                      ? null
                                      : () {
                                          final cached = HtmlCacheService.instance.getHtmlSync(webViewModel.siteId);
                                          if (cached == null) return null;
                                          final isDark = webViewModel.currentTheme == WebViewTheme.dark ||
                                              (webViewModel.currentTheme == WebViewTheme.system &&
                                                  MediaQuery.platformBrightnessOf(context) == Brightness.dark);
                                          return HtmlCacheService.applyThemePrelude(cached, dark: isDark);
                                        }(),
                                  isActive: () => _currentIndex == index,
                                  onConfirmScriptFetch: (url) async {
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
                                  },
                                  onExternalSchemeUrl: (url, info) async {
                                    if (!mounted) return;
                                    await confirmAndLaunchExternalUrl(
                                      context,
                                      info,
                                      fallbackController: webViewModel.controller,
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
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _exitFullscreen,
                        child: Align(
                          alignment: Alignment.bottomCenter,
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
    return PopScope(
      // On Android, always intercept back so we can implement the two-step
      // exit pattern (back → open drawer → back → exit app).
      // On other platforms, allow pop only when no webview is visible.
      canPop: Platform.isAndroid ? false : !webviewIsVisible,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _isBackHandling) return;
        _isBackHandling = true;
        try {
          final scaffoldState = _scaffoldKey.currentState;
          if (scaffoldState != null && scaffoldState.isDrawerOpen) {
            if (Platform.isAndroid) {
              LogService.instance.log('Navigation', 'Back gesture: drawer open, exiting app');
              SystemNavigator.pop();
            } else {
              LogService.instance.log('Navigation', 'Back gesture: closing open drawer');
              Navigator.pop(context);
            }
            return;
          }
          // Android homepage (no webview visible): open drawer as exit warning
          if (Platform.isAndroid && !webviewIsVisible) {
            LogService.instance.log('Navigation', 'Back gesture: homepage, opening drawer as exit hint');
            scaffoldState?.openDrawer();
            return;
          }
          // Webview is visible - try to go back in its history.
          // Don't trust canGoBack(): it can return false for pushState
          // entries on some webview versions. Instead, always attempt
          // goBack() (which is a no-op when there's no history) and
          // check whether the URL actually changed.
          final controller = getController();
          if (controller == null) {
            LogService.instance.log('Navigation', 'Back gesture: no controller, opening drawer');
            scaffoldState?.openDrawer();
            return;
          }
          final urlBefore = (await controller.getUrl())?.toString();
          await controller.goBack();
          // Give the native webview time to process the navigation
          await Future.delayed(const Duration(milliseconds: 150));
          if (!mounted) return;
          final urlAfter = (await controller.getUrl())?.toString();
          if (urlBefore == urlAfter) {
            LogService.instance.log('Navigation', 'Back gesture: URL unchanged ($urlAfter), opening drawer');
            scaffoldState?.openDrawer();
          } else {
            LogService.instance.log('Navigation', 'Back gesture: navigated back from $urlBefore to $urlAfter');
            if (Platform.isIOS && _currentIndex != null && _currentIndex! < _webViewModels.length) {
              // After a successful goBack(), if we've landed on the home URL,
              // synchronously clear _canGoBack so the drawer edge-swipe is
              // enabled immediately for the next gesture.
              final homeUrl = _webViewModels[_currentIndex!].initUrl;
              if (urlAfter != null && NavigationEngine.isHomeUrl(urlAfter, homeUrl)) {
                LogService.instance.log('Navigation', 'Back gesture: landed on home URL, enabling drawer swipe');
                ++_canGoBackVersion;
                setState(() => _canGoBack = false);
              }
            }
          }
        } finally {
          _isBackHandling = false;
        }
      },
      child: Scaffold(
      key: _scaffoldKey,
      // Disable drawer edge drag when a webview is active to prevent conflict
      // between the drawer swipe gesture and the system back/navigation gesture.
      // On iOS, re-enable it when the webview has no back history — the left
      // edge swipe does nothing in that state (PopScope blocks pop, drawer drag
      // is disabled), so letting it open the drawer is strictly additive.
      drawerEdgeDragWidth: webviewIsVisible
          ? (Platform.isIOS && !_canGoBack ? null : 0)
          : null,
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
