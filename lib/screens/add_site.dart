import 'dart:async';
import 'package:webspace/platform/host_platform.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/toast.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/webspace_chips.dart';
import 'favicon_image.dart';
import '../services/icon_service.dart' show getFaviconUrlStream, getSvgContent, onSvgContentCached, invalidateFaviconFor, faviconInvalidations, IconUpdate, iconReloads, reloadAllIcons;
import '../services/file_dialog.dart';
import '../services/html_import_storage.dart' show importedFileSite;
import '../services/outbound_http.dart' show resolveEffectiveProxy;
import '../services/site_icon_store.dart';
import '../services/reentry_guard.dart';
import '../services/top_sites_engine.dart' show siteAddress;
import '../services/top_sites_service.dart';
import '../settings/app_prefs.dart';
import '../widgets/datasets.dart' show TopSitesDataset;
import '../widgets/setting_tile.dart' show HintedTitle;
import '../services/url_host.dart';
import '../settings/proxy.dart';
import '../settings/site_suggestion.dart';
import '../utils/url_utils.dart';
import '../web_view_model.dart' show WebViewModel;
import 'site_settings_qr.dart';

/// Persistent cache for favicon URLs and SVG content
class FaviconUrlCache {
  static const String _prefix = 'favicon_src_';
  // Releases up to v0.3.5 kept icon URLs here, some resolved through
  // third-party icon services (ICON-014), so they are dropped and each icon
  // is found again on its site.
  static const String _retiredPrefix = 'favicon_url_';
  static const String _svgPrefix = 'favicon_svg_';
  static SharedPreferences? _prefs;

  static Future<void> initialize() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith(_retiredPrefix)) await prefs.remove(key);
    }
    onSvgContentCached =
        (url, {required content}) => setSvg(url, svgContent: content);
  }

  static String? get(String siteUrl) =>
      _prefs?.getString('$_prefix$siteUrl');

  static Future<void> set(String siteUrl, {required String faviconUrl}) async {
    _missing.remove(siteUrl);
    await _prefs?.setString('$_prefix$siteUrl', faviconUrl);
  }

  /// Sites whose last icon search this session found nothing, held in memory
  /// only: an icon widget made afresh for one, as a site's opening card is,
  /// knows it from its first frame instead of once its own search ends.
  static final Set<String> _missing = {};

  static bool isMissing(String siteUrl) => _missing.contains(siteUrl);

  static void markMissing(String siteUrl) => _missing.add(siteUrl);

  static String? getSvg(String faviconUrl) =>
      _prefs?.getString('$_svgPrefix$faviconUrl');

  static Future<void> setSvg(String faviconUrl,
      {required String svgContent}) async {
    await _prefs?.setString('$_svgPrefix$faviconUrl', svgContent);
  }

  /// Invalidate cached favicon for a site, triggering re-fetch. The icon the
  /// site's own webview reported goes too unless [keepSiteIcon]: a TLS pin
  /// re-fetches the fetched candidates, it says nothing about the page icon.
  static Future<void> invalidate(String siteUrl,
      {bool keepSiteIcon = false}) async {
    _missing.remove(siteUrl);
    final oldUrl = _prefs?.getString('$_prefix$siteUrl');
    await _prefs?.remove('$_prefix$siteUrl');
    if (oldUrl != null) {
      await _prefs?.remove('$_svgPrefix$oldUrl');
    }
    if (!keepSiteIcon) await SiteIconStore.instance.remove(siteUrl);
    invalidateFaviconFor(siteUrl);
  }

  /// Drop every cached icon: the URLs and SVGs kept here, the icons sites
  /// reported, and the icon service's memory. Every icon on screen is then
  /// fetched again.
  static Future<void> resetAll() async {
    _missing.clear();
    final prefs = _prefs;
    if (prefs != null) {
      for (final key in prefs.getKeys().toList()) {
        if (key.startsWith(_prefix) || key.startsWith(_svgPrefix)) {
          await prefs.remove(key);
        }
      }
    }
    await SiteIconStore.instance.clear();
    reloadAllIcons();
  }
}

