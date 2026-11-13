import 'package:flutter/material.dart';
import 'package:webspace/settings/site_ids.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/link_handling_settings.dart';
import 'package:webspace/services/html_source.dart';
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/services/popup_webview.dart';
import 'package:webspace/services/shortcut_service.dart';
import 'package:webspace/services/site_overrides.dart';
import 'package:webspace/services/web_search_engine.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/widgets/settings_rows.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/settings/setting_labels.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/web_view_model_search.dart';
import 'package:webspace/widgets/container_mark.dart' show SiteIdLine;
import 'package:webspace/widgets/dirty_guard.dart' show ValueList;
import 'package:webspace/widgets/search_site_picker.dart';
import 'package:webspace/widgets/setting_tile.dart';

/// What a site stores of how the app hosts it, the whole of what the
/// behaviour screen edits. A record, so the settings screen's dirty snapshot
/// compares every field of it and a field added here cannot be left out of
/// that comparison, which is how unsaved edits got dropped (BUG-006).
typedef BehaviourChoices = ({
  bool alwaysOpenHome,
  bool kioskMode,
  bool fullscreenMode,
  Scoped<bool> tabsEnabled,
  bool htmlCachingEnabled,
  Scoped<ExternalLinkMode> externalLinkMode,
  bool routeOutboundLinks,
  ValueList<OutboundPreference> outboundPreferences,
  Scoped<bool> signInPopups,
  /// LIR-028: how to search this site, and what a search from it offers.
  String? searchAddress,
  bool searchesWeb,
  ValueList<SiteId> searchSites,
  Scoped<SiteId> searchDefault,
});

/// Where a site's [BehaviourChoices] are stored: the one mapping between the
/// record and the model's fields.
extension SiteBehaviourChoices on WebViewModel {
  BehaviourChoices get behaviourChoices => (
        alwaysOpenHome: alwaysOpenHome,
        kioskMode: kioskMode,
        fullscreenMode: fullscreenMode,
        tabsEnabled: Scoped.fromStored(tabsEnabled),
        htmlCachingEnabled: htmlCachingEnabled,
        externalLinkMode: Scoped.fromStored(externalLinkMode),
        routeOutboundLinks: routeOutboundLinks,
        outboundPreferences: ValueList(outboundPreferences),
        signInPopups: Scoped.fromStored(signInPopups),
        searchAddress: searchAddress,
        searchesWeb: searchesWeb,
        searchSites: ValueList(searchSites),
        searchDefault: Scoped.fromStored(searchDefault),
      );

  /// The pattern names every field, so one added to [BehaviourChoices] does
  /// not compile until it is stored here.
  set behaviourChoices(BehaviourChoices c) {
    final (
      :alwaysOpenHome,
      :kioskMode,
      :fullscreenMode,
      :tabsEnabled,
      :htmlCachingEnabled,
      :externalLinkMode,
      :routeOutboundLinks,
      :outboundPreferences,
      :signInPopups,
      :searchAddress,
      :searchesWeb,
      :searchSites,
      :searchDefault,
    ) = c;
    this.alwaysOpenHome = alwaysOpenHome;
    this.kioskMode = kioskMode;
    this.fullscreenMode = fullscreenMode;
    this.tabsEnabled = tabsEnabled.stored;
    this.htmlCachingEnabled = htmlCachingEnabled;
    this.externalLinkMode = externalLinkMode.stored;
    this.routeOutboundLinks = routeOutboundLinks;
    this.outboundPreferences = [...outboundPreferences.items];
    this.signInPopups = signInPopups.stored;
    this.searchAddress = searchAddress;
    this.searchesWeb = searchesWeb;
    this.searchSites = [...searchSites.items];
    this.searchDefault = searchDefault.stored;
  }
}

