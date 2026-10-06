import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/link_handling_settings.dart';
import 'package:webspace/services/container_color_engine.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/services/web_search_engine.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/container_mark.dart' show SiteIdLine;
import 'package:webspace/widgets/hint_button.dart';

/// Everything the behaviour screen may change, in one value so the caller can
/// apply a whole edit in a single `setState`.
///
/// Same contract as `SitePrivacyValues` and `SitePermissionValues`: the
/// settings screen keeps the fields, the dirty-snapshot diff and the save
/// path, and this is only a different way of presenting them. Moving the
/// fields here would take them out of that diff, which is how unsaved edits
/// get dropped (BUG-006).
class SiteBehaviourValues {
  const SiteBehaviourValues({
    required this.alwaysOpenHome,
    required this.kioskMode,
    required this.fullscreenMode,
    required this.htmlCachingEnabled,
    required this.externalLinkMode,
    this.tabsEnabled = true,
    this.routeOutboundLinks = false,
    this.outboundPreferences = const [],
    this.searchAddress,
    this.searchesWeb = false,
    this.searchSites = const [],
    this.searchDefault,
  });

  final bool alwaysOpenHome;
  final bool kioskMode;
  final bool fullscreenMode;
  final bool tabsEnabled;
  final bool htmlCachingEnabled;
  final ExternalLinkMode externalLinkMode;
  final bool routeOutboundLinks;
  final List<OutboundPreference> outboundPreferences;

  /// LIR-028: how to search this site, and what a search from it offers.
  final String? searchAddress;
  final bool searchesWeb;
  final List<String> searchSites;
  final String? searchDefault;

  static const Object _keep = Object();

  SiteBehaviourValues copyWith({
    bool? alwaysOpenHome,
    bool? kioskMode,
    bool? fullscreenMode,
    bool? tabsEnabled,
    bool? htmlCachingEnabled,
    ExternalLinkMode? externalLinkMode,
    bool? routeOutboundLinks,
    List<OutboundPreference>? outboundPreferences,
    Object? searchAddress = _keep,
    bool? searchesWeb,
    List<String>? searchSites,
    Object? searchDefault = _keep,
  }) =>
      SiteBehaviourValues(
        alwaysOpenHome: alwaysOpenHome ?? this.alwaysOpenHome,
        kioskMode: kioskMode ?? this.kioskMode,
        fullscreenMode: fullscreenMode ?? this.fullscreenMode,
        tabsEnabled: tabsEnabled ?? this.tabsEnabled,
        htmlCachingEnabled: htmlCachingEnabled ?? this.htmlCachingEnabled,
        externalLinkMode: externalLinkMode ?? this.externalLinkMode,
        routeOutboundLinks: routeOutboundLinks ?? this.routeOutboundLinks,
        outboundPreferences: outboundPreferences ?? this.outboundPreferences,
        searchAddress: identical(searchAddress, _keep)
            ? this.searchAddress
            : searchAddress as String?,
        searchesWeb: searchesWeb ?? this.searchesWeb,
        searchSites: searchSites ?? this.searchSites,
        searchDefault: identical(searchDefault, _keep)
            ? this.searchDefault
            : searchDefault as String?,
      );

  /// Incognito drops the stored URL on every restart, so the site opens at its
  /// home page whatever this stores. Mirrors `WebViewModel.toJson`'s `dropUrl`,
  /// which is what actually decides it.
  bool effectiveAlwaysOpenHome(bool incognito) => incognito || alwaysOpenHome;

  /// Mirrors `WebViewModel.effectiveTabsEnabled` (TAB-013).
  bool get effectiveTabsEnabled => tabsEnabled && !kioskMode;

  /// Routing is an option of the in-app mode (LIR-014); mirrors
  /// `WebViewModel.effectiveRouteOutboundLinks`.
  bool get effectiveRouteOutboundLinks =>
      routeOutboundLinks && externalLinkMode == ExternalLinkMode.inApp;
}