/// Whether the add-site preview may run its DNS reachability probe for
/// [host] on the device's own resolver. False as soon as any outbound proxy
/// is configured — the preview is a convenience, and losing it costs the user
/// nothing but a preview card that stays up for a host that turns out not to
/// exist — and never for an onion service, which only Tor resolves
/// (LEAK-016).
bool addSitePreviewMayResolveLocally(String host) =>
    !Host(host).isOnion &&
    resolveEffectiveProxy(
          UserProxySettings(type: ProxyType.DEFAULT),
          siteId: null,
        ).type ==
        ProxyType.DEFAULT;

// A site's icon: the page icon the site's own webview produced (ICON-009/013)
// when there is one, else the best its home page declares (ICON-002).
class UnifiedFaviconImage extends StatefulWidget {
  final String url;
  final double size;
  /// Per-site proxy of the site this favicon belongs to. When null (e.g. for
  /// search-suggestion thumbnails with no specific site context), the
  /// app-global outbound proxy applies. When set, [resolveEffectiveProxy]
  /// chooses per-site if explicit, or global if the per-site type is DEFAULT.
  final UserProxySettings? proxy;
  /// User-chosen icon bytes (`WebViewModel.customIconPng`). When set, they
  /// render directly and no favicon is fetched for this widget.
  final Uint8List? customIcon;

  /// Whether the resolved favicon URL (and SVG body) may be written to
  /// plaintext SharedPreferences. False for archive-tier sites: a
  /// `favicon_src_<initUrl>` key would name the archived site on disk
  /// after the archive closes (ARCH-001). The in-memory caches still serve
  /// the session either way.
  final bool persist;

  /// What the icon is drawn in, told whether a generic globe stands in for
  /// an icon the site does not have; null draws the icon alone.
  final Widget Function(
    BuildContext context, {
    required bool missing,
    required Widget icon,
  })? frame;

  const UnifiedFaviconImage({
    super.key,
    required this.url,
    required this.size,
    this.proxy,
    this.customIcon,
    this.persist = true,
    this.frame,
  });

  /// [site]'s own icon: the one the user picked if any, fetched through the
  /// site's proxy, and never written to disk for an archive-tier site.
  UnifiedFaviconImage.site(
    WebViewModel site, {
    super.key,
    required this.size,
    this.frame,
  }) : url = site.initUrl,
       proxy = site.outboundProxySettings,
       customIcon = site.customIconPng,
       persist = !site.isArchiveTier;

  @override
  State<UnifiedFaviconImage> createState() => _UnifiedFaviconImageState();
}

class _UnifiedFaviconImageState extends State<UnifiedFaviconImage> {
  String? _currentIconUrl;
  String? _svgContent; // Cached SVG content for offline display
  int _currentQuality = 0;
  bool _isLoading = true;
  Stream<IconUpdate>? _iconStream;
  StreamSubscription<IconUpdate>? _iconSub;
  StreamSubscription<String>? _invalidationSub;
  StreamSubscription<String?>? _siteIconSub;
  StreamSubscription<void>? _reloadSub;

  /// Whether the icon's image, or its SVG body, failed to come, so the globe
  /// stands in for it.
  bool _imageFailed = false;
  bool _svgFailed = false;

  bool _isSvgUrl(String url) =>
      url.toLowerCase().endsWith('.svg') || url.contains('.svg?');

  @override
  void initState() {
    super.initState();
    // A TLS pin granted after this widget mounted can rescue a favicon
    // fetch that originally died on CERTIFICATE_VERIFY_FAILED — listen
    // for invalidations targeting our URL and reset.
    _invalidationSub = faviconInvalidations.listen((invalidatedUrl) {
      if (invalidatedUrl == widget.url && mounted && widget.customIcon == null) {
        unawaited(FaviconUrlCache.invalidate(widget.url, keepSiteIcon: true));
        _resetAndLoad();
      }
    });
    _reloadSub = iconReloads.listen((_) {
      if (!mounted || widget.customIcon != null) return;
      // Clearing the site icons already restarted a load with nothing shown.
      if (_currentIconUrl == null && _iconStream != null) return;
      setState(_resetAndLoad);
    });
    _siteIconSub = SiteIconStore.instance.changes.listen((siteUrl) {
      if (!mounted || (siteUrl != null && siteUrl != widget.url)) return;
      if (widget.customIcon != null) return;
      if (SiteIconStore.instance.get(widget.url) != null) {
        setState(() {});
      } else if (_currentIconUrl == null && _iconStream == null) {
        _resetAndLoad();
        setState(() {});
      }
    });
    if (widget.customIcon == null) {
      _loadIcon();
    } else {
      _isLoading = false;
    }
  }