extension BehaviourChoicesEdit on BehaviourChoices {
  /// These choices with the given ones replaced. A nullable field comes as a
  /// one-element record, so clearing it (`searchAddress: (null,)`) is told
  /// apart from leaving it out.
  BehaviourChoices copyWith({
    bool? alwaysOpenHome,
    bool? kioskMode,
    bool? fullscreenMode,
    Scoped<bool>? tabsEnabled,
    bool? htmlCachingEnabled,
    Scoped<ExternalLinkMode>? externalLinkMode,
    bool? routeOutboundLinks,
    ValueList<OutboundPreference>? outboundPreferences,
    Scoped<bool>? signInPopups,
    (String?,)? searchAddress,
    bool? searchesWeb,
    ValueList<SiteId>? searchSites,
    Scoped<SiteId>? searchDefault,
  }) =>
      (
        alwaysOpenHome: alwaysOpenHome ?? this.alwaysOpenHome,
        kioskMode: kioskMode ?? this.kioskMode,
        fullscreenMode: fullscreenMode ?? this.fullscreenMode,
        tabsEnabled: tabsEnabled ?? this.tabsEnabled,
        htmlCachingEnabled: htmlCachingEnabled ?? this.htmlCachingEnabled,
        externalLinkMode: externalLinkMode ?? this.externalLinkMode,
        routeOutboundLinks: routeOutboundLinks ?? this.routeOutboundLinks,
        outboundPreferences: outboundPreferences ?? this.outboundPreferences,
        signInPopups: signInPopups ?? this.signInPopups,
        searchAddress:
            searchAddress == null ? this.searchAddress : searchAddress.$1,
        searchesWeb: searchesWeb ?? this.searchesWeb,
        searchSites: searchSites ?? this.searchSites,
        searchDefault: searchDefault ?? this.searchDefault,
      );
}

/// The behaviour screen's input: the site's [choices] and what they resolve
/// to where it runs.
class SiteBehaviourValues {
  const SiteBehaviourValues({
    required this.archived,
    required this.htmlSource,
    required this.choices,
  });

  /// Not edited here: an archive-tier site runs with the archive's posture
  /// for the settings ARCH-006 folds.
  final bool archived;

  /// Where the site's HTML comes from (`htmlSourceFor`), which decides
  /// whether HTML caching can be in effect at all.
  final HtmlSource htmlSource;
  final BehaviourChoices choices;

  SiteBehaviourValues withChoices(BehaviourChoices next) => SiteBehaviourValues(
      archived: archived, htmlSource: htmlSource, choices: next);

  bool effectiveAlwaysOpenHome({required bool incognito}) =>
      resolveAlwaysOpenHome(
          alwaysOpenHome: choices.alwaysOpenHome, incognito: incognito);

  bool get effectiveKioskMode => resolveKiosk(
      stored: choices.kioskMode, shortcutsOffered: ShortcutService.offered);

  bool get effectiveTabsEnabled => resolveTabs(
      tabs: choices.tabsEnabled.resolve(AppPref.tabsEnabled.value),
      kiosk: effectiveKioskMode);

  bool get effectiveRouteOutboundLinks => resolveRouteOutboundLinks(
      route: choices.routeOutboundLinks,
      appRoute: AppPref.routeOutboundLinks.value,
      followsAppLinks: choices.externalLinkMode is FollowApp,
      mode: effectiveExternalLinkMode);

  bool get effectiveHtmlCaching =>
      htmlCachingInEffect(htmlSource,
          stored: choices.htmlCachingEnabled, engineCan: engineLoadsCacheFirst);

  ExternalLinkMode get effectiveExternalLinkMode =>
      ArchiveFold.externalLinks(
          choices.externalLinkMode.resolve(ExternalLinkMode.appDefault),
          archived: archived);
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
    required this.containersActive,
    this.routingTargets = const [],
    this.initUrl,
    this.discoveredSearchAddress,
    this.discoveredSearchesWeb = false,
    this.listedSearchAddress,
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

  /// The site's home, which decides the search address it is known for.
  final String? initUrl;

  /// The search address the site's pages declared (LIR-035), shown when it
  /// has no address of its own and its host is not a known one.
  final String? discoveredSearchAddress;
  final bool discoveredSearchesWeb;

  /// The address the downloaded site search list names for it (LIR-036).
  final String? listedSearchAddress;

