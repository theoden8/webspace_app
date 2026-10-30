import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/controllers/desktop_tray.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/home_shortcuts_settings.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/back_gesture_engine.dart';
import 'package:webspace/services/desktop_window.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/setting_labels.dart';
import 'package:webspace/settings/tab_strip_edge.dart';
import 'package:webspace/widgets/datasets.dart';
import 'package:webspace/widgets/dataset_tile.dart';
import 'package:webspace/widgets/icon_segments.dart';
import 'package:webspace/widgets/search_site_picker.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/settings_rows.dart';

/// How the site tab strip is reached. The floating button is the on-demand
/// presentation of the strip, so the three are one choice, not two toggles.
enum TabStrip {
  hidden,
  pinned,
  button;

  static TabStrip get current => AppPref.tabBarButton.value
      ? button
      : (AppPref.showTabStrip.value ? pinned : hidden);
}

extension on TabStrip {
  ButtonSegment<TabStrip> segment(AppLocalizations loc) => ButtonSegment(
        value: this,
        icon: Icon(switch (this) {
          TabStrip.hidden => Icons.visibility_off,
          TabStrip.pinned => Icons.visibility,
          TabStrip.button => Icons.smart_button,
        }),
        tooltip: switch (this) {
          TabStrip.hidden => loc.appSettingsFullscreenTabStripHidden,
          TabStrip.pinned => loc.appSettingsFullscreenTabStripAlways,
          TabStrip.button => loc.appSettingsFullscreenTabStripButton,
        },
      );
}

extension on TabStripEdge {
  ButtonSegment<TabStripEdge> segment(AppLocalizations loc) => ButtonSegment(
        value: this,
        icon: Icon(switch (this) {
          TabStripEdge.top => Icons.vertical_align_top,
          TabStripEdge.bottom => Icons.vertical_align_bottom,
        }),
        tooltip: switch (this) {
          TabStripEdge.top => loc.appSettingsTabStripPositionTop,
          TabStripEdge.bottom => loc.appSettingsTabStripPositionBottom,
        },
      );
}

/// Apple has no back gesture the app can act on (NAV-009), so the Back opens
/// menu setting is absent there rather than present and inert.
bool backOpensMenuOffered() =>
    backAtHistoryStartConfigurable(isIOS: hostIsIOS, isMacOS: hostIsMacOS);

/// How the app hosts sites: the tab strip, full screen, the back gesture and
/// where shared links and searches go.
class AppBehaviourScreen extends StatefulWidget {
  const AppBehaviourScreen({
    super.key,
    required this.onOpenLinkHandlingSettings,
    required this.homeShortcuts,
    this.webSearchSites = const [],
  });

  /// LIR-008: entry into the routing overview screen.
  final VoidCallback onOpenLinkHandlingSettings;

  /// HS-017: the pinned home screen tiles, null where no platform API lists
  /// them (everywhere but Android), which leaves the row out.
  final HomeShortcutsHost? homeShortcuts;

  /// The user's web search sites outside every archive (LIR-029), each with
  /// its container's colour, null on the legacy engine.
  final List<PickableSearchSite> webSearchSites;

  @override
  State<AppBehaviourScreen> createState() => _AppBehaviourScreenState();
}