  @override
  void dispose() {
    unawaited(_iconSub?.cancel());
    unawaited(_invalidationSub?.cancel());
    unawaited(_siteIconSub?.cancel());
    unawaited(_reloadSub?.cancel());
    super.dispose();
  }

  @override
  void didUpdateWidget(UnifiedFaviconImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.customIcon, widget.customIcon)) {
      _imageFailed = false;
    }
    if (widget.customIcon != null) return; // build() renders the bytes directly
    if (oldWidget.url != widget.url || oldWidget.customIcon != null) {
      _resetAndLoad();
    } else if (_currentIconUrl != null && FaviconUrlCache.get(widget.url) == null) {
      // Cache was invalidated (e.g. by refresh) — re-fetch
      _resetAndLoad();
    }
  }

  void _resetAndLoad() {
    // The previous fetch would keep writing into the reset state and persist
    // its result on done.
    unawaited(_iconSub?.cancel());
    _iconSub = null;
    _currentIconUrl = null;
    _svgContent = null;
    _imageFailed = false;
    _svgFailed = false;
    _currentQuality = 0;
    _isLoading = true;
    _iconStream = null;
    _loadIcon();
  }

  void _loadIcon() {
    if (SiteIconStore.instance.get(widget.url) != null) {
      _isLoading = false;
      return;
    }

    final cachedUrl = FaviconUrlCache.get(widget.url);
    if (cachedUrl != null) {
      _currentIconUrl = cachedUrl;
      _currentQuality = 100;
      _isLoading = false;
      if (_isSvgUrl(cachedUrl)) {
        unawaited(_fetchSvgContent(cachedUrl));
      } else {
        setState(() {});
      }
      return;
    }

    _startIconStream();
  }

  Future<void> _fetchSvgContent(String url) async {
    final content = await getSvgContent(
      url,
      persistedContent: FaviconUrlCache.getSvg(url),
      proxy: widget.proxy,
      persist: widget.persist,
    );
    if (mounted) {
      setState(() {
        _svgContent = content;
        _svgFailed = content == null;
      });
    }
  }

  void _startIconStream() {
    _iconStream = getFaviconUrlStream(widget.url, proxy: widget.proxy);
    _iconSub = _iconStream!.listen(
      (update) {
        if (mounted && update.quality > _currentQuality) {
          setState(() {
            _currentIconUrl = update.url;
            _currentQuality = update.quality;
            _imageFailed = false;
            _svgFailed = false;
            if (update.isFinal) {
              _isLoading = false;
              if (widget.persist) {
                unawaited(FaviconUrlCache.set(widget.url, faviconUrl: update.url));
              }
            }
          });
          if (_isSvgUrl(update.url)) unawaited(_fetchSvgContent(update.url));
        }
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _isLoading = false);
        final url = _currentIconUrl;
        if (url == null) FaviconUrlCache.markMissing(widget.url);
        if (url != null && widget.persist) {
          unawaited(FaviconUrlCache.set(widget.url, faviconUrl: url));
        }
      },
    );
  }

  /// Whether the globe stands in for an icon the site does not have: its
  /// search ended with none, now or earlier this session, or what it found
  /// failed to draw. While a search runs the site is not yet iconless.
  bool get _missing {
    if (_imageFailed) return true;
    if (widget.customIcon != null ||
        SiteIconStore.instance.get(widget.url) != null) {
      return false;
    }
    final iconUrl = _currentIconUrl;
    if (iconUrl != null) return _isSvgUrl(iconUrl) && _svgFailed;
    return !_isLoading || FaviconUrlCache.isMissing(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    final icon = _icon(context);
    final frame = widget.frame;
    return frame == null ? icon : frame(context, missing: _missing, icon: icon);
  }

  Widget _icon(BuildContext context) {
    Widget fallback(BuildContext context) => Icon(
          Icons.language,
          size: widget.size,
          color: Theme.of(context).colorScheme.primary,
        );
    // The globe drawn where an image failed: the frame learns of it after
    // this frame, since a child's error builder runs inside this build.
    Widget failed(BuildContext context) {
      if (!_imageFailed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_imageFailed) setState(() => _imageFailed = true);
        });
      }
      return fallback(context);
    }
    Widget spinner(BuildContext context) => SizedBox(
          width: widget.size,
          height: widget.size,
          child: CircularProgressIndicator(strokeWidth: 2),
        );

    final bytes = widget.customIcon ?? SiteIconStore.instance.get(widget.url);
    if (bytes != null) {
      return Image.memory(
        bytes,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        gaplessPlayback: true,
        errorBuilder: (context, _, _) => failed(context),
      );
    }

    final iconUrl = _currentIconUrl;
    if (iconUrl == null) {
      return _isLoading ? spinner(context) : fallback(context);
    }
    if (!_isSvgUrl(iconUrl)) {
      return faviconNetworkImage(
        url: iconUrl,
        size: widget.size,
        proxy: widget.proxy,
        placeholder: spinner,
        error: failed,
      );
    }
    final svg = _svgContent;
    // SVG not cached yet — show placeholder, never use SvgPicture.network
    if (svg == null) return fallback(context);
    // Wrap in MediaQuery to pass app theme to SVG's CSS media queries
    // (e.g., @media (prefers-color-scheme: dark) in codeberg's favicon)
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        platformBrightness: Theme.of(context).brightness,
      ),
      child: SvgPicture.string(
        svg,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.contain,
      ),
    );
  }
}