/// Per-site behaviour screen: how the app hosts the site — where it opens, how
/// much of the shell it gets, and where links leaving it end up. The
/// counterpart of the privacy and permissions screens, which cover what the
/// site may learn and what it may reach.
class SiteBehaviourScreen extends StatefulWidget {
  const SiteBehaviourScreen({
    super.key,
    required this.host,
    required this.incognito,
    required this.values,
    required this.onChanged,
    this.domainClaims,
    this.containersActive = true,
    this.routingTargets = const [],
    this.tabsAvailable,
    this.initUrl,
    this.discoveredSearchAddress,
    this.discoveredSearchesWeb = false,
  });

  final String host;

  /// Read-only here: incognito is a privacy-screen setting, and this screen
  /// only needs it to render Always open Home as already in force.
  final bool incognito;

  final SiteBehaviourValues values;
  final ValueChanged<SiteBehaviourValues> onChanged;

  /// The site's `DomainClaimsEditor`, built by the caller. It writes straight
  /// to the model rather than through [values], so it stays with the screen
  /// that holds the model; it renders here because the link group is where a
  /// reader looks for it (the external-links hint points at it).
  final Widget? domainClaims;

  /// Outbound routing runs only on the container engine (LIR-014); on the
  /// legacy engine its switch is disabled.
  final bool containersActive;

  /// The sites a routing preference may name: this site's LIR-014 candidates
  /// other than itself.
  final List<WebViewModel> routingTargets;

  /// Whether the Tabs row is shown: tabs are experimental (TAB-012), so the
  /// row exists only while the app-wide switch lets them in. Null reads the
  /// switch.
  final bool? tabsAvailable;

  /// The site's home, which decides the search address it is known for.
  final String? initUrl;

  /// The search address the site's pages declared (LIR-035), shown when it
  /// has no address of its own and its host is not a known one.
  final String? discoveredSearchAddress;
  final bool discoveredSearchesWeb;

  @override
  State<SiteBehaviourScreen> createState() => _SiteBehaviourScreenState();
}

class _SiteBehaviourScreenState extends State<SiteBehaviourScreen> {
  late SiteBehaviourValues _values = widget.values;

  void _update(SiteBehaviourValues next) {
    setState(() => _values = next);
    widget.onChanged(next);
  }

  Widget _groupHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  Widget _tile({
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
    String? hintTitle,
    String? hint,
    String? subtitle,
  }) =>
      SwitchListTile(
        title: hint == null
            ? Text(title)
            : Row(
                children: [
                  Flexible(child: Text(title)),
                  HintButton(title: hintTitle ?? title, description: hint),
                ],
              ),
        subtitle: subtitle == null ? null : Text(subtitle),
        value: value,
        onChanged: onChanged,
      );

  // --- Opening and display -------------------------------------------------

  Widget _alwaysOpenHome(AppLocalizations loc) => _tile(
        title: loc.siteSettingsAlwaysOpenHome,
        subtitle: widget.incognito
            ? loc.siteSettingsAlwaysOpenHomeForced
            : loc.siteSettingsAlwaysOpenHomeSubtitle,
        value: _values.effectiveAlwaysOpenHome(widget.incognito),
        onChanged: widget.incognito
            ? null
            : (value) => _update(_values.copyWith(alwaysOpenHome: value)),
      );

  Widget _kioskMode(AppLocalizations loc) => _tile(
        title: loc.siteSettingsKioskMode,
        hint: loc.siteSettingsKioskModeHint,
        value: _values.kioskMode,
        onChanged: (value) => _update(_values.copyWith(kioskMode: value)),
      );

  Widget _fullscreen(AppLocalizations loc) => _tile(
        title: loc.siteSettingsFullscreen,
        hintTitle: loc.siteSettingsFullscreenHintTitle,
        hint: loc.siteSettingsFullscreenHint,
        subtitle: loc.siteSettingsFullscreenSubtitle,
        value: _values.fullscreenMode,
        onChanged: (value) => _update(_values.copyWith(fullscreenMode: value)),
      );