class _AppBehaviourScreenState extends State<AppBehaviourScreen>
    with SettingsOpenGuard, RebuildOnAppPref {
  void _setTabStrip(TabStrip mode) {
    unawaited(AppPref.showTabStrip.set(mode == TabStrip.pinned));
    unawaited(AppPref.tabBarButton.set(mode == TabStrip.button));
    // "Keep in full screen" only applies to a pinned strip. Leaving it set
    // in button mode would pin the strip in full screen and hide the button
    // there; clear it whenever we leave the pinned mode.
    if (mode != TabStrip.pinned) unawaited(AppPref.tabStripInFullscreen.set(false));
  }

  /// A title with its control at the end of the row.
  Widget _row(Widget title, {required Widget trailing}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(children: [Expanded(child: title), trailing]),
      );

  /// Whether the tab strip can appear at all (pinned out of fullscreen, pinned
  /// in fullscreen, or revealed by the tab-bar button), so its position and
  /// width limit are meaningful.
  bool get _tabStripCanShow =>
      AppPref.showTabStrip.value ||
      AppPref.tabStripInFullscreen.value ||
      AppPref.tabBarButton.value;

  Localized? get _webSearchDefaultName {
    final site = widget.webSearchSites
        .where((s) => s.siteId == AppPref.webSearchDefaultSite.value)
        .firstOrNull;
    if (site == null) return null;
    return Localized.verbatim(searchSiteSummaryName(site.name,
        siteId: site.siteId, names: widget.webSearchSites.map((s) => s.name)));
  }

  /// LIR-029: which web search site Web search starts with. Only sites outside
  /// every archive are offered, so the pref never names an archived site.
  Future<void> _pickWebSearchDefault() async {
    final loc = AppLocalizations.of(context);
    final picked = await showDialog<SearchSitePick>(
      context: context,
      builder: (ctx) => SearchSiteChoiceDialog(
        title: loc.webSearchDefaultTitle,
        sites: widget.webSearchSites,
        selected: SiteId.parse(AppPref.webSearchDefaultSite.value),
        emptyText: loc.webSearchNoWebSites,
        cancelLabel: loc.commonCancel,
      ),
    );
    if (picked case (site: final id?)) {
      await AppPref.webSearchDefaultSite.set(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final backOpensMenuHint = hostIsAndroid
        ? loc.twoSentences(
            loc.appSettingsBackOpensMenuHint,
            loc.appSettingsBackOpensMenuHintExit,
          )
        : loc.appSettingsBackOpensMenuHint;
    final keepRunningHint = [
      loc.appSettingsKeepRunningWhenClosedHint,
      hostIsMacOS
          ? loc.appSettingsKeepRunningWhenClosedHintMac
          : loc.appSettingsKeepRunningWhenClosedHintLinux,
      if (DesktopTray.offered) loc.appSettingsKeepRunningWhenClosedHintTray,
      if (DesktopTray.offered && hostIsLinux)
        loc.appSettingsKeepRunningWhenClosedHintTrayLinux,
    ].reduce(loc.twoSentences);
    return Scaffold(
      appBar: AppBar(title: Text(loc.appSettingsBehaviour)),
      body: ListView(
        children: [
          SettingsSection(loc.appSettingsGroupTabStrip),
          _row(
            HintedTitle(loc.appSettingsSiteTabStrip,
                hint: loc.appSettingsSiteTabStripSubtitle),
            trailing: IconSegments(
              segments: [for (final m in TabStrip.values) m.segment(loc)],
              selected: TabStrip.current,
              onChanged: _setTabStrip,
            ),
          ),
          // Pinned mode only: whether the pinned strip stays visible in full
          // screen. Button mode reveals the strip in full screen on its own;
          // hidden mode has nothing to keep.
          if (TabStrip.current == TabStrip.pinned)
            _row(
              Text(loc.appSettingsFullscreenTabStrip),
              trailing: IconSegments(
                segments: [TabStrip.hidden.segment(loc), TabStrip.pinned.segment(loc)],
                selected: AppPref.tabStripInFullscreen.value
                    ? TabStrip.pinned
                    : TabStrip.hidden,
                onChanged: (mode) =>
                    AppPref.tabStripInFullscreen.set(mode == TabStrip.pinned),
              ),
            ),
          _row(
            Text(loc.appSettingsTabStripPosition),
            trailing: IconSegments<TabStripEdge>(
              segments: [for (final e in TabStripEdge.values) e.segment(loc)],
              selected: TabStripEdge.current,
              onChanged: _tabStripCanShow
                  ? (edge) => AppPref.tabStripEdge.set(edge.name)
                  : null,
            ),
          ),
          PrefSlider(
            AppPref.tabMaxWidth,
            title: loc.appSettingsTabMaxWidth,
            hint: loc.appSettingsTabMaxWidthHint,
            min: 80,
            max: 320,
            step: 10,
            label: (width) => '$width px',
            enabled: _tabStripCanShow,
          ),
          SettingsSection(loc.appSettingsGroupOpening),
          SettingTile(
            title: loc.siteSettingsTabs,
            hint: loc.siteSettingsTabsHint,
            control: const PrefToggle(AppPref.tabsEnabled),
          ),
          ChoiceTile<ExternalLinkMode>(
            title: loc.siteSettingsExternalLinks,
            hint: null,
            values: ExternalLinkMode.values,
            label: (mode) => mode.label(loc),
            value: ExternalLinkMode.appDefault,
            onChanged: (mode) => AppPref.externalLinkMode.set(mode.name),
          ),
          if (ExternalLinkMode.appDefault == ExternalLinkMode.inApp)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 24),
              child: SettingTile(
                title: loc.siteSettingsRouteOutboundLinks,
                hint: loc.siteSettingsRouteOutboundLinksHint,
                control: const PrefToggle(AppPref.routeOutboundLinks),
              ),
            ),
          SettingTile(
            title: loc.siteSettingsSignInPopups,
            hint: loc.siteSettingsSignInPopupsHint,
            control: const PrefToggle(AppPref.signInPopups),
          ),
          SettingTile(
            title: loc.appSettingsFullscreenOnShortcut,
            hint: loc.appSettingsFullscreenOnShortcutHint,
            control: const PrefToggle(AppPref.fullscreenOnShortcut),
          ),
          if (backOpensMenuOffered())
            SettingTile(
              // The escalation to leaving the app is Android's alone
              // (NAV-009), so the sentence describing it stays off every
              // other platform.
              title: loc.appSettingsBackOpensMenu,
              hint: backOpensMenuHint,
              control: const PrefToggle(AppPref.backOpensMenu),
            ),
          if (DesktopWindow.offered)
            SettingTile(
              title: loc.appSettingsKeepRunningWhenClosed,
              hint: keepRunningHint,
              control: const PrefToggle(AppPref.keepRunningWhenClosed),
            ),
          if (widget.homeShortcuts case final shortcuts?)
            ValueListenableBuilder<List<HomeShortcut>>(
              valueListenable: shortcuts.homeShortcuts,
              // Nothing to manage until a tile is pinned, which a TV's
              // launcher never takes (HS-004).
              builder: (context, pinned, _) => pinned.isEmpty
                  ? const SizedBox.shrink()
                  : SettingTile(
                leading: const Icon(Icons.app_shortcut),
                title: loc.homeShortcutsTitle,
                hint: loc.homeShortcutsHint,
                subtitle: loc.homeShortcutsCount(pinned.length),
                control: Opens(() => guardedOpen(() => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => HomeShortcutsScreen(host: shortcuts),
                      ),
                    ))),
              ),
            ),
          SettingTile(
            leading: const Icon(Icons.share_outlined),
            title: loc.appSettingsLinkHandling,
            hint: null,
            subtitle: AppPref.linkHandlingEnabled.value
                ? loc.appSettingsLinkHandlingOn
                : loc.appSettingsLinkHandlingOff,
            // The opener pushes synchronously, so the route check in the
            // guard is what drops a second tap.
            control: Opens(() => guardedOpen(
                () async => widget.onOpenLinkHandlingSettings())),
          ),
          SettingsSection(loc.webSearchGroup),
          SettingTile(
            leading: const Icon(Icons.travel_explore),
            title: loc.webSearchDefaultTitle,
            hint: loc.webSearchDefaultHint,
            subtitle: _webSearchDefaultName ?? loc.appSettingsNotConfigured,
            control: Opens(() => guardedOpen(_pickWebSearchDefault)),
          ),
          DatasetTile(
            create: SiteSearchListDataset.new,
            icon: Icons.manage_search,
            title: loc.webSearchSiteListTitle,
            hint: loc.webSearchSiteListHint,
          ),
          SettingsSection(loc.topSitesGroup),
          DatasetTile(
            create: TopSitesDataset.new,
            icon: Icons.public,
            title: loc.topSitesTitle,
            hint: Localized.joined([
              loc.topSitesHint,
              loc.termAndMeaning(
                loc.topSitesKeepFilters,
                loc.topSitesKeepFiltersHint,
              ),
            ], by: Joined.paragraphs),
            below: (topSites, {required download}) => SwitchListTile(
              // Placed as the Firefox version row's switch is, under the
              // title column.
              contentPadding:
                  const EdgeInsetsDirectional.only(start: 72, end: 24),
              dense: true,
              visualDensity: VisualDensity.compact,
              title: Text(loc.topSitesKeepFilters,
                  style: const TextStyle(fontSize: 13)),
              value: topSites.keepFilters,
              onChanged: (value) => topSites.setKeepFilters(on: value),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