class AddSiteScreen extends StatefulWidget {
  final List<SiteSuggestion> suggestions;
  final Function(List<SiteSuggestion>) onSuggestionsChanged;
  final String? initialUrl;

  /// The homes of the sites already added, which the field does not offer.
  final List<String> existingUrls;

  /// The named webspaces offered to the new site, and those picked for it;
  /// null where none are offered.
  final WebspacePick? webspaces;

  AddSiteScreen({
    required this.suggestions,
    required this.onSuggestionsChanged,
    required this.existingUrls,
    this.initialUrl,
    this.webspaces,
  });

  @override
  _AddSiteScreenState createState() => _AddSiteScreenState();
}

class _AddSiteScreenState extends State<AddSiteScreen> {
  final TextEditingController _urlController = TextEditingController();
  final FocusNode _urlFocus = FocusNode();
  late final Set<String> _added = {
    for (final url in widget.existingUrls) siteAddress(url),
  };

  /// The popular sites list, offered here until it is downloaded or the
  /// offer is dismissed (SUGGEST-012); read before the offer shows, so a
  /// list on disk never flashes it.
  final TopSitesDataset _topSites = TopSitesDataset();
  final ReentryGuard _topSitesDownload = ReentryGuard();
  bool _topSitesRead = false;
  bool _downloadingTopSites = false;
  Timer? _debounceTimer;
  String? _previewUrl;
  late List<SiteSuggestion> _suggestions;

  @override
  void initState() {
    super.initState();
    _suggestions = List.of(widget.suggestions);
    _topSites.addListener(_rebuild);
    unawaited(TopSitesService.instance.load().then((_) {
      if (mounted) setState(() => _topSitesRead = true);
    }));
    _urlController.addListener(_onUrlChanged);
    if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      _urlController.text = widget.initialUrl!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _updatePreview());
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _urlController.removeListener(_onUrlChanged);
    _urlController.dispose();
    _urlFocus.dispose();
    _topSites.removeListener(_rebuild);
    _topSites.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  bool get _offerTopSites =>
      _topSitesRead && !_topSites.ready && AppPref.topSitesOffer.value;

  Future<void> _downloadTopSites() async {
    await _topSitesDownload.run(() async {
      final loc = AppLocalizations.of(context);
      setState(() => _downloadingTopSites = true);
      final message = await _topSites.download(loc);
      if (!mounted) return;
      setState(() => _downloadingTopSites = false);
      ScaffoldMessenger.of(context).toast(message);
    });
  }

  void _dismissTopSitesOffer() {
    unawaited(AppPref.topSitesOffer.set(false));
    setState(() {});
    ScaffoldMessenger.of(context)
        .toast(AppLocalizations.of(context).topSitesOfferDismissed);
  }