  /// Either tabs or kiosk (TAB-013): turning tabs on turns Kiosk mode off,
  /// and Kiosk mode on shows tabs off without forgetting the stored choice.
  Widget _tabs(AppLocalizations loc) => _tile(
        title: loc.siteSettingsTabs,
        hint: loc.siteSettingsTabsHint,
        value: _values.effectiveTabsEnabled,
        onChanged: (value) => _update(value
            ? _values.copyWith(tabsEnabled: true, kioskMode: false)
            : _values.copyWith(tabsEnabled: false)),
      );

  Widget _htmlCaching(AppLocalizations loc) => _tile(
        title: loc.siteSettingsHtmlCaching,
        hintTitle: loc.siteSettingsHtmlCachingHintTitle,
        hint: loc.siteSettingsHtmlCachingHint,
        value: _values.htmlCachingEnabled,
        onChanged: (value) =>
            _update(_values.copyWith(htmlCachingEnabled: value)),
      );

  // --- Link handling -------------------------------------------------------

  bool get _tabsAvailable =>
      widget.tabsAvailable ??
      ExperimentalFeaturesService.instance
          .isEnabled(ExperimentalFeature.siteTabs);

  /// With tabs, the switch also decides which container a link's tab runs in
  /// (LIR-034), so the hint says so where that applies.
  Widget _routeOutboundLinks(AppLocalizations loc) => _tile(
        title: loc.siteSettingsRouteOutboundLinks,
        hint: _tabsAvailable && _values.effectiveTabsEnabled
            ? '${loc.siteSettingsRouteOutboundLinksHint}\n\n'
                '${loc.siteSettingsRouteOutboundLinksTabsHint}'
            : loc.siteSettingsRouteOutboundLinksHint,
        subtitle: widget.containersActive
            ? null
            : loc.siteSettingsRouteOutboundLinksNeedsContainers,
        value: _values.routeOutboundLinks,
        onChanged: widget.containersActive
            ? (value) => _update(_values.copyWith(routeOutboundLinks: value))
            : null,
      );