  @override
  State<SiteBehaviourScreen> createState() => _SiteBehaviourScreenState();
}

class _SiteBehaviourScreenState extends State<SiteBehaviourScreen>
    with RebuildOnAppPref {
  late SiteBehaviourValues _values = widget.values;

  BehaviourChoices get _choices => _values.choices;

  void _update(BehaviourChoices next) {
    setState(() => _values = _values.withChoices(next));
    widget.onChanged(_values);
  }

  // Where no kiosk runs (KIOSK-006) the stored one is left for a device
  // that runs it.
  void _setTabs(Scoped<bool> choice) => _update(_choices.copyWith(
        tabsEnabled: choice,
        kioskMode: choice.resolve(AppPref.tabsEnabled.value) &&
                _values.effectiveKioskMode
            ? false
            : _choices.kioskMode,
      ));

  // --- Link handling -------------------------------------------------------

  /// With tabs, this switch also decides which container a link's tab runs in
  /// (LIR-034), so the hint says so where that applies.
  Widget _routeOutboundLinks(AppLocalizations loc) => SettingTile(
        title: loc.siteSettingsRouteOutboundLinks,
        hint: _values.effectiveTabsEnabled
            ? Localized.joined([
                loc.siteSettingsRouteOutboundLinksHint,
                loc.siteSettingsRouteOutboundLinksTabsHint,
              ], by: Joined.paragraphs)
            : loc.siteSettingsRouteOutboundLinksHint,
        lock: widget.containersActive
            ? null
            : Lock.because(loc.siteSettingsRouteOutboundLinksNeedsContainers),
        control: Toggle(value: _choices.routeOutboundLinks,
            onChanged: (value) =>
                _update(_choices.copyWith(routeOutboundLinks: value))),
      );

  Widget _outboundPreferences(AppLocalizations loc) {
    final count = _choices.outboundPreferences.items.length;
    return SettingTile(
      title: loc.outboundPreferencesTitle,
      hint: null,
      subtitle: count == 0
          ? loc.outboundPreferencesGlobalOnly
          : loc.outboundPreferencesCount(count),
      control: Opens(() => Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => OutboundPreferencesScreen(
                preferences: _choices.outboundPreferences.items,
                targets: widget.routingTargets,
                onChanged: (next) =>
                    _update(_choices.copyWith(outboundPreferences: ValueList(next))),
              ),
            ),
          )),
    );
  }

  /// Where links leaving the site go, as a dropdown like the other
  /// multiple-choice settings. Routing to the user's own sites is an option of
  /// opening them in the app, so its rows sit indented under this one and
  /// only while that is the choice.
  Widget _externalLinks(AppLocalizations loc) {
    final mode = _values.effectiveExternalLinkMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChoiceTile<Scoped<ExternalLinkMode>>(
          title: loc.siteSettingsExternalLinks,
          hint: loc.siteSettingsExternalLinksHint,
          subtitle: _choices.externalLinkMode is FollowApp
              ? mode.label(loc)
              : null,
          values: [
            const FollowApp(),
            for (final m in ExternalLinkMode.values) Own(m),
          ],
          label: (choice) => switch (choice) {
            FollowApp() => loc.webSearchUseAppDefault,
            Own(:final value) => value.label(loc),
          },
          value: _choices.externalLinkMode is Own &&
                  mode != _choices.externalLinkMode.stored
              ? Own(mode)
              : _choices.externalLinkMode,
          offered: (choice) => !_values.archived ||
              choice != const Own(ExternalLinkMode.browser),
          onChanged: (choice) => _update(_choices.copyWith(externalLinkMode: choice)),
        ),
        if (_choices.externalLinkMode is Own && mode == ExternalLinkMode.inApp)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 24),
            child: Column(
              children: [
                _routeOutboundLinks(loc),
                if (_values.effectiveRouteOutboundLinks) _outboundPreferences(loc),
              ],
            ),
          ),
      ],
    );
  }

  /// A sign-in window the user's tap opened shows as a real popup
  /// (NESTED-014).
  Widget _signInPopups(AppLocalizations loc) => SettingTile(
        title: loc.siteSettingsSignInPopups,
        hint: loc.siteSettingsSignInPopupsHint,
        control: ScopedToggle(
          value: PopupKind.signInOpens(choice: _choices.signInPopups),
          choice: _choices.signInPopups,
          source: FollowSource.app,
          onChoice: (choice) =>
              _update(_choices.copyWith(signInPopups: choice)),
        ),
      );

  // --- Search (LIR-028, BEHAV-006) ------------------------------------------

  /// The user's other sites that search the web, which a search from this
  /// site may use.
  List<WebViewModel> get _webSearchSites => [
        for (final m in widget.routingTargets)
          if (m.searchCapability?.kind == SearchKind.web) m,
      ];

  /// [site]'s container colour, none on the legacy engine (TAB-018).
  int? _colorIndexOf(WebViewModel site) =>
      widget.containersActive ? site.drawnContainerColor : null;

  /// Two search sites can share a name, never an id (LIR-029).
  Widget _idLine(WebViewModel site) =>
      SiteIdLine(siteId: site.siteId, colorIndex: _colorIndexOf(site));

  String? _nameOf(SiteId? siteId) {
    final site = siteId == null
        ? null
        : widget.routingTargets.where((m) => m.siteId == siteId).firstOrNull;
    if (site == null) return null;
    return searchSiteSummaryName(site.getDisplayName(), siteId: site.siteId,
        names: _webSearchSites.map((m) => m.getDisplayName()));
  }

  /// What the site searches with without an address of its own: what its
  /// host is known for, else what its pages declared, else what the site
  /// search list names.
  SearchCapability? get _knownSearch => widget.initUrl == null
      ? null
      : WebSearchEngine.capabilityOf(
          initUrl: widget.initUrl!,
          discoveredAddress: widget.discoveredSearchAddress,
          discoveredWeb: widget.discoveredSearchesWeb,
          listedAddress: widget.listedSearchAddress,
        );

  Widget _searchAddressRow(AppLocalizations loc) {
    final effective = _choices.searchAddress ?? _knownSearch?.template;
    return SettingTile(
      title: loc.webSearchTemplateLabel,
      hint: loc.webSearchAddressHint,
      subtitle: switch (effective) {
        final address? => Localized.verbatim(address),
        null => loc.siteSettingsNotConfigured,
      },
      control: Opens(() => _editSearchAddress(effective)),
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
            _choices.searchAddress != null ? _choices.searchesWeb : knownWeb,
        canReset: _choices.searchAddress != null,
      ),
    );
    if (result == null) return;
    // Saving the known address as it is keeps following the known one.
    final isKnown = result.address != null &&
        result.address == known?.template &&
        result.web == knownWeb;
    final address = isKnown ? null : result.address;
    _update(_choices.copyWith(
      searchAddress: (address,),
      searchesWeb: address == null ? false : result.web,
    ));
  }

  Widget _searchDefaultRow(AppLocalizations loc) {
    final name = _nameOf(_choices.searchDefault.stored);
    return SettingTile(
      title: loc.webSearchFromSiteTitle,
      hint: loc.webSearchFromSiteHint,
      subtitle: switch (name) {
        final name? => Localized.verbatim(name),
        null => loc.webSearchUseAppDefault,
      },
      control: Opens(() async {
        final picked = await showDialog<SearchSitePick>(
          context: context,
          builder: (ctx) => SearchSiteChoiceDialog(
            title: loc.webSearchFromSiteTitle,
            noneLabel: loc.webSearchUseAppDefault,
            selected: _choices.searchDefault.stored,
            sites: [
              for (final m in _webSearchSites)
                (
                  siteId: m.siteId,
                  name: m.getDisplayName(),
                  containerColor: _colorIndexOf(m),
                ),
            ],
          ),
        );
        if (picked == null) return;
        _update(_choices.copyWith(
          searchDefault: Scoped.fromStored(picked.site),
        ));
      }),
    );
  }

  Widget _searchOfferedRow(AppLocalizations loc) {
    final names = [
      for (final id in _choices.searchSites.items) ?_nameOf(id),
    ];
    // Data, not copy: site names joined with punctuation (L10N-002).
    final summary = Localized.verbatim(names.join(', '));
    return SettingTile(
      title: loc.webSearchOfferedTitle,
      hint: loc.webSearchOfferedHint,
      subtitle: names.isEmpty ? loc.webSearchOfferedAll : summary,
      control: Opens(() async {
        final picked = await showDialog<List<SiteId>>(
          context: context,
          builder: (ctx) => _SearchSitesDialog(
            sites: _webSearchSites,
            selected: _choices.searchSites.items,
            idLine: _idLine,
          ),
        );
        if (picked == null) return;
        _update(_choices.copyWith(
          searchSites: ValueList(picked),
          // A default the list no longer offers falls back to the app's.
          searchDefault: switch (_choices.searchDefault) {
            Own(:final value)
                when picked.isNotEmpty && !picked.contains(value) =>
              const FollowApp(),
            final kept => kept,
          },
        ));
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.behaviourTitle)),
      body: ListView(
        children: [
          SettingsNote.host(widget.host),
          SettingsSection(loc.behaviourGroupOpening),
          SettingTile(
            title: loc.siteSettingsAlwaysOpenHome,
            hint: loc.siteSettingsAlwaysOpenHomeHint,
            lock: widget.incognito
                ? Lock.because(loc.siteSettingsAlwaysOpenHomeForced)
                : null,
            control: Toggle(value: _values.effectiveAlwaysOpenHome(incognito: widget.incognito),
                onChanged: (value) => _update(_choices.copyWith(alwaysOpenHome: value))),
          ),
          if (ShortcutService.offered)
            SettingTile(
              title: loc.siteSettingsKioskMode,
              hint: loc.siteSettingsKioskModeHint,
              control: Toggle(value: _choices.kioskMode,
                  onChanged: (value) => _update(_choices.copyWith(kioskMode: value))),
            ),
          SettingTile(
            title: loc.siteSettingsFullscreen,
            hintTitle: loc.siteSettingsFullscreenHintTitle,
            hint: loc.siteSettingsFullscreenHint,
            subtitle: loc.siteSettingsFullscreenSubtitle,
            control: Toggle(value: _choices.fullscreenMode,
                onChanged: (value) => _update(_choices.copyWith(fullscreenMode: value))),
          ),
          // Either tabs or kiosk (TAB-013): turning tabs on turns Kiosk mode
          // off, and Kiosk mode on shows tabs off without forgetting the
          // stored choice.
          SettingTile(
            title: loc.siteSettingsTabs,
            hint: loc.siteSettingsTabsHint,
            control: ScopedToggle(
              value: _values.effectiveTabsEnabled,
              choice: _choices.tabsEnabled,
              source: FollowSource.app,
              onChoice: _setTabs,
            ),
          ),
          // WPE has no per-load cache policy, so there is nothing to switch.
          if (engineLoadsCacheFirst)
            SettingTile(
              title: loc.siteSettingsHtmlCaching,
              hintTitle: loc.siteSettingsHtmlCachingHintTitle,
              hint: loc.siteSettingsHtmlCachingHint,
              lock: _values.archived ? const ArchiveLock() : null,
              control: Toggle(value: _values.effectiveHtmlCaching,
                  onChanged: (value) => _update(_choices.copyWith(htmlCachingEnabled: value))),
            ),
          SettingsSection(loc.linkHandlingScreenTitle),
          _externalLinks(loc),
          _signInPopups(loc),
          if (widget.domainClaims != null) widget.domainClaims!,
          SettingsSection(loc.webSearchGroup),
          _searchAddressRow(loc),
          _searchDefaultRow(loc),
          _searchOfferedRow(loc),
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
  final List<SiteId> selected;
  final Widget Function(WebViewModel site) idLine;

  @override
  State<_SearchSitesDialog> createState() => _SearchSitesDialogState();
}

class _SearchSitesDialogState extends State<_SearchSitesDialog> {
  late final Set<SiteId> _picked = {...widget.selected};

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