  /// The popular sites list offered where it is used (SUGGEST-012).
  Widget _topSitesOffer(AppLocalizations loc) => Padding(
        padding: const EdgeInsets.only(top: Spacing.sm),
        child: Row(
          children: [
            Icon(Icons.public,
                size: IconSizes.action,
                color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: HintedTitle(
                loc.topSitesOffer,
                hint: loc.topSitesHint,
                hintTitle: loc.topSitesTitle,
              ),
            ),
            if (_downloadingTopSites)
              const SizedBox.square(
                dimension: IconSizes.action,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              TextButton(
                onPressed: () => unawaited(_downloadTopSites()),
                child: Text(loc.appSettingsDownload),
              ),
            IconButton(
              icon: const Icon(Icons.close, size: IconSizes.action),
              tooltip: loc.commonClose,
              onPressed: _downloadingTopSites ? null : _dismissTopSitesOffer,
            ),
          ],
        ),
      );

  void _onUrlChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 600), _updatePreview);
  }

  /// Check if a host is an IP address or localhost (no DNS needed)
  bool _isDirectHost(String host) =>
      host == 'localhost' ||
      host.contains(':') || // IPv6
      RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(host); // IPv4

  Future<void> _updatePreview() async {
    final uri = Uri.tryParse(ensureUrlScheme(_urlController.text.trim()));
    final host = uri?.host ?? '';
    String? preview;
    if (host.contains('.') || host.contains(':') || host == 'localhost') {
      // Skip DNS check for IP addresses, localhost, and whenever an outbound
      // proxy is configured: the probe runs on the device's own resolver, so
      // under Tor it would hand the local resolver and the ISP every site the
      // user is about to add (LEAK-006). The proxy resolves the name itself
      // when the site is actually loaded.
      final resolves = _isDirectHost(host) ||
          !addSitePreviewMayResolveLocally(host) ||
          await hostCanResolve(host);
      if (resolves) preview = '${uri!.scheme}://$host';
    }
    if (mounted && _previewUrl != preview) {
      setState(() => _previewUrl = preview);
    }
  }

  Future<void> _addByQr() async {
    final decoded = await showSiteSettingsQrApplyDialog(context);
    if (decoded == null || !mounted) return;
    Navigator.pop(context, {'qrSettings': decoded});
  }

  Future<void> _importHtmlFile() async {
    try {
      final file = await FileDialog.pickFile(extensions: ['html', 'htm']);
      if (file == null) return;

      final bytes = file.bytes;
      final path = file.path;
      final htmlContent = bytes != null
          ? String.fromCharCodes(bytes)
          : path != null
              ? await hostReadFileText(path)
              : null;
      if (!mounted) return;
      if (htmlContent == null) {
        ScaffoldMessenger.of(context)
            .toast(AppLocalizations.of(context).addSiteFileReadError);
        return;
      }

      final site = importedFileSite(file.name);
      Navigator.pop(context, {
        'url': site.url,
        'name': site.name,
        'htmlContent': htmlContent,
      });
    } on FileDialogFailure catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .toast(AppLocalizations.of(context).addSiteImportFailed('$e'));
      }
    } on IOException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .toast(AppLocalizations.of(context).addSiteImportFailed('$e'));
      }
    }
  }

  void _showAddSuggestionDialog() {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    unawaited(showDialog(
      context: context,
      builder: (context) {
        final loc = AppLocalizations.of(context);
        final urlHint = 'https://example.com';
        return AlertDialog(
          title: Text(loc.addSiteAddSuggestedTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: loc.addSiteNameLabel,
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 8),
              TextField(
                controller: urlController,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: loc.addSiteUrlLabel,
                  border: OutlineInputBorder(),
                  hintText: urlHint,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(loc.commonCancel),
            ),
            ElevatedButton(
              onPressed: () {
                final name = nameController.text.trim();
                var url = urlController.text.trim();
                if (name.isEmpty || url.isEmpty) return;
                url = ensureUrlScheme(url);
                final uri = Uri.tryParse(url);
                if (uri == null || uri.host.isEmpty) return;
                final suggestion = SiteSuggestion(
                  name: name,
                  url: url,
                  domain: uri.host,
                );
                Navigator.of(context).pop();
                setState(() => _suggestions.add(suggestion));
                widget.onSuggestionsChanged(_suggestions);
              },
              child: Text(loc.commonAdd),
            ),
          ],
        );
      },
    ));
  }

  void _showSuggestionDialog(SiteSuggestion suggestion) {
    final TextEditingController urlController = TextEditingController(text: suggestion.url);
    bool incognito = false;

    unawaited(showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final loc = AppLocalizations.of(context);
            return AlertDialog(
              title: Text(loc.addSiteAddNamedTitle(suggestion.name)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: urlController,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: loc.addSiteSiteUrlLabel,
                      border: OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          incognito ? Icons.visibility_off : Icons.visibility_off_outlined,
                          color: incognito ? Theme.of(context).colorScheme.primary : null,
                        ),
                        tooltip: incognito ? loc.addSiteIncognitoOn : loc.addSiteIncognitoOff,
                        onPressed: () =>
                            setDialogState(() => incognito = !incognito),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(loc.commonCancel),
                ),
                ElevatedButton(
                  onPressed: () {
                    final url = ensureUrlScheme(urlController.text.trim());
                    Navigator.of(context).pop();
                    Navigator.of(context).pop({'url': url, 'name': '', 'incognito': incognito});
                  },
                  child: Text(loc.commonAdd),
                ),
              ],
            );
          },
        );
      },
    ));
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.addSiteScreenTitle)),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tileSize = (constraints.maxWidth - 36) / 4; // 4 columns with 12px spacing
            final iconSize = tileSize * 0.7;

            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Popular sites complete the address on this device
                      // only: no option's icon is fetched (SUGGEST-007).
                      Autocomplete<String>(
                        textEditingController: _urlController,
                        focusNode: _urlFocus,
                        optionsBuilder: (value) => TopSitesService.instance
                            .match(value.text, added: _added),
                        fieldViewBuilder:
                            (context, controller, focusNode, onSubmitted) =>
                                TextField(
                          controller: controller,
                          focusNode: focusNode,
                          autofocus: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          keyboardType: TextInputType.url,
                          onSubmitted: (_) => onSubmitted(),
                          decoration: InputDecoration(
                            labelText: loc.addSiteEnterUrlLabel,
                            prefixIcon: _previewUrl != null
                                ? Padding(
                                    padding: const EdgeInsets.all(12.0),
                                    child: SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: UnifiedFaviconImage(
                                        url: _previewUrl!,
                                        size: 24,
                                      ),
                                    ),
                                  )
                                : null,
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.qr_code_scanner),
                              tooltip: loc.addSiteAddFromQr,
                              onPressed: _addByQr,
                            ),
                          ),
                        ),
                      ),
                      if (_offerTopSites) _topSitesOffer(loc),
                      if (widget.webspaces case final pick?) ...[
                        const SizedBox(height: Spacing.md),
                        WebspaceChips(pick: pick),
                      ],
                      SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () => Navigator.pop(context, {
                                'url': ensureUrlScheme(_urlController.text.trim()),
                                'name': '',
                              }),
                              child: Text(loc.addSiteAddSiteButton),
                            ),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _importHtmlFile,
                              icon: Icon(Icons.file_open),
                              label: Text(loc.addSiteImportFileButton),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 8),
                      Text(
                        loc.addSiteSchemeTip,
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              loc.addSiteSuggestedSitesHeader,
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.add, size: 20),
                            tooltip: loc.addSiteAddSuggestedTooltip,
                            onPressed: _showAddSuggestionDialog,
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      SizedBox(height: 12),
                    ],
                  ),
                ),
                if (_suggestions.isNotEmpty)
                  SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 1,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final suggestion = _suggestions[index];
                        return InkWell(
                          onTap: () => _showSuggestionDialog(suggestion),
                          onLongPress: () async {
                            final remove = await confirm(
                              context,
                              title: loc.addSiteRemoveSuggestionTitle(suggestion.name),
                              body: loc.addSiteRemoveSuggestionBody,
                              confirmLabel: loc.commonRemove,
                              destructive: false,
                            );
                            if (!remove || !mounted) return;
                            setState(() => _suggestions.removeAt(index));
                            widget.onSuggestionsChanged(_suggestions);
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(4.0),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Center(
                                      child: UnifiedFaviconImage(
                                        url: 'https://${suggestion.domain}',
                                        size: iconSize,
                                      ),
                                    ),
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    suggestion.name,
                                    style: TextStyle(fontSize: 10),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                      childCount: _suggestions.length,
                    ),
                  ),
                if (_suggestions.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24.0),
                      child: Center(
                        child: Text(
                          loc.addSiteNoSuggestions,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).padding.bottom,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