  Widget _outboundPreferences(AppLocalizations loc) {
    final count = _values.outboundPreferences.length;
    return ListTile(
      title: Text(loc.outboundPreferencesTitle),
      subtitle: Text(count == 0
          ? loc.outboundPreferencesGlobalOnly
          : loc.outboundPreferencesCount(count)),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () => Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => OutboundPreferencesScreen(
            preferences: _values.outboundPreferences,
            targets: widget.routingTargets,
            onChanged: (next) =>
                _update(_values.copyWith(outboundPreferences: next)),
          ),
        ),
      ),
    );
  }

  /// Where links leaving the site go, as a dropdown like the other
  /// multiple-choice settings. Routing to the user's own sites is an option of
  /// opening them in the app, so its rows sit indented under this one and
  /// only while that is the choice.
  Widget _externalLinks(AppLocalizations loc) {
    final mode = _values.externalLinkMode;
    final labels = {
      ExternalLinkMode.inApp: loc.siteSettingsExternalLinksInApp,
      ExternalLinkMode.browser: loc.siteSettingsExternalLinksBrowser,
      ExternalLinkMode.block: loc.siteSettingsExternalLinksBlock,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Row(
            children: [
              Flexible(child: Text(loc.siteSettingsExternalLinks)),
              HintButton(
                title: loc.siteSettingsExternalLinks,
                description: loc.siteSettingsExternalLinksHint,
              ),
            ],
          ),
          // Capped so a long label (Greek runs to 32 characters) cannot
          // squeeze the title; the open menu is wider and shows it whole.
          trailing: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: DropdownButton<ExternalLinkMode>(
              value: mode,
              isExpanded: true,
              menuWidth: 280,
              onChanged: (value) {
                if (value != null) {
                  _update(_values.copyWith(externalLinkMode: value));
                }
              },
              selectedItemBuilder: (context) => [
                for (final m in ExternalLinkMode.values)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(
                      labels[m]!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              items: [
                for (final m in ExternalLinkMode.values)
                  DropdownMenuItem(value: m, child: Text(labels[m]!)),
              ],
            ),
          ),
        ),
        if (mode == ExternalLinkMode.inApp)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 24),
            child: Column(
              children: [
                _routeOutboundLinks(loc),
                if (_values.routeOutboundLinks) _outboundPreferences(loc),
              ],
            ),
          ),
      ],
    );
  }

  // --- Search (LIR-028, BEHAV-005) ------------------------------------------

  /// The user's other sites that search the web, which a search from this
  /// site may use.
  List<WebViewModel> get _webSearchSites => [
        for (final m in widget.routingTargets)
          if (m.searchCapability?.kind == SearchKind.web) m,
      ];

  /// Two search sites can share a name, never an id (LIR-029).
  Widget _idLine(WebViewModel site) => SiteIdLine(
        siteId: site.siteId,
        colorIndex: widget.containersActive
            ? site.containerColor ??
                ContainerColorEngine.fallback(
                    site.siteId, kContainerPaletteSize)
            : null,
      );

  String? _nameOf(String? siteId) => siteId == null
      ? null
      : widget.routingTargets
          .where((m) => m.siteId == siteId)
          .firstOrNull
          ?.getDisplayName();

  Widget _titleWithHint(String title, String hint) => Row(
        children: [
          Flexible(child: Text(title)),
          HintButton(title: title, description: hint),
        ],
      );

  /// What the site searches with without an address of its own: what its
  /// host is known for, else what its pages declared.
  SearchCapability? get _knownSearch => widget.initUrl == null
      ? null
      : WebSearchEngine.capabilityOf(
          initUrl: widget.initUrl!,
          discoveredAddress: widget.discoveredSearchAddress,
          discoveredWeb: widget.discoveredSearchesWeb,
        );

  Widget _searchAddressRow(AppLocalizations loc) {
    final effective = _values.searchAddress ?? _knownSearch?.template;
    return ListTile(
      title: _titleWithHint(loc.webSearchTemplateLabel, loc.webSearchAddressHint),
      subtitle: Text(effective ?? loc.siteSettingsNotConfigured),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () => _editSearchAddress(effective),
    );
  }

  Future<void> _editSearchAddress(String? current) async {
    final known = _knownSearch;
    final knownWeb = known?.kind == SearchKind.web;
    final result = await showDialog<({String? address, bool web})>(
      context: context,
      builder: (ctx) => _SearchAddressDialog(
        initial: current ?? '',
        searchesWeb:
            _values.searchAddress != null ? _values.searchesWeb : knownWeb,
        canReset: _values.searchAddress != null,
      ),
    );
    if (result == null) return;
    // Saving the known address as it is keeps following the known one.
    final isKnown = result.address != null &&
        result.address == known?.template &&
        result.web == knownWeb;
    final address = isKnown ? null : result.address;
    _update(_values.copyWith(
      searchAddress: address,
      searchesWeb: address == null ? false : result.web,
    ));
  }

  Widget _searchDefaultRow(AppLocalizations loc) {
    final name = _nameOf(_values.searchDefault);
    return ListTile(
      title:
          _titleWithHint(loc.webSearchFromSiteTitle, loc.webSearchFromSiteHint),
      subtitle: Text(name ?? loc.webSearchUseAppDefault),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () async {
        const appDefault = '';
        final picked = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(loc.webSearchFromSiteTitle),
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            content: SizedBox(
              width: double.maxFinite,
              child: RadioGroup<String>(
                groupValue: _values.searchDefault ?? appDefault,
                onChanged: (v) => Navigator.pop(ctx, v),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    RadioListTile<String>(
                      value: appDefault,
                      title: Text(loc.webSearchUseAppDefault),
                    ),
                    for (final m in _webSearchSites)
                      RadioListTile<String>(
                        value: m.siteId,
                        title: Text(m.getDisplayName()),
                        subtitle: _idLine(m),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        if (picked == null) return;
        _update(_values.copyWith(
          searchDefault: picked == appDefault ? null : picked,
        ));
      },
    );
  }

  Widget _searchOfferedRow(AppLocalizations loc) {
    final names = [
      for (final id in _values.searchSites) ?_nameOf(id),
    ];
    // Data, not copy: site names joined with punctuation (LOC-002).
    final summary = names.join(', ');
    return ListTile(
      title: _titleWithHint(loc.webSearchOfferedTitle, loc.webSearchOfferedHint),
      subtitle: Text(names.isEmpty ? loc.webSearchOfferedAll : summary),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () async {
        final picked = await showDialog<List<String>>(
          context: context,
          builder: (ctx) => _SearchSitesDialog(
            sites: _webSearchSites,
            selected: _values.searchSites,
            idLine: _idLine,
          ),
        );
        if (picked == null) return;
        final def = _values.searchDefault;
        _update(_values.copyWith(
          searchSites: picked,
          // A default the list no longer offers falls back to the app's.
          searchDefault:
              def != null && picked.isNotEmpty && !picked.contains(def)
                  ? null
                  : def,
        ));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.behaviourTitle)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              widget.host,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _groupHeader(loc.behaviourGroupOpening),
          _alwaysOpenHome(loc),
          _kioskMode(loc),
          _fullscreen(loc),
          if (_tabsAvailable) _tabs(loc),
          _htmlCaching(loc),
          _groupHeader(loc.linkHandlingScreenTitle),
          _externalLinks(loc),
          if (widget.domainClaims != null) widget.domainClaims!,
          if (_tabsAvailable) ...[
            _groupHeader(loc.webSearchGroup),
            _searchAddressRow(loc),
            _searchDefaultRow(loc),
            _searchOfferedRow(loc),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Edits a site's search address. Pops `(address: null)` to go back to the
/// address the site's host is known for.
class _SearchAddressDialog extends StatefulWidget {
  const _SearchAddressDialog({
    required this.initial,
    required this.searchesWeb,
    required this.canReset,
  });

  final String initial;
  final bool searchesWeb;
  final bool canReset;

  @override
  State<_SearchAddressDialog> createState() => _SearchAddressDialogState();
}

class _SearchAddressDialogState extends State<_SearchAddressDialog> {
  late final TextEditingController _address =
      TextEditingController(text: widget.initial);
  late bool _web = widget.searchesWeb;

  @override
  void initState() {
    super.initState();
    _address.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final text = _address.text.trim();
    final valid = WebSearchEngine.isValidTemplate(text);
    return AlertDialog(
      title: Text(loc.webSearchTemplateLabel),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _address,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: loc.webSearchTemplateLabel,
              helperText: loc.webSearchTemplateHelper,
              helperMaxLines: 3,
              errorText:
                  text.isEmpty || valid ? null : loc.webSearchTemplateInvalid,
              errorMaxLines: 3,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(loc.webSearchSearchesWeb),
            value: _web,
            onChanged: (v) => setState(() => _web = v),
          ),
        ],
      ),
      actions: [
        if (widget.canReset)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, (address: null, web: false)),
            child: Text(loc.webSearchAddressReset),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(loc.commonCancel),
        ),
        TextButton(
          onPressed: valid
              ? () => Navigator.pop(context, (address: text, web: _web))
              : null,
          child: Text(loc.commonSave),
        ),
      ],
    );
  }
}

/// Picks the search sites a search from a site offers. None picked offers
/// every one.
class _SearchSitesDialog extends StatefulWidget {
  const _SearchSitesDialog({
    required this.sites,
    required this.selected,
    required this.idLine,
  });

  final List<WebViewModel> sites;
  final List<String> selected;
  final Widget Function(WebViewModel site) idLine;

  @override
  State<_SearchSitesDialog> createState() => _SearchSitesDialogState();
}

class _SearchSitesDialogState extends State<_SearchSitesDialog> {
  late final Set<String> _picked = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(loc.webSearchOfferedTitle),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.sites.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(loc.webSearchNoWebSites),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final m in widget.sites)
                    CheckboxListTile(
                      value: _picked.contains(m.siteId),
                      title: Text(m.getDisplayName()),
                      subtitle: widget.idLine(m),
                      onChanged: (v) => setState(() {
                        if (v ?? false) {
                          _picked.add(m.siteId);
                        } else {
                          _picked.remove(m.siteId);
                        }
                      }),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(loc.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, [
            for (final m in widget.sites)
              if (_picked.contains(m.siteId)) m.siteId,
          ]),
          child: Text(loc.commonSave),
        ),
      ],
    );
  }
}
