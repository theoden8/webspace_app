import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/back_gesture_engine.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/widgets/datasets.dart';
import 'package:webspace/widgets/dataset_tile.dart';
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
  IconData get icon => switch (this) {
        TabStrip.hidden => Icons.visibility_off,
        TabStrip.pinned => Icons.visibility,
        TabStrip.button => Icons.smart_button,
      };

  String tooltip(AppLocalizations loc) => switch (this) {
        TabStrip.hidden => loc.appSettingsFullscreenTabStripHidden,
        TabStrip.pinned => loc.appSettingsFullscreenTabStripAlways,
        TabStrip.button => loc.appSettingsFullscreenTabStripButton,
      };
}

/// Whether the Default search row and the site search list are offered: web
/// search ships with Site tabs (LIR-029, TAB-012), read on every build so
/// flipping either switch takes effect at once.
bool webSearchSettingsOffered() =>
    DeveloperModeService.instance.enabled &&
    ExperimentalFeaturesService.instance.switchOn(ExperimentalFeature.siteTabs);

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
    this.webSearchSites = const [],
  });

  /// LIR-008: entry into the routing overview screen.
  final VoidCallback onOpenLinkHandlingSettings;

  /// The user's web search sites outside every archive (LIR-029), each with
  /// its container's colour, null on the legacy engine.
  final List<PickableSearchSite> webSearchSites;

  @override
  State<AppBehaviourScreen> createState() => _AppBehaviourScreenState();
}

class _AppBehaviourScreenState extends State<AppBehaviourScreen>
    with SettingsOpenGuard, RebuildOnAppPref {
  /// The tab width while its slider is dragged; persisted on release.
  double? _tabWidthDrag;

  void _setTabStrip(TabStrip mode) {
    AppPref.showTabStrip.set(mode == TabStrip.pinned);
    AppPref.tabBarButton.set(mode == TabStrip.button);
    // "Keep in full screen" only applies to a pinned strip. Leaving it set
    // in button mode would pin the strip in full screen and hide the button
    // there; clear it whenever we leave the pinned mode.
    if (mode != TabStrip.pinned) AppPref.tabStripInFullscreen.set(false);
  }

  /// A title with its control at the end of the row.
  Widget _row(Widget title, Widget trailing) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(children: [Expanded(child: title), trailing]),
      );

  Widget _tabStripPicker(
    List<TabStrip> modes,
    TabStrip selected,
    ValueChanged<TabStrip> onChanged,
  ) {
    final loc = AppLocalizations.of(context);
    return SegmentedButton<TabStrip>(
      segments: [
        for (final m in modes)
          ButtonSegment(value: m, icon: Icon(m.icon), tooltip: m.tooltip(loc)),
      ],
      selected: {selected},
      showSelectedIcon: false,
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }

  /// Whether the tab strip can appear at all (pinned out of fullscreen, pinned
  /// in fullscreen, or revealed by the tab-bar button), so the width limit is
  /// meaningful.
  bool get _tabStripCanShow =>
      AppPref.showTabStrip.value ||
      AppPref.tabStripInFullscreen.value ||
      AppPref.tabBarButton.value;

  String? get _webSearchDefaultName {
    final site = widget.webSearchSites
        .where((s) => s.siteId == AppPref.webSearchDefaultSite.value)
        .firstOrNull;
    if (site == null) return null;
    return searchSiteSummaryName(site.name, site.siteId,
        widget.webSearchSites.map((s) => s.name));
  }

  /// LIR-029: which web search site Web search starts with. Only sites outside
  /// every archive are offered, so the pref never names an archived site.
  Future<void> _pickWebSearchDefault() async {
    final loc = AppLocalizations.of(context);
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SearchSiteChoiceDialog(
        title: loc.webSearchDefaultTitle,
        sites: widget.webSearchSites,
        selected: AppPref.webSearchDefaultSite.value,
        emptyText: loc.webSearchNoWebSites,
        cancelLabel: loc.commonCancel,
      ),
    );
    if (picked != null) await AppPref.webSearchDefaultSite.set(picked);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final backOpensMenuHint = hostIsAndroid
        ? '${loc.appSettingsBackOpensMenuHint} ${loc.appSettingsBackOpensMenuHintExit}'
        : loc.appSettingsBackOpensMenuHint;
    final tabWidth = _tabWidthDrag ?? AppPref.tabMaxWidth.value.toDouble();
    final tabWidthLabel = '${tabWidth.round()} px';
    return Scaffold(
      appBar: AppBar(title: Text(loc.appSettingsBehaviour)),
      body: ListView(
        children: [
          SettingsSection(loc.appSettingsGroupTabStrip),
          _row(
            HintedTitle(loc.appSettingsSiteTabStrip,
                hint: loc.appSettingsSiteTabStripSubtitle),
            _tabStripPicker(TabStrip.values, TabStrip.current, _setTabStrip),
          ),
          // Pinned mode only: whether the pinned strip stays visible in full
          // screen. Button mode reveals the strip in full screen on its own;
          // hidden mode has nothing to keep.
          if (TabStrip.current == TabStrip.pinned)
            _row(
              Text(loc.appSettingsFullscreenTabStrip),
              _tabStripPicker(
                const [TabStrip.hidden, TabStrip.pinned],
                AppPref.tabStripInFullscreen.value
                    ? TabStrip.pinned
                    : TabStrip.hidden,
                (mode) =>
                    AppPref.tabStripInFullscreen.set(mode == TabStrip.pinned),
              ),
            ),
          _row(
            HintedTitle(loc.appSettingsTabMaxWidth,
                hint: loc.appSettingsTabMaxWidthHint),
            Text(tabWidthLabel),
          ),
          Slider(
            value: tabWidth,
            min: 80,
            max: 320,
            divisions: 24,
            label: tabWidthLabel,
            onChanged: _tabStripCanShow
                ? (value) => setState(() => _tabWidthDrag = value)
                : null,
            onChangeEnd: _tabStripCanShow
                ? (value) {
                    _tabWidthDrag = null;
                    AppPref.tabMaxWidth.set(value.round());
                  }
                : null,
          ),
          SettingsSection(loc.appSettingsGroupOpening),
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
          if (webSearchSettingsOffered()) ...[
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
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
